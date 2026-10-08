extends RefCounted
## 探索模式狀態：房子地圖、時段時間、玩家位置、格子內容、家人作息。
## 不依賴任何節點，方便自動測試；畫面只負責讀這裡的資料。

const DB = preload("res://scripts/db.gd")
const GameState = preload("res://scripts/game_state.gd")
const BattleSim = preload("res://scripts/sim/battle_sim.gd")

const STEP_SECONDS := 3.0        # 每走一格扣的時間（地圖變大後從 5 秒下修）
const PREP_SECONDS := 30.0       # 擺陣時間，也算進時段
const RETREAT_SECONDS := 10.0    # 撤退：只扣開戰後 10 秒
const RETREAT_HP := 5
const LOSE_HP := 12              # 戰敗扣的個人血量
const OCCUPIED_HP := 5           # 待在被家人佔用的房間，每走一格扣血
const OCCUPIED_ITEM_CHANCE := 0.25
const MAX_HP := 50
const DOWN_SECONDS := 30.0       # 倒地等待
const COPIER_COST := 5
const COPIER_USES := 2
const REST_HP := 5
const ARENA_PAD := 6             # 戰場在玩家與怪群之外多留幾格
const FIELD_MAX_TICKS := 900     # 就地開打沒有 40 秒上限，只留一個很長的安全上限（90 秒）
const CHEST_MM := [3, 6]

var rng := RandomNumberGenerator.new()
var gs: GameState

var width := 0
var height := 0
var room_at: Dictionary = {}       # Vector2i -> 房間名
var rooms_by_id: Dictionary = {}   # 房間名 -> map.json 的房間定義
var terrain_at: Dictionary = {}    # Vector2i -> 地形名
var cells: Dictionary = {}         # Vector2i -> {kind, key?, label?}
var walls: Dictionary = {}         # Vector2i -> true，家具之類走不進去的格子
var heights: Dictionary = {}       # Vector2i -> int，地板高度
var discovered: Dictionary = {}    # Vector2i -> true，看過的格子（沒看過的是黑的）
var vision := 5                    # 視野半徑
var pos := Vector2i.ZERO

var seg := 0                       # 目前時段索引
var time_left := 0.0
var hp := MAX_HP
var copier_left := COPIER_USES
var day_over := false
var logs: Array = []                # 最近的事件訊息

# 驗證指標
var steps_taken := 0
var battle_seconds := 0.0
var battles_fought := 0
var mm_earned := 0


func start(seed_value: int, game_state: GameState) -> void:
	rng.seed = seed_value
	gs = game_state
	var m: Dictionary = DB.map
	width = int(m.width)
	height = int(m.height)
	pos = Vector2i(int(m.start[0]), int(m.start[1]))
	for room in m.rooms:
		rooms_by_id[room.id] = room
		var r: Array = room.rect
		for dy in int(r[3]):
			for dx in int(r[2]):
				var c := Vector2i(int(r[0]) + dx, int(r[1]) + dy)
				room_at[c] = room.id
				terrain_at[c] = room.terrain
	for ov in m.terrain_overrides:
		terrain_at[Vector2i(int(ov.cell[0]), int(ov.cell[1]))] = ov.terrain
	vision = int(m.get("vision", 5))
	_build_furniture()
	_place_contents()
	_reveal(pos)
	time_left = float(m.segments[0].seconds)
	_log("【%s】%s" % [segment().name, segment().desc])


