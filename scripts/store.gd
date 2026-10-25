extends Node
## 数据存储：游戏库与设置（<数据目录>/library.json、settings.json）
##
## 便携模式（桌面版 Windows / Linux）：所有数据保存在程序旁边的 data 文件夹，
## 整个文件夹复制到别的电脑即可带走设置、游戏库、导入的 BIOS 等。
## 程序目录不可写（如装在 Program Files）、在编辑器中运行、安卓版、或带 --no-portable 参数时
## 使用系统用户数据目录 user://（Windows: %APPDATA%/PC98GameHall，Linux: ~/.local/share/PC98GameHall）。

const PORTABLE_DIR_NAME := "data"
const APP_MARK := "<APP>/"   # 保存到 json 时，程序文件夹内的路径写成相对形式，换电脑 / 换盘符也能用
const LIB_MARK := "<LIB>/"   # 游戏库文件夹内的路径写成相对于游戏库文件夹的形式（换盘符 / 移动游戏库后重新选择文件夹即可）
const LibraryScan := preload("res://scripts/library_scan.gd")
const FONT_FILE_NAMES := ["font.bmp", "font.rom", "font.tmp", "fontrom.bin"]

var portable := false
var app_dir := ""        # 程序所在文件夹（便携模式下）
var _data_dir := ""      # 数据目录绝对路径，不带结尾 /
var _just_migrated := false

## 数据目录（绝对路径）。所有设置、游戏库、BIOS 副本、内核系统目录都在这里面。
func data_dir() -> String:
	if _data_dir == "":
		_init_data_dir()
	return _data_dir

func data_path(rel: String) -> String:
	return data_dir() + "/" + rel

func _init_data_dir() -> void:
	var user_dir := ProjectSettings.globalize_path("user://").trim_suffix("/")
	_data_dir = user_dir
	portable = false
	if OS.has_feature("mobile") or OS.has_feature("editor") or "--no-portable" in OS.get_cmdline_user_args():
		print("[data] mode=user dir=", _data_dir)
		return
	var exe_dir := OS.get_executable_path().get_base_dir().replace("\\", "/")
	var d := exe_dir + "/" + PORTABLE_DIR_NAME
	var ok := DirAccess.make_dir_recursive_absolute(d) == OK
	if ok:
		var probe := d + "/.write_test"
		var f := FileAccess.open(probe, FileAccess.WRITE)
		ok = f != null
		if f:
			f.close()
			DirAccess.remove_absolute(probe)
	if not ok:
		print("[data] exe folder not writable (", exe_dir, "), mode=user dir=", _data_dir)
		return
	portable = true
	app_dir = exe_dir
	_data_dir = d
	print("[data] mode=portable dir=", _data_dir)
	_migrate_from_user_dir(user_dir)

## 第一次使用便携模式时，把以前保存在系统用户目录里的设置 / 游戏库 / 导入的文件复制过来（只做一次）
func _migrate_from_user_dir(user_dir: String) -> void:
	if FileAccess.file_exists(data_path("settings.json")) or FileAccess.file_exists(data_path("library.json")) \
			or FileAccess.file_exists(data_path(".migrated")):
		return
	var marker := FileAccess.open(data_path(".migrated"), FileAccess.WRITE)
	if marker:
		marker.store_string("from " + user_dir + "\n")
		marker.close()
	if not (FileAccess.file_exists(user_dir + "/settings.json") or FileAccess.file_exists(user_dir + "/library.json")):
		return
	var n := 0
	for e in DirAccess.get_files_at(user_dir):
		if e.ends_with(".json"):
			var txt := FileAccess.get_file_as_string(user_dir + "/" + e)
			# 旧路径（系统用户目录）→ 新的便携数据目录
			txt = txt.replace(user_dir + "/", _data_dir + "/")
			var f := FileAccess.open(data_path(e), FileAccess.WRITE)
			if f:
				f.store_string(txt)
				f.close()
				n += 1
	for sub in ["bios", "games", "imported", "PC98", "system"]:
		if DirAccess.dir_exists_absolute(user_dir + "/" + sub):
			n += _copy_tree(user_dir + "/" + sub, data_path(sub))
	print("[data] migrated ", n, " file(s) from ", user_dir)
	_just_migrated = true

static func _copy_tree(src: String, dst: String) -> int:
	DirAccess.make_dir_recursive_absolute(dst)
	var n := 0
	for f in DirAccess.get_files_at(src):
		if DirAccess.copy_absolute(src + "/" + f, dst + "/" + f) == OK:
			n += 1
	for sd in DirAccess.get_directories_at(src):
		n += _copy_tree(src + "/" + sd, dst + "/" + sd)
	return n

