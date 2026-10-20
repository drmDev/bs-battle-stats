extends RefCounted
## The game's own look, loaded from its pack at runtime: panel styleboxes, fonts and icons.
## Every lookup has a fallback, so a renamed asset after a game patch degrades to a plain
## panel instead of breaking the overlay.

const PANEL_THEME := "res://assets/ui/themes/panel_container.tres"
const SECTION_THEME := "res://assets/ui/themes/inner_section_container.tres"
const HEADER_THEME := "res://assets/ui/themes/header_yellow_panel.tres"
const HEADER_RED_THEME := "res://assets/ui/themes/header_red_panel.tres"
const FONT_HEADER := "res://assets/ui/fonts/Guilty Treasure.otf"
const FONT_TEXT := "res://assets/ui/fonts/ChevyRay - Express.ttf"
const FONT_NUMBER := "res://assets/ui/fonts/ChevyRay - Little League.ttf"
# Player names can be Thai, Japanese, Korean, Chinese, ...: the game's pixel fonts are Latin-only,
# so every font we draw with falls back to the game's own Noto fonts, then to a system font.
const FALLBACK_FONTS := [
	"res://assets/ui/fonts/NotoSansJP-ExtraBold.ttf",
	"res://assets/ui/fonts/NotoSansKR-ExtraBold.ttf",
	"res://assets/ui/fonts/NotoSansSC-ExtraBold.ttf",
]
const SYSTEM_FALLBACKS := ["Leelawadee UI", "Tahoma", "Segoe UI", "Noto Sans Thai", "Noto Sans", "Arial Unicode MS", "Droid Sans Fallback"]
const ICON_LIVES := "res://assets/ui/textures/shop/lives_icon.png"
const ICON_LIVES_SC := "res://assets/ui/textures/shop/lives_icon_second_chance.png"

# Colours sampled from the game's text themes (description_text / small_header / small_number)


const OUTLINE := Color(0.251, 0.251, 0.251)
const WHITE := Color(0.98, 0.98, 0.98)
const GOLD := Color(1.0, 0.82, 0.25)
const RED := Color(0.93, 0.36, 0.33)                # opponent side

# my customs
const INK := Color("#263348")
const INK_SHADOW := Color("#ffffff")
const BLUE := Color("#007f91")
const DIM := Color("#747d8c")

var panel: StyleBox
var section: StyleBox
var header: StyleBox
var header_red: StyleBox
var font_header: Font
var font_text: Font
var font_number: Font
var icon_lives: Texture2D
var icon_lives_sc: Texture2D
var fallbacks: Array[Font] = []      # shared fallback chain (game Noto fonts + a system font)
var ellipsis := "..."                # U+2026 when a font of ours has it (resolved once in _init)
var _fit_cache: Dictionary = {}
var missing: Array[String] = []     # assets that fell back (logged once, checked by the harness)


func _init() -> void:
	panel = _flat(Color("#f0f4f8"), Color("#52647a"))
	section = _style(SECTION_THEME, _flat(Color(0.86, 0.85, 0.82), Color(0.6, 0.6, 0.62)))
	header = _style(HEADER_THEME, _flat(Color(0.98, 0.8, 0.3), Color(0.35, 0.28, 0.1)))
	header_red = _flat(Color("#24788a"), Color("#153b49"))
	for p in FALLBACK_FONTS:
		if ResourceLoader.exists(p):
			var f = load(p)
			if f is Font:
				fallbacks.append(f)
	var sys := SystemFont.new()
	sys.font_names = PackedStringArray(SYSTEM_FALLBACKS)
	fallbacks.append(sys)

	# my customs 2
	var custom_font := SystemFont.new()
	custom_font.font_names = PackedStringArray(["Consolas"])
	custom_font.fallbacks = fallbacks
	font_header = custom_font
	font_text = custom_font
	font_number = custom_font

	icon_lives = _tex(ICON_LIVES)
	icon_lives_sc = _tex(ICON_LIVES_SC)
	var e := String.chr(0x2026)
	if can_draw(font_text, e) and can_draw(font_header, e):
		ellipsis = e


