extends Control
## 斜角 2.5D 的 8×8 棋盤（等距投影）。
##
## 格子畫成菱形、整塊棋盤有厚度側面；棋子直立「站」在格子上並投下橢圓陰影，
## 依前後順序繪製所以會正確遮擋，越後排畫得越小。
## 所有動畫都是從 sim 已經算好的 frames / events 推導出來的表演，
## 不會回頭影響戰鬥結果，同一個種子的戰鬥永遠長得一樣。

const DB = preload("res://scripts/db.gd")
const Art = preload("res://scripts/art.gd")

signal cell_clicked(cell: Vector2i)

const W := 8
const H := 8
const TW := 64.0                # 菱形格寬
const TH := 40.0                # 菱形格高（拉高一點，棋子才不會擠在一起）
const ORIGIN := Vector2(264, 70)
const SLAB := 16.0              # 棋盤厚度
const LIFT := 24.0              # 棋子浮在格子上的高度
const ICON_R := 18.0
const FLASH_TICKS := 2
const SHAKE_TICKS := 3
const LUNGE_TICKS := 3
const FADE_TICKS := 8
const PROJ_TICKS := 2.5

var static_units: Array = []
var sim = null
var tick_f := 0.0
var selected_cell := Vector2i(-1, -1)
var font: Font
var anim_t := 0.0

var _sim_cache = null
var _death_tick: Dictionary = {}
var _acts: Dictionary = {}
var _hits: Dictionary = {}


func _ready() -> void:
	custom_minimum_size = Vector2(534, 430)
	size = custom_minimum_size
	font = ThemeDB.fallback_font
	set_process(true)


func _process(delta: float) -> void:
	anim_t += delta
	if sim != null:
		queue_redraw()


# ── 等距投影 ────────────────────────────────────────────────

## 格線交點 (gx, gy) → 畫面座標。gx / gy 可以是小數，移動才會沿著斜向滑過去。
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


func _ellipse(center: Vector2, rx: float, ry: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 18:
		var a: float = TAU * i / 18.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, col)


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
	for it in _gather():
		var pos: Vector2 = it.pos if it.has("pos") else Vector2(it.cell)
		var center := cell_center(pos) - Vector2(0, LIFT)
		if p.distance_to(center) <= ICON_R * _depth_scale(pos) + 3.0:
			return Vector2i(roundi(pos.x), roundi(pos.y))
	return Vector2i(-1, -1)


## 後排畫小一點，做出一點距離感
static func _depth_scale(pos: Vector2) -> float:
	return 0.86 + 0.14 * clampf((pos.x + pos.y) / float(W + H - 2), 0.0, 1.0)


# ── 繪製 ────────────────────────────────────────────────────

func _rebuild_cache() -> void:
	_sim_cache = sim
	_death_tick.clear()
	_acts.clear()
	_hits.clear()
	if sim == null:
		return
	for e in sim.events:
		match e.type:
			"death":
				if not _death_tick.has(e.dst):
					_death_tick[e.dst] = int(e.t)
			"hit", "skill":
				if not _acts.has(e.src):
					_acts[e.src] = []
				_acts[e.src].append({"t": int(e.t), "dst": int(e.dst)})
				if not _hits.has(e.dst):
					_hits[e.dst] = []
				_hits[e.dst].append(int(e.t))
			"burn":
				if not _hits.has(e.dst):
					_hits[e.dst] = []
				_hits[e.dst].append(int(e.t))


func _draw() -> void:
	if sim != _sim_cache:
		_rebuild_cache()
	_draw_board()
	var items := _gather()
	# 由遠到近排序，近的才會蓋住遠的
	items.sort_custom(func(a, b):
		var pa: Vector2 = a.pos if a.has("pos") else Vector2(a.cell)
		var pb: Vector2 = b.pos if b.has("pos") else Vector2(b.cell)
		return pa.x + pa.y < pb.x + pb.y)
	for it in items:
		_draw_shadow(it)
	if sim != null:
		_draw_beams(items)
	for it in items:
		_draw_unit(it)
	if sim != null:
		_draw_projectiles(items)
		_draw_numbers(items)


