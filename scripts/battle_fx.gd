extends RefCounted
## 戰鬥表演：待機浮動、撲擊、受擊閃白與震動、陣亡淡出、遠程彈道、施法與治療光圈、
## 傷害數字、暈眩星星。
##
## 全部從 sim 已經算好的 frames／events「推導」出來，不會回頭影響戰鬥結果，
## 所以同一個種子的戰鬥永遠長得一樣。
##
## 投影由使用的畫面自己提供（project：格子座標 → 棋子在畫面上的中心），
## 所以同一份表演可以放在任何地圖上。以前這些只寫在 8×8 棋盤裡，大地圖戰鬥是簡化版。

const ItemMoves = preload("res://scripts/item_moves.gd")

const FLASH_TICKS := 2          # 受擊白閃持續幾個 tick
const SHAKE_TICKS := 3          # 受擊震動
const FADE_TICKS := 8           # 陣亡淡出（同時倒下）
const SUPPORT_SKILLS := ["heal", "heal_nearby", "shield_allies"]

var sim = null
var tick_f := 0.0
var anim_t := 0.0               # 待機浮動用的連續時間，和戰鬥進度無關

var _death: Dictionary = {}     # uid -> 陣亡的 tick
var _acts: Dictionary = {}      # uid -> [出手]，依時間排序；出手 = {t, rel, T, dst, style, eff, big, sd}
var _hits: Dictionary = {}      # uid -> [t, ...]，被打到的 tick
var _poses: Dictionary = {}     # uid -> 這一幀的姿勢（每幀 gather 時清掉）


## 換一場戰鬥：把事件整理成「每個單位的出手／受擊／陣亡」表，之後每幀查起來很快
func set_sim(s) -> void:
	sim = s
	tick_f = 0.0
	_death.clear()
	_acts.clear()
	_hits.clear()
	_poses.clear()
	if s == null:
		return
	for e in s.events:
		match e.type:
			"death":
				if not _death.has(e.dst):
					_death[e.dst] = float(e.t)
			"hit", "miss":
				_add_act(e, false)
				if e.type == "hit":
					_add_hit(e)
			"cast":
				_add_act(e, true)
			"skill", "burn":
				_add_hit(e)


func _add_hit(e: Dictionary) -> void:
	if not _hits.has(e.dst):
		_hits[e.dst] = []
	_hits[e.dst].append(float(e.t))


## 一次出手（普攻或施放技能）。飛行時間用出手當下兩邊的距離算好存起來，
## 播放中單位移動也不會讓動畫時間跳來跳去。
func _add_act(e: Dictionary, is_cast: bool) -> void:
	var u: Dictionary = sim.units[e.src]
	var mv: Array = ItemMoves.move_of(str(u.id), int(u.team) == 1)
	var style: String = mv[0]
	var eff: String = mv[1]
	if is_cast and str(u.get("skill", {}).get("type", "")) in SUPPORT_SKILLS:
		style = "buff"
		eff = ""
	var fr: Array = sim.frames[clampi(int(e.t), 0, sim.frames.size() - 1)]
	var dist := Vector2(fr[e.src][0], fr[e.src][1]).distance_to(Vector2(fr[e.dst][0], fr[e.dst][1]))
	var travel := ItemMoves.travel(eff, dist)
	if not _acts.has(e.src):
		_acts[e.src] = []
	_acts[e.src].append({"t": float(e.t), "rel": float(e.t) - travel, "T": travel, "dst": int(e.dst),
			"style": style, "eff": eff, "big": is_cast, "sd": int(e.t) * 7 + int(e.src)})


## 目前（或最近一次）的出手：已經開始蓄力的裡面最新的那一次；還沒出過手就回傳第一次（拿來決定面向）
func _latest_act(uid: int):
	var list: Array = _acts.get(uid, [])
	var best = null
	for a in list:
		if float(a.rel) - ItemMoves.WIND > tick_f:
			break
		best = a
	if best == null and not list.is_empty():
		return list[0]
	return best


## 模擬在「最後一隻死掉」那一刻就停了，播放要多留一段給牠淡出，不然屍體會定格
func end_tick() -> float:
	return float(sim.frames.size() - 1) + FADE_TICKS + 2.0