## 保存时：程序文件夹里的绝对路径 → "<APP>/相对路径"；读取时反过来
func _pack_paths(v, lib := ""):
	if not portable and lib == "":
		return v
	if v is Dictionary:
		var o := {}
		for k in v.keys():
			o[k] = _pack_paths(v[k], lib)
		return o
	if v is Array:
		var a := []
		for x in v:
			a.append(_pack_paths(x, lib))
		return a
	if v is String:
		var norm: String = v.replace("\\", "/")
		if lib != "" and _path_under(norm, lib):
			return LIB_MARK + norm.substr(lib.length() + 1)
		if portable and _path_under(norm, app_dir):
			return APP_MARK + norm.substr(app_dir.length() + 1)
	return v

static func _path_under(p: String, dir: String) -> bool:
	var pre := dir.trim_suffix("/") + "/"
	return p.to_lower().begins_with(pre.to_lower()) if OS.get_name() == "Windows" else p.begins_with(pre)

func _unpack_paths(v):
	if v is Dictionary:
		for k in v.keys():
			v[k] = _unpack_paths(v[k])
		return v
	if v is Array:
		for i in v.size():
			v[i] = _unpack_paths(v[i])
		return v
	if v is String and v.begins_with(APP_MARK):
		var base := app_dir if portable else OS.get_executable_path().get_base_dir()
		return base + "/" + v.substr(APP_MARK.length())
	if v is String and v.begins_with(LIB_MARK):
		return library_root() + "/" + v.substr(LIB_MARK.length())
	return v

var games: Array = []
var settings: Dictionary = {}

signal library_changed
signal settings_changed
signal fullscreen_changed(on: bool)

## 画面缩放模式：4:3 等比例 / 原始比例（方形像素）/ 整数倍
const SCALE_MODES := ["4:3", "native", "integer"]

func _ready() -> void:
	data_dir()
	load_all()
	if _just_migrated:   # 迁移来的路径重新保存为相对形式
		_write_json(data_path("settings.json"), settings)
		_write_json(data_path("library.json"), {"version": 1, "games": games}, library_root())
	I18n.apply_locale(get_language())
	if is_android():
		# 首次启动就创建外部导入文件夹，用户用 USB / 文件管理器拷贝文件时能直接找到
		DirAccess.make_dir_recursive_absolute(external_import_dir() + "/BIOS")

# ---------------------------------------------------------------- language
func get_language() -> String:
	var l := str(settings.get("language", I18n.DEFAULT_LOCALE))
	return l if l in I18n.LOCALES else I18n.DEFAULT_LOCALE

func set_language(locale: String) -> void:
	if not locale in I18n.LOCALES:
		locale = I18n.DEFAULT_LOCALE
	settings["language"] = locale
	I18n.apply_locale(locale)
	save_settings()

# ---------------------------------------------------------------- fullscreen (Alt+Enter / 标题栏最大化)
## 桌面版：标题栏「最大化」按钮（或双击标题栏）= Alt+Enter，进入等比例黑边全屏。
## 记住最大化之前的窗口位置/大小，退出全屏时回到普通窗口（不是最大化状态）。
var _win_rect := Rect2i()          # 最近一次普通窗口状态下的位置+大小
var _max_watch_cooldown := 0.0     # 刚退出全屏时短暂忽略「最大化」，防止来回切换
var _restore_rect := Rect2i()      # 退出全屏后要恢复的窗口位置/大小
var _restore_frames := 0

func is_fullscreen() -> bool:
	var m := get_window().mode
	return m == Window.MODE_FULLSCREEN or m == Window.MODE_EXCLUSIVE_FULLSCREEN

func set_fullscreen(on: bool) -> void:
	var w := get_window()
	if on == is_fullscreen():
		return
	if not on and _win_rect.size.x > 0 and not is_mobile():
		_restore_rect = _win_rect
		_restore_frames = 3
	w.mode = Window.MODE_FULLSCREEN if on else Window.MODE_WINDOWED
	if not on:
		_max_watch_cooldown = 0.5
	settings["fullscreen"] = on
	save_settings()
	fullscreen_changed.emit(on)

