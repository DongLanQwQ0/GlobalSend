# 默认绕过系统代理 · 1.0.74+91

## 行为

- “设置 → 连接”和未登录时的“服务器设置”提供“绕过系统代理”，默认开启。
- 按本机安装保存到状态目录 `network.json`，不随服务器或分组切换而改变。旧安装没有该字段时也默认开启。
- 中心 HTTP、WebSocket、直连文件、可达性检测、GitHub 更新检查共用直连策略。客户端已创建后也会按新策略发送下一请求；切换时重连控制通道，不重置待发送或正在传输的文件。
- Android 原生逐网络检测、蜂窝上传/下载同样显式使用 `Proxy.NO_PROXY`，保留所选网卡/蜂窝绑定、证书和组权限。
- 关闭后恢复原来的运行时代理行为：Dart 使用环境代理解析，Android 的逐网络连接使用系统 Network 默认代理。没有新增代理服务器、PAC 或认证配置功能。
- 这是应用层代理开关，不是 VPN/TUN 绕行。Web 的网络由浏览器管理，不显示一个无法生效的开关。

## 验证

- Dart 路由/保存及原生桥、更新检查回归：8 项通过。实际本地 HTTP 代理验证：默认中心、更新及持久 WebSocket 均直连；同一客户端关闭后进入代理，再开启后恢复直连。
- Android `NetworkProxyPolicyTest`：通过，验证默认/显式开启使用所选 Network 的 `Proxy.NO_PROXY`，关闭恢复单参数系统连接。
- 设置弹窗 widget：默认开、可开关、空白关闭通过；已检查压缩后的实际测试渲染中新增开关的布局。
- Dart 分析无错误及警告；现有文件仍有代码风格 info 提示。
- 未操作真实 Windows 界面、未测试手机触控。构建开始前 ADB 无在线设备。

## 交付

使用 `npm run release:local -- -DeferPhone` 完成 Windows/APK 构建。Windows 已完整覆盖至 `E:\Programs\GlobalSend` 并重启，实际文件版本 `1.0.74+91`。

用户随后提供 `10.197.184.141:40137`，已连接 vivo V2527A，使用 `adb install -r` 流式覆盖成功并启动；包管理器确认 `versionName=1.0.74`、`versionCode=91`。保留应用数据，没有向手机常用目录另存 APK，没有进行手机触控或真实 Windows 界面测试。

APK：`artifacts/releases/GlobalSend-1.0.74-android-arm64-v8a.apk`，16,369,268 字节。Windows 和 APK 均确认没有字体文件。证据集中在 `artifacts/tmp/proxy-default/`；发布状态已记入 `artifacts/releases/latest-local.json`。

安装包未上传中心服务器；没有构建 IPA、部署 Web 或发布 GitHub Release。
