extends "collapsible_panel.gd"
## Battle screen card: who you are fighting, and what YOUR team is doing, live. (No trinkets,
## no health bars, no opponent damage - by request.)
##   header : VS <opponent name>
##   row 1  : username (trainer class) + MMR  |  their lives (icon) / Wins n / Day  |  your team DPS
##   table  : YOUR team - unit, damage dealt so far, damage per second; front row (slots 0-2) on the
##            left, back row (slots 3-5) on the right, like the board
## No health bars and no opponent damage here: the game's own bars already show HP.
## Sits in the strip between the two trainer portraits, below the board, so the game's floating
## damage / heal numbers never cover it. Drag the header to move it; click it (or its -/+ button) to
## minimize it to the header bar. Position and minimized state are remembered.

const W := 424.0
const PAD := 5.0
const ROW := 10.0          # one text row
const GAP := 3.0
const COL_GAP := 12.0
const ICON := 10.0
const FS := 8              # body font size (the game's small text)
const TABLE_ROWS := 3      # 6 slots = 2 columns x 3 rows
const NAME_MAX_W := 120.0  # a long username is trimmed with an ellipsis, the rest of the row stays put
const NAME_FS := 12        # opponent name in the header (headline; the game uses this font at 12)
const VS_FS := 9

var info: Dictionary = {}            # static facts (mod_main.opponent_info)
var live: Dictionary = {}            # live battle snapshot (mod_main.battle_snapshot)


func setup(p_skin) -> void:
	size = Vector2(W, 80)
	super(p_skin)


func full_height() -> float:
	if info.is_empty():
		return HEAD_H + 20.0
	return HEAD_H + PAD + ROW + GAP + ROW + TABLE_ROWS * ROW + PAD + 3


func header_style() -> StyleBox:
	return skin.header_red


func header_text() -> String:
	return "My Battle Stats"


## The opponent's name is the card's headline: a small white "VS", then the name in the game's
## header font, gold with the dark outline, centred; a long name is trimmed with an ellipsis so it
## never runs under the -/+ button.
func draw_header_text(r: Rect2) -> void:
	super.draw_header_text(r)


func _record_text() -> String:
	var rec := "Day %d" % int(info.get("round", 0))
	if info.get("second_chance", false):
		rec += " (2nd chance used)"
	return rec


func show_info(p_info: Dictionary, p_live: Dictionary) -> void:
	info = p_info
	live = p_live
	_apply_size()
	queue_redraw()


## Baseline y for a text row whose top is `top`.
static func _base(top: float) -> float:
	return top + ROW - 2.0


func _started() -> bool:
	return float(live.get("time", 0.0)) > 0.0


func draw_body() -> void:
	if info.is_empty():
		return
	var x := PAD + 2
	var cw := size.x - x * 2
	var y := HEAD_H + PAD
	_info_row(x, y, cw)
	y += ROW + GAP
	draw_line(Vector2(x, y - 2), Vector2(x + cw, y - 2), Color(skin.INK, 0.2), 1.0)
	_team_table(x, y, cw)



func _info_row(x: float, y: float, cw: float) -> void:
	var b := _base(y)
	var cx := x
	var f: Font = skin.font_text

	var summary := "My HP %s   Wins %s   Day %s" % [
		str(info.get("my_hp", "?")),
		str(info.get("my_wins", "?")),
		str(info.get("my_day", "?")),
	]
	skin.ink(self, f, Vector2(cx, b), summary, FS)

	# right: your team's DPS (only yours)
	var t: float = maxf(float(live.get("time", 0.0)), 0.001)
	var dps_txt := "-"
	if _started():
		dps_txt = skin.num(float(live.get("damage", 0.0)) / t)
	var vw: float = skin.font_text.get_string_size(dps_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x
	skin.ink(self, skin.font_text, Vector2(x + cw - vw, b), dps_txt, FS, skin.BLUE)
	skin.ink(self, skin.font_text, Vector2(x, b), "Your DPS ", FS, skin.DIM, cw - vw - 2, HORIZONTAL_ALIGNMENT_RIGHT)


## YOUR team: two columns (front row slots 0-2, back row slots 3-5), each "name  damage  /s".
func _team_table(x: float, y: float, cw: float) -> void:
	var col_w := (cw - COL_GAP) * 0.5
	var num_w := 40.0
	var t: float = maxf(float(live.get("time", 0.0)), 0.001)
	for c in 2:
		var cx := x + c * (col_w + COL_GAP)
		skin.ink(self, skin.font_text, Vector2(cx, _base(y)), "Your team - %s" % ("front" if c == 0 else "back"), FS, skin.DIM)
		skin.ink(self, skin.font_text, Vector2(cx + col_w - num_w * 2 - 4, _base(y)), "damage", FS, skin.DIM, num_w, HORIZONTAL_ALIGNMENT_RIGHT)
		skin.ink(self, skin.font_text, Vector2(cx + col_w - num_w, _base(y)), "per sec", FS, skin.DIM, num_w, HORIZONTAL_ALIGNMENT_RIGHT)
	var dx := x + col_w + COL_GAP * 0.5
	draw_line(Vector2(dx, y), Vector2(dx, y + ROW * (TABLE_ROWS + 1)), Color(skin.INK, 0.2), 1.0)
	var units: Dictionary = live.get("my_units", {})
	var top := 0.0
	for s in units:
		top = maxf(top, float(units[s].get("damage", 0.0)))
	for u in info.get("my_team", []):
		var slot := int(u.slot)
		var c := 0 if slot < TABLE_ROWS else 1
		var r := slot % TABLE_ROWS
		var cx := x + c * (col_w + COL_GAP)
		var ry := y + ROW * (r + 1)
		var row: Dictionary = units.get(slot, {})
		var dead: bool = row.get("dead", false) and _started()
		var d: float = float(row.get("damage", 0.0))
		var col: Color = skin.DIM if dead else skin.INK
		var nm := "%s Lv%d%s%s" % [u.name, int(u.level), "*" if u.get("shiny", false) else "", "  KO" if dead else ""]
		skin.ink(self, skin.font_text, Vector2(cx, _base(ry)), skin.fit(skin.font_text, nm, FS, col_w - num_w * 2 - 6), FS, col)
		var best: bool = _started() and d > 0.0 and is_equal_approx(d, top)
		var dmg_txt: String = skin.num(d) if _started() else "-"
		var dps_txt: String = skin.num(d / t) if _started() else "-"
		skin.ink(self, skin.font_text, Vector2(cx + col_w - num_w * 2 - 4, _base(ry)), dmg_txt, FS, col, num_w, HORIZONTAL_ALIGNMENT_RIGHT)
		skin.ink(self, skin.font_text, Vector2(cx + col_w - num_w, _base(ry)), dps_txt, FS,
			Color("#a36800") if best else(skin.BLUE if d > 0.0 and not dead else col), num_w, HORIZONTAL_ALIGNMENT_RIGHT)



func _icon_count(tex: Texture2D, x: float, y: float, text: String, col: Color) -> float:
	if tex != null:
		draw_texture_rect(tex, Rect2(x, y, ICON, ICON), false)
		x += ICON + 2
	skin.outlined(self, skin.font_text, Vector2(x, _base(y)), text, FS, col, -1, HORIZONTAL_ALIGNMENT_LEFT, 2)
	return x + skin.font_text.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x
