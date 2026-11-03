# Windows 116：拖影清理与显示变化

本次仅修复Windows两项现存行为，不重排UI、不操作真实Windows界面或系统显示设置，不接触手机。源码 `1b8fc79a63d9a7ac1a92fcdefe9c65e513b127f3`。

## 拖影不再等待指针事件清理

旧实现只请求异步PointerCancel，并在原生导出结束时重新显示Flutter反馈。指针派发被锁住时，该取消尚未被处理，旧拖影会重新出现。新增测试锁住指针派发，分别覆盖有/无原生开始通知：未修复源码两项均失败，修复后通过。

现在由当前拖动会话直接持有并结束Flutter avatar；交接、完成、取消及来源销毁会清理它。旧取消/结束通知不能重复结束同一avatar，也不能复活旧拖影；原生拖放进行时不创建第二个Flutter avatar。仍使用原生OLE交付内容，保留现有卡片像素、鼠标/触屏和窗口内投放。

证据：`artifacts/tmp/windows116/drag-baseline.log`两项真实失败，`drag-regression.log`九项通过，`drag-capture-toolbar.log`四项通过。最初名为drag-before的启动与修改发生交叠，未作为旧源码失败证据；baseline为明确恢复旧源码单独运行后得到的结果，随后已还原修复源码。

## 接收窗口跟随显示配置校正

接收窗口响应WM_DISPLAYCHANGE、WM_DPICHANGED及SPI_SETWORKAREA。使用原停靠位置或系统DPI建议位置选择最近的可用显示器，根据该屏DPI调整尺寸并夹入工作区；有效的用户位置保留。移除副屏、降低分辨率或改变任务栏工作区后，不再沿用不可见坐标。屏幕变化会结束使用旧坐标的过渡，隐藏窗口不会被意外显示。

真实生产几何函数的C++检查通过：分辨率缩小、负坐标副屏移除、任务栏工作区、96–192 DPI、极小屏幕及有效用户位置保持。编译及输出`artifacts/tmp/windows116/geometry.log`。完整Windows C++/Flutter release也编译通过；未伪称实际切换显示器或实体触屏验收。

## 本机交付

标准 `pnpm run release:local -WindowsOnly` 成功，完整目录已覆盖并重启。`E:\Programs\GlobalSend\globalsend.exe`读回 **1.0.91+116**，PID612；无打包字体。包位于 `artifacts/releases/GlobalSend-1.0.91-windows-x64.zip`，构建日志`artifacts/logs/release-windows116.log`。

Android未构建或操作，最后确认手机114，已有115 APK继续保留；中心/Web仍115、IPA仍114。GitHub Git传输443超时，本次源码/文档提交和116 ZIP保留本地，不能宣称116已公开发布；原115公开包不变。
