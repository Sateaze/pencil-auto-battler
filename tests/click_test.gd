extends SceneTree

const GameState = preload("res://scripts/game_state.gd")
## 回歸測試：載入真的 main.tscn，送出真的滑鼠事件。
## 曾經踩過的坑：
##   - set_anchors_preset() 只設錨點不設 offset，控制項維持 0×0，畫面正常但收不到點擊。
##   - 標題畫面是全螢幕且會吃掉滑鼠，一上線就讓整組測試失效。
##   - 測試自己抄了一份格子大小常數，地圖一改就對不上。現在一律跟畫面拿。
##
## 注意：**這個測試不能加 --headless**。headless 視窗固定 64×64，
## 點擊座標會落在視窗外造成假失敗。
## 執行：Godot_..._console.exe --path . --script tests/click_test.gd

var scene
var ex                      # ExploreScreen
var ms
var failures: Array = []


func _init() -> void:
	# 遊戲開局用 randi() 產生地圖；固定全域種子，每次測的才是同一張地圖，不會時好時壞
	seed(20261009)
	root.size = Vector2i(1280, 800)
	scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame

	# 遊戲會先停在標題畫面，它是全螢幕且會吃掉滑鼠，測試要先跳過它
	scene._show_explore()
	await process_frame
	ex = scene.explore
	ms = scene.ms
	_check(not scene.title.visible, "進入遊戲後標題畫面應該要收起來")
	_check(ex.size.x > 0.0 and ex.size.y > 0.0, "explore 尺寸是 0，不可能收到點擊")
	print("視窗 %s｜地圖 %d×%d｜起點 %s" % [str(root.size), ms.width, ms.height, str(ms.pos)])

	await _test_map_click()
	await _test_attack_click()
	await _test_shop_hover()
	await _test_synergy_preview()
	await _test_map_formation()
	await _test_foe_preview()
	await _test_board_click()
	_test_corpse_fades()
	await _test_boss_flow()          # 會讓天黑，要放最後

	if failures.is_empty():
		print("點擊測試通過 ✔")
	else:
		print("點擊測試失敗 ✘")
		for f in failures:
			print("  - %s" % f)
	quit(0 if failures.is_empty() else 1)


func _check(ok: bool, msg: String) -> void:
	if not ok:
		failures.append(msg)


## 格子在畫面上的位置，一律跟 ExploreScreen 拿，不要在測試裡自己算。
## 攝影機是平滑跟隨的，會在「算好座標」和「事件被處理」之間繼續移動，
## 所以先把它貼齊目標，點擊才對得準。
func _pixel(cell: Vector2i) -> Vector2:
	ex.cam = ex._cam_target()
	return ex.to_screen(Vector2(cell), ms.height_of(cell))


func _click(pos: Vector2) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = pos
		ev.global_position = pos
		root.push_input(ev)


# ── 地圖 ────────────────────────────────────────────────────

func _test_map_click() -> void:
	# 投影換算要能來回對上。只測「沒有被遮擋」的格子 —— 斜角視角下，
	# 前方比較高的格子本來就會蓋住後面格子的中心點，這時點到前面那格是正確的。
	var bad: Array = []
	var tested := 0
	for c in ms.discovered:
		if not _unoccluded(c):
			continue
		tested += 1
		var back: Vector2i = ex.pick_cell(_pixel(c))
		if back != c:
			bad.append("%s→%s" % [str(c), str(back)])
	_check(tested >= 20, "可測的無遮擋格子只有 %d 個，樣本太少" % tested)
	_check(bad.is_empty(), "斜角投影來回換算對不上：%s" % str(bad.slice(0, 6)))
	print("投影換算：%d 個無遮擋格子全部對上" % tested)

	var target := _walkable_target()
	_check(target.x >= 0, "找不到可以走過去的已探索格子")
	if target.x < 0:
		return
	var before = ms.pos
	var steps: int = ms.path_to(target).size()
	_click(_pixel(target))
	await process_frame
	await process_frame
	_check(ms.pos != before, "左鍵點地圖沒有讓鉛筆移動（忘了拿掉 --headless 會出現假失敗）")
	print("點 %s（%d 格）後移動到 %s" % [str(target), steps, str(ms.pos)])


