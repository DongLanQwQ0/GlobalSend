# Windows 窗口内外统一原生拖放 · 1.0.74+94

## 根因

用户确认：在窗口内开始拖动后切换 Windows 虚拟桌面，拖影消失；先拖出窗口再切换则能保留。原实现中，普通鼠标拖动先由 Flutter 的 Draggable 展示窗口内反馈，只有指针越过窗口边界才进入 OLE；尚未跨边界时，拖影随源窗口隐藏。

## 修改

- Windows 在拖动刚开始时复用已有卡片的首帧像素，并立即走现有原生 OLE 导出入口，不等指针越过边界或再次移动。
- 沿用原生 Shell 拖影、居中热点、数据对象、复制操作和现有触屏入口；没有新增模拟鼠标输入、自绘顶层拖影窗口或移动主窗口的实现。
- 保留正在使用的卡片外观。Flutter 头像仅用于这次首帧像素读取，随后取消其指针流，整次拖放由原生入口继续，避免两个头像及拖回后无法再次拖动。
- 原生队列和设备目标继续启用，保留剪贴板建议的禁止投放范围。不改 Android 拖放和刚交付的贴边/阻尼版本 93。

## 验证

- `content_drag_surface_regression_test.dart` 5 项通过：在窗口内且没有后续移动时已进入原生导出、取得原卡片像素、生命周期隐藏后原生 Future 仍保留；不重复导出、原生消费 UP 后下一次仍可拖；触屏类型、阅读器拖动及 Android 入口回归。
- `windows_export_surface_test.dart` 及剪贴板排除范围检查在组合运行中通过 4 项，包含保存的文件/图片及卡片内容、元信息触点。
- 新 `windows_native_drag_start_test.dart` 通过：真实页面组件在普通卡片的原生拖放进行中仍发布待发和设备目标；放回队列、直接向设备发送均保留其他草稿。
- 同一组合运行中的旧图片/剪贴板建议长流程遇到 `did not complete`（无产品断言），保留在 `integration.log`；新增普通卡片集成用例首次也遇到该退出，加入同步步骤记录后完整通过。没有据此声称整套集成测试全部通过，也没有改动已验收的建议专用入口。
- 证据：`artifacts/tmp/native-start94/` 中的 `regression.log`、`integration.log`、`targets.log`、`analyze.log`。

遵守用户“不测试 Windows”的限制：以上均为独立测试引擎和模拟平台接口，没有切换用户的真实虚拟桌面或操作桌面应用。真实虚拟桌面切换与外部投放仍由用户验收。

原生入口沿用 Microsoft 文档定义的 [DoDragDrop](https://learn.microsoft.com/en-us/windows/win32/api/ole2/nf-ole2-dodragdrop) 和 [IDropSource::GiveFeedback](https://learn.microsoft.com/en-us/windows/win32/api/oleidl/nf-oleidl-idropsource-givefeedback)，未引入虚拟桌面私有接口。

## 交付范围

仅运行 `npm run release:local -- -WindowsOnly` 更新 Windows。Android 保持已装好的 `1.0.74+93`，不构建或推送 APK、不访问 ADB、不再次占用手机；服务器、Web 和 IPA 不变。

Windows 已构建、完整覆盖并重启，实际文件版本 `1.0.74+94`；字体文件数为 0。发布记录已明确区分 Windows build 94 与已确认的 Android build 93，证据保存于任务目录 `delivery.json`。真实虚拟桌面切换仍待用户手动验收。
