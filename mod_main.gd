extends Node
## BatoEyes - always-on information overlay for Batomon Showdown.
##   * Battle: who you are fighting right now (name, trainer, MMR, Day / wins / lives left)
##     and your own team's live DPS with every unit's damage so far.
##   * Updates itself from the mod's GitHub releases (updater.gd; Settings > Mods > Auto-update,
##     updates the author marks as required install even with it off).
## No hotkeys: the overlay follows the active game scene. Read-only toward the game: it never
## changes the run, the shop, the battle, saves, uploads or matchmaking. It writes only its own
## settings and, when updating, its own folder.
##
## Install: Mods/BatoEyes/ for the community Mod Loader (this file is its mod_main.gd), or as a plain
## autoload line (BatoEyes="*res://BatoEyes/mod_main.gd"). Sibling scripts are loaded relative to
## this file, so both locations work. A second copy (loader + autoload) stays idle.

const VERSION := "0.2.0"
const MOD_ID := "mybattlestats"
const GROUP := "mybattlestats_core"
const CFG_PATH := "user://mybattlestats.cfg"
const POLL_SEC := 0.1
const BATTLE_STATE := "res://game/states/battle_state.gd"
const PARTS := ["ui_skin.gd", "collapsible_panel.gd", "opponent_hud.gd"]
const SETTINGS := {"opponent_panel": true, "auto_update": true}
const DEFAULT_HUD_POS := Vector2(108, 244)    # strip between the two trainer portraits, below the board

var base_dir := ""
var skin
var layer: CanvasLayer
var hud
var updater
var cfg := ConfigFile.new()
var settings := SETTINGS.duplicate()
var active := false                  # true = the overlay runs (false: idle duplicate / broken part / update required)
var phase := ""                      # "battle" | ""
var off_reason := ""                 # why the overlay is off ("" while it runs)

var _poll_ms := 0
var _captured_opponent = null        # RunData the game handed to the battle transition (has MMR)
var _captured_at := 0
var _battle_id := 0                  # instance id of the battle state the HUD info belongs to
var _info: Dictionary = {}


var hooks: Array[String] = []        # Mod Loader lifecycle hooks received, in order (log + harness)
var _booted := false


func _init() -> void:
	base_dir = str(get_script().resource_path).get_base_dir()


func _sub(file: String):
	return load(base_dir.path_join(file))


# ---- Mod Loader lifecycle: mod_init (instantiated, not in the tree yet) -> _ready -> mod_ready
# -> mod_bootstrap. Under the loader everything starts in mod_ready; as a plain autoload no hook is
# called, so _ready starts it. Nothing here touches the loader, other mods or override.cfg.

func mod_init() -> void:
	hooks.append("mod_init")


func mod_ready() -> void:
	hooks.append("mod_ready")
	_boot()


func mod_bootstrap() -> void:
	hooks.append("mod_bootstrap")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not _from_loader():
		_boot()


func _exit_tree() -> void:
	if active:
		_save_cfg()
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


func _boot() -> void:
	if _booted:
		return
	_booted = true
	for other in get_tree().get_nodes_in_group(GROUP):
		if other != self and is_instance_valid(other):
			print("BatoEyes: another copy is already running (%s) - this one stays idle" % other.get_path())
			return
	add_to_group(GROUP)
	cfg.load(CFG_PATH)
	# 0.1.0 had a shop panel; its saved position / state are no longer used
	for k in ["dps_pos", "dps_minimized"]:
		if cfg.has_section_key("ui", k):
			cfg.erase_section_key("ui", k)
	_load_settings()
	# _start_updater()
	_boot_overlay()
	if updater != null:
		updater.skin = skin
		updater.start()
	var loader = get_node_or_null("/root/ModLoader")
	if loader != null and loader.has_signal("config_changed"):
		loader.config_changed.connect(_on_config_changed)
	print("BatoEyes %s loaded (%s)%s" % [VERSION, "Mod Loader" if _from_loader() else "autoload",
		"" if active else " - overlay off: " + off_reason])