## 前方幾格內沒有比它更高的格子，才不會被蓋住
func _unoccluded(c: Vector2i) -> bool:
	for dy in range(0, 5):
		for dx in range(0, 5):
			if dx == 0 and dy == 0:
				continue
			var f: Vector2i = c + Vector2i(dx, dy)
			if ms.in_bounds(f) and ms.height_of(f) > ms.height_of(c):
				return false
	return true


func _walkable_target() -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_len := 0
	for c in ms.discovered:
		if c == ms.pos or ms.is_blocked(c):
			continue
		var n: int = ms.path_to(c).size()
		if n > best_len and n <= 4:
			best_len = n
			best = c
	return best


func _test_attack_click() -> void:
	var fought := {"n": 0}
	ex.attack_requested.connect(func(_c): fought.n += 1)
	var adj: Array = ms.adjacent_monsters()
	if adj.is_empty():
		_walk_next_to_monster()
		adj = ms.adjacent_monsters()
	if adj.is_empty():
		_check(false, "走不到任何怪群旁邊，開打測試無法進行")
		return
	_click(_pixel(adj[0]))
	await process_frame
	_check(int(fought.n) == 1, "點相鄰的怪群沒有觸發戰鬥（實際觸發 %d 次）" % int(fought.n))
	print("點相鄰怪群會開打")


func _walk_next_to_monster() -> void:
	for i in 8:
		var best: Array = []
		for c in ms.cells:
			if not ms.has_monster(c) or not ms.discovered.has(c):
				continue
			for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
				var side: Vector2i = c + d
				if not ms.in_bounds(side) or ms.is_blocked(side):
					continue
				var path: Array = ms.path_to(side)
				if not path.is_empty() and (best.is_empty() or path.size() < best.size()):
					best = path
		if best.is_empty():
			return
		ms.walk(best)
		if not ms.adjacent_monsters().is_empty():
			return


# ── 整備畫面 ────────────────────────────────────────────────

func _test_shop_hover() -> void:
	scene._on_prep_requested()
	await process_frame
	var slot := -1
	for i in scene.shop_buttons.size():
		if scene.gs.shop[i] != null:
			slot = i
			break
	if slot < 0:
		_check(false, "商店是空的，無法測試懸停預覽")
		return
	var want: String = scene.DB.units[scene.gs.shop[slot].id].name
	scene.shop_buttons[slot].mouse_entered.emit()
	await process_frame
	_check(scene.info_label.text.begins_with(want),
			"懸停商店第 %d 格沒有顯示「%s」" % [slot, want])
	scene.shop_buttons[slot].mouse_exited.emit()
	await process_frame
	_check(not scene.info_label.text.begins_with(want), "滑鼠移開後預覽沒有收起來")
	_check("經驗" in scene.top_label.text or "最高等級" in scene.top_label.text,
			"整備畫面的頂欄沒有顯示經驗值")
	_check("經驗" in ex.top_label.text or "最高等級" in ex.top_label.text,
			"探索畫面的頂欄沒有顯示經驗值")
	print("商店懸停預覽正常（%s）" % want)


func _test_synergy_preview() -> void:
	scene.gs.board = {
		Vector2i(1, 5): {"uid": 90, "id": "pencil", "star": 1, "bonus_hp": 0.0},
		Vector2i(2, 5): {"uid": 91, "id": "ruler", "star": 1, "bonus_hp": 0.0},
	}
	scene.gs.shop[0] = {"id": "compass", "star": 1}
	scene.gs.mm = 99
	scene._refresh()
	await process_frame
	_check(scene.shop_buttons[0].text.begins_with("✦"),
			"會啟動羈絆的棋子沒有標 ✦：%s" % scene.shop_buttons[0].text.replace("\n", " / "))
	scene.shop_buttons[0].mouse_entered.emit()
	await process_frame
	var info: String = scene.info_label.text
	_check("放上場後" in info and "會啟動" in info,
			"懸停沒有顯示羈絆預覽：%s" % info.replace("\n", " / "))
	if "會啟動" in info:
		print("羈絆預覽正常：%s" % info.split("\n")[-2])


