extends RefCounted
## 資料庫：從 data/*.json 載入物品、流派、敵人、波次。全部靜態存取。

static var units: Dictionary = {}       # id -> unit def
static var enemies: Dictionary = {}     # id -> enemy def
static var schools: Dictionary = {}     # school name -> {color, role, tiers}
static var waves: Array = []
static var boss_waves: Array = []
static var terrain: Dictionary = {}     # terrain name -> {mark, color, desc, fx}
static var traits: Dictionary = {}      # trait name -> {role, tiers}
static var map: Dictionary = {}         # 探索地圖佈局
static var by_cost: Dictionary = {}     # cost(int) -> Array of unit ids
static var _loaded := false


static func load_all() -> void:
	if _loaded:
		return
	for u in _read("res://data/units.json"):
		units[u.id] = u
		var c := int(u.cost)
		if not by_cost.has(c):
			by_cost[c] = []
		by_cost[c].append(u.id)
	for e in _read("res://data/enemies.json"):
		enemies[e.id] = e
	schools = _read("res://data/schools.json")
	waves = _read("res://data/waves.json")
	boss_waves = _read("res://data/boss_waves.json")
	terrain = _read("res://data/terrain.json")
	map = _read("res://data/map.json")
	var trait_data: Dictionary = _read("res://data/traits.json")
	for key in trait_data:
		if not key.begins_with("_"):      # _rule 之類的說明欄位不是特徵
			traits[key] = trait_data[key]
	_loaded = true


static func terrain_fx(name: String) -> Dictionary:
	return terrain[name].fx if terrain.has(name) else {}


static func _read(path: String):
	var text := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(text)
	assert(data != null, "JSON 解析失敗：" + path)
	return data


static func school_color(school: String) -> Color:
	if schools.has(school):
		return Color(schools[school].color)
	return Color.GRAY


static func skill_desc(skill: Dictionary) -> String:
	if skill.is_empty():
		return "（無技能）"
	match skill.type:
		"single_burst":
			return "%s：對目標造成 %.1f 倍攻擊傷害" % [skill.name, skill.mult]
		"aoe_damage":
			return "%s：目標周圍 %d 格內敵人受 %.1f 倍攻擊傷害" % [skill.name, skill.radius, skill.mult]
		"aoe_slow":
			return "%s：周圍 %d 格 %.1f 倍傷害，並讓敵人移速 −%d%%，持續 %.0f 秒" % [
					skill.name, skill.radius, skill.mult, skill.slow_pct, skill.duration]
		"freeze_aoe":
			return "%s：周圍 %d 格 %.1f 倍傷害並凍結 %.1f 秒" % [skill.name, skill.radius, skill.mult, skill.duration]
		"blind":
			return "%s：周圍 %d 格 %.1f 倍傷害，敵人 %d%% 機率落空，持續 %.0f 秒" % [
					skill.name, skill.radius, skill.mult, skill.miss_pct, skill.duration]
		"knockback":
			return "%s：周圍 %d 格 %.1f 倍傷害並擊退 %d 格" % [skill.name, skill.radius, skill.mult, skill.push]
		"mark":
			return "%s：%.1f 倍傷害並標記目標，受到的傷害 +%d%%，持續 %.0f 秒" % [
					skill.name, skill.mult, skill.bonus_pct, skill.duration]
		"pierce":
			return "%s：貫穿，對目標附近最多 %d 名敵人各造成 %.1f 倍傷害" % [skill.name, skill.targets, skill.mult]
		"execute":
			return "%s：目標血量低於 %d%% 直接擦掉，否則造成 %.1f 倍傷害" % [skill.name, skill.hp_pct, skill.mult]
		"energy_share":
			return "%s：%.1f 倍傷害，並把 %d 點能量分給周圍 %d 格內的隊友" % [
					skill.name, skill.mult, skill.amount, skill.radius]
		"heal":
			return "%s：回復血量比例最低的隊友 %d 點" % [skill.name, skill.amount]
		"heal_nearby":
			return "%s：回復周圍 %d 格內所有隊友各 %d 點" % [skill.name, skill.radius, skill.amount]
		"shield_allies":
			if int(skill.radius) == 0:
				return "%s：自己獲得 %d 點護盾" % [skill.name, skill.amount]
			return "%s：周圍 %d 格內隊友獲得 %d 點護盾" % [skill.name, skill.radius, skill.amount]
		"stun":
			return "%s：造成 %.1f 倍攻擊傷害並暈眩 %.1f 秒" % [skill.name, skill.mult, skill.duration]
	return skill.name
