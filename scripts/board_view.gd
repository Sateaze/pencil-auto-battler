extends Control
## 整備畫面上的斜角 2.5D 陣形棋盤（等距投影）。只用來擺陣，戰鬥都在大地圖上打。
##
## 格子畫成菱形、整塊棋盤有厚度側面；棋子就是物品本身站在格子上，腳下的圈表示隊伍，
## 依前後順序繪製所以會正確遮擋，越後排畫得越小。

const DB = preload("res://scripts/db.gd")
const Art = preload("res://scripts/art.gd")
const GameState = preload("res://scripts/game_state.gd")

signal cell_clicked(cell: Vector2i)

const W := 8
const H := 8
const TW := 64.0                # 菱形格寬
const TH := 40.0                # 菱形格高
const ORIGIN := Vector2(264, 70)
const SLAB := 16.0              # 棋盤厚度
const LIFT := 16.0              # 棋子身體中心離地多高（點棋子用）
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
		var r := ICON_R * _depth_scale(pos)
		if p.distance_to(cell_center(pos) - Vector2(0, LIFT * _depth_scale(pos))) <= r + 3.0:
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
	# 陣形最前排的中間就是你站的格子；上方（y 小）是面對敵人的前方
	var me := GameState.FORMATION_FRONT
	draw_polyline(_closed(_diamond(me.x, me.y)), Color(1, 0.85, 0.3, 0.9), 2.0)
	_outlined(cell_center(Vector2(me)) + Vector2(-32, TH * 0.5 + 12), "你站這", 11, Color(1, 0.88, 0.4))
	_outlined(proj(W * 0.5, 4) + Vector2(-80, -10), "↑ 前方（面對敵人）", 12, Color(1, 0.9, 0.6), 160)
	if selected_cell.x >= 0:
		draw_colored_polygon(_diamond(selected_cell.x, selected_cell.y), Color(1, 0.9, 0.2, 0.28))
		draw_polyline(_closed(_diamond(selected_cell.x, selected_cell.y)), Color(1, 0.9, 0.25), 2.5)


func _draw_unit(it: Dictionary) -> void:
	var pos := Vector2(it.cell)
	var ground := cell_center(pos)
	var is_enemy: bool = int(it.team) == 1
	var r := ICON_R * _depth_scale(pos)
	Art.draw_team_ring(self, ground, r, is_enemy)
	Art.draw_figure(self, str(it.id), ground, r, is_enemy)
	var star := int(it.get("star", 1))
	if star > 1:
		_outlined(ground + Vector2(-32, -r * 2.0 - 6), "★".repeat(star), 12, Color(1, 0.85, 0.2))
	_outlined(ground + Vector2(-32, r * 0.5 + 12), str(it.name), 11, Color(0.97, 0.97, 1.0))


func _outlined(p: Vector2, text: String, size_px: int, col: Color, width: float = 64.0) -> void:
	draw_string_outline(font, p, text, HORIZONTAL_ALIGNMENT_CENTER, width, size_px, 4, Color(0, 0, 0, col.a))
	draw_string(font, p, text, HORIZONTAL_ALIGNMENT_CENTER, width, size_px, col)