## The updater comes first and uses engine APIs only: it keeps running when a game patch breaks the
## overlay, so a fixed version can still arrive.
func _start_updater() -> void:
	# Personal copy: do not create or start the upstream updater.
	pass


func _boot_overlay() -> void:
	# a part that fails to compile (e.g. after a game patch) -> overlay off with one warning,
	# never a stream of errors inside the game
	for f in PARTS:
		var s = _sub(f)
		if not (s is Script) or not s.can_instantiate():
			off_reason = "%s failed to load" % f
			push_warning("BatoEyes %s: %s - overlay disabled" % [VERSION, off_reason])
			return
	if updater != null and updater.below_required():
		off_reason = "update required (version %s or newer)" % updater.cfg.get_value("update", "min_version", "?")
		return
	active = true

	skin = _sub("ui_skin.gd").new(base_dir)
	if not skin.missing.is_empty():
		push_warning("BatoEyes: game assets not found, using fallbacks: %s" % ", ".join(skin.missing))
	layer = CanvasLayer.new()
	layer.layer = 110
	layer.name = "BatoEyesLayer"
	add_child(layer)

	hud = _sub("opponent_hud.gd").new()
	hud.name = "OpponentHud"
	hud.setup(skin)
	hud.position = _on_screen(cfg.get_value("ui", "battle_hud_pos", DEFAULT_HUD_POS), DEFAULT_HUD_POS)
	hud.set_minimized(bool(cfg.get_value("ui", "battle_hud_minimized", false)), false)
	hud.visible = false
	layer.add_child(hud)
	# the player's minimize / move choices are saved at once (they hold across rounds and restarts)
	hud.minimized_changed.connect(func(_on): _save_cfg())
	hud.moved_by_drag.connect(_save_cfg)

	get_tree().node_added.connect(_on_node_added)


## The author marked this version as too old: the overlay goes off now (the updater installs the
## required version; it runs from the next game start).
func _on_update_required(min_version: String) -> void:
	if not active:
		return
	_save_cfg()
	active = false
	off_reason = "update required (version %s or newer)" % min_version
	hud.visible = false
	print("BatoEyes %s: %s - overlay off" % [VERSION, off_reason])


func _from_loader() -> bool:
	var p = get_parent()
	return p != null and p == get_node_or_null("/root/ModLoader")


func _load_settings() -> void:
	var loader = get_node_or_null("/root/ModLoader")
	for k in SETTINGS:
		var v = cfg.get_value("settings", k, SETTINGS[k])
		if loader != null and loader.has_method("get_config"):
			var lv = loader.get_config(MOD_ID, k, null)
			if lv is bool:
				v = lv
		settings[k] = bool(v)


func _on_config_changed(mod_id: String, key: String, value) -> void:
	if mod_id == MOD_ID and settings.has(key) and value is bool:
		settings[key] = value
		print("BatoEyes: %s %s" % [key, "on" if value else "off"])
		if key == "auto_update" and updater != null:
			updater.set_auto(value)


func _save_cfg() -> void:
	if not active:
		return
	cfg.set_value("ui", "battle_hud_pos", hud.position)
	cfg.set_value("ui", "battle_hud_minimized", hud.minimized)
	cfg.save(CFG_PATH)


## A saved position that is off the 640x360 canvas (older layout, other resolution) -> default.
static func _on_screen(pos, fallback: Vector2) -> Vector2:
	if not (pos is Vector2) or not Rect2(Vector2(-40, 0), Vector2(660, 345)).has_point(pos):
		return fallback
	return pos


func _notification(what: int) -> void:
	if what in [NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT]:
		if active and hud.moved:
			_save_cfg()


## Script `n` is `path` or a subclass of it (other mods swap in subclasses of game scripts).
static func script_is(n, path: String) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	var s = n.get_script()
	while s != null:
		if str(s.resource_path) == path:
			return true
		s = s.get_base_script()
	return false


