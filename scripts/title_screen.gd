extends Control
## 標題畫面：遊戲名、一句世界觀、開始按鈕、玩法速查。
## 背景的房子與鉛筆一樣是程式畫的。

const Art = preload("res://scripts/art.gd")
const UITheme = preload("res://scripts/ui_theme.gd")

signal start_pressed()

var font: Font
var t := 0.0
var help_open := false
var help_label: Label
var btn_help: Button


func _ready() -> void:
	font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)

	var btn_start := Button.new()
	btn_start.text = "開始遊戲"
	btn_start.position = Vector2(140, 520)
	btn_start.size = Vector2(220, 56)
	btn_start.add_theme_font_size_override("font_size", 22)
	btn_start.pressed.connect(func(): start_pressed.emit())
	add_child(btn_start)

	btn_help = Button.new()
	btn_help.text = "玩法說明"
	btn_help.position = Vector2(380, 520)
	btn_help.size = Vector2(160, 56)
	btn_help.add_theme_font_size_override("font_size", 18)
	btn_help.pressed.connect(_toggle_help)
	add_child(btn_help)

	help_label = Label.new()
	help_label.position = Vector2(140, 596)
	help_label.size = Vector2(600, 190)
	help_label.add_theme_font_size_override("font_size", 14)
	help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help_label.visible = false
	help_label.text = """一、在房子地圖上左鍵點格子移動，每走一格扣時間。點怪群會先走到旁邊，再點一次開打。滾輪可以放大縮小地圖。
二、戰鬥全自動，你只在開戰前擺位。戰場地形由你站的那一格決定，繞到別格再打就是換戰場。
三、同流派／同特徵湊夠件數會啟動羈絆；三件同名同星會合成高一星。
四、撐過早上、下午、晚上三個時段，天黑後打五波最終決戰。"""
	add_child(help_label)


func _toggle_help() -> void:
	help_open = not help_open
	help_label.visible = help_open
	btn_help.text = "收起說明" if help_open else "玩法說明"


func _process(delta: float) -> void:
	t += delta
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), UITheme.BG)
	_draw_desk()
	_draw_house(Vector2(1010, 320), 190.0)
	# 標題
	var title_pos := Vector2(140, 246)
	_big(title_pos, "鉛棋百怪", 76, Color(1.0, 0.88, 0.4))
	_big(title_pos + Vector2(4, 56), "用魔法鉛筆，把家裡的東西寫成戰士", 22, Color(0.82, 0.85, 0.92))
	_big(title_pos + Vector2(4, 92), "主人出門的夜裡，害蟲、灰塵與黴菌開始作亂。", 16, Color(0.6, 0.64, 0.74))
	_big(title_pos + Vector2(4, 118), "書桌上的鉛筆醒了過來 —— 筆芯就是力量，寫得越多，鉛筆就越短。", 16, Color(0.6, 0.64, 0.74))
	# 主角鉛筆，會輕輕浮動
	var pen := Vector2(772, 318) + Vector2(0, sin(t * 1.6) * 10.0)
	Art.draw_pencil(self, pen, 92.0, 0.55 + sin(t * 0.8) * 0.3)
	# 幾隻怪在桌面上晃
	var ids := ["dust", "roach", "mold", "hairball", "ant", "spore"]
	for i in ids.size():
		var p := Vector2(760 + i * 86, 556 + sin(t * 2.0 + i) * 7.0)
		Art.draw_enemy(self, ids[i], p, 28.0)


## 背景的書桌：木紋橫線 + 一張方格紙
func _draw_desk() -> void:
	draw_rect(Rect2(0, 470, size.x, size.y - 470), Color(0.19, 0.145, 0.11))
	for i in 24:
		var y: float = 480.0 + i * 14.0
		draw_line(Vector2(0, y), Vector2(size.x, y), Color(0, 0, 0, 0.10), 1.0)
	# 標題背後的方格紙
	var paper := Rect2(108, 168, 568, 268)
	draw_rect(paper, Color(0.95, 0.94, 0.88, 0.055))
	draw_rect(paper, Color(0.95, 0.94, 0.88, 0.14), false, 1.5)
	for i in 13:
		draw_line(Vector2(paper.position.x, paper.position.y + 20 + i * 20),
				Vector2(paper.end.x, paper.position.y + 20 + i * 20), Color(1, 1, 1, 0.035), 1.0)


static func _house_pts(c: Vector2, s: float) -> Array:
	return [c + Vector2(-s, -s * 0.1), c + Vector2(0, -s * 0.75), c + Vector2(s, -s * 0.1)]


func _draw_house(c: Vector2, s: float) -> void:
	var wall := Color(0.30, 0.33, 0.42)
	var roof := Color(0.46, 0.30, 0.30)
	draw_colored_polygon(PackedVector2Array(_house_pts(c, s)), roof)
	draw_rect(Rect2(c + Vector2(-s * 0.78, -s * 0.1), Vector2(s * 1.56, s * 0.85)), wall)
	for i in 2:
		for j in 2:
			var w := Rect2(c + Vector2(-s * 0.55 + i * s * 0.62, s * 0.02 + j * s * 0.34),
					Vector2(s * 0.3, s * 0.22))
			draw_rect(w, Color(1.0, 0.88, 0.5, 0.85))
			draw_rect(w, Color(0.2, 0.18, 0.2), false, 2.0)
	draw_rect(Rect2(c + Vector2(-s * 0.12, s * 0.42), Vector2(s * 0.26, s * 0.33)),
			Color(0.35, 0.24, 0.2))


func _big(p: Vector2, text: String, s: int, col: Color) -> void:
	draw_string_outline(font, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, s, 6, Color(0, 0, 0, 0.8))
	draw_string(font, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, s, col)