## 這一幀每個單位的狀態：位置已內插；陣亡的帶淡出 alpha，完全淡掉的不回傳。
## 已經由遠到近排好（grid.x + grid.y 由小到大），照順序畫就會正確遮擋。
func gather() -> Array:
	_poses.clear()
	var out: Array = []
	if sim == null:
		return out
	var i0 := clampi(floori(tick_f), 0, sim.frames.size() - 1)
	var i1 := mini(i0 + 1, sim.frames.size() - 1)
	var f := clampf(tick_f - i0, 0.0, 1.0)
	for k in sim.units.size():
		var u: Dictionary = sim.units[k]
		var a: Array = sim.frames[i0][k]
		var b: Array = sim.frames[i1][k]
		var alpha := 1.0
		if _death.has(k):
			var since: float = tick_f - float(_death[k])
			if since >= 0.0:
				alpha = clampf(1.0 - since / FADE_TICKS, 0.0, 1.0)
				if alpha <= 0.0:
					continue
		out.append({
			"uid": k, "id": u.id, "grid": Vector2(a[0], a[1]).lerp(Vector2(b[0], b[1]), f),
			"name": u.name, "school": u.school, "star": u.star, "team": u.team,
			"hp": a[2], "max_hp": u.max_hp, "shield": a[3], "alive": a[4],
			"energy": a[5], "stun": a[6], "alpha": alpha, "range": u.range,
			"moving": a[0] != b[0] or a[1] != b[1],
		})
	out.sort_custom(func(x, y): return x.grid.x + x.grid.y < y.grid.x + y.grid.y)
	return out


## 這一幀的姿勢 {off, rot, flip, sx, sy}：待機、走路小跳、物品自己的出手動作、受擊震動、陣亡倒下。
## off 疊在棋子位置上；rot 以腳底為軸；flip = -1 表示面向左邊。
func pose(it: Dictionary, project: Callable) -> Dictionary:
	var uid := int(it.uid)
	if _poses.has(uid):
		return _poses[uid]
	var off := Vector2(0, sin(anim_t * 2.4 + uid * 0.9) * 1.6)
	if str(it.id) == "basketball" and int(it.team) == 0:
		off = Vector2(0, -absf(sin(anim_t * 5.0 + uid)) * 5.0)          # 籃球待機時在原地運球
	if bool(it.get("moving", false)):
		off.y -= absf(sin(tick_f * PI * 0.5)) * 5.0                       # 走路時一跳一跳
	var p := {"off": off, "rot": 0.0, "spin": 0.0, "flip": 1.0, "sx": 1.0, "sy": 1.0}
	var here: Vector2 = project.call(it.grid)
	var act = _latest_act(uid)
	if act != null:
		var to: Vector2 = project.call(grid_of(int(act.dst))) - here
		p.flip = -1.0 if to.x < -0.5 else 1.0
		var s: float = tick_f - float(act.rel)
		if s >= -ItemMoves.WIND and s <= ItemMoves.FOLLOW:
			var m: Dictionary = ItemMoves.pose(str(act.style), s, to, bool(act.big))
			p.off += m.off
			p.rot = float(m.rot) * p.flip
			p.spin = float(m.spin) * p.flip
			p.sx = m.sx
			p.sy = m.sy
	for t in _hits.get(uid, []):
		var age2: float = tick_f - float(t)
		if age2 < 0.0 or age2 > SHAKE_TICKS:
			continue
		p.off += Vector2(sin(age2 * 9.0), cos(age2 * 7.0)) * 3.5 * (1.0 - age2 / SHAKE_TICKS)
	var alpha := float(it.get("alpha", 1.0))
	if alpha < 1.0:
		p.rot = -p.flip * minf(1.0, (1.0 - alpha) * 2.5) * 1.45          # 往後倒下，再慢慢淡掉
	_poses[uid] = p
	return p


func offset(it: Dictionary, project: Callable) -> Vector2:
	return pose(it, project).off


## 最近幾個 tick 內有沒有被打到（0～1），用來疊白閃
func flash(uid: int) -> float:
	for t in _hits.get(uid, []):
		var age: float = tick_f - float(t)
		if age >= 0.0 and age <= FLASH_TICKS:
			return 1.0 - age / float(FLASH_TICKS + 1)
	return 0.0


func grid_of(uid: int) -> Vector2:
	var i0 := clampi(floori(tick_f), 0, sim.frames.size() - 1)
	var fr: Array = sim.frames[i0][uid]
	return Vector2(fr[0], fr[1])