func _on_node_added(n: Node) -> void:
	if n.has_signal("transition_requested") and n.has_method("request_transition"):
		# read-only listener: the battle transition carries the opponent RunData (MMR / bot flags)
		if not n.transition_requested.is_connected(_on_transition):
			n.transition_requested.connect(_on_transition)


func _on_transition(target: String, data: Dictionary) -> void:
	if target != "battle":
		return
	var opp = data.get("opponent_data")
	if opp != null and is_instance_valid(opp):
		_captured_opponent = opp
		_captured_at = Time.get_ticks_msec()


func current_state():
	var main = get_tree().current_scene
	if main == null or not ("current_state" in main):
		return null
	var st = main.current_state
	return st if st != null and is_instance_valid(st) else null


func _process(_delta: float) -> void:
	if not active:
		return
	# real time, not delta: the game slows / stops Engine.time_scale (KO slow motion, pause)
	var now := Time.get_ticks_msec()
	if now - _poll_ms < int(POLL_SEC * 1000.0):
		return
	_poll_ms = now
	var st = current_state()
	phase = "battle" if script_is(st, BATTLE_STATE) else ""
	_tick_battle(st)


# ------------------------------------------------------------------ battle

func _tick_battle(st) -> void:
	if phase != "battle" or not settings.opponent_panel:
		hud.visible = false
		return
	var p2 = st.get("_replay_p2_data")
	if p2 == null:
		hud.visible = false
		return
	if st.get_instance_id() != _battle_id or _info.is_empty():
		_battle_id = st.get_instance_id()
		_info = opponent_info(p2, _captured_opponent)
		_info["my_team"] = team_list(st.get("_replay_p1_data"))

	var my_run = st.get("_replay_p1_data")
	_info["my_hp"] = "?"
	_info["my_wins"] = "?"
	_info["my_day"] = "?"

	if my_run != null:
		for pair in [
			["my_hp", "lives"],
			["my_wins", "current_wins"],
			["my_day", "current_round"],
		]:
			var value = my_run.get(pair[1])
			if value != null:
				_info[pair[0]] = str(value)
				
	var sim = st.get("simulation")
	hud.show_info(_info, battle_snapshot(sim))
	# the game's VS intro already names both sides full-screen: the card appears once the fight runs
	hud.visible = bool(st.get("is_battle_active")) or (sim != null and (float(sim.data.time_elapsed) > 0.0 or sim.data.battle_over))


## Static facts about the opponent for the HUD (from the battle's own copy of their run).
func opponent_info(p2, captured) -> Dictionary:
	var trainer = GameDatabase.get_trainer_by_id(str(p2.trainer_id))
	if trainer == null:
		trainer = GameDatabase.get_trainer_by_id("youngster_f")
	var trainer_name: String = str(trainer.name) if trainer != null else ""
	var shown := display_name_for(p2, trainer_name)
	return {
		"name": shown,                                       # what the game's VS screen shows
		"player": shown if shown != trainer_name else "",    # the ghost's username ("" = hidden / none)
		"trainer": trainer_name,                             # trainer class (Chef, Painter, ...)
		"mmr": mmr_text(captured if _same_opponent(captured, p2) else null),
		"round": int(p2.current_round),
		"wins": int(p2.current_wins),
		"lives": int(p2.lives),
		"lives_lost": int(p2.lives_lost),
		"second_chance": bool(p2.has_used_second_chance),
	}


## Units of a run by board slot (0-2 front row, 3-5 back row).
static func team_list(run) -> Array:
	var out: Array = []
	if run == null:
		return out
	for i in run.team.size():
		var m = run.team[i]
		if m != null and m.data != null:
			out.append({"slot": i, "name": str(m.data.name), "level": int(m.level), "shiny": bool(m.is_shiny)})
	return out


