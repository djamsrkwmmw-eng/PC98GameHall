extends Control
## PC-98 游戏厅 —— 主界面（游戏库 / 最近游玩 / 设置 / 详情 / 模拟器）

const EmuView := preload("res://scripts/emu_view.gd")

var theme_res: Theme
var sidebar_buttons := {}
var content: Control
var pages := {}
var current_page := ""
var detail_game_id := ""
var search_edit: LineEdit
var lib_grid: HFlowContainer
var recent_grid: HFlowContainer
var lib_count_label: Label
var bios_status_label: Label
var emu_view: Control
var file_dialog: FileDialog
var _fd_callback: Callable
var toast_label: Label
var ui_root: Control
var _rebuild_pending := false

# settings widgets
var s_bios: LineEdit
var s_bios_info: Label
var s_font_mode: OptionButton
var s_font_file: LineEdit
var s_ttf: LineEdit
var s_kbd: OptionButton
var s_model: OptionButton
var s_esc: CheckBox
var s_lang: OptionButton
var s_scale: OptionButton
var side_lang: OptionButton
var s_fs_button: Button
var a_title: LineEdit
var a_fdd1: LineEdit
var a_fdd2: LineEdit
var a_hdd: LineEdit
var a_cover: LineEdit
var settings_scroll: ScrollContainer
var add_panel: Control

# ---- 移动端（Android / --force-mobile）：底部标签栏、自适应网格、纵向排列的设置与详情页
var mobile := false
var lib_card_w := 196
var m_bios_info: Label
var s_touch_pad: CheckBox
var s_touch_mouse: CheckBox
var s_mouse: CheckBox
var s_mouse_sens: HSlider
var s_mouse_sens_val: Label
var cat_filter: OptionButton
var lib_scan_btn: Button
var s_libroot: LineEdit
var s_lib_auto: CheckBox
var s_lib_status: Label
var s_lib_unhide: Button
var _lib_limit := LIB_PAGE
var _toast_tw: Tween
var _card_gen := 0
const CARD_BATCH := 36
const FastText := preload("res://scripts/fast_text.gd")
var _cat_keys: Array = []
const LIB_PAGE := 240        # 游戏库一次最多显示的卡片数（数千款时不卡顿），可点「显示更多」
const MOBILE_GAP := 12
const TOUCH_H := 48

const FDD_FILTERS := ["*.fdi, *.FDI ; FDI 软盘镜像", "*.d88, *.D88, *.88d, *.d98, *.98d ; D88 软盘镜像", "*.hdm, *.HDM, *.xdf, *.dup, *.2hd, *.tfd, *.nfd, *.fdd, *.img ; 其它软盘镜像", "* ; 所有文件"]
const HDD_FILTERS := ["*.hdi, *.HDI ; HDI 硬盘镜像", "*.nhd, *.thd, *.vhd, *.slh, *.hdn ; 其它硬盘镜像", "* ; 所有文件"]
const FONT_FILTERS := ["*.rom, *.ROM, *.bmp, *.BMP, *.bin ; 字体 ROM / 字体位图 (FONT.ROM, font.bmp)", "* ; 所有文件"]
const TTF_FILTERS := ["*.ttf, *.ttc, *.otf, *.TTF, *.TTC, *.OTF ; TrueType / OpenType 字体", "* ; 所有文件"]
## 宽屏布局参数：内容区最大宽度（全屏时居中显示，两侧留白）
const SIDEBAR_W := 240
const BIOS_OPTIONAL_NOTE := "BIOS 是可选的：不放入时自动使用 NP2kai 内置的兼容 BIOS，并用系统字体生成汉字字库；放入真机 BIOS 兼容性更好。"
const BUILTIN_BIOS_COLOR := Color("#d9b84a")  # 内置兼容 BIOS：黄色提示（不是错误）
const LIB_MAX_W := 1320.0
const DETAIL_MAX_W := 1200.0
const SETTINGS_MAX_W := 1000.0
const CARD_W := 196
const GRID_GAP := 22
const ROW_LABEL_W := 150
const OPTION_W := 400
const IMG_FILTERS := ["*.png, *.jpg, *.jpeg, *.webp, *.bmp ; 图片", "* ; 所有文件"]

const APP_ICON := "res://assets/icon_256.png"
const APP_ICON_ICO := "res://assets/icon.ico"


# 运行时窗口 / 任务栏图标：桌面版启动时设置成游戏厅图标（不再用 Godot 默认图标）
func _apply_window_icon() -> void:
	if mobile:
		return
	# Windows：用多尺寸 .ico（16~256）做窗口/任务栏图标，系统按需挑选清晰的尺寸
	if OS.get_name() == "Windows" and DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_ICON) \
			and FileAccess.file_exists(APP_ICON_ICO):
		DisplayServer.set_native_icon(APP_ICON_ICO)
		return
	if not DisplayServer.has_feature(DisplayServer.FEATURE_ICON):
		return
	var tex := load(APP_ICON) as Texture2D
	if tex == null:
		return
	var img := tex.get_image()
	if img == null or img.is_empty():
		return
	if img.is_compressed():
		img.decompress()
	DisplayServer.set_icon(img)


func _ready() -> void:
	mobile = Store.is_mobile()
	theme_res = UITheme.make_theme(TranslationServer.get_locale())
	if mobile:
		theme_res.default_font_size = 16
		_apply_mobile_scale()
		get_tree().root.size_changed.connect(_on_mobile_resized)
		get_tree().node_added.connect(_on_mobile_node_added)
	theme = theme_res
	if not mobile:
		get_window().min_size = Vector2i(960, 600)
	get_window().title = tr("PC-98 游戏厅")
	_apply_window_icon()
	_build_ui()
	Store.library_changed.connect(_refresh_lists)
	Store.scan_progress.connect(_on_scan_progress)
	Store.scan_finished.connect(_on_scan_finished)
	Store.fullscreen_changed.connect(func(_on): _update_fs_button())
	_refresh_lists()
	_load_settings_into_form()
	show_page("library")
	if bool(Store.settings.get("fullscreen", false)) and not mobile:
		Store.set_fullscreen(true)
	_run_cmdline_tests.call_deferred()
	if bool(Store.settings.get("library_autoscan", true)) and str(Store.settings.get("library_root", "")) != "" \
			and not _has_test_args():
		_start_scan.call_deferred()

## 按屏幕 DPI 缩放界面（160 dpi = 1 倍，与 Android 的 dp 相同），触控目标约 48 dp
func _apply_mobile_scale() -> void:
	var f := 1.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mobile-scale="):
			f = float(a.split("=", true, 1)[1])
	if f == 1.0 and OS.has_feature("mobile"):
		f = clampf(DisplayServer.screen_get_dpi() / 160.0, 1.0, 4.0)
	get_window().content_scale_factor = f

func _on_mobile_resized() -> void:
	if lib_grid:
		_mobile_grid_resized.call_deferred()

## Android 返回键：游戏中打开菜单；详情 / 其它页面返回游戏库；游戏库中询问是否退出
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		on_back()

func on_back() -> void:
	if emu_view != null and emu_view.visible:
		emu_view.on_back()
	elif current_page != "library":
		show_page("library")
	else:
		_confirm(tr("要退出 PC-98 游戏厅吗？"), func(): get_tree().quit())

## 全局快捷键：Alt+Enter 切换全屏（游戏中由 emu_view 处理）；在游戏库界面 Esc 退出全屏
func _input(event: InputEvent) -> void:
	if emu_view != null and emu_view.visible:
		return
	if event is InputEventKey:
		var k := event as InputEventKey
		var code: int = k.physical_keycode if k.physical_keycode != 0 else k.keycode
		if (code == KEY_ENTER or code == KEY_KP_ENTER) and k.alt_pressed:
			if k.pressed and not k.echo:
				Store.toggle_fullscreen()
			get_viewport().set_input_as_handled()
		elif code == KEY_ESCAPE and k.pressed and not k.echo and Store.is_fullscreen():
			Store.set_fullscreen(false)
			get_viewport().set_input_as_handled()

# =================================================================== language
## 切换界面语言：设置 locale、保存设置，然后重建整个界面（游戏中的菜单通过自动翻译 / 重新生成文本更新）
func set_language(locale: String) -> void:
	if locale == Store.get_language():
		return
	Store.set_language(locale)
	if not _rebuild_pending:
		_rebuild_pending = true
		_rebuild_ui.call_deferred()

func _rebuild_ui() -> void:
	_rebuild_pending = false
	theme_res = UITheme.make_theme(TranslationServer.get_locale())
	theme = theme_res
	get_window().title = tr("PC-98 游戏厅")
	var page := current_page
	var scroll := 0
	if settings_scroll:
		scroll = settings_scroll.scroll_vertical
	if ui_root:
		remove_child(ui_root)
		ui_root.queue_free()
	sidebar_buttons = {}
	pages = {}
	m_bios_info = null
	_build_main_ui()
	move_child(ui_root, 0)
	_refresh_lists()
	_load_settings_into_form()
	if page == "detail" and detail_game_id != "":
		show_detail(detail_game_id)
	else:
		show_page(page if page != "" else "library")
	if page == "settings":
		await get_tree().process_frame
		settings_scroll.scroll_vertical = scroll
	toast(tr("界面语言已切换为：%s") % I18n.language_name(Store.get_language()))

func _make_lang_option() -> OptionButton:
	var o := OptionButton.new()
	o.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED  # 语言名称始终用各自的语言显示
	for i in I18n.LOCALES.size():
		o.add_item(I18n.LANG_NAMES[i], i)
	o.select(maxi(0, I18n.LOCALES.find(Store.get_language())))
	o.item_selected.connect(func(i): set_language(I18n.LOCALES[i]))
	return o

# =================================================================== layout
func _build_ui() -> void:
	_build_main_ui()
	_build_overlays()

## 游戏库 / 设置等主界面（切换语言时整体重建）
func _build_main_ui() -> void:
	ui_root = Control.new()
	ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(ui_root)
	var bg := ColorRect.new()
	bg.color = UITheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui_root.add_child(bg)
	if mobile:
		_build_mobile_main_ui()
		return

	var root := HBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	ui_root.add_child(root)

	# ---- sidebar
	var side := PanelContainer.new()
	side.custom_minimum_size = Vector2(SIDEBAR_W, 0)
	side.add_theme_stylebox_override("panel", UITheme.sidebar_panel())
	root.add_child(side)
	var sv := VBoxContainer.new()
	sv.add_theme_constant_override("separation", 6)
	side.add_child(sv)
	var logo := HBoxContainer.new()
	logo.add_theme_constant_override("separation", 10)
	var icon := TextureRect.new()
	icon.texture = load(APP_ICON)
	icon.custom_minimum_size = Vector2(40, 40)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.add_child(icon)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", -2)
	var lt := Label.new()
	lt.text = tr("PC-98 游戏厅")
	lt.add_theme_font_size_override("font_size", 19)
	lv.add_child(lt)
	var ls := Label.new()
	ls.text = tr("NP2kai 内核")
	ls.add_theme_color_override("font_color", UITheme.MUTED)
	ls.add_theme_font_size_override("font_size", 12)
	lv.add_child(ls)
	logo.add_child(lv)
	sv.add_child(logo)
	sv.add_child(_spacer(18))
	for item in [["library", tr("▦  游戏库")], ["recent", tr("◷  最近游玩")], ["settings", tr("⚙  设置")]]:
		var b := Button.new()
		b.text = item[1]
		b.custom_minimum_size = Vector2(0, 44)
		b.pressed.connect(show_page.bind(item[0]))
		sv.add_child(b)
		sidebar_buttons[item[0]] = b
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sv.add_child(fill)
	# 底部状态卡片：BIOS 状态 + 界面语言（放在卡片内，留足内边距，避免贴边或被裁切）
	var status := PanelContainer.new()
	status.add_theme_stylebox_override("panel", UITheme.box(Color("#13171d"), 10, 12, UITheme.BORDER, 1))
	var stv := VBoxContainer.new()
	stv.add_theme_constant_override("separation", 8)
	status.add_child(stv)
	bios_status_label = Label.new()
	bios_status_label.add_theme_font_size_override("font_size", 12)
	bios_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bios_status_label.custom_minimum_size = Vector2(SIDEBAR_W - 70, 0)
	bios_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stv.add_child(bios_status_label)
	var lang_row := HBoxContainer.new()
	lang_row.add_theme_constant_override("separation", 6)
	var gl := Label.new()
	gl.text = "🌐"
	gl.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	gl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lang_row.add_child(gl)
	side_lang = _make_lang_option()
	side_lang.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_lang.custom_minimum_size = Vector2(0, 34)
	side_lang.clip_text = true
	side_lang.tooltip_text = tr("界面语言")
	lang_row.add_child(side_lang)
	stv.add_child(lang_row)
	sv.add_child(status)

	# ---- content
	content = Control.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(content)
	# 内容区顶部的柔和光晕，增加层次感
	var glow := TextureRect.new()
	var gg := Gradient.new()
	gg.set_color(0, Color("#1c2636"))
	gg.set_color(1, Color(UITheme.BG, 0.0))
	var ggt := GradientTexture2D.new()
	ggt.gradient = gg
	ggt.fill_from = Vector2(0, 0)
	ggt.fill_to = Vector2(0, 1)
	glow.texture = ggt
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.set_anchors_preset(Control.PRESET_TOP_WIDE)
	glow.offset_bottom = 380
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(glow)
	pages["library"] = _build_library_page()
	pages["recent"] = _build_recent_page()
	pages["settings"] = _build_settings_page()
	pages["detail"] = Control.new()
	for k in pages:
		pages[k].set_anchors_preset(Control.PRESET_FULL_RECT)
		content.add_child(pages[k])

## 模拟器 / 文件对话框 / 提示（只创建一次，切换语言时不重建，避免中断正在运行的游戏）
func _build_overlays() -> void:
	# ---- emulator (overlay, hidden)
	emu_view = EmuView.new()
	emu_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	emu_view.visible = false
	emu_view.exited.connect(_on_emu_exited)
	emu_view.crashed.connect(_on_emu_crashed)
	add_child(emu_view)

	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.use_native_dialog = true
	file_dialog.size = Vector2i(900, 600)
	file_dialog.file_selected.connect(func(p): if _fd_callback.is_valid(): _fd_callback.call(p))
	file_dialog.dir_selected.connect(func(p): if _fd_callback.is_valid(): _fd_callback.call(p))
	file_dialog.files_selected.connect(func(ps): if _fd_callback.is_valid(): _fd_callback.call(ps))
	add_child(file_dialog)

	toast_label = Label.new()
	toast_label.add_theme_stylebox_override("normal", UITheme.box(Color("#000000cc"), 8, 16))
	toast_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	toast_label.position.y -= 60
	toast_label.visible = false
	add_child(toast_label)

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

func _page_header(title: String, sub: String = "") -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 30)
	v.add_child(t)
	if sub != "":
		var s := Label.new()
		s.text = sub
		s.add_theme_color_override("font_color", UITheme.MUTED)
		s.add_theme_font_size_override("font_size", 14)
		if mobile:
			s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(s)
	return v

