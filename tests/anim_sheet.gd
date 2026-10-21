extends SceneTree
## 出手動作對照表（看圖用，不是自動測試）：每件物品打一個沙包，
## 一列是一件物品，從左到右是蓄力 → 命中 → 收招的幾個瞬間。輸出到 shots/anim_sheet_N.png。
## 執行（不能 headless，要真的畫出來）：Godot --path . --script tests/anim_sheet.gd

const DB = preload("res://scripts/db.gd")
const Art = preload("res://scripts/art.gd")
const BattleSim = preload("res://scripts/sim/battle_sim.gd")
const BattleFx = preload("res://scripts/battle_fx.gd")
const ItemMoves = preload("res://scripts/item_moves.gd")

const ROWS := 10
const R := 15.0
const TW := 48.0
const TH := 26.0
const STEPS := [-2.5, -1.5, -0.7, 0.0, 0.5, 1.2, 2.2]     # 相對「命中」的 tick

var rows: Array = []        # [{id, fx, hit_t}]
var page := 0
var frames := 0


class Sheet extends Control:
	var owner_tree


	func _draw() -> void:
		owner_tree.draw_sheet(self)


func _init() -> void:
	DB.load_all()
	DisplayServer.window_set_size(Vector2i(1280, 800))
	for id in DB.units.keys():
		var d: Dictionary = DB.units[id]
		var hero := {
			"id": id, "name": d.name, "school": d.school, "traits": d.traits,
			"star": 1, "smult": 1.0, "hp": 99999.0, "atk": float(d.atk), "aspd": d.aspd,
			"range": d.range, "move": d.move, "armor": d.armor, "skill": d.get("skill", {}),
			"cell": Vector2i(0, 1), "fx": {},
		}
		var dummy := {
			"id": "dust", "name": "沙包", "school": "害蟲", "traits": [], "star": 1, "smult": 1.0,
			"hp": 99999.0, "atk": 0.1, "aspd": 0.3, "range": 1, "move": 0.01, "armor": 0,
			"skill": {}, "cell": Vector2i(int(d.range), 1), "fx": {},
		}
		var sim := BattleSim.new()
		sim.setup(1, [hero], [dummy], {}, {"w": 6, "h": 3})
		sim.run()
		var fx := BattleFx.new()
		fx.set_sim(sim)
		var hit_t := -1.0
		for e in sim.events:
			if e.type == "hit" and int(e.src) == 0 and float(e.t) > 6.0:
				hit_t = float(e.t)
				break
		rows.append({"id": id, "fx": fx, "hit_t": hit_t})
	var sheet := Sheet.new()
	sheet.owner_tree = self
	sheet.size = Vector2(1280, 800)
	root.add_child(sheet)
	process_frame.connect(_on_frame.bind(sheet))


func _on_frame(sheet: Control) -> void:
	frames += 1
	if frames % 3 != 0:
		sheet.queue_redraw()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://shots"))
	root.get_texture().get_image().save_png("res://shots/anim_sheet_%d.png" % page)
	page += 1
	if page * ROWS >= rows.size():
		quit(0)
	sheet.queue_redraw()


func draw_sheet(c: Control) -> void:
	var font := ThemeDB.fallback_font
	c.draw_rect(Rect2(0, 0, 1280, 800), Color(0.16, 0.15, 0.14))
	for j in STEPS.size():
		var s: float = STEPS[j]
		c.draw_string(font, Vector2(130 + j * 160, 18), "命中 %+.1f" % s if s != 0.0 else "命中",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 0.9, 0.5) if s == 0.0 else Color(0.8, 0.8, 0.8))
	for i in ROWS:
		var k := page * ROWS + i
		if k >= rows.size():
			break
		var row: Dictionary = rows[k]
		var y := 30.0 + i * 77.0
		c.draw_string(font, Vector2(8, y + 45), "%s" % DB.units[row.id].name, HORIZONTAL_ALIGNMENT_LEFT,
				-1, 14, Color.WHITE)
		c.draw_string(font, Vector2(8, y + 62), "%s" % " / ".join(ItemMoves.move_of(row.id, false)),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.7, 0.7, 0.7))
		for j in STEPS.size():
			var o := Vector2(170 + j * 160, y + 38)
			c.draw_rect(Rect2(o - Vector2(48, 34), Vector2(156, 74)), Color(0.24, 0.23, 0.21))
			if float(row.hit_t) < 0.0:
				continue
			_draw_moment(c, row.fx, o, float(row.hit_t) + float(STEPS[j]), font)


func _draw_moment(c: Control, fx, o: Vector2, t: float, font: Font) -> void:
	fx.tick_f = t
	fx.anim_t = 0.0
	var ground := func(g: Vector2) -> Vector2: return o + Vector2((g.x - g.y) * TW * 0.5, (g.x + g.y - 1.0) * TH * 0.5)
	var proj := func(g: Vector2) -> Vector2: return ground.call(g) - Vector2(0, R * 0.9)
	var items: Array = fx.gather()
	for it in items:
		var is_enemy: bool = int(it.team) == 1
		var p: Dictionary = fx.pose(it, proj).duplicate()
		var g: Vector2 = ground.call(it.grid)
		Art.draw_team_ring(c, g, R, is_enemy)
		p.flash = fx.flash(int(it.uid))
		Art.draw_figure(c, str(it.id), g + p.off, R, is_enemy, p)
	fx.draw_over(c, items, proj, font, R)
