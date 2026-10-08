extends RefCounted
## 單人版遊戲狀態：筆芯、商店、備戰席、棋盤、升星、流派計算、波次推進。
## 沒有任何節點相依，方便之後接連線與自動測試。

const DB = preload("res://scripts/db.gd")
const BattleSim = preload("res://scripts/sim/battle_sim.gd")

const BENCH_SIZE := 8
const SHOP_SIZE := 5
const START_LIFE := 100
const BOSS_LIFE_BASE := 30      # 最終決戰的共用生命底線
const START_MM := 20            # demo 規格：開局 20 mm
const START_UNITS := 2          # demo 規格：開局 2 件 1 星物品
const STAR_MULT := 1.8
const MAX_LEVEL := 6
const XP_NEEDS := [4, 8, 12, 16, 20]       # 抽屜等級 n → n+1 所需經驗
const POP_CAP := 7              # 人口上限固定，不隨抽屜等級成長
const OWNED_BIAS := 0.30        # 每格商店有此機率改出「已持有」的棋子（幫助升星）
const SCHOOL_BIAS := 0.20       # 再有此機率改出「主力流派」的棋子（幫助湊羈絆）
const MAX_SAME_IN_SHOP := 2     # 同一次刷新最多出現幾件同名
# 卡池：每個名字的張數有限（參考明日方舟「衛戍協議：盟約」的共用卡池）
# 已擁有的（場上＋備戰席）會佔掉張數；商店「正在顯示」的不佔，賣掉會還回池裡。
const POOL_BY_COST := {1: 18, 2: 12, 3: 8}
const MAX_COST := 3
# 刷新費用：同一場戰鬥內越刷越貴，打完一場就重置
const REFRESH_BASE := 2
const REFRESH_STEP := 1         # 2 → 3 → 4 → 5…，每場戰鬥後歸零
const XP_COST := 4
const BASE_INCOME := 5
const FREE_XP_PER_ROUND := 2
const PLAYER_Y_MIN := 4
# 抽屜等級 → 費用 1..4 的出現權重
const ODDS := [[80, 20, 0, 0], [60, 35, 5, 0], [40, 40, 18, 2], [25, 35, 30, 10], [15, 25, 35, 25], [10, 20, 30, 40]]
# 抽屜等級 → 商店直接刷出 2 星的機率（%）；只對費用 1–2 的棋子生效
const STAR2_ODDS := [0, 6, 12, 18, 24, 30]
const STAR2_MAX_COST := 2

var rng := RandomNumberGenerator.new()
var mm := START_MM
var life := START_LIFE
var wave := 1
var level := 1
var xp := 0
var streak := 0
var shop: Array = []
var bench: Array = []
var board: Dictionary = {}     # Vector2i -> instance
var next_uid := 1
var state := "playing"         # playing | won | lost
var pool: Dictionary = {}      # 棋子 id -> 卡池剩餘張數
var refreshes := 0             # 這場戰鬥已經刷新幾次
var pending_reward: Array = [] # 升星獎勵：三選一的免費招募


func start_new(seed_value: int) -> void:
	rng.seed = seed_value
	bench.resize(BENCH_SIZE)
	bench.fill(null)
	for id in DB.units:
		pool[id] = int(POOL_BY_COST.get(int(DB.units[id].cost), 10))
	var starters: Array = DB.by_cost.get(1, [])
	for i in START_UNITS:
		if not starters.is_empty():
			add_unit(starters[rng.randi() % starters.size()])
	roll_shop()


# ── 容量與查詢 ──────────────────────────────────────────────

func pop_cap() -> int:
	return POP_CAP


func wave_list() -> Array:
	return DB.boss_waves         # 只剩最終決戰會用到波次（10 波練習模式已移除）


func max_wave() -> int:
	return wave_list().size()


func xp_need() -> int:
	return XP_NEEDS[level - 1] if level < MAX_LEVEL else 0


func interest() -> int:
	return mini(floori(mm / 10.0), 5)