func _draw_board() -> void:
	# 棋盤側面：整塊往下偏移當厚度
	var down := Vector2(0, SLAB)
	var outline: Array = [proj(0, 0), proj(W, 0), proj(W, H), proj(0, H)]
	var side := PackedVector2Array([
		outline[1], outline[2], outline[3],
		outline[3] + down, outline[2] + down, outline[1] + down])
	draw_colored_polygon(side, Color(0.11, 0.09, 0.08))
	# 地板
	for y in H:
		for x in W:
			var col := Color(0.30, 0.25, 0.22) if y < 4 else Color(0.22, 0.33, 0.28)
			if (x + y) % 2 == 1:
				col = col.lightened(0.07)
			draw_colored_polygon(_diamond(x, y), col)
			draw_polyline(_closed(_diamond(x, y)), Color(0, 0, 0, 0.16), 1.0)
	# 敵我分界
	draw_line(proj(0, 4), proj(W, 4), Color(0.95, 0.9, 0.72, 0.55), 2.0)
	if selected_cell.x >= 0:
		draw_colored_polygon(_diamond(selected_cell.x, selected_cell.y), Color(1, 0.9, 0.2, 0.28))
		draw_polyline(_closed(_diamond(selected_cell.x, selected_cell.y)), Color(1, 0.9, 0.25), 2.5)


