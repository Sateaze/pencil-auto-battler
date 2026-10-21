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
const BattleFx = preload("res://scripts/battle_fx.gd")

signal attack_requested(cell: Vector2i)
signal prep_requested()
signal day_finished()
signal retreat_requested()
signal boss_fight_requested()
signal restart_requested()

const SPEEDS := [1.0, 1.5, 3.0]   # 戰鬥播放速度

const TW := 48.0                  # 菱形格寬
const TH := 26.0                  # 菱形格高
const STEP_PX := 13.0             # 每一層高度在畫面上的高度
const VIEW := Rect2(0, 66, 898, 734)
const PANEL_X := 912.0
const MINI := Rect2(922, 78, 324, 240)     # 小地圖
const MINI_CELL := 6.0
const SCREEN_BG := Color(0.09, 0.10, 0.13)   # 和 main.gd 的背景同色
const FIGHTER_R := 15.0                      # 大地圖戰鬥時棋子的半徑
const ZOOM_DEFAULT := 1.5                    # 一開始就拉近一點，房子不會只是黑底中間的一小塊
const ZOOM_MIN := 0.6
const ZOOM_MAX := 2.6
const ZOOM_STEP := 1.15                      # 滾輪每一格放大／縮小的倍率


var ms: MapState
var font: Font
var hover := Vector2i(-1, -1)
var preview: Array = []
var cam := Vector2.ZERO           # 攝影機中心（畫面座標，未套用視窗偏移）
var cam_ready := false
## 滾輪縮放：以地圖視窗中心（＝玩家）為中心放大縮小。
## 地圖上的東西都先用 zoom = 1 的座標算（to_screen 等），畫的時候整層套 _zoom_xf()；
## 滑鼠位置則用 _unzoom() 換回來再判斷點到哪一格。
var zoom := ZOOM_DEFAULT
var zoom_want := ZOOM_DEFAULT

# 就地開打：戰鬥直接畫在大地圖上，不換畫面
var fx := BattleFx.new()           # 就地開打的戰鬥表演（撲擊、閃白、彈道、數字…）
## 一指定戰鬥就交給表演模組。以前要等畫面第一次繪製才交，開打第一幀主程式
## 問「什麼時候播完」時拿到空值，整場戰鬥直接壞掉。
var battle = null:                 # BattleSim
	set(v):
		battle = v
		fx.set_sim(v)
var battle_origin := Vector2i.ZERO   # 戰場左上角在大地圖上的位置
var battle_cell := Vector2i(-1, -1)  # 正在打的那群怪原本所在的格子（開打時不再畫牠的圖示）
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
var btn_speed: Button
var btn_boss: Button
var speed_idx := 1

# 最終決戰：在巢穴那塊地圖上打五波，期間不能亂跑，只能佈陣、整備、開打下一波
var boss_mode := false
var boss_wave_text := ""          # 由 main 填：第幾波、共用生命等
var game_over := false
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

# 效能用的快取
var _room_col: Dictionary = {}     # 格子 -> 房間底色
var _cell_col: Dictionary = {}     # 格子 -> 房間底色＋手繪色差＋家具變暗
var _max_lift := 0.0               # 最高的格子抬升多少像素（決定要往下多掃幾排）
var _mini_tex: ImageTexture        # 小地圖畫成一張圖，只在內容變了才重畫
var _mini_sig := ""
var _ground_mesh := ArrayMesh.new()   # 整片已探索的地面，世界座標
var _occ_mesh := ArrayMesh.new()      # 家人佔用的格子，疊會呼吸的紅光用
var _outline := PackedVector2Array()  # 所有格子的邊線（成對的線段）
var _occ_lines := PackedVector2Array()
var _ground_sig := ""
var _white: ImageTexture
# 手繪感的底：桌面紙張底紋（跟著地圖移動）、視窗暗角、玩家身邊的光暈
var _paper_tex: ImageTexture
var _vignette_tex: GradientTexture2D
var _glow_tex: GradientTexture2D
var _sketch := PackedVector2Array()   # 還沒探索、但就在邊上的格子：鉛筆淡淡打的草稿線
var _hatch := PackedVector2Array()    # 墊高格子側面的鉛筆排線
var _sketch_n := -1                   # 草稿線是用多少格已探索算的（探索範圍變了才重算）


