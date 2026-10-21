extends RefCounted
## 每件物品「怎麼被拿來用」：身體動作（揮、丟、砸、甩、射）＋ 打出去的東西（筆畫、風、光、噴霧…）。
## 純表演，不影響戰鬥結果。
##
## 時間軸（單位 tick）：
##   pose 的 s 以「出手點」為 0 —— 近戰的出手點就是命中；遠程的出手點 = 命中 − 飛行時間 T。
##   draw_effect 的 s 以「命中」為 0 —— 東西在 −T 飛出去、0 打到。
##   所以打到人的那一刻，剛好就是傷害數字跳出來、對方閃白的那一刻。s < 0 是蓄力，s > 0 是收招。

const WIND := 2.5           # 蓄力多久
const FOLLOW := 3.0         # 收招多久

## 物品 id → [身體動作, 打出去的東西]
##   swing  以腳底為軸往前揮（球棒、掃把、拖把、球拍）
##   throw  整件丟出去砸人再彈回來（籃球）
##   slam   跳起來壓到敵人身上（重的東西）
##   whip   原地甩，打出去的是繩子／電線本身（跳繩、延長線）
##   recoil 原地發射，身體往後一頓（文具、家電、會噴東西的）
##   lunge  怪物撲咬（敵人一律用這個）
const MOVES := {
	"pencil": ["recoil", "stroke"], "ruler": ["recoil", "extend"], "glue": ["recoil", "blob"],
	"sticky_note": ["recoil", "note"], "compass": ["recoil", "circle"], "tape": ["recoil", "tape"],
	"calculator": ["recoil", "digits"],
	"lamp": ["recoil", "beam"], "sofa": ["slam", ""], "fan": ["recoil", "wind"],
	"dryer": ["recoil", "hotair"], "aircon": ["recoil", "cold"], "fridge": ["slam", "frost"],
	"extension": ["whip", "zap"],
	"potato": ["slam", ""], "onion": ["slam", "stink"], "toast": ["slam", ""],
	"chili": ["recoil", "fire"], "shavedice": ["recoil", "ice"], "leftovers": ["slam", "stink"],
	"bat": ["swing", ""], "rope": ["whip", "rope"], "racket": ["swing", "shuttle"],
	"dumbbell": ["slam", ""], "basketball": ["throw", ""],
	"broom": ["swing", "dust"], "sponge": ["slam", "bubbles"], "mop": ["swing", "splash"],
	"bleach": ["recoil", "spray"],
}

const PENCIL_COLS := [Color(0.93, 0.3, 0.3), Color(0.3, 0.55, 0.95), Color(0.35, 0.75, 0.35),
		Color(0.95, 0.65, 0.2), Color(0.7, 0.4, 0.85)]
const INK := Color(0.12, 0.11, 0.14)


static func move_of(id: String, is_enemy: bool) -> Array:
	if is_enemy:
		return ["lunge", ""]
	return MOVES.get(id, ["recoil", "bullet"])


## 打出去的東西要飛多久（tick）。0 = 沒有飛行物，出手那一刻就打到。
static func travel(effect: String, dist_cells: float) -> float:
	match effect:
		"", "dust", "splash", "bubbles", "frost", "stink", "rope", "zap":
			return 0.0
		"beam":
			return 1.0
		"extend", "tape":
			return 1.5
		"circle":
			return 2.5
	return clampf(dist_cells * 0.8, 1.5, 3.5)


## 關鍵影格之間平滑內插：keys = [[s, 值], ...]，s 由小到大
static func _keys(s: float, keys: Array) -> float:
	if s <= keys[0][0]:
		return keys[0][1]
	for i in range(1, keys.size()):
		if s <= keys[i][0]:
			var a: Array = keys[i - 1]
			var b: Array = keys[i]
			var f: float = (s - a[0]) / (b[0] - a[0])
			return lerpf(a[1], b[1], f * f * (3.0 - 2.0 * f))
	return keys[-1][1]