## 直接在地圖上佈陣：點棋子、點格子搬過去，而且陣形是相對位置
func _test_map_formation() -> void:
	scene._show_explore()
	await process_frame
	var from: Vector2i = GameState.FORMATION_FRONT    # 陣形最前排中間，對應玩家腳下那格
	var to := Vector2i(5, 5)
	scene.gs.board = {from: {"uid": 60, "id": "bat", "star": 1, "bonus_hp": 0.0}}
	ex.formation_mode = true
	ex.sel = null
	ex.refresh()
	await process_frame

	_check(ex.board_cell_of(ms.pos) == GameState.FORMATION_FRONT,
			"玩家腳下那格應該對應到陣形最前排中間，實際 %s" % str(ex.board_cell_of(ms.pos)))
	_check(ex.bench_buttons[0].visible, "佈陣模式下備戰席應該顯示出來")

	var before_pos = ms.pos
	_click(_pixel(ex.map_cell_of(from)))
	await process_frame
	_check(ex.sel != null and ex.sel.c == from,
			"點地圖上的棋子沒有選到它（實際 %s）" % str(ex.sel))
	_click(_pixel(ex.map_cell_of(to)))
	await process_frame
	_check(scene.gs.board.has(to) and not scene.gs.board.has(from),
			"棋子沒有搬到新的陣形位置（場上：%s）" % str(scene.gs.board.keys()))
	_check(ms.pos == before_pos, "佈陣模式下點地圖不該讓鉛筆移動")

	# 陣形是相對位置：走到別的地方，陣形內容不該改變
	var snapshot := str(scene.gs.board.keys())
	var step := _walkable_target()
	ex.formation_mode = false
	if step.x >= 0:
		ms.walk(ms.path_to(step))
		_check(str(scene.gs.board.keys()) == snapshot,
				"走動之後陣形被改掉了：%s → %s" % [snapshot, str(scene.gs.board.keys())])
		_check(ex.map_cell_of(to) == GameState.formation_to_map(to, ms.pos, ms.formation_facing()),
				"陣形沒有跟著玩家移動")
	# 佈陣時要看得到棋子數據。
	# 上面走路時可能經過家人佔用的房間、棋子被「收走」，所以這裡重新放一件確定存在的。
	scene.gs.board = {to: {"uid": 61, "id": "bat", "star": 1, "bonus_hp": 0.0}}
	ex.formation_mode = true
	ex._hover_loc({"t": "board", "c": to})
	await process_frame
	var info: String = ex.cell_label.text
	_check(info.begins_with("球棒"), "佈陣時滑鼠移到棋子上沒有顯示它的資訊：%s" % info.split("\n")[0])
	_check("生命" in info and "攻擊" in info, "佈陣時的棋子資訊缺少數值：%s" % info.replace("\n", " / "))
	_check("放上場後" in info, "佈陣時的棋子資訊缺少羈絆預覽")
	_check(ex.syn_label.visible and "運動用品" in ex.syn_label.text,
			"佈陣時沒有顯示目前的羈絆：%s" % ex.syn_label.text.replace("\n", " / "))
	ex._hover_loc(null)
	ex.formation_mode = false
	ex.sel = null
	print("地圖上佈陣正常（可看數據、羈絆；陣形是相對位置會跟著走）")


