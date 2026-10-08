extends SceneTree
## 讓每一件物品都實際放一次技能，確保新加的技能類型不會在執行期炸掉。
## 也檢查特徵（冰冷、高溫…）在湊齊條件時真的會產生效果。
## 執行：Godot --headless --path . --script tests/skills_test.gd

const DB = preload("res://scripts/db.gd")
const GameState = preload("res://scripts/game_state.gd")
const BattleSim = preload("res://scripts/sim/battle_sim.gd")


func _init() -> void:
	DB.load_all()
	# 腳本編譯失敗時 Godot 不會中止，測試會假裝通過，所以先確認東西真的建得起來
	assert(DB.units.size() > 0 and DB.traits.size() > 0, "資料沒載進來")
	assert(BattleSim.new() != null, "BattleSim 建立失敗（多半是 battle_sim.gd 編譯錯誤）")
	assert(GameState.new() != null, "GameState 建立失敗")
	_test_every_skill_casts()
	_test_trait_rules()
	_test_trait_effects()
	print("技能與特徵測試全部通過")
	quit()


## 耐打但傷害很低的沙包，讓受測棋子一定有時間把能量集滿
func _dummies(count: int) -> Array:
	var out: Array = []
	for i in count:
		out.append({
			"name": "沙包%d" % i, "school": "害蟲", "traits": [], "star": 1, "smult": 1.0,
			"hp": 4000.0, "atk": 3.0, "aspd": 0.5, "range": 1, "move": 0.6, "armor": 0,
			"skill": {}, "cell": Vector2i(2 + i, 2), "fx": {},
		})
	return out


func _desc(id: String, cell: Vector2i, fx: Dictionary = {}) -> Dictionary:
	var def: Dictionary = DB.units[id]
	return {
		"name": def.name, "school": def.school, "traits": def.traits, "star": 1, "smult": 1.0,
		"hp": float(def.hp), "atk": float(def.atk), "aspd": def.aspd, "range": def.range,
		"move": def.move, "armor": def.armor, "skill": def.get("skill", {}),
		"revive_pct": def.get("revive_pct", 0), "cell": cell, "fx": fx,
	}


func _test_every_skill_casts() -> void:
	var missing: Array = []
	var seen_types: Dictionary = {}
	for id in DB.units:
		var sim := BattleSim.new()
		# 受測棋子 + 一個肉盾，確保它活得夠久把能量集滿
		var team: Array = [_desc(id, Vector2i(3, 6)), _desc("sofa", Vector2i(3, 4))]
		if id == "sofa":
			team = [_desc(id, Vector2i(3, 6)), _desc("potato", Vector2i(3, 4))]
		sim.setup(7, team, _dummies(3))
		sim.run()
		assert(not sim.frames.is_empty(), "%s 的戰鬥沒有產生任何畫面" % id)
		var cast := false
		for e in sim.events:
			if e.type == "cast" and e.src == 0:
				cast = true
				break
		if cast:
			seen_types[DB.units[id].skill.type] = true
		else:
			missing.append(DB.units[id].name)
	assert(missing.is_empty(), "這些物品整場都沒放出技能，可能是能量或目標判定有問題：%s" % str(missing))
	assert(seen_types.size() >= 10, "涵蓋到的技能類型太少（%d），測試可能根本沒跑起來" % seen_types.size())
	print("每件物品都成功施放技能；涵蓋技能類型 %d 種：%s" % [seen_types.size(), str(seen_types.keys())])


## 特徵必須來自至少 2 個不同大流派才算數
func _test_trait_rules() -> void:
	var gs := GameState.new()
	gs.start_new(3)
	# 冰箱 + 冷氣：都是冰冷，但同屬家具家電 → 不該啟動
	gs.board = {Vector2i(1, 5): _inst("fridge"), Vector2i(2, 5): _inst("aircon")}
	var t := gs.trait_synergies()
	assert(t.has("冰冷") and int(t["冰冷"].count) == 2, "冰冷應該算到 2 件")
	assert(int(t["冰冷"].tier) == -1, "同一個大流派的 2 件不該觸發特徵")
	# 換成冰箱（家具家電）+ 挫冰（食物）→ 跨流派，應該啟動
	gs.board = {Vector2i(1, 5): _inst("fridge"), Vector2i(2, 5): _inst("shavedice")}
	t = gs.trait_synergies()
	assert(int(t["冰冷"].tier) == 0, "跨 2 個大流派的 2 件冰冷應該觸發第一階")
	assert(float(t["冰冷"].fx.slow_pct) > 0.0, "冰冷第一階應該要有減速效果")
	print("特徵的「需跨 2 個大流派」規則正確")


## 冰冷要真的減速、高溫要真的造成持續傷害
func _test_trait_effects() -> void:
	var cold := {"slow_pct": 20.0}
	var plain := BattleSim.new()
	plain.setup(11, [_desc("fridge", Vector2i(3, 6))], _dummies(1))
	plain.run()
	var chilled := BattleSim.new()
	chilled.setup(11, [_desc("fridge", Vector2i(3, 6), cold)], _dummies(1))
	chilled.run()
	var dummy_moves_plain := _moves_of(plain, 1)
	var dummy_moves_cold := _moves_of(chilled, 1)
	assert(dummy_moves_cold <= dummy_moves_plain,
			"被冰冷減速後，敵人移動次數不該比沒減速時多（%d vs %d）" % [dummy_moves_cold, dummy_moves_plain])

	var burn := BattleSim.new()
	burn.setup(11, [_desc("chili", Vector2i(3, 6), {"burn_pct": 2.0, "burn_max": 3})], _dummies(1))
	burn.run()
	var burned := false
	for u in burn.units:
		if u.team == 1 and int(u.burn_stacks) > 0:
			burned = true
	assert(burned, "高溫特徵沒有在敵人身上疊出灼燒層數")
	print("冰冷的減速與高溫的灼燒都有實際作用")


func _moves_of(sim: BattleSim, unit_index: int) -> int:
	var moves := 0
	var last: Array = []
	for f in sim.frames:
		var cur: Array = [f[unit_index][0], f[unit_index][1]]
		if not last.is_empty() and cur != last:
			moves += 1
		last = cur
	return moves


func _inst(id: String) -> Dictionary:
	return {"uid": 1, "id": id, "star": 1, "bonus_hp": 0.0}