## 畫在棋子底下的特效：技能光束、施法光圈、治療光圈（光圈貼著地板，所以是橢圓）
func draw_under(c: CanvasItem, items: Array, project: Callable, ground: Callable, r: float) -> void:
	var pos_of := _positions(items, project)
	var now := floori(tick_f)
	for e in sim.events:
		if e.t < now - 3 or e.t > now:
			continue
		match e.type:
			"cast":
				var k: float = clampf((tick_f - float(e.t)) / 4.0, 0.0, 1.0)
				ellipse(c, ground.call(grid_of(int(e.src))), (r + 6) * (1.0 + k * 1.4),
						(r + 6) * 0.5 * (1.0 + k * 1.4), Color(1, 0.9, 0.35, (1.0 - k) * 0.35))
			"heal":
				var k2: float = clampf((tick_f - float(e.t)) / 4.0, 0.0, 1.0)
				ellipse(c, ground.call(grid_of(int(e.dst))), (r + 4) * (1.0 + k2),
						(r + 4) * 0.5 * (1.0 + k2), Color(0.4, 1.0, 0.55, (1.0 - k2) * 0.35))


## 畫在棋子上面的特效：每件物品打出去的東西、傷害數字、技能名稱、暈眩星星
func draw_over(c: CanvasItem, items: Array, project: Callable, font: Font, r: float) -> void:
	var pos_of := _positions(items, project)
	var now := floori(tick_f)
	for it in items:
		if float(it.alpha) < 1.0:
			continue
		for a in _acts.get(it.uid, []):
			var s: float = tick_f - float(a.t)                  # 特效以命中為 0
			if s < -ItemMoves.WIND - float(a.T):
				break
			if s > ItemMoves.FOLLOW:
				continue
			var dst := int(a.dst)
			var b: Vector2 = pos_of[dst] if pos_of.has(dst) else project.call(grid_of(dst))
			ItemMoves.draw_effect(c, font, str(a.style), str(a.eff), pos_of[it.uid], b, s, float(a.T),
					bool(a.big), int(a.sd))
	for it in items:
		if it.stun and float(it.alpha) >= 1.0:
			var center: Vector2 = pos_of[it.uid]
			for i in 3:
				var a: float = anim_t * 3.0 + TAU * i / 3.0
				text(c, font, center + Vector2(cos(a) * r * 0.9, -r - 6 + sin(a) * 3.0), "★", 11,
						Color(1, 0.95, 0.35))
	for e in sim.events:
		var age_f: float = tick_f - float(e.t)
		if age_f < 0.0 or age_f > 8.0:
			continue
		var age: int = now - int(e.t)
		if age < 0 or age > 7 or not pos_of.has(e.dst):
			continue
		var fade := 1.0 - float(age) / 8.0
		var up := Vector2(0, -r - 14 - age * 2.5)
		match e.type:
			"skill":
				text(c, font, pos_of[e.dst] + up, "%d" % int(e.v), 15, Color(1, 0.85, 0.3, fade))
			"heal":
				text(c, font, pos_of[e.dst] + up, "+%d" % int(e.v), 13, Color(0.45, 1.0, 0.55, fade))
			"cast":
				if pos_of.has(e.src):
					text(c, font, pos_of[e.src] + Vector2(0, -r - 26 - age * 2.0), str(e.name), 12,
							Color(1, 0.92, 0.4, fade))


func _positions(items: Array, project: Callable) -> Dictionary:
	var out: Dictionary = {}
	for it in items:
		out[it.uid] = project.call(it.grid) + offset(it, project)
	return out


static func ellipse(c: CanvasItem, center: Vector2, rx: float, ry: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 18:
		var a: float = TAU * i / 18.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	c.draw_colored_polygon(pts, col)


## 置中、有黑邊的文字（p 是文字的中心點 x、基線 y）
static func text(c: CanvasItem, font: Font, p: Vector2, s: String, size_px: int, col: Color) -> void:
	c.draw_string_outline(font, p - Vector2(40, 0), s, HORIZONTAL_ALIGNMENT_CENTER, 80, size_px, 4,
			Color(0, 0, 0, col.a))
	c.draw_string(font, p - Vector2(40, 0), s, HORIZONTAL_ALIGNMENT_CENTER, 80, size_px, col)
