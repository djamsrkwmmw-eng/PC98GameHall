extends Control
## 模拟器视图：等比例放大的 640x400 画面（4:3 / 原始比例 / 整数倍，黑边填充）+ NP2 风格菜单栏
## 界面文字：固定文字直接写翻译键（简体中文），由 Control 的自动翻译随语言切换；动态文字用 tr()

signal exited(game_id: String, seconds: float)
signal crashed(message: String)

var emu: Node
var screen: TextureRect
var bar: PanelContainer
var status: Label
var hint: Label
var player: AudioStreamPlayer
var playback: AudioStreamGeneratorPlayback
var game: Dictionary = {}
var paused := false
var auto_run := true
var _frames_run := 0
var _acc := 0.0
var _started_at := 0.0
var _fd: FileDialog
var _fd_cb: Callable
var m_fdd := []
var m_hdd: MenuButton
var m_font: MenuButton
var m_sys: MenuButton
var m_view: MenuButton
var fs_button: Button
var m_mouse: Button
var _last_frame := Vector2i.ZERO

# ---- 游戏内鼠标（PC-98 总线鼠标）
var _captured := false          # 桌面版：系统光标已锁定到游戏画面，鼠标移动 / 按键送给 PC-98
var _mouse_acc := Vector2.ZERO  # 尚未送出的移动量（PC-98 像素，保留小数部分）
var mouse_events := 0           # 已送给核心的鼠标事件数（测试用）
var mouse_raw_total := Vector2.ZERO  # 测试用：累计收到的系统鼠标相对移动量

# ---- 移动端（Android）触屏控制
var mobile := false
var touch_layer: Control        # 方向键 + RETURN/ESC/SPACE + 右上角工具按钮
var pad_group: Control          # 方向键 / 动作键（可在设置中隐藏）
var vkbd: Control               # PC-98 虚拟键盘
var vkbd_visible := false
var _keys: Array = []           # [{node, code, kind, label}]
var _touch_map := {}            # 触点 index -> key 字典
var _latched := {}              # 已锁定的修饰键 code -> true
var _mt := -1                   # 当前用于鼠标的触点
var _mt_start := Vector2.ZERO
var _mt_time := 0
var _mt_moved := 0.0
var _mt_two := false
const KEY_UNIT := 60.0          # 触屏按键基准尺寸（逻辑像素 ≈ dp）

func _ready() -> void:
	mobile = Store.is_mobile()
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	screen = TextureRect.new()
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.stretch_mode = TextureRect.STRETCH_SCALE
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(screen)
	resized.connect(_layout)
	Store.fullscreen_changed.connect(func(_on):
		_update_fs_button()
		_layout.call_deferred())

	emu = ClassDB.instantiate("PC98Emulator")
	if emu == null:
		push_error("PC98Emulator GDExtension not loaded")
	else:
		add_child(emu)
		screen.texture = emu.get_texture()
		emu.core_crashed.connect(_on_core_crashed)

	player = AudioStreamPlayer.new()
	add_child(player)

	if mobile:
		_build_touch()
	_build_bar()
	hint = Label.new()
	hint.text = "按返回键或右上角 ≡ 打开菜单 · 在画面上滑动移动鼠标，点按 = 左键" if mobile else "按 Esc / F12 打开菜单 · Alt+Enter 全屏"
	hint.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	hint.add_theme_stylebox_override("normal", UITheme.box(Color("#000000aa"), 6, 12))
	hint.add_theme_font_size_override("font_size", 13)
	hint.position = Vector2(16, 16)
	add_child(hint)

	_fd = FileDialog.new()
	_fd.access = FileDialog.ACCESS_FILESYSTEM
	_fd.use_native_dialog = true
	_fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_fd.size = Vector2i(900, 600)
	_fd.file_selected.connect(func(p): if _fd_cb.is_valid(): _fd_cb.call(p))
	add_child(_fd)
	_layout()

