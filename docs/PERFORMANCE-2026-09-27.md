# LightMD 0.14.1 性能与回归记录

日期：2026-09-27。

## 历史依据

早期分栏使用 `HSplitView`，后续改为自定义布局以支持模式过渡。Git 版本记录从 0.14.0 开始。
## 对照测试

样本文档为生成的 157,208 字节 Markdown，包含 120 个章节、长段落、中文粗体和列表。测试使用实际 ReaderView、NSTextView 和分隔线事件，统计事件处理、布局及一次短运行循环的耗时。数值不是屏幕显示 FPS。

| 位置 | 源码每次拖动重排：中位耗时 | 拖动时固定源码换行：中位耗时 | 固定源码换行后的 P95 |
| --- | ---: | ---: | ---: |
| 顶部 | 17.14 ms | 8.37 ms | 9.20 ms |
| 全文滚读后的中部 | 121.87 ms | 12.50 ms | 29.99 ms |
| 文档后部 | 240.09 ms | 10.40 ms | 14.70 ms |

两组均使用按需创建的预览内容块。额外对照显示，仅 NSTextView 的全文重排就能产生约 238–240 ms 的开销。因此采用有限处理：拖动时源码保持原换行，右侧预览持续实时排版，松手后源码按最终宽度重排。松手时仍需要一次源码重排，不能把拖动期间的耗时宣称为所有阶段都无停顿。

整篇 VStack 的窗口宽度变化测试中位约 277 ms；按需创建内容块后约 19.5 ms。该结果用于判断预览布局方案，与上表的实际分隔线拖动测试不是同一指标。

## 验证结果

- 原生左右调整光标、分隔线拖动改变栏宽均通过。
- 模式切换记录到 25 个不同中间正文尺寸；目录动画记录到 47 个中间尺寸，文字高度随换行变化。
- 远处未显示章节、嵌套列表、连续定位只执行最新目标、预览反向带动源码、目录／搜索跳转和待定位期间切换标签均通过。
- 离屏检查验证两侧滚到底、远处定位→顶部→再次定位、源码宽度恢复、文本与选择范围及撤销状态保持、替换编辑器时取消冻结。
- HTML 结构与内联 JavaScript 语法检查通过。未自动打开浏览器。
- 后续测试遵守用户最新要求：不显示或置顶测试窗口，不切换用户当前应用。

## 参考资料

- Apple：[SwiftUI 性能分析](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance)。
- Apple：[用户滚动通知](https://developer.apple.com/documentation/appkit/nsscrollview/1403486-didlivescrollnotification)。
- Apple：[NSView 光标区域](https://developer.apple.com/documentation/appkit/nsview/resetcursorrects())。
