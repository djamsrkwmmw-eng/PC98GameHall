extends RefCounted
## 游戏库文件夹递归扫描（在后台线程中运行，不访问场景树）
##
## 分类规则（简单、可预测）：
##   1. 根目录里直接放的镜像文件：每个文件 = 一款游戏（名称 = 文件名去掉扩展名）
##   2. 第一层子文件夹 = 分类（如「あ」「R」「OS」），只遍历，不会被当成游戏；
##      分类文件夹里直接放的镜像文件：每个文件 = 一款游戏
##   3. 更深层的「末端文件夹」（直接包含镜像、且没有子文件夹）= 一款游戏，名称 = 文件夹名，
##      里面的所有镜像按自然顺序（Disk1 < Disk2 < Disk10、A < B、(1) < (2)）组成磁盘组；
##      例外：文件夹里只有 2 个以上硬盘镜像（没有软盘）时，每个硬盘镜像各算一款游戏
##   4. 既有镜像又有子文件夹的文件夹：直接放的镜像各算一款游戏，子文件夹继续往下扫描
##   5. 只有子文件夹的文件夹：继续往下扫描
## 分类 = 根目录下的第一层文件夹名（根目录里直接放的游戏没有分类）。

## 软盘镜像（NP2kai 支持的格式；未知扩展名的 RAW 镜像按大小识别）
const FD_EXTS := ["fdi", "d88", "88d", "d98", "98d", "hdm", "xdf", "dup", "2hd", "tfd", "nfd", "fdd",
	"hd4", "hd5", "hd9", "h01", "hdb", "ddb", "dd6", "dcp", "dcu", "fim", "dsk", "img", "ima", "flp"]
## 这些扩展名太常见（也会出现在非 PC-98 文件上），只有大小像软盘（≤ 2 MB）时才算镜像
const FD_GENERIC_EXTS := ["img", "ima", "flp", "dsk"]
## 硬盘镜像
const HDD_EXTS := ["hdi", "nhd", "thd", "hdd", "hdn", "hds", "vhd", "slh"]
const MIN_SIZE := 512                 # 小于此大小的文件（含 0 字节）忽略
const GENERIC_MAX_SIZE := 2 * 1024 * 1024
const MAX_DEPTH := 12                 # 递归深度上限（防止符号链接循环 / 过深的目录）
const SKIP_DIRS := ["__macosx", "$recycle.bin", "system volume information", ".trash", ".trashes", ".git", "bios"]

var root := ""
var cancel := false
var dirs_scanned := 0
var files_seen := 0
var skipped := 0
var entries: Array = []        # [{key, title, category, disks:[], hdds:[]}]
var errors: Array = []
var _mutex := Mutex.new()
var _progress_cb: Callable

static func image_kind(path: String, size: int = -1) -> String:
	var ext := path.get_extension().to_lower()
	if ext in HDD_EXTS:
		return "hdd"
	if ext in FD_EXTS:
		if ext in FD_GENERIC_EXTS:
			if size < 0:
				size = FileAccess.get_size(path)
			if size > GENERIC_MAX_SIZE:
				return ""
		return "fd"
	return ""

static func natural_less(a: String, b: String) -> bool:
	var c := a.get_file().naturalnocasecmp_to(b.get_file())
	if c == 0:
		return a < b
	return c < 0

func _init(root_dir: String, progress_cb: Callable = Callable()) -> void:
	root = root_dir.replace("\\", "/").trim_suffix("/")
	_progress_cb = progress_cb

## 线程入口：返回 {entries, dirs, files, skipped, errors, msec}
func run() -> Dictionary:
	var t0 := Time.get_ticks_msec()
	if root == "" or not DirAccess.dir_exists_absolute(root):
		errors.append("root not found: " + root)
	else:
		_scan_dir(root, 0, "")
	return {"entries": entries, "dirs": dirs_scanned, "files": files_seen, "skipped": skipped,
		"errors": errors, "msec": Time.get_ticks_msec() - t0, "cancelled": cancel}

func _scan_dir(path: String, depth: int, category: String) -> void:
	if cancel:
		return
	var d := DirAccess.open(path)
	if d == null:
		errors.append("cannot open: " + path)
		return
	d.include_hidden = false
	d.include_navigational = false
	dirs_scanned += 1
	var fds: Array = []
	var hdds: Array = []
	var subdirs: Array = []
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var p := path + "/" + name
		if d.current_is_dir():
			if not (name.to_lower() in SKIP_DIRS):
				subdirs.append(name)
		else:
			files_seen += 1
			var ext := name.get_extension().to_lower()
			if ext in HDD_EXTS or ext in FD_EXTS:
				var sz := FileAccess.get_size(p)
				if sz < MIN_SIZE:
					skipped += 1
				else:
					var k := image_kind(p, sz)
					if k == "hdd":
						hdds.append(p)
					elif k == "fd":
						fds.append(p)
					else:
						skipped += 1
		name = d.get_next()
	d.list_dir_end()
	fds.sort_custom(natural_less)
	hdds.sort_custom(natural_less)
	subdirs.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	var has_images := not (fds.is_empty() and hdds.is_empty())
	if has_images:
		var leaf_game := depth >= 2 and subdirs.is_empty() and not (fds.is_empty() and hdds.size() >= 2)
		if leaf_game:
			_add(path, path.get_file(), category, fds, hdds)
		else:
			for h in hdds:
				_add(h, h.get_file().get_basename(), category, [], [h])
			for f in fds:
				_add(f, f.get_file().get_basename(), category, [f], [])
	if _progress_cb.is_valid() and dirs_scanned % 25 == 0:
		_progress_cb.call_deferred(dirs_scanned, entries.size())
	if depth >= MAX_DEPTH:
		if not subdirs.is_empty():
			errors.append("max depth reached: " + path)
		return
	for s in subdirs:
		_scan_dir(path + "/" + s, depth + 1, s if depth == 0 else category)

func _add(key: String, title: String, category: String, fds: Array, hdds: Array) -> void:
	entries.append({"key": key, "title": title, "category": category, "disks": fds.duplicate(), "hdds": hdds.duplicate()})