func _process(delta: float) -> void:
	if is_mobile():
		return
	var w := get_window()
	var m := w.mode
	if _max_watch_cooldown > 0.0:
		_max_watch_cooldown -= delta
	if _restore_frames > 0:
		# 退出全屏后连续几帧把窗口放回原位（部分窗口管理器会异步改回去）
		_restore_frames -= 1
		if m == Window.MODE_MAXIMIZED:
			w.mode = Window.MODE_WINDOWED
		elif m == Window.MODE_WINDOWED:
			if w.size != _restore_rect.size:
				w.size = _restore_rect.size
			if w.position != _restore_rect.position:
				w.position = _restore_rect.position
		return
	if m == Window.MODE_WINDOWED:
		_win_rect = Rect2i(w.position, w.size)
	elif m == Window.MODE_MAXIMIZED and _max_watch_cooldown <= 0.0:
		# 标题栏最大化 → 与 Alt+Enter 共用同一个全屏开关（贴靠左右半屏不是 MAXIMIZED，不会触发）
		set_fullscreen(true)

func toggle_fullscreen() -> void:
	set_fullscreen(not is_fullscreen())

## 找一个含日文假名/汉字的系统字体（没有 FONT.ROM / font.bmp 时用它生成 PC-98 字库）
static func find_system_cjk_font() -> String:
	var cands: Array[String] = []
	if OS.get_name() == "Windows":
		var windir := OS.get_environment("WINDIR")
		if windir == "":
			windir = "C:/Windows"
		var fd := windir.replace("\\", "/") + "/Fonts/"
		var local := OS.get_environment("LOCALAPPDATA").replace("\\", "/") + "/Microsoft/Windows/Fonts/"
		for n in ["msgothic.ttc", "YuGothR.ttc", "YuGothM.ttc", "meiryo.ttc", "msmincho.ttc", "NotoSansCJK-Regular.ttc", "msyh.ttc", "simsun.ttc", "simhei.ttf", "mingliub.ttc", "malgun.ttf"]:
			cands.append(fd + n)
			cands.append(local + n)
	elif OS.get_name() == "Android":
		cands = ["/system/fonts/NotoSansCJK-Regular.ttc", "/system/fonts/NotoSerifCJK-Regular.ttc",
			"/system/fonts/DroidSansJapanese.ttf", "/system/fonts/DroidSansFallbackFull.ttf", "/system/fonts/DroidSansFallback.ttf"]
	else:
		cands = ["/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
			"/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc", "/usr/share/fonts/google-noto-sans-cjk-fonts/NotoSansCJK-Regular.ttc",
			"/usr/share/fonts/google-noto-sans-cjk-vf-fonts/NotoSansCJK-VF.ttc", "/usr/share/fonts/noto-cjk/NotoSansCJKjp-Regular.otf",
			"/usr/share/fonts/opentype/ipafont-gothic/ipag.ttf", "/usr/share/fonts/truetype/fonts-japanese-gothic.ttf",
			"/usr/share/fonts/truetype/vlgothic/VL-Gothic-Regular.ttf", "/usr/share/fonts/vl-gothic/VL-Gothic-Regular.ttf",
			"/usr/share/fonts/truetype/takao-gothic/TakaoGothic.ttf", "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
			"/usr/share/fonts/truetype/wqy/wqy-microhei.ttc", "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
			"/usr/share/fonts/wenquanyi/wqy-zenhei/wqy-zenhei.ttc", "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"]
	for p in cands:
		if FileAccess.file_exists(p):
			return p
	if OS.get_name() == "Linux" or OS.get_name() == "FreeBSD":
		# 最后尝试 fontconfig：任意支持日文的 TrueType / OpenType 字体（找不到时返回空 = 汉字显示为空白，但不会崩溃）
		var out := []
		if OS.execute("fc-list", [":lang=ja", "file"], out) == 0 and out.size() > 0:
			for line: String in str(out[0]).split("\n", false):
				var fp := line.strip_edges().trim_suffix(":").strip_edges()
				var ext := fp.get_extension().to_lower()
				if ext in ["ttf", "ttc", "otf"] and FileAccess.file_exists(fp):
					return fp
	return ""

func default_settings() -> Dictionary:
	var ttf := find_system_cjk_font()
	return {
		"bios_dir": bios_import_dir() if is_android() else "",
		"font_mode": "auto",      # auto / file / ttf
		"font_file": "",
		"ttf_file": ttf,
		"ttf_index": 0,
		"keyboard": "Us",
		"model": "PC-9801VX",
		"esc_to_pc98": false,
		"fullscreen": false,
		"language": I18n.DEFAULT_LOCALE,   # 默认 en；可选 zh_CN / zh_TW / en / ja（用户切换后会记住）
		"scale_mode": "4:3",      # 4:3 / native / integer
		"touch_pad": true,        # 移动端：显示触屏方向键 / 按钮
		"touch_mouse": true,      # 移动端：在画面上滑动 = 移动鼠标，点按 = 左键
		"game_mouse": true,       # 桌面版：游戏内鼠标（PC-98 总线鼠标），游戏中锁定系统光标
		"mouse_sens": 1.0,        # 鼠标灵敏度（0.25–4，1.0 = 与系统光标移动距离相同）
		"library_root": "",       # 游戏库文件夹（递归扫描；安卓为空时使用导入文件夹）
		"library_autoscan": true, # 启动时自动扫描游戏库文件夹
	}