func unit_def(inst: Dictionary) -> Dictionary:
	return DB.units[inst.id]


func star_mult(star: int) -> float:
	return pow(STAR_MULT, star - 1)


func sell_value(inst: Dictionary) -> int:
	return int(unit_def(inst).cost) * int(pow(3, inst.star - 1))


# ── 商店 ────────────────────────────────────────────────────

## 商店每格是 {"id": String, "star": int} 或 null（已購買）
func roll_shop() -> void:
	shop.clear()
	var owned := _owned_ids()
	var main_school := _main_school()
	for i in SHOP_SIZE:
		var r := rng.randf()
		var id := ""
		if r < OWNED_BIAS and not owned.is_empty():
			id = owned[rng.randi() % owned.size()]
		elif r < OWNED_BIAS + SCHOOL_BIAS and main_school != "":
			id = _roll_unit_id(main_school)
		if id == "" or pool_left(id) <= 0:
			id = _roll_unit_id()
		# 同一次刷新最多出現兩件同名，避免整排都是同一樣東西
		var tries := 0
		while (id == "" or _count_in_shop(id) >= MAX_SAME_IN_SHOP) and tries < 10:
			id = _roll_unit_id()
			tries += 1
		# 整個費用層的卡池都被抽光時，退而求其次找任何還有貨的棋子
		if id == "":
			id = _any_available_id()
		shop.append({"id": id, "star": _roll_star(id)} if id != "" else null)


## 卡池裡還有貨的任一棋子；全空才回傳 ""（該格會顯示「卡池已空」）
func _any_available_id() -> String:
	var ids: Array = []
	for i in DB.units:
		if pool_left(i) > 0:
			ids.append(i)
	return ids[rng.randi() % ids.size()] if not ids.is_empty() else ""


func _count_in_shop(id: String) -> int:
	var n := 0
	for e in shop:
		if e != null and e.id == id:
			n += 1
	return n


## 抽屜等級越高，越可能直接刷出 2 星（只限便宜棋子，避免高費 2 星一步登天）
## 2 星等於 3 張卡，所以池裡不夠 3 張就只能刷 1 星
func _roll_star(id: String) -> int:
	if int(DB.units[id].cost) > STAR2_MAX_COST or pool_left(id) < 3:
		return 1
	return 2 if rng.randi_range(1, 100) <= STAR2_ODDS[level - 1] else 1


# ── 卡池 ────────────────────────────────────────────────────

func pool_left(id: String) -> int:
	return int(pool.get(id, 0))


func _take_from_pool(id: String, copies: int) -> bool:
	if pool_left(id) < copies:
		return false
	pool[id] = pool_left(id) - copies
	return true


## 一件 n 星的棋子等於 3^(n-1) 張卡，賣掉或弄丟都要原數還回池裡
func _return_to_pool(id: String, star: int) -> void:
	pool[id] = pool_left(id) + int(pow(3, star - 1))


func _pick_random(arr: Array, n: int) -> Array:
	var copy: Array = arr.duplicate()
	var out: Array = []
	while not copy.is_empty() and out.size() < n:
		out.append(copy.pop_at(rng.randi() % copy.size()))
	return out


func shop_price(entry) -> int:
	if entry == null:
		return 0
	return int(DB.units[entry.id].cost) * int(pow(3, int(entry.star) - 1))


## 目前持有（場上＋備戰席）且本等級商店買得到的棋子 id（不重複）
func _owned_ids() -> Array:
	var max_cost := _max_shop_cost()
	var seen: Dictionary = {}
	for c in board:
		seen[board[c].id] = true
	for inst in bench:
		if inst != null:
			seen[inst.id] = true
	var out: Array = []
	for id in seen:
		if int(DB.units[id].cost) <= max_cost and pool_left(id) > 0:
			out.append(id)
	return out


