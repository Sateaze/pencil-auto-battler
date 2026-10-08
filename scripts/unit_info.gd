extends RefCounted
## 棋子資訊的排版。整備畫面與地圖佈陣都會用到，所以抽出來共用，
## 不要在兩個地方各寫一份、改了一邊忘了另一邊。

const DB = preload("res://scripts/db.gd")


## is_shop 為 true 時顯示售價與「再幾件可以升星」，否則顯示賣出價
static func text(gs, id: String, star: int, bonus_hp: float, is_shop: bool) -> String:
	var def: Dictionary = DB.units[id]
	var sm: float = gs.star_mult(star)
	var price: int = int(def.cost) * int(pow(3, star - 1))
	var lines: Array = []
	lines.append("%s %s　%s　%s %d mm" % [
			def.name, "★".repeat(star), def.school, "售價" if is_shop else "費用", price])
	lines.append("生命 %d　攻擊 %d　攻速 %.2f　射程 %d　護甲 %d　移速 %.1f" % [
			int(float(def.hp) * sm + bonus_hp), int(float(def.atk) * sm),
			def.aspd, def.range, def.armor, def.move])
	lines.append(DB.skill_desc(def.get("skill", {})))
	if float(def.get("revive_pct", 0)) > 0.0:
		lines.append("被動：陣亡時以 %d%% 生命重新站起（每場一次）" % int(def.revive_pct))
	if is_shop:
		var owned := _count_owned(gs, id, star)
		if owned > 0:
			lines.append("你已經有 %d 件同名同星，再 %d 件可以升星" % [owned, maxi(1, 3 - owned)])
	else:
		lines.append("賣出可得 %d mm" % price)
	lines.append("")
	lines += synergy_lines(gs, id)
	return "\n".join(lines)


## 「放上場之後」羈絆會變怎樣。羈絆算的是場上不重複的棋子種類，
## 所以場上已有同名就不會增加件數。
static func synergy_lines(gs, id: String) -> Array:
	var p: Dictionary = gs.preview_unit(id)
	var lines: Array = ["放上場後："]
	if bool(p.already_on_board):
		lines.append("　場上已有同名，羈絆件數不會增加（但可以升星）")
	lines.append("　◆ " + tier_change(p.school.name, p.school, false))
	for t in p.traits:
		lines.append("　◇ " + tier_change(t.name, t, true))
	if p.traits.is_empty():
		lines.append("　（這件沒有特徵）")
	return lines


static func tier_change(label: String, d: Dictionary, is_trait: bool) -> String:
	var tiers: Array = d.tiers
	var from_i: int = int(d.tier_from)
	var to_i: int = int(d.tier_to)
	var head := "%s %d → %d　" % [label, int(d["from"]), int(d["to"])]
	if is_trait and int(d.schools_to) < 2:
		return head + "✘ 只來自 %d 個大流派，湊再多也不算數" % int(d.schools_to)
	if to_i > from_i:
		return head + "✦ 會啟動：%s" % tiers[to_i].desc
	if to_i >= 0:
		return head + "✔ 已啟動：%s%s" % [tiers[to_i].desc, next_need(tiers, int(d["to"]))]
	return head + "（未啟動）%s" % next_need(tiers, int(d["to"]))


static func next_need(tiers: Array, count: int) -> String:
	for t in tiers:
		if count < int(t.count):
			return "　｜再 %d 件 → %s" % [int(t.count) - count, t.desc]
	return ""


## 目前場上已經生效（或快要生效）的羈絆，佈陣時一邊排一邊看
static func active_synergies(gs) -> Array:
	var lines: Array = []
	var syn: Dictionary = gs.synergies()
	for school in DB.schools:
		if school == "害蟲" or not syn.has(school):
			continue
		var info: Dictionary = syn[school]
		lines.append("◆ %s %d　%s" % [school, int(info.count),
				_tier_text(DB.schools[school].tiers, int(info.count), int(info.tier))])
	var tsyn: Dictionary = gs.trait_synergies()
	for tr in tsyn:
		if not DB.traits.has(tr):
			continue
		var info2: Dictionary = tsyn[tr]
		var body := ""
		if int(info2.schools) < 2 and int(info2.tier) < 0:
			body = "✘ 只來自 %d 個大流派，不算數" % int(info2.schools)
		else:
			body = _tier_text(DB.traits[tr].tiers, int(info2.count), int(info2.tier))
		lines.append("◇ %s %d　%s" % [tr, int(info2.count), body])
	if lines.is_empty():
		lines.append("（場上還沒有棋子）")
	return lines


static func _tier_text(tiers: Array, count: int, tier: int) -> String:
	var cur := "✔ " + str(tiers[tier].desc) if tier >= 0 else "（未啟動）"
	for t in tiers:
		if count < int(t.count):
			return "%s　｜再 %d 件 → %s" % [cur, int(t.count) - count, t.desc]
	return cur


static func _count_owned(gs, id: String, star: int) -> int:
	var n := 0
	for c in gs.board:
		if gs.board[c].id == id and int(gs.board[c].star) == star:
			n += 1
	for inst in gs.bench:
		if inst != null and inst.id == id and int(inst.star) == star:
			n += 1
	return n