func load_all() -> void:
	settings = default_settings()
	var s = _read_json(data_path("settings.json"))
	if s is Dictionary:
		for k in s.keys():
			settings[k] = s[k]
	# the configured system font may not exist on this PC (e.g. no Japanese font pack): pick another
	var tf := str(settings.get("ttf_file", ""))
	if tf == "" or not FileAccess.file_exists(tf):
		settings["ttf_file"] = find_system_cjk_font()
	var l = _read_json(data_path("library.json"))
	games = []
	if l is Dictionary and l.has("games") and l["games"] is Array:
		games = l["games"]

func save_settings() -> void:
	_write_json(data_path("settings.json"), settings)
	settings_changed.emit()

func save_library() -> void:
	_write_json(data_path("library.json"), {"version": 1, "games": games}, library_root())
	library_changed.emit()

func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return _unpack_paths(JSON.parse_string(f.get_as_text()))

func _write_json(path: String, data, lib := "") -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_pack_paths(data, lib), "\t"))

# ---------------------------------------------------------------- games
func add_game(title: String, fdd1: String, fdd2: String, hdd1: String, cover: String) -> Dictionary:
	var g := {
		"id": "%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000],
		"title": title,
		"fdd1": fdd1, "fdd2": fdd2, "hdd1": hdd1,
		"cover": cover,
		"added": Time.get_unix_time_from_system(),
		"last_played": 0,
		"play_count": 0,
		"play_seconds": 0,
	}
	games.append(g)
	save_library()
	return g

func update_game(g: Dictionary) -> void:
	for i in games.size():
		if games[i]["id"] == g["id"]:
			games[i] = g
	save_library()

func remove_game(id: String) -> void:
	for i in range(games.size() - 1, -1, -1):
		if games[i]["id"] == id:
			games.remove_at(i)
	save_library()

func get_game(id: String) -> Dictionary:
	for g in games:
		if g["id"] == id:
			return g
	return {}

func recent_games() -> Array:
	var r := games.filter(func(g): return float(g.get("last_played", 0)) > 0)
	r.sort_custom(func(a, b): return float(a["last_played"]) > float(b["last_played"]))
	return r

static func media_kind(g: Dictionary) -> String:
	if str(g.get("hdd1", "")) != "":
		var nh: int = (g.get("hdds", []) as Array).size()
		var nf: int = (g.get("disks", []) as Array).size()
		var t := TranslationServer.translate("HDI 硬盘")
		if nh > 1:
			t += " ×%d" % nh
		if nf > 0:
			t += " + " + TranslationServer.translate("%d 张软盘") % nf
		return t
	var n: int = (g.get("disks", []) as Array).size()
	if n > 1:
		return TranslationServer.translate("%d 张软盘") % n
	return TranslationServer.translate("FDI 软盘")

## 游戏的主镜像（用于判断文件是否缺失）
static func primary_path(g: Dictionary) -> String:
	var h := str(g.get("hdd1", ""))
	return h if h != "" else str(g.get("fdd1", ""))

static func is_missing(g: Dictionary) -> bool:
	var p := primary_path(g)
	return p == "" or not FileAccess.file_exists(p)

## 游戏库中可见的游戏（不含已隐藏的扫描条目）
func visible_games() -> Array:
	return games.filter(func(g): return not bool(g.get("hidden", false)))

func hidden_count() -> int:
	return games.size() - visible_games().size()

func unhide_all() -> int:
	var n := 0
	for g in games:
		if bool(g.get("hidden", false)):
			g["hidden"] = false
			n += 1
	if n > 0:
		save_library()
	return n

## 从游戏库移除：手动添加的直接删除；扫描得到的标记为隐藏（重新扫描也不会再出现）
func remove_or_hide(id: String) -> void:
	var g := get_game(id)
	if g.is_empty():
		return
	if str(g.get("source", "")) == "scan":
		g["hidden"] = true
		save_library()
	else:
		remove_game(id)

## 分类列表：[[分类名, 数量], ...]（"" = 未分类）
func categories() -> Array:
	var cnt := {}
	for g in visible_games():
		var c := str(g.get("category", ""))
		cnt[c] = int(cnt.get(c, 0)) + 1
	var keys := cnt.keys()
	keys.sort_custom(func(a, b):
		if a == "" or b == "":
			return a != "" and b == ""
		return str(a).naturalnocasecmp_to(str(b)) < 0)
	var out := []
	for k in keys:
		out.append([k, cnt[k]])
	return out

