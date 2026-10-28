# GlobalSend 原生客户端

Flutter Windows / Android 应用。中心协议见 [API](../docs/API.md)，候选包和切换步骤见 [实机测试](../docs/QUICK_TEST.md)。

## 日常使用

1. 填写至少 **10 位组密码**，点击“连接”。中心默认 `https://123.207.180.163/globalsend`，可修改；同一中心、同一密码自动入组，无邀请码或创建确认。设备名自动读取系统名称，可在“更多”或设置中修改。
2. 手机发送页用“文件”或“媒体”多选添加；Android“媒体”打开系统图片/视频 Picker。Windows 窗口任意区域也可拖入。内容先进入待发区；默认点设备直接发送，多台先点“多选”再确认。Android 也支持系统拖放或“分享 → GlobalSend”。
3. 同组文件默认自动接收，可关闭开关改为逐项确认。只读文件与文本卡片整体可拖，正文不再选字；复制使用按钮，编辑框保留输入与选字。Windows 鼠标直接拖、触屏/笔长按拖；Android 长按后拖动。
4. 文字独立复制、查看；接收页多选时整卡切换选择，支持全选、批量删除，复制仅处理选中文本。收到消息只读，已发送消息可编辑原记录。常见文本文件和图片可预览。组内共享只协作编辑，不通知或弹出收件页面。
5. 文件库两列显示本机已保存文件，离线、换中心或退出组后仍可查看；通过编辑/多选按钮选择，长按只拖放。支持重命名、删除与转发。转发需明确选择当前在线设备，不自动跨组发送。

本版发现规则要求中心同步升级。已登记设备使用原设备凭据自动重连，无需重新输入组密码；保留自定义名称和本机文件。

## 保存位置与清理

在“设置 → 存储”选择 Windows 文件夹或 Android 系统目录。文件直接接收到所选位置，不保留第二份永久副本；已有半文件仍在原位置续传，取消失败任务会释放半文件。

默认保留 **24 小时**，可按小时/天设置，并选择清理类别和大于/小于 MiB 的大小条件。清理包括自选目录内由本应用接收的文件；不扫描删除目录中的原有文件，不删除发送源文件或另行导出的副本。

## 连接方式

自动顺序为：**局域网 HTTPS / WebRTC → 公网 HTTPS / WebRTC → 中继**。原生之间先拉取、再反向推送；与浏览器通过 WebRTC 数据通道互通。反向推送让手机能连电脑、电脑无法连手机时，手机发送也能尝试直传。界面显示实际路径和失败原因；每分钟检测同组在线设备已公布的 HTTPS 地址，网卡变化时重新发布与检测。WebRTC 候选在文件协商时检测。

所有设备地址由中心按组交换，不使用局域网广播扫描。首次连接与重连均在 WebSocket `hello` 后立即发布本机 IPv4 / IPv6；正常心跳继续刷新。中心地址记录 30 分钟过期，设备离线立即撤下；客户端保留掉线设备 30 秒，可尝试发送，不继续在线探测。到期或切换分组后移除，不提供永久离线管理列表。

发送和接收均可手动指定网络类别。发送方的指定约束随本次 offer 保存，本机接收偏好只在发送方为自动时生效；手动直连失败不暗中改走中继。改路径重发只替换该文件，不重新选源文件，也不影响同批其他项。

Android 蜂窝传输默认开启且不限大小，可在设置中关闭。HTTPS 探测与文件使用所选 Network；RTC 仅在公网阶段、本机允许时使用蜂窝候选，界面按实际选中的网络显示。关闭开关会等待相关 RTC 会话释放，保留半文件；不改变全进程网络。超过默认 32 MiB 而需走中继时先确认。

## 项目内运行

### 构建、更新并重启两端

```powershell
npm run release:local
```

成功后完整Windows程序更新至`E:\Programs\GlobalSend`并重启，继续使用项目已有状态；旧安装备份留在项目`backups/windows-installed`。APK保存在`artifacts/releases`，推送到唯一ADB实体手机的`Download/GlobalSend-latest.apk`，覆盖安装并启动，不清除数据。多台设备时直接运行`scripts/Release-Local.ps1 -Serial <设备序列号>`。安装包不上服务器。

已知手机拒绝安装时，使用 `-PushOnlyPhone` 只推送 APK，不重复触发权限提示。无人值守仅重连已提供的地址或复用已授权 USB；失败保留待安装记录，其它端继续发布。

设备由另一个已授权任务独占联调时，使用 `npm run release:local -- -DeferPhone` 构建两端并更新Windows，将APK交给设备所有者安装；此选项不访问ADB。Android明确暂停时仍使用 `-WindowsOnly`，不构建APK。

Windows新版为单实例，重复打开会唤起原窗口，托盘或最小化窗口也会恢复。

以下是标准开发入口，不是隔离候选入口。候选的准确路径见 [实机测试](../docs/QUICK_TEST.md)。Release 的 EXE、DLL 和 `data` 必须一起保留。

```powershell
$env:PUB_CACHE = 'F:\Caches\PubCache'
$env:GRADLE_USER_HOME = 'F:\Android\GradleCache'
New-Item -ItemType Directory -Force 'build/tmp' | Out-Null
$env:TEMP = (Resolve-Path 'build/tmp').Path
$env:TMP = $env:TEMP
$env:GLOBALSEND_DATA_DIR = 'F:\Codes\Java\GlobalSend\artifacts\native-state'
& 'E:\Programs\flutter\bin\flutter.bat' run -d windows
```

`GLOBALSEND_DATA_DIR` 将项目验收的状态和默认接收文件留在项目内；未设置时使用系统应用目录。Windows 使用 DPAPI，Android 使用 Keystore 保护设备凭据及本机 HTTPS 私钥，不保存组密码。中心连接保持正常 HTTPS 校验；同组直连使用本次授权和精确证书身份。

## 平台边界与证据

Windows剪贴板同步由用户启用。Android采用缓存接收引擎、后台接收服务和独立有界接收/暂存坞；“后台弹出”通过系统授权入口开启，无法弹出时使用通知。厂商后台限制、锁屏和系统回收后的实际行为仍需真机确认。

Android 使用标准拖放、临时只读 URI 授权和系统目录选择；具体来源/目标 App 是否支持，仍以真机为准。iPad 使用独立 Web，新版源码已接入 WebRTC 和本机文件库，Safari 真机仍待验收。Android RTC 已接入每次公网连接的蜂窝授权策略，关闭开关等待相关会话释放；局域网不使用蜂窝。实际 Android JNI、蜂窝 IPv6 和切网仍待真机确认。详见 [WebRTC 开发验收](../docs/WEBRTC_DEVELOPMENT.md)。

构建、真实 socket、组件渲染和设备验收分别记录，不相互替代。当前有效证据与剩余项见 [原生验收](../docs/NATIVE_TESTING.md) 和 [实施记录](../docs/PROGRESS.md)。
