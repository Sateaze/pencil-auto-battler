extends SceneTree
## 卡池與刷新機制的測試（參考明日方舟「衛戍協議：盟約」）：
##   - 每個名字的張數有限，買走會扣、賣掉會還
##   - 商店「正在顯示」的不佔張數
##   - 抽乾之後就刷不到
##   - 3 張同名合成升星，並送一次「高一階免費招募」三選一
##   - 刷新費用在同一場戰鬥內越刷越貴，打完一場歸零
## 執行：Godot --headless --path . --script tests/pool_test.gd

const DB = preload("res://scripts/db.gd")
const GameState = preload("res://scripts/game_state.gd")

var failures: Array = []


func _init() -> void:
	DB.load_all()
	_test_buy_and_sell()
	_test_display_does_not_consume()
	_test_exhausted_never_rolls()
	_test_merge_reward()
	_test_refresh_escalates()
	_test_synergy_preview()
	if failures.is_empty():
		print("卡池測試全部通過 ✔")
	else:
		print("卡池測試失敗 ✘")
		for f in failures:
			print("  - %s" % f)
	quit(0 if failures.is_empty() else 1)


func _check(ok: bool, msg: String) -> void:
	if not ok:
		failures.append(msg)


func _inst(id: String, star := 1) -> Dictionary:
	return {"uid": 1, "id": id, "star": star, "bonus_hp": 0.0}


func _fresh(seed_value := 1) -> GameState:
	var gs := GameState.new()
	gs.start_new(seed_value)
	# 開局會送 2 件 1 星，先清掉以免干擾計數
	for i in GameState.BENCH_SIZE:
		if gs.bench[i] != null:
			gs.remove_at({"t": "bench", "i": i})
	gs.mm = 999
	return gs


func _test_buy_and_sell() -> void:
	var gs := _fresh()
	gs.shop = [{"id": "bat", "star": 1}, null, null, null, null]
	var before := gs.pool_left("bat")
	gs.buy(0)
	_check(gs.pool_left("bat") == before - 1,
			"買走 1 星應該扣 1 張：%d → %d" % [before, gs.pool_left("bat")])
	gs.sell({"t": "bench", "i": 0})
	_check(gs.pool_left("bat") == before,
			"賣掉應該把張數還回池裡：%d（原本 %d）" % [gs.pool_left("bat"), before])

	# 2 星等於 3 張
	var gs2 := _fresh()
	gs2.shop = [{"id": "bat", "star": 2}, null, null, null, null]
	var b2 := gs2.pool_left("bat")
	gs2.buy(0)
	_check(gs2.pool_left("bat") == b2 - 3,
			"買走 2 星應該扣 3 張：%d → %d" % [b2, gs2.pool_left("bat")])


func _test_display_does_not_consume() -> void:
	var gs := _fresh(7)
	var snapshot: Dictionary = {}
	for id in gs.pool:
		snapshot[id] = gs.pool_left(id)
	for i in 20:
		gs.roll_shop()
	var changed: Array = []
	for id in gs.pool:
		if gs.pool_left(id) != snapshot[id]:
			changed.append(id)
	_check(changed.is_empty(),
			"只是刷新顯示不該消耗卡池，但這些被扣了：%s" % str(changed))


func _test_exhausted_never_rolls() -> void:
	var gs := _fresh(11)
	# 把除了「球棒」以外的 1 費棋子全部抽乾，商店就只剩球棒可出
	for id in DB.by_cost[1]:
		if id != "bat":
			gs.pool[id] = 0
	gs.level = 1          # Lv1 的商店以 1 費為主
	var saw_other := false
	for i in 30:
		gs.roll_shop()
		for e in gs.shop:
			if e != null and int(DB.units[e.id].cost) == 1 and e.id != "bat":
				saw_other = true
	_check(not saw_other, "卡池已抽乾的 1 費棋子仍然出現在商店")

	gs.pool["bat"] = 0
	gs.roll_shop()
	var one_cost := 0
	for e in gs.shop:
		if e != null and int(DB.units[e.id].cost) == 1:
			one_cost += 1
	_check(one_cost == 0, "所有 1 費棋子都抽乾了，商店卻還刷得出 1 費")


