# iPad：网页图片、分享导入与窗口顶栏

## 网页图片拖入

同一个 Safari `NSItemProvider` 可以同时声明网页地址和图片。旧入口先读取 `public.url`，会把图片变成链接；某种文件表示读取失败时也没有继续读取其他表示。

现在的入口保留设备卡片的直接投递目标，依次读取：

1. 真实文件 URL、文件夹。
2. 图片及其他文件的原始文件表示、原始 Data、旧式 item 表示。
3. 图像 URL；普通网页地址仍作为文字链接处理。
4. 只有来源未提供原始字节时，才使用 `UIImage` 的 PNG 表示。

文件在 provider 回调返回前复制到共享收件空间。文件和 Data 都检查实际图像容器，补全或修正后缀，不把原始 HEIC/JPEG/PNG 统一转码。`data:image` 可以直接保存；公开图像 URL 使用实际响应下载。HTTP 仍服从平台现有 ATS 配置。浏览器私有 `blob:` 地址无法由另一个原生应用读取，不能把它当作文件或普通文字静默发送。GlobalSend Web 已由主任务核实会导出真实 `File`，不需要用 blob 文字替代图片。

对应实现：`client/ios/Runner/SharedInboxStore.swift` 的 `SharedItemLoader`、`SharedProviderImport`、`SharedImportedFileName`，以及 `FileSharing.swift` 的 drop 入口。原有每卡原生出站拖影、剪贴板和媒体建议 provider 未被替换。

## 分享先请求唤起，导入进度连续显示

分享扩展先建立带唯一批次 ID 的 `importing` 清单，然后在主线程请求打开 GlobalSend，再启动 provider 导入。不会等所有复制完成才请求打开。宿主提前看到的是导入中的批次，完成前不入队、不发送。

每个已完成的项目及其真实计数都原子写入 App Group。宿主监听目录变化，显示“正在导入 X/N 项”，完成后显示“正在加入待发送”，入队并确认后消失。普通分享加入待发送；系统设备建议携带的 `serverKey + deviceId` 定向批次仍自动发送给原目标。

进度不根据时间增长。扩展持有进程文件锁；完成时先写入完成清单再释放锁。宿主在独立后台队列等待锁释放，因此扩展被系统终止、没有新的目录事件时也会收到结束信号。没有完成清单的批次会显示中断原因，并保留已经导入的项目；这些项目仍可进入待发送，不把整批错误变成应用无法使用。

保持扩展请求到 provider 回调完成，避免提前 `completeRequest` 丢失临时文件。如果系统拒绝唤起，导入仍继续，结果保存在共享空间，扩展显示“导入完成，请打开 GlobalSend”。Share Extension 没有公开的、无条件把宿主置前台的系统保证。

来源核对：