func _ready() -> void:
	font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 線性濾鏡：紙張底紋、暗角、光暈都會被拉大，最近點濾鏡會出現一格一格的色階。
	# 小地圖是原尺寸貼上，不受影響。紙張底紋要能重複鋪滿，所以開 repeat。
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	var px := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	px.fill(Color.WHITE)
	_white = ImageTexture.create_from_image(px)             # 地面網格用頂點色，貼一張白圖就好
	_paper_tex = _make_paper()
	_vignette_tex = _make_radial(Color(0, 0, 0, 0), Color(0, 0, 0, 0.72), 0.55)
	_glow_tex = _make_radial(Color(1, 1, 1, 1), Color(1, 1, 1, 0), 0.0)
	set_process(true)

	top_label = _label(Vector2(16, 8), Vector2(1250, 26), 17)
	time_label = _label(Vector2(16, 36), Vector2(1250, 24), 13)
	# 小地圖自己畫外框。這裡不能墊 Panel —— Panel 是子節點，會蓋在 _draw() 畫的東西上面。
	info_panel = UITheme.add_panel(self, Vector2(PANEL_X, 342), Vector2(352, 196))
	log_panel = UITheme.add_panel(self, Vector2(PANEL_X, 672), Vector2(352, 124))
	syn_panel = UITheme.add_panel(self, Vector2(PANEL_X, 614), Vector2(352, 182))
	cell_label = _label(Vector2(PANEL_X + 10, 350), Vector2(332, 186), 13)
	cell_label.clip_text = true          # 棋子資訊很長時不要溢出面板、壓到下面的「主動出擊」按鈕
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
	btn_prep = _button("整備／抽屜商店", Vector2(16, 762), Vector2(160, 32), func(): prep_requested.emit())
	btn_copy = _button("影印機（5 mm）", Vector2(186, 762), Vector2(140, 32), _on_copy)
	btn_end = _button("結束這個時段", Vector2(336, 762), Vector2(140, 32), _on_end_segment)
	btn_formation = _button("佈陣", Vector2(486, 762), Vector2(130, 32), _toggle_formation)
	btn_speed = _button("", Vector2(626, 762), Vector2(120, 32), _on_speed)
	btn_retreat = _button("撤退", Vector2(756, 762), Vector2(130, 32), func(): retreat_requested.emit())
	btn_retreat.visible = false
	# 最終決戰：開打下一波／重新開始
	btn_boss = _button("", Vector2(PANEL_X + 8, 548), Vector2(336, 40), _on_boss_pressed)
	btn_boss.add_theme_font_size_override("font_size", 15)
	btn_boss.visible = false
	for b in [btn_prep, btn_copy, btn_end, btn_retreat, btn_formation, btn_speed]:
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


func speed() -> float:
	return float(SPEEDS[speed_idx])


func _on_speed() -> void:
	speed_idx = (speed_idx + 1) % SPEEDS.size()
	refresh()


func _on_boss_pressed() -> void:
	if game_over:
		restart_requested.emit()
	else:
		boss_fight_requested.emit()


func _toggle_formation() -> void:
	formation_mode = not formation_mode
	sel = null
	refresh()


## 佈陣時先算好「真的開打的話，敵人會站在哪」。
## 整條佈陣流程（free_spot、排序）都沒有用到亂數，所以這份預覽和實際開打一模一樣。
func build_foe_preview() -> void:
	foe_preview = []
	preview_label = ""
	if ms == null or not formation_mode or battle != null:
		return
	# 決戰時預覽的是下一波魔王軍；平常是旁邊那一群
	var cell: Vector2i
	var groups: Array
	var label: String
	if boss_mode:
		if game_over:
			return
		cell = ms.lair
		groups = ms.boss_groups()
		label = "決戰第 %d 波" % ms.gs.wave
	else:
		var adj: Array = ms.adjacent_monsters()
		if adj.is_empty():
			return
		cell = adj[0]
		groups = ms.encounter_groups(cell)
		label = ms.cell_at(cell).label
	# 跟實際開打呼叫同一個 deploy()，預覽才不會騙人
	var d: Dictionary = ms.deploy(cell, groups)
	var origin: Vector2i = d.arena.origin
	for f in d.foes:
		foe_preview.append({"cell": Vector2i(f.cell) + origin, "id": f.id})
	preview_label = "%s（%d 隻）" % [label, foe_preview.size()]


## 地圖格 ↔ 陣形格。陣形是相對位置，而且會轉向面對要打的怪：
## 最前排的中間對到你站的格子，其他排往你身後延伸。
func board_cell_of(map_cell: Vector2i) -> Vector2i:
	return GameState.map_to_formation(map_cell, ms.pos, ms.formation_facing())


func map_cell_of(board_cell: Vector2i) -> Vector2i:
	return GameState.formation_to_map(board_cell, ms.pos, ms.formation_facing())


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
	_build_color_cache()
	_mini_sig = ""
	_ground_sig = ""
	refresh()


# ── 投影與攝影機 ────────────────────────────────────────────

static func iso(gx: float, gy: float) -> Vector2:
	return Vector2((gx - gy) * TW * 0.5, (gx + gy) * TH * 0.5)


## 格子中心 → 畫面座標（含高度抬升與攝影機位移）
func to_screen(grid: Vector2, h: int) -> Vector2:
	return iso(grid.x + 0.5, grid.y + 0.5) - Vector2(0, h * STEP_PX) - cam + VIEW.get_center()


## zoom = 1 的畫面座標 → 實際畫面座標
func _zoom_xf() -> Transform2D:
	var c := VIEW.get_center()
	return Transform2D(0.0, Vector2(zoom, zoom), 0.0, c - c * zoom)


## 實際畫面座標（滑鼠）→ zoom = 1 的畫面座標
func _unzoom(p: Vector2) -> Vector2:
	var c := VIEW.get_center()
	return c + (p - c) / zoom


