extends SceneTree
## 無畫面測試：確定性 + 機器人打 10 波，用來粗看數值平衡。
## 執行：Godot --headless --path . --script tests/bot_test.gd

const DB = preload("res://scripts/db.gd")
const GameState = preload("res://scripts/game_state.gd")


func _init() -> void:
	DB.load_all()
	_test_determinism()
	var wins := 0
	var runs := 40        # 20 場的通關率抖動可達 ±5，樣本要夠大才看得出平衡變化
	var wave_reach: Array = []
	for s in runs:
		var r := _play(1000 + s, s == 0)
		if r.won:
			wins += 1
		wave_reach.append(r.wave)
	print("機器人通關率：%d / %d；結束波數：%s" % [wins, runs, str(wave_reach)])
	_diagnose()
	quit()


## 通關率掉下來時，分辨是「卡池抽乾」還是「刷新太貴」造成的
func _diagnose() -> void:
	var gs := GameState.new()
	gs.start_new(4242)
	var guard := 0
	while gs.state == "playing" and guard < 40:
		guard += 1
		_shop_round(gs)
		_arrange(gs)
		var sim = gs.make_sim()
		gs.apply_result(sim.run())
	var empty := 0
	var low := 0
	var total := 0
	for id in gs.pool:
		total += 1
		if gs.pool_left(id) == 0:
			empty += 1
		elif gs.pool_left(id) <= 3:
			low += 1
	print("  卡池診斷：%d 種棋子中，抽乾 %d 種、剩 3 張以下 %d 種" % [total, empty, low])
	print("  刷新費用：第 1 次 %d mm，連刷 3 次共 %d mm（每場戰鬥後歸零）" % [
			GameState.REFRESH_BASE,
			GameState.REFRESH_BASE * 3 + GameState.REFRESH_STEP * 3])


func _test_determinism() -> void:
	var gs := GameState.new()
	gs.start_new(7)
	for i in 3:
		gs.mm = 20
		gs.buy(i)
	_place_all(gs)
	var a = gs.make_sim()
	var ra: Dictionary = a.run()
	var gs2 := GameState.new()
	gs2.start_new(7)
	for i in 3:
		gs2.mm = 20
		gs2.buy(i)
	_place_all(gs2)
	var b = gs2.make_sim()
	var rb: Dictionary = b.run()
	assert(str(ra) == str(rb) and a.frames.hash() == b.frames.hash(), "同種子結果必須一致")
	print("確定性測試通過：", ra)


func _place_all(gs) -> void:
	for i in gs.bench.size():
		if gs.bench[i] != null and gs.board.size() < gs.pop_cap():
			var x: int = gs.board.size() % 8
			gs.move({"t": "bench", "i": i}, {"t": "board", "c": Vector2i(x, 5)})


## 簡單機器人：每回合優先買「已擁有同名」或「同流派」的最貴物品，放滿人口。
func _play(seed_value: int, verbose: bool) -> Dictionary:
	var gs := GameState.new()
	gs.start_new(seed_value)
	var guard := 0
	while gs.state == "playing" and guard < 40:
		guard += 1
		_shop_round(gs)
		_arrange(gs)
		var sim = gs.make_sim()
		var res: Dictionary = sim.run()
		if verbose:
			var stars := []
			for c in gs.board:
				stars.append(gs.board[c].star)
			var tiers := []
			var syn: Dictionary = gs.synergies()
			for s in syn:
				tiers.append("%s%d/T%d" % [s, syn[s].count, syn[s].tier + 1])
			print("波%d 贏=%s 存活 %d/敵 %d 秒=%.1f 生命=%d 筆芯=%d Lv%d 星=%s 羈絆=%s" % [
				gs.wave, res.winner == 0, res.player_alive, res.enemy_alive, res.ticks * 0.1,
				gs.life, gs.mm, gs.level, str(stars), str(tiers)])
		gs.apply_result(res)
	return {"won": gs.state == "won", "wave": gs.wave}


func _shop_round(gs) -> void:
	# 錢夠就先買經驗，之後盡量買
	while gs.level < 5 and gs.mm >= 14 and gs.buy_xp():
		pass
	for r in 3:
		for slot in gs.shop.size():
			var entry = gs.shop[slot]
			if entry == null:
				continue
			var owned := _count_id(gs, entry.id)
			if owned > 0 or int(entry.star) > 1 or gs.board.size() + _bench_count(gs) < gs.pop_cap() + 2:
				gs.buy(slot)
		# 留一點錢再刷新，否則買完就沒錢刷，刷新漲價機制等於沒被測到
		if r < 2 and gs.mm >= gs.refresh_cost() + 4:
			gs.refresh_shop()
		else:
			break


func _count_id(gs, id: String) -> int:
	var n := 0
	for c in gs.board:
		if gs.board[c].id == id:
			n += 1
	for b in gs.bench:
		if b != null and b.id == id:
			n += 1
	return n


func _bench_count(gs) -> int:
	var n := 0
	for b in gs.bench:
		if b != null:
			n += 1
	return n


func _arrange(gs) -> void:
	# 全部先收回備戰席，再依射程排：近戰前排 y=4，遠程後排 y=7
	for c in gs.board.keys():
		var idx: int = gs.bench.find(null)
		if idx < 0:
			break
		gs.move({"t": "board", "c": c}, {"t": "bench", "i": idx})
	var cands: Array = []
	for i in gs.bench.size():
		if gs.bench[i] != null:
			cands.append(i)
	# 星數高、費用高優先上場
	cands.sort_custom(func(a, b):
		var ia = gs.bench[a]
		var ib = gs.bench[b]
		var sa = ia.star * 10 + DB.units[ia.id].cost
		var sb = ib.star * 10 + DB.units[ib.id].cost
		return sa > sb)
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