## 場上不重複棋子最多的流派（沒有就回傳空字串）
func _main_school() -> String:
	var syn := synergies()
	var best := ""
	var best_n := 0
	for school in syn:
		if syn[school].count > best_n:
			best = school
			best_n = syn[school].count
	return best


func _max_shop_cost() -> int:
	var odds: Array = ODDS[level - 1]
	var m := 1
	for i in odds.size():
		if int(odds[i]) > 0:
			m = i + 1
	return m


## school 不為空時只從該流派挑；該費用沒有該流派的棋子就回傳 ""
func _roll_unit_id(school: String = "") -> String:
	var odds: Array = ODDS[level - 1]
	var total := 0
	for w in odds:
		total += int(w)
	var r := rng.randi_range(1, total)
	var cost := 1
	for i in odds.size():
		r -= int(odds[i])
		if r <= 0:
			cost = i + 1
			break
	while cost > 1 and not DB.by_cost.has(cost):
		cost -= 1
	var ids: Array = DB.by_cost[cost].filter(func(id): return pool_left(id) > 0)
	if school != "":
		ids = ids.filter(func(id): return DB.units[id].school == school)
	if ids.is_empty():
		return ""
	return ids[rng.randi() % ids.size()]


## 同一場戰鬥內越刷越貴；打完一場戰鬥會由 reset_refresh() 歸零
func refresh_cost() -> int:
	return REFRESH_BASE + REFRESH_STEP * refreshes


func reset_refresh() -> void:
	refreshes = 0


func refresh_shop() -> bool:
	var cost := refresh_cost()
	if mm < cost:
		return false
	mm -= cost
	refreshes += 1
	roll_shop()
	return true


func buy_xp() -> bool:
	if level >= MAX_LEVEL or mm < XP_COST:
		return false
	mm -= XP_COST
	_add_xp(XP_COST)
	return true


## 房間特性給的額外經驗（例如書房打贏 +2）
func add_xp(amount: int) -> void:
	_add_xp(amount)


func _add_xp(amount: int) -> void:
	xp += amount
	while level < MAX_LEVEL and xp >= XP_NEEDS[level - 1]:
		xp -= XP_NEEDS[level - 1]
		level += 1
	if level >= MAX_LEVEL:
		xp = 0


func buy(slot: int) -> bool:
	var entry = shop[slot]
	if entry == null:
		return false
	var price := shop_price(entry)
	if mm < price:
		return false
	var idx := bench.find(null)
	if idx < 0:
		return false
	var copies := int(pow(3, int(entry.star) - 1))
	if not _take_from_pool(entry.id, copies):
		return false
	mm -= price
	shop[slot] = null
	bench[idx] = _new_inst(entry.id, int(entry.star))
	_merge_all()
	return true


## 直接把一件棋子放進備戰席（寶箱、影印機、升星獎勵用）
## free 為 true 時不扣卡池（目前沒用到，保留給之後的獎勵設計）
func add_unit(id: String, star: int = 1, free := false) -> bool:
	var idx := bench.find(null)
	if idx < 0:
		return false
	if not free and not _take_from_pool(id, int(pow(3, star - 1))):
		return false
	bench[idx] = _new_inst(id, star)
	_merge_all()
	return true


## 棋子離場（倒地懲罰、被家人收走）：張數要還回卡池
func remove_at(loc: Dictionary) -> void:
	var inst = get_at(loc)
	if inst != null:
		_return_to_pool(inst.id, int(inst.star))
	_set_at(loc, null)


func _new_inst(id: String, star: int = 1) -> Dictionary:
	var inst := {"uid": next_uid, "id": id, "star": star, "bonus_hp": 0.0}
	next_uid += 1
	return inst


# ── 棋盤與備戰席 ────────────────────────────────────────────

func get_at(loc: Dictionary):
	if loc.t == "bench":
		return bench[loc.i]
	return board.get(loc.c)


func _set_at(loc: Dictionary, inst) -> void:
	if loc.t == "bench":
		bench[loc.i] = inst
	elif inst == null:
		board.erase(loc.c)
	else:
		board[loc.c] = inst


