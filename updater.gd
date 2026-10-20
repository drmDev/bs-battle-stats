extends Node
## BatoEyes self-updater. Once per game start (and every 6 h while the game runs) it reads a small
## manifest (update.json) from the mod's GitHub releases. When a newer BatoEyes is out it downloads
## the release zip and checks it before anything on disk changes:
##   * SHA-256 and size = the manifest's, the address starts with the mod's own release URL
##   * only Mods/BatoEyes/<name>.gd|json|txt entries, plain ASCII text, nothing else
##   * the version inside (mod.json + mod_main.gd) = the manifest's
##   * every script of the update compiles on THIS game build (loaded from a staging folder)
## Then it replaces the files of its own folder (old ones backed up, put back if a swap fails) and
## removes scripts the new version no longer has. The running game keeps the old scripts; the new
## version starts with the next game start. Nothing outside Mods/BatoEyes and user://batoeyes_update
## is written.
##
## Auto-update (Settings > Mods, default on) installs new versions by itself. With it off, a new
## version only shows a notice - unless the manifest's "min_version" is above the running version:
## then the update is REQUIRED (forced): it installs anyway and the overlay stays off until the game
## restarts on the new version. The last min_version seen is kept in batoeyes.cfg, so a forced
## update also holds on an offline start.
## Engine APIs only (no game classes): it keeps working when a game patch breaks the overlay, which
## is exactly when a fixed version has to arrive.
##
## Manifest (a release asset, built by tools/package_release.ps1):
##   {"mod": "batoeyes", "version": "0.2.1", "min_version": "0.2.0", "url": "<zip address>",
##    "sha256": "<hex>", "size": 12345, "notes": "one line"}
## batoeyes.cfg [update] keys (shared by every version - keep them stable):
##   min_version, installed_version, announced, notes

signal finished(state: String)        # current | available | installed | no_release | offline | error
signal required(min_version: String)  # the running version is below the author's minimum

const MANIFEST_URL := "https://github.com/Maxkii3/BatoEyes/releases/latest/download/update.json"
const DOWNLOAD_PREFIX := "https://github.com/Maxkii3/BatoEyes/releases/download/"
const WORK_DIR := "user://batoeyes_update"
const ZIP_ROOT := "Mods/BatoEyes/"
const FIRST_CHECK_SEC := 4.0
const RECHECK_SEC := 6.0 * 3600.0
const MAX_MANIFEST := 64 * 1024
const MAX_ZIP := 2 * 1024 * 1024
const MAX_UNZIPPED := 4 * 1024 * 1024
const NAME_PATTERN := "^[A-Za-z0-9_\\-]+\\.(gd|json|txt)$"
const VERSION_PATTERN := "^\\d+(\\.\\d+){0,3}(-[A-Za-z0-9.]+)?$"

var version := ""
var mod_dir := ""                     # folder of the running mod_main.gd (absolute or res://)
var cfg: ConfigFile
var cfg_path := ""
var auto_update := true
var manifest_url := MANIFEST_URL
var allow_prefix := DOWNLOAD_PREFIX
var enabled := true                   # dev / test builds: only with a test channel (setup)
var skin                              # the overlay's skin when it runs (toasts fall back to plain styles)
var state := "idle"                   # idle | checking | downloading | one of the finished() states
var detail := ""                      # reason of the last error / version found or installed
var remote: Dictionary = {}           # last valid manifest
var installed := ""                   # version installed this session (waits for the restart)
var last_notice := ""

var _next_check_ms := -1
var _layer: CanvasLayer
var _toast = null
var _shown := {}                      # notices already shown this session
var _name_re := RegEx.create_from_string(NAME_PATTERN)
var _version_re := RegEx.create_from_string(VERSION_PATTERN)