## The name the game itself shows in the battle intro (respects "hide usernames").
static func display_name_for(p2, trainer_name: String) -> String:
	var show := true
	if SettingsManager.has_method("is_hide_usernames_enabled"):
		show = not SettingsManager.is_hide_usernames_enabled()
	if show and UserManager.data and str(UserManager.data.display_name) != "":
		var n := str(p2.display_name)
		return n if n != "" else trainer_name
	return trainer_name


func _same_opponent(captured, p2) -> bool:
	return captured != null and is_instance_valid(captured) \
		and str(captured.display_name) == str(p2.display_name) \
		and str(captured.trainer_id) == str(p2.trainer_id) \
		and Time.get_ticks_msec() - _captured_at < 600000


static func mmr_text(opp) -> String:
	if opp == null:
		return ""
	var uid := str(opp.get("_matched_user_id"))
	var mmr := int(opp.get("_matched_opponent_mmr")) if opp.get("_matched_opponent_mmr") != null else -1
	if uid.begins_with("bot_"):
		return "Bot"
	if mmr < 0:
		return ""
	if opp.get("_matched_mmr_is_ranked") == false:
		return "MMR %d (casual)" % mmr
	return "MMR %d" % mmr


## Live numbers of YOUR side of the visual battle simulation (the one on screen): your team's
## damage (hits + burn / poison) and each of your units' damage so far (hits + its status share).
static func battle_snapshot(sim) -> Dictionary:
	if sim == null or sim.data == null:
		return {}
	var d = sim.data

	# Temporary diagnostic: log once when a friendly unit is available.
	if not sim.has_meta("my_stats_fields_logged"):
		for debug_unit in d.battle_units:
			if debug_unit == null or debug_unit.team_id != 0:
				continue

			sim.set_meta("my_stats_fields_logged", true)

			print("MyBattleStats: BATTLE DATA FIELDS")
			for property in d.get_property_list():
				print("MyBattleStats data field: ", property["name"])

			print("MyBattleStats: UNIT FIELDS")
			for property in debug_unit.get_property_list():
				print("MyBattleStats unit field: ", property["name"])

			var unit_script: Script = debug_unit.get_script()
			if unit_script != null:
				print("MyBattleStats unit script: ", unit_script.resource_path)

			break

	# burn / poison damage is pooled per team by the game: each unit gets the share of it that matches
	# its share of the burn + poison stacks your team applied
	var units := {}
	var stacks := 0.0
	for u in d.battle_units:
		if u == null or u.team_id != 0:
			continue
		var s: int = u.slot_index
		var r: Dictionary = units.get(s, {"damage": 0.0, "heal": 0.0, "shield": 0.0, "stacks": 0.0, "dead": true})
		r.damage = float(r.damage) + float(u.damage_dealt)
		r.heal = float(r.heal) + float(u.healing_done)
		r.shield = float(r.shield) + float(u.shield_granted)
		r.stacks = float(r.stacks) + float(u.burn_inflicted + u.poison_inflicted)
		r.dead = bool(r.dead) and bool(u.is_dead)
		units[s] = r
		stacks += float(u.burn_inflicted + u.poison_inflicted)
	var status_dmg := float(d.team_status_damage_dealt[0])
	for s in units:
		if stacks > 0.0:
			units[s].damage = float(units[s].damage) + status_dmg * float(units[s].stacks) / stacks
	
	# Calculate team-wide heal and shield totals by summing per-unit values
	var total_heal := 0.0
	var total_shield := 0.0
	for s in units:
		total_heal += float(units[s].get("heal", 0.0))
		total_shield += float(units[s].get("shield", 0.0))
	
	return {
		"time": float(d.time_elapsed),
		"damage": float(d.team_damage_dealt[0]) + float(d.team_status_damage_dealt[0]),
		"heal": total_heal,
		"shield": total_shield,
		"my_units": units,
		"over": bool(d.battle_over),
	}
