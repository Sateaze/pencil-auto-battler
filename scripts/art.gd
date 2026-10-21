extends RefCounted
## 程式畫出來的向量美術：每件物品、每隻怪、玩家鉛筆各有自己的圖示。
## 全部用 Godot 的 draw_* 基本圖形組出來，不依賴任何外部素材檔。
##
## 圖示都畫在以 center 為中心、半徑 r 的方形裡（座標範圍 −1 ~ 1），
## 所以同一份圖可以用在棋盤（大）與地圖（小）兩種尺寸。
## 物品與怪物的形狀一律經過 _poly/_rect/_circ/_line/_arc 畫，才能統一描外框、白閃、淡出。

const DB = preload("res://scripts/db.gd")

const INK := Color(0.12, 0.11, 0.14)          # 鉛筆線條色
const PAPER := Color(0.96, 0.94, 0.88)        # 紙張底色


# ── 基本圖形 ────────────────────────────────────────────────

## 畫外框／白閃時把所有顏色換成同一色（a = 0 表示照原色畫），_alpha 是整體透明度（陣亡淡出用）
static var _ov := Color(0, 0, 0, 0)
static var _alpha := 1.0
## 畫面本身的變換（地圖縮放）。draw_figure 會疊在它上面，畫完再還原成它。
static var base_xf := Transform2D.IDENTITY


## 讓接下來畫的物品／怪物／地圖圖示整體變淡（記得但看不到的東西），畫完記得設回 1
static func set_fade(a: float) -> void:
	_alpha = a


static func _c(col: Color) -> Color:
	if _ov.a > 0.0:
		return Color(_ov.r, _ov.g, _ov.b, _ov.a * _alpha)
	return Color(col.r, col.g, col.b, col.a * _alpha)


static func _p(center: Vector2, r: float, x: float, y: float) -> Vector2:
	return center + Vector2(x, y) * r


static func _poly(c: CanvasItem, center: Vector2, r: float, pts: Array, col: Color) -> void:
	var out := PackedVector2Array()
	for i in range(0, pts.size(), 2):
		out.append(_p(center, r, pts[i], pts[i + 1]))
	c.draw_colored_polygon(out, _c(col))


static func _rect(c: CanvasItem, center: Vector2, r: float,
		x: float, y: float, w: float, h: float, col: Color) -> void:
	c.draw_rect(Rect2(_p(center, r, x, y), Vector2(w, h) * r), _c(col))


static func _circ(c: CanvasItem, center: Vector2, r: float,
		x: float, y: float, rad: float, col: Color) -> void:
	c.draw_circle(_p(center, r, x, y), rad * r, _c(col))


static func _line(c: CanvasItem, center: Vector2, r: float,
		x1: float, y1: float, x2: float, y2: float, col: Color, w := 0.08) -> void:
	c.draw_line(_p(center, r, x1, y1), _p(center, r, x2, y2), _c(col), w * r)


static func _arc(c: CanvasItem, center: Vector2, r: float, x: float, y: float, rad: float,
		a0: float, a1: float, col: Color, w: float) -> void:
	c.draw_arc(_p(center, r, x, y), rad * r, a0, a1, 20, _c(col), w * r)


# ── 站在地上的棋子 ──────────────────────────────────────────

