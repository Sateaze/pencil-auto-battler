extends Control
## 斜角 2.5D 的大地圖探索畫面。
##
## 地圖比畫面大很多，所以攝影機跟著鉛筆跑；沒走過的地方是黑的，
## 走過但離開視野的地方會變暗（記得有什麼，但看不清楚）。
## 格子有高度，墊高的地方會畫出側面；家人佔用的房間畫成危險的紅色警戒區。
## 右邊有一張小地圖，是判斷「東西大概在哪」的主要依據。

const DB = preload("res://scripts/db.gd")
const MapState = preload("res://scripts/map_state.gd")
const GameState = preload("res://scripts/game_state.gd")
const UnitInfo = preload("res://scripts/unit_info.gd")
const Art = preload("res://scripts/art.gd")
const UITheme = preload("res://scripts/ui_theme.gd")

signal attack_requested(cell: Vector2i)
signal prep_requested()
signal day_finished()
signal retreat_requested()

const TW := 48.0                  # 菱形格寬
const TH := 26.0                  # 菱形格高
const STEP_PX := 13.0             # 每一層高度在畫面上的高度
const VIEW := Rect2(0, 66, 898, 734)
const PANEL_X := 912.0
const MINI := Rect2(922, 78, 324, 240)     # 小地圖
const MINI_CELL := 6.0


var ms: MapState
var font: Font
var hover := Vector2i(-1, -1)
var preview: Array = []
var cam := Vector2.ZERO           # 攝影機中心（畫面座標，未套用視窗偏移）
var cam_ready := false

# 就地開打：戰鬥直接畫在大地圖上，不換畫面
var battle = null                 # BattleSim
var battle_origin := Vector2i.ZERO   # 戰場左上角在大地圖上的位置
var battle_tick := 0.0

var top_label: Label
var time_label: Label
var cell_label: Label
var log_label: Label
var btn_prep: Button
var btn_copy: Button
var btn_end: Button
var btn_retreat: Button
var btn_formation: Button
var attack_buttons: Array = []

# 直接在地圖上佈陣：以玩家所在格為中心，把陣形畫在周圍的格子上
var formation_mode := false
var sel = null                    # 選取中的棋子位置（備戰席或陣形格）
var hover_unit = null             # 滑鼠停著的棋子位置，用來顯示數據
var foe_preview: Array = []       # 佈陣時預覽：敵人開打時會站在哪
var preview_label := ""
var bench_buttons: Array = []
var syn_label: Label
var syn_panel: Panel
var log_panel: Panel
var info_panel: Panel


func _ready() -> void:
	font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)

	top_label = _label(Vector2(16, 8), Vector2(1250, 26), 17)
	time_label = _label(Vector2(16, 36), Vector2(1250, 24), 13)
	# 小地圖自己畫外框。這裡不能墊 Panel —— Panel 是子節點，會蓋在 _draw() 畫的東西上面。
	info_panel = UITheme.add_panel(self, Vector2(PANEL_X, 342), Vector2(352, 196))
	log_panel = UITheme.add_panel(self, Vector2(PANEL_X, 672), Vector2(352, 124))
	syn_panel = UITheme.add_panel(self, Vector2(PANEL_X, 614), Vector2(352, 182))
	cell_label = _label(Vector2(PANEL_X + 10, 350), Vector2(332, 186), 13)
	log_label = _label(Vector2(PANEL_X + 10, 680), Vector2(332, 110), 12)
	for i in 4:
		var b := Button.new()
		b.position = Vector2(PANEL_X + 8, 548 + i * 30)
		b.size = Vector2(336, 27)
		b.add_theme_font_size_override("font_size", 12)
		b.visible = false
		b.pressed.connect(_on_attack.bind(i))
		add_child(b)
		attack_buttons.append(b)
	# 三顆按鈕排在地圖下緣
	btn_prep = _button("整備／抽屜商店", Vector2(16, 762), Vector2(200, 32), func(): prep_requested.emit())
	btn_copy = _button("影印機（5 mm）", Vector2(226, 762), Vector2(170, 32), _on_copy)
	btn_end = _button("結束這個時段", Vector2(406, 762), Vector2(170, 32), _on_end_segment)
	btn_retreat = _button("撤退", Vector2(586, 762), Vector2(150, 32), func(): retreat_requested.emit())
	btn_retreat.visible = false
	btn_formation = _button("佈陣", Vector2(746, 762), Vector2(140, 32), _toggle_formation)
	for b in [btn_prep, btn_copy, btn_end, btn_retreat, btn_formation]:
		b.add_theme_font_size_override("font_size", 13)
	# 佈陣模式下才出現的備戰席
	for i in GameState.BENCH_SIZE:
		var b := Button.new()
		b.position = Vector2(16 + i * 70, 700)
		b.size = Vector2(66, 54)
		b.add_theme_font_size_override("font_size", 12)
		b.visible = false
		b.pressed.connect(_on_bench_pressed.bind(i))
		b.mouse_entered.connect(func(): _hover_loc({"t": "bench", "i": i}))
		b.mouse_exited.connect(func(): _hover_loc(null))
		add_child(b)
		bench_buttons.append(b)
	syn_label = _label(Vector2(PANEL_X + 10, 622), Vector2(332, 166), 12)
	syn_label.visible = false
	syn_panel.visible = false