# ---------------------------------------------------------------- 游戏库文件夹（递归扫描）
signal scan_progress(dirs: int, found: int)
signal scan_finished(result: Dictionary)

var _scan_thread: Thread
var _scanner = null
var scan_running := false

## 游戏库文件夹；安卓上未设置时使用导入文件夹
func library_root() -> String:
	var r := str(settings.get("library_root", "")).replace("\\", "/").trim_suffix("/")
	if r == "" and is_android():
		r = external_import_dir()
	return r

func set_library_root(p: String) -> void:
	p = p.strip_edges().replace("\\", "/").trim_suffix("/")
	settings["library_root"] = p
	save_settings()
	save_library()   # 重新写出相对路径

## 在后台线程扫描游戏库文件夹；完成后在主线程合并结果并发出 scan_finished
func start_library_scan() -> bool:
	if scan_running:
		return false
	var root := library_root()
	if root == "" or not DirAccess.dir_exists_absolute(root):
		scan_finished.emit({"error": "no_root", "root": root})
		return false
	scan_running = true
	_scanner = LibraryScan.new(root, func(d, f): scan_progress.emit(d, f))
	_scan_thread = Thread.new()
	_scan_thread.start(_scan_worker.bind(_scanner))
	print("[scan] started root=", root)
	return true

func _scan_worker(sc) -> void:
	var r: Dictionary = sc.run()
	_scan_done.call_deferred(r)

func cancel_library_scan() -> void:
	if _scanner:
		_scanner.cancel = true

func _scan_done(r: Dictionary) -> void:
	if _scan_thread:
		_scan_thread.wait_to_finish()
	_scan_thread = null
	_scanner = null
	scan_running = false
	var t0 := Time.get_ticks_msec()
	var m := merge_scan(r["entries"], library_root())
	r.merge(m, true)
	r["merge_msec"] = Time.get_ticks_msec() - t0
	r.erase("entries")
	print("[scan] done: dirs=%d files=%d games=%d added=%d updated=%d missing=%d removed=%d scan=%dms merge=%dms errors=%d" % [
		r["dirs"], r["files"], r["found"], r["added"], r["updated"], r["missing"], r["removed"], r["msec"], r["merge_msec"], r["errors"].size()])
	scan_finished.emit(r)

## 合并扫描结果：按路径去重；已有条目保留游玩记录 / 改过的名称 / 封面 / 隐藏状态
func merge_scan(entries: Array, root: String) -> Dictionary:
	var by_key := {}
	var used_paths := {}
	for g in games:
		if str(g.get("source", "")) == "scan":
			by_key[_norm_key(str(g.get("scan_key", "")))] = g
		else:
			for k in ["fdd1", "fdd2", "hdd1"]:
				var p := str(g.get(k, ""))
				if p != "":
					used_paths[_norm_key(p)] = true
	var seen := {}
	var res := {"found": entries.size(), "added": 0, "updated": 0, "missing": 0, "removed": 0}
	var now := Time.get_unix_time_from_system()
	var n := 0
	for e in entries:
		var key := _norm_key(str(e["key"]))
		seen[key] = true
		var disks: Array = e["disks"]
		var hdds: Array = e["hdds"]
		var g: Dictionary = by_key.get(key, {})
		if g.is_empty():
			# 手动添加过同一个镜像：不重复加入
			var first := str(hdds[0] if not hdds.is_empty() else disks[0])
			if used_paths.has(_norm_key(first)):
				continue
			n += 1
			g = {"id": "s%d_%d_%d" % [int(now), n, randi() % 100000], "title": str(e["title"]), "cover": "",
				"added": now, "last_played": 0, "play_count": 0, "play_seconds": 0, "source": "scan", "scan_key": str(e["key"])}
			games.append(g)
			by_key[key] = g
			res["added"] += 1
		else:
			res["updated"] += 1
		g["category"] = str(e["category"])
		g["disks"] = disks
		g["hdds"] = hdds
		# 有硬盘镜像：从硬盘启动（软盘留在换盘菜单里）；否则第 1、2 张软盘插入 FDD1 / FDD2
		g["hdd1"] = str(hdds[0]) if not hdds.is_empty() else ""
		g["fdd1"] = str(disks[0]) if hdds.is_empty() and not disks.is_empty() else ""
		g["fdd2"] = str(disks[1]) if hdds.is_empty() and disks.size() > 1 else ""
		g["missing"] = false
	# 本次没有扫到的旧条目：文件不在了 → 标记缺失（不删除，可能是移动硬盘没插）；
	# 文件还在但分类方式变了（例如文件夹里新增了子文件夹）→ 删除旧条目，由新条目代替
	for i in range(games.size() - 1, -1, -1):
		var g: Dictionary = games[i]
		if str(g.get("source", "")) != "scan" or seen.has(_norm_key(str(g.get("scan_key", "")))):
			continue
		var key2 := str(g.get("scan_key", ""))
		var exists := FileAccess.file_exists(key2) or DirAccess.dir_exists_absolute(key2)
		if exists and _path_under(key2.replace("\\", "/"), root) and not is_missing(g):
			games.remove_at(i)
			res["removed"] += 1
		elif is_missing(g):
			g["missing"] = true
			res["missing"] += 1
	save_library()
	return res