## 縮放後，地圖視窗實際看得到的範圍（zoom = 1 的座標）
func _world_view() -> Rect2:
	return Rect2(_unzoom(VIEW.position), VIEW.size / zoom)


func zoom_by(steps: float) -> void:
	zoom_want = clampf(zoom_want * pow(ZOOM_STEP, steps), ZOOM_MIN, ZOOM_MAX)


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
	zoom = lerpf(zoom, zoom_want, clampf(delta * 12.0, 0.0, 1.0))
	if absf(zoom - zoom_want) < 0.002:
		zoom = zoom_want
	fx.anim_t += delta
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
	if ms == null:
		return
	# 滾輪縮放：打架時也可以，方便拉近看戰鬥
	if ev is InputEventMouseButton and ev.pressed and VIEW.has_point(ev.position) \
			and ev.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		zoom_by(1.0 if ev.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0)
		accept_event()
		return
	if battle != null:
		return          # 打架的時候不能亂跑
	if ev is InputEventMouse:
		ev = ev.duplicate()
		ev.position = _unzoom(ev.position) if VIEW.has_point(ev.position) else ev.position
	if ev is InputEventMouseMotion:
		if formation_mode:
			var fc := pick_formation_cell(ev.position)
			var b := board_cell_of(fc) if ms.in_bounds(fc) else Vector2i(-9, -9)
			_hover_loc({"t": "board", "c": b} if is_formation_cell(b) else null)
			return
		if ms.day_over or boss_mode:
			return      # 天黑之後只能佈陣，不能移動
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
		if ms.day_over or boss_mode:
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
	if boss_mode:
		top_label.text = boss_wave_text
		time_label.text = "天黑了，全家睡著，黴菌之王在巢穴現身。不能再移動，只能佈陣、整備，然後開打下一波。"
	else:
		top_label.text = "【%s】%s　　血量 %d/%d　　筆芯 %d mm　　抽屜 Lv.%d（%s）　　影印機剩 %d 次" % [
			seg.name, seg.desc, ms.hp, MapState.MAX_HP, gs.mm, gs.level, xp, ms.copier_left]
		time_label.text = "剩餘時間 %d 秒（還能走 %d 格，每格 %.1f 秒）　⚠ 危險：%s　　%s" % [
			int(ms.time_left), ms.steps_affordable(), ms.step_cost(),
			"、".join(seg.occupied), _lair_hint()]
	var fighting: bool = battle != null
	var monsters := ms.adjacent_monsters() if not boss_mode else []
	for i in attack_buttons.size():
		var b: Button = attack_buttons[i]
		b.visible = not fighting and i < monsters.size()
		if b.visible:
			b.text = "主動出擊：%s（在「%s」開打）" % [
				ms.cell_at(monsters[i]).label, ms.terrain_of(ms.pos)]
	btn_boss.visible = boss_mode and not fighting
	if game_over:
		btn_boss.text = "重新開始"
	elif boss_mode:
		btn_boss.text = "開打決戰第 %d 波" % gs.wave
	btn_copy.disabled = fighting or boss_mode or not ms.can_copy()
	btn_end.disabled = fighting or formation_mode or ms.day_over or boss_mode
	btn_prep.disabled = fighting or game_over
	btn_formation.disabled = fighting or game_over
	btn_speed.text = "播放 ×%s" % str(SPEEDS[speed_idx])
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
		time_label.text = "佈陣中：陣形會轉向面對旁邊的怪，你站在最前排中間。點棋子再點藍色格子移動。場上 %d / %d　紅叉 = 有家具%s" % [
				gs2.board.size(), gs2.pop_cap(), foes]
	log_label.text = "\n".join(ms.logs)
	_refresh_cell_label()
	queue_redraw()


## 找到巢穴之前只說「還沒找到」；找到之後提醒離多遠，晚上別跑太遠
func _lair_hint() -> String:
	if not ms.discovered.has(ms.lair):
		return "巢穴：還沒找到"
	var d := ms.lair_distance()
	var late := d / MapState.LATE_STEPS_PER_LIFE
	return "巢穴：離你 %d 格（天黑時在這裡，決戰共用生命 −%d）" % [d, late]


## 戰鬥播放中每幀只需要更新時間列；完整的 refresh() 會重建所有面板文字
func update_battle_hud() -> void:
	if battle == null:
		return
	if boss_mode:
		time_label.text = "決戰中…　已經打了 %.1f 秒" % (battle_tick * 0.1)
	else:
		time_label.text = "戰鬥中…　已經打了 %.1f 秒　剩餘時間 %d 秒（時間照常在走）" % [
			battle_tick * 0.1, int(ms.time_left)]


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
			elif content != null and content.kind == "lair":
				lines.append("魔王的巢穴！天黑時黴菌之王會在這裡現身。")
				lines.append("晚上離這裡越遠，趕到時決戰共用生命扣越多。")
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
	# 地圖上的東西整層套縮放；畫完（蓋掉視窗外的部分之前）換回原本的座標
	Art.base_xf = _zoom_xf()
	draw_set_transform_matrix(Art.base_xf)
	_draw_paper()
	_draw_ground()
	_draw_player_glow()
	_draw_near_details()
	var cells := _visible_cells()
	for c in cells:
		_draw_content(c)
	if battle != null:
		_draw_battle()
	else:
		if formation_mode:
			_draw_formation()
			_draw_foe_preview()
		_draw_player()
	Art.base_xf = Transform2D.IDENTITY
	draw_set_transform_matrix(Transform2D.IDENTITY)
	draw_texture_rect(_vignette_tex, VIEW, false)
	# 地面網格不做裁切，超出地圖視窗的部分用背景色蓋掉（上方資訊列、右側面板區）
	draw_rect(Rect2(0, 0, size.x, VIEW.position.y), SCREEN_BG)
	draw_rect(Rect2(VIEW.end.x, 0, size.x - VIEW.end.x, size.y), SCREEN_BG)
	_draw_minimap()


