# Android 本机集成 ABI v1

本机集成ABI已实现；真实跨进程绑定、首次关联、通知点击与系统浏览器页面在原共享AVD的1.0.31包上完成记录。55版在v1中兼容新增`send_link`，让iPad等不能自动打开网页的设备接收普通链接，原`send_open_url`不变。当前Windows/手机安装版本分开记录于 [快速测试](QUICK_TEST.md)，不把构建完成等同于手机安装。Chrona负责调用端和LAN页面，GlobalSend负责本机桥与组内定向投递。

## 绑定与消息

- GlobalSend 包 `dev.globalsend.globalsend`，显式服务 `dev.globalsend.globalsend.IntegrationService`。
- Android 平台 Messenger；请求 `Message.what = 1`、`Message.data["request"] = JSON字符串`、`Message.replyTo = Chrona Messenger`。
- 读取系统填入的 `Message.sendingUid`，不使用 Handler 调度时的 Binder.getCallingUid，也不相信 JSON 中自报身份。
- 响应 `Message.what = 1`、`Message.data["response"] = JSON字符串`。需要首次关联时，另附 `Message.data["association_intent"]`，类型为不可变的一次性 PendingIntent；Chrona 在前台显式打开，再用新 hello 查询关联结果。
- 本机 RPC 关联使用 `Message.arg1`：Chrona 每次调用分配本地递增序号，所有响应原样回显 arg1。它与幂等 requestId 分开，防止 status 沿用同一 requestId 时被前一次迟到回复误配。旧调用不设置时为0，JSON格式不变；arg1不参与权限判断或服务器幂等。
- `v=1`，`requestId` 为调用方 UUID。`send_open_url` 的 ID 同时是幂等意图 ID；`status` 使用相同 ID 查询。hello / list_devices 各使用自己的调用 UUID。
- 同一 ID 重试不创建第二次打开；同 ID 不同发送正文返回 conflict。最长期限120秒。
- 幂等操作身份为来源设备、requestId、targetDeviceId、规范化URL及callerAppId；expiresInMs不是身份字段。已有ID无论重试TTL更短或更长，均复用首次expiresAt、不延长有效期。

```json
{"v":1,"requestId":"uuid","method":"hello"}
{"v":1,"requestId":"uuid","method":"list_devices","refresh":true}
{"v":1,"requestId":"intent-uuid","method":"send_open_url","targetDeviceId":"device-id","url":"http://10.x.x.x:8765/","expiresInMs":120000}
{"v":1,"requestId":"intent-uuid","method":"status"}
```

响应统一外壳：

```json
{"v":1,"requestId":"uuid","ok":true,"result":{}}
{"v":1,"requestId":"uuid","ok":false,"error":{"code":"not_connected","message":"GlobalSend 尚未连接","retryable":true}}
```

### hello.result

```json
{"protocolVersion":1,"appVersion":"1.0.55","connected":true,"associationState":"authorized","capabilities":["list_devices","send_open_url","send_link"]}
```

`associationState` 为 required / authorized；未授权 hello 不泄露设备、分组或凭据。required 时 connected 为 false，并附上述关联 PendingIntent。拒绝或撤销后重新关联。用户批准的范围仅“读取本组设备 / 发送所选网页”。Chrona 包为 `com.donglan.chrona`；候选签名及绑定规则见 `CHRONA_INTEGRATION_DRAFT.md`。不能只凭 Debug 证书授权别的包。

### list_devices.result

```json
{"devices":[{"deviceId":"stable-id","name":"电脑","platform":"windows","online":true,"sendable":true,"capabilities":{"openUrlIntentV1":true,"sendLinkV1":true}}],"updatedAt":"2026-10-28T14:00:00.000Z"}
```

列表不含自身、撤销设备、凭据、peer证书或完整内部地址信息。sendable 复用现有在线/30秒宽限；online 明确是否当前在线。未支持自动打开的设备 capability=false，不能在 Chrona 显示成可自动打开。

### iPad 等设备：发送普通链接

`sendLinkV1`独立于`openUrlIntentV1`。Chrona优先按原`send_open_url`合同调用支持自动打开的设备；不支持自动打开时，只有hello声明`send_link`且目标声明`sendLinkV1=true`，才可使用下面的新调用。旧端没有新能力时，不猜平台或伪造支持；打开请求失败也不自动改发普通链接。

```json
{"v":1,"requestId":"uuid","method":"send_link","targetDeviceId":"ipad-id","url":"http://10.x.x.x:8765/"}
{"v":1,"requestId":"同一个uuid","method":"status","deliveryMode":"link"}
```

结果为`{requestId,targetDeviceId,deliveryMode:"link",state:"sent",createdAt,updatedAt}`。`sent`是链接发送成功终态，表示中心已接受，文案“链接已发送”；不表示iPad已读或浏览器已打开。iPad/Web沿用已有普通文本消息接收，收到后手动点击链接，不需要升级中心或iPad包。