## 佈陣時畫出來的敵人分佈，必須和真的開打時一模一樣，不然預覽等於在騙人
func _test_foe_preview() -> void:
	scene._show_explore()
	await process_frame
	_walk_next_to_monster()
	var adj: Array = ms.adjacent_monsters()
	if adj.is_empty():
		_check(false, "走不到怪群旁邊，敵人預覽測試無法進行")
		return
	scene.gs.board = {
		Vector2i(3, 6): {"uid": 41, "id": "bat", "star": 1, "bonus_hp": 0.0},
		Vector2i(2, 5): {"uid": 42, "id": "pencil", "star": 1, "bonus_hp": 0.0},
	}
	ex.formation_mode = true
	ex.refresh()
	await process_frame
	_check(not ex.foe_preview.is_empty(), "佈陣時沒有預覽出敵人分佈")
	var want: Array = []
	for f in ex.foe_preview:
		want.append("%s@%s" % [f.id, str(f.cell)])
	want.sort()

	ex.formation_mode = false
	scene._on_attack_requested(adj[0])
	await process_frame
	_check(scene.explore.battle != null, "就地開打沒有啟動")
	if scene.explore.battle == null:
		return
	# 曾經的 bug：表演模組要等第一次繪製才拿到戰鬥，開打第一幀就讀到空值當掉
	_check(scene.explore.fx.sim == scene.explore.battle, "開打後表演模組沒有立刻拿到這場戰鬥")
	# 用第 0 幀的位置，因為 units 的 cell 在模擬跑完後已經變了
	var origin: Vector2i = scene.explore.battle_origin
	var first: Array = scene.explore.battle.frames[0]
	var got: Array = []
	for k in scene.explore.battle.units.size():
		var u: Dictionary = scene.explore.battle.units[k]
		if int(u.team) != 1:
			continue
		got.append("%s@%s" % [u.id, str(Vector2i(first[k][0], first[k][1]) + origin)])
	got.sort()
	_check(want == got, "預覽的敵人位置和實際開打對不上\n預覽=%s\n實際=%s" % [
			str(want.slice(0, 5)), str(got.slice(0, 5))])
	if want == got:
		print("敵人預覽和實際開打完全一致（%d 隻）" % want.size())
	scene._finish_field_battle()
	await process_frame


func _test_board_click() -> void:
	scene._on_prep_requested()        # 棋盤在整備畫面上，要先切回去才點得到
	await process_frame
	var bv = scene.board_view
	var bad: Array = []
	for gy in 8:
		for gx in 8:
			var back: Vector2i = bv.cell_from_point(bv.cell_center(Vector2(gx, gy)))
			if back != Vector2i(gx, gy):
				bad.append("(%d,%d)→(%d,%d)" % [gx, gy, back.x, back.y])
	_check(bad.is_empty(), "棋盤的等距投影來回換算對不上：%s" % str(bad))

	scene.gs.board = {Vector2i(3, 5): {"uid": 70, "id": "bat", "star": 1, "bonus_hp": 0.0}}
	scene._refresh()
	await process_frame
	_click(bv.position + bv.cell_center(Vector2(3, 5)) - Vector2(0, bv.LIFT))
	await process_frame
	var sel = scene.selected
	_check(sel != null and sel.t == "board" and sel.c == Vector2i(3, 5),
			"點斜角棋盤上的棋子沒有選到 (3,5)，實際 %s" % str(sel))
	if sel != null and sel.c == Vector2i(3, 5):
		print("斜角棋盤的點擊對位正常")