## 整片已探索的地面：玩家移動（明暗改變）、探索範圍或時段變了才重建網格；
## 每一幀只要用位移跟著攝影機貼一次。以前每幀對畫面內每一格各畫 3～5 次。
func _draw_ground() -> void:
	var sig := "%d|%d|%d|%d|%s" % [ms.discovered.size(), ms.seg, ms.pos.x, ms.pos.y, ms.day_over]
	if sig != _ground_sig:
		_ground_sig = sig
		_rebuild_ground()
	draw_set_transform_matrix(_zoom_xf() * Transform2D(0.0, VIEW.get_center() - cam))
	if not _sketch.is_empty():
		draw_multiline(_sketch, Color(0.8, 0.76, 0.68, 0.13), 1.0)
	draw_mesh(_ground_mesh, _white)
	draw_multiline(_outline, Color(0, 0, 0, 0.18), 1.0)
	if not _hatch.is_empty():
		draw_multiline(_hatch, Color(0, 0, 0, 0.2), 1.0)
	# 家人佔用：底色已經染紅，這裡再疊一層會呼吸的紅光
	var pulse := 0.07 + 0.07 * sin(Time.get_ticks_msec() / 260.0)
	draw_mesh(_occ_mesh, _white, Transform2D.IDENTITY, Color(1.0, 0.2, 0.15, pulse))
	if not _occ_lines.is_empty():
		draw_multiline(_occ_lines, Color(1, 0.42, 0.32, 0.4), 1.5)
	draw_set_transform_matrix(_zoom_xf())


func _rebuild_ground() -> void:
	var verts := PackedVector2Array()
	var cols := PackedColorArray()
	var overts := PackedVector2Array()
	var ocols := PackedColorArray()
	_outline = PackedVector2Array()
	_occ_lines = PackedVector2Array()
	_hatch = PackedVector2Array()
	if _sketch_n != ms.discovered.size():
		_sketch_n = ms.discovered.size()
		_rebuild_sketch()
	var order: Array = ms.discovered.keys()
	order.sort_custom(func(a, b): return a.x + a.y < b.x + b.y)    # 由遠到近，墊高的側面才會蓋對
	var dim := Color(0.07, 0.08, 0.12)
	for c in order:
		var h := ms.height_of(c)
		var ctr: Vector2 = iso(c.x + 0.5, c.y + 0.5) - Vector2(0, h * STEP_PX)
		var seen := ms.is_visible(c)
		var occ := ms.is_occupied(c)
		var col: Color = _cell_col[c]
		if occ:
			col = col.lerp(Color(0.9, 0.22, 0.17), 0.3)
		if not seen:
			col = col.lerp(dim, 0.62)          # 記得，但看不清楚
		var top := ctr + Vector2(0, -TH * 0.5)
		var right := ctr + Vector2(TW * 0.5, 0)
		var bot := ctr + Vector2(0, TH * 0.5)
		var left := ctr + Vector2(-TW * 0.5, 0)
		if h > 0:
			var drop := Vector2(0, h * STEP_PX)
			var side := col.darkened(0.42)
			_quad(verts, cols, left, bot, bot + drop, left + drop, side)
			_quad(verts, cols, bot, right, right + drop, bot + drop, side.darkened(0.12))
			# 側面的鉛筆排線（稍微斜一點，像手畫的陰影）
			# 只畫前面沒被擋住的那一面（排線是最後才整批畫的，被擋住的會透出來）
			var open_left: bool = ms.height_of(c + Vector2i(0, 1)) < h
			var open_right: bool = ms.height_of(c + Vector2i(1, 0)) < h
			for f in [0.2, 0.45, 0.7, 0.92]:
				var p: Vector2 = left.lerp(bot, f)
				var q: Vector2 = bot.lerp(right, f)
				if open_left:
					_hatch.append_array([p + Vector2(0, 1), p + drop + Vector2(-2.5, -1)])
				if open_right:
					_hatch.append_array([q + Vector2(0, 1), q + drop + Vector2(-2.5, -1)])
		_quad(verts, cols, top, right, bot, left, col)
		_outline.append_array([top, right, right, bot, bot, left, left, top])
		if occ:
			_quad(overts, ocols, top, right, bot, left, Color(1, 1, 1, 1.0 if seen else 0.45))
			if (c.x + c.y) % 3 == 0:
				_occ_lines.append_array([ctr + Vector2(-TW * 0.3, 0), ctr + Vector2(TW * 0.3, 0)])
	_set_mesh(_ground_mesh, verts, cols)
	_set_mesh(_occ_mesh, overts, ocols)