func _test_merge_reward() -> void:
	var gs := _fresh(3)
	gs.level = 3          # 讓「高一階」有東西可送
	for i in 3:
		gs.shop = [{"id": "bat", "star": 1}, null, null, null, null]
		gs.buy(0)
	var star := 0
	for inst in gs.bench:
		if inst != null and inst.id == "bat":
			star = int(inst.star)
	_check(star == 2, "3 張同名應該合成 2 星，實際星數 %d" % star)
	_check(gs.pending_reward.size() == 3,
			"升星應該送三選一的免費招募，實際給了 %d 個選項" % gs.pending_reward.size())
	var uniq: Dictionary = {}
	for id in gs.pending_reward:
		uniq[id] = true
	_check(uniq.size() == gs.pending_reward.size(), "三選一的選項不該重複")

	var pick: String = gs.pending_reward[0]
	var before := gs.pool_left(pick)
	gs.claim_merge_reward(pick)
	_check(gs.pending_reward.is_empty(), "領取之後三選一應該消失")
	_check(gs.pool_left(pick) == before - 1, "領取免費招募也要從卡池扣張數")

	gs.apply_result({"winner": 0, "player_alive": 1, "enemy_alive": 0, "ticks": 50})
	_check(gs.pending_reward.is_empty(), "打完一場之後，沒領的三選一應該失效")


## 商店預覽：買下並放上場之後，羈絆會變成什麼樣子
func _test_synergy_preview() -> void:
	var gs := _fresh(13)
	# 場上先放兩件文具（色鉛筆、尺）→ 再買第三件文具就該啟動 3 件效果
	gs.board = {Vector2i(1, 5): _inst("pencil"), Vector2i(2, 5): _inst("ruler")}
	var p := gs.preview_unit("compass")
	_check(int(p.school["from"]) == 2 and int(p.school["to"]) == 3,
			"文具應該從 2 變 3，實際 %d → %d" % [int(p.school["from"]), int(p.school["to"])])
	_check(int(p.school.tier_to) > int(p.school.tier_from), "第 3 件文具應該會啟動流派效果")
	_check(gs.would_upgrade("compass"), "would_upgrade 應該判定為會升一層")

	# 買已經在場上的同名棋子，不該讓羈絆件數增加
	var same := gs.preview_unit("pencil")
	_check(bool(same.already_on_board), "色鉛筆已在場上，應該被判定為 already_on_board")
	_check(int(same.school["from"]) == int(same.school["to"]),
			"場上已有同名時，羈絆件數不該增加")
	_check(not gs.would_upgrade("pencil"), "買場上已有的同名不該標示為會升一層")

	# 特徵要跨 2 個大流派才算數：場上只有文具時，再加一件文具的黏性仍然不算
	gs.board = {Vector2i(1, 5): _inst("glue")}          # 膠水：文具、黏性
	var sticky := gs.preview_unit("sticky_note")        # 便利貼：也是文具、也是黏性
	var tr: Dictionary = {}
	for t in sticky.traits:
		if t.name == "黏性":
			tr = t
	_check(not tr.is_empty(), "便利貼的預覽應該包含「黏性」特徵")
	_check(int(tr["to"]) == 2 and int(tr.schools_to) == 1,
			"兩件都是文具時，黏性件數到 2 但大流派只有 1")
	_check(int(tr.tier_to) == -1, "只來自 1 個大流派時，黏性不該被判定為啟動")

	# 換成食物的吐司（黏性）就跨流派了，應該啟動
	var toast := gs.preview_unit("toast")
	var tr2: Dictionary = {}
	for t in toast.traits:
		if t.name == "黏性":
			tr2 = t
	_check(int(tr2.schools_to) == 2 and int(tr2.tier_to) == 0,
			"膠水（文具）+ 吐司（食物）應該讓黏性跨 2 個大流派並啟動")
	print("商店的羈絆預覽計算正確（含「場上已有同名」與「需跨 2 大流派」兩種例外）")


func _test_refresh_escalates() -> void:
	var gs := _fresh(5)
	var costs: Array = []
	for i in 4:
		costs.append(gs.refresh_cost())
		gs.refresh_shop()
	_check(costs[0] < costs[1] and costs[1] < costs[2],
			"同一場戰鬥內刷新應該越來越貴，實際是 %s" % str(costs))
	gs.reset_refresh()
	_check(gs.refresh_cost() == costs[0],
			"打完一場戰鬥後刷新費用應該歸零回 %d，實際 %d" % [costs[0], gs.refresh_cost()])
	print("刷新費用序列：%s（每場戰鬥後歸零）" % str(costs))
