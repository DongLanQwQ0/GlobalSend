# Chrona → GlobalSend：定向打开局域网页面（协商草案）

状态：双方已按此方案分工实现。中心已部署独立 URL 意图队列，Windows 1.0.30+39已更新运行，Android同版正式包已交付并等待独占设备联调。准确消息格式以 [ABI v1](INTEGRATION_ABI_V1.md) 为准。Chrona 拥有 LAN 服务、入口 UI 和独占的设备联调，GlobalSend 拥有本机集成桥、组内发现、定向投递及接收端行为。

已收敛范围：Chrona 发送端仅 Android（`com.donglan.chrona`，minSdk 26 / targetSdk 36）；GlobalSend 接收端先覆盖 Windows / Android。不开发 Chrona Windows 客户端，不新增 Windows 本机 IPC，不宣布 Web / iOS 支持自动打开。Chrona 代理已读取并采用本草案，以下纳入其确认的身份和平台边界。

## 1.0.29 集成前能力（历史基线）

| 能力 | 现状与出处 |
| --- | --- |
| Android 已安装检测 | 包名 `dev.globalsend.globalsend`。Chrona 可声明精确包名的 `<queries>` 后通过 PackageManager 查询；GlobalSend 的 MainActivity exported，支持 ACTION_SEND/SEND_MULTIPLE。现有分享只入待发送，仍需用户选择设备。见 `client/android/app/src/main/AndroidManifest.xml`、`DockCoordinator.handleSharedIntent`。 |
| 设备列表 | GlobalSend 内部 `controller.dart` 的 `onlinePeers` / `sendablePeers` 会排除自身，后者还保留 30 秒离线宽限。中心 `GET /api/v1/devices` 需要 GlobalSend 设备凭据，返回当前组内设备；没有外部无凭据的本机查询 API。见 `server/src/server.ts` 的 `deviceView` 和 `/devices`。 |
| 定向文本 | `controller.dart: sendText(target,text)` 调用 `/texts`，按 targetDeviceId 投递。文本是中心事件通道，不走大文件的 LAN/公网/中继文件选路；不能宣称已经有 URL 的点对点最优传输接口。 |
| 打开浏览器 | `SystemBridge.openWebUrl` 已有 Windows Shell 启动与 Android ACTION_VIEW；当前由用户点击链接触发。接收坞也有调用入口。见 `client/lib/web_links.dart`、`NativeReceiveRuntime.java`、Windows `system_integration.cpp` / `receive_dock.cpp`。没有“收到特定远程意图自动打开并回报状态”的协议。 |
| 版本、去重、回执 | 现有文本 eventId 支持发送重试去重，但没有跨应用 requestId、open_url 能力协商、浏览器启动回执或本机调用方认证。不可用普通文本拼命令替代。 |

设备信任应表述为“属于当前组且未撤销”，不虚构另一套逐设备批准状态。外部列表只返回 deviceId、name、platform、online、lastSeen/离线宽限、能力与版本；不返回 token、组密码、证书私钥或完整内部 peer 对象。

## 推荐最小接口：本机版本化桥

不要让 Chrona 读取 GlobalSend 的文件、缓存或中心凭据，也不另开一个无鉴权的 localhost HTTP 服务。

- Android：新增显式绑定的 `IntegrationService`，用 Binder 调用身份取得 UID/包名，不相信请求内自报的 caller。Chrona 绑定该服务，使用异步回调收列表和状态。
- 本期没有 Windows 本机调用端；Windows 仅实现远端 open_url 接收与既有 Shell 启动，不新增管道。
- Android 首次关联为本机应用授权：GlobalSend 明确批准“拾时：读取本组设备 / 发送所选网页”，之后按系统取得的 UID → 精确包名 → 当前签名匹配关联。不能仅凭 caller 字符串、Chrona 自报证书或 Debug 证书本身放行；撤销、重装或签名变化需重新关联。不要求两应用共享签名。
- 身份输入由 Chrona 代理提供并拥有：候选 226 / 0.15.64，包 `com.donglan.chrona`，Debug 证书 SHA-256 `3f64d76960de8f2ee9705c2abd44f0d321851fda7edf9c6bc85d02f75b876770`，其出处 `E:/Programs/拾时 · Chrona/build/release-0.15.64-signature.txt`。这是联调候选身份，不是对任意同证书应用的授权；本轮不重复计算或读取签名材料。
- 能力入口 `hello` 返回协议版本、GlobalSend 版本、当前是否连接、`list_devices` / `send_open_url` 能力。旧版返回 unsupported，Chrona 可引导更新，不能假装成功或改成普通链接自动打开。

逻辑消息与两种平台传输解耦：

```json
{"v":1,"method":"list_devices","requestId":"uuid","refresh":true}
```

