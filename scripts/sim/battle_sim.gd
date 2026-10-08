extends RefCounted
## 純資料的自走棋戰鬥模擬：固定時間步、固定隨機種子，不碰任何節點或畫面。
## team 0 = 玩家（棋盤下半 y 4..7），team 1 = 敵人（棋盤上半 y 0..3）。
## run() 會一次算完整場戰鬥並記錄每個 tick 的快照，畫面只負責播放 frames。

const W := 8                    # 預設戰場大小（獨立棋盤）
const H := 8
const CLIMB_COST := 0.6         # 往上爬一層，移動多花這個比例的時間
const HIGH_GROUND_RANGE := 1    # 站得比目標高時的射程加成
const DT := 0.1
const MAX_TICKS := 400          # 40 秒
const PULSE_TICKS := 50         # 清潔流派每 5 秒一次
const ENERGY_PER_ATTACK := 10.0
const ENERGY_PER_HIT := 5.0
const MAX_ARMOR_SHRED_STACKS := 3
const DIRS := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0),
		Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]

var rng := RandomNumberGenerator.new()
var units: Array = []
var occ: Dictionary = {}
var terrain_fx: Dictionary = {}
# 戰場範圍。預設是獨立的 8×8 棋盤；之後要「直接在大地圖上開打」時，
# 由外面指定一塊區域、哪些格子被家具擋住、以及每格的高度。
var aw := W
var ah := H
var blocked: Dictionary = {}    # Vector2i -> true，走不進去的格子
var heights: Dictionary = {}    # Vector2i -> int，0 是地面
var max_ticks := MAX_TICKS      # 戰鬥長度上限（就地開打時會放寬）
var frames: Array = []     # frames[tick][unit index] = [x, y, hp, shield, alive, energy, stunned]
var events: Array = []     # {t, type, src, dst, v, name}
var tick := 0


## 每個 desc：name, school, traits, star, hp, atk, aspd, range, move, armor, skill, cell, fx
## terrain：戰場地形效果（move_mult / back_row_range / slip_chance / slip_move_mult）
## arena：{w, h, blocked:[Vector2i], height:{Vector2i: int}}，省略就是預設 8×8 空棋盤
func setup(seed_value: int, player_descs: Array, enemy_descs: Array,
		terrain: Dictionary = {}, arena: Dictionary = {}) -> void:
	rng.seed = seed_value
	terrain_fx = terrain
	aw = int(arena.get("w", W))
	ah = int(arena.get("h", H))
	blocked = {}
	for c in arena.get("blocked", []):
		blocked[c] = true
	heights = arena.get("height", {})
	max_ticks = int(arena.get("max_ticks", MAX_TICKS))
	var uid := 0
	for team in [0, 1]:
		var src: Array = player_descs if team == 0 else enemy_descs
		for d in src:
			var u := _make_unit(d, team, uid)
			uid += 1
			units.append(u)
			occ[u.cell] = u


func _make_unit(d: Dictionary, team: int, uid: int) -> Dictionary:
	var fx: Dictionary = d.get("fx", {})
	var cell: Vector2i = d.cell
	var traits: Array = d.get("traits", [])
	var school: String = d.get("school", "")
	var move := float(d.move)
	var reach := int(d.range)
	var slip := 0.0
	move *= float(terrain_fx.get("move_mult", 1.0))
	if team == 0 and cell.y >= ah - 2:
		reach += int(terrain_fx.get("back_row_range", 0))
	if terrain_fx.has("slip_chance") and school != "清潔用品" and not ("黏性" in traits):
		slip = float(terrain_fx.slip_chance)
		move *= float(terrain_fx.get("slip_move_mult", 1.0))
	return {
		"uid": uid, "id": d.get("id", ""), "team": team, "name": d.name,
		"school": school, "traits": traits,
		"star": int(d.get("star", 1)), "smult": float(d.get("smult", 1.0)),
		"max_hp": float(d.hp), "hp": float(d.hp), "shield": float(fx.get("shield", 0)),
		"atk": float(d.atk),
		"aspd": float(d.aspd) * (1.0 + float(fx.get("aspd_pct", 0)) / 100.0),
		"range": reach, "base_move": move, "slip": slip,
		"armor": float(d.armor), "armor_lost": 0.0,
		"skill": d.get("skill", {}), "fx": fx,
		"energy": 0.0, "atk_cd": 0.0, "move_cd": 0.0, "stun": 0.0, "root": 0.0,
		"slow_pct": 0.0, "slow_t": 0.0,
		"burn_stacks": 0, "burn_t": 0.0, "burn_pct": 0.0,
		"mark_pct": 0.0, "mark_t": 0.0,
		"miss_pct": 0.0, "miss_t": 0.0,
		"atk_count": 0,
		"revive_pct": float(d.get("revive_pct", 0)), "revived": false,
		"alive": true, "cell": cell,
	}