## 棋子就是物品本身「立」在地上：沒有圓形底座，只描一圈鉛筆外框。
## foot 是腳底（地面）在畫面上的位置；pose 可以帶：
##   rot   以腳底為軸的旋轉（揮擊、倒下）     flip  -1 = 左右翻面（面向左邊的敵人）
##   sx/sy 壓扁拉長（落地、蓄力）             spin  以身體中心自轉（丟出去的球）
##   alpha 整體透明度                          flash 0～1 受擊白閃
static func draw_figure(c: CanvasItem, id: String, foot: Vector2, r: float, is_enemy: bool,
		pose: Dictionary = {}) -> void:
	var flip := float(pose.get("flip", 1.0))
	var sc := Vector2(flip * float(pose.get("sx", 1.0)), float(pose.get("sy", 1.0)))
	c.draw_set_transform_matrix(base_xf * Transform2D(float(pose.get("rot", 0.0)), sc, 0.0, foot)
			* Transform2D(float(pose.get("spin", 0.0)), Vector2(0, -r * 0.9)))
	var body := Vector2.ZERO
	_alpha = float(pose.get("alpha", 1.0))
	var w := maxf(1.2, r * 0.09)
	_ov = INK
	for o in [Vector2(-w, 0), Vector2(w, 0), Vector2(0, -w), Vector2(0, w)]:
		_shape(c, id, body + o, r, is_enemy)
	_ov = Color(0, 0, 0, 0)
	_shape(c, id, body, r, is_enemy)
	var fl := float(pose.get("flash", 0.0))
	if fl > 0.0:
		_ov = Color(1, 1, 1, fl * 0.7)
		_shape(c, id, body, r, is_enemy)
		_ov = Color(0, 0, 0, 0)
	_alpha = 1.0
	c.draw_set_transform_matrix(base_xf)


static func _shape(c: CanvasItem, id: String, center: Vector2, r: float, is_enemy: bool) -> void:
	if is_enemy:
		draw_enemy(c, id, center, r)
	else:
		draw_item(c, id, center, r)


## 腳下的隊伍圈（我方藍、敵方紅），取代以前整顆棋子的彩色外框
static func draw_team_ring(c: CanvasItem, foot: Vector2, r: float, is_enemy: bool, alpha := 1.0) -> void:
	var col := Color(0.98, 0.42, 0.36) if is_enemy else Color(0.42, 0.78, 1.0)
	var pts := PackedVector2Array()
	for i in 21:
		var a: float = TAU * i / 20.0
		pts.append(foot + Vector2(cos(a) * r * 0.85, sin(a) * r * 0.4))
	c.draw_colored_polygon(pts.slice(0, 20), Color(0, 0, 0, 0.3 * alpha))
	c.draw_polyline(pts, Color(col, 0.9 * alpha), maxf(1.5, r * 0.11))


# ── 物品圖示 ────────────────────────────────────────────────