static func _norm_key(p: String) -> String:
	p = p.replace("\\", "/")
	return p.to_lower() if OS.get_name() == "Windows" else p

# ---------------------------------------------------------------- system dir / BIOS
func system_dir() -> String:
	return data_path("system")

func np2_dir() -> String:
	return system_dir() + "/np2kai"

## 检查 BIOS 文件夹，返回 {name: bool}
func bios_status(dir_path: String = "") -> Dictionary:
	if dir_path == "":
		dir_path = str(settings.get("bios_dir", ""))
	var found := {}
	var names := _list_lower(dir_path)
	for n in ["bios.rom", "font.bmp", "font.rom", "sound.rom", "itf.rom"]:
		found[n] = names.has(n)
	return found

func _list_lower(dir_path: String) -> Dictionary:
	var out := {}
	if dir_path == "" or not DirAccess.dir_exists_absolute(dir_path):
		return out
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	for f in d.get_files():
		out[f.to_lower()] = f
	return out

## 准备核心的系统目录：复制 BIOS，按字体模式放置字体文件
func prepare_system_dir() -> void:
	DirAccess.make_dir_recursive_absolute(np2_dir())
	var bios_dir := str(settings.get("bios_dir", ""))
	var files := _list_lower(bios_dir)
	for lower in files.keys():
		if lower in FONT_FILE_NAMES:
			continue
		if _is_bios_copy(lower):
			_copy_if_changed(bios_dir + "/" + files[lower], np2_dir() + "/" + lower)
	# 删除 BIOS 文件夹中已不存在的旧副本（否则移除真机 BIOS 后仍会继续使用旧文件）。
	# 没有 bios.rom / itf.rom / sound.rom 时，NP2kai 会自动使用内置兼容 BIOS。
	var d := DirAccess.open(np2_dir())
	if d:
		for f in d.get_files():
			var lower := f.to_lower()
			if lower in FONT_FILE_NAMES or not _is_bios_copy(lower):
				continue
			if not files.has(lower):
				DirAccess.remove_absolute(np2_dir() + "/" + f)
	prepare_fonts()

static func _is_bios_copy(lower: String) -> bool:
	return lower.ends_with(".rom") or lower.ends_with(".wav") or lower.ends_with(".bin") or lower == "default.ttf"

## 是否有真机 BIOS（bios.rom）；没有时使用 NP2kai 内置的兼容 BIOS
func has_real_bios() -> bool:
	return bios_status().get("bios.rom", false)

func has_font_rom() -> bool:
	var st := bios_status()
	if str(settings.get("font_mode", "auto")) == "file":
		return FileAccess.file_exists(str(settings.get("font_file", "")))
	return str(settings.get("font_mode", "auto")) == "auto" and (st.get("font.bmp", false) or st.get("font.rom", false))

## 字体文件：auto = 使用 BIOS 文件夹里的 font.bmp/FONT.ROM；file = 指定文件；ttf = 仅系统字体生成
func prepare_fonts() -> String:
	var dst := np2_dir()
	DirAccess.make_dir_recursive_absolute(dst)
	var mode := str(settings.get("font_mode", "auto"))
	var src := ""
	if mode == "auto":
		var files := _list_lower(str(settings.get("bios_dir", "")))
		for n in ["font.bmp", "font.rom"]:
			if files.has(n):
				src = str(settings["bios_dir"]) + "/" + files[n]
				break
	elif mode == "file":
		src = str(settings.get("font_file", ""))
		if not FileAccess.file_exists(src):
			src = ""
	var canonical := ""
	if src != "":
		canonical = dst + ("/font.bmp" if src.get_extension().to_lower() == "bmp" else "/FONT.ROM")
	# remove stale font files so the core does not pick up the wrong one
	for n: String in ["font.bmp", "FONT.ROM", "font.rom", "FONT.BMP"]:
		var p := dst + "/" + n
		if p != canonical and FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	if canonical != "":
		_copy_if_changed(src, canonical)
	# invalidate the cached synthesised font when the font source changed
	var stamp := "%s|%s|%s|%d" % [mode, src, str(settings.get("ttf_file", "")), int(settings.get("ttf_index", 0))]
	var stamp_path := dst + "/pc98_font_stamp.txt"
	var old := ""
	if FileAccess.file_exists(stamp_path):
		old = FileAccess.get_file_as_string(stamp_path)
	if old != stamp:
		if FileAccess.file_exists(dst + "/font.tmp"):
			DirAccess.remove_absolute(dst + "/font.tmp")
		var f := FileAccess.open(stamp_path, FileAccess.WRITE)
		if f:
			f.store_string(stamp)
	return canonical