func run() -> Dictionary:
	_opening_charge()
	_snapshot()
	while tick < max_ticks:
		tick += 1
		_step()
		_snapshot()
		if _alive_count(0) == 0 or _alive_count(1) == 0:
			break
	var pa := _alive_count(0)
	var ea := _alive_count(1)
	var winner := -1
	if ea == 0 and pa > 0:
		winner = 0
	elif pa == 0:
		winner = 1
	return {"winner": winner, "player_alive": pa, "enemy_alive": ea, "ticks": tick}


## 圓滾滾：開場翻滾衝撞最近的敵人
func _opening_charge() -> void:
	for u in units:
		var dmg := float(u.fx.get("charge_damage", 0))
		if dmg <= 0.0:
			continue
		var t = _find_target(u)
		if t != null:
			_hit(u, t, dmg * u.smult, "skill")


func _step() -> void:
	if tick % PULSE_TICKS == 0:
		_pulse()
	for u in units:
		if not u.alive:
			continue
		_tick_status(u)
		if not u.alive or u.stun > 0.0:
			continue
		u.atk_cd -= DT
		u.move_cd -= DT
		var tgt = _find_target(u)
		if tgt == null:
			continue
		if _dist(u.cell, tgt.cell) <= _range_from(u, u.cell, tgt):
			if u.atk_cd <= 0.0:
				if u.energy >= 100.0 and not u.skill.is_empty():
					_cast(u, tgt)
				else:
					_attack(u, tgt)
				u.atk_cd = 1.0 / u.aspd
		elif u.move_cd <= 0.0 and u.root <= 0.0:
			_step_toward(u, tgt)


## 倒數各種狀態，並結算灼燒傷害
func _tick_status(u: Dictionary) -> void:
	if u.stun > 0.0:
		u.stun -= DT
	if u.root > 0.0:
		u.root -= DT
	if u.slow_t > 0.0:
		u.slow_t -= DT
		if u.slow_t <= 0.0:
			u.slow_pct = 0.0
	if u.mark_t > 0.0:
		u.mark_t -= DT
		if u.mark_t <= 0.0:
			u.mark_pct = 0.0
	if u.miss_t > 0.0:
		u.miss_t -= DT
		if u.miss_t <= 0.0:
			u.miss_pct = 0.0
	if u.burn_t > 0.0:
		u.burn_t -= DT
		var dmg: float = u.max_hp * u.burn_pct / 100.0 * float(u.burn_stacks) * DT
		_apply_damage(u.uid, u, dmg, "burn", false)
		if u.burn_t <= 0.0:
			u.burn_stacks = 0


func _eff_move(u: Dictionary) -> float:
	return maxf(0.1, u.base_move * (1.0 - u.slow_pct / 100.0))


