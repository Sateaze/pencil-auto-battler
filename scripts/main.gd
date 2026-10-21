extends Control
## 路由器 + 自走棋戰鬥畫面。
## 兩個畫面：探索（ExploreScreen）與整備／戰鬥（battle_root 底下的一整組 UI）。
## 戰鬥有三種情境：
##   encounter — 探索地圖上的遭遇戰，可撤退，結算走 MapState
##   shop      — 只整備與購買（站在抽屜格才能買），不打架
##   boss      — 一天結束後的 5 波最終決戰，結算走 GameState.apply_result

const DB = preload("res://scripts/db.gd")
const GameState = preload("res://scripts/game_state.gd")
const MapState = preload("res://scripts/map_state.gd")
const BattleSim = preload("res://scripts/sim/battle_sim.gd")
const BoardView = preload("res://scripts/board_view.gd")
const ExploreScreen = preload("res://scripts/explore_screen.gd")
const TitleScreen = preload("res://scripts/title_screen.gd")
const UITheme = preload("res://scripts/ui_theme.gd")
const UnitInfo = preload("res://scripts/unit_info.gd")

const BOARD_POS := Vector2(24, 92)
const BENCH_Y := 606.0
const SHOP_Y := 700.0
const PANEL_X := 580.0
const FIELD_RETREAT := 10.0       # 開打後還能撤退的秒數

var gs: GameState
var ms: MapState
var explore: ExploreScreen
var battle_root: Control          # 整備畫面（陣形棋盤、備戰席、商店）
var board_view: BoardView

var phase := "explore"            # explore | prep（整備畫面）| field（地圖上開打中）
var selected = null
var hover_preview: Dictionary = {}     # 滑鼠停在商店／備戰席上時預覽的棋子
var retreated := false
var field: Dictionary = {}        # 進行中的戰鬥（MapState.begin_field_battle／begin_boss_wave 的回傳）
var boss_active := false          # 天黑後的最終決戰

var top_label: Label
var syn_label: Label
var info_label: Label
var msg_label: Label
var shop_buttons: Array = []
var bench_buttons: Array = []
var btn_refresh: Button
var btn_xp: Button
var btn_sell: Button
var btn_back: Button
var reward_label: Label
var reward_buttons: Array = []
var title: TitleScreen
var fade: ColorRect

var _demo := false
var _frames := 0
var _demo_boss_frame := -1
var _shots_taken: Dictionary = {}      # 這次 demo 已經存過的截圖（不看檔案在不在，舊圖才不會擋住新圖）


func _ready() -> void:
	DB.load_all()
	var seed_value := randi()
	gs = GameState.new()
	gs.start_new(seed_value)
	ms = MapState.new()
	ms.start(seed_value, gs)
	_demo = "--demo" in OS.get_cmdline_user_args()
	theme = UITheme.make()
	_build_ui()
	_show_title()          # demo 模式會先截標題畫面，再由 _demo_tick 切進遊戲