func setup(p_version: String, p_mod_dir: String, p_cfg: ConfigFile, p_cfg_path: String, p_auto: bool) -> void:
	version = p_version
	mod_dir = p_mod_dir
	cfg = p_cfg
	cfg_path = p_cfg_path
	auto_update = p_auto
	if OS.has_feature("editor"):
		# dev / test builds never call the real channel unless a run asks for it (tests/run_test.sh)
		enabled = false
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--batoeyes-update="):
				manifest_url = a.trim_prefix("--batoeyes-update=")
				enabled = true
			elif a.begins_with("--batoeyes-update-allow="):
				allow_prefix = a.trim_prefix("--batoeyes-update-allow=")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_layer = CanvasLayer.new()
	_layer.layer = 120
	_layer.name = "BatoEyesNotice"
	add_child(_layer)


## Called once the overlay booted (or stayed off): the first-start notice, then the check schedule.
func start() -> void:
	if str(cfg.get_value("update", "installed_version", "")) == version and not bool(cfg.get_value("update", "announced", true)):
		cfg.set_value("update", "announced", true)
		cfg.save(cfg_path)
		var notes := str(cfg.get_value("update", "notes", ""))
		notice("BatoEyes updated to %s" % version, notes if notes != "" else "The new version is running.")
	if enabled:
		_next_check_ms = Time.get_ticks_msec() + int(FIRST_CHECK_SEC * 1000.0)


func set_auto(on: bool) -> void:
	auto_update = on
	if on and state == "available":
		check_now()


## The last manifest said this version is below the author's minimum (holds while offline).
func below_required() -> bool:
	var m := str(cfg.get_value("update", "min_version", ""))
	return m != "" and cmp_version(version, m) < 0


func _process(_delta: float) -> void:
	# real time: the game slows / stops Engine.time_scale
	if _next_check_ms >= 0 and Time.get_ticks_msec() >= _next_check_ms:
		_next_check_ms = Time.get_ticks_msec() + int(RECHECK_SEC * 1000.0)
		check_now()


func check_now() -> void:
	if state == "checking" or state == "downloading" or installed != "":
		return
	state = "checking"
	detail = ""
	var r: Dictionary = await _fetch(manifest_url, MAX_MANIFEST, 20.0)
	if r.result != HTTPRequest.RESULT_SUCCESS:
		_finish("offline" if r.offline else "error", r.why)
		return
	if r.code == 404:
		_finish("no_release", "no release published yet")
		return
	if r.code != 200:
		_finish("error", "manifest HTTP %d" % r.code)
		return
	var m = parse_json(r.body.get_string_from_utf8())
	var bad := manifest_error(m)
	if bad != "":
		_finish("error", bad)
		return
	remote = m
	var newer := cmp_version(str(m.version), version) > 0
	var min_v := str(m.get("min_version", ""))
	if str(cfg.get_value("update", "min_version", "")) != min_v:
		cfg.set_value("update", "min_version", min_v)
		cfg.save(cfg_path)
	var forced := newer and min_v != "" and cmp_version(version, min_v) < 0
	if forced:
		required.emit(min_v)
	if not newer:
		_finish("current", str(m.version))
		return
	if not forced and not auto_update:
		_notice_once("available " + str(m.version), "BatoEyes %s is out" % m.version,
			"Turn on Auto-update in Settings > Mods, or download it from Nexus Mods.")
		_finish("available", str(m.version))
		return
	await _install(m, forced)


func _install(m: Dictionary, forced: bool) -> void:
	var v := str(m.version)
	var err: String = await _download_and_apply(m)
	_clear_work(false)
	if err != "":
		if forced:
			_notice_once("failed " + v, "BatoEyes update required",
				"Could not install %s (%s). Please download it from Nexus Mods - BatoEyes is off until then." % [v, err], true)
		_finish("error", err)
		return
	installed = v
	cfg.set_value("update", "installed_version", v)
	cfg.set_value("update", "announced", false)
	cfg.set_value("update", "notes", str(m.get("notes", "")).left(200))
	cfg.save(cfg_path)
	if forced:
		notice("BatoEyes update required", "Version %s is installed. Restart the game to use it - BatoEyes is off until then." % v, true)
	else:
		notice("BatoEyes %s downloaded" % v, "Restart the game to use the new version.")
	_finish("installed", v)


