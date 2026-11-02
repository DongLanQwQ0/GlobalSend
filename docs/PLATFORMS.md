# 正式支持平台

GlobalSend 正式支持 **Windows、Android、iOS、iPadOS、Web**。后续需求、界面、使用说明、发布及验收均按这五个平台检查；共享实现不等于省略平台适配。

| 平台 | 客户端与分发 | 平台交互重点 |
| --- | --- | --- |
| Windows | 原生客户端，完整 ZIP | 鼠标与触屏原生拖放、全窗投放、托盘、接收坞、窗口与系统剪贴板 |
| Android | 原生客户端，APK | 系统拖放、媒体选择、系统分享、后台接收、悬浮暂存坞 |
| iOS | iPhone 原生客户端，IPA | 系统分享、剪贴板、文件与媒体选择、预览及触摸返回 |
| iPadOS | iPad 原生客户端，同一 IPA | iOS 共同能力，以及跨应用拖放、多任务窗口、窗口控制避让与横竖屏布局 |
| Web | 浏览器访问中心提供的网页 | 同源默认连接、浏览器拖放与粘贴、响应式页面、浏览器文件库及可用的 RTC 路径 |

## 共享核心，按平台接入系统

组与设备身份、收发数据含义、待发送、接收、历史、文件库及组内共享保持一致。系统拖放、分享、文件访问、后台接收和剪贴板使用对应平台的实现；浏览器遵循其可用能力，不以网页版本替代 iOS 或 iPadOS 原生客户端。

iOS 与 iPadOS 共用 Apple 原生工程、通用 IPA 和现有 `ios` 更新通道；当前工程的设备族为 iPhone 与 iPad（`TARGETED_DEVICE_FAMILY = 1,2`）。这是构建与协议复用，不将两个产品平台合并成一个验收项。现有 `ios` 协议值、更新清单及 `ipad` 指南键保留兼容。

## 使用说明与验收

- [Windows 指南](guides/windows.md)、[Android 指南](guides/android.md)、[iOS / iPadOS 共同指南](guides/ipad.md)、[Web 指南](guides/web.md)。共同指南中的多任务、台前调度与窗口控制说明适用于 iPadOS。
- Android 悬浮暂存坞和 Windows 接收坞分别验收；不在 iOS、iPadOS 或 Web 上声称有 Android 系统悬浮窗能力。
- iOS 与 iPadOS 分别检查各自布局、系统入口和返回交互；iPad 的成功结果不替代 iPhone 验收，网页结果也不替代原生验收。
- 平台专用修复只更新受影响的平台；发布与检查更新按平台包选择，不因为另一平台发布就提示升级。

中心和中继为共用 Docker 服务。macOS、Linux 暂不列入正式客户端支持范围。