## 每個房間撒一些擋路的家具與墊高的平台。
## 家具彼此至少隔一格，保證不會把房間封死（任何方向都還留得下通道）。
func _build_furniture() -> void:
	for room in DB.map.rooms:
		var r: Array = room.rect
		var base := int(room.get("height", 0))
		for dy in int(r[3]):
			for dx in int(r[2]):
				heights[Vector2i(int(r[0]) + dx, int(r[1]) + dy)] = base
		var tries := 0
		var placed := 0
		var want := int(room.get("obstacles", 0))
		while placed < want and tries < want * 30:
			tries += 1
			var c := Vector2i(int(r[0]) + rng.randi() % int(r[2]), int(r[1]) + rng.randi() % int(r[3]))
			if c == pos or _near_wall(c):
				continue
			walls[c] = true
			placed += 1
		for i in int(room.get("platforms", 0)):
			var p := Vector2i(int(r[0]) + rng.randi() % maxi(1, int(r[2]) - 1),
					int(r[1]) + rng.randi() % maxi(1, int(r[3]) - 1))
			var lift: int = 1 if rng.randf() < 0.7 else 2
			for dy2 in 2:
				for dx2 in 2:
					var q: Vector2i = p + Vector2i(dx2, dy2)
					if heights.has(q) and not walls.has(q):
						heights[q] = base + lift


func _near_wall(c: Vector2i) -> bool:
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if walls.has(c + Vector2i(dx, dy)):
				return true
	return false


## 走到哪就看到哪；看過的格子會記住（之後變暗但還看得見內容）
func _reveal(center: Vector2i) -> void:
	for dy in range(-vision, vision + 1):
		for dx in range(-vision, vision + 1):
			var c := center + Vector2i(dx, dy)
			if in_bounds(c) and absi(dx) + absi(dy) <= vision + 2:
				discovered[c] = true


func is_visible(c: Vector2i) -> bool:
	return maxi(absi(c.x - pos.x), absi(c.y - pos.y)) <= vision


func height_of(c: Vector2i) -> int:
	return int(heights.get(c, 0))


func is_wall(c: Vector2i) -> bool:
	return walls.has(c)


func _place_contents() -> void:
	for room in DB.map.rooms:
		var free: Array = []
		var r: Array = room.rect
		for dy in int(r[3]):
			for dx in int(r[2]):
				var c := Vector2i(int(r[0]) + dx, int(r[1]) + dy)
				if c != pos:
					free.append(c)
		free = free.filter(func(c): return not walls.has(c))
		for key in room.quota:
			for i in int(room.quota[key]):
				if free.is_empty():
					break
				var idx := rng.randi() % free.size()
				var c: Vector2i = free[idx]
				free.remove_at(idx)
				if key.begins_with("monster_"):
					cells[c] = {"kind": "monster", "key": key, "label": DB.map.monster_tiers[key].label}
				else:
					cells[c] = {"kind": key, "label": key}


# ── 查詢 ────────────────────────────────────────────────────

func segment() -> Dictionary:
	return DB.map.segments[seg]


func segment_total() -> float:
	return float(segment().seconds)


func occupied_rooms() -> Array:
	return segment().occupied


func is_occupied(cell: Vector2i) -> bool:
	return room_at.get(cell, "") in occupied_rooms()


func terrain_of(cell: Vector2i) -> String:
	return terrain_at.get(cell, "普通")


func cell_at(cell: Vector2i):
	return cells.get(cell)


func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < width and cell.y >= 0 and cell.y < height


## 走不進去的格子：家具，或是還沒清掉的怪群
func is_blocked(cell: Vector2i) -> bool:
	if walls.has(cell):
		return true
	var c = cells.get(cell)
	return c != null and c.kind == "monster"


## 只有怪群（家具不算），點擊要分辨得出來
func has_monster(cell: Vector2i) -> bool:
	var c = cells.get(cell)
	return c != null and c.kind == "monster"


## 玩家四周（上下左右）還沒清掉的怪群
func adjacent_monsters() -> Array:
	var out: Array = []
	for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
		var c: Vector2i = pos + d
		if in_bounds(c) and has_monster(c):
			out.append(c)
	return out


## 每走一格實際扣的秒數（「輕便」特徵會降低）
func step_cost() -> float:
	return STEP_SECONDS * gs.explore_step_mult()


func steps_affordable() -> int:
	return floori(time_left / step_cost())


# ── 移動 ────────────────────────────────────────────────────