## 把 from 的棋子移到 to；to 有棋子就交換。回傳是否成功。
func move(from: Dictionary, to: Dictionary) -> bool:
	if to.t == "board" and (to.c.y < PLAYER_Y_MIN or to.c.y >= BattleSim.H or to.c.x < 0 or to.c.x >= BattleSim.W):
		return false
	var a = get_at(from)
	var b = get_at(to)
	if a == null:
		return false
	# 備戰席 → 空格 會讓場上人數 +1
	if from.t == "bench" and to.t == "board" and b == null and board.size() >= pop_cap():
		return false
	_set_at(from, b)
	_set_at(to, a)
	return true


func sell(loc: Dictionary) -> bool:
	var inst = get_at(loc)
	if inst == null:
		return false
	mm += sell_value(inst)
	_return_to_pool(inst.id, int(inst.star))
	_set_at(loc, null)
	return true


## 三件同名同星合成高一星；優先保留在場上的位置。
func _merge_all() -> void:
	var merged := true
	while merged:
		merged = false
		var groups: Dictionary = {}
		for loc in _all_locs():
			var inst = get_at(loc)
			if inst == null or inst.star >= 3:
				continue
			var key := "%s|%d" % [inst.id, inst.star]
			if not groups.has(key):
				groups[key] = []
			groups[key].append(loc)
		for key in groups:
			var locs: Array = groups[key]
			if locs.size() < 3:
				continue
			locs.sort_custom(func(x, y): return (x.t == "board") and (y.t != "board"))
			var keep: Dictionary = locs[0]
			var inst: Dictionary = get_at(keep)
			var extra := 0.0
			for k in [1, 2]:
				extra += float(get_at(locs[k]).bonus_hp)
				_set_at(locs[k], null)
			inst.star += 1
			inst.bonus_hp = float(inst.bonus_hp) + extra
			_offer_merge_reward()
			merged = true
			break


## 升星的額外獎勵（抄「衛戍協議」的設計）：
## 送一次「高一階的免費招募」，從比目前商店最高費用再高一階的棋子裡三選一。
## 不能刷新，打完這場戰鬥就失效。
func _offer_merge_reward() -> void:
	var tier := mini(_max_shop_cost() + 1, MAX_COST)
	var ids: Array = []
	for id in DB.by_cost.get(tier, []):
		if pool_left(id) > 0:
			ids.append(id)
	if ids.is_empty():
		return
	pending_reward = _pick_random(ids, 3)


func claim_merge_reward(id: String) -> bool:
	if not id in pending_reward:
		return false
	pending_reward = []
	return add_unit(id)


func drop_merge_reward() -> void:
	pending_reward = []


func _all_locs() -> Array:
	var out: Array = []
	for c in board:
		out.append({"t": "board", "c": c})
	for i in BENCH_SIZE:
		out.append({"t": "bench", "i": i})
	return out


# ── 流派 ────────────────────────────────────────────────────

## 回傳 school → {count, tier（-1 = 未啟動）, fx}
func synergies() -> Dictionary:
	var seen: Dictionary = {}     # school → {id: true}
	for c in board:
		var def := unit_def(board[c])
		if not seen.has(def.school):
			seen[def.school] = {}
		seen[def.school][def.id] = true
	var out: Dictionary = {}
	for school in seen:
		var count: int = seen[school].size()
		var tier := -1
		var fx: Dictionary = {}
		var tiers: Array = DB.schools[school].tiers
		for i in tiers.size():
			if count >= int(tiers[i].count):
				tier = i
				fx = tiers[i].fx
		out[school] = {"count": count, "tier": tier, "fx": fx}
	return out