func _build_bar() -> void:
	bar = PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.add_theme_stylebox_override("panel", UITheme.box(Color("#0c0e12f0"), 0, 10))
	add_child(bar)
	var v := VBoxContainer.new()
	bar.add_child(v)
	var h: Container
	if mobile:
		var fl := HFlowContainer.new()
		fl.add_theme_constant_override("h_separation", 8)
		fl.add_theme_constant_override("v_separation", 8)
		h = fl
	else:
		h = HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
	v.add_child(h)
	for d in 2:
		var mb := MenuButton.new()
		mb.text = "FDD%d" % (d + 1)
		mb.flat = false
		mb.about_to_popup.connect(_fill_fdd_menu.bind(d))
		mb.get_popup().id_pressed.connect(_on_fdd_menu.bind(d))
		h.add_child(mb)
		m_fdd.append(mb)
	var sw := Button.new()
	sw.text = "⇄ 交换软盘"
	sw.pressed.connect(func():
		emu.swap_disks()
		_toast(tr("已交换 FDD1 / FDD2"))
		_update_status())
	h.add_child(sw)
	m_hdd = MenuButton.new()
	m_hdd.text = "HDD"
	m_hdd.flat = false
	m_hdd.about_to_popup.connect(_fill_hdd_menu)
	m_hdd.get_popup().id_pressed.connect(_on_hdd_menu)
	h.add_child(m_hdd)
	m_font = MenuButton.new()
	m_font.text = "字体"
	m_font.flat = false
	m_font.about_to_popup.connect(_fill_font_menu)
	m_font.get_popup().id_pressed.connect(_on_font_menu)
	h.add_child(m_font)
	m_view = MenuButton.new()
	m_view.text = "画面"
	m_view.flat = false
	m_view.about_to_popup.connect(_fill_view_menu)
	m_view.get_popup().id_pressed.connect(_on_view_menu)
	h.add_child(m_view)
	m_mouse = Button.new()
	m_mouse.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	m_mouse.pressed.connect(toggle_game_mouse)
	h.add_child(m_mouse)
	_update_mouse_button()
	var sep := VSeparator.new()
	h.add_child(sep)
	var rs := Button.new()
	rs.text = "↺ 重置"
	rs.tooltip_text = "软重置（与 NP2 的「Reset」相同，更换磁盘后使用）"
	rs.pressed.connect(func():
		emu.reset()
		_toast(tr("已重置"))
		resume())
	h.add_child(rs)
	var pc := Button.new()
	pc.text = "↻ 重新启动"
	pc.tooltip_text = "电源循环：完全重新加载模拟器（保留当前插入的磁盘）"
	pc.pressed.connect(func():
		_apply_settings()
		if emu.power_cycle():
			_toast(tr("已重新启动（电源循环）"))
		else:
			_toast(tr("重新启动失败：") + I18n.core_message(emu.get_last_error()))
		resume())
	h.add_child(pc)
	if mobile:
		var kb := Button.new()
		kb.text = "虚拟键盘"
		kb.pressed.connect(func():
			resume()
			set_vkbd_visible(true))
		h.add_child(kb)
		var tp := Button.new()
		tp.text = "显示 / 隐藏触屏按键"
		tp.pressed.connect(func():
			Store.settings["touch_pad"] = not bool(Store.settings.get("touch_pad", true))
			Store.save_settings()
			resume())
		h.add_child(tp)
	else:
		fs_button = Button.new()
		fs_button.tooltip_text = "Alt+Enter"
		fs_button.pressed.connect(toggle_fullscreen)
		h.add_child(fs_button)
		_update_fs_button()
		var fill := Control.new()
		fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(fill)
	var cont := Button.new()
	cont.text = "▶ 继续"
	UITheme.accent_button(cont)
	cont.pressed.connect(resume)
	h.add_child(cont)
	var back := Button.new()
	back.text = "返回游戏库"
	back.pressed.connect(exit_to_library)
	h.add_child(back)
	if mobile:
		for c in h.get_children():
			if c is Button:
				c.custom_minimum_size.y = 52
				c.add_theme_font_size_override("font_size", 17)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if mobile else TextServer.AUTOWRAP_OFF
	status.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	status.add_theme_color_override("font_color", UITheme.MUTED)
	status.add_theme_font_size_override("font_size", 12)
	v.add_child(status)
	bar.visible = false

func _frame_size() -> Vector2:
	var fs := Vector2(640, 400)
	if emu != null and emu.has_method("get_frame_size"):
		var v = emu.get_frame_size()
		if (v is Vector2 or v is Vector2i) and v.x > 0 and v.y > 0:
			fs = Vector2(v)
	return fs

## 计算在 avail 内保持比例的最大画面矩形（居中，其余为黑边）
static func fit_rect(avail: Vector2, frame: Vector2, mode: String) -> Rect2:
	if avail.x <= 0 or avail.y <= 0 or frame.x <= 0 or frame.y <= 0:
		return Rect2(Vector2.ZERO, avail)
	var w: float
	var h: float
	if mode == "integer":
		# 方形像素，整数倍放大（窗口太小时退回等比例缩小）
		var n := floorf(minf(avail.x / frame.x, avail.y / frame.y))
		if n >= 1.0:
			w = frame.x * n
			h = frame.y * n
		else:
			return fit_rect(avail, frame, "native")
	else:
		var aspect := 4.0 / 3.0 if mode == "4:3" else frame.x / frame.y
		w = avail.x
		h = w / aspect
		if h > avail.y:
			h = avail.y
			w = h * aspect
	w = floorf(w)
	h = floorf(h)
	return Rect2(floorf((avail.x - w) / 2.0), floorf((avail.y - h) / 2.0), w, h)

func _layout() -> void:
	if screen == null:
		return
	var mode := str(Store.settings.get("scale_mode", "4:3"))
	var area := Rect2(Vector2.ZERO, size)
	if mobile:
		area = _layout_touch()
	var r := fit_rect(area.size, _frame_size(), mode)
	r.position += area.position
	screen.position = r.position
	screen.size = r.size
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if mode == "integer" else CanvasItem.TEXTURE_FILTER_LINEAR

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and status != null:
		_update_status()
		_update_fs_button()
		_update_mouse_button()
		_update_hint()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		# 切换到其他窗口（Alt+Tab 等）时自动释放鼠标，回来后点击画面重新锁定。
		# 部分 X11 环境在鼠标抓取 / 点击时会发出短暂的失焦通知，所以稍后再确认窗口确实失去了焦点。
		if _captured:
			get_tree().create_timer(0.2).timeout.connect(_check_focus_lost)

# ------------------------------------------------------------------ lifecycle
func _apply_settings() -> void:
	var s := Store.settings
	Store.prepare_system_dir()
	emu.set_core_path(Store.core_path())
	emu.set_system_dir(Store.system_dir())
	emu.set_core_option("np2kai_keyboard", str(s.get("keyboard", "Us")))
	emu.set_core_option("np2kai_model", str(s.get("model", "PC-9801VX")))
	# PC-98 总线鼠标：核心只有在此选项为 ON 时才读取鼠标（未提供时核心完全忽略鼠标输入）。
	# 始终打开；是否把鼠标送给游戏由「启用游戏内鼠标」/ 触控板鼠标设置决定，可在游戏中随时切换。
	emu.set_core_option("np2kai_inputmouse", "ON")
	var mode := str(s.get("font_mode", "auto"))
	emu.set_ttf_font(str(s.get("ttf_file", "")), int(s.get("ttf_index", 0)))

