extends RefCounted
## 全遊戲共用的 UI 樣式：按鈕、面板。
## 色調走「書桌上的紙與鉛筆」：深藍灰底、米白字、鉛筆黃當強調色。

const BG := Color(0.085, 0.095, 0.12)
const PANEL := Color(0.14, 0.155, 0.19)
const PANEL_EDGE := Color(0.30, 0.33, 0.40)
const TEXT := Color(0.93, 0.93, 0.96)
const ACCENT := Color(1.0, 0.86, 0.35)


static func _box(bg: Color, edge: Color, radius := 6, width := 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = edge
	s.set_border_width_all(width)
	s.set_corner_radius_all(radius)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	return s


static func make() -> Theme:
	var t := Theme.new()
	t.set_stylebox("normal", "Button", _box(Color(0.21, 0.23, 0.29), PANEL_EDGE))
	t.set_stylebox("hover", "Button", _box(Color(0.30, 0.34, 0.42), Color(0.72, 0.78, 0.92)))
	t.set_stylebox("pressed", "Button", _box(Color(0.16, 0.17, 0.22), ACCENT))
	t.set_stylebox("disabled", "Button", _box(Color(0.135, 0.145, 0.175), Color(0.26, 0.27, 0.32)))
	t.set_stylebox("focus", "Button", _box(Color(0, 0, 0, 0), Color(0.9, 0.85, 0.45)))
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", ACCENT)
	t.set_color("font_disabled_color", "Button", Color(0.46, 0.47, 0.52))
	t.set_stylebox("panel", "Panel", _box(PANEL, PANEL_EDGE, 8))
	t.set_color("font_color", "Label", TEXT)
	return t


## 半透明面板，用來把一堆文字框起來，不要讓字直接浮在背景上
static func add_panel(parent: Control, pos: Vector2, size: Vector2, title := "") -> Panel:
	var p := Panel.new()
	p.position = pos
	p.size = size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(p)
	if title != "":
		var l := Label.new()
		l.text = title
		l.position = pos + Vector2(10, -2)
		l.add_theme_font_size_override("font_size", 13)
		l.add_theme_color_override("font_color", Color(0.62, 0.66, 0.76))
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parent.add_child(l)
	return p