## 特徵：跨流派存在，湊到 2 / 4 件觸發，但必須來自至少 2 個不同大流派。
## 回傳 trait → {count, schools, tier（-1 = 未啟動）, fx}
func trait_synergies() -> Dictionary:
	var seen: Dictionary = {}     # trait → {ids: {}, schools: {}}
	for c in board:
		var def := unit_def(board[c])
		for tr in def.traits:
			if not seen.has(tr):
				seen[tr] = {"ids": {}, "schools": {}}
			seen[tr].ids[def.id] = true
			seen[tr].schools[def.school] = true
	var out: Dictionary = {}
	for tr in seen:
		var count: int = seen[tr].ids.size()
		var schools: int = seen[tr].schools.size()
		var tier := -1
		var fx: Dictionary = {}
		if schools >= 2 and DB.traits.has(tr):
			var tiers: Array = DB.traits[tr].tiers
			for i in tiers.size():
				if count >= int(tiers[i].count):
					tier = i
					fx = tiers[i].fx
		out[tr] = {"count": count, "schools": schools, "tier": tier, "fx": fx}
	return out


## 預覽「把這件棋子放上場」之後，流派與特徵會變成什麼樣子。
## 羈絆是算「場上不重複的棋子種類」，所以場上已經有同名的話，再買一件不會讓件數增加。
## 回傳 {already_on_board, school:{...}, traits:[{...}]}，每筆都含 from/to 與 tier_from/tier_to。
func preview_unit(id: String) -> Dictionary:
	var def: Dictionary = DB.units[id]
	var on_board := false
	var seen: Dictionary = {}        # trait -> {ids, schools}
	var school_ids: Dictionary = {}  # school -> {id: true}
	for c in board:
		var d := unit_def(board[c])
		if d.id == id:
			on_board = true
		if not school_ids.has(d.school):
			school_ids[d.school] = {}
		school_ids[d.school][d.id] = true
		for tr in d.traits:
			if not seen.has(tr):
				seen[tr] = {"ids": {}, "schools": {}}
			seen[tr].ids[d.id] = true
			seen[tr].schools[d.school] = true

	var s_from: int = school_ids[def.school].size() if school_ids.has(def.school) else 0
	var s_to: int = s_from if on_board else s_from + 1
	var stiers: Array = DB.schools[def.school].tiers
	var out: Dictionary = {
		"already_on_board": on_board,
		"school": {
			"name": def.school, "from": s_from, "to": s_to, "tiers": stiers,
			"tier_from": _tier_index(stiers, s_from), "tier_to": _tier_index(stiers, s_to),
		},
		"traits": [],
	}
	for tr in def.traits:
		if not DB.traits.has(tr):
			continue
		var info: Dictionary = seen.get(tr, {"ids": {}, "schools": {}})
		var t_from: int = info.ids.size()
		var sch_from: int = info.schools.size()
		var t_to := t_from
		var sch_to := sch_from
		if not info.ids.has(id):
			t_to = t_from + 1
			sch_to = sch_from + (0 if info.schools.has(def.school) else 1)
		var ttiers: Array = DB.traits[tr].tiers
		out.traits.append({
			"name": tr, "from": t_from, "to": t_to, "tiers": ttiers,
			"schools_from": sch_from, "schools_to": sch_to,
			# 特徵必須來自至少 2 個不同大流派，不然湊再多件也不算數
			"tier_from": _tier_index(ttiers, t_from) if sch_from >= 2 else -1,
			"tier_to": _tier_index(ttiers, t_to) if sch_to >= 2 else -1,
		})
	return out


## 買下並放上場後，會不會多啟動一層羈絆（商店按鈕上的提示用）
func would_upgrade(id: String) -> bool:
	var p := preview_unit(id)
	if int(p.school.tier_to) > int(p.school.tier_from):
		return true
	for t in p.traits:
		if int(t.tier_to) > int(t.tier_from):
			return true
	return false


static func _tier_index(tiers: Array, count: int) -> int:
	var t := -1
	for i in tiers.size():
		if count >= int(tiers[i].count):
			t = i
	return t


## 輕便特徵：探索時每格扣的時間倍率
func explore_step_mult() -> float:
	var t := trait_synergies()
	if t.has("輕便"):
		return 1.0 - float(t["輕便"].fx.get("step_cut", 0)) / 100.0
	return 1.0