func launch(g: Dictionary) -> String:
	if emu == null:
		return "GDExtension 未加载"
	game = g
	_apply_settings()
	var media := {"fdd1": str(g.get("fdd1", "")), "fdd2": str(g.get("fdd2", "")), "hdd1": str(g.get("hdd1", "")), "hdd2": ""}
	if not emu.start(media):
		return emu.get_last_error()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = emu.get_sample_rate()
	gen.buffer_length = 0.12
	player.stream = gen
	player.play()
	playback = player.get_stream_playback()
	_started_at = Time.get_unix_time_from_system()
	_acc = 0.0
	_mouse_acc = Vector2.ZERO
	mouse_events = 0
	paused = false
	bar.visible = false
	_update_hint()
	hint.visible = true
	if mobile:
		if Store.is_android():
			DisplayServer.screen_set_orientation(DisplayServer.SCREEN_SENSOR_LANDSCAPE)
		_release_touch_keys()
		_refresh_touch()
	get_tree().create_timer(4.0).timeout.connect(func(): if hint: hint.visible = false)
	_update_status()
	_update_mouse_button()
	grab_focus()
	# 延后到本帧末尾：调用方在 launch() 之后才把视图设为可见
	set_mouse_capture.call_deferred(true)
	return ""

func exit_to_library() -> void:
	var secs := Time.get_unix_time_from_system() - _started_at
	if emu:
		emu.stop()
	player.stop()
	playback = null
	if mobile:
		_release_touch_keys()
		set_vkbd_visible(false)
		if Store.is_android():
			DisplayServer.screen_set_orientation(DisplayServer.SCREEN_SENSOR)
	_captured = false
	_mouse_acc = Vector2.ZERO
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	exited.emit(str(game.get("id", "")), secs)

## 核心崩溃（已被 GDExtension 拦截）：返回游戏库并报告错误，而不是整个程序闪退
func _on_core_crashed(message: String) -> void:
	push_warning("[PC98] " + message)
	if visible:
		exit_to_library()
	crashed.emit(message)

func open_menu() -> void:
	paused = true
	set_mouse_capture(false)
	bar.visible = true
	hint.visible = false
	_release_touch_keys()
	emu.release_all_keys()
	_update_status()
	_update_mouse_button()
	_refresh_touch()

func resume() -> void:
	paused = false
	bar.visible = false
	_refresh_touch()
	grab_focus()
	set_mouse_capture(true)

# ------------------------------------------------------------------ 游戏内鼠标
## 桌面版：是否启用游戏内鼠标（设置「启用游戏内鼠标（PC-98 总线鼠标）」，默认开）
func _check_focus_lost() -> void:
	if _captured and not get_window().has_focus():
		set_mouse_capture(false)

func game_mouse_enabled() -> bool:
	if mobile:
		return bool(Store.settings.get("touch_mouse", true))
	return bool(Store.settings.get("game_mouse", true))

func is_mouse_captured() -> bool:
	return _captured

## 锁定 / 释放系统光标。锁定时光标隐藏，鼠标移动以相对量送给 PC-98；释放后光标可自由移出窗口。
const CAPTURE_SETTLE_MS := 250
var _capture_ms := 0
var _skip_motion := false

func set_mouse_capture(on: bool, announce := false) -> void:
	if mobile:
		return
	var want: bool = on and game_mouse_enabled() and visible and not paused and emu != null and emu.is_running()
	var was := _captured
	_captured = want
	if want:
		# 锁定时系统会把光标移到窗口中央，Windows / Wine 会把这次移动当作一次很大的相对移动发过来，忽略锁定后最初的一小段时间
		_capture_ms = Time.get_ticks_msec()
		_skip_motion = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if want else Input.MOUSE_MODE_VISIBLE
	if not want:
		_mouse_acc = Vector2.ZERO
		if was and emu:
			emu.mouse_button(0, false)
			emu.mouse_button(1, false)
			_btn_release_pending = [false, false]
	if announce and was != want:
		if want:
			_toast(tr("鼠标已锁定到游戏画面 · 中键或 Ctrl+F10 释放"))
		else:
			_toast(tr("鼠标已释放 · 点击游戏画面重新锁定"))
	_update_mouse_button()

## 工具栏「鼠标」按钮：开 / 关游戏内鼠标（桌面版 = 启用游戏内鼠标；移动端 = 触控板鼠标），保存到设置
func toggle_game_mouse() -> void:
	var key := "touch_mouse" if mobile else "game_mouse"
	var on := not game_mouse_enabled()
	Store.settings[key] = on
	Store.save_settings()
	if not on:
		set_mouse_capture(false)
		if emu:
			emu.mouse_button(0, false)
			emu.mouse_button(1, false)
			_btn_release_pending = [false, false]
	_toast(tr("游戏内鼠标：已开启") if on else tr("游戏内鼠标：已关闭（仅键盘）"))
	_update_mouse_button()
	_update_hint()
	_update_status()

func _update_mouse_button() -> void:
	if m_mouse == null:
		return
	var on := game_mouse_enabled()
	m_mouse.text = tr("鼠标：开") if on else tr("鼠标：关")
	if mobile:
		m_mouse.tooltip_text = tr("触控板鼠标：在画面上滑动移动鼠标，点按 = 左键，双指点按 = 右键")
	else:
		m_mouse.tooltip_text = tr("游戏内鼠标（PC-98 总线鼠标）：继续游戏后鼠标锁定到画面；中键或 Ctrl+F10 释放 / 重新锁定")

func _update_hint() -> void:
	if hint == null:
		return
	if mobile:
		hint.text = tr("按返回键或右上角 ≡ 打开菜单 · 在画面上滑动移动鼠标，点按 = 左键")
	elif game_mouse_enabled():
		hint.text = tr("按 Esc / F12 打开菜单 · Alt+Enter 全屏") + " · " + tr("鼠标已锁定到游戏画面 · 中键或 Ctrl+F10 释放")
	else:
		hint.text = tr("按 Esc / F12 打开菜单 · Alt+Enter 全屏")