## 身體在這一刻的姿勢。to = 從自己指向目標的畫面向量。
## rot 以「面向右邊」為準，呼叫端依面向再乘上 ±1。
static func pose(style: String, s: float, to: Vector2, big: bool) -> Dictionary:
	var dir := to.normalized()
	var amp := 1.3 if big else 1.0
	var p := {"off": Vector2.ZERO, "rot": 0.0, "spin": 0.0, "sx": 1.0, "sy": 1.0}
	match style:
		"swing":
			# 先往後拉，命中那一刻用力往前劈下去
			p.rot = _keys(s, [[-WIND, 0.0], [-0.8, -0.8], [0.0, 1.25], [1.0, 1.0], [FOLLOW, 0.0]]) * amp
			p.off = dir * _keys(s, [[-WIND, 0.0], [-0.8, -3.0], [0.0, 8.0], [FOLLOW, 0.0]])
		"slam":
			# 蹲低 → 跳起來 → 整個壓在敵人身上（落地壓扁）→ 跳回原位
			var reach := minf(to.length() * 0.5, 26.0)
			p.off = dir * reach * _keys(s, [[-WIND, 0.0], [0.0, 1.0], [FOLLOW, 0.0]]) \
					+ Vector2(0, -_keys(s, [[-WIND, 0.0], [-1.6, 0.0], [-0.9, 18.0 * amp], [0.0, 0.0]]))
			p.rot = _keys(s, [[-WIND, 0.0], [-1.0, -0.25], [0.0, 0.3], [FOLLOW, 0.0]])
			var sq := _keys(s, [[-WIND, 0.0], [-1.6, -0.18], [-1.0, 0.12], [0.0, 0.0], [0.3, -0.3], [1.5, 0.0]])
			p.sy = 1.0 + sq
			p.sx = 1.0 - sq * 0.6
		"throw":
			# 整顆丟出去：拋物線飛到敵人身上，再彈回來，一路滾著轉
			var out := _keys(s, [[-WIND, 0.0], [0.0, 1.0], [FOLLOW, 0.0]])
			var lift := 0.0
			if s < 0.0:
				lift = sin(PI * clampf((s + WIND) / WIND, 0.0, 1.0)) * 22.0 * amp
			else:
				lift = sin(PI * clampf(s / FOLLOW, 0.0, 1.0)) * 12.0
			p.off = to * 0.85 * out + Vector2(0, -lift)
			p.spin = clampf((s + WIND) / (WIND + FOLLOW), 0.0, 1.0) * TAU * 2.0
		"whip":
			p.rot = _keys(s, [[-WIND, 0.0], [-1.0, -0.3], [0.0, 0.35], [FOLLOW, 0.0]])
			p.off = dir * _keys(s, [[-WIND, 0.0], [0.0, 3.0], [FOLLOW, 0.0]])
		"recoil":
			p.off = dir * _keys(s, [[-WIND, 0.0], [-0.5, -2.0], [0.2, 4.0 * amp], [2.0, 0.0]])
			p.rot = _keys(s, [[-WIND, 0.0], [-0.5, -0.15], [0.2, 0.18], [2.0, 0.0]])
		"buff":
			# 補血、上盾：原地開心地跳一下
			p.off = Vector2(0, -sin(clampf((s + WIND) / (WIND + FOLLOW), 0.0, 1.0) * PI) * 10.0)
		_:
			p.off = dir * _keys(s, [[-WIND, 0.0], [-0.6, -3.0], [0.0, 10.0], [2.5, 0.0]])
	return p


