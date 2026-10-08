extends SceneTree
## 戰場一般化的測試：戰鬥模擬不再寫死 8×8，而是可以指定大小、障礙物與高度。
## 這是「直接在大地圖上開打」的前提，所以先把規則釘住。
## 執行：Godot --headless --path . --script tests/arena_test.gd

const DB = preload("res://scripts/db.gd")
const BattleSim = preload("res://scripts/sim/battle_sim.gd")

var failures: Array = []


func _init() -> void:
	DB.load_all()
	_test_custom_size()
	_test_blocked_cells()
	_test_high_ground_range()
	_test_climb_is_slower()
	_test_default_is_unchanged()
	if failures.is_empty():
		print("戰場一般化測試全部通過 ✔")
	else:
		print("戰場一般化測試失敗 ✘")
		for f in failures:
			print("  - %s" % f)
	quit(0 if failures.is_empty() else 1)


func _check(ok: bool, msg: String) -> void:
	if not ok:
		failures.append(msg)


func _unit(id: String, cell: Vector2i, hp := 0.0) -> Dictionary:
	var d: Dictionary = DB.units[id]
	return {
		"id": id, "name": d.name, "school": d.school, "traits": d.traits,
		"star": 1, "smult": 1.0, "hp": hp if hp > 0.0 else float(d.hp),
		"atk": float(d.atk), "aspd": d.aspd, "range": d.range, "move": d.move,
		"armor": d.armor, "skill": d.get("skill", {}), "cell": cell, "fx": {},
	}


func _dummy(cell: Vector2i, hp := 3000.0) -> Dictionary:
	return {
		"id": "dust", "name": "沙包", "school": "害蟲", "traits": [], "star": 1, "smult": 1.0,
		"hp": hp, "atk": 1.0, "aspd": 0.4, "range": 1, "move": 0.8, "armor": 0,
		"skill": {}, "cell": cell, "fx": {},
	}


func _test_custom_size() -> void:
	var s := BattleSim.new()
	s.setup(1, [_unit("bat", Vector2i(1, 9))], [_dummy(Vector2i(1, 0))],
			{}, {"w": 4, "h": 12})
	_check(s.aw == 4 and s.ah == 12, "戰場大小沒有套用，實際 %d×%d" % [s.aw, s.ah])
	s.run()
	var moved := false
	for u in s.units:
		if u.team == 0 and u.cell != Vector2i(1, 9):
			moved = true
		_check(u.cell.x < 4 and u.cell.y < 12, "有棋子跑到 4×12 戰場外面：%s" % str(u.cell))
	_check(moved, "在細長戰場上近戰應該要移動過去")


func _test_blocked_cells() -> void:
	# 用一道牆把近戰和目標隔開，只留最右邊一個缺口
	var wall: Array = []
	for x in 7:
		wall.append(Vector2i(x, 4))
	# 沙包幾乎不動，否則牠也會走到缺口來會合，就測不出「英雄有沒有繞路」
	var target := _dummy(Vector2i(0, 0))
	target.move = 0.05
	var s := BattleSim.new()
	s.setup(2, [_unit("bat", Vector2i(0, 7))], [target], {}, {"blocked": wall})
	s.run()
	var hero: Dictionary = s.units[0]
	var foe: Dictionary = s.units[1]
	for c in wall:
		_check(hero.cell != c, "棋子走進了障礙物格 %s" % str(c))
	var d: int = maxi(absi(hero.cell.x - foe.cell.x), absi(hero.cell.y - foe.cell.y))
	_check(d <= 1, "棋子應該繞過牆上的缺口貼到目標旁邊，實際停在 %s（目標在 %s）" % [
			str(hero.cell), str(foe.cell)])


func _test_high_ground_range() -> void:
	# 射程 3 的色鉛筆，跟目標相距 4 格：平地打不到，站高地就打得到
	var flat := BattleSim.new()
	flat.setup(3, [_unit("pencil", Vector2i(0, 4))], [_dummy(Vector2i(0, 0), 99999.0)], {},
			{"blocked": _ring_around(Vector2i(0, 4))})
	flat.run()
	var high := BattleSim.new()
	high.setup(3, [_unit("pencil", Vector2i(0, 4))], [_dummy(Vector2i(0, 0), 99999.0)], {},
			{"blocked": _ring_around(Vector2i(0, 4)), "height": {Vector2i(0, 4): 2}})
	high.run()
	var flat_hits := _count_hits(flat)
	var high_hits := _count_hits(high)
	_check(flat_hits == 0, "平地、距離 4 格、射程 3，不該打得到（實際打了 %d 次）" % flat_hits)
	_check(high_hits > 0, "站在高地射程 +1 應該就打得到了（實際打了 %d 次）" % high_hits)


## 把某格圍起來，讓棋子動不了，才能單純測射程
func _ring_around(c: Vector2i) -> Array:
	var out: Array = []
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx != 0 or dy != 0:
				out.append(c + Vector2i(dx, dy))
	return out


func _count_hits(s) -> int:
	var n := 0
	for e in s.events:
		if e.type == "hit" and e.src == 0:
			n += 1
	return n


func _test_climb_is_slower() -> void:
	var heights: Dictionary = {}
	for y in 8:
		for x in 8:
			if y < 4:
				heights[Vector2i(x, y)] = 2
	var flat := BattleSim.new()
	flat.setup(5, [_unit("bat", Vector2i(3, 7))], [_dummy(Vector2i(3, 0))], {})
	flat.run()
	var hill := BattleSim.new()
	hill.setup(5, [_unit("bat", Vector2i(3, 7))], [_dummy(Vector2i(3, 0))], {}, {"height": heights})
	hill.run()
	_check(_first_hit_tick(hill) >= _first_hit_tick(flat),
			"爬坡應該比走平地慢才對（平地第 %d tick 接敵、爬坡第 %d tick）" % [
				_first_hit_tick(flat), _first_hit_tick(hill)])


func _first_hit_tick(s) -> int:
	for e in s.events:
		if e.type == "hit" and e.src == 0:
			return int(e.t)
	return 9999


## 不指定 arena 時，行為要跟以前一模一樣，免得舊的戰鬥被改壞
func _test_default_is_unchanged() -> void:
	var s := BattleSim.new()
	s.setup(9, [_unit("bat", Vector2i(3, 6)), _unit("pencil", Vector2i(2, 7))],
			[_dummy(Vector2i(3, 1)), _dummy(Vector2i(4, 1))])
	var res: Dictionary = s.run()
	_check(s.aw == BattleSim.W and s.ah == BattleSim.H, "預設戰場應該還是 8×8")
	_check(s.blocked.is_empty(), "預設戰場不該有障礙物")
	_check(int(res.ticks) > 0 and not s.frames.is_empty(), "預設戰場跑不起來")