## 同一件棋子可能同時吃到流派與多個特徵的加成，數值取最大值合併
static func _merge_fx(into: Dictionary, from: Dictionary) -> void:
	for k in from:
		var v = from[k]
		var is_num := typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT
		if into.has(k) and is_num:
			into[k] = maxf(float(into[k]), float(v))
		else:
			into[k] = v



## 陣形會轉向、面對要打的那群怪：
## 整備棋盤的「上方」（y 小的那邊）就是面對敵人的前方。最前排的中間這一格對到玩家站的位置，
## 其他排往玩家身後延伸；敵人則從怪群那格往遠離玩家的方向排開。
## 這樣兩邊中間是一條清楚的前線，不會交錯站在一起（以前陣形以玩家為中心向四周展開，
## 跟只隔一格的怪群範圍重疊，佈陣預覽和實際開打都疊成一團）。
## 佈陣畫面、敵人預覽、實際開打都用下面這組換算，所以看到什麼就是什麼。
const FORMATION_FRONT := Vector2i(3, 4)
const DEFAULT_FACING := Vector2i(0, -1)      # 附近沒有怪時，陣形朝地圖上方


## from 看向 to 的方向，取上下左右之中最接近的一個
static func facing_toward(from: Vector2i, to: Vector2i) -> Vector2i:
	var d := to - from
	if d == Vector2i.ZERO:
		return DEFAULT_FACING
	if absi(d.x) >= absi(d.y):
		return Vector2i(signi(d.x), 0)
	return Vector2i(0, signi(d.y))


## 陣形格（整備棋盤座標）→ 大地圖格。facing 是「前方」在地圖上的方向。
static func formation_to_map(b: Vector2i, anchor: Vector2i, facing: Vector2i) -> Vector2i:
	var o := b - FORMATION_FRONT                 # o.x 往右為正，o.y 往後為正
	var right := Vector2i(-facing.y, facing.x)
	return anchor + right * o.x - facing * o.y


## 大地圖格 → 陣形格（formation_to_map 的反函數）
static func map_to_formation(m: Vector2i, anchor: Vector2i, facing: Vector2i) -> Vector2i:
	var d := m - anchor
	var right := Vector2i(-facing.y, facing.x)
	return FORMATION_FRONT + Vector2i(d.x * right.x + d.y * right.y,
			-(d.x * facing.x + d.y * facing.y))


## 在戰場裡找一個離 want 最近、沒被佔用也沒被擋住的格子（螺旋往外找）。
## 放在這裡而不是 MapState，是因為 MapState 已經 preload 了本檔，再反過來會變成循環引用。
static func free_spot(arena: Dictionary, want: Vector2i, used: Dictionary) -> Vector2i:
	var blocks: Dictionary = {}
	for b in arena.blocked:
		blocks[b] = true
	for r in range(0, 8):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var c: Vector2i = want + Vector2i(dx, dy)
				if c.x < 0 or c.y < 0 or c.x >= int(arena.w) or c.y >= int(arena.h):
					continue
				if blocks.has(c) or used.has(c):
					continue
				return c
	return Vector2i(-1, -1)


## 在大地圖上就地開打時的我方佈陣：最前排對齊 anchor（玩家所在格），面向 facing。
## 位置被家具擋住就往外找最近的空位，所以不會有人卡在牆裡。
func field_player_descs(arena: Dictionary, anchor_map: Vector2i, used: Dictionary,
		facing: Vector2i) -> Array:
	var syn := synergies()
	var tsyn := trait_synergies()
	var origin: Vector2i = arena.origin
	var out: Array = []
	for c in board:
		var inst: Dictionary = board[c]
		var def := unit_def(inst)
		var want: Vector2i = formation_to_map(c, anchor_map, facing) - origin
		var local := free_spot(arena, want, used)
		if local.x < 0:
			continue
		used[local] = true
		var sm := star_mult(inst.star)
		var fx: Dictionary = {}
		if syn.has(def.school):
			_merge_fx(fx, syn[def.school].fx)
		for tr in def.traits:
			if tsyn.has(tr):
				_merge_fx(fx, tsyn[tr].fx)
		out.append({
			"id": def.id, "name": def.name, "school": def.school, "traits": def.traits,
			"star": inst.star, "smult": sm,
			"hp": float(def.hp) * sm + float(inst.bonus_hp), "atk": float(def.atk) * sm,
			"aspd": def.aspd, "range": def.range, "move": def.move, "armor": def.armor,
			"skill": def.get("skill", {}), "cell": local, "fx": fx,
		})
	return out


