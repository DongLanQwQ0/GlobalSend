# GlobalSend 手动测试

## 先确认版本

截至 2026-10-28，发布记录确认：

- Windows 已更新、启动 **1.0.30+39**，位于 `E:\Programs\GlobalSend`，进程响应。
- [Android arm64 APK](../artifacts/releases/GlobalSend-1.0.30-android-arm64-v8a.apk)：16,261,512 字节，约 15.51 MiB。**尚未安装到真实手机**；手机最后确认版本仍为 **1.0.28+37**，原数据保留。Chrona 独占共享模拟器进行本机集成联调，x86_64验证包与正式arm64包分开。
- [Windows 完整包](../artifacts/releases/GlobalSend-1.0.30-windows-x64.zip)。不要只替换 EXE。
- 中心与 [网页版](https://123.207.180.163/globalsend/app/) 已上线 `globalsend:url-integration-20261028-224537`，新增独立网页意图队列；Web资源沿用已验收的跟随系统及居中拖影版本，原有数据和中继卷保留。

版本以 [本机发布记录](../artifacts/releases/latest-local.json) 和 [中心部署记录](../artifacts/deploy/current-workspace-deployment.json) 为准。新版手机重点为 [独立暂存坞](TEMPORARY_SHELF.md)、系统拖影主题及应用安装包选择；不能把框架测试当作手机更新或物理跨应用拖放验收。步骤见 [UI 验收](UI_ACCEPTANCE.md)。

## 快速走一遍

1. 两端使用中心 `https://123.207.180.163/globalsend` 和同一个至少十位的组密码。Web 默认使用网页来源服务器，不必重复填写。
2. 添加一段文字、一张图片和一个小文件；点击设备直接发送。成功后本批清空。多台发送先进入“多选”，选完确认。
3. 接收后打开内容、复制文字，再把卡片拖回待发送或拖到其他应用。Windows 另试 Ctrl+V 粘贴文字、图片、文件，以及 Esc 回退。
4. 编辑组内共享文字，另一端应更新；试撤销、重做。共享编辑不得触发收件弹层、后台唤起或聊天通知。
5. Windows 留在托盘、手机切到其他应用，再收文字和图片。检查接收展示与 [Android 通知](RECEIVE_NOTIFICATIONS.md)。

失败时记录：两端版本、来源/目标、操作步骤、实际路径或错误提示。先用小文件验证；中继不要用大文件做吞吐测试。

## 更新约定

统一使用 `npm run release:local`。成功构建后完整更新 `E:\Programs\GlobalSend` 并重启；向已授权手机推送 APK、覆盖安装并启动，保留数据。安装包留本地及 GitHub Release，不上传中心服务器。

无人值守时只尝试已有授权 USB 或用户提供的 ADB 地址；断开则保留 APK 与待推送状态，不索要新地址，不阻塞 Windows 和 Web 发布。
