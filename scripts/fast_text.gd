extends Control
## 轻量文字控件：游戏卡片上用。
## 普通 Label 每次排版含汉字 / 假名的文字都要好几毫秒，游戏库有几千张卡片时会明显卡顿；
## 这里直接用 TextParagraph 在 _draw 里排版绘制，速度快很多，显示效果相同。

var text := "":
	set(v):
		text = v
		_dirty = true
		queue_redraw()
var font_size := 0          ## 0 = 使用主题字号
var color := Color.WHITE:
	set(v):
		color = v
		queue_redraw()
var shadow_color := Color(0, 0, 0, 0)
var shadow_offset := Vector2.ZERO
var wrap := false           ## true = 按字换行（超出高度时末尾显示省略号）
var valign := 0             ## 0 上 / 1 中 / 2 下

var _para := TextParagraph.new()
var _dirty := true

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		_dirty = true
		queue_redraw()

func _rebuild() -> void:
	_dirty = false
	_para.clear()
	var f := get_theme_font("font", "Label")
	var fs := font_size if font_size > 0 else get_theme_font_size("font_size", "Label")
	_para.add_string(text, f, fs)
	_para.width = maxf(size.x, 1.0)
	_para.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if wrap:
		_para.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_GRAPHEME_BOUND
		var lh := f.get_height(fs)
		_para.max_lines_visible = maxi(1, floori(size.y / maxf(lh, 1.0)))
	else:
		_para.break_flags = TextServer.BREAK_MANDATORY
		_para.max_lines_visible = 1

func _draw() -> void:
	if text == "":
		return
	if _dirty:
		_rebuild()
	var n := mini(_para.get_line_count(), _para.max_lines_visible)
	var h := 0.0
	for i in n:
		h += _para.get_line_size(i).y
	var y := 0.0
	if valign == 1:
		y = (size.y - h) / 2.0
	elif valign == 2:
		y = size.y - h
	if shadow_color.a > 0.0:
		_para.draw(get_canvas_item(), Vector2(0, y) + shadow_offset, shadow_color)
	_para.draw(get_canvas_item(), Vector2(0, y), color)