func _divider() -> Control:
	var c := ColorRect.new()
	c.color = UITheme.BORDER
	c.custom_minimum_size = Vector2(0, 1)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

## 触屏：滚动页面中的卡片 / 按钮默认会拦截按下事件（MOUSE_FILTER_STOP），手指从它们上面开始拖动时页面无法滚动。
## 改为 PASS 后事件会继续传给 ScrollContainer；拖动超过死区时按钮自动取消按下，不会误触。
func _on_mobile_node_added(n: Node) -> void:
	if n is Control and not (n is ScrollBar or n is Slider or n is LineEdit or n is TextEdit):
		_mobile_pass_mouse.call_deferred(n)

func _mobile_pass_mouse(n: Node) -> void:
	if not is_instance_valid(n) or not n.is_inside_tree():
		return
	var c := n as Control
	if c.mouse_filter != Control.MOUSE_FILTER_STOP:
		return
	var p := c.get_parent()
	while p != null:
		if p is ScrollContainer:
			c.mouse_filter = Control.MOUSE_FILTER_PASS
			return
		if p == emu_view:
			return
		p = p.get_parent()

## 页面外壳：整页可滚动（滚动条贴在窗口右边缘），内容限制最大宽度并居中
func _page_shell(v: Control, max_w: float) -> ScrollContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	if mobile:
		sc.scroll_deadzone = 12   # 轻点按钮时手指的细微移动不触发滚动
		# 始终为滚动条预留宽度：否则卡片数量少时「出现/消失滚动条 → 宽度变 → 卡片重排」会来回振荡
		sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_RESERVE
	var mw := MaxWidthContainer.new(max_w, 32, 48)
	if mobile:
		mw.min_pad = 14
		mw.top_pad = 16
		mw.bottom_pad = 24
	sc.add_child(mw)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mw.add_child(v)
	return sc

## 卡片网格两端对齐：根据可用宽度计算列数并均分间距，左右边缘与标题栏对齐
func _justify_grid(grid: HFlowContainer) -> void:
	var w := grid.size.x
	var cols := maxi(1, int((w + GRID_GAP) / (CARD_W + GRID_GAP)))
	var sep := GRID_GAP
	if cols > 1:
		sep = clampi(int((w - cols * CARD_W) / (cols - 1)), GRID_GAP, GRID_GAP * 3)
	if grid.get_theme_constant("h_separation") != sep:
		grid.add_theme_constant_override("h_separation", sep)

func _margin(child: Control, m := 32) -> MarginContainer:
	var mc := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		mc.add_theme_constant_override("margin_" + side, m)
	mc.add_child(child)
	return mc

func _build_library_page() -> Control:
	if mobile:
		return _build_mobile_library_page()
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 18)
	var head := HBoxContainer.new()
	var hv := _page_header(tr("游戏库"))
	hv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lib_count_label = Label.new()
	lib_count_label.add_theme_color_override("font_color", UITheme.MUTED)
	hv.add_child(lib_count_label)
	head.add_child(hv)
	search_edit = LineEdit.new()
	search_edit.placeholder_text = tr("🔍  搜索游戏…")
	search_edit.custom_minimum_size = Vector2(260, 40)
	search_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	search_edit.text_changed.connect(func(_t): _lib_limit = LIB_PAGE; _refresh_lists())
	cat_filter = _make_cat_filter()
	cat_filter.custom_minimum_size = Vector2(170, 40)
	cat_filter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(cat_filter)
	head.add_child(search_edit)
	lib_scan_btn = Button.new()
	lib_scan_btn.text = tr("⟳ 扫描游戏库")
	lib_scan_btn.tooltip_text = tr("重新扫描「设置 → 游戏库文件夹」")
	lib_scan_btn.custom_minimum_size = Vector2(0, 40)
	lib_scan_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lib_scan_btn.pressed.connect(_start_scan)
	head.add_child(lib_scan_btn)
	var add := Button.new()
	add.text = tr("＋ 添加游戏")
	add.custom_minimum_size = Vector2(0, 40)
	add.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UITheme.accent_button(add)
	add.pressed.connect(_goto_add_game)
	head.add_child(add)
	v.add_child(head)
	v.add_child(_divider())
	lib_grid = HFlowContainer.new()
	lib_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lib_grid.add_theme_constant_override("h_separation", GRID_GAP)
	lib_grid.add_theme_constant_override("v_separation", GRID_GAP)
	lib_grid.resized.connect(_justify_grid.bind(lib_grid))
	v.add_child(lib_grid)
	return _page_shell(v, LIB_MAX_W)

func _build_recent_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12 if mobile else 18)
	v.add_child(_page_header(tr("最近游玩"), tr("按最后游玩时间排序")))
	v.add_child(_divider())
	recent_grid = HFlowContainer.new()
	recent_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	recent_grid.add_theme_constant_override("h_separation", GRID_GAP)
	recent_grid.add_theme_constant_override("v_separation", GRID_GAP)
	if mobile:
		recent_grid.add_theme_constant_override("h_separation", MOBILE_GAP)
		recent_grid.add_theme_constant_override("v_separation", MOBILE_GAP)
	else:
		recent_grid.resized.connect(_justify_grid.bind(recent_grid))
	v.add_child(recent_grid)
	return _page_shell(v, LIB_MAX_W)

# =================================================================== cards
func _make_card(g: Dictionary, show_last := false) -> Control:
	# 桌面固定 196 宽；移动端按列数计算宽度（封面始终 3:4）
	var cw: int = lib_card_w if mobile else CARD_W
	var cov_w := cw - 16
	var cov_h := roundi(cov_w * 4.0 / 3.0)
	var card := Button.new()
	card.custom_minimum_size = Vector2(cw, cov_h + 78)
	card.flat = true
	card.focus_mode = Control.FOCUS_ALL
	card.add_theme_stylebox_override("normal", UITheme.box(Color("#181c23"), 10, 0, UITheme.BORDER, 1))
	card.add_theme_stylebox_override("hover", UITheme.box(Color("#1f2733"), 10, 0, Color("#3a4a60"), 1))
	card.add_theme_stylebox_override("pressed", UITheme.box(Color("#242e3c"), 10, 0, UITheme.ACCENT, 1))
	card.add_theme_stylebox_override("focus", UITheme.box(Color(0, 0, 0, 0), 10, 0, UITheme.ACCENT, 2))
	card.pressed.connect(show_detail.bind(str(g["id"])))
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var cov := _cover_widget(g, Vector2(cov_w, cov_h), 20 if not mobile else clampi(roundi(20.0 * cw / CARD_W), 14, 22))
	cov.position = Vector2(8, 8)
	card.add_child(cov)
	# 卡片文字用轻量的 FastText（几千张卡片时普通 Label 排版汉字太慢）
	var t := FastText.new()
	t.text = str(g.get("title", ""))
	t.color = UITheme.TEXT
	t.position = Vector2(10, 14 + cov_h + 2)
	t.size = Vector2(cw - 20, 24)
	card.add_child(t)
	var s := FastText.new()
	var sub := Store.media_kind(g)
	var cat := str(g.get("category", ""))
	if cat != "":
		sub = cat + " · " + sub
	if show_last:
		sub = _fmt_time(float(g.get("last_played", 0)))
	s.color = UITheme.MUTED
	if Store.is_missing(g):
		sub = tr("⚠ 文件缺失")
		s.color = Color("#e0a040")
		t.color = Color("#e0a040")
		card.tooltip_text = tr("找不到镜像文件：") + Store.primary_path(g)
	s.text = sub
	s.font_size = 12
	s.position = Vector2(10, 39 + cov_h + 2)
	s.size = Vector2(cw - 20, 18)
	card.add_child(s)
	return card

func _cover_widget(g: Dictionary, sz: Vector2, title_size: int) -> Control:
	var holder := Panel.new()
	holder.custom_minimum_size = sz
	holder.size = sz
	holder.clip_contents = true
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_theme_stylebox_override("panel", UITheme.box(Color("#000000"), 8, 0))
	var tr := TextureRect.new()
	tr.texture = UITheme.cover_texture(g)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(tr)
	if not UITheme.has_custom_cover(g):
		var tag := Label.new()
		tag.text = "PC-9801"
		tag.add_theme_font_size_override("font_size", maxi(10, title_size / 2))
		tag.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
		tag.position = Vector2(12, 10)
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(tag)
		var title := FastText.new()
		title.text = str(g.get("title", ""))
		title.wrap = true
		title.valign = 2
		title.font_size = title_size
		title.color = Color.WHITE
		title.shadow_color = Color(0, 0, 0, 0.5)
		title.shadow_offset = Vector2(1, 2)
		title.position = Vector2(12, sz.y * 0.45)
		title.size = Vector2(sz.x - 24, sz.y * 0.55 - 14)
		holder.add_child(title)
		var stripe := ColorRect.new()
		stripe.color = Color(1, 1, 1, 0.18)
		stripe.position = Vector2(12, sz.y * 0.45 - 8)
		stripe.size = Vector2(36, 3)
		stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(stripe)
	var badge := Label.new()
	badge.text = _badge_text(g)
	badge.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	badge.add_theme_font_size_override("font_size", 11)
	badge.add_theme_stylebox_override("normal", UITheme.box(Color("#000000aa"), 4, 6))
	badge.position = Vector2(sz.x - 8 - 9 * badge.text.length() - 12, 8)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(badge)
	return holder

func _refresh_lists() -> void:
	if lib_grid == null:
		return
	for c in lib_grid.get_children():
		c.queue_free()
	for c in recent_grid.get_children():
		c.queue_free()
	var q := search_edit.text.strip_edges().to_lower()
	_fill_cat_filter()
	var want_cat = null
	if cat_filter and cat_filter.selected > 0 and cat_filter.selected - 1 < _cat_keys.size():
		want_cat = _cat_keys[cat_filter.selected - 1]
	var vis := Store.visible_games()
	var matched := []
	for g in vis:
		if want_cat != null and str(g.get("category", "")) != want_cat:
			continue
		if q != "" and str(g.get("title", "")).to_lower().find(q) < 0 and str(g.get("category", "")).to_lower() != q:
			continue
		matched.append(g)
	# 卡片分批创建：先同步创建第一屏，其余每帧创建一部分，几千款游戏时界面也不会卡住
	_card_gen += 1
	var cnt := mini(matched.size(), _lib_limit)
	var first := mini(cnt, CARD_BATCH)
	for i in first:
		lib_grid.add_child(_make_card(matched[i]))
	var more: Button = null
	if matched.size() > _lib_limit:
		more = Button.new()
		more.text = tr("显示更多（还有 %d 款）") % (matched.size() - _lib_limit)
		more.custom_minimum_size = Vector2(lib_card_w if mobile else CARD_W, 48)
		more.pressed.connect(func(): _lib_limit += LIB_PAGE; _refresh_lists())
		lib_grid.add_child(more)
	if cnt > first:
		_add_cards_async(matched, first, cnt, _card_gen, more)
	if matched.size() == vis.size():
		lib_count_label.text = tr("共 %d 款游戏") % vis.size()
	else:
		lib_count_label.text = tr("显示 %d 款 / 共 %d 款游戏") % [matched.size(), vis.size()]
	if Store.scan_running:
		lib_count_label.text += "   " + tr("正在扫描游戏库…")
	if lib_scan_btn:
		lib_scan_btn.visible = str(Store.settings.get("library_root", "")) != ""
		lib_scan_btn.disabled = Store.scan_running
	if vis.is_empty():
		lib_grid.add_child(_empty_hint(tr("游戏库还是空的"), tr("在「设置 → 添加游戏」中添加 FDI 软盘或 HDI 硬盘镜像。")))
	var rec := Store.recent_games().filter(func(g): return not bool(g.get("hidden", false)))
	for g in rec:
		recent_grid.add_child(_make_card(g, true))
	if rec.is_empty():
		recent_grid.add_child(_empty_hint(tr("还没有游玩记录"), tr("从游戏库中选择一款游戏并点击「开始游戏」。")))
	_update_bios_label()

func _add_cards_async(list: Array, from: int, to: int, gen: int, before: Control) -> void:
	var i := from
	while i < to:
		await get_tree().process_frame
		if gen != _card_gen or lib_grid == null or not is_instance_valid(lib_grid):
			return
		var t_end := Time.get_ticks_msec() + 12
		while i < to and Time.get_ticks_msec() < t_end:
			var c := _make_card(list[i])
			lib_grid.add_child(c)
			if before != null and is_instance_valid(before):
				lib_grid.move_child(c, before.get_index())
			i += 1

func _empty_hint(t: String, s: String) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(520, 0)
	var v := VBoxContainer.new()
	var a := Label.new()
	a.text = t
	a.add_theme_font_size_override("font_size", 20)
	v.add_child(a)
	var b := Label.new()
	if mobile:
		# 移动端：占满一行，文字自动换行
		p.custom_minimum_size = Vector2(maxf(lib_grid.size.x if lib_grid else 0.0, 280.0), 0)
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		a.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		s = s.replace(tr("在「设置 → 添加游戏」中添加 FDI 软盘或 HDI 硬盘镜像。"), tr("点击下方「导入」，从手机存储中选择 FDI 软盘或 HDI 硬盘镜像。"))
	b.text = s
	b.add_theme_color_override("font_color", UITheme.MUTED)
	v.add_child(b)
	p.add_child(v)
	return p

func _update_bios_label() -> void:
	var st := Store.bios_status()
	var dir := str(Store.settings.get("bios_dir", ""))
	if m_bios_info and is_instance_valid(m_bios_info):
		_fill_bios_info(m_bios_info, dir)
	var font := tr("字体 ROM") if (st.get("font.bmp", false) or st.get("font.rom", false)) else tr("系统字体")
	if st.get("bios.rom", false):
		bios_status_label.text = tr("● BIOS 已就绪 · ") + font
		bios_status_label.add_theme_color_override("font_color", UITheme.GREEN)
	else:
		# 没有真机 BIOS 也能运行：NP2kai 内置兼容 BIOS + 系统字体生成的字库
		bios_status_label.text = tr("● 内置 BIOS · ") + font
		bios_status_label.add_theme_color_override("font_color", BUILTIN_BIOS_COLOR)

func _fmt_time(t: float) -> String:
	if t <= 0:
		return tr("从未游玩")
	var d := Time.get_datetime_dict_from_unix_time(int(t) + int(Time.get_time_zone_from_system().get("bias", 0)) * 60)
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]

# =================================================================== navigation
func show_page(name: String) -> void:
	current_page = name
	for k in pages:
		pages[k].visible = (k == name)
	for k in sidebar_buttons:
		if mobile:
			_style_tab(sidebar_buttons[k], k == name or (name == "detail" and k == "library"))
		else:
			UITheme.sidebar_button(sidebar_buttons[k], k == name or (name == "detail" and k == "library"))
	if mobile and name == "import":
		_update_bios_label()
	if name == "settings":
		_load_settings_into_form()