## 四方向 BFS，繞開怪群格；回傳不含起點的路徑，走不到則為空
func path_to(target: Vector2i) -> Array:
	if target == pos or not in_bounds(target) or is_blocked(target):
		return []
	var parent: Dictionary = {pos: pos}
	var queue: Array = [pos]
	var head := 0
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		if c == target:
			break
		for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
			var n: Vector2i = c + d
			if not in_bounds(n) or parent.has(n) or is_blocked(n):
				continue
			parent[n] = c
			queue.append(n)
	if not parent.has(target):
		return []
	var path: Array = []
	var cur := target
	while cur != pos:
		path.push_front(cur)
		cur = parent[cur]
	return path


## 沿路徑逐格移動，時間不夠或倒地就停下。回傳實際走的格數。
func walk(path: Array) -> int:
	var moved := 0
	var cost := step_cost()
	for cell in path:
		if day_over or time_left < cost:
			_log("時間不夠，走不動了")
			break
		time_left -= cost
		pos = cell
		moved += 1
		steps_taken += 1
		_reveal(pos)
		if is_occupied(pos):
			_hurt(OCCUPIED_HP, "被吸塵器掃到（%s 正被家人佔用）" % room_at[pos])
			if rng.randf() < OCCUPIED_ITEM_CHANCE:
				_lose_random_item("東西被收走了")
			if hp <= 0:
				break
		var c = cells.get(pos)
		if c != null:
			_on_enter(pos, c)
	_check_time()
	return moved


func _on_enter(cell: Vector2i, c: Dictionary) -> void:
	match c.kind:
		"chest":
			if rng.randf() < 0.5:
				var gain := rng.randi_range(CHEST_MM[0], CHEST_MM[1])
				gs.mm += gain
				mm_earned += gain
				_log("寶箱：撿到 %d mm 筆芯" % gain)
			else:
				var id := _random_affordable_id()
				if id != "" and gs.add_unit(id):
					_log("寶箱：撿到「%s」" % DB.units[id].name)
				else:
					gs.mm += CHEST_MM[0]
					mm_earned += CHEST_MM[0]
					_log("寶箱：備戰席滿了，改拿 %d mm" % CHEST_MM[0])
			cells.erase(cell)
		"rest":
			hp = mini(MAX_HP, hp + REST_HP)
			_log("休息點：回復 %d 點血量（目前 %d）" % [REST_HP, hp])
			cells.erase(cell)


func _random_affordable_id() -> String:
	var pool: Array = DB.by_cost.get(1, [])
	if pool.is_empty():
		return ""
	return pool[rng.randi() % pool.size()]


# ── 戰鬥 ────────────────────────────────────────────────────

## 從大地圖上切出一塊戰場：包住玩家與怪群，往外留一圈空間。
## 家具變成障礙物、地板高度照搬，所以「在哪裡打」真的會影響戰鬥。
## 回傳的座標是戰場內的區域座標，origin 是它在大地圖上的左上角。
func build_arena(monster_cell: Vector2i) -> Dictionary:
	var lo := Vector2i(mini(pos.x, monster_cell.x), mini(pos.y, monster_cell.y))
	var hi := Vector2i(maxi(pos.x, monster_cell.x), maxi(pos.y, monster_cell.y))
	lo = Vector2i(maxi(0, lo.x - ARENA_PAD), maxi(0, lo.y - ARENA_PAD))
	hi = Vector2i(mini(width - 1, hi.x + ARENA_PAD), mini(height - 1, hi.y + ARENA_PAD))
	var w: int = hi.x - lo.x + 1
	var h: int = hi.y - lo.y + 1
	var blocks: Array = []
	var hmap: Dictionary = {}
	for y in h:
		for x in w:
			var m: Vector2i = lo + Vector2i(x, y)
			if walls.has(m):
				blocks.append(Vector2i(x, y))
			hmap[Vector2i(x, y)] = height_of(m)
	return {"origin": lo, "w": w, "h": h, "blocked": blocks, "height": hmap,
			"max_ticks": FIELD_MAX_TICKS}


## 房間定義（怪物種類、獎勵倍率、特性）
func room_def(cell: Vector2i) -> Dictionary:
	return rooms_by_id.get(room_at.get(cell, ""), {})