## 灵敏度：1.0 时 PC-98 光标与系统光标在屏幕上移动的距离相同（按当前画面缩放换算）
func _mouse_scale() -> float:
	var sens := clampf(float(Store.settings.get("mouse_sens", 1.0)), 0.25, 4.0)
	return sens * _frame_size().x / maxf(screen.size.x, 1.0)

## 累积鼠标移动量（PC-98 像素）；整数部分在下一帧模拟前送给核心，小数部分保留，慢速移动也不会丢失
func add_mouse_motion(d: Vector2) -> void:
	_mouse_acc += d
	mouse_events += 1

## 鼠标按键：按下后至少保持 MIN_BTN_FRAMES 帧再松开，避免很快的单击（同一帧内按下又松开）被 PC-98 漏掉
const MIN_BTN_FRAMES := 3
var _btn_frames := [99, 99]
var _btn_release_pending := [false, false]

func game_mouse_button(b: int, pressed: bool) -> void:
	if emu == null:
		return
	if pressed:
		emu.mouse_button(b, true)
		_btn_frames[b] = 0
		_btn_release_pending[b] = false
	elif _btn_frames[b] >= MIN_BTN_FRAMES:
		emu.mouse_button(b, false)
		_btn_release_pending[b] = false
	else:
		_btn_release_pending[b] = true

func flush_mouse() -> void:
	if emu == null:
		return
	for b in 2:
		_btn_frames[b] += 1
		if _btn_release_pending[b] and _btn_frames[b] >= MIN_BTN_FRAMES:
			emu.mouse_button(b, false)
			_btn_release_pending[b] = false
	if _mouse_acc == Vector2.ZERO:
		return
	var ix := clampf(float(int(_mouse_acc.x)), -127.0, 127.0)
	var iy := clampf(float(int(_mouse_acc.y)), -127.0, 127.0)
	if ix != 0.0 or iy != 0.0:
		emu.mouse_motion(ix, iy)
		_mouse_acc -= Vector2(ix, iy)

## Android 返回键：游戏中打开 / 关闭菜单
func on_back() -> void:
	if paused:
		resume()
	else:
		open_menu()

func toggle_fullscreen() -> void:
	if emu:
		emu.release_all_keys()  # Alt 已按下送给了 PC-98，切换窗口后避免按键卡住
	Store.toggle_fullscreen()
	if not paused:
		grab_focus()
		# 切换窗口模式后重新应用光标锁定（部分系统切换全屏时会丢失锁定）
		if _captured:
			(func(): set_mouse_capture(true)).call_deferred()

func _update_fs_button() -> void:
	if fs_button:
		fs_button.text = tr("⛶ 退出全屏") if Store.is_fullscreen() else tr("⛶ 全屏")

func _fill_view_menu() -> void:
	var p := m_view.get_popup()
	p.clear()
	var mode := str(Store.settings.get("scale_mode", "4:3"))
	var names := [tr("4:3 等比例（CRT 显示器比例，推荐）"), tr("原始比例（640×400，方形像素）"), tr("整数倍放大（像素清晰）")]
	for i in Store.SCALE_MODES.size():
		p.add_radio_check_item(names[i], i)
		p.set_item_checked(i, Store.SCALE_MODES[i] == mode)
	p.add_separator()
	p.add_item(tr("⛶ 退出全屏") if Store.is_fullscreen() else tr("⛶ 全屏"), 10)

func _on_view_menu(id: int) -> void:
	if id == 10:
		toggle_fullscreen()
		return
	Store.settings["scale_mode"] = Store.SCALE_MODES[id]
	Store.save_settings()
	_layout()

func _process(delta: float) -> void:
	if not visible or emu == null or not emu.is_running():
		return
	var fsz := Vector2i(_frame_size())
	if fsz != _last_frame:
		_last_frame = fsz
		_layout()
	if paused or not auto_run:
		return
	var fps: float = emu.get_fps()
	_acc += delta
	var n := 0
	while _acc >= 1.0 / fps and n < 4:
		flush_mouse()
		emu.run_frame()
		if emu.has_crashed():
			return
		_frames_run += 1
		if Store.is_android() and _frames_run % 600 == 0:
			# 安卓 logcat 中可查看模拟进度（每 600 帧一行），便于排查低端设备上的速度问题
			print("PC98: %d frames, %d ms, frame %s, engine fps %d" % [_frames_run, Time.get_ticks_msec(), str(_frame_size()), Engine.get_frames_per_second()])
		_acc -= 1.0 / fps
		n += 1
	if n == 4:
		_acc = 0.0
	if playback:
		emu.fill_audio(playback)