## 敵人從怪群所在格開始，往 facing（遠離玩家）的方向一排排排開，每排 5 隻；近戰排前面
func field_enemy_descs(groups: Array, arena: Dictionary, center_map: Vector2i,
		used: Dictionary, facing: Vector2i) -> Array:
	var origin: Vector2i = arena.origin
	var entries: Array = []
	for group in groups:
		var def: Dictionary = DB.enemies[group.id]
		for i in int(group.count):
			entries.append({"def": def, "mult": float(group.mult)})
	entries.sort_custom(func(a, b): return a.def.range < b.def.range)
	var out: Array = []
	var right := Vector2i(-facing.y, facing.x)
	var idx := 0
	for e in entries:
		var row: int = idx / 5
		var col: int = (idx % 5) - 2
		var want: Vector2i = center_map + facing * row + right * col - origin
		idx += 1
		var local := free_spot(arena, want, used)
		if local.x < 0:
			continue
		used[local] = true
		var def: Dictionary = e.def
		out.append({
			"id": def.id, "name": def.name, "school": "害蟲", "traits": [], "star": 1,
			"smult": e.mult, "hp": float(def.hp) * e.mult, "atk": float(def.atk) * e.mult,
			"aspd": def.aspd, "range": def.range, "move": def.move, "armor": def.armor,
			"skill": def.get("skill", {}), "cell": local, "fx": {},
		})
	return out


## 探索結束 → 最終決戰：共用生命 = 底線 + 帶進來的剩餘個人血量。
## 加底線是因為血量剩個位數時決戰會變成形式，完全打不起來。
func start_boss(carry_hp: int) -> void:
	wave = 1
	life = BOSS_LIFE_BASE + carry_hp
	state = "playing"
	roll_shop()


## 探索地圖上的遭遇戰打贏時呼叫（扣血與獎勵由 MapState 負責）
func on_encounter_won() -> void:
	streak = streak + 1 if streak > 0 else 1
	_food_growth()


## 波次模式（練習 10 波 / 決戰 5 波）的結算
func apply_result(res: Dictionary) -> void:
	var won: bool = res.winner == 0
	if won:
		streak = streak + 1 if streak > 0 else 1
		_food_growth()
	else:
		streak = streak - 1 if streak < 0 else -1
		life -= int(res.enemy_alive) * 2 + wave
	if life <= 0:
		life = 0
		state = "lost"
		return
	if wave >= max_wave():
		state = "won"
		return
	wave += 1
	mm += BASE_INCOME + interest() + _streak_bonus()
	_add_xp(FREE_XP_PER_ROUND)
	reset_refresh()
	drop_merge_reward()
	roll_shop()


func _streak_bonus() -> int:
	var n := absi(streak)
	if n < 3:
		return 0
	return mini((n - 1) / 2, 3)


func _food_growth() -> void:
	var syn := synergies()
	if not syn.has("食物"):
		return
	var pct := float(syn["食物"].fx.get("perm_hp_pct", 0))
	if pct <= 0.0:
		return
	for c in board:
		var inst: Dictionary = board[c]
		var def := unit_def(inst)
		if def.school == "食物":
			inst.bonus_hp = float(inst.bonus_hp) + float(def.hp) * star_mult(inst.star) * pct / 100.0