## 一次出手打出去的東西。a、b 是攻擊者與目標的身體中心；T 是飛行時間；sd 讓同一下長得固定。
static func draw_effect(c: CanvasItem, font: Font, style: String, effect: String, a: Vector2, b: Vector2,
		s: float, T: float, big: bool, sd: int) -> void:
	var w := 1.5 if big else 1.0
	var d := b - a
	var dl := maxf(d.length(), 1.0)
	var dir := d / dl
	var n := Vector2(-dir.y, dir.x)
	var k := clampf((s + T) / maxf(T, 0.01), 0.0, 1.0)      # 飛行進度：s = 0 時抵達
	var fade := clampf(1.0 - s / FOLLOW, 0.0, 1.0) if s > 0.0 else 1.0
	var flying := s >= -T and s <= 0.0
	var arc_pt := func(f: float, h: float) -> Vector2: return a.lerp(b, f) - Vector2(0, sin(f * PI) * h)

	match effect:
		"stroke":       # 色鉛筆：一條手繪的彩色線一路畫到敵人身上
			if s < -T:
				return
			var col: Color = PENCIL_COLS[sd % PENCIL_COLS.size()]
			var end := a.lerp(b, k)
			var pts := PackedVector2Array()
			for i in 10:
				var f := i / 9.0
				pts.append(a.lerp(end, f) + n * sin(f * 8.0 + sd) * 3.0)
			c.draw_polyline(pts, Color(col, fade), 3.0 * w)
			c.draw_circle(pts[-1], 2.5 * w, Color(col.darkened(0.3), fade))
		"extend":       # 尺：整把伸長戳過去再縮回來
			if s < -T:
				return
			var reach := k if s <= 0.0 else clampf(1.0 - s / 1.5, 0.0, 1.0)
			if reach <= 0.0:
				return
			var tip := a.lerp(b, reach)
			c.draw_line(a, tip, INK, 9.0 * w)
			c.draw_line(a, tip, Color(0.98, 0.88, 0.5), 6.5 * w)
			var marks := int(dl * reach / 6.0)
			for i in marks:
				var p := a + dir * (i * 6.0 + 3.0)
				c.draw_line(p, p + n * (2.5 if i % 2 == 0 else 1.5) * w, INK, 1.0)
		"blob":         # 膠水：一坨白膠拋過去，啪地黏在地上
			if flying:
				var p: Vector2 = arc_pt.call(k, 18.0)
				c.draw_circle(p, 4.5 * w, INK)
				c.draw_circle(p, 3.5 * w, Color(0.97, 0.97, 0.92))
			elif s > 0.0:
				_blob(c, b + Vector2(0, 8), 9.0 * w, 4.0 * w, Color(0.97, 0.97, 0.9, 0.85 * fade))
		"note":         # 便利貼：一張轉著飛過去
			if flying:
				var p: Vector2 = arc_pt.call(k, 14.0)
				_square(c, p, 5.0 * w, k * TAU * 1.5, Color(1.0, 0.9, 0.35))
			elif s > 0.0 and s < 2.0:
				_square(c, b + Vector2(4, -2), 5.0 * w, 0.3, Color(1.0, 0.9, 0.35, fade))
		"circle":       # 圓規：針腳插在敵人身上，筆腳繞著畫一圈
			if s < -T:
				return
			var ang := k * TAU
			var rr := 13.0 * w
			var alpha := fade
			c.draw_line(a, b, Color(0.5, 0.5, 0.55, 0.6 * alpha), 1.5)
			c.draw_arc(b, rr, -PI * 0.5, -PI * 0.5 + ang, 24, Color(0.3, 0.3, 0.9, alpha), 2.5 * w)
			c.draw_circle(b + Vector2(cos(-PI * 0.5 + ang), sin(-PI * 0.5 + ang)) * rr, 2.5, Color(INK, alpha))
		"tape":         # 修正帶：一條白帶子拉過去蓋在敵人身上
			if s < -T:
				return
			var end := a.lerp(b, k)
			c.draw_line(a, end, Color(0.6, 0.6, 0.65, 0.8 * fade), 7.0 * w)
			c.draw_line(a, end, Color(1, 1, 1, 0.95 * fade), 5.0 * w)
		"digits":       # 計算機：一串數字飛過去
			if s < -T:
				return
			var glyphs := ["7", "+", "3", "=", "π"]
			for i in 3:
				var f := clampf(k - i * 0.18, 0.0, 1.0)
				if f <= 0.0 or (s > 0.0 and i > 0):
					continue
				var p: Vector2 = arc_pt.call(f, 12.0)
				_label(c, font, p, glyphs[(sd + i) % glyphs.size()], int(12 * w),
						Color(0.55, 1.0, 0.6, fade))
		"beam":         # 檯燈：一道光錐照過去
			if s < -T or s > 1.5:
				return
			var glow := k * (1.0 - clampf(s / 1.5, 0.0, 1.0)) if s > 0.0 else k
			var half := 9.0 * w
			c.draw_colored_polygon(PackedVector2Array([a, b + n * half, b - n * half]),
					Color(1.0, 0.95, 0.55, 0.45 * glow))
			c.draw_circle(b, half * 0.8, Color(1.0, 0.97, 0.7, 0.5 * glow))
		"wind", "hotair", "cold":       # 電風扇／吹風機／冷氣：一道道弧形氣流往前推
			if s < -T or s > 1.0:
				return
			var col := Color(0.92, 0.97, 1.0)
			if effect == "hotair":
				col = Color(1.0, 0.6, 0.3)
			elif effect == "cold":
				col = Color(0.55, 0.85, 1.0)
			for i in 3:
				var f := clampf(k - i * 0.15, 0.0, 1.0)
				if f <= 0.05:
					continue
				var p := a.lerp(b, f)
				var ang := dir.angle()
				c.draw_arc(p, (5.0 + f * 6.0) * w, ang - 0.9, ang + 0.9, 10, Color(col, 0.9 * fade), 2.0 * w)
			if effect == "cold" and s >= 0.0:
				_snowflake(c, b, 7.0 * w, Color(0.75, 0.95, 1.0, fade))
		"fire":         # 辣椒：噴出一團火
			if s < -T or s > 1.5:
				return
			for i in 4:
				var f := clampf(k - i * 0.12, 0.0, 1.0)
				if f <= 0.0:
					continue
				var p := a.lerp(b, f) + n * sin(f * 10.0 + i) * 3.0
				var rr := (2.0 + f * 5.0) * w * (fade if s > 0.0 else 1.0)
				c.draw_circle(p, rr, Color(1.0, 0.45, 0.15, 0.8))
				c.draw_circle(p, rr * 0.55, Color(1.0, 0.85, 0.3, 0.9))
		"ice":          # 挫冰：丟一把冰塊過去
			if not flying:
				return
			for i in 3:
				var f := clampf(k - i * 0.1, 0.0, 1.0)
				var p: Vector2 = arc_pt.call(f, 16.0) + n * (i - 1) * 4.0
				_square(c, p, 3.0 * w, f * 6.0 + i, Color(0.8, 0.95, 1.0))
		"spray":        # 漂白水：噴出一道水柱
			if s < -T or s > 0.6:
				return
			for i in 6:
				var f := clampf(k - i * 0.08, 0.0, 1.0)
				if f <= 0.0:
					continue
				var p := a.lerp(b, f) + n * sin(i * 2.3 + sd) * 2.5
				c.draw_circle(p, 2.2 * w, Color(0.75, 0.9, 1.0, 0.85))
		"shuttle":      # 羽球拍：揮拍，羽毛球飛過去
			if not flying:
				return
			var p: Vector2 = arc_pt.call(k, 20.0)
			var back := -dir * 7.0
			c.draw_colored_polygon(PackedVector2Array([p, p + back + n * 4.0, p + back - n * 4.0]),
					Color(1, 1, 1, 0.95))
			c.draw_circle(p, 2.5, Color(0.9, 0.3, 0.3))
		"rope", "zap":  # 跳繩／延長線：繩子本身甩出去抽在敵人身上
			if s < -WIND or s > FOLLOW:
				return
			var start_ang := -TAU if big else -2.4
			var ang := _keys(s, [[-WIND, start_ang], [0.0, 0.0], [FOLLOW, 0.0]])
			var reach := _keys(s, [[-WIND, 0.35], [0.0, 1.0], [1.2, 0.75], [FOLLOW, 0.2]])
			var tip := a + dir.rotated(ang) * dl * reach
			var sag := sin(s * 2.5 + 1.0) * 0.25 * dl * reach
			var mid := (a + tip) * 0.5 + (tip - a).orthogonal().normalized() * sag
			var pts := PackedVector2Array()
			for i in 13:
				var f := i / 12.0
				pts.append(a.lerp(mid, f).lerp(mid.lerp(tip, f), f))
			var col := Color(0.95, 0.45, 0.6) if effect == "rope" else Color(0.25, 0.25, 0.28)
			c.draw_polyline(pts, INK, 4.5 * w)
			c.draw_polyline(pts, col, 2.5 * w)
			c.draw_rect(Rect2(tip - Vector2(2.5, 2.5) * w, Vector2(5, 5) * w), col.darkened(0.3))
			if effect == "zap" and s >= 0.0 and s < 2.0:
				_zigzag(c, b, 10.0 * w, sd + int(s * 4.0), Color(1.0, 0.95, 0.3, fade))
		"bullet":
			if not flying:
				return
			var p: Vector2 = arc_pt.call(k, 10.0)
			c.draw_circle(p, 8.0 * (1.0 - k * 0.4), Color(1, 0.9, 0.5, 0.25))
			c.draw_circle(p, 4.5 * (1.0 - k * 0.4), Color(1, 0.96, 0.75, 1.0 - k * 0.3))

	# 打到那一刻的效果：近戰的「碰」、會留下東西的近戰（灰塵、水花、泡泡、冷氣、臭味）
	if s < 0.0 or s > 3.0:
		return
	match effect:
		"dust":
			for i in 4:
				var p := b + Vector2(cos(i * 1.7 + sd) * 9.0, 6.0 - s * 2.0 + sin(i * 2.1) * 3.0)
				c.draw_circle(p, (3.0 + s * 1.5) * w, Color(0.7, 0.66, 0.6, 0.6 * fade))
		"splash":
			for i in 5:
				var ang := -PI * 0.5 + (i - 2) * 0.45
				var p := b + Vector2(cos(ang), sin(ang)) * (6.0 + s * 6.0) + Vector2(0, s * s * 1.5)
				c.draw_circle(p, 2.2 * w, Color(0.55, 0.8, 1.0, fade))
		"bubbles":
			for i in 4:
				var p := b + Vector2((i - 1.5) * 6.0, -s * 5.0 - i * 2.0)
				c.draw_arc(p, (2.5 + i * 0.6) * w, 0, TAU, 10, Color(0.85, 0.95, 1.0, fade), 1.2)
		"frost":
			_snowflake(c, b, (8.0 + s * 2.0) * w, Color(0.75, 0.95, 1.0, fade))
		"stink":
			for i in 3:
				var x := (i - 1) * 7.0
				var pts := PackedVector2Array()
				for j in 6:
					pts.append(b + Vector2(x + sin(j * 1.3 + s * 3.0 + i) * 2.5, -4.0 - j * 3.0 - s * 3.0))
				c.draw_polyline(pts, Color(0.55, 0.7, 0.3, 0.8 * fade), 1.8)
	if style in ["swing", "slam", "throw", "lunge", "whip"] and s <= 1.5:
		_pow(c, b - dir * 6.0, (6.0 + s * 6.0) * w, sd, Color(1.0, 0.95, 0.7, 1.0 - s / 1.5))