static func _quad(v: PackedVector2Array, c: PackedColorArray,
		a: Vector2, b: Vector2, d: Vector2, e: Vector2, col: Color) -> void:
	v.append_array([a, b, d, a, d, e])
	for i in 6:
		c.append(col)


static func _set_mesh(mesh: ArrayMesh, verts: PackedVector2Array, cols: PackedColorArray) -> void:
	mesh.clear_surfaces()
	if verts.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)


## 還沒探索、但緊鄰已探索範圍的格子（兩格內）：用鉛筆淡淡打個草稿，暗示「那邊還有路」。
## 一律畫在高度 0 —— 沒去過的地方不該先洩漏地形高低。線條故意畫出頭、歪一點，像手打的稿。
func _rebuild_sketch() -> void:
	_sketch = PackedVector2Array()
	var frontier: Dictionary = {}
	for c in ms.discovered:
		# 內部的格子（八方都探索過）不用往外看兩格，省掉大部分的查詢
		var edge := false
		for d in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0),
				Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]:
			if not ms.discovered.has(c + d):
				edge = true
				break
		if not edge:
			continue
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var n: Vector2i = c + Vector2i(dx, dy)
				if ms.in_bounds(n) and not ms.discovered.has(n):
					frontier[n] = true
	for c in frontier:
		var ctr := iso(c.x + 0.5, c.y + 0.5)
		var pts := [ctr + Vector2(0, -TH * 0.5), ctr + Vector2(TW * 0.5, 0), ctr + Vector2(0, TH * 0.5)]
		# 每格只打兩條邊（右上、右下）；另外兩條剛好是左邊、下面鄰格的這兩條，同一條線不會畫兩次變深
		for i in 2:
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var d := (b - a).normalized()
			var j := Vector2(_jitter(c, 40 + i), _jitter(c, 50 + i)) * 2.5
			_sketch.append_array([a - d * 2.0 + j, b + d * 2.5 + j])
		if (c.x * 3 + c.y) % 4 == 0:
			# 偶爾補一筆斜線陰影
			_sketch.append_array([ctr + Vector2(-TW * 0.18, -TH * 0.05), ctr + Vector2(TW * 0.05, TH * 0.2)])


const PAPER_PX := 256

## 桌面紙張底紋：無縫雜訊做出深淺不均，再撒一些很短的紙纖維。只在開場做一次。
func _make_paper() -> ImageTexture:
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.frequency = 0.025
	noise.fractal_octaves = 4
	var img: Image = noise.get_seamless_image(PAPER_PX, PAPER_PX)
	img.convert(Image.FORMAT_RGBA8)
	var base := Color(0.115, 0.105, 0.118)
	for y in PAPER_PX:
		for x in PAPER_PX:
			var v: float = img.get_pixel(x, y).r
			var col := base.lightened((v - 0.5) * 0.09)
			if (x + y) % 8 == 0:
				col = col.lightened(0.012)          # 很淡的斜向紙紋（週期 8 能整除 256，接縫才對得上）
			img.set_pixel(x, y, col)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 320:
		var p := Vector2(rng.randf() * PAPER_PX, rng.randf() * PAPER_PX)
		var d := Vector2.from_angle(rng.randf() * TAU)
		var light := rng.randf() < 0.5
		for k in rng.randi_range(3, 10):
			var x := posmod(int(p.x + d.x * k), PAPER_PX)
			var y := posmod(int(p.y + d.y * k), PAPER_PX)
			var col := img.get_pixel(x, y)
			img.set_pixel(x, y, col.lightened(0.05) if light else col.darkened(0.12))
	return ImageTexture.create_from_image(img)


## 圓形漸層（暗角、光暈共用）。start = 從半徑的哪裡開始變色；radius 以貼圖寬為 1。
func _make_radial(inner: Color, outer: Color, start: float, radius := 0.5) -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, inner)
	g.set_color(1, outer)
	g.set_offset(0, start)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5 + radius, 0.5)
	t.width = 256
	t.height = 256
	return t


## 時段的色調：白天原色、越晚越暗越冷，天黑之後偏藍
func _time_tint() -> Color:
	if ms.day_over:
		return Color(0.62, 0.68, 0.9)
	var n: int = maxi(1, DB.map.segments.size() - 1)
	return Color(1, 1, 1).lerp(Color(0.85, 0.8, 0.9), float(ms.seg) / n)


## 紙張底紋鋪滿看得到的範圍。對齊世界座標，所以會跟著地圖一起捲動，不會黏在螢幕上。
func _draw_paper() -> void:
	var wv := _world_view()
	var anchor := VIEW.get_center() - cam           # 世界原點在（zoom = 1）畫面上的位置
	var t := float(PAPER_PX)
	var x0 := anchor.x + floorf((wv.position.x - anchor.x) / t) * t
	var y0 := anchor.y + floorf((wv.position.y - anchor.y) / t) * t
	draw_texture_rect(_paper_tex, Rect2(x0, y0, wv.end.x - x0 + t, wv.end.y - y0 + t), true, _time_tint())