func _input(event: InputEvent) -> void:
	if not visible or emu == null:
		return
	if mobile:
		if event is InputEventScreenTouch or event is InputEventScreenDrag:
			if not paused:
				_touch_input(event)
			return
		# 触屏产生的模拟鼠标事件不送给 PC-98（鼠标由触控板逻辑处理）
		if (event is InputEventMouseButton or event is InputEventMouseMotion) and event.device == InputEvent.DEVICE_ID_EMULATION:
			return
	if event is InputEventKey:
		var k := event as InputEventKey
		var code: int = k.physical_keycode if k.physical_keycode != 0 else k.keycode
		var menu_key := code == KEY_F12 or (code == KEY_ESCAPE and not bool(Store.settings.get("esc_to_pc98", false)))
		if menu_key:
			if k.pressed and not k.echo:
				if paused:
					resume()
				else:
					open_menu()
			get_viewport().set_input_as_handled()
			return
		# Alt+Enter：切换全屏（按下与松开都不送给 PC-98，避免游戏收到 RETURN）
		if (code == KEY_ENTER or code == KEY_KP_ENTER) and k.alt_pressed:
			if k.pressed and not k.echo:
				toggle_fullscreen()
			get_viewport().set_input_as_handled()
			return
		# Ctrl+F10：锁定 / 释放鼠标（不送给 PC-98）
		if code == KEY_F10 and k.ctrl_pressed and not mobile:
			if k.pressed and not k.echo and not paused:
				if game_mouse_enabled():
					set_mouse_capture(not _captured, true)
				else:
					_toast(tr("游戏内鼠标已关闭：可在菜单栏「鼠标」按钮或设置中开启"))
			get_viewport().set_input_as_handled()
			return
		if paused:
			return
		if not k.echo:
			if k.location == KEY_LOCATION_RIGHT:
				code |= 1 << 30
			emu.key_event(code, k.pressed)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and not paused:
		# 桌面版：只有锁定后才把移动送给 PC-98（相对移动量，按画面缩放与灵敏度换算）
		if _captured:
			var mm := event as InputEventMouseMotion
			get_viewport().set_input_as_handled()
			if _skip_motion or Time.get_ticks_msec() - _capture_ms < CAPTURE_SETTLE_MS:
				_skip_motion = false
				return
			mouse_raw_total += mm.relative
			add_mouse_motion(mm.relative * _mouse_scale())
	elif event is InputEventMouseButton and not paused:
		var mb := event as InputEventMouseButton
		if mobile or not game_mouse_enabled():
			return
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			# 中键：锁定 / 释放鼠标（不送给 PC-98；NP2kai 的中键菜单在本程序中不使用）
			if mb.pressed:
				set_mouse_capture(not _captured, true)
			get_viewport().set_input_as_handled()
			return
		if not _captured:
			# 未锁定：在游戏画面上左键单击 = 重新锁定（这一下不送给游戏）
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and screen.get_global_rect().has_point(mb.position):
				set_mouse_capture(true, true)
				get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			game_mouse_button(0, mb.pressed)
			mouse_events += 1
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			game_mouse_button(1, mb.pressed)
			mouse_events += 1
		get_viewport().set_input_as_handled()

# ------------------------------------------------------------------ menus
func _pick(title: String, filters: Array, cb: Callable) -> void:
	_fd_cb = cb
	_fd.title = title
	_fd.filters = I18n.tr_filters(filters)
	_fd.popup_centered()

func _fill_fdd_menu(d: int) -> void:
	var p: PopupMenu = m_fdd[d].get_popup()
	p.clear()
	var cur: String = emu.get_disk(d)
	p.add_item(tr("当前：") + (cur.get_file() if cur != "" else tr("（空）")), 99)
	p.set_item_disabled(0, true)
	p.add_separator()
	p.add_item(tr("插入软盘…"), 0)
	p.add_item(tr("弹出"), 1)
	var set_disks: Array = game.get("disks", [])
	if set_disks.size() > 0:
		# 游戏库文件夹扫描得到的磁盘组：列出全部软盘，点一下即插入本驱动器
		p.add_separator(tr("本游戏的软盘（共 %d 张）") % set_disks.size())
		for i in set_disks.size():
			var dp := str(set_disks[i])
			var label := "%d. %s" % [i + 1, dp.get_file()]
			if dp == cur:
				label = "● " + label
			elif dp == emu.get_disk(1 - d):
				label += "   " + tr("（在 FDD%d 中）") % (2 - d)
			p.add_item(label, 100 + i)
			if not FileAccess.file_exists(dp):
				p.set_item_disabled(p.item_count - 1, true)
	elif d == 0 or d == 1:
		var other := str(game.get("fdd2" if d == 1 else "fdd1", ""))
		if other != "" and other != cur:
			p.add_item(tr("插入游戏的 FDD%d 镜像：%s") % [d + 1, other.get_file()], 2)

func _on_fdd_menu(id: int, d: int) -> void:
	match id:
		0:
			_pick(tr("插入软盘到 FDD%d") % (d + 1), ["*.fdi, *.FDI, *.d88, *.D88, *.hdm, *.HDM, *.88d, *.d98, *.98d, *.xdf, *.dup, *.2hd, *.tfd, *.nfd, *.fdd, *.img ; 软盘镜像", "* ; 所有文件"], func(p):
				emu.insert_disk(d, p)
				_toast(tr("FDD%d 已插入：%s（如需从此盘启动请点击「重置」）") % [d + 1, p.get_file()])
				_update_status())
		1:
			emu.eject_disk(d)
			_toast(tr("FDD%d 已弹出") % (d + 1))
			_update_status()
		2:
			var p := str(game.get("fdd2" if d == 1 else "fdd1", ""))
			emu.insert_disk(d, p)
			_toast(tr("FDD%d 已插入：%s") % [d + 1, p.get_file()])
			_update_status()
		_:
			var set_disks: Array = game.get("disks", [])
			var i := id - 100
			if i >= 0 and i < set_disks.size():
				var p := str(set_disks[i])
				emu.insert_disk(d, p)
				_toast(tr("FDD%d 已插入：%s") % [d + 1, p.get_file()])
				_update_status()

func _fill_hdd_menu() -> void:
	var p := m_hdd.get_popup()
	p.clear()
	for i in 2:
		var cur: String = emu.get_hdd(i)
		p.add_item(tr("HDD%d 当前：%s") % [i + 1, cur.get_file() if cur != "" else tr("（无）")], 90 + i)
		p.set_item_disabled(p.item_count - 1, true)
		p.add_item(tr("挂载 HDD%d…") % (i + 1), i * 2)
		p.add_item(tr("卸载 HDD%d") % (i + 1), i * 2 + 1)
		p.add_separator()
	var set_hdds: Array = game.get("hdds", [])
	if set_hdds.size() > 1:
		p.add_separator(tr("本游戏的硬盘镜像（共 %d 个）") % set_hdds.size())
		for i in set_hdds.size():
			var hp := str(set_hdds[i])
			p.add_item(("● " if hp == emu.get_hdd(0) else "") + tr("挂载到 HDD1：%s") % hp.get_file(), 200 + i)
		p.add_separator()
	p.add_item(tr("（更换硬盘需要重置后生效）"), 98)
	p.set_item_disabled(p.item_count - 1, true)