func _download_and_apply(m: Dictionary) -> String:
	var v := str(m.version)
	var url := str(m.url)
	if not url.begins_with(allow_prefix):
		return "download address not allowed: " + url
	state = "downloading"
	var r: Dictionary = await _fetch(url, MAX_ZIP, 90.0)
	if r.result != HTTPRequest.RESULT_SUCCESS:
		return "download failed: " + r.why
	if r.code != 200:
		return "download HTTP %d" % r.code
	var body: PackedByteArray = r.body
	if m.has("size") and int(m.size) != body.size():
		return "size mismatch (%d bytes, manifest %d)" % [body.size(), int(m.size)]
	if sha256_hex(body) != str(m.sha256).to_lower():
		return "checksum mismatch"
	DirAccess.make_dir_recursive_absolute(WORK_DIR)
	var zip_path := WORK_DIR.path_join("BatoEyes-%s.zip" % v)
	if not _write(zip_path, body):
		return "cannot write " + zip_path
	var z := read_zip(zip_path, v)
	if z.has("error"):
		return z.error
	var c := compile_check(z.files)
	if c != "":
		return c
	return apply(z.files)


## {"result", "code", "body", "why", "offline"} of one GET (redirects followed, size-capped).
func _fetch(url: String, limit: int, timeout_s: float) -> Dictionary:
	var out := {"result": HTTPRequest.RESULT_CANT_CONNECT, "code": 0, "body": PackedByteArray(), "why": "", "offline": true}
	var http := HTTPRequest.new()
	http.use_threads = true
	http.timeout = timeout_s
	http.body_size_limit = limit
	add_child(http)
	var err := http.request(url, PackedStringArray(["User-Agent: BatoEyes/" + version]))
	if err == OK:
		var r: Array = await http.request_completed
		out.result = r[0]
		out.code = r[1]
		out.body = r[3]
	else:
		out.why = "request not started (%s)" % error_string(err)
	http.queue_free()
	if out.why == "":
		out.why = _result_text(int(out.result))
	out.offline = int(out.result) in [HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE,
		HTTPRequest.RESULT_CONNECTION_ERROR, HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR,
		HTTPRequest.RESULT_NO_RESPONSE, HTTPRequest.RESULT_TIMEOUT]
	return out


static func _result_text(result: int) -> String:
	match result:
		HTTPRequest.RESULT_SUCCESS: return ""
		HTTPRequest.RESULT_CANT_CONNECT: return "cannot connect"
		HTTPRequest.RESULT_CANT_RESOLVE: return "no internet (name lookup failed)"
		HTTPRequest.RESULT_CONNECTION_ERROR: return "connection error"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "secure connection failed"
		HTTPRequest.RESULT_NO_RESPONSE: return "no response"
		HTTPRequest.RESULT_TIMEOUT: return "timed out"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: return "file too large"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: return "too many redirects"
	return "network error %d" % result


func manifest_error(m) -> String:
	if not (m is Dictionary):
		return "manifest is not readable"
	if str(m.get("mod", "")) != "batoeyes":
		return "manifest is not for BatoEyes"
	for k in ["version", "url", "sha256"]:
		if not (m.get(k) is String) or str(m[k]) == "":
			return "manifest misses " + k
	if _version_re.search(str(m.version)) == null:
		return "manifest version is malformed"
	var min_v = m.get("min_version", "")
	if not (min_v is String) or (min_v != "" and (_version_re.search(min_v) == null or cmp_version(min_v, str(m.version)) > 0)):
		return "manifest min_version is malformed"
	var sha := str(m.sha256).to_lower()
	if sha.length() != 64 or not sha.is_valid_hex_number():
		return "manifest sha256 is malformed"
	if m.has("size") and not (m.size is float or m.size is int):
		return "manifest size is malformed"
	return ""