func _hover_loc(loc) -> void:
	if loc != null and ms.gs.get_at(loc) == null:
		loc = null
	if hover_unit == null and loc == null:
		return
	hover_unit = loc
	_refresh_cell_label()


func _toggle_formation() -> void:
	formation_mode = not formation_mode
	sel = null
	refresh()


## 佈陣時先算好「真的開打的話，敵人會站在哪」。
## 整條佈陣流程（free_spot、排序）都沒有用到亂數，所以這份預覽和實際開打一模一樣。
func build_foe_preview() -> void:
	foe_preview = []
	preview_label = ""
	if ms == null or not formation_mode:
		return
	var adj: Array = ms.adjacent_monsters()
	if adj.is_empty():
		return
	var cell: Vector2i = adj[0]
	var arena := ms.build_arena(cell)
	var origin: Vector2i = arena.origin
	var used: Dictionary = {}
	ms.gs.field_player_descs(arena, ms.pos, used)      # 先佔位，敵人才不會疊上來
	for d in ms.gs.field_enemy_descs(ms.encounter_groups(cell), arena, cell, used):
		foe_preview.append({"cell": Vector2i(d.cell) + origin, "id": d.id})
	preview_label = "%s（%d 隻）" % [ms.cell_at(cell).label, foe_preview.size()]


## 地圖格 ↔ 陣形格。陣形是相對位置，所以你走到哪，陣形就跟到哪。
func board_cell_of(map_cell: Vector2i) -> Vector2i:
	return GameState.FORMATION_CENTER + (map_cell - ms.pos)


func map_cell_of(board_cell: Vector2i) -> Vector2i:
	return ms.pos + (board_cell - GameState.FORMATION_CENTER)


static func is_formation_cell(b: Vector2i) -> bool:
	return b.x >= 0 and b.x < 8 and b.y >= GameState.PLAYER_Y_MIN and b.y < 8


func _on_bench_pressed(i: int) -> void:
	if not formation_mode:
		return
	var loc := {"t": "bench", "i": i}
	if sel == null:
		if ms.gs.bench[i] != null:
			sel = loc
	elif sel.hash() == loc.hash():
		sel = null
	else:
		ms.gs.move(sel, loc)
		sel = null
	refresh()