func _on_hdd_menu(id: int) -> void:
	if id >= 200:
		var set_hdds: Array = game.get("hdds", [])
		var i := id - 200
		if i < set_hdds.size():
			emu.mount_hdd(0, str(set_hdds[i]))
			_toast(tr("HDD%d 已挂载：%s —— 请点击「重置」使其生效") % [1, str(set_hdds[i]).get_file()])
			_update_status()
		return
	var idx := id / 2
	if id % 2 == 0:
		_pick(tr("挂载硬盘镜像到 HDD%d") % (idx + 1), ["*.hdi, *.HDI, *.nhd, *.thd, *.vhd, *.slh, *.hdn ; 硬盘镜像", "* ; 所有文件"], func(p):
			emu.mount_hdd(idx, p)
			_toast(tr("HDD%d 已挂载：%s —— 请点击「重置」使其生效") % [idx + 1, p.get_file()])
			_update_status())
	else:
		emu.mount_hdd(idx, "")
		_toast(tr("HDD%d 已卸载 —— 请点击「重置」使其生效") % (idx + 1))
		_update_status()

func _fill_font_menu() -> void:
	var p := m_font.get_popup()
	p.clear()
	var mode := str(Store.settings.get("font_mode", "auto"))
	p.add_radio_check_item(tr("BIOS 文件夹中的字体 ROM"), 0)
	p.set_item_checked(0, mode == "auto")
	p.add_radio_check_item(tr("指定字体文件：") + (str(Store.settings.get("font_file", "")).get_file() if str(Store.settings.get("font_file", "")) != "" else tr("（未选择）")), 1)
	p.set_item_checked(1, mode == "file")
	p.add_radio_check_item(tr("系统字体：") + str(Store.settings.get("ttf_file", "")).get_file(), 2)
	p.set_item_checked(2, mode == "ttf")
	p.add_separator()
	p.add_item(tr("选择字体文件（FONT.ROM / font.bmp）…"), 3)
	p.add_item(tr("选择系统字体（TTF / TTC）…"), 4)

func _on_font_menu(id: int) -> void:
	match id:
		0:
			_switch_font("auto")
		1:
			if str(Store.settings.get("font_file", "")) == "":
				_on_font_menu(3)
			else:
				_switch_font("file")
		2:
			_switch_font("ttf")
		3:
			_pick(tr("选择字体文件"), ["*.rom, *.ROM, *.bmp, *.BMP, *.bin ; 字体 ROM / 位图", "* ; 所有文件"], func(p):
				Store.settings["font_file"] = p
				_switch_font("file"))
		4:
			_pick(tr("选择系统字体"), ["*.ttf, *.ttc, *.otf, *.TTF, *.TTC, *.OTF ; 字体", "* ; 所有文件"], func(p):
				Store.settings["ttf_file"] = p
				_switch_font("ttf"))

func _switch_font(mode: String) -> void:
	Store.settings["font_mode"] = mode
	Store.save_settings()
	var canonical := Store.prepare_fonts()
	emu.set_ttf_font(str(Store.settings.get("ttf_file", "")), int(Store.settings.get("ttf_index", 0)))
	emu.reload_font(canonical)
	var names := {"auto": tr("BIOS 文件夹字体"), "file": tr("指定字体文件"), "ttf": tr("系统字体")}
	_toast(tr("字体已切换为：%s（画面将在重绘后更新，必要时请重置）") % names[mode])

func _update_status() -> void:
	if emu == null:
		return
	var parts := []
	for d in 2:
		var p: String = emu.get_disk(d)
		parts.append("FDD%d: %s" % [d + 1, p.get_file() if p != "" else "—"])
	var h: String = emu.get_hdd(0)
	parts.append("HDD1: %s" % (h.get_file() if h != "" else "—"))
	if mobile:
		status.text = tr("%s    |    %s    |    返回键 = 菜单") % [str(game.get("title", "")), "    ".join(parts)]
	else:
		var fmt := "%s    |    %s    |    Esc/F12 菜单 · Alt+Enter 全屏"
		if game_mouse_enabled():
			fmt = "%s    |    %s    |    Esc/F12 菜单 · Alt+Enter 全屏 · 中键/Ctrl+F10 锁定/释放鼠标"
		status.text = tr(fmt) % [str(game.get("title", "")), "    ".join(parts)]

func _toast(msg: String) -> void:
	var p := get_parent()
	if p and p.has_method("toast"):
		p.toast(msg)