func _copy_if_changed(src: String, dst: String) -> void:
	if not FileAccess.file_exists(src):
		return
	if FileAccess.file_exists(dst):
		if FileAccess.get_modified_time(src) <= FileAccess.get_modified_time(dst) and _size(src) == _size(dst):
			return
	DirAccess.copy_absolute(src, dst)

func _size(p: String) -> int:
	var f := FileAccess.open(p, FileAccess.READ)
	return f.get_length() if f else -1

func core_path() -> String:
	if OS.get_name() == "Android":
		# 核心作为 GDExtension 依赖随 APK 安装在原生库目录（lib/<abi>/），按文件名 dlopen
		return "libnp2kai_libretro.so"
	var name := "np2kai_libretro.dll" if OS.get_name() == "Windows" else "np2kai_libretro.so"
	var exe_dir := OS.get_executable_path().get_base_dir()
	if not OS.has_feature("editor") and FileAccess.file_exists(exe_dir + "/" + name):
		return exe_dir + "/" + name
	return ProjectSettings.globalize_path("res://addons/pc98/bin/" + name)

# ---------------------------------------------------------------- mobile / Android 导入
static func is_android() -> bool:
	return OS.get_name() == "Android"

## 移动端界面：真机（mobile 特性）或桌面上用 --force-mobile 预览
static func is_mobile() -> bool:
	return OS.has_feature("mobile") or "--force-mobile" in OS.get_cmdline_user_args()

const BIOS_NAMES := ["bios.rom", "itf.rom", "sound.rom", "font.bmp", "font.rom", "2608_bd.wav", "2608_sd.wav",
	"2608_top.wav", "2608_hh.wav", "2608_tom.wav", "2608_rim.wav", "bios9821.rom", "d8000.rom", "ide.rom", "default.ttf"]
const DISK_EXTS := LibraryScan.FD_EXTS
const HDD_EXTS := LibraryScan.HDD_EXTS

func bios_import_dir() -> String:
	return data_path("bios")

func games_import_dir() -> String:
	return data_path("games")

## 「导入文件夹」：Android 上是应用的外部文件目录（可通过 USB / 文件管理器直接拷贝，无需额外权限）
func external_import_dir() -> String:
	if is_android():
		# user:// = /data/user/0/<包名>/files  → /storage/emulated/0/Android/data/<包名>/files/PC98
		var pkg := OS.get_user_data_dir().get_base_dir().get_file()
		return "/storage/emulated/0/Android/data/%s/files/PC98" % pkg
	return data_path("PC98")

## 从 SAF 返回的 content:// URI（或普通路径）推断文件名
static func uri_file_name(uri: String) -> String:
	if not uri.begins_with("content://"):
		return uri.get_file()
	var s := uri.split("#")[0]
	var seg := s.get_file().uri_decode()
	if seg.contains("/"):
		seg = seg.get_file()
	if seg.contains(":"):
		seg = seg.get_slice(":", seg.get_slice_count(":") - 1)
	return seg.get_file()