static func draw_item(c: CanvasItem, id: String, center: Vector2, r: float) -> void:
	var tint := DB.school_color(DB.units[id].school) if DB.units.has(id) else Color.GRAY
	var dark := tint.darkened(0.35)
	var light := tint.lightened(0.45)
	match id:
		# ── 文具 ──
		"pencil":
			_poly(c, center, r, [-0.7, 0.5, -0.5, -0.6, -0.25, -0.6, -0.05, 0.5], light)
			_poly(c, center, r, [-0.7, 0.5, -0.05, 0.5, -0.38, 0.85], Color(0.95, 0.85, 0.6))
			_poly(c, center, r, [-0.55, 0.62, -0.2, 0.62, -0.38, 0.85], INK)
			_poly(c, center, r, [0.15, 0.5, 0.35, -0.6, 0.6, -0.6, 0.8, 0.5], dark)
			_poly(c, center, r, [0.15, 0.5, 0.8, 0.5, 0.48, 0.85], Color(0.95, 0.85, 0.6))
		"ruler":
			_rect(c, center, r, -0.85, -0.22, 1.7, 0.44, light)
			for i in 5:
				var x: float = -0.65 + i * 0.32
				_line(c, center, r, x, -0.22, x, 0.0, dark, 0.05)
			_line(c, center, r, -0.85, 0.22, 0.85, 0.22, dark, 0.06)
		"glue":
			_rect(c, center, r, -0.32, -0.15, 0.64, 0.85, light)
			_rect(c, center, r, -0.18, -0.55, 0.36, 0.4, dark)
			_poly(c, center, r, [-0.18, -0.55, 0.18, -0.55, 0.0, -0.9], Color(0.95, 0.9, 0.5))
			_rect(c, center, r, -0.24, 0.15, 0.48, 0.3, PAPER)
		"sticky_note":
			_poly(c, center, r, [-0.65, -0.65, 0.65, -0.65, 0.65, 0.35, 0.35, 0.65, -0.65, 0.65], light)
			_poly(c, center, r, [0.65, 0.35, 0.35, 0.65, 0.35, 0.35], dark)
			for i in 3:
				_line(c, center, r, -0.45, -0.35 + i * 0.28, 0.4, -0.35 + i * 0.28, dark, 0.05)
		"compass":
			_line(c, center, r, 0.0, -0.75, -0.45, 0.75, dark, 0.12)
			_line(c, center, r, 0.0, -0.75, 0.45, 0.75, dark, 0.12)
			_circ(c, center, r, 0.0, -0.75, 0.16, light)
			_arc(c, center, r, 0.0, 0.3, 0.62, PI * 0.15, PI * 0.85, light, 0.07)
		"tape":
			_rect(c, center, r, -0.8, -0.35, 1.6, 0.7, light)
			_circ(c, center, r, -0.38, 0.0, 0.26, PAPER)
			_circ(c, center, r, 0.38, 0.0, 0.26, PAPER)
			_circ(c, center, r, -0.38, 0.0, 0.1, dark)
			_circ(c, center, r, 0.38, 0.0, 0.1, dark)
		"calculator":
			_rect(c, center, r, -0.6, -0.85, 1.2, 1.7, dark)
			_rect(c, center, r, -0.45, -0.7, 0.9, 0.45, Color(0.7, 0.95, 0.75))
			for row in 3:
				for col in 3:
					_rect(c, center, r, -0.45 + col * 0.33, -0.1 + row * 0.28, 0.22, 0.18, light)

		# ── 家具家電 ──
		"lamp":
			_poly(c, center, r, [-0.6, -0.1, 0.6, -0.1, 0.3, -0.8, -0.3, -0.8], light)
			_circ(c, center, r, 0.0, 0.05, 0.2, Color(1.0, 0.95, 0.6))
			_line(c, center, r, 0.0, 0.1, 0.0, 0.7, dark, 0.1)
			_rect(c, center, r, -0.45, 0.7, 0.9, 0.18, dark)
		"sofa":
			_rect(c, center, r, -0.8, -0.35, 1.6, 0.55, dark)
			_rect(c, center, r, -0.62, -0.15, 1.24, 0.45, light)
			_rect(c, center, r, -0.9, -0.2, 0.26, 0.75, dark)
			_rect(c, center, r, 0.64, -0.2, 0.26, 0.75, dark)
			_rect(c, center, r, -0.6, 0.55, 0.15, 0.25, INK)
			_rect(c, center, r, 0.45, 0.55, 0.15, 0.25, INK)
		"fan":
			_circ(c, center, r, 0.0, -0.1, 0.68, light.darkened(0.1))
			for i in 3:
				var a: float = TAU * i / 3.0
				_poly(c, center, r, [0.0, -0.1,
						cos(a) * 0.6, -0.1 + sin(a) * 0.6,
						cos(a + 0.9) * 0.6, -0.1 + sin(a + 0.9) * 0.6], dark)
			_circ(c, center, r, 0.0, -0.1, 0.16, PAPER)
			_line(c, center, r, 0.0, 0.58, 0.0, 0.82, dark, 0.12)
		"dryer":
			_poly(c, center, r, [-0.8, -0.4, 0.3, -0.5, 0.3, 0.2, -0.8, 0.1], light)
			_poly(c, center, r, [0.3, -0.4, 0.75, -0.25, 0.75, 0.0, 0.3, 0.1], dark)
			_poly(c, center, r, [-0.6, 0.1, -0.25, 0.1, -0.35, 0.85, -0.6, 0.85], dark)
		"aircon":
			_rect(c, center, r, -0.85, -0.5, 1.7, 0.8, light)
			for i in 3:
				_line(c, center, r, -0.7, -0.1 + i * 0.14, 0.7, -0.1 + i * 0.14, dark, 0.06)
			_circ(c, center, r, 0.6, -0.35, 0.08, Color(0.5, 0.9, 1.0))
			for i in 3:
				_arc(c, center, r, -0.3 + i * 0.3, 0.62, 0.14, PI * 0.1, PI * 0.9, Color(0.6, 0.9, 1.0, 0.8), 0.05)
		"fridge":
			_rect(c, center, r, -0.5, -0.85, 1.0, 1.7, light)
			_line(c, center, r, -0.5, -0.25, 0.5, -0.25, dark, 0.07)
			_rect(c, center, r, 0.22, -0.68, 0.1, 0.32, dark)
			_rect(c, center, r, 0.22, -0.1, 0.1, 0.5, dark)
		"extension":
			_rect(c, center, r, -0.75, -0.3, 1.5, 0.6, light)
			for i in 2:
				_circ(c, center, r, -0.3 + i * 0.6, -0.08, 0.07, INK)
				_circ(c, center, r, -0.3 + i * 0.6, 0.12, 0.07, INK)
			_arc(c, center, r, -0.75, 0.55, 0.35, -PI * 0.5, PI * 0.5, dark, 0.08)

		# ── 食物 ──
		"potato":
			_poly(c, center, r, [-0.75, 0.05, -0.5, -0.5, 0.15, -0.65, 0.7, -0.25,
					0.72, 0.3, 0.25, 0.68, -0.4, 0.6], light)
			for p in [[-0.25, -0.15], [0.2, 0.05], [-0.05, 0.38], [0.42, -0.3]]:
				_circ(c, center, r, p[0], p[1], 0.08, dark)
		"onion":
			_poly(c, center, r, [-0.65, 0.0, -0.3, -0.55, 0.3, -0.55, 0.65, 0.0,
					0.35, 0.7, -0.35, 0.7], light)
			for i in 3:
				_arc(c, center, r, 0.0, 0.1, 0.2 + i * 0.18, PI * 1.05, PI * 1.95, dark, 0.05)
			_line(c, center, r, 0.0, -0.55, -0.2, -0.95, Color(0.5, 0.75, 0.4), 0.07)
			_line(c, center, r, 0.0, -0.55, 0.22, -0.9, Color(0.5, 0.75, 0.4), 0.07)
		"toast":
			_poly(c, center, r, [-0.65, 0.7, -0.65, -0.25, -0.5, -0.6, -0.15, -0.72,
					0.15, -0.72, 0.5, -0.6, 0.65, -0.25, 0.65, 0.7], Color(0.85, 0.66, 0.38))
			_poly(c, center, r, [-0.45, 0.52, -0.45, -0.2, -0.2, -0.5, 0.2, -0.5,
					0.45, -0.2, 0.45, 0.52], Color(0.97, 0.88, 0.66))
		"chili":
			_poly(c, center, r, [-0.1, -0.5, 0.35, -0.2, 0.42, 0.35, 0.05, 0.75,
					-0.2, 0.55, 0.05, 0.2, 0.05, -0.2], Color(0.86, 0.22, 0.18))
			_line(c, center, r, -0.1, -0.5, -0.35, -0.82, Color(0.42, 0.68, 0.33), 0.1)
		"shavedice":
			_poly(c, center, r, [-0.55, -0.1, 0.55, -0.1, 0.3, 0.8, -0.3, 0.8], PAPER)
			_arc(c, center, r, 0.0, -0.1, 0.55, PI, TAU, Color(0.75, 0.93, 1.0), 0.5)
			_circ(c, center, r, -0.2, -0.35, 0.12, Color(0.9, 0.4, 0.5))
			_circ(c, center, r, 0.22, -0.3, 0.1, Color(0.5, 0.8, 0.5))
		"leftovers":
			_poly(c, center, r, [-0.7, -0.05, 0.7, -0.05, 0.48, 0.65, -0.48, 0.65], light)
			_arc(c, center, r, 0.0, -0.05, 0.68, PI, TAU, Color(0.55, 0.5, 0.3), 0.3)
			_circ(c, center, r, -0.22, -0.3, 0.13, Color(0.6, 0.7, 0.35))
			_circ(c, center, r, 0.18, -0.26, 0.1, Color(0.72, 0.5, 0.3))

		# ── 運動用品 ──
		"bat":
			_poly(c, center, r, [-0.72, 0.62, -0.5, 0.78, 0.6, -0.42, 0.78, -0.72,
					0.42, -0.6], Color(0.82, 0.6, 0.34))
			_rect(c, center, r, -0.78, 0.45, 0.3, 0.3, dark)
		"rope":
			_arc(c, center, r, 0.0, 0.05, 0.6, PI * 0.85, PI * 2.15, light, 0.09)
			_rect(c, center, r, -0.72, -0.72, 0.22, 0.5, dark)
			_rect(c, center, r, 0.5, -0.72, 0.22, 0.5, dark)
		"racket":
			_arc(c, center, r, 0.08, -0.28, 0.52, 0, TAU, light, 0.11)
			for i in 3:
				_line(c, center, r, -0.38 + i * 0.3, -0.72, -0.38 + i * 0.3, 0.14, PAPER, 0.035)
				_line(c, center, r, -0.44, -0.66 + i * 0.3, 0.6, -0.66 + i * 0.3, PAPER, 0.035)
			_line(c, center, r, 0.0, 0.2, -0.45, 0.82, dark, 0.13)
		"dumbbell":
			_rect(c, center, r, -0.5, -0.12, 1.0, 0.24, dark)
			_rect(c, center, r, -0.82, -0.45, 0.32, 0.9, light)
			_rect(c, center, r, 0.5, -0.45, 0.32, 0.9, light)
		"basketball":
			_circ(c, center, r, 0.0, 0.0, 0.78, Color(0.88, 0.47, 0.2))
			_line(c, center, r, -0.78, 0.0, 0.78, 0.0, INK, 0.06)
			_line(c, center, r, 0.0, -0.78, 0.0, 0.78, INK, 0.06)
			_arc(c, center, r, 0.0, 0.0, 0.78, 0, TAU, INK, 0.05)

		# ── 清潔用品 ──
		"broom":
			_line(c, center, r, 0.3, -0.8, -0.1, 0.25, Color(0.72, 0.55, 0.32), 0.12)
			_poly(c, center, r, [-0.35, 0.2, 0.15, 0.2, 0.4, 0.82, -0.6, 0.82], light)
			for i in 4:
				_line(c, center, r, -0.42 + i * 0.26, 0.35, -0.5 + i * 0.3, 0.82, dark, 0.04)
		"sponge":
			_poly(c, center, r, [-0.72, -0.45, 0.72, -0.5, 0.68, 0.5, -0.68, 0.52], light)
			for p in [[-0.35, -0.2], [0.12, -0.28], [0.42, 0.08], [-0.15, 0.22], [-0.52, 0.22]]:
				_circ(c, center, r, p[0], p[1], 0.11, dark)
		"mop":
			_line(c, center, r, 0.25, -0.85, 0.05, 0.05, Color(0.72, 0.55, 0.32), 0.11)
			_rect(c, center, r, -0.42, 0.0, 0.9, 0.18, dark)
			for i in 5:
				_line(c, center, r, -0.38 + i * 0.22, 0.18, -0.46 + i * 0.24, 0.85, light, 0.06)
		"bleach":
			_rect(c, center, r, -0.42, -0.3, 0.84, 1.1, light)
			_rect(c, center, r, -0.2, -0.72, 0.4, 0.42, dark)
			_rect(c, center, r, -0.3, 0.0, 0.6, 0.45, PAPER)
			_line(c, center, r, -0.18, 0.15, 0.18, 0.15, dark, 0.06)
			_line(c, center, r, -0.18, 0.32, 0.1, 0.32, dark, 0.06)
		_:
			_circ(c, center, r, 0.0, 0.0, 0.6, light)