# ------------------------------------------------------------------ 触屏控制（移动端）
const VKBD_ROWS := [
	[["ESC", KEY_ESCAPE, 1.25], ["F1", KEY_F1], ["F2", KEY_F2], ["F3", KEY_F3], ["F4", KEY_F4], ["F5", KEY_F5],
		["F6", KEY_F6], ["F7", KEY_F7], ["F8", KEY_F8], ["F9", KEY_F9], ["F10", KEY_F10], ["BS", KEY_BACKSPACE, 1.25]],
	[["1", KEY_1], ["2", KEY_2], ["3", KEY_3], ["4", KEY_4], ["5", KEY_5], ["6", KEY_6], ["7", KEY_7], ["8", KEY_8],
		["9", KEY_9], ["0", KEY_0], ["-", KEY_MINUS], ["^", KEY_EQUAL], ["DEL", KEY_DELETE, 1.0]],
	[["TAB", KEY_TAB, 1.5], ["Q", KEY_Q], ["W", KEY_W], ["E", KEY_E], ["R", KEY_R], ["T", KEY_T], ["Y", KEY_Y],
		["U", KEY_U], ["I", KEY_I], ["O", KEY_O], ["P", KEY_P], ["@", KEY_BRACKETLEFT], ["RETURN", KEY_ENTER, 1.5]],
	[["CTRL", KEY_CTRL, 1.75, "mod"], ["A", KEY_A], ["S", KEY_S], ["D", KEY_D], ["F", KEY_F], ["G", KEY_G], ["H", KEY_H],
		["J", KEY_J], ["K", KEY_K], ["L", KEY_L], [";", KEY_SEMICOLON], [":", KEY_APOSTROPHE], ["↑", KEY_UP, 1.25]],
	[["SHIFT", KEY_SHIFT, 2.25, "mod"], ["Z", KEY_Z], ["X", KEY_X], ["C", KEY_C], ["V", KEY_V], ["B", KEY_B], ["N", KEY_N],
		["M", KEY_M], [",", KEY_COMMA], [".", KEY_PERIOD], ["/", KEY_SLASH], ["←", KEY_LEFT], ["↓", KEY_DOWN], ["→", KEY_RIGHT]],
	[["GRPH", KEY_ALT, 1.5, "mod"], ["HOME", KEY_HOME, 1.5], ["SPACE", KEY_SPACE, 6.0], ["ROLL↑", KEY_PAGEUP, 1.5],
		["ROLL↓", KEY_PAGEDOWN, 1.5], ["收起", 0, 1.5, "hide"]],
]

func _make_key(parent: Control, label: String, code: int, kind := "key", font := 18) -> Dictionary:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.text = label
	l.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_ALWAYS if kind in ["hide", "kbd", "menu"] else Node.AUTO_TRANSLATE_MODE_DISABLED
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	l.clip_text = true
	p.add_child(l)
	parent.add_child(p)
	var k := {"node": p, "code": code, "kind": kind, "down": 0}
	_keys.append(k)
	_style_key(k)
	return k

func _style_key(k: Dictionary) -> void:
	var on: bool = int(k["down"]) > 0 or _latched.has(k["code"])
	var c := Color(0.10, 0.62, 1.0, 0.85) if on else Color(0.16, 0.18, 0.22, 0.62)
	if k["node"].get_parent() == vkbd:
		c = Color(0.10, 0.62, 1.0, 0.95) if on else Color(0.20, 0.23, 0.28, 0.96)
	k["node"].add_theme_stylebox_override("panel", UITheme.box(c, 8, 0, Color(1, 1, 1, 0.18), 1))

func _build_touch() -> void:
	touch_layer = Control.new()
	touch_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	touch_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(touch_layer)
	pad_group = Control.new()
	pad_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad_group.set_anchors_preset(Control.PRESET_FULL_RECT)
	touch_layer.add_child(pad_group)
	for d in [["↑", KEY_UP], ["←", KEY_LEFT], ["→", KEY_RIGHT], ["↓", KEY_DOWN]]:
		_make_key(pad_group, d[0], d[1], "key", 26)["slot"] = "pad"
	for b in [["ESC", KEY_ESCAPE], ["SPACE", KEY_SPACE], ["RETURN", KEY_ENTER]]:
		_make_key(pad_group, b[0], b[1], "key", 17)["slot"] = "act"
	_make_key(touch_layer, "键盘", 0, "kbd", 16)["slot"] = "tool"
	_make_key(touch_layer, "≡", 0, "menu", 26)["slot"] = "tool"
	vkbd = Control.new()
	vkbd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	touch_layer.add_child(vkbd)
	var bgk := ColorRect.new()
	bgk.color = Color("#0c0e12f2")
	bgk.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bgk.set_anchors_preset(Control.PRESET_FULL_RECT)
	vkbd.add_child(bgk)
	for ri in VKBD_ROWS.size():
		for e in VKBD_ROWS[ri]:
			var kind: String = e[3] if e.size() > 3 else "key"
			var k := _make_key(vkbd, e[0], e[1], kind, 15)
			k["slot"] = "vkbd"
			k["row"] = ri
			k["w"] = float(e[2]) if e.size() > 2 else 1.0
	vkbd.visible = false

func set_vkbd_visible(on: bool) -> void:
	if vkbd == null:
		return
	_release_touch_keys()
	vkbd_visible = on
	_refresh_touch()
	_layout()

func _refresh_touch() -> void:
	if touch_layer == null:
		return
	var running: bool = emu != null and emu.is_running()
	touch_layer.visible = (not paused) and (running or vkbd_visible or not auto_run)
	vkbd.visible = vkbd_visible
	pad_group.visible = bool(Store.settings.get("touch_pad", true)) and not vkbd_visible
	_layout()