## 最後一隻敵人死掉後，屍體要淡出消失，不能定格留在畫面上（戰鬥表演是共用的 BattleFx）
func _test_corpse_fades() -> void:
	var BattleSim = load("res://scripts/sim/battle_sim.gd")
	var BattleFx = load("res://scripts/battle_fx.gd")
	var hero := {"id": "calculator", "name": "計算機", "school": "文具", "traits": [], "star": 3,
			"smult": 3.24, "hp": 3000.0, "atk": 400.0, "aspd": 1.0, "range": 3, "move": 1.0,
			"armor": 0, "skill": {}, "cell": Vector2i(3, 6), "fx": {}}
	var foe := {"id": "dust", "name": "灰塵團", "school": "害蟲", "traits": [], "star": 1,
			"smult": 1.0, "hp": 60.0, "atk": 1.0, "aspd": 0.5, "range": 1, "move": 1.0,
			"armor": 0, "skill": {}, "cell": Vector2i(3, 3), "fx": {}}
	var s = BattleSim.new()
	s.setup(3, [hero], [foe])
	var res: Dictionary = s.run()
	var fx = BattleFx.new()
	fx.set_sim(s)
	fx.tick_f = float(s.frames.size() - 1)          # 剛好停在最後一隻死掉的瞬間
	var at_death := 0
	for it in fx.gather():
		if int(it.team) == 1:
			at_death += 1
	fx.tick_f = fx.end_tick()                         # 播放結束（含淡出）
	var remains := 0
	for it in fx.gather():
		if int(it.team) == 1:
			remains += 1
	_check(int(res.winner) == 0, "測試前提沒成立：這場應該要打贏")
	_check(at_death == 1, "死掉的瞬間應該還看得到牠在淡出（實際 %d 隻）" % at_death)
	_check(remains == 0, "播放結束後還有 %d 隻敵人屍體留在畫面上" % remains)
	if remains == 0 and at_death == 1:
		print("最後一隻敵人會淡出，播完後消失")


## 天黑之後：趕到巢穴，在大地圖上打決戰的一波
func _test_boss_flow() -> void:
	scene._show_explore()
	await process_frame
	scene.gs.board = {Vector2i(3, 6): {"uid": 7, "id": "calculator", "star": 3, "bonus_hp": 0.0},
			Vector2i(2, 5): {"uid": 8, "id": "fridge", "star": 3, "bonus_hp": 0.0}}
	ms.seg = 2
	ms.time_left = 0.0
	ms.advance_segment()                              # 晚上結束 → 天黑
	_check(ms.day_over, "時段用完之後應該天黑")
	scene._on_day_finished()
	await process_frame
	_check(scene.boss_active and ex.boss_mode, "天黑之後應該進入最終決戰")
	_check(maxi(absi(ms.pos.x - ms.lair.x), absi(ms.pos.y - ms.lair.y)) <= 4,
			"天黑後應該被帶到巢穴附近（玩家 %s，巢穴 %s）" % [str(ms.pos), str(ms.lair)])
	_check(ms.discovered.has(ms.lair), "到了巢穴應該要看得到它")
	_check(ex.btn_boss.visible and "第 1 波" in ex.btn_boss.text,
			"決戰時應該有「開打第 1 波」按鈕：%s" % ex.btn_boss.text)

	# 決戰時不能再移動
	var before = ms.pos
	var away: Vector2i = ms.pos + Vector2i(1, 0)
	if ms.in_bounds(away) and not ms.is_blocked(away):
		_click(_pixel(away))
		await process_frame
		_check(ms.pos == before, "決戰中點地圖不該讓鉛筆移動")

	# 佈陣預覽要預覽的是下一波魔王軍
	ex.formation_mode = true
	ex.refresh()
	_check(not ex.foe_preview.is_empty() and "決戰第 1 波" in ex.preview_label,
			"決戰時佈陣應該預覽下一波魔王軍（%s）" % ex.preview_label)
	ex.formation_mode = false

	scene._on_boss_fight()
	await process_frame
	_check(scene.phase == "field" and ex.battle != null, "按開打後應該在大地圖上打決戰")
	var wave_before: int = scene.gs.wave
	var life_before: int = scene.gs.life
	scene._finish_field_battle()
	await process_frame
	_check(scene.gs.wave > wave_before or scene.gs.state != "playing" or scene.gs.life < life_before,
			"打完一波之後，波數、生命或勝負應該要有變化")
	print("決戰流程正常：天黑後到巢穴（%s），在大地圖上打完第 %d 波" % [str(ms.lair), wave_before])