# ── 怪物圖示 ────────────────────────────────────────────────

static func draw_enemy(c: CanvasItem, id: String, center: Vector2, r: float) -> void:
	var body := Color(0.55, 0.38, 0.62)
	match id:
		"dust":
			for p in [[-0.3, -0.1, 0.45], [0.28, -0.18, 0.4], [0.0, 0.25, 0.42]]:
				_circ(c, center, r, p[0], p[1], p[2], Color(0.62, 0.6, 0.66))
			_eyes(c, center, r, 0.0, -0.05, 0.22)
		"ant":
			_circ(c, center, r, -0.45, 0.0, 0.22, Color(0.45, 0.3, 0.22))
			_circ(c, center, r, 0.0, 0.0, 0.26, Color(0.5, 0.33, 0.24))
			_circ(c, center, r, 0.5, 0.05, 0.34, Color(0.42, 0.28, 0.2))
			for i in 3:
				_line(c, center, r, 0.0, 0.1, -0.3 + i * 0.3, 0.6, INK, 0.05)
			_line(c, center, r, -0.45, -0.1, -0.8, -0.5, INK, 0.05)
			_eyes(c, center, r, -0.45, -0.02, 0.12)
		"roach":
			_poly(c, center, r, [-0.6, 0.0, -0.2, -0.5, 0.4, -0.45, 0.7, 0.1,
					0.35, 0.55, -0.25, 0.5], Color(0.4, 0.26, 0.16))
			_line(c, center, r, -0.5, -0.2, -0.9, -0.65, INK, 0.05)
			_line(c, center, r, -0.5, -0.05, -0.95, -0.3, INK, 0.05)
			for i in 3:
				_line(c, center, r, -0.1 + i * 0.3, 0.45, -0.2 + i * 0.35, 0.85, INK, 0.05)
			_eyes(c, center, r, -0.3, -0.18, 0.14)
		"mold":
			for p in [[-0.35, 0.1, 0.42], [0.3, 0.0, 0.46], [0.0, -0.35, 0.38]]:
				_circ(c, center, r, p[0], p[1], p[2], Color(0.4, 0.58, 0.32))
			for p in [[-0.4, -0.1], [0.35, 0.22], [0.0, 0.3]]:
				_circ(c, center, r, p[0], p[1], 0.12, Color(0.25, 0.4, 0.2))
			_eyes(c, center, r, 0.0, -0.1, 0.2)
		"hairball":
			var pts: Array = []
			for i in 14:
				var a: float = TAU * i / 14.0
				var rad: float = 0.85 if i % 2 == 0 else 0.55
				pts.append(cos(a) * rad)
				pts.append(sin(a) * rad)
			_poly(c, center, r, pts, Color(0.46, 0.42, 0.4))
			_eyes(c, center, r, 0.0, -0.05, 0.24)
		"spore":
			_circ(c, center, r, 0.0, 0.0, 0.5, Color(0.6, 0.72, 0.4))
			for i in 6:
				var a: float = TAU * i / 6.0
				_line(c, center, r, cos(a) * 0.5, sin(a) * 0.5, cos(a) * 0.85, sin(a) * 0.85,
						Color(0.45, 0.58, 0.3), 0.06)
			_eyes(c, center, r, 0.0, 0.0, 0.16)
		"moldking":
			_circ(c, center, r, 0.0, 0.15, 0.78, Color(0.33, 0.48, 0.28))
			for p in [[-0.5, -0.2], [0.5, -0.2], [0.0, 0.6], [-0.45, 0.42], [0.45, 0.42]]:
				_circ(c, center, r, p[0], p[1], 0.26, Color(0.26, 0.38, 0.22))
			_poly(c, center, r, [-0.5, -0.5, -0.3, -0.95, -0.1, -0.55, 0.1, -0.95,
					0.3, -0.55, 0.5, -0.95, 0.5, -0.4, -0.5, -0.4], Color(0.9, 0.78, 0.3))
			_eyes(c, center, r, 0.0, 0.1, 0.3)
		_:
			_circ(c, center, r, 0.0, 0.0, 0.6, body)
			_eyes(c, center, r, 0.0, 0.0, 0.22)