func _label(pos: Vector2, sz: Vector2, font_size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.size = sz
	l.add_theme_font_size_override("font_size", font_size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


func _button(text: String, pos: Vector2, sz: Vector2, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = sz
	b.pressed.connect(cb)
	add_child(b)
	return b


func attach(state: MapState) -> void:
	ms = state
	cam_ready = false
	refresh()


# ── 投影與攝影機 ────────────────────────────────────────────

static func iso(gx: float, gy: float) -> Vector2:
	return Vector2((gx - gy) * TW * 0.5, (gx + gy) * TH * 0.5)


## 格子中心 → 畫面座標（含高度抬升與攝影機位移）
func to_screen(grid: Vector2, h: int) -> Vector2:
	return iso(grid.x + 0.5, grid.y + 0.5) - Vector2(0, h * STEP_PX) - cam + VIEW.get_center()


func _cam_target() -> Vector2:
	if ms == null:
		return Vector2.ZERO
	return iso(ms.pos.x + 0.5, ms.pos.y + 0.5) - Vector2(0, ms.height_of(ms.pos) * STEP_PX)


func _process(delta: float) -> void:
	if ms == null:
		return
	var want := _cam_target()
	if not cam_ready:
		cam = want
		cam_ready = true
	else:
		cam = cam.lerp(want, clampf(delta * 7.0, 0.0, 1.0))
	queue_redraw()


## 畫面座標 → 格子。先用地面估一個，再在附近找真的被點到的那一格
## （墊高的格子畫在比較上面，單純用地面反推會偏掉）。
func pick_cell(p: Vector2) -> Vector2i:
	var local := p - VIEW.get_center() + cam
	var a := local.x / (TW * 0.5)
	var b := local.y / (TH * 0.5)
	var guess := Vector2i(floori((a + b) * 0.5), floori((b - a) * 0.5))
	var best := Vector2i(-1, -1)
	var best_key := -9999
	for dy in range(-1, 5):
		for dx in range(-1, 5):
			var c: Vector2i = guess + Vector2i(dx, dy)
			if ms == null or not ms.in_bounds(c):
				continue
			var d := p - to_screen(Vector2(c), ms.height_of(c))
			if absf(d.x) / (TW * 0.5) + absf(d.y) / (TH * 0.5) > 1.0:
				continue
			var key: int = c.x + c.y + ms.height_of(c) * 2
			if key > best_key:
				best_key = key
				best = c
	return best if best.x >= 0 else guess


## 佈陣時只在陣形格裡選，而且用「離格子中心最近」判定。
## 一般的 pick_cell 會優先選前方比較高的格子（因為它畫在上面會擋住後面），
## 佈陣時那樣會讓人點不到被擋住的位置，很難用。
func pick_formation_cell(p: Vector2) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_d := 1e9
	for by in range(GameState.PLAYER_Y_MIN, 8):
		for bx in 8:
			var m := map_cell_of(Vector2i(bx, by))
			if not ms.in_bounds(m):
				continue
			var d: float = p.distance_squared_to(to_screen(Vector2(m), ms.height_of(m)))
			if d < best_d:
				best_d = d
				best = m
	# 離最近的陣形格太遠就當作點在外面，取消選取
	return best if best_d < (TW * TW) else Vector2i(-9999, -9999)


# ── 輸入 ────────────────────────────────────────────────────

func _gui_input(ev: InputEvent) -> void:
	if ms == null or ms.day_over or battle != null:
		return          # 打架的時候不能亂跑
	if ev is InputEventMouseMotion:
		if formation_mode:
			var fc := pick_formation_cell(ev.position)
			var b := board_cell_of(fc) if ms.in_bounds(fc) else Vector2i(-9, -9)
			_hover_loc({"t": "board", "c": b} if is_formation_cell(b) else null)
			return
		var c := pick_cell(ev.position)
		if c != hover:
			hover = c
			preview = _route_to(c)
			_refresh_cell_label()
	elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		if MINI.has_point(ev.position):
			return
		if formation_mode:
			_formation_click(pick_formation_cell(ev.position))
			return
		var c := pick_cell(ev.position)
		if not ms.in_bounds(c) or not ms.discovered.has(c):
			return
		if ms.has_monster(c):
			if c in ms.adjacent_monsters():
				attack_requested.emit(c)
				return
		var route := _route_to(c)
		if not route.is_empty():
			ms.walk(route)
			preview = []
			_after_action()


## 佈陣模式下，點地圖上的格子 = 點陣形上的對應位置
func _formation_click(map_cell: Vector2i) -> void:
	var b := board_cell_of(map_cell)
	if not is_formation_cell(b):
		sel = null
		refresh()
		return
	var loc := {"t": "board", "c": b}
	if sel == null:
		if ms.gs.board.has(b):
			sel = loc
	elif sel.hash() == loc.hash():
		sel = null
	else:
		ms.gs.move(sel, loc)
		sel = null
	refresh()


## 到 target 的路徑；target 是怪群時改走到牠旁邊最近的空格
func _route_to(target: Vector2i) -> Array:
	if ms == null or not ms.in_bounds(target) or not ms.discovered.has(target):
		return []
	if not ms.is_blocked(target):
		return ms.path_to(target)
	if not ms.has_monster(target):
		return []        # 家具：走不進去也沒得打
	var best: Array = []
	for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
		var side: Vector2i = target + d
		if not ms.in_bounds(side) or ms.is_blocked(side):
			continue
		if side == ms.pos:
			return []
		var path := ms.path_to(side)
		if not path.is_empty() and (best.is_empty() or path.size() < best.size()):
			best = path
	return best


func _on_attack(i: int) -> void:
	var monsters := ms.adjacent_monsters()
	if i < monsters.size():
		attack_requested.emit(monsters[i])


func _on_copy() -> void:
	var best = null
	for loc in _all_locs():
		var inst = ms.gs.get_at(loc)
		if inst != null and (best == null or inst.star > ms.gs.get_at(best).star):
			best = loc
	if best != null:
		ms.copy_item(best)
	_after_action()


func _all_locs() -> Array:
	var out: Array = []
	for i in ms.gs.bench.size():
		out.append({"t": "bench", "i": i})
	for c in ms.gs.board:
		out.append({"t": "board", "c": c})
	return out


func _on_end_segment() -> void:
	ms.advance_segment()
	_after_action()


func _after_action() -> void:
	refresh()
	if ms.day_over:
		day_finished.emit()


# ── 更新 ────────────────────────────────────────────────────

func refresh() -> void:
	if ms == null:
		return
	var seg: Dictionary = ms.segment()
	var gs = ms.gs
	var xp: String = "最高等級" if gs.level >= gs.MAX_LEVEL else "經驗 %d/%d" % [gs.xp, gs.xp_need()]
	top_label.text = "【%s】%s　　血量 %d/%d　　筆芯 %d mm　　抽屜 Lv.%d（%s）　　影印機剩 %d 次" % [
		seg.name, seg.desc, ms.hp, MapState.MAX_HP, gs.mm, gs.level, xp, ms.copier_left]
	time_label.text = "剩餘時間 %d 秒（還能走 %d 格，每格 %.1f 秒）　⚠ 危險：%s　　已探索 %d / %d 格" % [
		int(ms.time_left), ms.steps_affordable(), ms.step_cost(),
		"、".join(seg.occupied), ms.discovered.size(), ms.width * ms.height]
	var fighting: bool = battle != null
	var monsters := ms.adjacent_monsters()
	for i in attack_buttons.size():
		var b: Button = attack_buttons[i]
		b.visible = not fighting and i < monsters.size()
		if b.visible:
			b.text = "主動出擊：%s（在「%s」開打）" % [
				ms.cell_at(monsters[i]).label, ms.terrain_of(ms.pos)]
	btn_copy.disabled = fighting or not ms.can_copy()
	btn_end.disabled = fighting or formation_mode or ms.day_over
	btn_prep.disabled = fighting
	btn_formation.disabled = fighting
	btn_formation.text = "完成佈陣" if formation_mode else "佈陣"
	build_foe_preview()
	var gs2 = ms.gs
	for i in bench_buttons.size():
		var b: Button = bench_buttons[i]
		b.visible = formation_mode and not fighting
		if not b.visible:
			continue
		var inst = gs2.bench[i]
		if inst == null:
			b.text = ""
			b.modulate = Color.WHITE
		else:
			var def = gs2.unit_def(inst)
			b.text = "%s\n%s" % [def.name, "★".repeat(int(inst.star))]
			b.modulate = DB.school_color(def.school).lerp(Color.WHITE, 0.55)
		if sel != null and sel.t == "bench" and int(sel.i) == i:
			b.modulate = Color(1, 0.95, 0.4)
	if fighting:
		time_label.text = "戰鬥中…　已經打了 %.1f 秒　剩餘時間 %d 秒（時間照常在走）" % [
			battle_tick * 0.1, int(ms.time_left)]
	elif formation_mode:
		var foes := "　紅色影子 = 開打時敵人會站的位置（%s）" % preview_label \
				if not preview_label.is_empty() else "　走到怪群旁邊佈陣，就會看到敵人會站在哪"
		time_label.text = "佈陣中：點棋子再點藍色格子移動。場上 %d / %d　紅叉 = 有家具，開打時會自動挪開%s" % [
				gs2.board.size(), gs2.pop_cap(), foes]
	log_label.text = "\n".join(ms.logs)
	_refresh_cell_label()
	queue_redraw()


func _refresh_cell_label() -> void:
	if ms == null:
		return
	# 佈陣時用整塊下半部顯示羈絆，紀錄先收起來，免得兩邊擠在一起
	syn_label.visible = formation_mode
	syn_panel.visible = formation_mode
	log_panel.visible = not formation_mode
	log_label.visible = not formation_mode
	# 佈陣時棋子資訊比較長，把面板拉高（攻擊按鈕這時本來就是隱藏的）
	info_panel.size.y = 262 if formation_mode else 196
	cell_label.size.y = 250 if formation_mode else 186
	cell_label.add_theme_font_size_override("font_size", 12 if formation_mode else 13)
	if formation_mode:
		syn_label.text = "目前羈絆\n" + "\n".join(UnitInfo.active_synergies(ms.gs))
		# 滑鼠停著的優先，否則顯示選取中的
		var show = hover_unit if hover_unit != null else sel
		var inst = ms.gs.get_at(show) if show != null else null
		if inst != null:
			cell_label.text = UnitInfo.text(ms.gs, inst.id, int(inst.star),
					float(inst.bonus_hp), false)
		else:
			cell_label.text = "佈陣中。\n滑鼠移到棋子上就能看它的數值、技能，以及放上場會湊到什麼羈絆。\n" \
					+ "點棋子再點藍色格子可以搬動；備戰席在畫面下方。\n" \
					+ "陣形是相對位置，走到哪都跟著你。"
		return
	var t := ms.terrain_of(ms.pos)
	var room := ms.room_def(ms.pos)
	var lines: Array = [
		"你在：%s（高度 %d）" % [ms.room_at.get(ms.pos, "？"), ms.height_of(ms.pos)],
		"　%s" % room.get("perk", ""),
		"　出沒的怪：%s" % _pool_names(room),
		"地形「%s」：%s" % [t, DB.terrain[t].desc],
	]
	if ms.can_shop():
		lines.append("這格是抽屜：可以買東西。")
	if hover.x >= 0 and ms.in_bounds(hover):
		lines.append("")
		if not ms.discovered.has(hover):
			lines.append("那邊還沒去過，不知道有什麼。")
		else:
			var content = ms.cell_at(hover)
			if content != null and content.kind == "monster":
				lines.append("「%s」：%s" % [content.label, _roster_text(hover)])
				if hover in ms.adjacent_monsters():
					lines.append("就在旁邊 → 點牠開打（按「佈陣」可先看敵人會站在哪）")
				elif not preview.is_empty():
					lines.append("走過去：%d 格，%d 秒" % [
						preview.size(), int(preview.size() * ms.step_cost())])
			elif ms.is_wall(hover):
				lines.append("家具擋住了，過不去。")
			elif not preview.is_empty():
				lines.append("移動到 %s：%d 格，%d 秒" % [
					ms.room_at.get(hover, "？"), preview.size(),
					int(preview.size() * ms.step_cost())])
	cell_label.text = "\n".join(lines)


## 這一群是由哪幾種怪、各幾隻組成的
func _roster_text(cell: Vector2i) -> String:
	var parts: Array = []
	var total := 0
	for g in ms.encounter_groups(cell):
		parts.append("%s ×%d" % [DB.enemies[g.id].name, int(g.count)])
		total += int(g.count)
	return "共 %d 隻（%s）" % [total, "、".join(parts)]


func _pool_names(room: Dictionary) -> String:
	var names: Array = []
	for id in room.get("enemy_pool", []):
		names.append(DB.enemies[id].name)
	return "、".join(names) if not names.is_empty() else "（無）"


# ── 繪製 ────────────────────────────────────────────────────

func _draw() -> void:
	if ms == null:
		return
	draw_rect(VIEW, Color(0.05, 0.05, 0.07))
	var cells := _visible_cells()
	for c in cells:
		_draw_cell(c)
	for c in cells:
		_draw_content(c)
	if battle != null:
		_draw_battle()
	else:
		if formation_mode:
			_draw_formation()
			_draw_foe_preview()
		_draw_player()
	_draw_minimap()


## 敵人開打時會站的位置，畫成半透明的影子，讓人在按下去之前就看得到這仗長什麼樣
func _draw_foe_preview() -> void:
	for f in foe_preview:
		var c: Vector2i = f.cell
		if not ms.in_bounds(c):
			continue
		var center := to_screen(Vector2(c), ms.height_of(c))
		var top := center - Vector2(0, TH * 0.5 + 10)
		draw_colored_polygon(_diamond(center), Color(0.95, 0.25, 0.2, 0.16))
		var d := _diamond(center)
		var outline := PackedVector2Array(d)
		outline.append(d[0])
		draw_polyline(outline, Color(1, 0.4, 0.32, 0.5), 1.0)
		_ellipse(center, 9.0, 4.0, Color(0, 0, 0, 0.2))
		# 半透明：先畫實體再用背景色蓋一層，draw_* 不吃節點的 modulate
		Art.draw_enemy(self, str(f.id), top, 12.0)
		draw_circle(top, 13.0, Color(0.05, 0.05, 0.07, 0.45))


## 把陣形畫在玩家周圍：可放的範圍打亮，棋子站在各自的格子上
func _draw_formation() -> void:
	var gs = ms.gs
	for by in range(GameState.PLAYER_Y_MIN, 8):
		for bx in 8:
			var b := Vector2i(bx, by)
			var m := map_cell_of(b)
			if not ms.in_bounds(m):
				continue
			var center := to_screen(Vector2(m), ms.height_of(m))
			var on: bool = gs.board.has(b)
			var picked: bool = sel != null and sel.t == "board" and sel.c == b
			var tint := Color(1, 0.9, 0.35, 0.3) if picked else Color(0.45, 0.8, 1.0, 0.14)
			draw_colored_polygon(_diamond(center), tint)
			var d := _diamond(center)
			var outline := PackedVector2Array(d)
			outline.append(d[0])
			draw_polyline(outline, Color(0.6, 0.85, 1.0, 0.45 if not picked else 0.95), 1.0)
			if ms.is_wall(m):
				draw_line(center + Vector2(-TW * 0.25, -TH * 0.25),
						center + Vector2(TW * 0.25, TH * 0.25), Color(1, 0.4, 0.3, 0.6), 1.5)
			if not on:
				continue
			var inst: Dictionary = gs.board[b]
			var def = gs.unit_def(inst)
			var top := center - Vector2(0, TH * 0.5 + 12)
			_ellipse(center, 11.0, 5.0, Color(0, 0, 0, 0.35))
			Art.draw_token_base(self, top, 15.0, DB.school_color(def.school), false, float(bx + by))
			Art.draw_item(self, def.id, top, 14.0)
			Art.draw_token_ring(self, top, 15.0, false)
			if int(inst.star) > 1:
				draw_string_outline(font, top + Vector2(-20, -20), "★".repeat(int(inst.star)),
						HORIZONTAL_ALIGNMENT_CENTER, 40, 10, 3, Color.BLACK)
				draw_string(font, top + Vector2(-20, -20), "★".repeat(int(inst.star)),
						HORIZONTAL_ALIGNMENT_CENTER, 40, 10, Color(1, 0.85, 0.2))


## 戰鬥就在大地圖上進行：把棋子畫在它們實際站的格子上，由遠到近排序
func _draw_battle() -> void:
	var i0 := clampi(floori(battle_tick), 0, battle.frames.size() - 1)
	var i1 := mini(i0 + 1, battle.frames.size() - 1)
	var f := clampf(battle_tick - i0, 0.0, 1.0)
	var items: Array = []
	for k in battle.units.size():
		var u: Dictionary = battle.units[k]
		var a: Array = battle.frames[i0][k]
		var b: Array = battle.frames[i1][k]
		var alpha := 1.0
		if not a[4]:
			# 死掉之後淡出，不要定格變成屍體
			var died := _death_tick(k)
			alpha = clampf(1.0 - (battle_tick - died) / 8.0, 0.0, 1.0)
			if alpha <= 0.0:
				continue
		items.append({
			"grid": Vector2(a[0], a[1]).lerp(Vector2(b[0], b[1]), f),
			"u": u, "hp": a[2], "shield": a[3], "energy": a[5], "stun": a[6], "alpha": alpha,
		})
	items.sort_custom(func(x, y): return x.grid.x + x.grid.y < y.grid.x + y.grid.y)
	for it in items:
		_draw_fighter(it)


func _death_tick(uid: int) -> float:
	for e in battle.events:
		if e.type == "death" and e.dst == uid:
			return float(e.t)
	return 0.0


func _draw_fighter(it: Dictionary) -> void:
	var u: Dictionary = it.u
	var map_pos: Vector2 = it.grid + Vector2(battle_origin)
	var h := ms.height_of(Vector2i(roundi(map_pos.x), roundi(map_pos.y)))
	var ground := to_screen(map_pos, h)
	var center := ground - Vector2(0, TH * 0.5 + 12)
	var is_enemy: bool = int(u.team) == 1
	var r := 15.0
	_ellipse(ground, r * 0.7, r * 0.34, Color(0, 0, 0, 0.35 * float(it.alpha)))
	Art.draw_token_base(self, center, r, DB.school_color(u.school), is_enemy, float(u.uid))
	if is_enemy:
		Art.draw_enemy(self, str(u.id), center, r * 0.95)
	else:
		Art.draw_item(self, str(u.id), center, r * 0.95)
	Art.draw_token_ring(self, center, r, is_enemy)
	if float(it.alpha) < 1.0:
		draw_circle(center, r + 3, Color(0.05, 0.05, 0.07, 1.0 - float(it.alpha)))
		return
	var ratio := clampf(float(it.hp) / maxf(1.0, float(u.max_hp)), 0.0, 1.0)
	var bx := center.x - 16.0
	var by := center.y - r - 6
	draw_rect(Rect2(bx - 1, by - 1, 34, 6), Color(0, 0, 0, 0.8))
	draw_rect(Rect2(bx, by, 32 * ratio, 4),
			Color(0.35, 0.85, 0.45) if not is_enemy else Color(0.9, 0.35, 0.35))
	if float(it.shield) > 0.0:
		draw_rect(Rect2(bx, by - 3.5, 32 * clampf(float(it.shield) / float(u.max_hp), 0.0, 1.0), 2.5),
				Color(0.95, 0.9, 0.5))


## 只畫落在視窗裡的格子（地圖有兩千多格，全畫會很慢）
func _visible_cells() -> Array:
	var span := 2 + ceili(maxf(VIEW.size.x / TW, VIEW.size.y / TH))
	var out: Array = []
	for dy in range(-span, span + 1):
		for dx in range(-span, span + 1):
			var c: Vector2i = ms.pos + Vector2i(dx, dy)
			if not ms.in_bounds(c) or not ms.discovered.has(c):
				continue
			var p := to_screen(Vector2(c), ms.height_of(c))
			if p.x < VIEW.position.x - TW or p.x > VIEW.end.x + TW:
				continue
			if p.y < VIEW.position.y - TH * 3 or p.y > VIEW.end.y + TH * 3:
				continue
			out.append(c)
	out.sort_custom(func(a, b): return a.x + a.y < b.x + b.y)
	return out


func _diamond(center: Vector2) -> PackedVector2Array:
	return PackedVector2Array([
		center + Vector2(0, -TH * 0.5), center + Vector2(TW * 0.5, 0),
		center + Vector2(0, TH * 0.5), center + Vector2(-TW * 0.5, 0)])


## 手繪感：用格子座標決定一個固定的小偏移，讓每格顏色與邊線都不完全一樣
static func _jitter(c: Vector2i, salt: int) -> float:
	var n: int = (c.x * 73856093) ^ (c.y * 19349663) ^ (salt * 83492791)
	return float(absi(n) % 1000) / 1000.0 - 0.5


func _room_color(c: Vector2i) -> Color:
	var room: String = ms.room_at.get(c, "")
	for r in DB.map.rooms:
		if r.id == room:
			return Color(r.color)
	return Color(0.3, 0.3, 0.34)


func _draw_cell(c: Vector2i) -> void:
	var h := ms.height_of(c)
	var center := to_screen(Vector2(c), h)
	var seen := ms.is_visible(c)
	var col := _room_color(c)
	col = col.lightened(_jitter(c, 1) * 0.16)        # 手繪的顏色不均
	if ms.is_wall(c):
		col = col.darkened(0.35)
	if not seen:
		col = col.lerp(Color(0.07, 0.08, 0.12), 0.62)   # 記得，但看不清楚
	# 高度側面
	if h > 0:
		var side := PackedVector2Array([
			center + Vector2(-TW * 0.5, 0), center + Vector2(0, TH * 0.5),
			center + Vector2(TW * 0.5, 0),
			center + Vector2(TW * 0.5, h * STEP_PX), center + Vector2(0, TH * 0.5 + h * STEP_PX),
			center + Vector2(-TW * 0.5, h * STEP_PX)])
		draw_colored_polygon(side, col.darkened(0.42))
	draw_colored_polygon(_diamond(center), col)
	# 手繪邊線：兩條稍微錯開的細線
	var d := _diamond(center)
	var outline := PackedVector2Array(d)
	outline.append(d[0])
	draw_polyline(outline, Color(0, 0, 0, 0.22 if seen else 0.12), 1.0)
	if seen:
		var j := Vector2(_jitter(c, 2), _jitter(c, 3)) * 1.6
		var sketch := PackedVector2Array()
		for p in outline:
			sketch.append(p + j)
		draw_polyline(sketch, Color(0.1, 0.09, 0.12, 0.18), 1.0)
	# 家人佔用：紅色警戒區，會呼吸
	if ms.is_occupied(c):
		var pulse: float = 0.22 + 0.14 * sin(Time.get_ticks_msec() / 260.0 + c.x * 0.4 + c.y * 0.4)
		draw_colored_polygon(_diamond(center), Color(1.0, 0.18, 0.14, pulse if seen else pulse * 0.45))
		if ((c.x + c.y) % 3) == 0:
			draw_line(center + Vector2(-TW * 0.3, 0), center + Vector2(TW * 0.3, 0),
					Color(1, 0.4, 0.3, 0.5 if seen else 0.22), 1.5)
	# 地形標記只在看得見時畫，而且很淡，不要搶走圖案
	var mark: String = DB.terrain[ms.terrain_of(c)].mark
	if seen and mark != "" and not ms.is_wall(c):
		draw_string(font, center + Vector2(-TW * 0.5 + 3, -2), mark,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(DB.terrain[ms.terrain_of(c)].color, 0.5))


func _draw_content(c: Vector2i) -> void:
	var content = ms.cell_at(c)
	if content == null:
		return
	var h := ms.height_of(c)
	var center := to_screen(Vector2(c), h) - Vector2(0, TH * 0.35)
	var seen := ms.is_visible(c)
	if content.kind == "monster":
		_draw_monster_group(c, center, seen)
	else:
		if seen:
			Art.draw_cell_icon(self, content.kind, center, TW * 0.30)
		else:
			draw_circle(center, TW * 0.2, Color(0.8, 0.78, 0.5, 0.3))


## 怪群直接畫成一群怪：有幾隻、是哪幾種，都看得出來。
## 只畫在自己那一格裡叢聚，不往旁邊的格子擴張 —— 旁邊的格子其實走得過去，
## 畫上去會讓人誤判路線，也會跟「紅色影子＝實際開打位置」的保證打架。
const GROUP_SHOW_MAX := 7

func _draw_monster_group(c: Vector2i, center: Vector2, seen: bool) -> void:
	var roster: Array = []
	for g in ms.encounter_groups(c):
		for i in int(g.count):
			roster.append(g.id)
	if roster.is_empty():
		return
	var total := roster.size()
	var shown: int = mini(total, GROUP_SHOW_MAX)
	var r: float = TW * (0.26 if total <= 6 else 0.22)
	for i in shown:
		# 用格子座標和序號決定固定的位置，每次畫都一樣
		var a: float = TAU * (float(i) / shown) + _jitter(c, 10 + i) * 1.2
		var spread: float = 0.42 + 0.4 * absf(_jitter(c, 30 + i))
		var p := center + Vector2(cos(a) * TW * 0.3 * spread,
				sin(a) * TH * 0.42 * spread - r * 0.35)
		if seen:
			Art.draw_enemy(self, roster[i], p, r)
		else:
			# 看過但不在視野內：只記得「那邊有一群東西」
			draw_circle(p, r * 0.6, Color(0.75, 0.3, 0.3, 0.3))
	if seen:
		var label := "×%d" % total
		draw_string_outline(font, center + Vector2(-TW * 0.5, TH * 0.62), label,
				HORIZONTAL_ALIGNMENT_CENTER, TW, 11, 4, Color.BLACK)
		draw_string(font, center + Vector2(-TW * 0.5, TH * 0.62), label,
				HORIZONTAL_ALIGNMENT_CENTER, TW, 11, Color(1, 0.72, 0.65))


func _draw_player() -> void:
	var center := to_screen(Vector2(ms.pos), ms.height_of(ms.pos))
	# 路徑預覽
	for p in preview:
		var q := to_screen(Vector2(p), ms.height_of(p))
		draw_colored_polygon(_diamond(q), Color(1, 0.95, 0.4, 0.22))
	var top := center - Vector2(0, TH * 0.5)
	_ellipse(center, TW * 0.26, TH * 0.3, Color(0, 0, 0, 0.4))
	Art.draw_pencil(self, top - Vector2(0, 10), 26.0,
			clampf(ms.gs.mm / 40.0, 0.15, 1.0))
	draw_arc(center, TW * 0.3, 0, TAU, 20, Color(1, 0.95, 0.4, 0.55), 1.5)


func _ellipse(center: Vector2, rx: float, ry: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 16:
		var a: float = TAU * i / 16.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, col)


## 小地圖：俯視、只畫走過的地方。這是判斷「東西大概在哪」的主要依據。
func _draw_minimap() -> void:
	draw_rect(MINI.grow(4), Color(0.07, 0.08, 0.11))
	draw_rect(MINI.grow(4), Color(0.4, 0.43, 0.5), false, 1.0)
	for c in ms.discovered:
		var r := Rect2(MINI.position + Vector2(c) * MINI_CELL, Vector2(MINI_CELL, MINI_CELL))
		var col := _room_color(c)
		if ms.is_wall(c):
			col = col.darkened(0.5)
		if ms.is_occupied(c):
			col = col.lerp(Color(0.95, 0.2, 0.15), 0.55)
		draw_rect(r, col)
	for c in ms.discovered:
		var content = ms.cell_at(c)
		if content == null:
			continue
		var p: Vector2 = MINI.position + (Vector2(c) + Vector2(0.5, 0.5)) * MINI_CELL
		var col := Color(0.95, 0.35, 0.3)
		var dot := MINI_CELL * 0.45
		match content.kind:
			"shop": col = Color(0.4, 0.8, 1.0)
			"chest": col = Color(1.0, 0.85, 0.3)
			"rest": col = Color(0.4, 1.0, 0.6)
			"copier": col = Color(0.85, 0.7, 1.0)
			"monster":
				# 小地圖上的點大小代表怪群規模，一眼看得出哪邊硬
				dot = MINI_CELL * (0.32 if content.key == "monster_small"
						else (0.45 if content.key == "monster_mid" else 0.6))
		draw_circle(p, dot, col)
	var pp: Vector2 = MINI.position + (Vector2(ms.pos) + Vector2(0.5, 0.5)) * MINI_CELL
	draw_circle(pp, MINI_CELL * 0.8, Color(1, 0.95, 0.4))
	draw_arc(pp, MINI_CELL * 1.6, 0, TAU, 16, Color(1, 0.95, 0.4, 0.6), 1.0)
	draw_string(font, MINI.position + Vector2(-2, MINI.size.y + 18),
			"小地圖：紅=怪　藍=抽屜　金=寶箱　綠=休息　紫=影印",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.62, 0.66, 0.76))
