extends "collapsible_panel.gd"
## Battle screen card showing YOUR team's live stats during battle.
##   header : My Battle Stats
##   row 1  : HP (icon) | Wins (icon) | Day (icon) | Your DPS (right-aligned)
##   table  : YOUR team - unit name, DPS, HPS, SPS; front row (slots 0-2) on the left,
##            back row (slots 3-5) on the right, like the board
## Sits in the strip between the two trainer portraits, below the board, so the game's floating
## damage / heal numbers never cover it. Drag the header to move it; click it (or its -/+ button) to
## minimize it to the header bar. Position and minimized state are remembered.

const W := 424.0
const PAD := 5.0
const ROW := 10.0          # one text row
const GAP := 3.0
const COL_GAP := 12.0
const FS := 8              # body font size (the game's small text)
const TABLE_ROWS := 3      # 6 slots = 2 columns x 3 rows

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
	var baseline := _base(y)
	var cursor_x := x
	var font: Font = skin.font_text

	# Colors: experiment here.
	var hp_normal_color := Color("#a34860")
	var hp_warning_color := Color("#e02020")
	var wins_color := Color("#a36800")
	var day_color := Color("#c46516")
	var label_color: Color = skin.DIM
	var dps_color: Color = skin.BLUE

	# Layout.
	var icon_size := 8.0
	var icon_gap := 3.0
	var label_gap := 3.0
	var group_gap := 12.0

	# Read values safely: "?" should not trigger low-HP highlighting.
	var hp := str(info.get("my_hp", "?"))
	var wins := str(info.get("my_wins", "?"))
	var day := str(info.get("my_day", "?"))
	var low_hp: bool = hp.is_valid_int() and int(hp) <= 3

	var hp_color: Color = hp_normal_color
	if low_hp:
		hp_color = hp_warning_color

	# HP: existing heart artwork, then label and value.
	var heart: Texture2D = skin.icon_lives
	if heart != null:
		var icon_position := Vector2(cursor_x, y + (ROW - icon_size) * 0.5)
		draw_texture_rect(
			heart,
			Rect2(icon_position, Vector2(icon_size, icon_size)),
			false
		)
		cursor_x += icon_size + icon_gap

	var hp_label := "HP"
	var hp_label_color: Color = label_color
	if low_hp:
		hp_label_color = hp_warning_color

	skin.ink(self, font, Vector2(cursor_x, baseline),
		hp_label, FS, hp_label_color)
	cursor_x += font.get_string_size(
		hp_label, HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x + label_gap

	skin.ink(self, font, Vector2(cursor_x, baseline),
		hp, FS, hp_color)
	cursor_x += font.get_string_size(
		hp, HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x + group_gap

	# Wins: badge icon, then gold label and value.
	if skin.icon_badge != null:
		var icon_position := Vector2(cursor_x, y + (ROW - icon_size) * 0.5)
		draw_texture_rect(
			skin.icon_badge,
			Rect2(icon_position, Vector2(icon_size, icon_size)),
			false
		)
		cursor_x += icon_size + icon_gap
	
	var wins_text := "Wins %s" % wins
	skin.ink(self, font, Vector2(cursor_x, baseline),
		wins_text, FS, wins_color)
	cursor_x += font.get_string_size(
		wins_text, HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x + group_gap

	# Day: sun icon, then orange label and value.
	if skin.icon_sun != null:
		var icon_position := Vector2(cursor_x, y + (ROW - icon_size) * 0.5)
		draw_texture_rect(
			skin.icon_sun,
			Rect2(icon_position, Vector2(icon_size, icon_size)),
			false
		)
		cursor_x += icon_size + icon_gap
	
	var day_text := "Day %s" % day
	skin.ink(self, font, Vector2(cursor_x, baseline),
		day_text, FS, day_color)

	# Right: your team's live DPS.
	var elapsed_time: float = maxf(float(live.get("time", 0.0)), 0.001)
	var dps_text := "-"
	if _started():
		dps_text = skin.num(float(live.get("damage", 0.0)) / elapsed_time)

	var dps_width: float = font.get_string_size(
		dps_text, HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x


## YOUR team: two columns (front row slots 0-2, back row slots 3-5), each "name  DPS  HPS  SPS".
func _team_table(x: float, y: float, cw: float) -> void:
	# Colors: experiment here.
	var normal_color: Color = skin.INK
	var knocked_out_color: Color = skin.DIM
	var heading_color: Color = skin.DIM
	var active_dps_color: Color = skin.BLUE
	var carry_color := Color("#a36800")  # Used for highlighting highest DPS unit
	var divider_color := Color(skin.INK, 0.2)

	# Layout and battle state.
	var font: Font = skin.font_text
	var column_width := (cw - COL_GAP) * 0.5
	var number_width := 35.0  # Reduced from 40.0 to fit 3 columns
	var name_width := column_width - number_width * 3 - 8  # Changed from * 2 - 6 to fit 3 columns
	var battle_started: bool = _started()
	var battle_finished: bool = battle_started and bool(live.get("over", false))
	var elapsed_time: float = maxf(float(live.get("time", 0.0)), 0.001)
	var units: Dictionary = live.get("my_units", {})
	var team: Array = info.get("my_team", [])

	# Shared elapsed time means damage and DPS have the same ranking.
	var highest_damage := 0.0
	for unit_slot in units:
		var unit_damage := float(units[unit_slot].get("damage", 0.0))
		highest_damage = maxf(highest_damage, unit_damage)

	# Column headings.
	for column in range(2):
		var column_x := x + column * (column_width + COL_GAP)
		var heading_y := _base(y)
		var dps_x := column_x + column_width - number_width * 3 - 6
		var hps_x := column_x + column_width - number_width * 2 - 4
		var sps_x := column_x + column_width - number_width - 2
		var side := "front" if column == 0 else "back"

		skin.ink(self, font, Vector2(column_x, heading_y),
			"Your team - %s" % side, FS, heading_color)
		
		# DPS column with sword icon - icon positioned right next to text
		var icon_size := 8.0
		var icon_gap := 2.0
		var dps_text_width := font.get_string_size("DPS", HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x
		var dps_text_x := column_x + column_width - number_width * 3 - 6 + number_width - dps_text_width
		skin.ink(self, font, Vector2(dps_text_x, heading_y),
			"DPS", FS, skin.GREEN, -1, HORIZONTAL_ALIGNMENT_LEFT)
		if skin.icon_sword != null:
			var icon_x := dps_text_x - icon_size - icon_gap
			var icon_y := y + (ROW - icon_size) * 0.5
			draw_texture_rect(skin.icon_sword, Rect2(icon_x, icon_y, icon_size, icon_size), false)
		
		# HPS column with heal icon - icon positioned right next to text
		var hps_text_width := font.get_string_size("HPS", HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x
		var hps_text_x := column_x + column_width - number_width * 2 - 4 + number_width - hps_text_width
		skin.ink(self, font, Vector2(hps_text_x, heading_y),
			"HPS", FS, skin.YELLOW, -1, HORIZONTAL_ALIGNMENT_LEFT)
		if skin.icon_heal != null:
			var icon_x := hps_text_x - icon_size - icon_gap
			var icon_y := y + (ROW - icon_size) * 0.5
			draw_texture_rect(skin.icon_heal, Rect2(icon_x, icon_y, icon_size, icon_size), false)
		
		# SPS column with shield icon - icon positioned right next to text
		var sps_text_width := font.get_string_size("SPS", HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x
		var sps_text_x := column_x + column_width - number_width - 2 + number_width - sps_text_width
		skin.ink(self, font, Vector2(sps_text_x, heading_y),
			"SPS", FS, skin.BLUE, -1, HORIZONTAL_ALIGNMENT_LEFT)
		if skin.icon_shield != null:
			var icon_x := sps_text_x - icon_size - icon_gap
			var icon_y := y + (ROW - icon_size) * 0.5
			draw_texture_rect(skin.icon_shield, Rect2(icon_x, icon_y, icon_size, icon_size), false)

	# Divider between front and back columns.
	var divider_x := x + column_width + COL_GAP * 0.5
	var divider_bottom := y + ROW * (TABLE_ROWS + 1)
	draw_line(
		Vector2(divider_x, y),
		Vector2(divider_x, divider_bottom),
		divider_color,
		1.0
	)

	# Unit rows.
	for unit in team:
		var slot := int(unit.slot)
		var column := 0 if slot < TABLE_ROWS else 1
		var row_index := slot % TABLE_ROWS
		var column_x := x + column * (column_width + COL_GAP)
		var row_top := y + ROW * (row_index + 1)
		var text_y := _base(row_top)

		var name_position := Vector2(column_x, text_y)
		var dps_position := Vector2(
			column_x + column_width - number_width * 3 - 6, text_y)
		var hps_position := Vector2(
			column_x + column_width - number_width * 2 - 4, text_y)
		var sps_position := Vector2(
			column_x + column_width - number_width - 2, text_y)

		var stats: Dictionary = units.get(slot, {})
		var knocked_out: bool = battle_started and bool(stats.get("dead", false))
		var damage := float(stats.get("damage", 0.0))
		var heal := float(stats.get("heal", 0.0))
		var shield := float(stats.get("shield", 0.0))
		var is_highest_dps: bool = (
			battle_started
			and damage > 0.0
			and is_equal_approx(damage, highest_damage)
		)

		var row_color: Color = normal_color
		if knocked_out:
			row_color = knocked_out_color


		var shiny_suffix := "*" if unit.get("shiny", false) else ""
		var ko_suffix := "  KO" if knocked_out else ""
		var unit_name := "%s Lv%d%s%s" % [
			unit.name, int(unit.level), shiny_suffix, ko_suffix,
		]
		var fitted_name: String = skin.fit(font, unit_name, FS, name_width)

		var dps_text := "-"
		var hps_text := "-"
		var sps_text := "-"
		if battle_started:
			dps_text = skin.num(damage / elapsed_time)
			hps_text = skin.num(heal / elapsed_time)
			sps_text = skin.num(shield / elapsed_time)

		# Determine DPS color (highlight highest DPS unit)
		var final_dps_color: Color = skin.GREEN
		if is_highest_dps:
			final_dps_color = carry_color

		skin.ink(self, font, name_position, fitted_name, FS, row_color)
		skin.ink(self, font, dps_position, dps_text,
			FS, final_dps_color, number_width, HORIZONTAL_ALIGNMENT_RIGHT)
		skin.ink(self, font, hps_position, hps_text,
			FS, skin.YELLOW, number_width, HORIZONTAL_ALIGNMENT_RIGHT)
		skin.ink(self, font, sps_position, sps_text,
			FS, skin.BLUE, number_width, HORIZONTAL_ALIGNMENT_RIGHT)

