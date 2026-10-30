# GlobalSend 手动测试

## 先确认版本

截至 2026-10-30，本地候选与公开发布分别为：

- Windows **1.0.58+74** 已完整更新并启动于 `E:\Programs\GlobalSend`；本轮不进行 Windows 界面测试。[开机启动与后台参数](WINDOWS_STARTUP.md)保持默认关闭，登录启动、不抢焦点及托盘恢复仍待手动验收。
- [Android arm64 APK](../artifacts/releases/GlobalSend-1.0.58-android-arm64-v8a.apk)约16.3 MB，手机已覆盖安装 74 版（16,317,376 字节）。真机已验证文件夹仅显示根卡片且结构完整、文本直接投到设备且其它草稿保留、编辑保存不再弹旧收件、删除媒体后建议消失。55版 Chrona 链接投递、54版图标触感、49版 APK 安装与48版微信投放验收保留。
- [Windows 完整包](../artifacts/releases/GlobalSend-1.0.58-windows-x64.zip)，不要只复制 EXE。[Windows/Android GitHub 公开分发](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.50-build59)仍为50版；本地74版未发布这些平台的包。中心不托管包。
- [iPad / iPhone 74版 IPA](../artifacts/releases/ios-1.0.58-build74/GlobalSend-iPad-unsigned.ipa)约14.8 MB，已构建并[发布](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.58-build74)，由用户用 iloader 手动签名安装。
- 中心及[网页版](https://123.207.180.163/globalsend/app/)已部署 58 版 Web 源码（37fa1fa），镜像 `globalsend:ui-1.0.58-20261030`。多组连接、流式中继和链接识别保留；71–74 仅原生修复，不重复部署。

版本以 [本机发布记录](../artifacts/releases/latest-local.json) 和 [中心部署记录](../artifacts/deploy/current-workspace-deployment.json) 为准。新版手机重点为 [独立暂存坞](TEMPORARY_SHELF.md)、系统拖影主题及应用安装包选择；不能把框架测试当作手机更新或物理跨应用拖放验收。步骤见 [UI 验收](UI_ACCEPTANCE.md)。

## 快速走一遍

1. 两端使用中心 `https://123.207.180.163/globalsend` 和同一个至少十位的组密码。Web 默认使用网页来源服务器，不必重复填写。
2. 添加一段文字、一张图片和一个小文件；点击设备直接发送。成功后本批清空。多台发送先进入“多选”，选完确认。
3. 接收后打开内容、复制文字，再把卡片拖回待发送或拖到其他应用。Windows 另试 Ctrl+V 粘贴文字、图片、文件，以及 Esc 回退。
4. 编辑组内共享文字，另一端应更新；试撤销、重做。共享编辑不得触发收件弹层、后台唤起或聊天通知。
5. Windows 留在托盘、手机切到其他应用，再收文字和图片。检查接收展示与 [Android 通知](RECEIVE_NOTIFICATIONS.md)。

## 本轮验收状态

- 手机：三次左右贴边往返、横竖屏位置恢复通过；用户确认窗口行为、投放和重启后位置记忆正常，并要求跳过后续同类测试。
- 微信：用户提前打开的文件传输助手实际收到合成测试图；代理没有点击发送。微信松手后直接显示聊天图片，而非确认预览。
- Windows：按用户最新要求停止测试，不继续操作窗口，不把构建和进程响应当作本轮交互验收。
- iPad：74版主应用/分享扩展均为真机 arm64，App Group 模板匹配、无打包字体。安装后从“文件”、照片和 Safari 拖入待发区或直接投到设备卡片，确认只发送本批、保留其它草稿；再从接收内容拖回其它应用。普通分享仍唤起待发送；系统第一排设备建议按唯一 ID 定向发送，其出现与排序由 iPadOS 决定。右滑返回和图片偏心缩放也需实机确认，详见 [iPad 安装说明](IPAD.md)。

失败时记录：两端版本、来源/目标、操作步骤、实际路径或错误提示。先用小文件验证；中继不要用大文件做吞吐测试。

## 更新约定

统一使用 `npm run release:local`。成功构建后完整更新 `E:\Programs\GlobalSend` 并重启；向已授权手机推送 APK、覆盖安装并启动，保留数据。安装包留本地及 GitHub Release，不上传中心服务器。

无人值守时只尝试已有授权 USB 或用户提供的 ADB 地址；断开则保留 APK 与待推送状态，不索要新地址，不阻塞 Windows 和 Web 发布。