func show_detail(id: String) -> void:
	detail_game_id = id
	var old: Control = pages["detail"]
	var g := Store.get_game(id)
	if g.is_empty():
		show_page("library")
		return
	var page := _build_detail_page(g)
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.add_child(page)
	pages["detail"] = page
	old.queue_free()
	show_page("detail")

func _build_detail_page(g: Dictionary) -> Control:
	if mobile:
		return _build_mobile_detail_page(g)
	var root := Control.new()
	# hero background
	var hero := TextureRect.new()
	hero.texture = UITheme.cover_texture(g, 600, 300)
	hero.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hero.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	hero.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hero.custom_minimum_size = Vector2(0, 360)
	hero.offset_bottom = 360
	hero.modulate = Color(0.55, 0.55, 0.6)
	root.add_child(hero)
	var fade := TextureRect.new()
	var gr := Gradient.new()
	gr.set_color(0, Color(UITheme.BG, 0.0))
	gr.set_color(1, UITheme.BG)
	var gt := GradientTexture2D.new()
	gt.gradient = gr
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	fade.texture = gt
	fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fade.set_anchors_preset(Control.PRESET_TOP_WIDE)
	fade.offset_bottom = 362
	root.add_child(fade)

	var mc := MaxWidthContainer.new(DETAIL_MAX_W, 28, 32)
	mc.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(mc)
	var v := VBoxContainer.new()
	mc.add_child(v)
	v.add_theme_constant_override("separation", 20)
	var back := Button.new()
	back.text = tr("‹  返回游戏库")
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.add_theme_stylebox_override("normal", UITheme.box(Color("#00000066"), 6, 14))
	back.pressed.connect(show_page.bind("library"))
	v.add_child(back)
	v.add_child(_spacer(40))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 32)
	v.add_child(h)
	h.add_child(_cover_widget(g, Vector2(252, 336), 28))
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 10)
	h.add_child(info)
	info.add_child(_spacer(60))
	var t := Label.new()
	t.text = str(g.get("title", ""))
	t.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	t.add_theme_font_size_override("font_size", 38)
	info.add_child(t)
	var kind := Label.new()
	kind.text = "PC-9801 · " + Store.media_kind(g) + ((" · " + tr("分类：") + str(g["category"])) if str(g.get("category", "")) != "" else "")
	kind.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	kind.add_theme_color_override("font_color", UITheme.MUTED)
	info.add_child(kind)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var play := Button.new()
	play.text = tr("▶  开始游戏")
	UITheme.accent_button(play, true)
	play.pressed.connect(launch_game.bind(str(g["id"])))
	row.add_child(play)
	var stats := VBoxContainer.new()
	stats.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var s1 := Label.new()
	s1.text = tr("上次游玩：") + _fmt_time(float(g.get("last_played", 0)))
	s1.add_theme_color_override("font_color", UITheme.MUTED)
	stats.add_child(s1)
	var s2 := Label.new()
	var mins := int(g.get("play_seconds", 0)) / 60
	s2.text = tr("游玩次数：%d    游玩时长：%d 小时 %d 分钟") % [int(g.get("play_count", 0)), mins / 60, mins % 60]
	s2.add_theme_color_override("font_color", UITheme.MUTED)
	stats.add_child(s2)
	row.add_child(stats)
	info.add_child(row)
	info.add_child(_spacer(8))

	var media := PanelContainer.new()
	media.add_theme_stylebox_override("panel", UITheme.card_panel(18))
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 6)
	var mt := Label.new()
	mt.text = tr("介质")
	mt.add_theme_font_size_override("font_size", 18)
	mv.add_child(mt)
	_media_lines(mv, g)
	media.add_child(mv)
	info.add_child(media)

	var ops := HBoxContainer.new()
	ops.add_theme_constant_override("separation", 10)
	var cov := Button.new()
	cov.text = tr("更换封面…")
	cov.pressed.connect(func(): _pick_file(tr("选择封面图片"), IMG_FILTERS, func(p):
		var gg := Store.get_game(str(g["id"]))
		gg["cover"] = p
		Store.update_game(gg)
		show_detail(str(g["id"]))))
	ops.add_child(cov)
	var ren := Button.new()
	ren.text = tr("重命名")
	ren.pressed.connect(func(): _rename_dialog(str(g["id"])))
	ops.add_child(ren)
	var del := Button.new()
	del.text = tr("从游戏库移除")
	del.add_theme_color_override("font_color", UITheme.DANGER)
	del.pressed.connect(func(): _confirm(tr("确定要从游戏库移除「%s」吗？（不会删除镜像文件）") % g["title"], func():
		Store.remove_or_hide(str(g["id"]))
		show_page("library")))
	ops.add_child(del)
	info.add_child(ops)
	return root

# =================================================================== settings
func _section(title: String, desc: String = "") -> VBoxContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.card_panel(16 if mobile else 24))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	var th := HBoxContainer.new()
	th.add_theme_constant_override("separation", 10)
	var bar := ColorRect.new()
	bar.color = UITheme.ACCENT
	bar.custom_minimum_size = Vector2(3, 18)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	th.add_child(bar)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 18)
	th.add_child(t)
	v.add_child(th)
	if desc != "":
		var d := Label.new()
		d.text = desc
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.add_theme_color_override("font_color", UITheme.MUTED)
		d.add_theme_font_size_override("font_size", 13)
		v.add_child(d)
	v.add_child(_divider())
	p.add_child(v)
	return v

## 与输入框列左对齐（跳过标签列）
func _indented(parent: Control, c: Control) -> void:
	if mobile:
		parent.add_child(c)
		return
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	h.add_child(sp)
	h.add_child(c)
	parent.add_child(h)

func _row_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	l.add_theme_color_override("font_color", Color("#c3c9d2"))
	return l

func _path_row(parent: Control, label: String, placeholder: String, filters: Array, dir_mode := false) -> LineEdit:
	if mobile:
		return _mobile_path_row(parent, label, placeholder, filters, dir_mode)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	h.add_child(_row_label(label))
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.custom_minimum_size = Vector2(0, 38)
	h.add_child(e)
	var b := Button.new()
	b.text = tr("浏览…")
	b.custom_minimum_size = Vector2(96, 38)
	b.pressed.connect(func():
		if dir_mode:
			_pick_dir(label, func(p): e.text = p; e.text_submitted.emit(p))
		else:
			_pick_file(label, filters, func(p): e.text = p; e.text_submitted.emit(p)))
	h.add_child(b)
	parent.add_child(h)
	return e

func _option_row(parent: Control, label: String, items: Array) -> OptionButton:
	var h: BoxContainer = VBoxContainer.new() if mobile else HBoxContainer.new()
	h.add_theme_constant_override("separation", 6 if mobile else 10)
	h.add_child(_row_label(label))
	var o := OptionButton.new()
	o.custom_minimum_size = Vector2(0 if mobile else OPTION_W, TOUCH_H if mobile else 38)
	o.clip_text = true
	for it in items:
		o.add_item(it)
	h.add_child(o)
	parent.add_child(h)
	return o

func _build_settings_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 18)
	settings_scroll = _page_shell(v, SETTINGS_MAX_W)
	v.add_child(_page_header(tr("设置"), tr("界面语言、显示、BIOS、字体与模拟器选项，修改后自动保存。")))
	v.add_child(_divider())

	# language
	var lg := _section(tr("界面语言"), tr("切换整个程序界面的显示语言，立即生效并在下次启动时保持。"))
	var lh: BoxContainer = VBoxContainer.new() if mobile else HBoxContainer.new()
	lh.add_theme_constant_override("separation", 6 if mobile else 10)
	lh.add_child(_row_label(tr("语言")))
	s_lang = _make_lang_option()
	s_lang.custom_minimum_size = Vector2(0 if mobile else OPTION_W, TOUCH_H if mobile else 38)
	lh.add_child(s_lang)
	lg.add_child(lh)
	v.add_child(lg.get_parent())

	# display
	var dp := _section(tr("显示"), tr("游戏画面横屏全屏显示，始终按比例放大，多余部分以黑边填充，不会拉伸变形。") if mobile else tr("按 Alt+Enter 或点窗口右上角「最大化」按钮进入全屏（与 NP2 相同），再按 Alt+Enter 回到原来的窗口大小。画面始终按比例放大，多余部分以黑边填充，不会拉伸变形。"))
	s_scale = _option_row(dp, tr("画面缩放"), [tr("4:3 等比例（CRT 显示器比例，推荐）"), tr("原始比例（640×400，方形像素）"), tr("整数倍放大（像素清晰）")])
	s_scale.item_selected.connect(func(_i): _save_settings_from_form())
	if not mobile:
		s_fs_button = Button.new()
		s_fs_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		s_fs_button.pressed.connect(Store.toggle_fullscreen)
		_indented(dp, s_fs_button)
		_update_fs_button()
	v.add_child(dp.get_parent())
	if mobile:
		var tc := _section(tr("触屏控制"), tr("游戏中右上角「键盘」打开 PC-98 虚拟键盘，「≡」或返回键打开菜单。"))
		s_touch_pad = CheckBox.new()
		s_touch_pad.text = tr("显示触屏方向键与 RETURN / ESC / SPACE 按钮")
		s_touch_pad.toggled.connect(func(_b): _save_settings_from_form())
		tc.add_child(s_touch_pad)
		s_touch_mouse = CheckBox.new()
		s_touch_mouse.text = tr("触控板鼠标：在画面上滑动移动鼠标，点按 = 左键，双指点按 = 右键")
		s_touch_mouse.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		s_touch_mouse.toggled.connect(func(_b): _save_settings_from_form())
		tc.add_child(s_touch_mouse)
		v.add_child(tc.get_parent())

	# BIOS
	var b := _section(tr("BIOS 文件夹"), tr("点击「导入…」从手机存储中选择 BIOS 文件夹（bios.rom、itf.rom、sound.rom、font.bmp / FONT.ROM、2608_*.wav 等），文件会被复制到本应用中。本程序不附带任何 BIOS。") + "\n" + tr(BIOS_OPTIONAL_NOTE) if mobile else tr("选择存放 PC-98 BIOS 的文件夹（bios.rom、itf.rom、sound.rom、font.bmp / FONT.ROM、2608_*.wav 等）。启动游戏时会自动复制到模拟器系统目录。本程序不附带任何 BIOS。") + "\n" + tr(BIOS_OPTIONAL_NOTE))
	s_bios = _path_row(b, tr("BIOS 文件夹"), tr("例如 D:/PC98/BIOS"), [], true)
	if mobile:
		var bf := Button.new()
		bf.text = tr("导入 BIOS 文件（可多选）…")
		bf.pressed.connect(_import_bios_files)
		b.add_child(bf)
	s_bios.text_submitted.connect(func(_t): _save_settings_from_form())
	s_bios.focus_exited.connect(_save_settings_from_form)
	s_bios_info = Label.new()
	s_bios_info.add_theme_font_size_override("font_size", 13)
	s_bios_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	s_bios_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_indented(b, s_bios_info)
	v.add_child(b.get_parent())

	# fonts
	var f := _section(tr("字体"), tr("与 NP2 相同：可使用 BIOS 文件夹中的字体 ROM，也可手动指定 FONT.ROM / font.bmp；若没有字体 ROM，可用系统字体（如 MS Gothic）生成汉字字库。游戏中也可通过菜单「字体」切换。"))
	s_font_mode = _option_row(f, tr("字体来源"), [tr("自动（BIOS 文件夹中的 font.bmp / FONT.ROM）"), tr("指定字体文件（FONT.ROM / font.bmp）"), tr("系统字体生成（TTF/TTC，无需字体 ROM）")])
	s_font_mode.item_selected.connect(func(_i): _save_settings_from_form())
	s_font_file = _path_row(f, tr("字体文件"), tr("FONT.ROM 或 font.bmp"), FONT_FILTERS)
	s_font_file.text_submitted.connect(func(_t): _save_settings_from_form())
	s_font_file.focus_exited.connect(_save_settings_from_form)
	s_ttf = _path_row(f, tr("系统字体"), "/system/fonts/NotoSansCJK-Regular.ttc" if mobile else "C:/Windows/Fonts/msgothic.ttc", TTF_FILTERS)
	s_ttf.text_submitted.connect(func(_t): _save_settings_from_form())
	s_ttf.focus_exited.connect(_save_settings_from_form)
	v.add_child(f.get_parent())

	# emulation
	var e := _section(tr("模拟器"))
	s_model = _option_row(e, tr("机型"), ["PC-9801VX", "PC-9801VM", "PC-286"])
	s_model.item_selected.connect(func(_i): _save_settings_from_form())
	s_kbd = _option_row(e, tr("键盘布局"), [tr("美式键盘 (US 101)"), tr("日式键盘 (JIS 106)")])
	s_kbd.item_selected.connect(func(_i): _save_settings_from_form())
	s_esc = CheckBox.new()
	s_esc.text = tr("ESC 键发送给 PC-98（菜单改用 F12 打开）")
	s_esc.toggled.connect(func(_b): _save_settings_from_form())
	_indented(e, s_esc)
	if not mobile:
		s_mouse = CheckBox.new()
		s_mouse.text = tr("启用游戏内鼠标（PC-98 总线鼠标）")
		s_mouse.tooltip_text = tr("游戏中鼠标锁定到画面并送给 PC-98；中键或 Ctrl+F10 释放 / 重新锁定，Esc / F12 菜单时自动释放。关闭后只用键盘。")
		s_mouse.toggled.connect(func(_b): _save_settings_from_form())
		_indented(e, s_mouse)
	var sh := HBoxContainer.new()
	sh.add_theme_constant_override("separation", 10)
	sh.add_child(_row_label(tr("鼠标灵敏度")))
	s_mouse_sens = HSlider.new()
	s_mouse_sens.min_value = 0.25
	s_mouse_sens.max_value = 4.0
	s_mouse_sens.step = 0.05
	s_mouse_sens.value = 1.0
	s_mouse_sens.custom_minimum_size = Vector2(220, 32)
	s_mouse_sens.size_flags_horizontal = Control.SIZE_EXPAND_FILL if mobile else Control.SIZE_FILL
	s_mouse_sens.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s_mouse_sens_val = Label.new()
	s_mouse_sens_val.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	s_mouse_sens_val.custom_minimum_size = Vector2(56, 0)
	s_mouse_sens.value_changed.connect(func(val):
		s_mouse_sens_val.text = "%.2f×" % val
		_save_settings_from_form())
	sh.add_child(s_mouse_sens)
	sh.add_child(s_mouse_sens_val)
	e.add_child(sh)
	v.add_child(e.get_parent())

	# library folder
	_build_library_folder_section(v)

	# add game
	var a := _section(tr("添加游戏"), tr("支持 FDI 软盘镜像与 HDI 硬盘镜像（也支持 D88 / HDM 等）。硬盘游戏选择 HDI；需要两张软盘的游戏可同时选择 FDD1 与 FDD2。封面可选，不选则自动生成渐变封面。"))
	add_panel = a.get_parent()
	if mobile:
		var qi := Button.new()
		qi.text = tr("导入游戏镜像…")
		UITheme.accent_button(qi)
		qi.pressed.connect(_import_games)
		a.add_child(qi)
	a_title = LineEdit.new()
	a_title.placeholder_text = tr("游戏名称（留空则使用文件名）")
	a_title.custom_minimum_size = Vector2(0, 38)
	var th: BoxContainer = VBoxContainer.new() if mobile else HBoxContainer.new()
	th.add_theme_constant_override("separation", 6 if mobile else 10)
	th.add_child(_row_label(tr("名称")))
	a_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	th.add_child(a_title)
	if not mobile:
		var tsp := Control.new()
		tsp.custom_minimum_size = Vector2(96, 0)
		th.add_child(tsp)
	a.add_child(th)
	a_fdd1 = _path_row(a, tr("FDD1 软盘"), tr("*.fdi（可选）"), FDD_FILTERS)
	a_fdd2 = _path_row(a, tr("FDD2 软盘"), tr("*.fdi（可选）"), FDD_FILTERS)
	a_hdd = _path_row(a, tr("HDD 硬盘"), tr("*.hdi（可选）"), HDD_FILTERS)
	a_cover = _path_row(a, tr("封面图片"), tr("png / jpg（可选）"), IMG_FILTERS)
	var ab := Button.new()
	ab.text = tr("＋ 添加到游戏库")
	ab.size_flags_horizontal = Control.SIZE_FILL if mobile else Control.SIZE_SHRINK_END
	UITheme.accent_button(ab)
	ab.pressed.connect(_add_game_from_form)
	a.add_child(ab)
	v.add_child(add_panel)

	var about := _section(tr("关于"), tr("PC-98 游戏厅（原型） · 模拟器内核：NP2kai（Neko Project II kai，MIT 许可证）· 界面：Godot 4.7\n数据保存位置：") + Store.data_dir() + (tr("（便携模式：数据保存在程序旁边的 data 文件夹，整个文件夹可复制到其他电脑）") if Store.portable else ""))
	v.add_child(about.get_parent())
	if mobile:
		_touchify(v)
	return settings_scroll