## 玩家身邊的一圈光：白天暖色、天黑後冷色，讓「你在這裡」和視野範圍更明顯
func _draw_player_glow() -> void:
	if battle != null:
		return
	var center := to_screen(Vector2(ms.pos), ms.height_of(ms.pos))
	var rx: float = TW * (float(ms.vision) + 1.0) * 0.75
	var col := Color(0.65, 0.75, 1.0, 0.16) if ms.day_over else Color(1.0, 0.86, 0.55, 0.13)
	draw_texture_rect(_glow_tex, Rect2(center - Vector2(rx, rx * 0.55), Vector2(rx * 2.0, rx * 1.1)), false, col)


## 視野內的細節（手繪錯開的第二條邊線、地形標記）只有附近一百多格，照舊每幀畫
func _draw_near_details() -> void:
	var r := ms.vision
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var c: Vector2i = ms.pos + Vector2i(dx, dy)
			if not ms.in_bounds(c) or not ms.discovered.has(c):
				continue
			var center := to_screen(Vector2(c), ms.height_of(c))
			var d := _diamond(center)
			var j := Vector2(_jitter(c, 2), _jitter(c, 3)) * 1.6
			draw_polyline(PackedVector2Array([d[0] + j, d[1] + j, d[2] + j, d[3] + j, d[0] + j]),
					Color(0.1, 0.09, 0.12, 0.18), 1.0)
			var t: String = ms.terrain_of(c)
			var mark: String = DB.terrain[t].mark
			if mark != "" and not ms.is_wall(c):
				draw_string(font, center + Vector2(-TW * 0.5 + 3, -2), mark,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(DB.terrain[t].color, 0.5))


## 敵人開打時會站的位置，畫成半透明的影子，讓人在按下去之前就看得到這仗長什麼樣
func _draw_foe_preview() -> void:
	for f in foe_preview:
		var c: Vector2i = f.cell
		if not ms.in_bounds(c):
			continue
		var center := to_screen(Vector2(c), ms.height_of(c))
		draw_colored_polygon(_diamond(center), Color(0.95, 0.25, 0.2, 0.16))
		var d := _diamond(center)
		var outline := PackedVector2Array(d)
		outline.append(d[0])
		draw_polyline(outline, Color(1, 0.4, 0.32, 0.5), 1.0)
		Art.draw_team_ring(self, center, FIGHTER_R * 0.85, true, 0.6)
		Art.draw_figure(self, str(f.id), center, FIGHTER_R * 0.85, true, {"alpha": 0.6})


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
			var top := center - Vector2(0, FIGHTER_R)
			Art.draw_team_ring(self, center, FIGHTER_R, false)
			Art.draw_figure(self, def.id, center, FIGHTER_R, false)
			if int(inst.star) > 1:
				draw_string_outline(font, top + Vector2(-20, -20), "★".repeat(int(inst.star)),
						HORIZONTAL_ALIGNMENT_CENTER, 40, 10, 3, Color.BLACK)
				draw_string(font, top + Vector2(-20, -20), "★".repeat(int(inst.star)),
						HORIZONTAL_ALIGNMENT_CENTER, 40, 10, Color(1, 0.85, 0.2))


## 戰鬥就在大地圖上進行：把棋子畫在它們實際站的格子上，由遠到近排序
func _draw_battle() -> void:
	fx.tick_f = battle_tick
	var items := fx.gather()
	var proj := Callable(self, "_fx_project")
	fx.draw_under(self, items, proj, Callable(self, "_fx_ground"), FIGHTER_R)
	for it in items:
		_draw_fighter(it, proj)
	fx.draw_over(self, items, proj, font, FIGHTER_R)


## 戰場格子 → 大地圖上那一格的地面中心（含高度）
func _fx_ground(grid: Vector2) -> Vector2:
	var m := grid + Vector2(battle_origin)
	return to_screen(m, ms.height_of(Vector2i(roundi(m.x), roundi(m.y))))


## 棋子身體的中心（特效、數字都以這裡為準）；棋子本身是站在地面上的
func _fx_project(grid: Vector2) -> Vector2:
	return _fx_ground(grid) - Vector2(0, FIGHTER_R * 0.9)