# ── 建立畫面 ────────────────────────────────────────────────

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.10, 0.13)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	explore = ExploreScreen.new()
	explore.attack_requested.connect(_on_attack_requested)
	explore.prep_requested.connect(_on_prep_requested)
	explore.day_finished.connect(_on_day_finished)
	explore.retreat_requested.connect(_on_field_retreat)
	explore.boss_fight_requested.connect(_on_boss_fight)
	explore.restart_requested.connect(func(): get_tree().reload_current_scene())
	add_child(explore)
	explore.attach(ms)

	battle_root = Control.new()
	battle_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	battle_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(battle_root)

	# 文字不要直接浮在背景上，底下墊面板（標題文字沿用原本那幾個 Label，這裡不重複寫）
	UITheme.add_panel(battle_root, Vector2(PANEL_X - 12, 110), Vector2(700, 320))
	UITheme.add_panel(battle_root, Vector2(PANEL_X - 12, 484), Vector2(700, 216))
	UITheme.add_panel(battle_root, Vector2(20, 576), Vector2(552, 96))
	UITheme.add_panel(battle_root, Vector2(20, 672), Vector2(552, 114))

	top_label = _label(Vector2(30, 14), Vector2(1220, 36), 20)
	msg_label = _label(Vector2(PANEL_X, 60), Vector2(660, 60), 22)
	msg_label.modulate = Color(1, 0.9, 0.4)

	board_view = BoardView.new()
	board_view.position = BOARD_POS
	board_view.cell_clicked.connect(_on_cell_clicked)
	battle_root.add_child(board_view)

	_label(Vector2(30, BENCH_Y - 24), Vector2(400, 22), 14).text = "備戰席（點選後再點棋盤格放置）"
	for i in GameState.BENCH_SIZE:
		var b := Button.new()
		b.position = Vector2(30 + i * 68, BENCH_Y)
		b.size = Vector2(64, 60)
		b.add_theme_font_size_override("font_size", 13)
		b.pressed.connect(_on_bench_pressed.bind(i))
		b.mouse_entered.connect(_on_bench_hover.bind(i))
		b.mouse_exited.connect(_on_hover_clear)
		battle_root.add_child(b)
		bench_buttons.append(b)

	_label(Vector2(30, SHOP_Y - 22), Vector2(540, 22), 14).text = "抽屜商店　（✦ = 買下並放上場會多啟動一層羈絆；池 = 卡池還剩幾張）"
	for i in GameState.SHOP_SIZE:
		var b := Button.new()
		b.position = Vector2(30 + i * 108, SHOP_Y)
		b.size = Vector2(104, 76)
		b.add_theme_font_size_override("font_size", 14)
		b.pressed.connect(_on_shop_pressed.bind(i))
		b.mouse_entered.connect(_on_shop_hover.bind(i))
		b.mouse_exited.connect(_on_hover_clear)
		battle_root.add_child(b)
		shop_buttons.append(b)

	btn_refresh = _button("刷新商店（2 mm）", Vector2(580, 712), Vector2(160, 40), _on_refresh)
	btn_xp = _button("買經驗（4 mm）", Vector2(750, 712), Vector2(150, 40), _on_buy_xp)
	btn_sell = _button("賣出選取", Vector2(910, 712), Vector2(120, 40), _on_sell)
	btn_back = _button("返回地圖", Vector2(1040, 712), Vector2(210, 40), _on_back_to_map)

	title = TitleScreen.new()
	title.start_pressed.connect(_on_title_start)
	add_child(title)

	fade = ColorRect.new()
	fade.color = Color(0, 0, 0, 0)
	fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fade)

	syn_label = _label(Vector2(PANEL_X, 122), Vector2(670, 300), 14)
	info_label = _label(Vector2(PANEL_X, 494), Vector2(670, 202), 13)

	# 升星獎勵：高一階免費招募，三選一（放在羈絆面板與棋子資訊之間）
	reward_label = _label(Vector2(PANEL_X, 428), Vector2(670, 20), 13)
	reward_label.modulate = Color(1, 0.85, 0.3)
	for i in 3:
		var b := Button.new()
		b.position = Vector2(PANEL_X + i * 180, 450)
		b.size = Vector2(174, 34)
		b.add_theme_font_size_override("font_size", 13)
		b.pressed.connect(_on_reward_pressed.bind(i))
		b.mouse_entered.connect(_on_reward_hover.bind(i))
		b.mouse_exited.connect(_on_hover_clear)
		battle_root.add_child(b)
		reward_buttons.append(b)