## 怪群由「規模（小中大）」× 「所在房間的怪物種類與強度」組成，
## 所以同樣是大群，在儲藏室會比在玄關難打，掉的筆芯也不同。
func encounter_groups(cell: Vector2i) -> Array:
	var tier: Dictionary = DB.map.monster_tiers[cells[cell].key]
	var room := room_def(cell)
	var pool: Array = room.get("enemy_pool", ["dust"])
	var mult := float(tier.mult) * float(room.get("enemy_mult", 1.0))
	var total := int(tier.count)
	var groups: Array = []
	for i in pool.size():
		var share: int = total / pool.size() + (1 if i < total % pool.size() else 0)
		if share > 0:
			groups.append({"id": pool[i], "count": share, "mult": mult})
	return groups


func encounter_enemies(cell: Vector2i) -> Array:
	return gs.build_enemy_descs(encounter_groups(cell))


## 回傳發動攻擊的那一格（玩家目前位置）的地形效果
func battle_terrain_fx() -> Dictionary:
	return DB.terrain_fx(terrain_of(pos))


## result：BattleSim.run() 的結果；retreated 為 true 時只扣撤退成本
## charge_time 為 false 時不扣時間 —— 就地開打的時間是在戰鬥播放中即時流掉的，
## 這裡再扣一次就變成重複計費。
func finish_encounter(cell: Vector2i, result: Dictionary, retreated: bool,
		charge_time := true) -> void:
	battles_fought += 1
	var spent := PREP_SECONDS if charge_time else 0.0
	if retreated:
		if charge_time:
			spent += RETREAT_SECONDS
		battle_seconds += RETREAT_SECONDS
		_hurt(RETREAT_HP, "撤退：扣 %d 點血量，怪群留在原地" % RETREAT_HP)
	else:
		var elapsed: float = float(result.ticks) * 0.1
		if charge_time:
			spent += elapsed
		battle_seconds += elapsed
		if result.winner == 0:
			_reward(cell, elapsed)
		else:
			_hurt(LOSE_HP, "打輸了：扣 %d 點血量，怪群留在原地" % LOSE_HP)
	# 刷新費用與升星獎勵都以「一場戰鬥」為單位
	gs.reset_refresh()
	gs.drop_merge_reward()
	time_left = maxf(0.0, time_left - spent)
	_check_time()


## 打贏怪群的獎勵：筆芯（依房間倍率）、房間特性的回血／經驗，並清掉該格
func _reward(cell: Vector2i, secs: float) -> void:
	var tier: Dictionary = DB.map.monster_tiers[cells[cell].key]
	var room := room_def(cell)
	var gain := int(rng.randi_range(int(tier.reward[0]), int(tier.reward[1]))
			* float(room.get("reward_mult", 1.0)))
	gs.mm += gain
	mm_earned += gain
	cells.erase(cell)
	var bonus: Array = []
	var heal := int(room.get("win_hp", 0))
	if heal > 0:
		hp = mini(MAX_HP, hp + heal)
		bonus.append("回 %d 血" % heal)
	var xp := int(room.get("win_xp", 0))
	if xp > 0:
		gs.add_xp(xp)
		bonus.append("抽屜經驗 +%d" % xp)
	_log("打贏 %s（%s）：獲得 %d mm%s（花了 %.0f 秒）" % [
			tier.label, room_at.get(cell, ""), gain,
			"，" + "、".join(bonus) if not bonus.is_empty() else "", secs])


# ── 就地開打 ────────────────────────────────────────────────
# 遊戲畫面和自動測試都走這兩個函式，才不會「測的是一套、玩的是另一套」。

## 切戰場、在玩家周圍展開陣形、把整場算完。畫面之後只負責播放。
func begin_field_battle(cell: Vector2i) -> Dictionary:
	var arena := build_arena(cell)
	var used: Dictionary = {}
	var allies: Array = gs.field_player_descs(arena, pos, used)
	var foes: Array = gs.field_enemy_descs(encounter_groups(cell), arena, cell, used)
	var sim := BattleSim.new()
	sim.setup(gs.rng.randi(), allies, foes, battle_terrain_fx(), arena)
	var result: Dictionary = sim.run()
	return {"sim": sim, "arena": arena, "result": result, "cell": cell,
			"seconds": float(result.ticks) * BattleSim.DT}