## 摆放触屏控件，返回留给画面的区域
func _layout_touch() -> Rect2:
	var area := Rect2(Vector2.ZERO, size)
	if touch_layer == null:
		return area
	var u := KEY_UNIT
	var m := 14.0
	var portrait := size.y > size.x
	var tools := []
	for k in _keys:
		if k.get("slot") == "tool":
			tools.append(k)
	# 右上角：键盘 / 菜单
	var tx := size.x - m
	for i in range(tools.size() - 1, -1, -1):
		var w := 72.0 if tools[i]["kind"] == "kbd" else 56.0
		tx -= w
		tools[i]["node"].position = Vector2(tx, m)
		tools[i]["node"].size = Vector2(w, 52)
		tx -= 8
	if vkbd_visible:
		var rows := VKBD_ROWS.size()
		var kh := clampf(size.y * (0.42 if not portrait else 0.36) / rows, 38.0, 58.0)
		var kb_h := kh * rows + 10
		vkbd.position = Vector2(0, size.y - kb_h)
		vkbd.size = Vector2(size.x, kb_h)
		var max_units := 0.0
		for row in VKBD_ROWS:
			var us := 0.0
			for e in row:
				us += float(e[2]) if e.size() > 2 else 1.0
			max_units = maxf(max_units, us)
		var kw := (size.x - 12) / max_units
		var x_by_row := {}
		for k in _keys:
			if k.get("slot") != "vkbd":
				continue
			var r: int = k["row"]
			var x: float = x_by_row.get(r, 6.0)
			k["node"].position = Vector2(x + 2, 6 + r * kh + 2)
			k["node"].size = Vector2(kw * k["w"] - 4, kh - 4)
			x_by_row[r] = x + kw * k["w"]
		area = Rect2(0, 76 if portrait else 0, size.x, size.y - kb_h - (76 if portrait else 0))
		return area
	# 方向键（左下）与 动作键（右下）
	var base := Vector2(m, size.y - m - u * 3)
	var cells := {KEY_UP: Vector2(1, 0), KEY_LEFT: Vector2(0, 1), KEY_RIGHT: Vector2(2, 1), KEY_DOWN: Vector2(1, 2)}
	for k in _keys:
		if k.get("slot") == "pad":
			k["node"].position = base + cells[k["code"]] * u + Vector2(3, 3)
			k["node"].size = Vector2(u - 6, u - 6)
	var ax := size.x - m
	var acts := {KEY_ENTER: Rect2(-u * 2.2, -u * 1.05, u * 2.2, u * 1.05), KEY_SPACE: Rect2(-u * 2.2, -u * 2.2, u * 2.2, u * 1.0),
		KEY_ESCAPE: Rect2(-u * 2.2, -u * 3.3, u * 1.3, u * 0.95)}
	for k in _keys:
		if k.get("slot") == "act":
			var rr: Rect2 = acts[k["code"]]
			k["node"].position = Vector2(ax, size.y - m) + rr.position
			k["node"].size = rr.size - Vector2(0, 6)
	if portrait and pad_group.visible:
		# 竖屏：画面放在上方，按键在下方
		area = Rect2(0, 76, size.x, size.y - 76 - u * 3 - m * 2)
	return area

func _key_at(pos: Vector2) -> Dictionary:
	if touch_layer == null or not touch_layer.visible:
		return {}
	for i in range(_keys.size() - 1, -1, -1):
		var k: Dictionary = _keys[i]
		var n: Control = k["node"]
		if not n.is_visible_in_tree():
			continue
		if Rect2(n.global_position, n.size).grow(4).has_point(pos):
			return k
	if vkbd_visible and Rect2(vkbd.global_position, vkbd.size).has_point(pos):
		return {"kind": "none"}
	return {}

func _key_down(k: Dictionary) -> void:
	match str(k["kind"]):
		"menu":
			open_menu()
			return
		"kbd":
			set_vkbd_visible(not vkbd_visible)
			return
		"hide":
			set_vkbd_visible(false)
			return
		"none":
			return
		"mod":
			var c: int = k["code"]
			if _latched.has(c):
				_latched.erase(c)
				emu.key_event(c, false)
			else:
				_latched[c] = true
				emu.key_event(c, true)
			_restyle_mods()
			return
	k["down"] = int(k["down"]) + 1
	if int(k["down"]) == 1:
		emu.key_event(int(k["code"]), true)
	_style_key(k)

func _key_up(k: Dictionary) -> void:
	if str(k["kind"]) != "key":
		return
	k["down"] = maxi(int(k["down"]) - 1, 0)
	if int(k["down"]) == 0:
		emu.key_event(int(k["code"]), false)
		# 锁定的 SHIFT / CTRL / GRPH 只作用于下一个按键
		if not _latched.is_empty() and k.get("slot") == "vkbd":
			for c in _latched.keys():
				emu.key_event(int(c), false)
			_latched.clear()
			_restyle_mods()
	_style_key(k)

func _restyle_mods() -> void:
	for k in _keys:
		if k["kind"] == "mod":
			_style_key(k)

func _release_touch_keys() -> void:
	for k in _keys:
		if int(k.get("down", 0)) > 0:
			k["down"] = 0
			if emu:
				emu.key_event(int(k["code"]), false)
			_style_key(k)
	if emu:
		for c in _latched.keys():
			emu.key_event(int(c), false)
	_latched.clear()
	_restyle_mods()
	_touch_map.clear()
	_mt = -1

func _touch_input(event: InputEvent) -> void:
	get_viewport().set_input_as_handled()
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			var k := _key_at(t.position)
			if not k.is_empty():
				_touch_map[t.index] = k
				_key_down(k)
				return
			# 画面区域：触控板式鼠标
			if not bool(Store.settings.get("touch_mouse", true)):
				return
			if _mt == -1:
				_mt = t.index
				_mt_start = t.position
				_mt_time = Time.get_ticks_msec()
				_mt_moved = 0.0
				_mt_two = false
			else:
				_mt_two = true
		else:
			if _touch_map.has(t.index):
				_key_up(_touch_map[t.index])
				_touch_map.erase(t.index)
				return
			if t.index == _mt:
				var quick := Time.get_ticks_msec() - _mt_time < 280 and _mt_moved < 14.0
				if quick:
					_click(1 if _mt_two else 0)
				_mt = -1
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if d.index == _mt and not _mt_two:
			_mt_moved += d.relative.length()
			# 画面上的 1 像素滑动 ≈ PC-98 的 1.5 像素（按画面缩放与灵敏度换算，小数部分累积到下一帧）
			add_mouse_motion(d.relative * 1.5 * _mouse_scale())

func _click(btn: int) -> void:
	emu.mouse_button(btn, true)
	get_tree().create_timer(0.08).timeout.connect(func():
		if emu:
			emu.mouse_button(btn, false))
