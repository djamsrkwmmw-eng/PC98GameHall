class_name I18n
extends RefCounted
## 多语言支持：翻译表为 res://i18n/ui.csv（Godot 内置 CSV 翻译导入），键 = 简体中文原文。
## 缺少的键自动回退为简体中文（键本身），project.godot 中 fallback 也设为 zh_CN。首次启动默认界面语言为英文（DEFAULT_LOCALE）。

const DEFAULT_LOCALE := "en"   # 首次启动（没有保存过语言设置）默认英文
const LOCALES := ["zh_CN", "zh_TW", "en", "ja"]
const LANG_NAMES := ["简体中文", "繁體中文", "English", "日本語"]

static func language_name(locale: String) -> String:
	var i := LOCALES.find(locale)
	return LANG_NAMES[i] if i >= 0 else locale

static func apply_locale(locale: String) -> void:
	if not locale in LOCALES:
		locale = DEFAULT_LOCALE
	TranslationServer.set_locale(locale)

static func t(key: String) -> String:
	return TranslationServer.translate(key)

## 文件对话框过滤器 "*.fdi ; 说明" —— 整条字符串作为翻译键
static func tr_filters(filters: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for f in filters:
		out.append(t(str(f)))
	return out

## 模拟器核心（GDExtension，C++ 内为简体中文）返回的错误信息 → 当前界面语言
const _CORE_FRAGMENTS := ["无法加载模拟器核心: ", "核心缺少函数: ", "未设置核心路径", "核心无法载入游戏镜像", "GDExtension 未加载",
	"内存访问违例 (SIGSEGV)", "总线错误 (SIGBUS)", "算术异常 (SIGFPE)", "非法指令 (SIGILL)", "核心中止 (SIGABRT)",
	"内存访问违例", "非法指令", "整数除零", "栈溢出", "未知异常"]
const _CORE_STAGES := ["启动（首帧初始化）", "运行", "初始化", "载入镜像", "释放核心", "读取视频参数", "读取介质", "挂载介质",
	"弹出软盘", "交换软盘", "切换字体", "设置字体", "插入软盘", "挂载硬盘", "停止", "复位"]

static func core_message(msg: String) -> String:
	if TranslationServer.get_locale().begins_with("zh_CN") or msg == "":
		return msg
	var re := RegEx.new()
	re.compile("^模拟器核心在“(.*?)”阶段崩溃：(.*)。已停止模拟。常见原因：BIOS 文件不完整/损坏、镜像文件损坏或机型设置不匹配。$")
	var m := re.search(msg)
	if m:
		var stage := m.get_string(1)
		if stage in _CORE_STAGES:
			stage = t(stage)
		return t("模拟器核心在“%s”阶段崩溃：%s。已停止模拟。常见原因：BIOS 文件不完整/损坏、镜像文件损坏或机型设置不匹配。") % [stage, _tr_fragments(m.get_string(2))]
	return _tr_fragments(msg)

static func _tr_fragments(s: String) -> String:
	for f in _CORE_FRAGMENTS:
		if s.find(f) >= 0:
			s = s.replace(f, t(f))
	return s