## 結算就地開打。played 是實際播放掉的秒數 —— 時間在播放過程中已經即時扣掉了，這裡不再扣。
## 時段時間在整場打完之前就用完，視為「被打斷」：不給獎勵、不扣血、怪群留著。
## （以前會直接套用整場算好的結果，播到一半時間到了也照拿勝利獎勵。）
## 回傳 "win" / "lose" / "retreat" / "interrupted"。
func end_field_battle(battle: Dictionary, played: float, retreated: bool) -> String:
	var cell: Vector2i = battle.cell
	var result: Dictionary = battle.result
	var full: float = float(battle.seconds)
	battles_fought += 1
	battle_seconds += minf(played, full)
	var outcome := ""
	if retreated:
		outcome = "retreat"
		_hurt(RETREAT_HP, "撤退：扣 %d 點血量，怪群留在原地" % RETREAT_HP)
	elif played + 0.001 < full:
		outcome = "interrupted"
		_log("時間到了，戰鬥被打斷：沒有獎勵，怪群留在原地")
	elif int(result.winner) == 0:
		outcome = "win"
		gs.on_encounter_won()
		_reward(cell, full)
	else:
		outcome = "lose"
		_hurt(LOSE_HP, "打輸了：扣 %d 點血量，怪群留在原地" % LOSE_HP)
	# 刷新費用與升星獎勵都以「一場戰鬥」為單位
	gs.reset_refresh()
	gs.drop_merge_reward()
	_check_time()
	return outcome


# ── 血量與時段 ──────────────────────────────────────────────

func _hurt(amount: int, why: String) -> void:
	hp -= amount
	_log(why)
	if hp <= 0:
		_knock_down()


func _knock_down() -> void:
	hp = int(MAX_HP * 0.5)
	time_left = maxf(0.0, time_left - DOWN_SECONDS)
	_log("筆尖斷了！等待 %d 秒後以 %d 點血量站起" % [int(DOWN_SECONDS), hp])
	_lose_random_item("倒地懲罰：掉了一件物品")
	_check_time()


func _lose_random_item(why: String) -> void:
	var locs: Array = []
	for i in GameState.BENCH_SIZE:
		if gs.bench[i] != null:
			locs.append({"t": "bench", "i": i})
	for c in gs.board:
		locs.append({"t": "board", "c": c})
	if locs.is_empty():
		return
	var loc: Dictionary = locs[rng.randi() % locs.size()]
	var inst = gs.get_at(loc)
	var name: String = gs.unit_def(inst).name
	gs.remove_at(loc)
	_log("%s：失去「%s」" % [why, name])


func _check_time() -> void:
	if time_left >= step_cost() or day_over:
		return
	advance_segment()


func advance_segment() -> void:
	if day_over:
		return
	seg += 1
	if seg >= DB.map.segments.size():
		seg = DB.map.segments.size() - 1
		day_over = true
		_log("天黑了，最終決戰開始。")
		return
	time_left = segment_total()
	_log("【%s】%s" % [segment().name, segment().desc])


# ── 影印機 ──────────────────────────────────────────────────

func can_copy() -> bool:
	return copier_left > 0 and cells.get(pos) != null and cells[pos].kind == "copier" and gs.mm >= COPIER_COST


func copy_item(loc: Dictionary) -> bool:
	if not can_copy():
		return false
	var inst = gs.get_at(loc)
	if inst == null or not gs.add_unit(inst.id, int(inst.star)):
		return false
	gs.mm -= COPIER_COST
	copier_left -= 1
	_log("影印機：複製了一件「%s」（剩 %d 次）" % [gs.unit_def(inst).name, copier_left])
	return true


func can_shop() -> bool:
	var c = cells.get(pos)
	return c != null and c.kind == "shop"


func _log(msg: String) -> void:
	logs.append(msg)
	if logs.size() > 8:
		logs.pop_front()
