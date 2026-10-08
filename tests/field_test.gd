extends SceneTree
## 就地開打（階段三）的測試：戰鬥直接發生在大地圖上。
##   - 從地圖切出來的戰場要帶著當地的家具（障礙）與高度
##   - 我方以玩家所在格為中心展開陣形，敵人在怪群那邊
##   - 沒有人會站在牆裡或疊在一起
##   - 戰鬥時間不再受 40 秒上限限制
## 執行：Godot --headless --path . --script tests/field_test.gd

const DB = preload("res://scripts/db.gd")
const GameState = preload("res://scripts/game_state.gd")
const MapState = preload("res://scripts/map_state.gd")
const BattleSim = preload("res://scripts/sim/battle_sim.gd")

var failures: Array = []


func _init() -> void:
	DB.load_all()
	_run()
	if failures.is_empty():
		print("就地開打測試全部通過 ✔")
	else:
		print("就地開打測試失敗 ✘")
		for f in failures:
			print("  - %s" % f)
	quit(0 if failures.is_empty() else 1)


func _check(ok: bool, msg: String) -> void:
	if not ok:
		failures.append(msg)


func _run() -> void:
	var gs := GameState.new()
	gs.start_new(31)
	var ms := MapState.new()
	ms.start(31, gs)

	# 擺一個陣形：前排兩件、後排兩件
	gs.mm = 999
	var ids := ["bat", "sofa", "pencil", "ruler"]
	var slots := [Vector2i(2, 5), Vector2i(4, 5), Vector2i(2, 7), Vector2i(4, 7)]
	for i in ids.size():
		gs.board[slots[i]] = {"uid": i + 1, "id": ids[i], "star": 1, "bonus_hp": 0.0}

	var cell := _walk_next_to_monster(ms)
	_check(cell.x >= 0, "走不到任何怪群旁邊，測試無法進行")
	if cell.x < 0:
		return

	var arena := ms.build_arena(cell)
	var origin: Vector2i = arena.origin
	_check(int(arena.w) > 0 and int(arena.h) > 0, "切出來的戰場是空的")

	# 戰場要帶著地圖上的家具與高度
	var wall_count := 0
	var height_ok := true
	for y in int(arena.h):
		for x in int(arena.w):
			var local := Vector2i(x, y)
			var m: Vector2i = origin + local
			if ms.is_wall(m):
				wall_count += 1
				if not (local in arena.blocked):
					_check(false, "地圖上的家具 %s 沒有變成戰場障礙" % str(m))
			if int(arena.height[local]) != ms.height_of(m):
				height_ok = false
	_check(height_ok, "戰場的高度沒有照抄地圖")
	print("戰場 %d×%d，帶進 %d 格家具障礙" % [int(arena.w), int(arena.h), wall_count])

	var dep: Dictionary = ms.deploy(cell, ms.encounter_groups(cell))
	var allies: Array = dep.allies
	var foes: Array = dep.foes
	_test_front_line(dep, ms.pos - origin, dep.facing)
	_check(allies.size() == gs.board.size(),
			"陣形有 %d 件，只展開了 %d 件" % [gs.board.size(), allies.size()])
	_check(foes.size() > 0, "敵人一個都沒放出來")

	var blocks: Dictionary = {}
	for b in arena.blocked:
		blocks[b] = true
	var seen: Dictionary = {}
	for d in allies + foes:
		var c: Vector2i = d.cell
		_check(c.x >= 0 and c.y >= 0 and c.x < int(arena.w) and c.y < int(arena.h),
				"%s 被放到戰場外面 %s" % [d.name, str(c)])
		_check(not blocks.has(c), "%s 被放進家具裡 %s" % [d.name, str(c)])
		_check(not seen.has(c), "%s 和別人疊在同一格 %s" % [d.name, str(c)])
		seen[c] = true

	# 我方要在玩家附近，敵人要在怪群附近
	var me: Vector2i = ms.pos - origin
	var them: Vector2i = cell - origin
	for d in allies:
		_check(_d(d.cell, me) <= _d(d.cell, them) + 2,
				"%s 展開的位置離玩家太遠（在 %s，玩家在 %s）" % [d.name, str(d.cell), str(me)])
	var far := 0
	for d in foes:
		if _d(d.cell, them) > 5:
			far += 1
	_check(far == 0, "有 %d 隻敵人離怪群格太遠" % far)

	_test_preview_matches(gs, ms, cell)

	var sim := BattleSim.new()
	sim.setup(7, allies, foes, ms.battle_terrain_fx(), arena)
	_check(sim.aw == int(arena.w) and sim.ah == int(arena.h), "模擬沒有套用戰場大小")
	_check(sim.max_ticks > BattleSim.MAX_TICKS,
			"就地開打應該放寬時間上限（實際 %d，預設 %d）" % [sim.max_ticks, BattleSim.MAX_TICKS])
	var res: Dictionary = sim.run()
	_check(not sim.frames.is_empty(), "戰鬥沒有產生任何畫面")
	print("在 %s 的「%s」開打：%d 對 %d，打了 %.1f 秒，贏=%s" % [
			ms.room_at.get(cell, "？"), ms.cell_at(cell).label,
			allies.size(), foes.size(), float(res.ticks) * 0.1, res.winner == 0])

	_test_end_field_battle(gs, ms)