func _pulse() -> void:
	for team in [0, 1]:
		var cleanse := false
		var heal_pct := 0.0
		for u in units:
			if u.alive and u.team == team:
				cleanse = cleanse or bool(u.fx.get("cleanse", false))
				heal_pct = maxf(heal_pct, float(u.fx.get("pulse_heal_pct", 0)))
		if not cleanse and heal_pct <= 0.0:
			continue
		for u in units:
			if u.alive and u.team == team:
				if cleanse:
					u.stun = 0.0
					u.root = 0.0
					u.burn_stacks = 0
					u.burn_t = 0.0
				if heal_pct > 0.0:
					_heal(u, u.max_hp * heal_pct / 100.0)


func _find_target(u: Dictionary):
	var best = null
	var best_d := 9999
	for e in units:
		if not e.alive or e.team == u.team:
			continue
		var d := _dist(u.cell, e.cell)
		if d < best_d or (d == best_d and e.hp < best.hp):
			best = e
			best_d = d
	return best


# ── 攻擊與技能 ──────────────────────────────────────────────

func _attack(u: Dictionary, t: Dictionary) -> void:
	u.atk_count += 1
	if u.miss_pct > 0.0 and rng.randf() * 100.0 < u.miss_pct:
		events.append({"t": tick, "type": "miss", "src": u.uid, "dst": t.uid})
		return
	var shred := float(u.fx.get("shred_armor", 0))
	if shred > 0.0:
		t.armor_lost = minf(t.armor_lost + shred, shred * MAX_ARMOR_SHRED_STACKS)
	_gain_energy(u, ENERGY_PER_ATTACK)
	_on_hit_traits(u, t)
	_hit(u, t, u.atk, "hit")


## 冰冷、高溫、黏性的普攻附加效果
func _on_hit_traits(u: Dictionary, t: Dictionary) -> void:
	var fx: Dictionary = u.fx
	var slow := float(fx.get("slow_pct", 0))
	if slow > 0.0:
		_slow(t, slow, 2.0)
	if fx.has("freeze_every") and u.atk_count % int(fx.freeze_every) == 0:
		t.stun = maxf(t.stun, float(fx.get("freeze_dur", 1.0)))
		events.append({"t": tick, "type": "freeze", "src": u.uid, "dst": t.uid})
	if fx.has("burn_pct"):
		t.burn_stacks = mini(int(t.burn_stacks) + 1, int(fx.get("burn_max", 1)))
		t.burn_pct = float(fx.burn_pct)
		t.burn_t = 3.0
	if fx.has("root_every") and u.atk_count % int(fx.root_every) == 0:
		t.root = maxf(t.root, float(fx.get("root_dur", 0.5)))


func _gain_energy(u: Dictionary, amount: float) -> void:
	u.energy = minf(100.0, u.energy + amount * (1.0 + float(u.fx.get("energy_pct", 0)) / 100.0))


func _slow(t: Dictionary, pct: float, secs: float) -> void:
	t.slow_pct = maxf(t.slow_pct, pct)
	t.slow_t = maxf(t.slow_t, secs)


