# GlobalSend 手动测试

## 先确认版本

截至 2026-10-29，发布记录确认：

- Windows **1.0.48+57** 已完整更新并启动于 `E:\Programs\GlobalSend`，进程响应。
- [Android arm64 APK](../artifacts/releases/GlobalSend-1.0.48-android-arm64-v8a.apk)：16,291,952字节。USB 覆盖安装成功，手机实际读回 **1.0.48+57**，数据保留；之后 USB 断开。
- [Windows 完整包](../artifacts/releases/GlobalSend-1.0.48-windows-x64.zip)：22,370,185字节，不要只复制EXE。当前公开的 [GitHub分发](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.35-build44)仍为35，不能将其当作48；中心不托管包。
- 中心及[网页版](https://123.207.180.163/globalsend/app/)已部署多组连接、流式中继和链接识别，镜像 `globalsend:multi-group-20261029-1620`。48仅改 Android 按钮栏，无需重复部署中心。

版本以 [本机发布记录](../artifacts/releases/latest-local.json) 和 [中心部署记录](../artifacts/deploy/current-workspace-deployment.json) 为准。新版手机重点为 [独立暂存坞](TEMPORARY_SHELF.md)、系统拖影主题及应用安装包选择；不能把框架测试当作手机更新或物理跨应用拖放验收。步骤见 [UI 验收](UI_ACCEPTANCE.md)。

## 快速走一遍

1. 两端使用中心 `https://123.207.180.163/globalsend` 和同一个至少十位的组密码。Web 默认使用网页来源服务器，不必重复填写。
2. 添加一段文字、一张图片和一个小文件；点击设备直接发送。成功后本批清空。多台发送先进入“多选”，选完确认。
3. 接收后打开内容、复制文字，再把卡片拖回待发送或拖到其他应用。Windows 另试 Ctrl+V 粘贴文字、图片、文件，以及 Esc 回退。
4. 编辑组内共享文字，另一端应更新；试撤销、重做。共享编辑不得触发收件弹层、后台唤起或聊天通知。
5. Windows 留在托盘、手机切到其他应用，再收文字和图片。检查接收展示与 [Android 通知](RECEIVE_NOTIFICATIONS.md)。

## 当前尚未完成的实机验收

- 手机：左右贴边收起、展开往返，检查按钮栏始终留在贴边侧；切换接收/暂存及重新打开应用后仍正确。48已观察到左右布局，USB断开前未完成受控往返。
- 微信：同一提前打开、没有菜单遮挡的聊天，将暂存坞图片拖入；检查是否出现图片/附件预览，不点击发送。不同UID测试接收器可读文件不代表微信插入通过。
- Windows：实体触屏拖出到另一应用、外部复制期间主界面响应、接收坞的点击/拖动与菜单删除仍需交互验收。此前停止的桌面输入保持停止，恢复后再验。
- iPad：Windows/Android稳定验收后，最后手动构建新IPA，再检查签名后的系统分享、跨应用拖放、右滑返回和图片缩放；不提前运行IPA工作流。

失败时记录：两端版本、来源/目标、操作步骤、实际路径或错误提示。先用小文件验证；中继不要用大文件做吞吐测试。

## 更新约定

统一使用 `npm run release:local`。成功构建后完整更新 `E:\Programs\GlobalSend` 并重启；向已授权手机推送 APK、覆盖安装并启动，保留数据。安装包留本地及 GitHub Release，不上传中心服务器。

无人值守时只尝试已有授权 USB 或用户提供的 ADB 地址；断开则保留 APK 与待推送状态，不索要新地址，不阻塞 Windows 和 Web 发布。
