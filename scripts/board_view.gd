extends Control
## 整備畫面上的斜角 2.5D 陣形棋盤（等距投影）。只用來擺陣，戰鬥都在大地圖上打。
##
## 格子畫成菱形、整塊棋盤有厚度側面；棋子直立「站」在格子上並投下橢圓陰影，
## 依前後順序繪製所以會正確遮擋，越後排畫得越小。

const DB = preload("res://scripts/db.gd")
const Art = preload("res://scripts/art.gd")

signal cell_clicked(cell: Vector2i)

const W := 8
const H := 8
const TW := 64.0                # 菱形格寬
const TH := 40.0                # 菱形格高
const ORIGIN := Vector2(264, 70)
const SLAB := 16.0              # 棋盤厚度
const LIFT := 24.0              # 棋子浮在格子上的高度
const ICON_R := 18.0

var static_units: Array = []    # {cell, id, name, school, star, team, hp, max_hp}
var selected_cell := Vector2i(-1, -1)
var font: Font


func _ready() -> void:
	custom_minimum_size = Vector2(534, 430)
	size = custom_minimum_size
	font = ThemeDB.fallback_font


# ── 等距投影 ────────────────────────────────────────────────

## 格線交點 (gx, gy) → 畫面座標
static func proj(gx: float, gy: float) -> Vector2:
	return ORIGIN + Vector2((gx - gy) * TW * 0.5, (gx + gy) * TH * 0.5)


static func cell_center(pos: Vector2) -> Vector2:
	return proj(pos.x + 0.5, pos.y + 0.5)


## 畫面座標 → 格子（proj 的反函數）
static func cell_from_point(p: Vector2) -> Vector2i:
	var local := p - ORIGIN
	var a := local.x / (TW * 0.5)      # = gx - gy
	var b := local.y / (TH * 0.5)      # = gx + gy
	return Vector2i(floori((a + b) * 0.5), floori((b - a) * 0.5))


static func _diamond(x: float, y: float) -> PackedVector2Array:
	return PackedVector2Array([proj(x, y), proj(x + 1, y), proj(x + 1, y + 1), proj(x, y + 1)])


static func _closed(d: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array(d)
	out.append(d[0])
	return out


## 後排畫小一點，做出一點距離感
static func _depth_scale(pos: Vector2) -> float:
	return 0.86 + 0.14 * clampf((pos.x + pos.y) / float(W + H - 2), 0.0, 1.0)


# ── 輸入 ────────────────────────────────────────────────────

func _gui_input(ev: InputEvent) -> void:
	if not (ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT):
		return
	# 棋子是立起來的，先判斷有沒有點到棋子本體，點不到才退回地板格子
	var hit := _unit_at(ev.position)
	var c: Vector2i = hit if hit.x >= 0 else cell_from_point(ev.position)
	if c.x >= 0 and c.x < W and c.y >= 0 and c.y < H:
		cell_clicked.emit(c)


func _unit_at(p: Vector2) -> Vector2i:
	for it in static_units:
		var pos := Vector2(it.cell)
		if p.distance_to(cell_center(pos) - Vector2(0, LIFT)) <= ICON_R * _depth_scale(pos) + 3.0:
			return it.cell
	return Vector2i(-1, -1)


# ── 繪製 ────────────────────────────────────────────────────

func _draw() -> void:
	_draw_board()
	var items: Array = static_units.duplicate()
	items.sort_custom(func(a, b): return a.cell.x + a.cell.y < b.cell.x + b.cell.y)
	for it in items:
		_draw_unit(it)


func _draw_board() -> void:
	var down := Vector2(0, SLAB)
	var side := PackedVector2Array([proj(W, 0), proj(W, H), proj(0, H),
			proj(0, H) + down, proj(W, H) + down, proj(W, 0) + down])
	draw_colored_polygon(side, Color(0.11, 0.09, 0.08))
	for y in H:
		for x in W:
			var col := Color(0.30, 0.25, 0.22) if y < 4 else Color(0.22, 0.33, 0.28)
			if (x + y) % 2 == 1:
				col = col.lightened(0.07)
			draw_colored_polygon(_diamond(x, y), col)
			draw_polyline(_closed(_diamond(x, y)), Color(0, 0, 0, 0.16), 1.0)
	draw_line(proj(0, 4), proj(W, 4), Color(0.95, 0.9, 0.72, 0.55), 2.0)
	if selected_cell.x >= 0:
		draw_colored_polygon(_diamond(selected_cell.x, selected_cell.y), Color(1, 0.9, 0.2, 0.28))
		draw_polyline(_closed(_diamond(selected_cell.x, selected_cell.y)), Color(1, 0.9, 0.25), 2.5)


func _draw_unit(it: Dictionary) -> void:
	var pos := Vector2(it.cell)
	var s := _depth_scale(pos)
	var ground := cell_center(pos)
	var center := ground - Vector2(0, LIFT)
	var is_enemy: bool = int(it.team) == 1
	var r := ICON_R * s
	var pts := PackedVector2Array()
	for i in 16:
		var a: float = TAU * i / 16.0
		pts.append(ground + Vector2(cos(a) * r * 0.78, sin(a) * r * 0.38))
	draw_colored_polygon(pts, Color(0, 0, 0, 0.32))
	draw_line(ground, center + Vector2(0, r * 0.7), Color(0, 0, 0, 0.3), 2.0)
	Art.draw_token_base(self, center, r, DB.school_color(it.school), is_enemy, float(it.cell.x + it.cell.y))
	if is_enemy:
		Art.draw_enemy(self, str(it.id), center, r * 0.95)
	else:
		Art.draw_item(self, str(it.id), center, r * 0.95)
	Art.draw_token_ring(self, center, r, is_enemy)
	var star := int(it.get("star", 1))
	if star > 1:
		_outlined(center + Vector2(-32, -r - 9), "★".repeat(star), 12, Color(1, 0.85, 0.2))
	_outlined(center + Vector2(-32, r + 14), str(it.name), 11, Color(0.97, 0.97, 1.0))


func _outlined(p: Vector2, text: String, size_px: int, col: Color) -> void:
	draw_string_outline(font, p, text, HORIZONTAL_ALIGNMENT_CENTER, 64, size_px, 4, Color(0, 0, 0, col.a))
	draw_string(font, p, text, HORIZONTAL_ALIGNMENT_CENTER, 64, size_px, col)