func _load_settings_into_form() -> void:
	if s_bios == null:
		return
	var s := Store.settings
	s_bios.text = str(s.get("bios_dir", ""))
	s_font_mode.select({"auto": 0, "file": 1, "ttf": 2}.get(str(s.get("font_mode", "auto")), 0))
	s_font_file.text = str(s.get("font_file", ""))
	s_ttf.text = str(s.get("ttf_file", ""))
	s_kbd.select(0 if str(s.get("keyboard", "Us")) == "Us" else 1)
	s_model.select(maxi(0, ["PC-9801VX", "PC-9801VM", "PC-286"].find(str(s.get("model", "PC-9801VX")))))
	s_esc.set_pressed_no_signal(bool(s.get("esc_to_pc98", false)))
	if s_mouse:
		s_mouse.set_pressed_no_signal(bool(s.get("game_mouse", true)))
	s_mouse_sens.set_value_no_signal(clampf(float(s.get("mouse_sens", 1.0)), 0.25, 4.0))
	s_mouse_sens_val.text = "%.2f×" % s_mouse_sens.value
	s_scale.select(maxi(0, Store.SCALE_MODES.find(str(s.get("scale_mode", "4:3")))))
	s_lang.select(maxi(0, I18n.LOCALES.find(Store.get_language())))
	if s_touch_pad:
		s_touch_pad.set_pressed_no_signal(bool(s.get("touch_pad", true)))
		s_touch_mouse.set_pressed_no_signal(bool(s.get("touch_mouse", true)))
	_update_fs_button()
	_update_bios_info()
	if s_libroot:
		s_libroot.text = str(s.get("library_root", ""))
		s_lib_auto.set_pressed_no_signal(bool(s.get("library_autoscan", true)))
		_update_lib_status()

func _save_settings_from_form() -> void:
	var s := Store.settings
	s["bios_dir"] = s_bios.text.strip_edges().replace("\\", "/")
	s["font_mode"] = ["auto", "file", "ttf"][maxi(0, s_font_mode.selected)]
	s["font_file"] = s_font_file.text.strip_edges().replace("\\", "/")
	s["ttf_file"] = s_ttf.text.strip_edges().replace("\\", "/")
	s["keyboard"] = "Us" if s_kbd.selected == 0 else "Ja"
	s["model"] = ["PC-9801VX", "PC-9801VM", "PC-286"][maxi(0, s_model.selected)]
	s["esc_to_pc98"] = s_esc.button_pressed
	if s_mouse:
		s["game_mouse"] = s_mouse.button_pressed
	s["mouse_sens"] = snappedf(s_mouse_sens.value, 0.05)
	s["scale_mode"] = Store.SCALE_MODES[maxi(0, s_scale.selected)]
	if s_touch_pad:
		s["touch_pad"] = s_touch_pad.button_pressed
		s["touch_mouse"] = s_touch_mouse.button_pressed
	Store.save_settings()
	_update_bios_info()
	_update_bios_label()

func _update_bios_info() -> void:
	_fill_bios_info(s_bios_info, s_bios.text.strip_edges())

func _fill_bios_info(lbl: Label, dir: String) -> void:
	if dir == "":
		lbl.text = tr("尚未选择文件夹（可选）：将使用内置兼容 BIOS")
		lbl.add_theme_color_override("font_color", UITheme.MUTED)
		return
	if not DirAccess.dir_exists_absolute(dir):
		lbl.text = tr("⚠ 文件夹不存在") + "\n" + tr("未找到 bios.rom：将使用内置兼容 BIOS（可正常使用，放入真机 BIOS 兼容性更好）")
		lbl.add_theme_color_override("font_color", UITheme.DANGER)
		return
	var st := Store.bios_status(dir)
	var parts := []
	for n in ["bios.rom", "itf.rom", "sound.rom", "font.bmp", "font.rom"]:
		parts.append(("✔ " if st[n] else "✘ ") + n)
	lbl.text = tr("检测结果：") + "   ".join(parts)
	if not st["bios.rom"]:
		lbl.text += "\n" + tr("未找到 bios.rom：将使用内置兼容 BIOS（可正常使用，放入真机 BIOS 兼容性更好）")
	lbl.add_theme_color_override("font_color", UITheme.GREEN if st["bios.rom"] else BUILTIN_BIOS_COLOR)

func _update_fs_button() -> void:
	if s_fs_button == null or not is_instance_valid(s_fs_button):
		return
	s_fs_button.text = tr("⛶ 退出全屏（Alt+Enter）") if Store.is_fullscreen() else tr("⛶ 切换到全屏（Alt+Enter）")

func _goto_add_game() -> void:
	if mobile:
		show_page("import")
		return
	show_page("settings")
	await get_tree().process_frame
	settings_scroll.ensure_control_visible(add_panel)
	a_title.grab_focus()

func _add_game_from_form() -> void:
	var fdd1 := a_fdd1.text.strip_edges().replace("\\", "/")
	var fdd2 := a_fdd2.text.strip_edges().replace("\\", "/")
	var hdd := a_hdd.text.strip_edges().replace("\\", "/")
	var cover := a_cover.text.strip_edges().replace("\\", "/")
	if fdd1 == "" and hdd == "":
		toast(tr("请至少选择 FDD1 软盘镜像或 HDD 硬盘镜像"))
		return
	for p in [fdd1, fdd2, hdd]:
		if p != "" and not FileAccess.file_exists(p):
			toast(tr("文件不存在：") + p)
			return
	var title := a_title.text.strip_edges()
	if title == "":
		title = (hdd if hdd != "" else fdd1).get_file().get_basename()
	var g := Store.add_game(title, fdd1, fdd2, hdd, cover)
	for e in [a_title, a_fdd1, a_fdd2, a_hdd, a_cover]:
		e.text = ""
	toast(tr("已添加「%s」") % title)
	show_detail(str(g["id"]))

# =================================================================== dialogs
func _pick_file(title: String, filters: Array, cb: Callable) -> void:
	_fd_callback = cb
	file_dialog.title = title
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	# Android 的系统文件选择器按 MIME 类型过滤，FDI/HDI 没有对应类型，所以不设过滤
	file_dialog.filters = PackedStringArray() if Store.is_android() else I18n.tr_filters(filters)
	file_dialog.popup_centered()

## 多选文件（Android 上返回 content:// URI 列表）
func _pick_files(title: String, filters: Array, cb: Callable) -> void:
	_fd_callback = cb
	file_dialog.title = title
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	file_dialog.filters = PackedStringArray() if Store.is_android() else I18n.tr_filters(filters)
	file_dialog.popup_centered()

func _pick_dir(title: String, cb: Callable) -> void:
	_fd_callback = cb
	file_dialog.title = title
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	file_dialog.filters = PackedStringArray()
	file_dialog.popup_centered()

func _confirm(text: String, cb: Callable) -> void:
	var d := ConfirmationDialog.new()
	d.dialog_text = text
	d.ok_button_text = tr("确定")
	d.cancel_button_text = tr("取消")
	d.confirmed.connect(cb)
	d.visibility_changed.connect(func(): if not d.visible: d.queue_free())
	add_child(d)
	d.popup_centered()

func _rename_dialog(id: String) -> void:
	var g := Store.get_game(id)
	var d := ConfirmationDialog.new()
	d.title = tr("重命名")
	d.ok_button_text = tr("确定")
	d.cancel_button_text = tr("取消")
	var e := LineEdit.new()
	e.text = str(g.get("title", ""))
	e.custom_minimum_size = Vector2(360, 36)
	d.add_child(e)
	d.confirmed.connect(func():
		if e.text.strip_edges() != "":
			g["title"] = e.text.strip_edges()
			Store.update_game(g)
			show_detail(id))
	add_child(d)
	d.popup_centered()

func toast(msg: String, secs := 2.5) -> void:
	toast_label.text = msg
	toast_label.visible = true
	toast_label.reset_size()
	if mobile:
		toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		toast_label.custom_minimum_size = Vector2(minf(size.x - 32, 560), 0)
		toast_label.reset_size()
	toast_label.position = Vector2((size.x - toast_label.size.x) / 2, size.y - (150 if mobile else 90))
	if _toast_tw and _toast_tw.is_valid():
		_toast_tw.kill()
	_toast_tw = create_tween()
	_toast_tw.tween_interval(secs)
	_toast_tw.tween_callback(func(): toast_label.visible = false)

# =================================================================== launch
func launch_game(id: String) -> void:
	var g := Store.get_game(id)
	if g.is_empty():
		return
	for k in ["fdd1", "fdd2", "hdd1"]:
		var p := str(g.get(k, ""))
		if p != "" and not FileAccess.file_exists(p):
			toast(tr("找不到镜像文件：") + p, 4)
			return
	if not Store.has_real_bios():
		toast(tr("未放入真机 BIOS，正在使用内置兼容 BIOS，放入真机 BIOS 兼容性更好"), 4)
	g["last_played"] = Time.get_unix_time_from_system()
	g["play_count"] = int(g.get("play_count", 0)) + 1
	Store.update_game(g)
	var err: String = emu_view.launch(g)
	if err != "":
		if not emu_view.emu.has_crashed():
			toast(tr("启动失败：") + I18n.core_message(err), 5)
		return
	emu_view.visible = true

