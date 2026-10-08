extends RefCounted
## 探索模式狀態：房子地圖、時段時間、玩家位置、格子內容、家人作息。
## 不依賴任何節點，方便自動測試；畫面只負責讀這裡的資料。

const DB = preload("res://scripts/db.gd")
const GameState = preload("res://scripts/game_state.gd")
const BattleSim = preload("res://scripts/sim/battle_sim.gd")

const STEP_SECONDS := 3.0        # 每走一格扣的時間（地圖變大後從 5 秒下修）
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
const LATE_STEPS_PER_LIFE := 3   # 天黑時離巢穴每 3 格，共用生命 −1
const BOSS_MIN_LIFE := 5         # 遲到再久，決戰至少留這麼多共用生命，不會一開打就輸
const CHEST_MM := [3, 6]

var rng := RandomNumberGenerator.new()
var gs: GameState

var width := 0
var height := 0
var room_at: Dictionary = {}       # Vector2i -> 房間名
var rooms_by_id: Dictionary = {}   # 房間名 -> map.json 的房間定義
var terrain_at: Dictionary = {}    # Vector2i -> 地形名
var cells: Dictionary = {}         # Vector2i -> {kind, key?, label?}
var lair := Vector2i(-1, -1)       # 魔王巢穴（開局隨機，藏在迷霧裡）
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
	_place_lair()
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


## 天黑之後全家都睡了，沒有房間被佔用（決戰時不該還畫著白天的紅色警戒區）
func is_occupied(cell: Vector2i) -> bool:
	return not day_over and room_at.get(cell, "") in occupied_rooms()


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


## 回傳發動攻擊的那一格（玩家目前位置）的地形效果
func battle_terrain_fx() -> Dictionary:
	return DB.terrain_fx(terrain_of(pos))


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
	return _begin_battle(cell, encounter_groups(cell))


## 最終決戰的一波：在巢穴那塊地圖上打，敵人從巢穴散開
func begin_boss_wave() -> Dictionary:
	return _begin_battle(lair, boss_groups())


func boss_groups() -> Array:
	return DB.boss_waves[clampi(gs.wave, 1, DB.boss_waves.size()) - 1].enemies


## 兩邊怎麼站：切戰場、陣形面向 cell 展開、敵人從 cell 往遠離玩家的方向排開。
## 實際開打和佈陣預覽都呼叫這一個，所以預覽不可能跟實際對不上。
func deploy(cell: Vector2i, groups: Array) -> Dictionary:
	var arena := build_arena(cell)
	var facing := GameState.facing_toward(pos, cell)
	var used: Dictionary = {}
	var allies: Array = gs.field_player_descs(arena, pos, used, facing)
	var foes: Array = gs.field_enemy_descs(groups, arena, cell, used, facing)
	return {"arena": arena, "allies": allies, "foes": foes, "facing": facing}


## 陣形現在朝哪：決戰時朝巢穴；旁邊有怪群時朝牠；都沒有就朝地圖上方
func formation_facing() -> Vector2i:
	if day_over and in_bounds(lair):
		return GameState.facing_toward(pos, lair)
	var adj := adjacent_monsters()
	if not adj.is_empty():
		return GameState.facing_toward(pos, adj[0])
	return GameState.DEFAULT_FACING


func _begin_battle(cell: Vector2i, groups: Array) -> Dictionary:
	var d := deploy(cell, groups)
	var arena: Dictionary = d.arena
	var allies: Array = d.allies
	var foes: Array = d.foes
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


# ── 巢穴與最終決戰 ──────────────────────────────────────────

## 巢穴隨機放在起點以外的某個房間，和其他東西一樣藏在迷霧裡，要自己找到。
## 越早找到，就越早知道晚上該收在哪附近（企劃書：越早猜出來，越早知道最後要往哪裡集合）。
func _place_lair() -> void:
	var start_room: String = room_at.get(pos, "")
	var rooms: Array = DB.map.rooms.filter(func(r): return r.id != start_room)
	for attempt in 40:
		var room: Dictionary = rooms[rng.randi() % rooms.size()]
		var r: Array = room.rect
		var c := Vector2i(int(r[0]) + rng.randi() % int(r[2]), int(r[1]) + rng.randi() % int(r[3]))
		if c != pos and not walls.has(c) and not cells.has(c):
			lair = c
			cells[c] = {"kind": "lair", "label": "巢穴"}
			return


## 天黑：魔王在巢穴現身，玩家趕過去。離巢穴越遠，到得越晚，共用生命扣越多
## （企劃書：還沒趕到的人那一路的怪會先打進來，所以探索時不能跑太遠）。
## 回傳 {distance, late, found}。
func arrive_at_lair() -> Dictionary:
	var dist := 0
	if pos != lair:
		var path := path_to(lair)
		dist = path.size() if not path.is_empty() else absi(pos.x - lair.x) + absi(pos.y - lair.y)
	var late := dist / LATE_STEPS_PER_LIFE
	var found := discovered.has(lair)
	pos = _boss_anchor()
	_reveal(pos)
	_reveal(lair)
	if dist == 0:
		_log("你就在巢穴旁邊，第一時間擋下了魔王。")
	else:
		_log("天黑了！你離巢穴 %d 格，趕過去的路上魔王已經在作亂：共用生命 −%d" % [dist, late])
	return {"distance": dist, "late": late, "found": found}


## 天黑 → 最終決戰開始：趕到巢穴，共用生命 = 底線 + 剩餘血量 − 遲到的懲罰。
## 遊戲畫面和自動測試都走這裡。
func start_final_battle() -> Dictionary:
	var arrival := arrive_at_lair()
	gs.start_boss(hp)
	gs.life = maxi(BOSS_MIN_LIFE, gs.life - int(arrival.late))
	return arrival


## 結算決戰的一波（輸贏、共用生命、收入都交給 GameState.apply_result）。回傳 "win" / "lose"。
func end_boss_wave(battle: Dictionary) -> String:
	var res: Dictionary = battle.result
	var wave_no: int = gs.wave
	var before: int = gs.life
	battles_fought += 1
	battle_seconds += float(battle.seconds)
	gs.apply_result(res)
	var won: bool = int(res.winner) == 0
	if won:
		_log("決戰第 %d 波：守住了！" % wave_no)
	else:
		_log("決戰第 %d 波：沒擋下來，剩 %d 隻，共用生命 −%d" % [
				wave_no, int(res.enemy_alive), before - gs.life])
	if gs.state == "won":
		_log("通關！你守住了這個家。")
	elif gs.state == "lost":
		_log("共用生命歸零，家被佔領了…")
	return "win" if won else "lose"


## 決戰時玩家站的位置：巢穴往外幾格，讓陣形和魔王的軍隊分在兩邊
func _boss_anchor() -> Vector2i:
	for d in [Vector2i(0, 4), Vector2i(4, 0), Vector2i(0, -4), Vector2i(-4, 0),
			Vector2i(3, 3), Vector2i(-3, 3), Vector2i(3, -3), Vector2i(-3, -3),
			Vector2i(0, 3), Vector2i(3, 0), Vector2i(0, -3), Vector2i(-3, 0)]:
		var c: Vector2i = lair + d
		if in_bounds(c) and not walls.has(c) and not has_monster(c):
			return c
	return lair


## 走到巢穴要幾格（找到巢穴之後，畫面會提示晚上別跑太遠）
func lair_distance() -> int:
	if pos == lair:
		return 0
	var path := path_to(lair)
	return path.size() if not path.is_empty() else absi(pos.x - lair.x) + absi(pos.y - lair.y)


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
