class_name MaxWidthContainer
extends Container
## 宽屏布局：子控件宽度限制为 max_width 并水平居中；窗口较窄时自动填满（保留 min_pad 边距）。
## 用于游戏库 / 最近游玩 / 游戏详情 / 设置等页面，避免全屏时内容铺满整个屏幕。

var max_width := 1100.0
var min_pad := 32.0
var top_pad := 32.0
var bottom_pad := 40.0

func _init(p_max_width := 1100.0, p_top := 32.0, p_bottom := 40.0) -> void:
	max_width = p_max_width
	top_pad = p_top
	bottom_pad = p_bottom
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

func content_rect() -> Rect2:
	var pad := min_pad if size.x < 1400 else 48.0
	var w := maxf(0.0, minf(size.x - pad * 2.0, max_width))
	return Rect2(floorf((size.x - w) / 2.0), top_pad, w, maxf(0.0, size.y - top_pad - bottom_pad))

func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		var r := content_rect()
		for c in get_children():
			if c is Control and c.visible and not c.top_level:
				fit_child_in_rect(c, r)

func _get_minimum_size() -> Vector2:
	var m := Vector2.ZERO
	for c in get_children():
		if c is Control and c.visible and not c.top_level:
			m = m.max(c.get_combined_minimum_size())
	return m + Vector2(min_pad * 2.0, top_pad + bottom_pad)