## The update zip's files ({"files": {name: bytes}}) or {"error": why}. Only Mods/BatoEyes/<name>
## entries with an allowed name, plain text, the expected version inside.
func read_zip(path: String, want: String) -> Dictionary:
	var z := ZIPReader.new()
	if z.open(path) != OK:
		return {"error": "update zip unreadable"}
	var files := {}
	var seen := {}
	var total := 0
	var err := ""
	for entry in z.get_files():
		var n := str(entry).replace("\\", "/")
		if n.ends_with("/"):
			if not ZIP_ROOT.begins_with(n):
				err = "unexpected folder in the zip: " + n
				break
			continue
		var fname := n.trim_prefix(ZIP_ROOT)
		if not n.begins_with(ZIP_ROOT) or not name_ok(fname):
			err = "file not allowed in the zip: " + n
			break
		if seen.has(fname.to_lower()):
			err = "duplicate file in the zip: " + n
			break
		seen[fname.to_lower()] = true
		var data := z.read_file(entry)
		total += data.size()
		if total > MAX_UNZIPPED:
			err = "zip contents too large"
			break
		if not is_text(data):
			err = "non-text bytes in " + fname
			break
		files[fname] = data
	z.close()
	if err != "":
		return {"error": err}
	if not files.has("mod_main.gd") or not files.has("mod.json"):
		return {"error": "zip misses mod_main.gd / mod.json"}
	var meta = parse_json(files["mod.json"].get_string_from_ascii())
	if not (meta is Dictionary) or str(meta.get("id", "")) != "batoeyes" or str(meta.get("version", "")) != want:
		return {"error": "zip mod.json is not BatoEyes " + want}
	if files["mod_main.gd"].get_string_from_ascii().find('const VERSION := "%s"' % want) < 0:
		return {"error": "zip mod_main.gd is not version " + want}
	return {"files": files}