static func _closed(d: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array(d)
	out.append(d[0])
	return out


func _gather() -> Array:
	if sim == null:
		return static_units
	var out: Array = []
	var i0 := clampi(floori(tick_f), 0, sim.frames.size() - 1)
	var i1 := mini(i0 + 1, sim.frames.size() - 1)
	var f := tick_f - i0
	for k in sim.units.size():
		var u: Dictionary = sim.units[k]
		var a: Array = sim.frames[i0][k]
		var b: Array = sim.frames[i1][k]
		var alpha := 1.0
		if _death_tick.has(k):
			var since: float = tick_f - float(_death_tick[k])
			if since >= 0.0:
				alpha = clampf(1.0 - since / FADE_TICKS, 0.0, 1.0)
				if alpha <= 0.0:
					continue
		out.append({
			"uid": k, "id": u.id, "pos": Vector2(a[0], a[1]).lerp(Vector2(b[0], b[1]), f),
			"name": u.name, "school": u.school, "star": u.star, "team": u.team,
			"hp": a[2], "max_hp": u.max_hp, "shield": a[3], "alive": a[4],
			"energy": a[5], "stun": a[6], "alpha": alpha, "range": u.range,
		})
	return out


func _anim_offset(it: Dictionary) -> Vector2:
	var uid := int(it.get("uid", 0))
	var off := Vector2.ZERO
	off.y += sin(anim_t * 2.4 + uid * 0.9) * 1.6
	if sim == null:
		return off
	var here := cell_center(it.pos if it.has("pos") else Vector2(it.cell))
	for a in _acts.get(uid, []):
		var age: float = tick_f - float(a.t)
		if age < 0.0 or age > LUNGE_TICKS:
			continue
		var dst = _dst_pos(int(a.dst))
		if dst == null:
			continue
		var dir: Vector2 = (Vector2(dst) - here).normalized()
		var reach: float = 9.0 if int(it.get("range", 1)) <= 1 else 4.0
		off += dir * reach * sin((1.0 - age / LUNGE_TICKS) * PI)
	for t in _hits.get(uid, []):
		var age2: float = tick_f - float(t)
		if age2 < 0.0 or age2 > SHAKE_TICKS:
			continue
		off += Vector2(sin(age2 * 9.0), cos(age2 * 7.0)) * 3.5 * (1.0 - age2 / SHAKE_TICKS)
	return off


func _dst_pos(uid: int):
	if sim == null or uid < 0 or uid >= sim.units.size():
		return null
	var i0 := clampi(floori(tick_f), 0, sim.frames.size() - 1)
	var fr: Array = sim.frames[i0][uid]
	return cell_center(Vector2(fr[0], fr[1]))


func _draw_shadow(it: Dictionary) -> void:
	var pos: Vector2 = it.pos if it.has("pos") else Vector2(it.cell)
	var s := _depth_scale(pos)
	var alpha := float(it.get("alpha", 1.0))
	_ellipse(cell_center(pos), ICON_R * 0.78 * s, ICON_R * 0.38 * s,
			Color(0, 0, 0, 0.32 * alpha))


func _draw_unit(it: Dictionary) -> void:
	var pos: Vector2 = it.pos if it.has("pos") else Vector2(it.cell)
	var alpha := float(it.get("alpha", 1.0))
	var s := _depth_scale(pos)
	var center := cell_center(pos) - Vector2(0, LIFT) + _anim_offset(it)
	var is_enemy: bool = int(it.team) == 1
	var r := ICON_R * s * (0.75 + 0.25 * alpha)

	# 從格子連到棋子的細桿，讓它看起來是「立」在格子上
	draw_line(cell_center(pos), center + Vector2(0, r * 0.7), Color(0, 0, 0, 0.3 * alpha), 2.0)
	Art.draw_token_base(self, center, r, DB.school_color(it.school), is_enemy, float(it.get("uid", 0)))
	if is_enemy:
		Art.draw_enemy(self, str(it.get("id", "")), center, r * 0.95)
	else:
		Art.draw_item(self, str(it.get("id", "")), center, r * 0.95)
	Art.draw_token_ring(self, center, r, is_enemy)

	var flash := _flash_amount(it)
	if flash > 0.0:
		draw_circle(center, r + 2, Color(1, 1, 1, flash * 0.5))
	if alpha < 1.0:
		draw_circle(center, r + 3, Color(0.23, 0.26, 0.24, 1.0 - alpha))
		return
	if it.get("stun", false):
		_draw_stun(center, r)
	var star := int(it.get("star", 1))
	if star > 1:
		_outlined(center + Vector2(-32, -r - 9), "★".repeat(star), 12, Color(1, 0.85, 0.2))
	_draw_bars(it, center, r)
	# 戰鬥中棋子會擠在一起，名字全印出來反而看不清楚；只在準備階段標名字
	if sim == null:
		_outlined(center + Vector2(-32, r + 14), str(it.name), 11, Color(0.97, 0.97, 1.0))


func _draw_stun(center: Vector2, r: float) -> void:
	for i in 3:
		var a: float = anim_t * 3.0 + TAU * i / 3.0
		_outlined(center + Vector2(cos(a) * r * 0.9 - 32, -r - 6 + sin(a) * 3.0), "★", 11,
				Color(1, 0.95, 0.35))


func _outlined(p: Vector2, text: String, size_px: int, col: Color) -> void:
	draw_string_outline(font, p, text, HORIZONTAL_ALIGNMENT_CENTER, 64, size_px, 4,
			Color(0, 0, 0, col.a))
	draw_string(font, p, text, HORIZONTAL_ALIGNMENT_CENTER, 64, size_px, col)


func _draw_bars(it: Dictionary, center: Vector2, r: float) -> void:
	var bar_w := 40.0
	var bx := center.x - bar_w / 2.0
	var by := center.y - r - 7
	var max_hp := maxf(1.0, float(it.max_hp))
	var ratio := clampf(float(it.hp) / max_hp, 0.0, 1.0)
	draw_rect(Rect2(bx - 1, by - 1, bar_w + 2, 7), Color(0, 0, 0, 0.8))
	var hp_col := Color(0.35, 0.85, 0.45) if int(it.team) == 0 else Color(0.9, 0.35, 0.35)
	if ratio < 0.3:
		hp_col = hp_col.lerp(Color(1, 0.75, 0.2), 0.6)
	draw_rect(Rect2(bx, by, bar_w * ratio, 5), hp_col)
	var shield := float(it.get("shield", 0))
	if shield > 0.0:
		draw_rect(Rect2(bx, by - 4.5, bar_w * clampf(shield / max_hp, 0.0, 1.0), 3),
				Color(0.95, 0.9, 0.5))
	if it.has("energy"):
		var e := clampf(float(it.energy) / 100.0, 0.0, 1.0)
		draw_rect(Rect2(bx, center.y + r + 3, bar_w, 3), Color(0, 0, 0, 0.8))
		draw_rect(Rect2(bx, center.y + r + 3, bar_w * e, 3),
				Color(1, 0.9, 0.35) if e >= 1.0 else Color(0.4, 0.65, 1.0))


func _flash_amount(it: Dictionary) -> float:
	if sim == null:
		return 0.0
	var now := floori(tick_f)
	for t in _hits.get(int(it.uid), []):
		var age: int = now - int(t)
		if age >= 0 and age <= FLASH_TICKS:
			return 1.0 - float(age) / float(FLASH_TICKS + 1)
	return 0.0


func _draw_beams(items: Array) -> void:
	var pos_of: Dictionary = {}
	for it in items:
		if it.alive:
			pos_of[it.uid] = cell_center(it.pos) - Vector2(0, LIFT) + _anim_offset(it)
	var now := floori(tick_f)
	for e in sim.events:
		if e.t < now - 1 or e.t > now:
			continue
		if not pos_of.has(e.src) or not pos_of.has(e.dst):
			continue
		var a: Vector2 = pos_of[e.src]
		var b: Vector2 = pos_of[e.dst]
		match e.type:
			"skill":
				draw_line(a, b, Color(1, 0.85, 0.25, 0.75), 3.0)
			"cast":
				var k: float = clampf((tick_f - float(e.t)) / 4.0, 0.0, 1.0)
				# 光圈貼著地板擴散，所以畫成橢圓而不是正圓
				_ellipse(cell_center(_grid_of(int(e.src))),
						(ICON_R + 6) * (1.0 + k * 1.4), (ICON_R + 6) * 0.5 * (1.0 + k * 1.4),
						Color(1, 0.9, 0.35, (1.0 - k) * 0.35))
			"heal":
				var k2: float = clampf((tick_f - float(e.t)) / 4.0, 0.0, 1.0)
				_ellipse(cell_center(_grid_of(int(e.dst))),
						(ICON_R + 4) * (1.0 + k2 * 1.0), (ICON_R + 4) * 0.5 * (1.0 + k2 * 1.0),
						Color(0.4, 1.0, 0.55, (1.0 - k2) * 0.35))


func _grid_of(uid: int) -> Vector2:
	if sim == null or uid < 0 or uid >= sim.units.size():
		return Vector2.ZERO
	var i0 := clampi(floori(tick_f), 0, sim.frames.size() - 1)
	var fr: Array = sim.frames[i0][uid]
	return Vector2(fr[0], fr[1])


func _draw_projectiles(items: Array) -> void:
	var pos_of: Dictionary = {}
	var reach: Dictionary = {}
	for it in items:
		pos_of[it.uid] = cell_center(it.pos) - Vector2(0, LIFT) + _anim_offset(it)
		reach[it.uid] = int(it.get("range", 1))
	for e in sim.events:
		if e.type != "hit":
			continue
		var age: float = tick_f - float(e.t)
		if age < 0.0 or age > PROJ_TICKS:
			continue
		if not pos_of.has(e.src) or not pos_of.has(e.dst) or int(reach.get(e.src, 1)) <= 1:
			continue
		var k: float = age / PROJ_TICKS
		var p: Vector2 = Vector2(pos_of[e.src]).lerp(pos_of[e.dst], k)
		p.y -= sin(k * PI) * 10.0        # 拋物線，看起來像飛過去的
		draw_circle(p, 4.5 * (1.0 - k * 0.4), Color(1, 0.96, 0.75, 1.0 - k * 0.3))
		draw_circle(p, 8.0 * (1.0 - k * 0.4), Color(1, 0.9, 0.5, 0.25))


func _draw_numbers(items: Array) -> void:
	var pos_of: Dictionary = {}
	for it in items:
		pos_of[it.uid] = cell_center(it.pos) - Vector2(0, LIFT)
	var now := floori(tick_f)
	for e in sim.events:
		var age: int = now - int(e.t)
		if age < 0 or age > 7 or not pos_of.has(e.dst):
			continue
		var fade := 1.0 - float(age) / 8.0
		var p: Vector2 = pos_of[e.dst] + Vector2(-32, -ICON_R - 14 - age * 2.5)
		match e.type:
			"skill":
				_outlined(p, "%d" % int(e.v), 15, Color(1, 0.85, 0.3, fade))
			"heal":
				_outlined(p, "+%d" % int(e.v), 13, Color(0.45, 1.0, 0.55, fade))
			"cast":
				if pos_of.has(e.src):
					_outlined(pos_of[e.src] + Vector2(-32, -ICON_R - 26 - age * 2.0),
							str(e.name), 12, Color(1, 0.92, 0.4, fade))