## 棋子就是物品本身站在地上，照自己的方式出手（見 item_moves.gd）；腳下的圈表示隊伍
func _draw_fighter(it: Dictionary, proj: Callable) -> void:
	var alpha := float(it.alpha)
	var ground := _fx_ground(it.grid)
	var is_enemy: bool = int(it.team) == 1
	var r := FIGHTER_R
	var pose: Dictionary = fx.pose(it, proj).duplicate()
	Art.draw_team_ring(self, ground, r, is_enemy, alpha)
	pose.alpha = alpha
	pose.flash = fx.flash(int(it.uid))
	Art.draw_figure(self, str(it.id), ground + pose.off, r, is_enemy, pose)
	if alpha < 1.0:
		return
	var center := ground - Vector2(0, r)
	var max_hp := maxf(1.0, float(it.max_hp))
	var ratio := clampf(float(it.hp) / max_hp, 0.0, 1.0)
	var bx := center.x - 16.0
	var by := center.y - r - 8
	draw_rect(Rect2(bx - 1, by - 1, 34, 6), Color(0, 0, 0, 0.8))
	var hp_col := Color(0.35, 0.85, 0.45) if not is_enemy else Color(0.9, 0.35, 0.35)
	if ratio < 0.3:
		hp_col = hp_col.lerp(Color(1, 0.75, 0.2), 0.6)
	draw_rect(Rect2(bx, by, 32 * ratio, 4), hp_col)
	if float(it.shield) > 0.0:
		draw_rect(Rect2(bx, by - 3.5, 32 * clampf(float(it.shield) / max_hp, 0.0, 1.0), 2.5),
				Color(0.95, 0.9, 0.5))
	var e := clampf(float(it.energy) / 100.0, 0.0, 1.0)
	draw_rect(Rect2(bx, ground.y + r * 0.45 + 2, 32, 2.5), Color(0, 0, 0, 0.8))
	draw_rect(Rect2(bx, ground.y + r * 0.45 + 2, 32 * e, 2.5),
			Color(1, 0.9, 0.35) if e >= 1.0 else Color(0.4, 0.65, 1.0))


## 只畫落在視窗裡的格子。
## 直接用斜角座標 u = x + y（上下）、v = x − y（左右）掃視窗範圍，
## 只會碰到真的在畫面裡的格子，而且 u 由小到大剛好就是「由遠到近」，不用再排序。
## （舊寫法是掃玩家周圍 63×63 的正方形再一格格剔除、最後排序。）
func _visible_cells() -> Array:
	var o := cam - VIEW.get_center()
	var wv := _world_view()
	var half_w := TW * 0.5
	var half_h := TH * 0.5
	var vmin := floori((wv.position.x - TW + o.x) / half_w)
	var vmax := ceili((wv.end.x + TW + o.x) / half_w)
	var umin := floori((wv.position.y - TH * 2.0 + o.y) / half_h) - 1
	var umax := ceili((wv.end.y + TH * 2.0 + _max_lift + o.y) / half_h)
	var out: Array = []
	for u in range(maxi(umin, 0), umax + 1):
		for v in range(vmin, vmax + 1):
			if (u + v) % 2 != 0 or u + v < 0 or u - v < 0:
				continue
			var c := Vector2i((u + v) / 2, (u - v) / 2)
			if ms.in_bounds(c) and ms.discovered.has(c):
				out.append(c)
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
	return _room_col.get(c, Color(0.3, 0.3, 0.34))


## 每格的底色（房間色＋手繪色差＋家具變暗）在地圖建好時算一次就好。
## 以前每一幀對每一格都要找房間、再把 "#7a5a42" 這種字串解析成顏色。
func _build_color_cache() -> void:
	_room_col.clear()
	_cell_col.clear()
	_max_lift = 0.0
	var parsed: Dictionary = {}
	for r in DB.map.rooms:
		parsed[r.id] = Color(r.color)
	for y in ms.height:
		for x in ms.width:
			var c := Vector2i(x, y)
			var base: Color = parsed.get(ms.room_at.get(c, ""), Color(0.3, 0.3, 0.34))
			_room_col[c] = base
			var col := base.lightened(_jitter(c, 1) * 0.16)    # 手繪的顏色不均
			if ms.is_wall(c):
				col = col.darkened(0.35)
			_cell_col[c] = col
			_max_lift = maxf(_max_lift, ms.height_of(c) * STEP_PX)


func _draw_content(c: Vector2i) -> void:
	var content = ms.cell_at(c)
	if content == null:
		return
	if battle != null and c == battle_cell:
		return          # 這群已經在場上展開成一隻隻的了
	var h := ms.height_of(c)
	var center := to_screen(Vector2(c), h) - Vector2(0, TH * 0.35)
	var seen := ms.is_visible(c)
	if content.kind == "monster":
		_draw_monster_group(c, center, seen)
	elif content.kind == "lair":
		# 巢穴就算離開視野也照樣畫清楚：找到一次就該記得它在哪
		Art.draw_cell_icon(self, "lair", center + Vector2(0, TH * 0.3), TW * 0.42)
	else:
		if seen:
			_ellipse(center + Vector2(0, TW * 0.26), TW * 0.24, TH * 0.17, Color(0, 0, 0, 0.32))
			Art.draw_cell_icon(self, content.kind, center, TW * 0.30)
		else:
			# 看過但現在不在視野內：記得那裡有什麼，畫成淡淡的
			Art.set_fade(0.35)
			Art.draw_cell_icon(self, content.kind, center, TW * 0.26)
			Art.set_fade(1.0)


## 怪群直接畫成一群怪：有幾隻、是哪幾種，都看得出來。
## 只畫在自己那一格裡叢聚，不往旁邊的格子擴張 —— 旁邊的格子其實走得過去，
## 畫上去會讓人誤判路線，也會跟「紅色影子＝實際開打位置」的保證打架。
const GROUP_SHOW_MAX := 7