## Every script of the update loads on this game build (from a fresh staging folder, so nothing is
## served from an earlier attempt's cache); "" = fine.
func compile_check(files: Dictionary) -> String:
	_clear_work(true)
	var stage := WORK_DIR.path_join("stage_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(stage)
	for fname in files:
		if not _write(stage.path_join(fname), files[fname]):
			return "cannot write " + stage
	for fname in files:
		if str(fname).get_extension() == "gd":
			var s = ResourceLoader.load(stage.path_join(fname), "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
			if not (s is Script) or not s.can_instantiate():
				return "%s of the update does not load on this game version" % fname
	return ""


## Swaps the new files into the mod's own folder; "" = done.
func apply(files: Dictionary) -> String:
	var dir := os_dir()
	if dir == "" or not FileAccess.file_exists(dir.path_join("mod_main.gd")):
		return "BatoEyes folder not found"
	var own = parse_json(FileAccess.get_file_as_string(dir.path_join("mod.json")))
	if not (own is Dictionary) or str(own.get("id", "")) != "batoeyes":
		return "BatoEyes folder check failed"
	var names: Array = files.keys()
	names.erase("mod_main.gd")
	names.sort()
	names.append("mod_main.gd")           # the entry script goes last
	# the current files, kept to put back if a swap fails half-way (and as a manual fallback)
	var backup := WORK_DIR.path_join("previous")
	_remove_files(backup)
	DirAccess.make_dir_recursive_absolute(backup)
	var old := {}
	for f in DirAccess.get_files_at(dir):
		if name_ok(f):
			old[f] = FileAccess.get_file_as_bytes(dir.path_join(f))
			_write(backup.path_join(f), old[f])
	for n in names:
		var tmp := dir.path_join(n + ".new")
		if not _write(tmp, files[n]) or FileAccess.get_file_as_bytes(tmp) != files[n]:
			_drop_new(dir, names)
			return "no write access to " + dir
	for i in names.size():
		if DirAccess.rename_absolute(dir.path_join(names[i] + ".new"), dir.path_join(names[i])) != OK:
			for k in i:
				if old.has(names[k]):
					_write(dir.path_join(names[k]), old[names[k]])
				else:
					DirAccess.remove_absolute(dir.path_join(names[k]))
			_drop_new(dir, names)
			return "could not replace " + str(names[i])
	# scripts of older versions the new one no longer has
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() == "gd" and name_ok(f) and not files.has(f):
			DirAccess.remove_absolute(dir.path_join(f))
	return ""


## The mod folder as an OS path (Mod Loader installs already are; res:// = next to the game exe).
func os_dir() -> String:
	if mod_dir.begins_with("res://"):
		if OS.has_feature("editor"):
			return ProjectSettings.globalize_path(mod_dir)
		return OS.get_executable_path().get_base_dir().path_join(mod_dir.trim_prefix("res://"))
	if mod_dir.begins_with("user://"):
		return ProjectSettings.globalize_path(mod_dir)
	return mod_dir


func name_ok(fname: String) -> bool:
	return _name_re.search(fname) != null


## -1 / 0 / 1. Numeric parts compare as numbers; "0.2.1-dev" sorts below "0.2.1".
static func cmp_version(a: String, b: String) -> int:
	var pa := _version_parts(a)
	var pb := _version_parts(b)
	var na: Array = pa[0]
	var nb: Array = pb[0]
	for i in maxi(na.size(), nb.size()):
		var x: int = na[i] if i < na.size() else 0
		var y: int = nb[i] if i < nb.size() else 0
		if x != y:
			return -1 if x < y else 1
	var ta: String = pa[1]
	var tb: String = pb[1]
	if ta == tb:
		return 0
	if ta == "":
		return 1
	if tb == "":
		return -1
	return -1 if ta < tb else 1


static func _version_parts(v: String) -> Array:
	var tag := ""
	var dash := v.find("-")
	if dash >= 0:
		tag = v.substr(dash + 1)
		v = v.left(dash)
	var nums: Array = []
	for p in v.strip_edges().split("."):
		nums.append(int(p) if p.is_valid_int() else 0)
	return [nums, tag]


## JSON text -> value, or null (quietly: a bad manifest must not print engine errors into the log).
static func parse_json(text: String):
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null


static func sha256_hex(data: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	if not data.is_empty():
		h.update(data)
	return h.finish().hex_encode()


## Printable ASCII plus tab / CR / LF (the release scripts are plain text by rule).
static func is_text(data: PackedByteArray) -> bool:
	for b in data:
		if b > 126 or (b < 32 and b != 9 and b != 10 and b != 13):
			return false
	return true


static func _write(path: String, data: PackedByteArray) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	var ok := f.get_error() == OK
	f.close()
	return ok


static func _remove_files(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


static func _drop_new(dir: String, names: Array) -> void:
	for n in names:
		if FileAccess.file_exists(dir.path_join(n + ".new")):
			DirAccess.remove_absolute(dir.path_join(n + ".new"))


## Removes downloaded zips and staging folders (keeps "previous", the last replaced version).
func _clear_work(stages_only: bool) -> void:
	if not DirAccess.dir_exists_absolute(WORK_DIR):
		return
	for d in DirAccess.get_directories_at(WORK_DIR):
		if d.begins_with("stage_"):
			_remove_files(WORK_DIR.path_join(d))
	if not stages_only:
		for f in DirAccess.get_files_at(WORK_DIR):
			if f.get_extension() == "zip":
				DirAccess.remove_absolute(WORK_DIR.path_join(f))


func _finish(s: String, why: String) -> void:
	state = s
	detail = why
	print("BatoEyes update: %s%s" % [s, (" - " + why) if why != "" else ""])
	finished.emit(s)


func _notice_once(key: String, title: String, body: String, urgent := false) -> void:
	if _shown.has(key):
		return
	_shown[key] = true
	notice(title, body, urgent)


## A small notice at the top of the screen (red header = urgent); it fades after a few seconds, a click
## dismisses it.
func notice(title: String, body: String, urgent := false) -> void:
	last_notice = title + " | " + body
	print("BatoEyes: %s - %s" % [title, body])
	if _layer == null:
		return
	if _toast != null and is_instance_valid(_toast):
		_toast.queue_free()
	var t := Toast.new()
	t.name = "Toast"
	_layer.add_child(t)
	t.setup(skin, title, body, urgent)
	_toast = t


class Toast extends Control:
	const FS := 8
	const HEAD := 15.0
	const PAD := 6.0
	const MAX_W := 400.0
	const LIFE_MS := 12000
	const FADE_MS := 600

	var skin
	var title := ""
	var body := ""
	var urgent := false
	var born := 0
	var _font: Font
	var _hfont: Font

	func setup(p_skin, p_title: String, p_body: String, p_urgent: bool) -> void:
		skin = p_skin
		urgent = p_urgent
		title = p_title
		body = p_body
		born = Time.get_ticks_msec()
		process_mode = Node.PROCESS_MODE_ALWAYS
		mouse_filter = Control.MOUSE_FILTER_STOP
		_font = skin.font_text if skin != null else ThemeDB.fallback_font
		_hfont = skin.font_header if skin != null else ThemeDB.fallback_font
		var one: float = _font.get_string_size(body, HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x
		var head: float = _hfont.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var w: float = clampf(maxf(one, head + 24.0) + PAD * 2 + 4, 160.0, MAX_W)
		var text_h: float = _font.get_multiline_string_size(body, HORIZONTAL_ALIGNMENT_LEFT, w - PAD * 2 - 4, FS).y
		size = Vector2(w, HEAD + PAD + text_h + PAD + 2)
		position = Vector2(roundf((get_viewport_rect().size.x - w) * 0.5), 6)

	func _process(_delta: float) -> void:
		var age := Time.get_ticks_msec() - born
		if age > LIFE_MS:
			modulate.a = 1.0 - clampf(float(age - LIFE_MS) / FADE_MS, 0.0, 1.0)
			if age > LIFE_MS + FADE_MS:
				queue_free()

	func _gui_input(event) -> void:
		if event is InputEventMouseButton and event.pressed:
			accept_event()
			queue_free()

	func _draw() -> void:
		var w := size.x
		var tw := w - PAD * 2 - 4
		var tp := Vector2(PAD + 2, HEAD + PAD + FS - 1)
		if skin != null:
			var ci := get_canvas_item()
			skin.panel.draw(ci, Rect2(Vector2(0, 4), Vector2(w, size.y - 4)))
			(skin.header_red if urgent else skin.header).draw(ci, Rect2(Vector2(8, 0), Vector2(w - 16, HEAD)))
			skin.outlined(self, _hfont, Vector2(8, 11), title, 12, skin.WHITE, w - 16, HORIZONTAL_ALIGNMENT_CENTER)
			draw_multiline_string(_font, tp + Vector2(0, 1), body, HORIZONTAL_ALIGNMENT_LEFT, tw, FS, -1, skin.INK_SHADOW)
			draw_multiline_string(_font, tp, body, HORIZONTAL_ALIGNMENT_LEFT, tw, FS, -1, skin.INK)
		else:
			draw_rect(Rect2(Vector2.ZERO, size), Color(0.12, 0.12, 0.14, 0.94))
			draw_rect(Rect2(Vector2.ZERO, Vector2(w, HEAD)), Color(0.85, 0.3, 0.25) if urgent else Color(0.85, 0.65, 0.2))
			draw_string(_hfont, Vector2(0, 11), title, HORIZONTAL_ALIGNMENT_CENTER, w, 10, Color.WHITE)
			draw_multiline_string(_font, tp, body, HORIZONTAL_ALIGNMENT_LEFT, tw, FS, -1, Color(0.95, 0.95, 0.95))