func _style(theme_path: String, fallback: StyleBox) -> StyleBox:
	if ResourceLoader.exists(theme_path):
		var th = load(theme_path)
		if th is Theme and th.has_stylebox("panel", "PanelContainer"):
			return th.get_stylebox("panel", "PanelContainer")
	missing.append(theme_path)
	return fallback


## The game font wrapped in our own FontVariation carrying the fallback chain. The game's font
## resource itself is never modified (its own UI keeps exactly its own fonts).
func _font(path: String) -> Font:
	var base: Font = ThemeDB.fallback_font
	if ResourceLoader.exists(path) and load(path) is Font:
		base = load(path)
	else:
		missing.append(path)
	var v := FontVariation.new()
	v.base_font = base
	v.fallbacks = fallbacks
	return v


## `text` shortened with an ellipsis so it fits `max_w` at `size` (the draw_string equivalent of a
## Label's OVERRUN_TRIM_ELLIPSIS). Works per character, so Thai / CJK names trim cleanly too.
## Results are cached: the panels redraw often and a name only changes between battles.
func fit(font: Font, text: String, size: int, max_w: float) -> String:
	if max_w <= 0.0:
		return ""
	var key := "%d|%d|%d|%s" % [font.get_instance_id(), size, int(max_w), text]
	if _fit_cache.has(key):
		return _fit_cache[key]
	if _fit_cache.size() > 256:
		_fit_cache.clear()
	var out := _fit(font, text, size, max_w)
	_fit_cache[key] = out
	return out


func _fit(font: Font, text: String, size: int, max_w: float) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= max_w:
		return text
	var dots := ellipsis
	var lo := 0
	var hi := text.length()
	while lo < hi:                     # longest prefix that fits together with the ellipsis
		var mid := (lo + hi + 1) / 2
		var s := text.left(mid).strip_edges(false, true) + dots
		if font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= max_w:
			lo = mid
		else:
			hi = mid - 1
	return text.left(lo).strip_edges(false, true) + dots if lo > 0 else dots


## True when `text` can be drawn by one of our fonts (its own glyphs or the fallback chain).
func can_draw(font: Font, text: String) -> bool:
	for i in text.length():
		var c := text.unicode_at(i)
		if c <= 32:
			continue
		if font.has_char(c):
			continue
		var ok := false
		for fb in fallbacks:
			if fb.has_char(c):
				ok = true
				break
		if not ok:
			return false
	return true


func _tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		var t = load(path)
		if t is Texture2D:
			return t
	missing.append(path)
	return null


static func _flat(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(3)
	s.set_content_margin_all(4)
	return s


## Text with the game's outlined-number look (white fill, dark outline).
static func outlined(ci: CanvasItem, font: Font, pos: Vector2, text: String, size: int, col: Color,
		width := -1.0, align := HORIZONTAL_ALIGNMENT_LEFT, outline := 2) -> void:
	# 2 px: wider outlines on the small pixel fonts merge neighbouring glyphs into a smear
	ci.draw_string_outline(font, pos, text, align, width, size, outline, OUTLINE)
	ci.draw_string(font, pos, text, align, width, size, col)


## Body text in the game's description style (dark ink with a light shadow) for light panels.
static func ink(ci: CanvasItem, font: Font, pos: Vector2, text: String, size: int, col := INK,
		width := -1.0, align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	ci.draw_string(font, pos + Vector2(0, 1), text, align, width, size, INK_SHADOW)
	ci.draw_string(font, pos, text, align, width, size, col)


## Compact number: 950 -> "950", 12345 -> "12.3k", 4.25 -> "4.3".
static func num(v: float) -> String:
	var a: float = absf(v)
	if a >= 1000000.0:
		return "%.1fM" % (v / 1000000.0)
	if a >= 10000.0:
		return "%.1fk" % (v / 1000.0)
	if a >= 100.0:
		return str(int(round(v)))
	return "%.1f" % v