func _label(pos: Vector2, sz: Vector2, font_size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.size = sz
	l.add_theme_font_size_override("font_size", font_size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	battle_root.add_child(l)
	return l


func _button(text: String, pos: Vector2, sz: Vector2, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = sz
	b.pressed.connect(cb)
	battle_root.add_child(b)
	return b


# ── 畫面切換 ────────────────────────────────────────────────

func _show_title() -> void:
	title.visible = true
	explore.visible = false
	battle_root.visible = false


func _on_title_start() -> void:
	_transition(func():
		title.visible = false
		_show_explore())


## 黑幕淡出淡入，中間切換畫面
func _transition(on_black: Callable) -> void:
	var tw := create_tween()
	tw.tween_property(fade, "color", Color(0, 0, 0, 1), 0.18)
	tw.tween_callback(on_black)
	tw.tween_property(fade, "color", Color(0, 0, 0, 0), 0.22)


func _show_explore() -> void:
	phase = "explore"
	title.visible = false
	battle_root.visible = false
	explore.visible = true
	explore.refresh()


## 整備畫面：排陣形、看羈絆；站在抽屜格上（或決戰的波與波之間）才能買東西
func _open_prep() -> void:
	phase = "prep"
	selected = null
	explore.visible = false
	battle_root.visible = true
	if boss_active:
		msg_label.text = "決戰準備：可以買東西、調整陣容，好了就回地圖開打下一波"
	elif ms.can_shop():
		msg_label.text = "整備：擺位置、換陣容、買東西"
	else:
		msg_label.text = "整備：擺位置、換陣容（不在抽屜格，不能購買）"
	_refresh()


## 就地開打：不換畫面，直接在大地圖上以玩家為中心展開陣形
func _on_attack_requested(cell: Vector2i) -> void:
	if gs.board.is_empty():
		ms._log("陣形是空的！先按「整備」把棋子放上場再打。")
		explore.refresh()
		return
	_start_field(ms.begin_field_battle(cell), cell, true)


## 最終決戰的下一波：一樣在大地圖上打，只是打在巢穴那一塊
func _on_boss_fight() -> void:
	if phase == "field" or gs.state != "playing":
		return
	if gs.board.is_empty():
		ms._log("陣形是空的！先按「整備」把棋子放上場再打。")
		explore.refresh()
		return
	_start_field(ms.begin_boss_wave(), ms.lair, false)


func _start_field(battle: Dictionary, cell: Vector2i, can_retreat: bool) -> void:
	field = battle
	retreated = false
	phase = "field"
	explore.formation_mode = false         # 佈陣中直接出擊的話，戰鬥時就不用再算佈陣預覽
	explore.battle = field.sim
	explore.battle_origin = field.arena.origin
	explore.battle_cell = cell
	explore.battle_tick = 0.0
	explore.btn_retreat.visible = can_retreat
	explore.refresh()


func _on_field_retreat() -> void:
	if phase != "field" or boss_active:
		return
	retreated = true
	_finish_field_battle()


func _finish_field_battle() -> void:
	var played: float = explore.battle_tick * BattleSim.DT
	explore.battle = null
	explore.btn_retreat.visible = false
	if boss_active:
		_finish_boss_wave()
		return
	# 時間在播放過程中已經即時扣掉；播到一半時間用完的話，這裡會判成「被打斷」
	ms.end_field_battle(field, played, retreated)
	if ms.day_over:
		_on_day_finished()
		return
	_show_explore()


func _on_prep_requested() -> void:
	_open_prep()


## 天黑：玩家趕到巢穴，最終決戰就在那塊地圖上開打。離巢穴越遠，共用生命扣越多。
func _on_day_finished() -> void:
	if boss_active:
		return
	boss_active = true
	ms.start_final_battle()
	explore.boss_mode = true
	explore.cam_ready = false              # 鏡頭直接切到巢穴，不要從原地慢慢滑過去
	_update_boss_text()
	_show_explore()


func _finish_boss_wave() -> void:
	ms.end_boss_wave(field)
	if gs.state == "won" or gs.state == "lost":
		explore.game_over = true
		ms._log(_summary())
	_update_boss_text()
	_show_explore()


func _update_boss_text() -> void:
	if gs.state == "won":
		explore.boss_wave_text = "通關！你守住了這個家。　" + _summary()
	elif gs.state == "lost":
		explore.boss_wave_text = "共用生命歸零，家被佔領了…　" + _summary()
	else:
		explore.boss_wave_text = "最終決戰 第 %d / %d 波：%s　　共用生命 %d　　筆芯 %d mm" % [
				gs.wave, gs.max_wave(), gs.wave_list()[gs.wave - 1].label, gs.life, gs.mm]


# ── 戰鬥畫面更新 ────────────────────────────────────────────

func _refresh() -> void:
	var prep := phase == "prep"
	var can_buy: bool = prep and (ms.can_shop() or boss_active)
	if boss_active:
		top_label.text = "最終決戰 第 %d / %d 波　共用生命 %d　筆芯 %d mm（利息 +%d）　%s　場上 %d / %d" % [
			gs.wave, gs.max_wave(), gs.life, gs.mm, gs.interest(), _level_text(),
			gs.board.size(), gs.pop_cap()]
	else:
		top_label.text = "【%s】剩 %d 秒　血量 %d / %d　筆芯 %d mm（利息 +%d）　%s　場上 %d / %d" % [
			ms.segment().name, int(ms.time_left), ms.hp, MapState.MAX_HP, gs.mm, gs.interest(),
			_level_text(), gs.board.size(), gs.pop_cap()]
	for i in GameState.SHOP_SIZE:
		var entry = gs.shop[i]
		var b: Button = shop_buttons[i]
		if entry == null:
			b.text = "（已購買）"
			b.disabled = true
			b.modulate = Color.WHITE
			continue
		var def: Dictionary = DB.units[entry.id]
		var price: int = gs.shop_price(entry)
		var star: int = int(entry.star)
		# ✦ = 買下並放上場就會多啟動一層羈絆，讓人不用一個個點開看
		var upgrades: bool = gs.would_upgrade(entry.id)
		b.text = "%s%s%s\n%s\n%d mm　池 %d" % [
			"✦ " if upgrades else "", def.name, "★".repeat(star) if star > 1 else "",
			def.school, price, gs.pool_left(entry.id)]
		b.disabled = not can_buy or gs.mm < price
		b.modulate = DB.school_color(def.school).lerp(Color.WHITE, 0.55)
		if star > 1:
			b.modulate = b.modulate.lerp(Color(1, 0.9, 0.3), 0.45)
		if upgrades:
			b.modulate = b.modulate.lerp(Color(0.6, 1.0, 0.6), 0.4)
	for i in GameState.BENCH_SIZE:
		var b: Button = bench_buttons[i]
		var inst = gs.bench[i]
		if inst == null:
			b.text = ""
			b.modulate = Color.WHITE
		else:
			var def := gs.unit_def(inst)
			b.text = "%s\n%s" % [def.name, "★".repeat(inst.star)]
			b.modulate = DB.school_color(def.school).lerp(Color.WHITE, 0.55)
		if _same_loc(selected, {"t": "bench", "i": i}):
			b.modulate = Color(1, 0.95, 0.4)
		b.disabled = not prep
	btn_refresh.text = "刷新商店（%d mm）" % gs.refresh_cost()
	btn_refresh.disabled = not can_buy or gs.mm < gs.refresh_cost()
	btn_xp.disabled = not can_buy or gs.mm < GameState.XP_COST or gs.level >= GameState.MAX_LEVEL
	_refresh_reward()
	btn_sell.disabled = not prep or selected == null
	_refresh_board_static()
	_refresh_synergy()
	_refresh_info()


## 抽屜等級 + 經驗進度 + 目前的 2 星機率
func _level_text() -> String:
	var xp := "最高等級" if gs.level >= GameState.MAX_LEVEL else "經驗 %d / %d" % [gs.xp, gs.xp_need()]
	return "抽屜 Lv.%d（%s；2 星機率 %d%%）" % [gs.level, xp, GameState.STAR2_ODDS[gs.level - 1]]


func _refresh_board_static() -> void:
	var list: Array = []
	for c in gs.board:
		var inst: Dictionary = gs.board[c]
		var def := gs.unit_def(inst)
		var sm := gs.star_mult(inst.star)
		var hp := float(def.hp) * sm + float(inst.bonus_hp)
		list.append({"cell": c, "id": def.id, "name": def.name, "school": def.school,
				"star": inst.star, "team": 0, "hp": hp, "max_hp": hp})
	board_view.static_units = list
	board_view.selected_cell = selected.c if selected != null and selected.t == "board" else Vector2i(-1, -1)
	board_view.queue_redraw()


## 每個流派／特徵各一行，避免文字溢出撞到下面的棋子資訊
func _refresh_synergy() -> void:
	var syn := gs.synergies()
	var lines: Array = ["流派羈絆（同名物品只算一件）"]
	if syn.is_empty():
		lines.append("　場上還沒有物品")
	for school in DB.schools:
		if school == "害蟲" or not syn.has(school):
			continue
		var count: int = syn[school].count
		var tier: int = syn[school].tier
		var tiers: Array = DB.schools[school].tiers
		lines.append("◆ %s %d　%s" % [school, count, _tier_text(tiers, count, tier)])
	var tsyn := gs.trait_synergies()
	if not tsyn.is_empty():
		lines.append("")
		lines.append("特徵（需來自至少 2 個不同大流派）")
	for tr in tsyn:
		if not DB.traits.has(tr):
			continue
		var info: Dictionary = tsyn[tr]
		var tiers: Array = DB.traits[tr].tiers
		var text := ""
		if int(info.schools) < 2 and int(info.tier) < 0:
			text = "✘ 目前只來自 %d 個大流派，不算數" % int(info.schools)
		else:
			text = _tier_text(tiers, int(info.count), int(info.tier))
		lines.append("◇ %s %d　%s" % [tr, int(info.count), text])
	if boss_active and gs.state == "playing":
		lines.append("\n下一波：%s（回地圖按「佈陣」可以先看牠們會站在哪）" % gs.wave_list()[gs.wave - 1].label)
	syn_label.text = "\n".join(lines)


## 同時顯示「目前生效的效果」和「再幾件可以升到下一階」
func _tier_text(tiers: Array, count: int, tier: int) -> String:
	var cur := "✔ " + str(tiers[tier].desc) if tier >= 0 else "（未啟動）"
	for t in tiers:
		if count < int(t.count):
			return "%s　｜再 %d 件 → %s" % [cur, int(t.count) - count, t.desc]
	return cur


## 升星送的「高一階免費招募」：三選一，不能刷新，打完這場戰鬥就失效
func _refresh_reward() -> void:
	var rewards: Array = gs.pending_reward
	var show: bool = not rewards.is_empty() and phase == "prep"
	reward_label.visible = show
	if show:
		reward_label.text = "升星獎勵！免費招募一件（三選一，打完這場就失效）"
	for i in reward_buttons.size():
		var b: Button = reward_buttons[i]
		b.visible = show and i < rewards.size()
		if b.visible:
			var def: Dictionary = DB.units[rewards[i]]
			b.text = "%s（%s　%d mm 級）" % [def.name, def.school, def.cost]
			b.modulate = DB.school_color(def.school).lerp(Color.WHITE, 0.5)


func _on_reward_pressed(i: int) -> void:
	if i < gs.pending_reward.size():
		gs.claim_merge_reward(gs.pending_reward[i])
	_refresh()


func _on_reward_hover(i: int) -> void:
	if i < gs.pending_reward.size():
		hover_preview = {"id": gs.pending_reward[i], "star": 1, "shop": true}
		_refresh_info()


## 滑鼠移到商店／備戰席上就預覽，不用先買；沒在預覽時顯示選取的棋子
func _on_shop_hover(i: int) -> void:
	var entry = gs.shop[i]
	hover_preview = {"id": entry.id, "star": int(entry.star), "shop": true} if entry != null else {}
	_refresh_info()


func _on_bench_hover(i: int) -> void:
	var inst = gs.bench[i]
	hover_preview = {"id": inst.id, "star": int(inst.star), "shop": false} if inst != null else {}
	_refresh_info()


func _on_hover_clear() -> void:
	hover_preview = {}
	_refresh_info()


func _refresh_info() -> void:
	if not hover_preview.is_empty():
		info_label.text = UnitInfo.text(gs, hover_preview.id, int(hover_preview.star), 0.0, bool(hover_preview.shop))
		return
	if selected == null:
		info_label.text = "滑鼠移到商店或備戰席的棋子上，就能先看完整數值與技能。\n三件同名同星自動合成高一星（每星 ×1.8 血量與攻擊）。\n高地效果只對站在最後兩排的遠程棋子生效。"
		return
	var inst = gs.get_at(selected)
	if inst == null:
		info_label.text = ""
		return
	info_label.text = UnitInfo.text(gs, inst.id, int(inst.star), float(inst.bonus_hp), false)



# ── 操作 ────────────────────────────────────────────────────

func _same_loc(a, b) -> bool:
	return a != null and b != null and a.hash() == b.hash()


func _on_shop_pressed(i: int) -> void:
	if phase == "prep" and gs.buy(i):
		_refresh()


func _on_bench_pressed(i: int) -> void:
	if phase != "prep":
		return
	var loc := {"t": "bench", "i": i}
	if selected == null:
		if gs.bench[i] != null:
			selected = loc
	elif _same_loc(selected, loc):
		selected = null
	else:
		gs.move(selected, loc)
		selected = null
	_refresh()


func _on_cell_clicked(cell: Vector2i) -> void:
	if phase != "prep":
		return
	var loc := {"t": "board", "c": cell}
	if selected == null:
		if gs.board.has(cell):
			selected = loc
	elif _same_loc(selected, loc):
		selected = null
	elif cell.y >= GameState.PLAYER_Y_MIN:
		gs.move(selected, loc)
		selected = null
	else:
		selected = null
	_refresh()


func _on_refresh() -> void:
	gs.refresh_shop()
	_refresh()


func _on_buy_xp() -> void:
	gs.buy_xp()
	_refresh()


func _on_sell() -> void:
	if selected != null:
		gs.sell(selected)
		selected = null
	_refresh()


func _process(delta: float) -> void:
	if _demo:
		_demo_tick()
	if phase != "field" or explore.battle == null:
		return
	var dt: float = delta * explore.speed()
	explore.battle_tick += dt / BattleSim.DT
	if not boss_active:
		ms.time_left = maxf(0.0, ms.time_left - dt)     # 打架的時候時間照常在走（決戰時天已經黑了）
		explore.btn_retreat.visible = explore.battle_tick * BattleSim.DT <= FIELD_RETREAT
	if explore.battle_tick >= explore.fx.end_tick() or (not boss_active and ms.time_left <= 0.0):
		_finish_field_battle()
	else:
		explore.update_battle_hud()    # 戰鬥中只更新時間列，不必每幀重建整個面板


func _on_back_to_map() -> void:
	if ms.day_over and not boss_active:
		_on_day_finished()
		return
	_show_explore()


func _summary() -> String:
	return "本局統計：走了 %d 格、打了 %d 場、戰鬥共 %.0f 秒、賺了 %d mm" % [
		ms.steps_taken, ms.battles_fought, ms.battle_seconds, ms.mm_earned]


# ── 示範／截圖（--demo） ────────────────────────────────────

func _demo_tick() -> void:
	_frames += 1
	if _frames == 4:
		_save_shot("title")
	elif _frames == 6:
		title.visible = false
		_show_explore()
	elif _frames == 10:
		_save_shot("explore")
	elif _frames == 14:
		# 先到整備畫面排好陣形（就地開打時會以玩家為中心展開這個陣形）
		_on_prep_requested()
		gs.mm = 60
		for slot in GameState.SHOP_SIZE:
			gs.buy(slot)
		var x := 2
		for i in GameState.BENCH_SIZE:
			if gs.bench[i] != null and gs.board.size() < gs.pop_cap():
				gs.move({"t": "bench", "i": i},
						{"t": "board", "c": Vector2i(x, 5 if x % 2 == 0 else 7)})
				x += 1
		_refresh()
	elif _frames == 18:
		_save_shot("prep")
		_show_explore()
	elif _frames == 20:
		# 示範一下地圖上佈陣的樣子（截圖拿的是前一幀，所以要分開好幾幀做）
		# 先走到怪旁邊，佈陣預覽才看得到敵人分佈
		for i in 8:
			if not ms.adjacent_monsters().is_empty():
				break
			var t0 = _nearest_monster()
			if t0 == null:
				break
			ms.walk(ms.path_to(_approach_cell(t0)))
		explore.formation_mode = true
		var any = explore.ms.gs.board.keys()
		if not any.is_empty():
			explore._hover_loc({"t": "board", "c": any[0]})
		explore.refresh()
	elif _frames == 23:
		_save_shot("formation")
		explore._hover_loc(null)
		explore.formation_mode = false
		explore.refresh()
	elif _frames == 26:
		# 大地圖上最近的怪可能離很遠，多走幾趟把視野推開
		for i in 8:
			if not ms.adjacent_monsters().is_empty():
				break
			var target = _nearest_monster()
			if target == null:
				break
			ms.walk(ms.path_to(_approach_cell(target)))
		explore.refresh()
		_save_shot("explore_moved")
	elif _frames == 30:
		var monsters: Array = ms.adjacent_monsters()
		if not monsters.is_empty():
			_on_attack_requested(monsters[0])
		explore.zoom_by(5.0)                     # 拉近看戰鬥（順便示範滾輪縮放）
		explore.zoom = explore.zoom_want
	elif phase == "field" and explore.battle_tick > 25.0 and not _shots_taken.has("field_battle"):
		_save_shot("field_battle")
	elif not boss_active and phase == "explore" and _frames > 90:
		explore.zoom_want = explore.ZOOM_DEFAULT
		explore.zoom = explore.ZOOM_DEFAULT
		_save_shot("result")
		_on_day_finished()                     # 直接天黑，示範巢穴與決戰
		_demo_boss_frame = _frames
	elif boss_active and _frames == _demo_boss_frame + 6:
		_save_shot("boss_lair")
		_on_boss_fight()
	elif boss_active and phase == "field" and explore.battle_tick > 30.0 and not _shots_taken.has("boss_battle"):
		_save_shot("boss_battle")
		get_tree().quit()
	elif _frames > 900:
		get_tree().quit()


func _nearest_monster():
	var best = null
	var best_d := 999
	for c in ms.cells:
		if ms.cells[c].kind != "monster":
			continue
		var d: int = absi(c.x - ms.pos.x) + absi(c.y - ms.pos.y)
		if d < best_d:
			best_d = d
			best = c
	return best


func _approach_cell(target: Vector2i) -> Vector2i:
	for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
		var c: Vector2i = target + d
		if ms.in_bounds(c) and not ms.is_blocked(c):
			return c
	return ms.pos


func _save_shot(shot_name: String) -> void:
	_shots_taken[shot_name] = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	get_viewport().get_texture().get_image().save_png("res://shots/%s.png" % shot_name)