func _draw_monster_group(c: Vector2i, center: Vector2, seen: bool) -> void:
	if not seen:
		# 看過但不在視野內：只記得「那邊有一群東西」，畫一隻淡淡的怪就好，大小代表規模。
		# （以前遠處每一群也各畫七個圓，探索越多越慢）
		var size_r: float = TW * {"monster_small": 0.2, "monster_mid": 0.26}.get(
				ms.cells[c].key, 0.32)
		var groups: Array = ms.encounter_groups(c)
		if not groups.is_empty():
			Art.set_fade(0.4)
			Art.draw_enemy(self, str(groups[0].id), center, size_r)
			Art.set_fade(1.0)
		return
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
		_ellipse(p + Vector2(0, r * 0.75), r * 0.7, r * 0.28, Color(0, 0, 0, 0.3))
		# 怪群會在原地蠢動（各自的節奏不同），看起來是活的
		p.y -= absf(sin(fx.anim_t * 2.6 + i * 1.7 + c.x * 0.9)) * 2.0
		Art.draw_enemy(self, roster[i], p, r)
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
	# 佈陣時你站的格子上也有棋子，鉛筆畫半透明才不會把它整個蓋住
	Art.set_fade(0.45 if formation_mode else 1.0)
	Art.draw_pencil(self, top - Vector2(0, 10), 26.0,
			clampf(ms.gs.mm / 40.0, 0.15, 1.0))
	Art.set_fade(1.0)
	draw_arc(center, TW * 0.3, 0, TAU, 20, Color(1, 0.95, 0.4, 0.55), 1.5)


func _ellipse(center: Vector2, rx: float, ry: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 16:
		var a: float = TAU * i / 16.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, col)


## 小地圖整張烘成一張圖（地板＋物件點），探索範圍、時段或物件變了才重畫。
## fill_rect 是引擎原生的，比每幀從腳本呼叫幾千次 draw_rect／draw_circle 快得多。
func _rebuild_minimap() -> void:
	var s := int(MINI_CELL)
	var img := Image.create(ms.width * s, ms.height * s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for c in ms.discovered:
		var col: Color = _room_color(c)
		if ms.is_wall(c):
			col = col.darkened(0.5)
		if ms.is_occupied(c):
			col = col.lerp(Color(0.95, 0.2, 0.15), 0.55)
		img.fill_rect(Rect2i(c.x * s, c.y * s, s, s), col)
	for c in ms.cells:
		if not ms.discovered.has(c):
			continue
		var content: Dictionary = ms.cells[c]
		var col := Color(0.95, 0.35, 0.3)
		var dot := 3
		match content.kind:
			"shop": col = Color(0.4, 0.8, 1.0)
			"chest": col = Color(1.0, 0.85, 0.3)
			"rest": col = Color(0.4, 1.0, 0.6)
			"copier": col = Color(0.85, 0.7, 1.0)
			"lair":
				col = Color(0.45, 1.0, 0.35)     # 巢穴：亮綠色大點，找到之後一眼看得到
				dot = 6
			"monster":
				# 點的大小代表怪群規模，一眼看得出哪邊硬
				dot = {"monster_small": 2, "monster_mid": 4}.get(content.key, 6)
		var off := (s - dot) / 2
		img.fill_rect(Rect2i(c.x * s + off, c.y * s + off, dot, dot), col)
	if _mini_tex == null:
		_mini_tex = ImageTexture.create_from_image(img)
	else:
		_mini_tex.update(img)


## 小地圖：俯視、只畫走過的地方。這是判斷「東西大概在哪」的主要依據。
func _draw_minimap() -> void:
	draw_rect(MINI.grow(4), Color(0.07, 0.08, 0.11))
	draw_rect(MINI.grow(4), Color(0.4, 0.43, 0.5), false, 1.0)
	# 地板與物件點都烘在同一張圖裡，貼一次就好。
	# 以前每一幀對每個探索過的格子各畫一個方塊（最多 2160 次），物件再各畫一個圓。
	var sig := "%d|%d|%d|%s" % [ms.discovered.size(), ms.seg, ms.cells.size(), ms.day_over]
	if sig != _mini_sig:
		_mini_sig = sig
		_rebuild_minimap()
	draw_texture(_mini_tex, MINI.position)
	var pp: Vector2 = MINI.position + (Vector2(ms.pos) + Vector2(0.5, 0.5)) * MINI_CELL
	draw_circle(pp, MINI_CELL * 0.8, Color(1, 0.95, 0.4))
	draw_arc(pp, MINI_CELL * 1.6, 0, TAU, 16, Color(1, 0.95, 0.4, 0.6), 1.0)
	draw_string(font, MINI.position + Vector2(-2, MINI.size.y + 18),
			"小地圖：紅=怪　藍=抽屜　金=寶箱　綠=休息　紫=影印　亮綠大點=巢穴",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.62, 0.66, 0.76))
	# 地圖縮放倍率（在地圖視窗左上角；左下角佈陣時會被備戰席蓋住）
	draw_string(font, Vector2(VIEW.position.x + 10, VIEW.position.y + 18),
			"滾輪縮放　×%.1f" % zoom, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.62, 0.66, 0.76, 0.8))