- [Apple：NSExtensionContext.open](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)) 说明是否支持打开 URL 由扩展点决定，文档列举 Today/iMessage，并未给 Share Extension 同样保证。
- [LocalSend 的分享扩展](https://raw.githubusercontent.com/localsend/localsend/main/app/ios/ShareExtension/ShareViewController.swift) 继承 `share_handler`。[该插件原始实现](https://raw.githubusercontent.com/AboutShout/share_handler/main/share_handler_ios/ios/Models/Classes/ShareHandlerIosViewController.swift) 使用 responder chain 中的 `UIApplication.open`，也不是 Share Extension 的无条件前台唤起 API。GlobalSend 保留这条已使用的唤起路径，改变导入顺序与状态交接。

## 窗口控制只占顶栏，不挤正文

iPadOS 26 使用真实窗口的公开 UIKit 布局指南，而不是凭屏幕尺寸猜安全区域：

- `UIView.layoutGuide(for: .margins(cornerAdaptation: .horizontal))` 提供绕开窗口控制的横向顶栏区域。
- 同一窗口的纵向适配区域用于确定控制区高度；与普通 margins 比较得到额外避让量。
- 自定义 `FlutterViewController` 在实际布局和安全区域变化后更新指标，覆盖窗口缩放、旋转和多任务变化。
- Flutter 的同一顶栏组件用于工作区、连接、设置、图片、文件库、连接检测、指南及旧记录页面；文本详情的自绘标题也接入。只有与顶部控制区相交的标题行避让，正文仍使用全宽，低处弹窗不额外缩进。全局右滑返回保留。

这套 API 不仅处理圆角。Apple 在 [WWDC25《Make your UIKit app more flexible》](https://developer.apple.com/videos/play/wwdc2025/282/) 的 12:21–13:04 专门说明新窗口控制，并以 horizontal corner adaptation 布局指南示范如何将栏状内容放在窗口控制的后缘。API 原文：[layoutGuide(for:)](https://developer.apple.com/documentation/uikit/uiview/layoutguide(for:))、[margins(cornerAdaptation:)](https://developer.apple.com/documentation/uikit/uiview/layoutregion/margins(corneradaptation:))。

iOS/iPadOS 26 之前仍使用既有系统 SafeArea，不加固定的大块顶栏留白，也不新增无障碍权限。

现有“全部拖拽”原生按钮的前景色也通过同一平台桥传入当前主题色，主题变化时更新。拖动中更新仍保留为 pending 参数，结束后一起应用，不改动正在导出的文件批次。

## 验证与设备边界

- Flutter 顶栏、导入状态桥、真实计数显示、原有右滑返回共 10 项检查通过；记录在 `artifacts/tmp/ios-native-20261102/flutter-tests-final.log`。
- 原生拖拽按钮的主题更新桥接套件 5 项通过（其中 4 项与上项复用，新增 1 项主题更新），记录在 `artifacts/tmp/ios-native-20261102/theme-bridge-tests.log`。
- 新顶栏和进度组件的聚焦分析无问题。包含既有大型页面的分析仅有原有风格提示，无编译错误或警告。
- 检查了工作区与设置页的实际 Flutter 渲染。测试注入窗口控制指标，验证标题避让、正文全宽、缩放后撤销避让；这不是实际 iPad 系统控制的测量结果。Windows 测试宿主不能完整替代 Apple 字体与 UIKit 窗口呈现。
- `SharedItemLoader` 的 Foundation/UTI 文件、Data 和 URL 共用路径可以直接在 macOS 编译，只有 `UIImage` 后备留在 UIKit 条件分支。现有手动 IPA 工作流在完整 iOS 构建前实际编译并执行 `client/ios/Tests/SharedItemProviderTests.swift`，使用真实 `NSItemProvider` 验证图片优先、file 失败后 Data 后备、普通链接、图像 Data URL 及 blob 拒绝；不创建模拟器，不需要签名，也不替换 UIKit/provider。
- macOS 工作流 [41395794956](https://github.com/DongLanQwQ0/GlobalSend/actions/runs/41395794956) 已实际执行共享容器与真实 `NSItemProvider` 检查，并完成 UIKit 宿主、分享扩展和 arm64 IPA107 构建。原始回调、handler 计数与通过结果在 `artifacts/tmp/receive106/ios107-ci-full.log`；产物检查在 `artifacts/tmp/receive106/ios107-verified.json`。`RunnerTests.swift` 的 iOS XCTest 并未执行，不把 IPA 编译当作它们通过。
- 首次106工作流验证了原字节导入，但测试错误地要求同一 UTI 的 file 和 Data handler 都执行；Foundation 实际直接选 Data 并合成文件。107保留此真实路径，同时另用不同 UTI 严格验证 JPEG file 失败三次后 PNG Data 成功，两个 handler 均有实测计数。只改测试，没有为通过检查而改变产品导入行为。首次失败日志保留在 `artifacts/tmp/receive106/ios-native-failure106.log`。
- 最终 iPad 手动验收仍需：Safari 普通图片与 GlobalSend Web 图片拖入空白发送区/设备卡；多文件分享提前唤起并连续导入；扩展被终止时不永久等待；窗口缩放、旋转后主界面和详情返回按钮不与系统控制重叠。