static func _eyes(c: CanvasItem, center: Vector2, r: float, x: float, y: float, s: float) -> void:
	_circ(c, center, r, x - s, y, s * 0.62, PAPER)
	_circ(c, center, r, x + s, y, s * 0.62, PAPER)
	_circ(c, center, r, x - s, y + s * 0.08, s * 0.3, INK)
	_circ(c, center, r, x + s, y + s * 0.08, s * 0.3, INK)


# ── 玩家：魔法鉛筆 ──────────────────────────────────────────

## length 0~1：筆芯剩多少，會讓鉛筆變短（企劃書「一眼看出還剩多少資源」）
static func draw_pencil(c: CanvasItem, center: Vector2, r: float, length := 1.0) -> void:
	var top: float = -0.9 + (1.0 - clampf(length, 0.15, 1.0)) * 0.7
	_poly(c, center, r, [-0.3, top, 0.3, top, 0.3, 0.45, -0.3, 0.45], Color(0.96, 0.78, 0.25))
	_poly(c, center, r, [-0.3, top, -0.12, top, -0.12, 0.45, -0.3, 0.45], Color(1.0, 0.88, 0.5))
	_poly(c, center, r, [-0.3, 0.45, 0.3, 0.45, 0.0, 0.95], Color(0.95, 0.86, 0.66))
	_poly(c, center, r, [-0.12, 0.72, 0.12, 0.72, 0.0, 0.95], INK)
	_rect(c, center, r, -0.3, top - 0.22, 0.6, 0.22, Color(0.88, 0.45, 0.5))
	_rect(c, center, r, -0.32, top - 0.06, 0.64, 0.08, Color(0.75, 0.75, 0.8))