# ── 小圖形 ──────────────────────────────────────────────────

## 命中時的爆炸線（漫畫的「碰！」）
static func _pow(c: CanvasItem, p: Vector2, r: float, sd: int, col: Color) -> void:
	for i in 7:
		var ang := TAU * i / 7.0 + sd * 0.37
		var dd := Vector2(cos(ang), sin(ang))
		c.draw_line(p + dd * r * 0.45, p + dd * r, INK if col.a > 0.5 else Color(INK, col.a), 3.0)
		c.draw_line(p + dd * r * 0.45, p + dd * r, col, 1.6)


static func _square(c: CanvasItem, p: Vector2, h: float, ang: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 4:
		pts.append(p + Vector2(h, 0).rotated(ang + i * PI * 0.5))
	c.draw_colored_polygon(pts, col)
	pts.append(pts[0])
	c.draw_polyline(pts, Color(INK, col.a), 1.0)


static func _blob(c: CanvasItem, p: Vector2, rx: float, ry: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 14:
		var ang := TAU * i / 14.0
		var wob := 1.0 + 0.18 * sin(i * 2.7)
		pts.append(p + Vector2(cos(ang) * rx, sin(ang) * ry) * wob)
	c.draw_colored_polygon(pts, col)


static func _snowflake(c: CanvasItem, p: Vector2, r: float, col: Color) -> void:
	for i in 3:
		var dd := Vector2(cos(i * PI / 3.0), sin(i * PI / 3.0)) * r
		c.draw_line(p - dd, p + dd, col, 1.8)


static func _zigzag(c: CanvasItem, p: Vector2, r: float, sd: int, col: Color) -> void:
	for j in 2:
		var pts := PackedVector2Array()
		var ang := sd * 1.3 + j * PI
		for i in 5:
			var f := i / 4.0
			pts.append(p + Vector2(cos(ang), sin(ang)) * r * f
					+ Vector2(-sin(ang), cos(ang)) * (3.0 if i % 2 == 0 else -3.0))
		c.draw_polyline(pts, col, 2.0)


static func _label(c: CanvasItem, font: Font, p: Vector2, s: String, size_px: int, col: Color) -> void:
	c.draw_string_outline(font, p - Vector2(10, -4), s, HORIZONTAL_ALIGNMENT_CENTER, 20, size_px, 3,
			Color(0, 0, 0, col.a))
	c.draw_string(font, p - Vector2(10, -4), s, HORIZONTAL_ALIGNMENT_CENTER, 20, size_px, col)