普通链接不传`expiresInMs`、结果不含`expiresAt`，保留时长沿用现有文本策略，不套用自动打开命令的120秒期限。发送结果持久化在来源客户端；中心结果不明时，`status`返回`queued`并且不重发，界面可提示待确认。中心明确拒绝时，记录为`failed`并带`error`。用户显式重试时复用原`requestId`调用`send_link`，复用现有文本事件幂等；同ID不同URL、目标或本机调用方返回`conflict`。错误沿用v1外壳，超时为`timeout_unknown`，查询他方或缺失记录为`request_not_found`。已确认`sent`的记录不会因目标稍后离线而回退。

请求ID与操作种类一并持久化。`status`只有显式`deliveryMode:"link"`才查询普通链接记录；不带该字段的查询完全维持原自动打开合同。普通链接进入文本历史，自动打开意图仍不混入文本/文件历史。

### send_open_url.result / status.result

```json
{"requestId":"intent-uuid","targetDeviceId":"stable-id","state":"queued","createdAt":"2026-10-28T14:00:00.000Z","expiresAt":"2026-10-28T14:02:00.000Z","updatedAt":"2026-10-28T14:00:00.000Z"}
```

意图执行失败时，可另附 `error:{code,message}`。state 为 queued / delivered / launch_accepted / needs_tap / failed / expired。系统接受启动不代表浏览器页面已加载或已配对。Android 后台直接 needs_tap + 可点击通知；Windows 使用现有 Shell 入口。Web/iOS 暂不发布支持能力。

顶层错误至少支持 invalid_request / unsupported_version / authorization_required / caller_not_allowed / not_connected / target_unavailable / unsupported_target / invalid_url / request_not_found / conflict / timeout_unknown。retryable 表示同一请求可重查/重试，不代表更换 requestId 重复打开。

本机桥约5秒响应超时；若无法判定请求是否到达服务器，返回 timeout_unknown，Chrona保留原ID查询。列表/状态不得串给别的调用方。

## GlobalSend 内部桥（不向 Chrona 暴露）

Android Java 与 Flutter 使用 MethodChannel `dev.globalsend/integration`：

- Dart 安装处理器后调用 `ready`。原生在此之前排队本机请求，保持首次接收时间与回复通道；不把 Flutter 冷启动时暂未安装处理器当成请求已完成。
- Java → Dart `request`，参数 `{callerAppId:"com.donglan.chrona",receivedAtMillis:UTC毫秒,request:{...v1请求...}}`，结果为上述完整响应外壳。Java 校验 UID/关联；Dart 校验请求、当前组和权限范围，不接收组密码/token。首次POST前扣掉原生冷启动排队耗时；期限已耗尽时返回expired，不向中心创建或宣称入队。
- Dart → Java `openUrlIntent`，参数 `{requestId,sourceDeviceId,url,expiresAt,callerAppId}`；返回 `{state:"launch_accepted"|"needs_tap"|"failed"|"expired",error?:{code,message}}`。
- Java → Dart `urlIntentResult`，同一 requestId/sourceDeviceId 加 `state`、原生生成的 `resultId:UUID` 和可选 error，用于通知被点击后的回执。冷启动不得丢回执，需原生保存/重放。`openUrlIntent`直接结果也可附resultId。
- Dart → Java `pendingResults` 返回上述未确认回执数组；`ackResult` 参数 `{requestId,sourceDeviceId,resultId}`，中心确认后仅移除匹配resultId版本，防止旧needs_tap回执的迟到ACK删除新launch_accepted回执。`manageAssociations` 打开 GlobalSend 本机关联管理页。
- Java API 实现由 Android owner 所有；Flutter owner 只写 Dart，不编辑 Java/Manifest。

## 中心内部端点

由现有设备 Bearer 凭据保护，仅 GlobalSend 客户端调用：

- `POST /api/v1/url-intents`：body `{requestId,targetDeviceId,url,expiresInMs,callerAppId}`；返回上述意图状态对象。
- `GET /api/v1/url-intents/:requestId`：来源设备按自身 requestId 查询，结果包含 callerAppId，Dart 再隔离本机调用方。
- `GET /api/v1/url-intents/pending`：目标设备未过期待处理请求，返回 `{intents:[{requestId,sourceDeviceId,targetDeviceId,callerAppId,url,createdAt,expiresAt,state}]}`。
- `POST /api/v1/url-intents/:requestId/result`：目标设备 body `{sourceDeviceId,state,error?:{code,message}}`；返回状态对象。
- WebSocket 提示 `{type:"url_intents.changed"}`；来源刷新状态，目标拉取 pending。持久意图不混入普通文本/文件卡片。
- `/info.features.openUrlIntents=true`。现有 `/devices/me/capabilities` 可选字段 `openUrlIntentV1`，`deviceView` 暴露同名 bool。旧调用不提供字段时不能抹掉已经发布的能力，不新增旧调用必填前置。

时间、同组/目标能力校验、期限、幂等和结果状态转换由中心拥有；目标端持久记录处理/结果，重连不重复唤起。URL仅HTTP(S)、无userinfo；Chrona只发送其实际LAN URL，不含配对query/fragment，不从GlobalSend地址拼接页面地址。文件传输可达不证明8765浏览器可达。