func _cast(u: Dictionary, t: Dictionary) -> void:
	var s: Dictionary = u.skill
	u.energy = 0.0
	events.append({"t": tick, "type": "cast", "src": u.uid, "dst": t.uid, "name": s.name})
	var mult := float(s.get("mult", 1.0))
	match s.type:
		"aoe_damage":
			for e in _enemies_near(u, t.cell, int(s.radius)):
				_hit(u, e, u.atk * mult, "skill")
		"aoe_slow":
			for e in _enemies_near(u, t.cell, int(s.radius)):
				_hit(u, e, u.atk * mult, "skill")
				_slow(e, float(s.slow_pct), float(s.duration))
		"freeze_aoe":
			for e in _enemies_near(u, t.cell, int(s.radius)):
				_hit(u, e, u.atk * mult, "skill")
				if e.alive:
					e.stun = maxf(e.stun, float(s.duration))
		"blind":
			for e in _enemies_near(u, t.cell, int(s.radius)):
				_hit(u, e, u.atk * mult, "skill")
				if e.alive:
					e.miss_pct = maxf(e.miss_pct, float(s.miss_pct))
					e.miss_t = maxf(e.miss_t, float(s.duration))
		"knockback":
			for e in _enemies_near(u, t.cell, int(s.radius)):
				_hit(u, e, u.atk * mult, "skill")
				if e.alive:
					_push(u, e, int(s.get("push", 1)))
		"mark":
			_hit(u, t, u.atk * mult, "skill")
			if t.alive:
				t.mark_pct = maxf(t.mark_pct, float(s.bonus_pct))
				t.mark_t = maxf(t.mark_t, float(s.duration))
		"pierce":
			var hit := 0
			for e in _sorted_enemies_from(u, t.cell):
				if hit >= int(s.get("targets", 2)):
					break
				_hit(u, e, u.atk * mult, "skill")
				hit += 1
		"execute":
			if t.hp / t.max_hp <= float(s.hp_pct) / 100.0:
				events.append({"t": tick, "type": "skill", "src": u.uid, "dst": t.uid, "v": t.hp})
				_apply_damage(u.uid, t, t.hp + t.shield, "skill", false)
			else:
				_hit(u, t, u.atk * mult, "skill")
		"energy_share":
			_hit(u, t, u.atk * mult, "skill")
			for a in units:
				if a.alive and a.team == u.team and a.uid != u.uid and _dist(a.cell, u.cell) <= int(s.radius):
					_gain_energy(a, float(s.amount) * u.smult)
		"heal":
			_heal(_lowest_hp_ally(u), float(s.amount) * u.smult)
		"heal_nearby":
			for a in units:
				if a.alive and a.team == u.team and _dist(a.cell, u.cell) <= int(s.radius):
					_heal(a, float(s.amount) * u.smult)
		"shield_allies":
			for a in units:
				if a.alive and a.team == u.team and _dist(a.cell, u.cell) <= int(s.radius):
					a.shield += float(s.amount) * u.smult
		"stun":
			_hit(u, t, u.atk * mult, "skill")
			if t.alive:
				t.stun = maxf(t.stun, float(s.duration))
		_:
			_hit(u, t, u.atk * mult, "skill")


func _enemies_near(u: Dictionary, center: Vector2i, radius: int) -> Array:
	var out: Array = []
	for e in units:
		if e.alive and e.team != u.team and _dist(e.cell, center) <= radius:
			out.append(e)
	return out


func _sorted_enemies_from(u: Dictionary, center: Vector2i) -> Array:
	var out: Array = []
	for e in units:
		if e.alive and e.team != u.team:
			out.append(e)
	out.sort_custom(func(a, b): return _dist(a.cell, center) < _dist(b.cell, center))
	return out


## 把 e 從 u 的方向推開 n 格（撞牆或有人就停）
func _push(u: Dictionary, e: Dictionary, n: int) -> void:
	var d: Vector2i = e.cell - u.cell
	var dir := Vector2i(signi(d.x), signi(d.y))
	if dir == Vector2i.ZERO:
		return
	for i in n:
		var nxt: Vector2i = e.cell + dir
		if nxt.x < 0 or nxt.x >= aw or nxt.y < 0 or nxt.y >= ah or occ.has(nxt) or blocked.has(nxt):
			return
		occ.erase(e.cell)
		occ[nxt] = e
		e.cell = nxt


# ── 傷害與死亡 ──────────────────────────────────────────────

func _hit(src: Dictionary, dst: Dictionary, raw: float, kind: String) -> void:
	var armor := maxf(0.0, dst.armor - dst.armor_lost)
	var dmg := raw * 100.0 / (100.0 + armor)
	dmg *= 1.0 + dst.mark_pct / 100.0
	events.append({"t": tick, "type": kind, "src": src.uid, "dst": dst.uid, "v": dmg})
	_apply_damage(src.uid, dst, dmg, kind, true)