# ── 地圖格子上的小圖示 ──────────────────────────────────────

static func draw_cell_icon(c: CanvasItem, kind: String, center: Vector2, r: float) -> void:
	match kind:
		"shop":      # 抽屜
			_rect(c, center, r, -0.8, -0.55, 1.6, 1.1, Color(0.72, 0.54, 0.34))
			_line(c, center, r, -0.8, 0.0, 0.8, 0.0, Color(0.45, 0.32, 0.2), 0.08)
			_rect(c, center, r, -0.2, -0.38, 0.4, 0.12, Color(0.95, 0.9, 0.7))
			_rect(c, center, r, -0.2, 0.2, 0.4, 0.12, Color(0.95, 0.9, 0.7))
		"chest":     # 寶箱
			_rect(c, center, r, -0.75, -0.1, 1.5, 0.75, Color(0.72, 0.5, 0.28))
			c.draw_arc(_p(center, r, 0.0, -0.1), 0.75 * r, PI, TAU, 18, Color(0.85, 0.62, 0.34), 0.45 * r)
			_rect(c, center, r, -0.14, -0.3, 0.28, 0.45, Color(0.95, 0.82, 0.35))
		"rest":      # 休息點
			_rect(c, center, r, -0.8, 0.1, 1.6, 0.5, Color(0.55, 0.62, 0.78))
			_poly(c, center, r, [-0.7, 0.1, 0.1, 0.1, 0.1, -0.3, -0.7, -0.15], PAPER)
			c.draw_arc(_p(center, r, 0.45, -0.35), 0.25 * r, 0, TAU, 14, Color(0.9, 0.95, 1.0), 0.12 * r)
		"copier":    # 影印機
			_rect(c, center, r, -0.75, -0.45, 1.5, 0.95, Color(0.55, 0.58, 0.64))
			_rect(c, center, r, -0.6, -0.7, 1.2, 0.25, Color(0.72, 0.75, 0.8))
			_rect(c, center, r, -0.45, 0.2, 0.9, 0.42, PAPER)
			_circ(c, center, r, 0.5, -0.2, 0.1, Color(0.4, 0.85, 0.5))
		"lair":      # 魔王巢穴：地板上一個長滿黴菌的黑洞，裡面有發光的眼睛
			_circ(c, center, r, 0.0, 0.05, 0.95, Color(0.22, 0.35, 0.18))
			_circ(c, center, r, 0.0, 0.1, 0.7, Color(0.05, 0.06, 0.05))
			for p in [[-0.75, -0.3], [0.7, -0.35], [-0.5, 0.55], [0.6, 0.5], [0.0, -0.75]]:
				_circ(c, center, r, p[0], p[1], 0.22, Color(0.36, 0.55, 0.28))
			_circ(c, center, r, -0.22, 0.05, 0.13, Color(0.75, 1.0, 0.4))
			_circ(c, center, r, 0.22, 0.05, 0.13, Color(0.75, 1.0, 0.4))
			_circ(c, center, r, -0.22, 0.07, 0.06, INK)
			_circ(c, center, r, 0.22, 0.07, 0.06, INK)
