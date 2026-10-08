extends SceneTree
## 無畫面測試：地圖完整性 + 機器人跑完一天並打最終決戰。
## 執行：Godot --headless --path . --script tests/explore_test.gd

const DB = preload("res://scripts/db.gd")
const GameState = preload("res://scripts/game_state.gd")
const MapState = preload("res://scripts/map_state.gd")


func _init() -> void:
	DB.load_all()
	_test_map_integrity()
	_test_determinism()
	var wins := 0
	var runs := 12
	var steps: Array = []
	var secs: Array = []
	var lates: Array = []
	var found := 0
	for s in runs:
		var r := _play(500 + s, s == 0)
		if r.won:
			wins += 1
		steps.append(r.steps)
		secs.append(int(r.battle_seconds))
		lates.append(r.late)
		if r.found_lair:
			found += 1
	print("決戰通關：%d / %d" % [wins, runs])
	print("白天找到巢穴：%d / %d　遲到扣的共用生命：%s" % [found, runs, str(lates)])
	print("移動格數：%s" % str(steps))
	print("戰鬥總秒數：%s" % str(secs))
	quit()


func _test_map_integrity() -> void:
	var gs := GameState.new()
	gs.start_new(1)
	var ms := MapState.new()
	ms.start(1, gs)
	var covered := 0
	for y in ms.height:
		for x in ms.width:
			var c := Vector2i(x, y)
			assert(ms.room_at.has(c), "格子沒有房間：%s" % c)
			assert(DB.terrain.has(ms.terrain_of(c)), "地形名稱不存在：%s" % ms.terrain_of(c))
			covered += 1
	assert(covered == ms.width * ms.height, "房間沒有鋪滿地圖")
	var kinds: Dictionary = {}
	for c in ms.cells:
		kinds[ms.cells[c].kind] = int(kinds.get(ms.cells[c].kind, 0)) + 1
	# 地圖至少要有怪、商店、影印機，否則探索迴圈跑不起來
	for need in ["monster", "shop", "copier"]:
		assert(kinds.has(need), "地圖缺少 %s" % need)
	assert(not ms.cells.has(ms.pos), "起點不該放東西")
	print("地圖檢查通過：%d 格、內容 %s" % [covered, str(kinds)])
	_test_lair()


## 巢穴：每局都要有一個、位置隨種子而變、不在起點房間、不在家具上、走得到
func _test_lair() -> void:
	var spots: Dictionary = {}
	for s in 20:
		var gs := GameState.new()
		gs.start_new(100 + s)
		var ms := MapState.new()
		ms.start(100 + s, gs)
		var start_room: String = ms.room_at[ms.pos]
		assert(ms.in_bounds(ms.lair), "種子 %d 沒有生成巢穴" % (100 + s))
		assert(ms.cells.has(ms.lair) and ms.cells[ms.lair].kind == "lair", "巢穴沒有登記在地圖上")
		assert(ms.room_at[ms.lair] != start_room, "巢穴不該放在起點的房間（%s）" % start_room)
		assert(not ms.is_wall(ms.lair), "巢穴放在家具上")
		assert(not ms.path_to(ms.lair).is_empty(), "種子 %d 的巢穴走不到 %s" % [100 + s, str(ms.lair)])
		assert(not ms.discovered.has(ms.lair), "巢穴一開局就看得到，應該藏在迷霧裡")
		spots[ms.room_at[ms.lair]] = true
	assert(spots.size() >= 4, "20 局的巢穴只出現在 %d 個房間，不夠隨機" % spots.size())
	print("巢穴檢查通過：20 局分布在 %d 個房間 %s" % [spots.size(), str(spots.keys())])


func _test_determinism() -> void:
	var a := _play(999, false)
	var b := _play(999, false)
	assert(not a.is_empty() and a.has("steps"), "探索沒有跑起來，結果是空的：%s" % str(a))
	assert(int(a.steps) > 0, "機器人一步都沒走，探索迴圈有問題")
	assert(str(a) == str(b), "同種子的探索結果必須一致\nA=%s\nB=%s" % [str(a), str(b)])
	print("探索確定性測試通過：", a)


