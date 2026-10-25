class_name UITheme
extends RefCounted
## 深色商城主题（代码构建，避免外部资源）

const BG := Color("#14171c")
const SIDEBAR := Color("#0c0e12")
const PANEL := Color("#1c2027")
const PANEL_HI := Color("#252b34")
const ACCENT := Color("#1a9fff")
const ACCENT_HI := Color("#47b4ff")
const GREEN := Color("#5cb85c")
const TEXT := Color("#e8eaed")
const MUTED := Color("#8d96a5")
const DANGER := Color("#e05555")
const BORDER := Color("#252b35")

static func box(c: Color, radius := 8, pad := 10, border := Color(0, 0, 0, 0), bw := 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad
	s.content_margin_right = pad
	s.content_margin_top = pad * 0.6
	s.content_margin_bottom = pad * 0.6
	if bw > 0:
		s.border_color = border
		s.set_border_width_all(bw)
	return s

## 设置分组 / 信息面板：圆角卡片 + 细边框，内边距统一
static func card_panel(pad := 24) -> StyleBoxFlat:
	var s := box(PANEL, 12, pad, BORDER, 1)
	s.content_margin_top = pad * 0.8
	s.content_margin_bottom = pad * 0.8
	return s

## 侧边栏：右侧细分隔线，四周留足内边距
static func sidebar_panel() -> StyleBoxFlat:
	var s := box(SIDEBAR, 0, 16)
	s.content_margin_top = 22
	s.content_margin_bottom = 18
	s.border_color = BORDER
	s.border_width_right = 1
	return s

## 每种界面语言优先使用对应地区的系统字体（字形更地道），都找不到时依次回退
const FONTS_BY_LOCALE := {
	"zh_CN": ["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "Source Han Sans SC", "PingFang SC", "WenQuanYi Micro Hei"],
	"zh_TW": ["Microsoft JhengHei UI", "Microsoft JhengHei", "Noto Sans CJK TC", "Source Han Sans TC", "PingFang TC", "Microsoft YaHei UI"],
	"ja": ["Yu Gothic UI", "Meiryo UI", "Meiryo", "MS UI Gothic", "Noto Sans CJK JP", "Source Han Sans JP", "Hiragino Sans", "Microsoft YaHei UI"],
	"en": ["Segoe UI", "Noto Sans", "DejaVu Sans", "Microsoft YaHei UI", "Noto Sans CJK SC"],
}

static func make_theme(locale := "zh_CN") -> Theme:
	var t := Theme.new()
	var f := SystemFont.new()
	var names: Array = FONTS_BY_LOCALE.get(locale, FONTS_BY_LOCALE["zh_CN"]).duplicate()
	for n in FONTS_BY_LOCALE["zh_CN"]:
		if not n in names:
			names.append(n)
	names.append("sans-serif")
	f.font_names = PackedStringArray(names)
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	t.default_font = f
	# 安卓上 SystemFont 只能匹配到 Roboto，汉字靠逐字回退能显示，但全角标点（，。、）等）会变成方块。
	# 因此直接加载系统自带的 CJK 字体文件，并按界面语言选择 TTC 中对应地区的字形。
	if OS.get_name() == "Android":
		var cjk := _android_cjk_font(locale)
		if cjk:
			if locale == "en":
				f.fallbacks = [cjk]
			else:
				cjk.fallbacks = [f]
				t.default_font = cjk
	t.default_font_size = 15
	# 还没加入场景树的控件（例如正在创建的游戏卡片）会用全局后备字体排版；后备字体没有汉字时
	# 每个标签都要去系统里查找回退字体，几千张卡片会很慢。所以把全局后备字体也设成界面字体。
	ThemeDB.fallback_font = t.default_font
	ThemeDB.fallback_font_size = 15
	t.set_color("font_color", "Label", TEXT)
	for cls in ["Button", "OptionButton", "MenuButton", "CheckBox"]:
		t.set_color("font_color", cls, TEXT)
		t.set_color("font_hover_color", cls, Color.WHITE)
		t.set_color("font_pressed_color", cls, Color.WHITE)
		t.set_color("font_focus_color", cls, Color.WHITE)
	t.set_stylebox("normal", "Button", box(PANEL_HI, 6, 14))
	t.set_stylebox("hover", "Button", box(Color("#323a46"), 6, 14))
	t.set_stylebox("pressed", "Button", box(Color("#3b4452"), 6, 14))
	t.set_stylebox("focus", "Button", box(Color(0, 0, 0, 0), 6, 14, ACCENT, 1))
	t.set_stylebox("disabled", "Button", box(Color("#1d2128"), 6, 14))
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		t.set_stylebox(st, "OptionButton", t.get_stylebox(st, "Button"))
		t.set_stylebox(st, "MenuButton", t.get_stylebox(st, "Button"))
	t.set_stylebox("normal", "LineEdit", box(Color("#0f1216"), 6, 10, Color("#2c333d"), 1))
	t.set_stylebox("focus", "LineEdit", box(Color("#0f1216"), 6, 10, ACCENT, 1))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", MUTED)
	t.set_stylebox("panel", "PanelContainer", box(PANEL, 10, 16))
	t.set_stylebox("panel", "PopupMenu", box(Color("#1f242c"), 6, 6, Color("#2f3742"), 1))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	t.set_stylebox("hover", "PopupMenu", box(ACCENT, 4, 6))
	t.set_stylebox("panel", "PopupPanel", box(Color("#1f242c"), 8, 12, Color("#2f3742"), 1))
	t.set_stylebox("panel", "AcceptDialog", box(Color("#1f242c"), 8, 16))
	t.set_stylebox("embedded_border", "Window", box(Color("#1f242c"), 8, 8, Color("#2f3742"), 1))
	t.set_color("title_color", "Window", TEXT)
	var grab := box(Color("#3a4250"), 4, 0)
	t.set_stylebox("grabber", "VScrollBar", grab)
	t.set_stylebox("grabber_highlight", "VScrollBar", box(Color("#4b5566"), 4, 0))
	t.set_stylebox("scroll", "VScrollBar", box(Color(0, 0, 0, 0), 4, 4))
	return t

static func accent_button(b: Button, big := false) -> void:
	var pad := 28 if big else 16
	b.add_theme_stylebox_override("normal", box(ACCENT, 6, pad))
	b.add_theme_stylebox_override("hover", box(ACCENT_HI, 6, pad))
	b.add_theme_stylebox_override("pressed", box(Color("#1580d0"), 6, pad))
	b.add_theme_stylebox_override("focus", box(Color(0, 0, 0, 0), 6, pad, Color.WHITE, 1))
	if big:
		b.add_theme_font_size_override("font_size", 20)
		b.custom_minimum_size = Vector2(220, 54)

static func sidebar_button(b: Button, active: bool) -> void:
	var c := Color("#1f2a38") if active else Color(0, 0, 0, 0)
	var s := box(c, 6, 14)
	if active:
		s.border_color = ACCENT
		s.border_width_left = 3
	b.add_theme_stylebox_override("normal", s)
	b.add_theme_stylebox_override("hover", box(Color("#18202b"), 6, 14))
	b.add_theme_stylebox_override("focus", box(Color(0, 0, 0, 0), 6, 14))
	b.add_theme_color_override("font_color", TEXT if active else MUTED)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", 16)

## 根据标题生成渐变占位封面
static func cover_texture(g: Dictionary, w := 300, h := 400) -> Texture2D:
	var cover := str(g.get("cover", ""))
	if cover != "" and FileAccess.file_exists(cover):
		var img := Image.load_from_file(cover)
		if img:
			return ImageTexture.create_from_image(img)
	var hsh: int = abs(str(g.get("title", "")).hash())
	# 渐变封面：低分辨率生成后由显卡拉伸（线性渐变放大后看不出差别），并按颜色缓存，
	# 这样游戏库里有几千款游戏时也不会卡
	w = maxi(8, w / 6)
	h = maxi(8, h / 6)
	var ck := "%d_%d_%dx%d" % [hsh % 360, (hsh >> 9) % 30, w, h]
	if _grad_cache.has(ck):
		return _grad_cache[ck]
	var h1 := float(hsh % 360) / 360.0
	var h2 := fmod(h1 + 0.12 + float((hsh >> 9) % 30) / 100.0, 1.0)
	var grad := Gradient.new()
	grad.set_color(0, Color.from_hsv(h1, 0.75, 0.55))
	grad.set_color(1, Color.from_hsv(h2, 0.85, 0.22))
	grad.add_point(0.55, Color.from_hsv(fmod(h1 + 0.06, 1.0), 0.8, 0.38))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.width = w
	gt.height = h
	gt.fill = GradientTexture2D.FILL_LINEAR
	gt.fill_from = Vector2(0.0, 0.0)
	gt.fill_to = Vector2(1.0, 1.0)
	if _grad_cache.size() > 2000:
		_grad_cache.clear()
	_grad_cache[ck] = gt
	return gt

static var _grad_cache := {}

static func has_custom_cover(g: Dictionary) -> bool:
	var c := str(g.get("cover", ""))
	return c != "" and FileAccess.file_exists(c)


## 安卓系统 CJK 字体（NotoSansCJK-Regular.ttc 的序号：0=日 1=韩 2=简 3=繁），找不到时返回 null
static func _android_cjk_font(locale: String) -> FontFile:
	var idx: int = {"ja": 0, "zh_TW": 3}.get(locale, 2)
	for cand in [["/system/fonts/NotoSansCJK-Regular.ttc", idx], ["/system/fonts/NotoSansSC-Regular.otf", 0],
			["/system/fonts/DroidSansFallbackFull.ttf", 0], ["/system/fonts/DroidSansFallback.ttf", 0]]:
		if FileAccess.file_exists(cand[0]):
			var ff := FontFile.new()
			if ff.load_dynamic_font(cand[0]) == OK:
				ff.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
				if cand[1] > 0 and ff.get_face_count() > cand[1]:
					ff.face_index = cand[1]
				return ff
	return null