```json
{"v":1,"method":"send_open_url","requestId":"uuid","targetDeviceId":"stable-id","url":"http://10.x.x.x:8765/","expiresInMs":120000}
```

`list_devices` 复用当前组与刷新流程。结果明确 `online` 与短暂离线；接收端未公布 `openUrlIntentV1` 能力时不能显示为可自动打开。发送方只能选择列表中的明确目标，不支持客户端冒用其它组。

`send_open_url` 的 URL 只允许普通 HTTP(S)，不得含账号、LAN 会话 token 或配对码。本期仅传 Chrona 提供的那个实际绑定地址，不从 GlobalSend 网卡列表拼出替代地址。

## 远端意图和状态

新增有类型的 `open_url` 消息，携带 requestId、来源/目标 deviceId、明确调用方标识、URL 和期限；以现有组凭据及中心事件通道定向投递。所有普通文本、剪贴板、共享编辑和普通链接继续保持原行为，不能自动开浏览器。

- 去重键为来源安装身份/调用方 + requestId；同 ID 不同正文返回 conflict。接收端持久记录已处理请求和最终结果，重连不重复唤起。过期只回 expired，不补开浏览器。
- 本机调用应在约 5 秒内返回可用性/入队结果；之后异步状态查询或订阅，不能把网络等待挂在 Chrona UI 主线程。
- 状态使用 `queued`、`delivered`、`launch_accepted`、`needs_tap`、`failed`、`expired`。`delivered` 是远端应用确认收到；`launch_accepted` 只表示系统接受打开请求，**不等于浏览器已加载页面或完成配对**。
- Windows 可调用现有 Shell 浏览器入口，以系统接受结果返回 launch_accepted；不承诺页面加载或配对。Android 前台可 ACTION_VIEW；后台无法可靠确认启动时直接 needs_tap，提供可点击通知，不能把 ACTION_VIEW 无异常当作浏览器可见，也不反复自动拉起。Web/iOS 本期不宣布自动打开能力。
- 错误至少区分 `not_installed`、`unsupported_version`、`not_connected`、`caller_not_allowed`、`target_unavailable`、`invalid_url`、`expired`、`launch_failed`、`timeout_unknown`。超时不等同未送达；相同 requestId 可查询，不创建第二个自动打开请求。

## Chrona LAN 地址的可证明范围

Chrona 已说明：本期 URL 是实际绑定的非 VPN Wi-Fi/以太网私有 IPv4 + 8765；Host 严格校验该 IP:端口，网络变化撤销会话。

GlobalSend 探通的是自身传输端口/RTC 通道。即便两机文件互通，也不能证明接收设备浏览器能访问 Chrona 的 8765，更不能证明浏览器会绕过 VPN/代理。因此不替换 URL、不添加手机蜂窝地址，也不保证“最优文件路径”能用来浏览该页面。

Chrona 关闭 LAN 服务或网络改变后，不自动重发旧链接；状态查询继续使用原 requestId，不产生新打开意图。URL 不含 query / fragment 配对码。

若之后需要页面可达检查，必须由**接收端**对这一个实际 Chrona URL 进行独立、有界、只读检测，并区分原生探测与真实浏览器访问；Host 校验、浏览器代理和配对页面仍由 Chrona 决定。不改变 Chrona 手机确认和配对授权流程。

## 可执行交接

1. Chrona Android 负责显式绑定本机宿主桥和设备选择 UI；包名、候选签名和范围已对齐，不再等待 Windows 调用身份。
2. GlobalSend 新增本机桥、能力发布、open_url 定向消息和去重/结果回执；不改 Chrona LAN 配对。
3. 两端用同一 requestId 验收：正确目标、未选目标不唤起、普通链接不唤起、重复请求只开一次、过期/离线/Android 后台拦截状态真实；最后独立验收 Chrona URL 的浏览器可达和原有配对。

此文件保留设计依据和集成前基线；实际交付、部署与设备验收分别记录，不将中心上线等同于客户端已安装。

## Android 首次关联的推荐交互

`hello` 可报告版本、能力与 `authorization_required`，未授权时不返回设备列表。GlobalSend 的绑定服务根据 Binder UID 和 PackageManager 识别调用方，生成绑定该身份和本次请求的一次性关联动作；Chrona 在自身前台的显式操作中打开 GlobalSend 所提供的关联页面，不靠后台弹出绕过系统限制。

页面显示系统读取的拾时名称/图标和上述两项权限。用户批准后仅保存此本机关联，返回结果给原绑定会话；不交出 GlobalSend 组密码或中心 token。关联可在 GlobalSend 设置中撤销，撤销后列表、发送和该调用方状态访问一同失效。设备范围始终是 GlobalSend 当前组；本机批准不批准 Chrona 网页配对，也不获得通用文件或账户操作权限。