## 機器人：走去最近的怪群打，時間剩不多就去抽屜買東西
func _play(seed_value: int, verbose: bool) -> Dictionary:
	var gs := GameState.new()
	gs.start_new(seed_value)
	var ms := MapState.new()
	ms.start(seed_value, gs)
	var avoid: Dictionary = {}      # 打輸撤退過的怪群，之後繞開
	var guard := 0
	while not ms.day_over and guard < 300:
		guard += 1
		if ms.time_left < ms.step_cost():
			ms.advance_segment()
			continue
		var adj: Array = ms.adjacent_monsters()
		adj = adj.filter(func(c): return not avoid.has(c))
		if not adj.is_empty() and ms.hp > MapState.LOSE_HP:
			_shop_and_arrange(gs)
			var label: String = ms.cell_at(adj[0]).label
			# 跟遊戲走同一套：在大地圖上切戰場、展開陣形、時間即時流逝
			var battle: Dictionary = ms.begin_field_battle(adj[0])
			# 會玩的人看得出打不贏就會撤退（開打一秒就撤），而不是硬打到底
			var retreat: bool = int(battle.result.winner) != 0
			var played: float = 1.0 if retreat else float(battle.seconds)
			played = minf(played, ms.time_left)      # 時段時間用完就被打斷
			ms.time_left -= played
			var outcome: String = ms.end_field_battle(battle, played, retreat)
			if outcome != "win":
				avoid[adj[0]] = true
			if verbose:
				print("  %s %s 於「%s」：%.0f 秒，剩 %d 秒 血 %d 筆芯 %d" % [
					{"win": "打贏", "lose": "打輸", "retreat": "撤退", "interrupted": "被打斷"}[outcome],
					label, ms.terrain_of(ms.pos), played, int(ms.time_left), ms.hp, gs.mm])
			continue
		var target = _pick_target(ms, avoid)
		if target == null:
			ms.advance_segment()
			continue
		var path: Array = ms.path_to(target)
		if path.is_empty():
			ms.advance_segment()
			continue
		ms.walk(path)
	# 最終決戰：跟遊戲走同一套 —— 趕到巢穴，在巢穴那塊地圖上打五波
	var arrival: Dictionary = ms.start_final_battle()
	if verbose:
		print("  天黑：離巢穴 %d 格（%s），遲到扣 %d，決戰共用生命 %d" % [
			int(arrival.distance), "白天有找到" if arrival.found else "白天沒找到",
			int(arrival.late), gs.life])
	var guard2 := 0
	while gs.state == "playing" and guard2 < 20:
		guard2 += 1
		_shop_and_arrange(gs)
		var wave_no: int = gs.wave
		var outcome: String = ms.end_boss_wave(ms.begin_boss_wave())
		if verbose:
			print("  決戰第 %d 波：%s 生命 %d" % [wave_no, outcome, gs.life])
	return {"won": gs.state == "won", "steps": ms.steps_taken,
			"battles": ms.battles_fought, "battle_seconds": ms.battle_seconds,
			"hp": ms.hp, "mm_earned": ms.mm_earned, "late": int(arrival.late),
			"found_lair": bool(arrival.found)}


## 優先走怪群旁邊；時間剩不到 25% 改去抽屜
func _pick_target(ms: MapState, avoid: Dictionary = {}):
	var want_shop: bool = ms.time_left < ms.segment_total() * 0.25
	var best = null
	var best_d := 9999
	for c in ms.cells:
		var kind: String = ms.cells[c].kind
		var is_shop: bool = kind == "shop"
		if want_shop and not is_shop:
			continue
		if not want_shop and kind != "monster":
			continue
		if avoid.has(c):
			continue
		var goal: Vector2i = c
		if kind == "monster":
			goal = _approach(ms, c)
			if goal == ms.pos:
				continue
		if ms.is_occupied(goal):
			continue
		var d: int = ms.path_to(goal).size()
		if d > 0 and d < best_d:
			best_d = d
			best = goal
	return best


func _approach(ms: MapState, target: Vector2i) -> Vector2i:
	for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
		var c: Vector2i = target + d
		if ms.in_bounds(c) and not ms.is_blocked(c) and not ms.is_occupied(c):
			return c
	return ms.pos


func _shop_and_arrange(gs: GameState) -> void:
	for slot in gs.shop.size():
		var entry = gs.shop[slot]
		if entry != null:
			gs.buy(slot)
	# 近戰前排 y=4，遠程後排 y=7
	for c in gs.board.keys():
		var idx: int = gs.bench.find(null)
		if idx < 0:
			break
		gs.move({"t": "board", "c": c}, {"t": "bench", "i": idx})
	var cands: Array = []
	for i in gs.bench.size():
		if gs.bench[i] != null:
			cands.append(i)
	cands.sort_custom(func(a, b):
		var ia = gs.bench[a]
		var ib = gs.bench[b]
		return ia.star * 10 + DB.units[ia.id].cost > ib.star * 10 + DB.units[ib.id].cost)
	var front := 0
	var back := 0
	for i in cands:
		if gs.board.size() >= gs.pop_cap():
			break
		var def: Dictionary = DB.units[gs.bench[i].id]
		var cell: Vector2i
		if int(def.range) <= 1:
			cell = Vector2i(2 + front, 4)
			front += 1
		else:
			cell = Vector2i(2 + back, 7)
			back += 1
		gs.move({"t": "bench", "i": i}, {"t": "board", "c": cell})