## 就地開打的結算：時間不重複扣、打完拿獎勵、播到一半時間用完不能白拿獎勵
func _test_end_field_battle(gs: GameState, ms: MapState) -> void:
	var cell := _walk_next_to_monster(ms)
	if cell.x < 0:
		_check(false, "找不到第二群怪來測結算")
		return

	# 時間在戰鬥播到一半就用完 → 被打斷：沒有獎勵、怪群還在
	var cut: Dictionary = ms.begin_field_battle(cell)
	var mm_before: int = gs.mm
	var hp_before: int = ms.hp
	var outcome: String = ms.end_field_battle(cut, float(cut.seconds) * 0.3, false)
	_check(outcome == "interrupted",
			"播到三成時間就用完，應該判成被打斷，實際是 %s" % outcome)
	_check(gs.mm == mm_before, "被打斷的戰鬥不該給筆芯（%d → %d）" % [mm_before, gs.mm])
	_check(ms.hp == hp_before, "被打斷的戰鬥不該扣血")
	_check(ms.has_monster(cell), "被打斷之後怪群應該還在")

	# 完整打完：時間不該在結算時再扣一次；打贏要清掉怪群
	var full: Dictionary = ms.begin_field_battle(cell)
	var t_before := ms.time_left
	outcome = ms.end_field_battle(full, float(full.seconds), false)
	_check(is_equal_approx(ms.time_left, t_before) or ms.seg > 0,
			"就地開打不該在結算時再扣時間（%.1f → %.1f）" % [t_before, ms.time_left])
	if outcome == "win":
		_check(not ms.has_monster(cell), "打贏了但怪群格沒有被清掉")
	print("結算規則正確：播到一半被打斷不給獎勵，完整打完 → %s" % outcome)


## 佈陣時的敵人預覽，必須和真的開打時的位置一模一樣。
## 整條佈陣流程不能用亂數，否則預覽會騙人 —— 這個測試就是為了擋住那種改動。
func _test_preview_matches(gs: GameState, ms: MapState, cell: Vector2i) -> void:
	var placements: Array = []
	for pass_i in 2:
		var dep: Dictionary = ms.deploy(cell, ms.encounter_groups(cell))
		var out: Array = []
		for d in dep.foes:
			out.append("%s@%s" % [d.id, str(Vector2i(d.cell) + Vector2i(dep.arena.origin))])
		placements.append(out)
	_check(placements[0] == placements[1],
			"同樣條件算兩次，敵人位置不一樣 —— 預覽會和實際開打對不上\nA=%s\nB=%s" % [
				str(placements[0].slice(0, 4)), str(placements[1].slice(0, 4))])
	_check(not placements[0].is_empty(), "預覽算不出任何敵人位置")
	print("敵人預覽可重現：%d 隻，位置完全一致" % placements[0].size())


## 兩邊要有一條清楚的前線：沿著「玩家 → 怪群」的方向，所有我方都在所有敵人的後面。
## （回報過的問題：陣形以玩家為中心展開，跟只隔一格的怪群範圍重疊，兩邊交錯站。）
func _test_front_line(dep: Dictionary, me: Vector2i, facing: Vector2i) -> void:
	var ally_front := -999
	var foe_back := 999
	for a in dep.allies:
		var p: int = (a.cell.x - me.x) * facing.x + (a.cell.y - me.y) * facing.y
		ally_front = maxi(ally_front, p)
	for f in dep.foes:
		var q: int = (f.cell.x - me.x) * facing.x + (f.cell.y - me.y) * facing.y
		foe_back = mini(foe_back, q)
	_check(ally_front < foe_back,
			"我方和敵人交錯站：我方最前到 %d，敵人最後到 %d（沿面向 %s 量）" % [
				ally_front, foe_back, str(facing)])
	if ally_front < foe_back:
		print("前線清楚：我方最前在第 %d 格、敵人最後在第 %d 格（面向 %s）" % [
				ally_front, foe_back, str(facing)])

	# 佈陣畫面的換算要和展開一致：陣形格 → 地圖 → 陣形格要能來回
	for f in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		for by in range(GameState.PLAYER_Y_MIN, 8):
			for bx in 8:
				var b := Vector2i(bx, by)
				var m := GameState.formation_to_map(b, Vector2i(10, 10), f)
				_check(GameState.map_to_formation(m, Vector2i(10, 10), f) == b,
						"陣形換算來回對不上：%s（面向 %s）" % [str(b), str(f)])
				# 後排一定在玩家身後（沿面向量 ≤ 0）
				var back: int = (m.x - 10) * f.x + (m.y - 10) * f.y
				_check(back <= 0, "陣形有格子跑到玩家前面去了：%s → %s（面向 %s）" % [str(b), str(m), str(f)])
		_check(GameState.formation_to_map(GameState.FORMATION_FRONT, Vector2i(10, 10), f) == Vector2i(10, 10),
				"陣形最前排的中間應該對到玩家站的格子（面向 %s）" % str(f))


func _d(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


func _walk_next_to_monster(ms: MapState) -> Vector2i:
	for i in 12:
		var best: Array = []
		var best_cell := Vector2i(-1, -1)
		for c in ms.cells:
			if not ms.has_monster(c):
				continue
			for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
				var side: Vector2i = c + d
				if not ms.in_bounds(side) or ms.is_blocked(side):
					continue
				var path: Array = ms.path_to(side)
				if path.is_empty() and side != ms.pos:
					continue
				if best_cell.x < 0 or path.size() < best.size():
					best = path
					best_cell = c
		if best_cell.x < 0:
			return Vector2i(-1, -1)
		if best.is_empty():
			return best_cell
		ms.walk(best)
		var adj: Array = ms.adjacent_monsters()
		if not adj.is_empty():
			return adj[0]
	return Vector2i(-1, -1)