## 根据文件头猜测磁盘镜像类型（SAF 有时只给出数字 ID，没有扩展名）
static func sniff_image_ext(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var n := f.get_length()
	if n >= 0x20:
		f.seek(0x1c)
		if f.get_32() == n:
			return "d88"
	if n >= 32:
		f.seek(0)
		var z := f.get_32()
		f.get_32()
		var hdr := f.get_32()
		var data := f.get_32()
		var sect := f.get_32()
		if z == 0 and hdr == 4096 and data + hdr == n:
			return "fdi" if sect == 1024 else "hdi"
	return "hdi" if n > 2 * 1024 * 1024 else "fdi"

## 把选中的文件（content:// URI 或路径）流式复制到 dst_dir，返回目标的真实文件系统路径（失败返回 ""）
func import_file(src: String, dst_dir: String, name: String = "") -> String:
	if name == "":
		name = uri_file_name(src)
	name = name.validate_filename()
	if name == "":
		name = "file_%d" % Time.get_unix_time_from_system()
	DirAccess.make_dir_recursive_absolute(dst_dir)
	var dst := dst_dir + "/" + name
	if ProjectSettings.globalize_path(src) == dst:
		return dst
	var fi := FileAccess.open(src, FileAccess.READ)
	if fi == null:
		push_warning("[PC98] 无法读取：" + src)
		return ""
	var fo := FileAccess.open(dst, FileAccess.WRITE)
	if fo == null:
		return ""
	var left := fi.get_length()
	while left > 0:
		var chunk := fi.get_buffer(mini(left, 1 << 20))
		if chunk.is_empty():
			break
		fo.store_buffer(chunk)
		left -= chunk.size()
	fo.close()
	return dst

## 导入 BIOS 文件（多选的 URI / 路径），按小写文件名放入 <数据目录>/bios；返回导入数量
func import_bios_files(srcs: Array) -> int:
	var n := 0
	for s in srcs:
		var name := uri_file_name(str(s)).to_lower()
		if import_file(str(s), bios_import_dir(), name) != "":
			n += 1
	if n > 0:
		settings["bios_dir"] = bios_import_dir()
		save_settings()
	return n

## 导入 BIOS 文件夹：SAF 目录 URI 无法列出内容，按已知的 BIOS 文件名逐个尝试（大小写两种）
func import_bios_tree(tree: String) -> int:
	var n := 0
	for name: String in BIOS_NAMES:
		for cand in [name, name.to_upper(), name.get_basename().to_upper() + "." + name.get_extension()]:
			var src: String = (tree + "#" + cand) if tree.begins_with("content://") else (tree + "/" + cand)
			if FileAccess.file_exists(src):
				if import_file(src, bios_import_dir(), name) != "":
					n += 1
				break
	if n > 0:
		settings["bios_dir"] = bios_import_dir()
		save_settings()
	return n

## 导入游戏镜像：一个 HDI → 硬盘游戏；1–2 个 FDI → 软盘游戏（按文件名排序为 FDD1/FDD2）。返回新增的游戏
func import_game_files(srcs: Array, title: String = "") -> Array:
	var hdds: Array[String] = []
	var fdds: Array[String] = []
	var stamp := str(Time.get_unix_time_from_system()).replace(".", "")
	var tmp_dir := games_import_dir() + "/" + stamp
	for s in srcs:
		var name := uri_file_name(str(s))
		var ext := name.get_extension().to_lower()
		var dst := import_file(str(s), tmp_dir, name)
		if dst == "":
			continue
		if not (ext in DISK_EXTS or ext in HDD_EXTS):
			ext = sniff_image_ext(dst)
			var fixed := dst + "." + ext
			DirAccess.rename_absolute(dst, fixed)
			dst = fixed
		if ext in HDD_EXTS:
			hdds.append(dst)
		else:
			fdds.append(dst)
	fdds.sort()
	var added := []
	for h in hdds:
		var t := title if title != "" and hdds.size() == 1 else h.get_file().get_basename()
		added.append(add_game(t, "", "", h, ""))
	if fdds.size() > 0:
		var t2 := title if title != "" else fdds[0].get_file().get_basename()
		added.append(add_game(t2, fdds[0], fdds[1] if fdds.size() > 1 else "", "", ""))
		for i in range(2, fdds.size()):
			added.append(add_game(fdds[i].get_file().get_basename(), fdds[i], "", "", ""))
	return added

func _game_has_path(p: String) -> bool:
	for g in games:
		if str(g.get("fdd1", "")) == p or str(g.get("fdd2", "")) == p or str(g.get("hdd1", "")) == p:
			return true
	return false

## 扫描导入文件夹中的 BIOS：BIOS/ 子文件夹（或根目录中的 bios.rom）作为 BIOS 文件夹
func scan_import_dir() -> Dictionary:
	var root := external_import_dir()
	DirAccess.make_dir_recursive_absolute(root + "/BIOS")
	var res := {"bios": 0, "games": 0}
	for bd in [root + "/BIOS", root + "/bios", root]:
		var files := _list_lower(bd)
		if files.has("bios.rom"):
			var n := 0
			for k in files.keys():
				if k in BIOS_NAMES:
					n += 1
			settings["bios_dir"] = bd
			save_settings()
			res["bios"] = n
			break
	# 游戏镜像由递归扫描（start_library_scan）处理：安卓上游戏库文件夹默认就是导入文件夹
	return res
