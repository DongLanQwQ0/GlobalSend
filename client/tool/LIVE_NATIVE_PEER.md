# 真实设备消费的 headless peer

`live_native_peer_test.dart` 使用原生 `SendController` 和 `PeerTransport`，经公网中心注册独立的 `Windows headless network probe`。候选来自真实 `NetworkInterface`，文件流走实际 HTTPS、pin、nonce 和中心单次票据；不代替 Windows 桌面 GUI、DPAPI 或真机验收。

它只读取项目根 `artifacts/live-device-session.json` 的测试中心地址和 groupKey，凭据使用进程内 FixtureVault。不要输出 groupKey、identity token 或控制 token。状态、合成样本与接收文件留在 `artifacts/live-native-peer/`。

在 `client/` 中使用现有 F Pub cache 与项目 TEMP/TMP 执行：

```powershell
$env:PUB_CACHE = 'F:\Caches\PubCache'
$env:TEMP = (Resolve-Path 'build/tmp').Path
$env:TMP = $env:TEMP
& 'E:\Programs\flutter\bin\flutter.bat' test --no-pub --reporter expanded tool/live_native_peer_test.dart
```

注册后写出 `artifacts/live-native-peer/control.json`，只在 stdout 提示这个文件路径。进程会等待消费者明确请求停止，超时四小时；不要把工具最终答复当成允许关闭它的依据。

## 控制接口（仅 loopback）

每次请求从 `control.json` 私下读取 `controlUrl` 和 `controlToken`，将 token 放 `x-live-peer-control` 头，不放 URL。

| 请求 | 用途 |
| --- | --- |
| `GET /status` | 连接、实际候选、同组设备、文件状态/路由/失败原因；不返回设备 token、文本或 groupKey |
| `POST /offer` | JSON `{targetDeviceId,routePreference,kind}`，显式触发发送，不自动选择手机 |
| `POST /peer/close` | 关闭真实 listener，停止发布心跳；中心尚未过期的候选可用于不可达回退观察 |
| `POST /peer/reopen` | 使用同一内存身份重新监听、发布当前真实地址和新端口 |
| `POST /stop` | 消费完成后明确停止控制服务与客户端连接 |

`routePreference` 为 `auto / lan / public / relay`。`kind=multi` 包含中文名的 2,621,441 字节样本、中文文本文件与零字节文件；`large` 和 `empty` 可单独发送。每次 offer 的 IDs 与模式记录在 `offers.jsonl`，方便公网 referee 对账。

本工具不修改防火墙、网络路由、蜂窝授权或系统服务，不调用 GUI/adb。地址存在/已发布不等于可达；没有真实公网成功时，记录实际失败和中继，不填造公网候选。设备操作、接收模式选择以及停止时机由主代理管理。