func _on_emu_crashed(message: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = tr("模拟器核心错误")
	dlg.dialog_text = I18n.core_message(message) + tr("\n\n程序没有退出，你可以检查 BIOS 文件夹 / 镜像后重新开始游戏。")
	dlg.dialog_autowrap = true
	dlg.min_size = Vector2i(560, 0)
	add_child(dlg)
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	dlg.popup_centered()
	print("[test] crash dialog: ", message)

func _on_emu_exited(game_id: String, seconds: float) -> void:
	emu_view.visible = false
	var g := Store.get_game(game_id)
	if not g.is_empty():
		g["play_seconds"] = int(g.get("play_seconds", 0)) + int(seconds)
		Store.update_game(g)
	if current_page == "detail":
		show_detail(detail_game_id)
	else:
		_refresh_lists()

# =================================================================== automated tests (xvfb)
func _run_cmdline_tests() -> void:
	var args := OS.get_cmdline_user_args()
	var shot_dir := ""
	var emu_dir := ""
	var boot_dir := ""
	var boot_bios := ""
	var boot_hdd := ""
	var boot_fdd := ""
	var boot_frames := 1800
	var lang_dir := ""
	var scale_dir := ""
	var mobile_dir := ""
	var portable_dir := ""
	var library_dir := ""
	var library_root := ""
	var boot_title := ""
	var swap_title := ""
	var mouse_dir := ""
	for a in args:
		if a.begins_with("--mouse-test="):
			mouse_dir = a.split("=", true, 1)[1]
		if a.begins_with("--library-test="):
			library_dir = a.split("=", true, 1)[1]
		elif a.begins_with("--library-root="):
			library_root = a.split("=", true, 1)[1]
		elif a.begins_with("--boot-title="):
			boot_title = a.split("=", true, 1)[1]
		elif a.begins_with("--swap-title="):
			swap_title = a.split("=", true, 1)[1]
		if a.begins_with("--portable-test="):
			portable_dir = a.split("=", true, 1)[1]
		if a.begins_with("--boot-test="):
			boot_dir = a.split("=", true, 1)[1]
		elif a.begins_with("--bios-dir="):
			boot_bios = a.split("=", true, 1)[1]
		elif a.begins_with("--hdd="):
			boot_hdd = a.split("=", true, 1)[1]
		elif a.begins_with("--fdd="):
			boot_fdd = a.split("=", true, 1)[1]
		elif a.begins_with("--frames="):
			boot_frames = int(a.split("=", true, 1)[1])
		if a.begins_with("--lang-test="):
			lang_dir = a.split("=", true, 1)[1]
		elif a.begins_with("--scale-test="):
			scale_dir = a.split("=", true, 1)[1]
		if a.begins_with("--screenshot-test="):
			shot_dir = a.split("=", true, 1)[1]
		elif a.begins_with("--emu-test="):
			emu_dir = a.split("=", true, 1)[1]
		if a.begins_with("--mobile-test="):
			mobile_dir = a.split("=", true, 1)[1]
	if shot_dir != "":
		await _screenshot_test(shot_dir)
	if emu_dir != "":
		await _emu_test(emu_dir)
	if boot_dir != "":
		await _boot_test(boot_dir, boot_bios, boot_hdd, boot_fdd, boot_frames)
	if lang_dir != "":
		await _lang_test(lang_dir)
	if scale_dir != "":
		await _scale_test(scale_dir, boot_bios, boot_hdd, boot_frames)
	if mobile_dir != "":
		await _mobile_test(mobile_dir, boot_bios, boot_hdd, boot_frames)
	if portable_dir != "":
		await _portable_test(portable_dir, boot_bios, boot_hdd, boot_frames)
	if library_dir != "":
		await _library_test(library_dir, library_root, boot_bios, boot_title, swap_title, boot_frames)
	if mouse_dir != "":
		await _mouse_test(mouse_dir, boot_bios, boot_hdd)
	if mouse_dir != "" or library_dir != "" or portable_dir != "" or shot_dir != "" or emu_dir != "" or boot_dir != "" or lang_dir != "" or scale_dir != "" or mobile_dir != "":
		get_tree().quit()

## 真实镜像启动测试：--boot-test=输出目录 --bios-dir=BIOS文件夹 --hdd=镜像.hdi [--fdd=..] [--frames=N]
func _boot_test(dir: String, bios: String, hdd: String, fdd: String, frames: int) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	print("[test] guard self-test recovered: ", emu_view.emu.debug_fault_test())
	if bios != "":
		Store.settings["bios_dir"] = bios
	Store.settings["font_mode"] = "auto"
	print("[test] bios status: ", Store.bios_status())
	var g := {"id": "boottest", "title": "启动测试", "fdd1": fdd, "fdd2": "", "hdd1": hdd}
	var err: String = emu_view.launch(g)
	print("[test] boot launch err='", err, "' core=", emu_view.emu.get_core_info())
	if err != "":
		return
	emu_view.visible = true
	emu_view.auto_run = false
	var produced := 0
	for i in frames:
		produced += emu_view.emu.run_frame()
		if emu_view.emu.has_crashed():
			print("[test] CORE CRASHED at frame ", i, ": ", emu_view.emu.get_last_error())
			for k in 10:
				await get_tree().process_frame
			await _shot(dir + "/crash_dialog.png")
			print("[test] app still alive after core crash")
			return
		if (i + 1) % 300 == 0:
			var img: Image = emu_view.emu.get_texture().get_image()
			img.save_png(dir + "/boot_%05d.png" % (i + 1))
			print("[test] frame ", i + 1, " saved, size=", emu_view.emu.get_frame_size())
			await get_tree().process_frame
	print("[test] boot frames run=", frames, " video frames=", produced)
	emu_view.auto_run = true
	await _shot(dir + "/boot_view.png")
	emu_view.open_menu()
	await _shot(dir + "/boot_menu.png")
	emu_view.exit_to_library()
	print("[test] boot test done")

## 便携模式测试：--portable-test=输出目录 [--bios-dir=.. --hdd=..（首次：导入到数据目录）] [--frames=N]
## 带 BIOS/镜像参数时：用正式的导入功能把 BIOS 和镜像复制进数据目录、加入游戏库，并把界面语言改为繁体中文；
## 之后（或不带参数时）列出读到的设置 / 游戏库，启动库中的游戏截图。
func _portable_test(dir: String, bios: String, hdd: String, frames: int) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	print("[ptest] portable=", Store.portable, " data_dir=", Store.data_dir())
	if bios != "" and hdd != "":
		print("[ptest] imported bios files: ", Store.import_bios_tree(bios))
		var added := Store.import_game_files([hdd], "天神乱魔")
		print("[ptest] imported games: ", added.size())
		Store.settings["language"] = "zh_TW"
		Store.save_settings()
		I18n.apply_locale("zh_TW")
		_refresh_lists()
	print("[ptest] settings.language=", Store.settings.get("language"), " bios_dir=", Store.settings.get("bios_dir"))
	print("[ptest] library size=", Store.games.size())
	var target := {}
	for g in Store.games:
		var h := str(g.get("hdd1", ""))
		print("[ptest]   game '", g.get("title"), "' hdd1=", h, " exists=", FileAccess.file_exists(h))
		if str(g.get("title")) == "天神乱魔":
			target = g
	show_page("library")
	await _shot(dir + "/01_library.png")
	show_page("settings")
	await _shot(dir + "/02_settings.png")
	if target.is_empty():
		print("[ptest] FAIL: imported game not in library")
		return
	var err: String = emu_view.launch(target)
	print("[ptest] launch err='", err, "'")
	if err != "":
		return
	emu_view.visible = true
	emu_view.auto_run = false
	for i in frames:
		emu_view.emu.run_frame()
	emu_view.emu.get_texture().get_image().save_png(dir + "/boot_%05d.png" % frames)
	emu_view.auto_run = true
	await _shot(dir + "/03_boot_view.png")
	emu_view.exit_to_library()
	print("[ptest] done")

## 游戏库文件夹测试：--library-test=输出目录 --library-root=游戏库 [--bios-dir=] [--boot-title=] [--swap-title=] [--frames=N]
func _library_test(dir: String, root: String, bios: String, boot_title: String, swap_title: String, frames: int) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	if bios != "":
		Store.settings["bios_dir"] = bios
	var lang := "zh_CN"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--lib-lang="):
			lang = a.split("=", true, 1)[1]
	if lang != Store.get_language():
		set_language(lang)
		for i in 4:
			await get_tree().process_frame
	Store.save_settings()
	if root != "":
		s_libroot.text = root
		_apply_lib_root(false)   # 改变文件夹时会自动开始扫描
	if not Store.scan_running:
		Store.start_library_scan()
	var r: Dictionary = await Store.scan_finished
	print("[ltest] scan result: ", JSON.stringify(r))
	var vis := Store.visible_games()
	print("[ltest] visible games=", vis.size(), " categories=", JSON.stringify(Store.categories()))
	for g in vis:
		print("[ltest]   [", g.get("category", ""), "] ", g.get("title"), "  disks=", (g.get("disks", []) as Array).size(),
			" hdds=", (g.get("hdds", []) as Array).size(), " fdd1=", str(g.get("fdd1", "")).get_file(), " fdd2=", str(g.get("fdd2", "")).get_file(),
			" hdd1=", str(g.get("hdd1", "")).get_file(), " missing=", Store.is_missing(g))
	var worst := 0
	var tprev := Time.get_ticks_msec()
	for i in 90:
		await get_tree().process_frame
		var tn := Time.get_ticks_msec()
		worst = maxi(worst, tn - tprev)
		tprev = tn
	print("[ltest] after scan: cards built=", lib_grid.get_child_count(), " worst frame in next 90 frames=", worst, "ms")
	var lib_json := FileAccess.get_file_as_string(Store.data_path("library.json"))
	print("[ltest] library.json has <LIB>/ paths: ", lib_json.count(Store.LIB_MARK), "  absolute root occurrences: ", lib_json.count(root))
	show_page("library")
	await _shot(dir + "/01_library_all.png")
	settings_scroll = settings_scroll
	for i in _cat_keys.size():
		if _cat_keys[i] == "あ":
			cat_filter.select(i + 1)
			_refresh_lists()
	await _shot(dir + "/02_library_cat_a.png")
	cat_filter.select(0)
	search_edit.text = "R"
	_refresh_lists()
	await _shot(dir + "/03_library_search.png")
	search_edit.text = ""
	_refresh_lists()
	show_page("settings")
	for i in 3:
		await get_tree().process_frame
	settings_scroll.ensure_control_visible(s_libroot.get_parent().get_parent())
	await _shot(dir + "/04_settings_library.png")
	var sw := {}
	var bt := {}
	for g in vis:
		if str(g.get("title")) == swap_title:
			sw = g
		if str(g.get("title")) == boot_title:
			bt = g
	if not sw.is_empty():
		show_detail(str(sw["id"]))
		await _shot(dir + "/05_detail_multidisk.png")
		var err: String = emu_view.launch(sw)
		print("[ltest] launch multi-disk err='", err, "' fdd1=", emu_view.emu.get_disk(0).get_file(), " fdd2=", emu_view.emu.get_disk(1).get_file())
		if err == "":
			emu_view.visible = true
			for i in 60:
				emu_view.emu.run_frame()
			emu_view.open_menu()
			var mb: MenuButton = emu_view.m_fdd[0]
			mb.show_popup()
			var pm := mb.get_popup()
			var items := []
			for i in pm.item_count:
				items.append("%d:%s" % [pm.get_item_id(i), pm.get_item_text(i)])
			print("[ltest] FDD1 menu: ", " | ".join(items))
			await _shot(dir + "/06_swap_menu.png")
			pm.hide()
			var disks: Array = sw.get("disks", [])
			if disks.size() >= 3:
				pm.id_pressed.emit(102)
				print("[ltest] after choosing disk 3: fdd1=", emu_view.emu.get_disk(0).get_file(), " expected=", str(disks[2]).get_file(),
					" ok=", emu_view.emu.get_disk(0) == str(disks[2]))
			emu_view.exit_to_library()
	if not bt.is_empty():
		var err2: String = emu_view.launch(bt)
		print("[ltest] launch boot '", boot_title, "' err='", err2, "' hdd1=", emu_view.emu.get_hdd(0))
		if err2 == "":
			emu_view.visible = true
			emu_view.auto_run = false
			for i in frames:
				emu_view.emu.run_frame()
			emu_view.emu.get_texture().get_image().save_png(dir + "/boot_%05d.png" % frames)
			emu_view.auto_run = true
			await _shot(dir + "/07_boot_view.png")
			emu_view.exit_to_library()
	# 重新扫描：不应产生重复条目
	Store.start_library_scan()
	var r2: Dictionary = await Store.scan_finished
	print("[ltest] rescan: found=", r2["found"], " added=", r2["added"], " updated=", r2["updated"], " visible=", Store.visible_games().size(), " total=", Store.games.size())
	print("[ltest] done")

## 游戏内鼠标测试：--mouse-test=输出目录 --bios-dir=.. --hdd=鼠标测试镜像.hdi
## 通过 Input.parse_input_event 注入真实的鼠标 / 键盘事件（与系统事件走同一条路径），
## 再从 PC-98 画面上读出测试程序绘制的光标位置与点击计数。
func _mouse_test(dir: String, bios: String, hdd: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	if bios != "":
		Store.settings["bios_dir"] = bios
	Store.settings["game_mouse"] = true
	Store.settings["mouse_sens"] = 1.0
	var g := {"id": "mousetest", "title": "鼠标测试", "fdd1": "", "fdd2": "", "hdd1": hdd}
	var err: String = emu_view.launch(g)
	print("[mtest] launch err='", err, "'")
	if err != "":
		return
	emu_view.visible = true
	emu_view.auto_run = false
	await get_tree().process_frame
	print("[mtest] after launch: captured=", emu_view.is_mouse_captured(), " Input.mouse_mode=", Input.mouse_mode, " (2=CAPTURED)")
	await _mt_frames(600)
	var c0 := _mt_cursor()
	print("[mtest] boot: cursor cell=", c0, " screen rect=", emu_view.screen.get_global_rect(), " scale=", emu_view._mouse_scale())
	emu_view.emu.get_texture().get_image().save_png(dir + "/m01_start.png")
	if OS.get_environment("MT_REAL") == "1":
		# 真实鼠标（外部 xdotool 发送 XTEST 事件）：模拟器自由运行 12 秒
		emu_view.auto_run = true
		print("[mtest] REAL READY captured=", emu_view.is_mouse_captured())
		await get_tree().create_timer(12.0).timeout
		emu_view.auto_run = false
		print("[mtest] REAL result: cell ", c0, " -> ", _mt_cursor(), " events=", emu_view.mouse_events, " raw relative total=", emu_view.mouse_raw_total, " (xdotool sent ", OS.get_environment("MV_TOTAL"), ")")
		emu_view.emu.get_texture().get_image().save_png(dir + "/r01_real_mouse.png")
		await _shot(dir + "/r02_real_mouse_view.png")
		c0 = _mt_cursor()
	# 1) 移动：20 次 (+20, +8) 屏幕像素
	for i in 20:
		_mt_motion(Vector2(20, 8))
		await _mt_frames(2)
	await _mt_frames(30)
	var c1 := _mt_cursor()
	var exp: Vector2 = Vector2(400, 160) * emu_view._mouse_scale()
	print("[mtest] move (+400,+160) host px -> expected ~(", exp.x, ",", exp.y, ") PC-98 px; cursor cell ", c0, " -> ", c1, " (cell=8x16 px)")
	emu_view.emu.get_texture().get_image().save_png(dir + "/m02_moved.png")
	# 2) 慢速小步移动：60 次 0.5 像素（每次 < 1 个 PC-98 像素，应通过小数累积仍然移动）
	var cs := _mt_cursor()
	for i in 60:
		_mt_motion(Vector2(-0.5, 0))
		await _mt_frames(1)
	await _mt_frames(30)
	print("[mtest] slow 60 x (-0.5) host px -> expected ~", -30.0 * emu_view._mouse_scale(), " PC-98 px; cell ", cs, " -> ", _mt_cursor())
	# 3) 左键 / 右键
	_mt_button(MOUSE_BUTTON_LEFT, true)
	await _mt_frames(20)
	emu_view.emu.get_texture().get_image().save_png(dir + "/m03_left_held.png")
	_mt_button(MOUSE_BUTTON_LEFT, false)
	await _mt_frames(20)
	_mt_button(MOUSE_BUTTON_RIGHT, true)
	await _mt_frames(20)
	_mt_button(MOUSE_BUTTON_RIGHT, false)
	await _mt_frames(20)
	_mt_button(MOUSE_BUTTON_LEFT, true)
	await _mt_frames(10)
	_mt_button(MOUSE_BUTTON_LEFT, false)
	await _mt_frames(20)
	print("[mtest] after clicks (expect L=2 R=1 on PC-98 status line): see m04_clicked.png; events sent=", emu_view.mouse_events)
	emu_view.emu.get_texture().get_image().save_png(dir + "/m04_clicked.png")
	emu_view.auto_run = true
	await _shot(dir + "/m05_view_captured.png")
	emu_view.auto_run = false
	# 4) 中键释放：之后移动 / 点击不送给 PC-98
	_mt_button(MOUSE_BUTTON_MIDDLE, true)
	_mt_button(MOUSE_BUTTON_MIDDLE, false)
	await get_tree().process_frame
	print("[mtest] middle click -> captured=", emu_view.is_mouse_captured(), " mouse_mode=", Input.mouse_mode, " (0=VISIBLE)")
	var cr := _mt_cursor()
	for i in 10:
		_mt_motion(Vector2(-30, -10))
		await _mt_frames(2)
	await _mt_frames(20)
	print("[mtest] motion while released: cell ", cr, " -> ", _mt_cursor(), " (should be unchanged)")
	emu_view.auto_run = true
	await _shot(dir + "/m06_view_released.png")
	emu_view.auto_run = false
	# 5) 在画面上左键单击：重新锁定（这一下不算游戏点击）
	var center: Vector2 = emu_view.screen.get_global_rect().get_center()
	_mt_button(MOUSE_BUTTON_LEFT, true, center)
	_mt_button(MOUSE_BUTTON_LEFT, false, center)
	await _mt_frames(20)
	print("[mtest] click on screen while released -> captured=", emu_view.is_mouse_captured(), " mouse_mode=", Input.mouse_mode)
	emu_view.emu.get_texture().get_image().save_png(dir + "/m07_recaptured.png")
	# 6) Ctrl+F10 切换
	_mt_key(KEY_F10, true, true)
	_mt_key(KEY_F10, false, true)
	await get_tree().process_frame
	print("[mtest] Ctrl+F10 -> captured=", emu_view.is_mouse_captured())
	_mt_key(KEY_F10, true, true)
	_mt_key(KEY_F10, false, true)
	await get_tree().process_frame
	print("[mtest] Ctrl+F10 again -> captured=", emu_view.is_mouse_captured())
	# 7) Esc 菜单释放鼠标，继续后重新锁定
	_mt_key(KEY_ESCAPE, true)
	_mt_key(KEY_ESCAPE, false)
	await get_tree().process_frame
	print("[mtest] Esc -> paused=", emu_view.paused, " captured=", emu_view.is_mouse_captured(), " mouse_mode=", Input.mouse_mode)
	await _shot(dir + "/m08_menu.png")
	_mt_key(KEY_F12, true)
	_mt_key(KEY_F12, false)
	await get_tree().process_frame
	print("[mtest] F12 -> paused=", emu_view.paused, " captured=", emu_view.is_mouse_captured(), " mouse_mode=", Input.mouse_mode)
	# 8) Alt+Enter 全屏仍然可用
	var fs0 := Store.is_fullscreen()
	_mt_key(KEY_ENTER, true, false, true)
	_mt_key(KEY_ENTER, false, false, true)
	for i in 10:
		await get_tree().process_frame
	print("[mtest] Alt+Enter: fullscreen ", fs0, " -> ", Store.is_fullscreen(), " captured=", emu_view.is_mouse_captured())
	_mt_key(KEY_ENTER, true, false, true)
	_mt_key(KEY_ENTER, false, false, true)
	for i in 10:
		await get_tree().process_frame
	print("[mtest] Alt+Enter again: fullscreen=", Store.is_fullscreen(), " captured=", emu_view.is_mouse_captured())
	# 9) 灵敏度 2.0
	await get_tree().create_timer(0.3).timeout  # 重新锁定后的 250 ms 内及第一次移动被忽略（见 emu_view.CAPTURE_SETTLE_MS）
	_mt_motion(Vector2(1, 0))
	await _mt_frames(2)
	Store.settings["mouse_sens"] = 2.0
	var c2 := _mt_cursor()
	for i in 10:
		_mt_motion(Vector2(-10, 0))
		await _mt_frames(2)
	await _mt_frames(30)
	print("[mtest] sens 2.0: 10 x (-10) host px -> expected ~", -100.0 * emu_view._mouse_scale(), " PC-98 px; cell ", c2, " -> ", _mt_cursor())
	Store.settings["mouse_sens"] = 1.0
	# 10) 工具栏「鼠标」按钮关闭：仅键盘，光标自由
	emu_view.open_menu()
	await _shot(dir + "/m09_toolbar.png")
	emu_view.toggle_game_mouse()
	emu_view.resume()
	await get_tree().process_frame
	print("[mtest] toolbar mouse OFF -> setting=", Store.settings.get("game_mouse"), " button='", emu_view.m_mouse.text, "' captured=", emu_view.is_mouse_captured(), " mouse_mode=", Input.mouse_mode)
	var c3 := _mt_cursor()
	for i in 10:
		_mt_motion(Vector2(30, 0))
		await _mt_frames(2)
	_mt_button(MOUSE_BUTTON_LEFT, true, center)
	await _mt_frames(10)
	_mt_button(MOUSE_BUTTON_LEFT, false, center)
	await _mt_frames(20)
	print("[mtest] mouse OFF: motion+click -> cell ", c3, " -> ", _mt_cursor(), " captured=", emu_view.is_mouse_captured(), " (no change expected)")
	emu_view.emu.get_texture().get_image().save_png(dir + "/m10_mouse_off.png")
	emu_view.open_menu()
	emu_view.toggle_game_mouse()
	print("[mtest] toolbar mouse ON again -> button='", emu_view.m_mouse.text, "'")
	await _shot(dir + "/m11_toolbar_on.png")
	emu_view.resume()
	await get_tree().process_frame
	print("[mtest] resume -> captured=", emu_view.is_mouse_captured())
	emu_view.exit_to_library()
	await get_tree().process_frame
	print("[mtest] exit -> mouse_mode=", Input.mouse_mode)
	# 设置页里的鼠标选项（四种语言）
	var old_loc := TranslationServer.get_locale()
	for loc in ["zh_CN", "zh_TW", "en", "ja"]:
		TranslationServer.set_locale(loc)
		show_page("settings")
		await get_tree().process_frame
		await get_tree().process_frame
		settings_scroll.ensure_control_visible(s_mouse_sens)
		await _shot(dir + "/s_settings_mouse_%s.png" % loc)
	TranslationServer.set_locale(old_loc)
	print("[mtest] done")

func _mt_frames(n: int) -> void:
	for i in n:
		emu_view.flush_mouse()
		emu_view.emu.run_frame()
	await get_tree().process_frame

func _mt_motion(rel: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.relative = rel
	ev.screen_relative = rel
	ev.position = emu_view.screen.get_global_rect().get_center()
	Input.parse_input_event(ev)
	Input.flush_buffered_events()

func _mt_button(b: int, pressed: bool, pos := Vector2(-1, -1)) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = b
	ev.pressed = pressed
	ev.position = pos if pos.x >= 0 else emu_view.screen.get_global_rect().get_center()
	ev.global_position = ev.position
	Input.parse_input_event(ev)
	Input.flush_buffered_events()

func _mt_key(code: int, pressed: bool, ctrl := false, alt := false) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	ev.ctrl_pressed = ctrl
	ev.alt_pressed = alt
	Input.parse_input_event(ev)
	Input.flush_buffered_events()

## 读出测试程序画的光标（第 3 行以下唯一的字符）所在字符格
func _mt_cursor() -> Vector2i:
	var img: Image = emu_view.emu.get_texture().get_image()
	var w := img.get_width()
	var h := img.get_height()
	var minx := w
	var miny := h
	for y in range(32, h):
		for x in w:
			if img.get_pixel(x, y).v > 0.5:
				minx = mini(minx, x)
				miny = mini(miny, y)
	if minx == w:
		return Vector2i(-1, -1)
	return Vector2i(minx / 8, miny / 16)

func _shot(path: String) -> void:
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[test] screenshot ", path)

func _screenshot_test(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	if Store.games.is_empty():
		var demo := [["星之迷宫", "", "", "/demo/hoshi.hdi"], ["夜行列车 98", "/demo/yakou_a.fdi", "/demo/yakou_b.fdi", ""],
			["电子侦探 K", "/demo/denshi.fdi", "", ""], ["蓝色海岸线", "", "", "/demo/blue.hdi"], ["机甲少女战记", "/demo/mecha1.fdi", "/demo/mecha2.fdi", ""],
			["魔导书 III", "/demo/madou.fdi", "", ""], ["午后的咖啡馆", "", "", "/demo/cafe.hdi"], ["银河交易商", "/demo/ginga.fdi", "", ""],
			["幻想乡物语", "/demo/gensou.fdi", "", ""], ["赛博东京 2099", "", "", "/demo/tokyo.hdi"]]
		for d in demo:
			Store.add_game(d[0], d[1], d[2], d[3], "")
		var g0: Dictionary = Store.games[0]
		g0["last_played"] = Time.get_unix_time_from_system() - 3600
		g0["play_count"] = 3
		g0["play_seconds"] = 5400
		Store.update_game(g0)
		var g2: Dictionary = Store.games[2]
		g2["last_played"] = Time.get_unix_time_from_system() - 86400
		g2["play_count"] = 1
		Store.update_game(g2)
	show_page("library")
	await _shot(dir + "/01_library.png")
	show_detail(str(Store.games[0]["id"]))
	await _shot(dir + "/02_detail.png")
	show_page("recent")
	await _shot(dir + "/03_recent.png")
	show_page("settings")
	await _shot(dir + "/04_settings.png")
	settings_scroll.ensure_control_visible(add_panel)
	await _shot(dir + "/05_settings_add_game.png")

func _emu_test(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var g := {"id": "test", "title": "内核测试（无介质）", "fdd1": "", "fdd2": "", "hdd1": ""}
	var err: String = emu_view.launch(g)
	print("[test] launch err='", err, "' core=", emu_view.emu.get_core_info())
	emu_view.visible = true
	emu_view.auto_run = false
	var frames := 0
	for i in 240:
		frames += emu_view.emu.run_frame()
	print("[test] video frames produced: ", frames, " size=", emu_view.emu.get_frame_size())
	var img: Image = emu_view.emu.get_texture().get_image()
	img.save_png(dir + "/06_emulator_frame_raw.png")
	emu_view.auto_run = true
	await _shot(dir + "/06_emulator_view.png")
	emu_view.open_menu()
	await _shot(dir + "/07_emulator_menu.png")
	emu_view.emu.power_cycle()
	frames = 0
	for i in 60:
		frames += emu_view.emu.run_frame()
	print("[test] after power_cycle frames: ", frames)
	emu_view.exit_to_library()
	await _media_test(dir)

func _write_blank_image(path: String, header: PackedInt32Array, data_size: int) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	for v in header:
		f.store_32(v)
	var pad := PackedByteArray()
	pad.resize(4096 - header.size() * 4)
	f.store_buffer(pad)
	var chunk := PackedByteArray()
	chunk.resize(65536)
	var left := data_size
	while left > 0:
		var n := mini(left, chunk.size())
		if n < chunk.size():
			chunk.resize(n)
		f.store_buffer(chunk)
		left -= n
	f.close()

func _media_test(dir: String) -> void:
	# self-made blank images (no game data) to exercise the disk APIs
	var tdir := Store.data_path("selftest")
	DirAccess.make_dir_recursive_absolute(tdir)
	var fa := tdir + "/空白软盘A.fdi"
	var fb := tdir + "/blank_b.fdi"
	var hd := tdir + "/blank.hdi"
	var fdd_bytes := 1024 * 8 * 2 * 77
	_write_blank_image(fa, PackedInt32Array([0, 0x90, 4096, fdd_bytes, 1024, 8, 2, 77]), fdd_bytes)
	_write_blank_image(fb, PackedInt32Array([0, 0x90, 4096, fdd_bytes, 1024, 8, 2, 77]), fdd_bytes)
	var hdd_bytes := 512 * 17 * 8 * 40
	_write_blank_image(hd, PackedInt32Array([0, 0, 4096, hdd_bytes, 512, 17, 8, 40]), hdd_bytes)
	var g := {"id": "test2", "title": "介质测试（空白镜像）", "fdd1": fa, "fdd2": "", "hdd1": ""}
	var err: String = emu_view.launch(g)
	print("[media] launch with fdd1 err='", err, "'")
	emu_view.auto_run = false
	var e = emu_view.emu
	var frames := 0
	for i in 120:
		frames += e.run_frame()
	print("[media] frames=", frames, " fdd1=", e.get_disk(0), " fdd2=", e.get_disk(1))
	e.insert_disk(1, fb)
	for i in 10:
		e.run_frame()
	print("[media] after insert fdd2=", e.get_disk(1))
	e.swap_disks()
	for i in 10:
		e.run_frame()
	print("[media] after swap fdd1=", e.get_disk(0), " fdd2=", e.get_disk(1))
	e.eject_disk(1)
	for i in 10:
		e.run_frame()
	print("[media] after eject fdd2='", e.get_disk(1), "'")
	e.mount_hdd(0, hd)
	e.reset()
	frames = 0
	for i in 120:
		frames += e.run_frame()
	print("[media] after hdd mount+reset hdd1=", e.get_hdd(0), " frames=", frames)
	e.key_event(KEY_SPACE, true)
	e.run_frame()
	e.key_event(KEY_SPACE, false)
	e.key_event(KEY_ALT | (1 << 30), true)
	e.run_frame()
	e.release_all_keys()
	e.run_frame()
	Store.settings["font_mode"] = "ttf"
	var t0 := Time.get_ticks_msec()
	e.set_ttf_font(str(Store.settings.get("ttf_file", "")), int(Store.settings.get("ttf_index", 0)))
	e.reload_font(Store.prepare_fonts())
	print("[media] reload_font(ttf) took ", Time.get_ticks_msec() - t0, " ms")
	for i in 30:
		e.run_frame()
	e.get_texture().get_image().save_png(dir + "/08_media_test_frame_raw.png")
	e.power_cycle()
	frames = 0
	for i in 60:
		frames += e.run_frame()
	print("[media] power_cycle keeps media fdd1=", e.get_disk(0), " hdd1=", e.get_hdd(0), " frames=", frames)
	emu_view.auto_run = true
	emu_view.exit_to_library()
	Store.settings["font_mode"] = "auto"
	Store.save_settings()
	print("[media] done")

## 多语言测试：依次切换 4 种界面语言并截图（游戏库 / 设置 / 游戏中菜单）
func _lang_test(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var orig := Store.get_language()
	for loc in I18n.LOCALES:
		if loc == Store.get_language():
			Store.set_language("zh_CN" if loc != "zh_CN" else "en")
			_rebuild_ui()
		set_language(loc)
		await get_tree().process_frame
		await get_tree().process_frame
		print("[lang] locale=", TranslationServer.get_locale(), " sample=", tr("游戏库"), " / ", tr("⛶ 全屏"), " / ", I18n.core_message("模拟器核心在“运行”阶段崩溃：内存访问违例 (SIGSEGV)。已停止模拟。常见原因：BIOS 文件不完整/损坏、镜像文件损坏或机型设置不匹配。"))
		show_page("library")
		await _shot(dir + "/lang_%s_1_library.png" % loc)
		if not Store.games.is_empty():
			show_detail(str(Store.games[0]["id"]))
			await _shot(dir + "/lang_%s_2_detail.png" % loc)
		show_page("settings")
		await _shot(dir + "/lang_%s_3_settings.png" % loc)
		if mobile:
			show_page("import")
			await _shot(dir + "/lang_%s_3b_import.png" % loc)
		var g := {"id": "langtest", "title": "Lang test", "fdd1": "", "fdd2": "", "hdd1": ""}
		var err: String = emu_view.launch(g)
		if err == "":
			emu_view.visible = true
			emu_view.auto_run = false
			for i in 30:
				emu_view.emu.run_frame()
			emu_view.auto_run = true
			emu_view.open_menu()
			await _shot(dir + "/lang_%s_4_emu_menu.png" % loc)
			emu_view.exit_to_library()
	set_language(orig)
	await get_tree().process_frame
	print("[lang] restored locale=", TranslationServer.get_locale())

## 全屏 / 缩放测试：不同窗口尺寸与三种缩放模式下截图，并检查画面矩形保持比例
func _scale_test(dir: String, bios: String, hdd: String, frames: int) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	if bios != "":
		Store.settings["bios_dir"] = bios
	var g := {"id": "scaletest", "title": "缩放测试", "fdd1": "", "fdd2": "", "hdd1": hdd}
	var err: String = emu_view.launch(g)
	print("[scale] launch err='", err, "'")
	if err != "":
		return
	emu_view.visible = true
	emu_view.auto_run = false
	for i in mini(frames, 900):
		emu_view.emu.run_frame()
	emu_view.auto_run = true
	var orig_mode := str(Store.settings.get("scale_mode", "4:3"))
	# 模拟 Alt+Enter 按键事件（按下 + 松开）
	var ev := InputEventKey.new()
	ev.keycode = KEY_ENTER
	ev.physical_keycode = KEY_ENTER
	ev.alt_pressed = true
	ev.pressed = true
	Input.parse_input_event(ev)
	var ev2: InputEventKey = ev.duplicate()
	ev2.pressed = false
	Input.parse_input_event(ev2)
	for i in 10:
		await get_tree().process_frame
	print("[scale] after Alt+Enter: window mode=", get_window().mode, " fullscreen=", Store.is_fullscreen(), " size=", get_window().size)
	await _shot(dir + "/scale_fullscreen_altenter.png")
	for sz in [Vector2i(1280, 800), Vector2i(1920, 1080), Vector2i(1000, 1000)]:
		Store.set_fullscreen(false)
		get_window().size = sz
		for i in 6:
			await get_tree().process_frame
		for mode in Store.SCALE_MODES:
			Store.settings["scale_mode"] = mode
			emu_view._layout()
			var r := Rect2(emu_view.screen.position, emu_view.screen.size)
			print("[scale] window=", get_window().size, " view=", emu_view.size, " mode=", mode, " rect=", r, " aspect=", snappedf(r.size.x / r.size.y, 0.001))
			await _shot(dir + "/scale_%dx%d_%s.png" % [sz.x, sz.y, mode.replace(":", "x")])
	Store.settings["scale_mode"] = orig_mode
	Store.save_settings()
	get_window().size = Vector2i(1280, 800)
	emu_view.exit_to_library()
	print("[scale] done")

# =================================================================== mobile (Android)
## 移动端主界面：内容区 + 底部标签栏（游戏库 / 最近 / 导入 / 设置）
func _build_mobile_main_ui() -> void:
	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", 0)
	ui_root.add_child(col)
	content = Control.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.clip_contents = true
	col.add_child(content)
	var glow := TextureRect.new()
	var gg := Gradient.new()
	gg.set_color(0, Color("#1c2636"))
	gg.set_color(1, Color(UITheme.BG, 0.0))
	var ggt := GradientTexture2D.new()
	ggt.gradient = gg
	ggt.fill_from = Vector2(0, 0)
	ggt.fill_to = Vector2(0, 1)
	glow.texture = ggt
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.set_anchors_preset(Control.PRESET_TOP_WIDE)
	glow.offset_bottom = 260
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(glow)
	bios_status_label = Label.new()
	bios_status_label.add_theme_font_size_override("font_size", 13)
	bios_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pages["library"] = _build_library_page()
	pages["recent"] = _build_recent_page()
	pages["import"] = _build_import_page()
	pages["settings"] = _build_settings_page()
	pages["detail"] = Control.new()
	for k in pages:
		pages[k].set_anchors_preset(Control.PRESET_FULL_RECT)
		content.add_child(pages[k])
	# ---- 底部标签栏
	var bar := PanelContainer.new()
	var sb := UITheme.box(Color("#12161c"), 0, 0, UITheme.BORDER, 0)
	sb.border_width_top = 1
	sb.content_margin_top = 4
	sb.content_margin_bottom = 6
	bar.add_theme_stylebox_override("panel", sb)
	col.add_child(bar)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 0)
	bar.add_child(h)
	for item in [["library", "▦", tr("游戏库")], ["recent", "◷", tr("最近")], ["import", "＋", tr("导入")], ["settings", "⚙", tr("设置")]]:
		var b := Button.new()
		b.text = item[1] + "\n" + item[2]
		b.custom_minimum_size = Vector2(0, 60)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 14)
		b.pressed.connect(show_page.bind(item[0]))
		h.add_child(b)
		sidebar_buttons[item[0]] = b

func _style_tab(b: Button, active: bool) -> void:
	var empty := StyleBoxEmpty.new()
	for st in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
		b.add_theme_stylebox_override(st, empty)
	var c := UITheme.ACCENT if active else UITheme.MUTED
	for fc in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(fc, c)

func _build_mobile_library_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	var head := HBoxContainer.new()
	var hv := _page_header(tr("游戏库"))
	hv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lib_count_label = Label.new()
	lib_count_label.add_theme_color_override("font_color", UITheme.MUTED)
	hv.add_child(lib_count_label)
	head.add_child(hv)
	var add := Button.new()
	add.text = tr("＋ 导入")
	add.custom_minimum_size = Vector2(96, TOUCH_H)
	add.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UITheme.accent_button(add)
	add.pressed.connect(show_page.bind("import"))
	head.add_child(add)
	v.add_child(head)
	search_edit = LineEdit.new()
	search_edit.placeholder_text = tr("🔍  搜索游戏…")
	search_edit.custom_minimum_size = Vector2(0, TOUCH_H)
	search_edit.text_changed.connect(func(_t): _lib_limit = LIB_PAGE; _refresh_lists())
	var sh := HBoxContainer.new()
	sh.add_theme_constant_override("separation", 8)
	search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sh.add_child(search_edit)
	cat_filter = _make_cat_filter()
	cat_filter.custom_minimum_size = Vector2(130, TOUCH_H)
	sh.add_child(cat_filter)
	v.add_child(sh)
	v.add_child(bios_status_label)
	lib_grid = HFlowContainer.new()
	lib_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lib_grid.add_theme_constant_override("h_separation", MOBILE_GAP)
	lib_grid.add_theme_constant_override("v_separation", MOBILE_GAP)
	lib_grid.resized.connect(_mobile_grid_resized)
	v.add_child(lib_grid)
	return _page_shell(v, LIB_MAX_W)

## 竖屏 2–3 列、横屏更多列：卡片宽度按可用宽度均分
func _mobile_grid_resized() -> void:
	if lib_grid == null or not is_instance_valid(lib_grid):
		return
	var w := lib_grid.size.x
	if w < 50:
		return
	var cols := clampi(int((w + MOBILE_GAP) / (150 + MOBILE_GAP)), 2, 8)
	var cw := int((w - MOBILE_GAP * (cols - 1)) / cols) - 1
	if cw != lib_card_w:
		lib_card_w = cw
		_refresh_lists.call_deferred()

## 「导入」页：BIOS / 游戏镜像 / 导入文件夹
func _build_import_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	var hdr := _page_header(tr("导入"), tr("把 BIOS 和游戏镜像导入到本应用中"))
	(hdr.get_child(1) as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hdr)
	var b := _section(tr("BIOS"), tr("选择存放 BIOS 的文件夹（bios.rom、itf.rom、sound.rom、font.bmp / FONT.ROM、2608_*.wav 等），或直接多选这些文件。文件会被复制到本应用的存储空间中。本程序不附带任何 BIOS。") + "\n" + tr(BIOS_OPTIONAL_NOTE))
	m_bios_info = Label.new()
	m_bios_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	m_bios_info.add_theme_font_size_override("font_size", 13)
	b.add_child(m_bios_info)
	var b1 := Button.new()
	b1.text = tr("导入 BIOS 文件夹…")
	UITheme.accent_button(b1)
	b1.pressed.connect(_import_bios_folder)
	b.add_child(b1)
	var b2 := Button.new()
	b2.text = tr("导入 BIOS 文件（可多选）…")
	b2.pressed.connect(_import_bios_files)
	b.add_child(b2)
	v.add_child(b.get_parent())
	var g := _section(tr("游戏镜像"), tr("选择一个 HDI 硬盘镜像，或 1–2 张 FDI 软盘镜像（按文件名顺序作为 FDD1 / FDD2）。镜像会被复制到本应用中，之后可以删除原文件。"))
	var g1 := Button.new()
	g1.text = tr("导入游戏镜像…")
	UITheme.accent_button(g1)
	g1.pressed.connect(_import_games)
	g.add_child(g1)
	v.add_child(g.get_parent())
	var f := _section(tr("导入文件夹"), tr("也可以通过 USB 或文件管理器，把文件直接拷贝到下面的文件夹：BIOS 放在 BIOS 子文件夹中，游戏镜像放在根目录。然后点击「扫描导入文件夹」，镜像会在原位置使用，不会复制。") + "\n" + tr(LIB_RULES_SHORT))
	var pl := Label.new()
	pl.text = Store.external_import_dir()
	pl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	pl.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	pl.add_theme_color_override("font_color", Color("#c3c9d2"))
	pl.add_theme_font_size_override("font_size", 13)
	f.add_child(pl)
	var f1 := Button.new()
	f1.text = tr("扫描导入文件夹")
	f1.pressed.connect(_scan_import_dir)
	f.add_child(f1)
	v.add_child(f.get_parent())
	_touchify(v)
	return _page_shell(v, 900)

## 所有按钮 / 输入框 / 下拉框 / 复选框至少 48 dp 高
func _touchify(n: Node) -> void:
	for c in n.get_children():
		if c is OptionButton:
			(c as OptionButton).fit_to_longest_item = false
			(c as OptionButton).clip_text = true
		if c is Button or c is LineEdit:
			var cc := c as Control
			cc.custom_minimum_size.y = maxf(cc.custom_minimum_size.y, TOUCH_H)
		# 竖直排列的长文字自动换行，避免把页面撑宽
		if c.get_parent() is VBoxContainer:
			if c is Label and (c as Label).autowrap_mode == TextServer.AUTOWRAP_OFF:
				(c as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			elif c is OptionButton:
				(c as OptionButton).fit_to_longest_item = false
				(c as OptionButton).clip_text = true
			elif c is Button and ((c as Control).size_flags_horizontal & Control.SIZE_FILL):
				# 只对横向填满的按钮换行；SHRINK_BEGIN 的按钮（如“返回游戏库”）换行会被压成 0 宽
				(c as Button).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_touchify(c)

func _busy_toast(msg: String) -> void:
	toast(msg, 30.0)
	for i in 3:
		await get_tree().process_frame

func _import_bios_folder() -> void:
	_pick_dir(tr("选择 BIOS 文件夹"), func(p):
		await _busy_toast(tr("正在导入…"))
		var n := Store.import_bios_tree(str(p))
		_after_bios_import(n))

func _import_bios_files() -> void:
	_pick_files(tr("选择 BIOS 文件"), [], func(ps):
		await _busy_toast(tr("正在导入…"))
		var arr: Array = ps if ps is PackedStringArray or ps is Array else [ps]
		var n := Store.import_bios_files(Array(arr))
		_after_bios_import(n))

func _after_bios_import(n: int) -> void:
	_update_bios_label()
	if s_bios:
		s_bios.text = str(Store.settings.get("bios_dir", ""))
		_update_bios_info()
	if n <= 0:
		toast(tr("没有找到可导入的 BIOS 文件"), 4.0)
	elif not Store.bios_status().get("bios.rom", false):
		toast(tr("已导入 %d 个文件（没有 bios.rom，将使用内置兼容 BIOS）") % n, 4.0)
	else:
		toast(tr("已导入 %d 个 BIOS 文件") % n, 3.0)

func _import_games() -> void:
	_pick_files(tr("选择游戏镜像"), FDD_FILTERS, func(ps):
		await _busy_toast(tr("正在导入…（大镜像需要一些时间）"))
		var arr: Array = ps if ps is PackedStringArray or ps is Array else [ps]
		var added := Store.import_game_files(Array(arr))
		_refresh_lists()
		if added.is_empty():
			toast(tr("导入失败：无法读取所选文件"), 4.0)
		else:
			toast(tr("已添加 %d 款游戏") % added.size(), 3.0)
			show_detail(str(added[0]["id"])))

func _scan_import_dir() -> void:
	var r := Store.scan_import_dir()
	_update_bios_label()
	if int(r["bios"]) > 0:
		toast(tr("已找到 BIOS 文件 %d 个，正在扫描游戏…") % int(r["bios"]), 3.0)
	_start_scan()

## Android 上选到的是 content:// URI：复制到数据目录后返回真实路径
func _import_if_needed(p: String, sub: String) -> String:
	if not p.begins_with("content://"):
		return p
	var dst := Store.import_file(p, Store.data_path("imported/" + sub))
	if dst == "":
		toast(tr("导入失败：无法读取所选文件"), 4.0)
	return dst

## 设置页的路径行（移动端）：标签在上，输入框 + 「选择…」在下
func _mobile_path_row(parent: Control, label: String, placeholder: String, filters: Array, dir_mode := false) -> LineEdit:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.add_child(_row_label(label))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.custom_minimum_size = Vector2(0, TOUCH_H)
	h.add_child(e)
	var b := Button.new()
	b.text = tr("导入…") if Store.is_android() else tr("浏览…")
	b.custom_minimum_size = Vector2(88, TOUCH_H)
	b.pressed.connect(func():
		if dir_mode:
			_pick_dir(label, func(p):
				var path := str(p)
				if path.begins_with("content://"):
					await _busy_toast(tr("正在导入…"))
					var n := Store.import_bios_tree(path)
					_after_bios_import(n)
					path = str(Store.settings.get("bios_dir", ""))
				e.text = path
				e.text_submitted.emit(path))
		else:
			_pick_file(label, filters, func(p):
				var sub := "fonts" if filters == TTF_FILTERS or filters == FONT_FILTERS else "disks"
				await _busy_toast(tr("正在导入…"))
				var path := _import_if_needed(str(p), sub)
				toast_label.visible = false
				if path != "":
					e.text = path
					e.text_submitted.emit(path)))
	h.add_child(b)
	v.add_child(h)
	parent.add_child(v)
	return e

## 详情页（移动端）：封面 + 标题并排，下面依次是「开始游戏」、统计、介质、操作按钮
func _build_mobile_detail_page(g: Dictionary) -> Control:
	var root := Control.new()
	var hero := TextureRect.new()
	hero.texture = UITheme.cover_texture(g, 600, 300)
	hero.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hero.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	hero.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hero.offset_bottom = 240
	hero.modulate = Color(0.45, 0.45, 0.5)
	root.add_child(hero)
	var fade := TextureRect.new()
	var gr := Gradient.new()
	gr.set_color(0, Color(UITheme.BG, 0.0))
	gr.set_color(1, UITheme.BG)
	var gt := GradientTexture2D.new()
	gt.gradient = gr
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	fade.texture = gt
	fade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fade.set_anchors_preset(Control.PRESET_TOP_WIDE)
	fade.offset_bottom = 242
	root.add_child(fade)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	var sc := _page_shell(v, 760)
	sc.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(sc)
	var back := Button.new()
	back.text = tr("‹  返回游戏库")
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.custom_minimum_size = Vector2(0, TOUCH_H)
	back.add_theme_stylebox_override("normal", UITheme.box(Color("#00000066"), 6, 14))
	back.pressed.connect(show_page.bind("library"))
	v.add_child(back)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	v.add_child(h)
	h.add_child(_cover_widget(g, Vector2(132, 176), 18))
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.alignment = BoxContainer.ALIGNMENT_END
	info.add_theme_constant_override("separation", 6)
	h.add_child(info)
	var t := Label.new()
	t.text = str(g.get("title", ""))
	t.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.add_theme_font_size_override("font_size", 26)
	info.add_child(t)
	var kind := Label.new()
	kind.text = "PC-9801 · " + Store.media_kind(g) + ((" · " + tr("分类：") + str(g["category"])) if str(g.get("category", "")) != "" else "")
	kind.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	kind.add_theme_color_override("font_color", UITheme.MUTED)
	info.add_child(kind)
	var play := Button.new()
	play.text = tr("▶  开始游戏")
	UITheme.accent_button(play, true)
	play.custom_minimum_size = Vector2(0, 56)
	play.size_flags_horizontal = Control.SIZE_FILL
	play.pressed.connect(launch_game.bind(str(g["id"])))
	v.add_child(play)
	var s1 := Label.new()
	s1.text = tr("上次游玩：") + _fmt_time(float(g.get("last_played", 0)))
	s1.add_theme_color_override("font_color", UITheme.MUTED)
	v.add_child(s1)
	var s2 := Label.new()
	var mins := int(g.get("play_seconds", 0)) / 60
	s2.text = tr("游玩次数：%d    游玩时长：%d 小时 %d 分钟") % [int(g.get("play_count", 0)), mins / 60, mins % 60]
	s2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	s2.add_theme_color_override("font_color", UITheme.MUTED)
	v.add_child(s2)
	var media := PanelContainer.new()
	media.add_theme_stylebox_override("panel", UITheme.card_panel(16))
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 6)
	var mt := Label.new()
	mt.text = tr("介质")
	mt.add_theme_font_size_override("font_size", 18)
	mv.add_child(mt)
	_media_lines(mv, g)
	media.add_child(mv)
	v.add_child(media)
	var ops := VBoxContainer.new()
	ops.add_theme_constant_override("separation", 8)
	var cov := Button.new()
	cov.text = tr("更换封面…")
	cov.pressed.connect(func(): _pick_file(tr("选择封面图片"), IMG_FILTERS, func(p):
		var path := _import_if_needed(str(p), "covers")
		if path == "":
			return
		var gg := Store.get_game(str(g["id"]))
		gg["cover"] = path
		Store.update_game(gg)
		show_detail(str(g["id"]))))
	ops.add_child(cov)
	var ren := Button.new()
	ren.text = tr("重命名")
	ren.pressed.connect(func(): _rename_dialog(str(g["id"])))
	ops.add_child(ren)
	var del := Button.new()
	del.text = tr("从游戏库移除")
	del.add_theme_color_override("font_color", UITheme.DANGER)
	del.pressed.connect(func(): _confirm(tr("确定要从游戏库移除「%s」吗？（不会删除镜像文件）") % g["title"], func():
		Store.remove_or_hide(str(g["id"]))
		show_page("library")))
	ops.add_child(del)
	v.add_child(ops)
	_touchify(v)
	return root

## 移动端界面测试（桌面上用 --force-mobile 预览）：竖屏游戏库 / 详情 / 导入 / 设置，横屏模拟器 + 触屏按键 + 虚拟键盘
func _mobile_test(dir: String, bios: String, hdd: String, frames: int) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	if Store.games.is_empty():
		for d in [["星之迷宫", "", "", "/demo/hoshi.hdi"], ["夜行列车 98", "/demo/a.fdi", "/demo/b.fdi", ""], ["电子侦探 K", "/demo/denshi.fdi", "", ""],
				["蓝色海岸线", "", "", "/demo/blue.hdi"], ["机甲少女战记", "/demo/m1.fdi", "", ""], ["魔导书 III", "/demo/madou.fdi", "", ""], ["午后的咖啡馆", "", "", "/demo/cafe.hdi"]]:
			Store.add_game(d[0], d[1], d[2], d[3], "")
	var portrait := get_window().size
	show_page("library")
	await _shot(dir + "/m01_library_portrait.png")
	show_detail(str(Store.games[0]["id"]))
	await _shot(dir + "/m02_detail_portrait.png")
	show_page("import")
	await _shot(dir + "/m03_import_portrait.png")
	show_page("settings")
	await _shot(dir + "/m04_settings_portrait.png")
	settings_scroll.scroll_vertical = 900
	await _shot(dir + "/m05_settings_portrait_2.png")
	settings_scroll.scroll_vertical = 0
	get_window().size = Vector2i(portrait.y, portrait.x)
	for i in 6:
		await get_tree().process_frame
	show_page("library")
	await _shot(dir + "/m06_library_landscape.png")
	if bios != "":
		Store.settings["bios_dir"] = bios
	var g := {"id": "mobiletest", "title": "触屏测试", "fdd1": "", "fdd2": "", "hdd1": hdd}
	var err: String = emu_view.launch(g)
	print("[mobile] launch err='", err, "'")
	if err == "":
		emu_view.visible = true
		emu_view.auto_run = false
		for i in maxi(frames, 60):
			emu_view.emu.run_frame()
		emu_view.auto_run = true
		await _shot(dir + "/m07_emulator_touch_overlay.png")
		emu_view.set_vkbd_visible(true)
		await _shot(dir + "/m08_virtual_keyboard.png")
		emu_view.set_vkbd_visible(false)
		on_back()
		await _shot(dir + "/m09_back_menu.png")
		emu_view.exit_to_library()
	get_window().size = portrait
	print("[mobile] done")


# =================================================================== 游戏库文件夹（递归扫描）
const LIB_RULES_SHORT := "扫描规则：子文件夹会被递归扫描。第一层文件夹（如「あ」「R」「OS」）是分类；单独的镜像文件 = 一款游戏；更深一层、只包含镜像的文件夹 = 一款多碟游戏（文件夹名为游戏名，里面的软盘按 Disk1、Disk2… 顺序组成换盘列表）。镜像在原位置使用，不会复制。"

func _has_test_args() -> bool:
	for a in OS.get_cmdline_user_args():
		if a.ends_with("-test") or a.contains("-test="):
			return true
	return false

func _make_cat_filter() -> OptionButton:
	var o := OptionButton.new()
	o.clip_text = true
	o.fit_to_longest_item = false
	o.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	o.tooltip_text = tr("按分类筛选")
	o.item_selected.connect(func(_i): _lib_limit = LIB_PAGE; _refresh_lists())
	return o

func _fill_cat_filter() -> void:
	if cat_filter == null or not is_instance_valid(cat_filter):
		return
	var prev = null
	if cat_filter.selected > 0 and cat_filter.selected - 1 < _cat_keys.size():
		prev = _cat_keys[cat_filter.selected - 1]
	var cats := Store.categories()
	_cat_keys = []
	cat_filter.clear()
	cat_filter.add_item(tr("全部分类"))
	var sel := 0
	for c in cats:
		_cat_keys.append(c[0])
		cat_filter.add_item("%s (%d)" % [c[0] if c[0] != "" else tr("未分类"), c[1]])
		if prev != null and c[0] == prev:
			sel = _cat_keys.size()
	cat_filter.select(sel)
	cat_filter.visible = cats.size() > 1 or (cats.size() == 1 and cats[0][0] != "")

func _badge_text(g: Dictionary) -> String:
	var h := str(g.get("hdd1", ""))
	var p := h if h != "" else str(g.get("fdd1", ""))
	var ext := p.get_extension().to_upper()
	if ext == "" or ext.length() > 4:
		ext = "HDI" if h != "" else "FDI"
	var n: int = (g.get("disks", []) as Array).size()
	if h == "" and n > 1:
		ext += " ×%d" % n
	return ext

## 详情页「介质」：多碟游戏列出整组软盘
func _media_lines(mv: VBoxContainer, g: Dictionary) -> void:
	var lines := []
	var disks: Array = g.get("disks", [])
	var hdds: Array = g.get("hdds", [])
	if disks.size() > 2 or hdds.size() > 1 or (not hdds.is_empty() and not disks.is_empty()):
		for i in hdds.size():
			lines.append([("HDD1" if i == 0 else tr("硬盘 %d") % (i + 1)), str(hdds[i])])
		for i in disks.size():
			var tag := tr("软盘 %d") % (i + 1)
			if str(disks[i]) == str(g.get("fdd1", "")):
				tag += " (FDD1)"
			elif str(disks[i]) == str(g.get("fdd2", "")):
				tag += " (FDD2)"
			lines.append([tag, str(disks[i])])
	else:
		for pair in [["FDD1", "fdd1"], ["FDD2", "fdd2"], ["HDD1", "hdd1"]]:
			lines.append([pair[0], str(g.get(pair[1], ""))])
	for ln in lines:
		var p: String = ln[1]
		var l := Label.new()
		l.text = tr("%s：%s") % [ln[0], p.get_file() if p != "" else tr("（无）")]
		l.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		l.tooltip_text = p
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		if mobile:
			l.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		if p != "" and not FileAccess.file_exists(p):
			l.text += tr("   ⚠ 文件不存在")
			l.add_theme_color_override("font_color", Color("#e0a040"))
		mv.add_child(l)
	if disks.size() > 2:
		var hint := Label.new()
		hint.text = tr("游戏中按 Esc/F12 打开菜单，在「FDD1」「FDD2」中可直接换成本游戏的任意一张软盘。")
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_color_override("font_color", UITheme.MUTED)
		hint.add_theme_font_size_override("font_size", 12)
		mv.add_child(hint)

func _build_library_folder_section(v: Control) -> void:
	var desc := tr("选择存放游戏的总文件夹（可以有多层子文件夹），程序会自动递归扫描并加入游戏库。") + "\n" + tr(LIB_RULES_SHORT)
	var sec := _section(tr("游戏库文件夹"), desc)
	if Store.is_android():
		var lv := VBoxContainer.new()
		lv.add_theme_constant_override("separation", 6)
		lv.add_child(_row_label(tr("游戏库文件夹")))
		s_libroot = LineEdit.new()
		s_libroot.placeholder_text = Store.external_import_dir()
		s_libroot.custom_minimum_size = Vector2(0, TOUCH_H)
		lv.add_child(s_libroot)
		var note := Label.new()
		note.text = tr("安卓版：留空 = 使用「导入」页中的导入文件夹（通过 USB / 文件管理器把游戏拷贝进去，可以按分类建子文件夹）。也可以填写本应用有权限读取的其它文件夹路径。")
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_color_override("font_color", UITheme.MUTED)
		note.add_theme_font_size_override("font_size", 13)
		lv.add_child(note)
		sec.add_child(lv)
	else:
		s_libroot = _path_row(sec, tr("游戏库文件夹"), tr("例如 D:/PC98/Games"), [], true)
	s_libroot.text_submitted.connect(func(_t): _apply_lib_root(true))
	s_libroot.focus_exited.connect(func(): _apply_lib_root(false))
	s_lib_auto = CheckBox.new()
	s_lib_auto.text = tr("启动时自动扫描游戏库文件夹")
	s_lib_auto.toggled.connect(func(b):
		Store.settings["library_autoscan"] = b
		Store.save_settings())
	_indented(sec, s_lib_auto)
	var bh := HBoxContainer.new()
	bh.add_theme_constant_override("separation", 10)
	var sb := Button.new()
	sb.text = tr("⟳ 扫描 / 刷新游戏库")
	UITheme.accent_button(sb)
	sb.pressed.connect(func(): _apply_lib_root(false); _start_scan())
	bh.add_child(sb)
	s_lib_unhide = Button.new()
	s_lib_unhide.pressed.connect(func():
		var n := Store.unhide_all()
		toast(tr("已恢复 %d 款隐藏的游戏") % n)
		_update_lib_status())
	bh.add_child(s_lib_unhide)
	_indented(sec, bh)
	s_lib_status = Label.new()
	s_lib_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	s_lib_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s_lib_status.add_theme_font_size_override("font_size", 13)
	s_lib_status.add_theme_color_override("font_color", UITheme.MUTED)
	s_lib_status.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_indented(sec, s_lib_status)
	v.add_child(sec.get_parent())

func _apply_lib_root(rescan: bool) -> void:
	if s_libroot == null:
		return
	var p := s_libroot.text.strip_edges().replace("\\", "/").trim_suffix("/")
	if p.begins_with("content://"):
		toast(tr("安卓系统文件夹选择器返回的地址无法直接扫描，请把游戏放进导入文件夹，或填写文件夹的实际路径。"), 5.0)
		s_libroot.text = str(Store.settings.get("library_root", ""))
		return
	var changed := p != str(Store.settings.get("library_root", ""))
	if changed:
		Store.set_library_root(p)
		_update_lib_status()
		if lib_scan_btn:
			lib_scan_btn.visible = p != ""
	if rescan or (changed and p != ""):
		_start_scan()

func _update_lib_status(extra := "") -> void:
	if s_lib_status == null or not is_instance_valid(s_lib_status):
		return
	var root := Store.library_root()
	var n := 0
	for g in Store.games:
		if str(g.get("source", "")) == "scan" and not bool(g.get("hidden", false)):
			n += 1
	var t := ""
	if root == "":
		t = tr("尚未选择游戏库文件夹。")
	elif not DirAccess.dir_exists_absolute(root):
		t = tr("⚠ 文件夹不存在") + "：" + root
	else:
		t = tr("游戏库文件夹中的游戏：%d 款") % n
	if extra != "":
		t += "\n" + extra
	s_lib_status.text = t
	var h := Store.hidden_count()
	s_lib_unhide.text = tr("恢复已隐藏的游戏（%d）") % h
	s_lib_unhide.disabled = h == 0

func _start_scan() -> void:
	if Store.scan_running:
		toast(tr("正在扫描游戏库…"))
		return
	if Store.start_library_scan():
		toast(tr("正在扫描游戏库…"), 30.0)
		_update_lib_status(tr("正在扫描游戏库…"))
		_refresh_lists()

func _on_scan_progress(dirs: int, found: int) -> void:
	var msg := tr("正在扫描游戏库… 已扫描 %d 个文件夹，找到 %d 款游戏") % [dirs, found]
	toast(msg, 30.0)
	_update_lib_status(msg)
	if lib_count_label and is_instance_valid(lib_count_label):
		lib_count_label.text = tr("共 %d 款游戏") % Store.visible_games().size() + "   " + msg

func _on_scan_finished(r: Dictionary) -> void:
	if r.has("error"):
		var root := str(r.get("root", ""))
		toast(tr("尚未选择游戏库文件夹。") if root == "" else tr("⚠ 文件夹不存在") + "：" + root, 4.0)
		_update_lib_status()
		return
	var msg := tr("扫描完成：%d 款游戏（新增 %d，缺失 %d），用时 %.1f 秒") % [int(r["found"]), int(r["added"]), int(r["missing"]), (int(r["msec"]) + int(r["merge_msec"])) / 1000.0]
	toast(msg, 5.0)
	_fill_cat_filter()
	_refresh_lists()
	_update_lib_status(msg)