func _apply_damage(src_uid: int, dst: Dictionary, dmg: float, kind: String, gives_energy: bool) -> void:
	if not dst.alive or dmg <= 0.0:
		return
	if dst.shield > 0.0:
		var absorbed := minf(dst.shield, dmg)
		dst.shield -= absorbed
		dmg -= absorbed
	dst.hp -= dmg
	if dst.hp > 0.0:
		if gives_energy:
			_gain_energy(dst, ENERGY_PER_HIT)
		return
	# 剩菜之類的復活：原地以一定比例血量站起，每場一次
	if dst.revive_pct > 0.0 and not dst.revived:
		dst.revived = true
		dst.hp = dst.max_hp * dst.revive_pct / 100.0
		dst.burn_stacks = 0
		dst.burn_t = 0.0
		events.append({"t": tick, "type": "revive", "src": dst.uid, "dst": dst.uid})
		return
	dst.hp = 0.0
	dst.alive = false
	occ.erase(dst.cell)
	events.append({"t": tick, "type": "death", "src": src_uid, "dst": dst.uid})


func _heal(u: Dictionary, amount: float) -> void:
	if not u.alive:
		return
	u.hp = minf(u.max_hp, u.hp + amount)
	events.append({"t": tick, "type": "heal", "src": u.uid, "dst": u.uid, "v": amount})


func _lowest_hp_ally(u: Dictionary) -> Dictionary:
	var best: Dictionary = u
	var best_ratio: float = u.hp / u.max_hp
	for a in units:
		if a.alive and a.team == u.team and a.hp / a.max_hp < best_ratio:
			best = a
			best_ratio = a.hp / a.max_hp
	return best


# ── 移動 ────────────────────────────────────────────────────

## 在 8 方向格子上做 BFS（均勻格子上與 A* 等價），走向第一個「射程內」的空格。
## 濕滑地形可能「滑過頭」：沿同方向再衝一格，可能一路滑進敵陣。
func _step_toward(u: Dictionary, t: Dictionary) -> void:
	var start: Vector2i = u.cell
	var queue: Array = [start]
	var parent: Dictionary = {start: start}
	var head := 0
	var goal := Vector2i(-1, -1)
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		if c != start and _dist(c, t.cell) <= _range_from(u, c, t):
			goal = c
			break
		for dir in DIRS:
			var n: Vector2i = c + dir
			if n.x < 0 or n.x >= aw or n.y < 0 or n.y >= ah:
				continue
			if parent.has(n) or occ.has(n) or blocked.has(n):
				continue
			parent[n] = c
			queue.append(n)
	if goal.x < 0:
		return
	var step := goal
	while parent[step] != start:
		step = parent[step]
	occ.erase(start)
	occ[step] = u
	u.cell = step
	# 往上爬比較慢，往下走不罰
	var climb: int = maxi(0, height_at(step) - height_at(start))
	u.move_cd = (1.0 + CLIMB_COST * climb) / _eff_move(u)
	if u.slip > 0.0 and rng.randf() < u.slip:
		var over: Vector2i = step + (step - start)
		if over.x >= 0 and over.x < aw and over.y >= 0 and over.y < ah and not occ.has(over) and not blocked.has(over):
			occ.erase(step)
			occ[over] = u
			u.cell = over
			events.append({"t": tick, "type": "slip", "src": u.uid, "dst": u.uid})


func _dist(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


func height_at(c: Vector2i) -> int:
	return int(heights.get(c, 0))


## 高地優勢：站得比目標高，射程 +1
func _range_from(u: Dictionary, from: Vector2i, t: Dictionary) -> int:
	var r: int = int(u.range)
	if height_at(from) > height_at(t.cell):
		r += HIGH_GROUND_RANGE
	return r


func _alive_count(team: int) -> int:
	var n := 0
	for u in units:
		if u.alive and u.team == team:
			n += 1
	return n


func _snapshot() -> void:
	var f: Array = []
	for u in units:
		f.append([u.cell.x, u.cell.y, int(ceil(u.hp)), int(u.shield), u.alive, int(u.energy), u.stun > 0.0])
	frames.append(f)
