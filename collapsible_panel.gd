extends Control
## Shared behaviour of the BatoEyes panels (the battle card): header drag, a minimize toggle and a
## smooth height animation. Subclasses draw with draw_body() / full_height() / header_text().
##
##   * The toggle is a small "-" / "+" button in the header's right corner, drawn with the game's
##     section stylebox. A click on it, or a click on the header that did not drag, toggles.
##   * Minimized = only the header bar (it still carries the key fact: the opponent's name).
##   * Dragging the header moves the panel; the owner saves position and minimized state.
##   * The control's rect shrinks with the animation and clips its own drawing, so once minimized
##     nothing of the panel catches clicks outside the header.

signal minimized_changed(minimized: bool)
signal moved_by_drag

const HEAD_H := 15.0
const BTN := 11.0
const ANIM_SEC := 0.14
const DRAG_THRESHOLD := 3.0

var skin
var minimized := false
var moved := false
var reveal := 1.0                       # 1 = expanded, 0 = minimized (animated)

var _pressing := false
var _dragged := false
var _press_pos := Vector2.ZERO
var _drag_off := Vector2.ZERO
var _tween: Tween


func setup(p_skin) -> void:
	skin = p_skin
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	_apply_size()


## Height of the panel when fully expanded (subclasses).
func full_height() -> float:
	return HEAD_H + 20.0


func header_text() -> String:
	return ""


func header_style() -> StyleBox:
	return skin.header


## Header text inside `r` (between the left edge and the -/+ button); centred, trimmed to fit.
func draw_header_text(r: Rect2) -> void:
	var t: String = skin.fit(skin.font_header, header_text(), 12, r.size.x)
	skin.outlined(self, skin.font_header, Vector2(r.position.x, 11), t, 12, skin.WHITE, r.size.x, HORIZONTAL_ALIGNMENT_CENTER)


## Body drawing, below the header (subclasses).
func draw_body() -> void:
	pass


func _apply_size() -> void:
	var w := size.x if size.x > 0.0 else 150.0
	size = Vector2(w, lerpf(HEAD_H + 1.0, full_height(), reveal))


func set_minimized(on: bool, animate := true) -> void:
	if on == minimized and (_tween == null or not _tween.is_running()):
		return
	minimized = on
	if _tween != null:
		_tween.kill()
	var target := 0.0 if on else 1.0
	if not animate or not is_inside_tree():
		reveal = target
		_apply_size()
		queue_redraw()
	else:
		# real time: the game slows / stops Engine.time_scale (KO slow motion, pause button)
		_tween = create_tween().set_ignore_time_scale(true)
		_tween.tween_method(func(v: float):
			reveal = v
			_apply_size()
			queue_redraw(), reveal, target, ANIM_SEC).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	minimized_changed.emit(on)


func toggle() -> void:
	set_minimized(not minimized)


func button_rect() -> Rect2:
	return Rect2(Vector2(size.x - 8 - BTN - 2, 2), Vector2(BTN, BTN))


func _draw() -> void:
	if skin == null:
		return
	var ci := get_canvas_item()
	var w := size.x
	if reveal > 0.01:
		skin.panel.draw(ci, Rect2(Vector2(0, 4), Vector2(w, maxf(size.y - 4, 8))))
		draw_body()
	header_style().draw(ci, Rect2(Vector2(8, 0), Vector2(w - 16, HEAD_H)))
	var b := button_rect()
	draw_header_text(Rect2(Vector2(10, 0), Vector2(b.position.x - 14, HEAD_H)))
	skin.section.draw(ci, b)
	# pixel glyph: "-" expanded (click to minimize), "+" minimized (click to expand)
	var c := b.get_center().floor()
	draw_rect(Rect2(c.x - 3, c.y, 6, 1), skin.INK)
	if minimized:
		draw_rect(Rect2(c.x - 0.0, c.y - 3, 1, 7), skin.INK)


func _gui_input(event) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.position.y > HEAD_H + 1:
				return                       # body: not ours to handle
			_pressing = true
			_dragged = false
			_press_pos = event.position
			_drag_off = event.position
		elif _pressing:
			_pressing = false
			if _dragged:
				moved = true
				moved_by_drag.emit()
			else:
				toggle()
		accept_event()
	elif event is InputEventMouseMotion and _pressing:
		if not _dragged and event.position.distance_to(_press_pos) >= DRAG_THRESHOLD:
			_dragged = true
		if _dragged:
			position += event.position - _drag_off
		accept_event()
