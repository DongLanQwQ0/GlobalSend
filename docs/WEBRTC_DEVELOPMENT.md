# WebRTC 开发与验收

新版源码让浏览器与原生客户端直接传文件，原生之间优先保留 HTTPS。自动顺序为局域网、公网、中继；手动 LAN / 公网失败不会改走中继。运行版、部署版和 reverse-direct 冻结包未切换。

## 已验证的文件链路

Windows 原生生产 `RtcFileTransport` 与浏览器生产 `RtcFileChannel`、OPFS Worker 通过真实本地中心完成双向传输：

| 方向 | 文件字节 | 起始断点 | 结果 |
| --- | ---: | ---: | --- |
| 浏览器 → Windows | 1,049,307 | 12,345 | 原半文件续传，逐字节一致 |
| Windows → 浏览器 OPFS | 1,049,307 | 12,345 | 磁盘文件完整，SHA-256 一致 |

两项中心状态均为 `received/direct`，中心 offset 与实际中继文件字节均为 0。使用实际本机网卡候选，无外部 STUN / TURN；这项证据不代表真实跨公网或 iPad 已通过。日志：`artifacts/logs/rtc-production-native-browser.log`；完整结果：`artifacts/tmp/rtc-production-interop/run-I62WNu/result.json`。

同一生产链路另已通过双向零字节文件，日志 `artifacts/logs/rtc-production-native-browser-empty.log`。可在联调命令后加 `--empty` 复现。

## 传输与文件生命周期

- 中心只交换已接受文件的 SDP / ICE，同组非参与者不可读取。协商不写入持久事件；服务重启后重新协商。
- 可靠、有序的 `globalsend-file-v1` 数据通道；16 KiB 二进制块，最多 512 KiB 未提交窗口。没有媒体轨道，也不调用摄像头/麦克风。
- `ready` 指定原断点，`ack` 表示磁盘提交，`end` 表示源字节结束，`complete` 仅表示全部字节已落盘。接收方另做完整性校验与原有 `/received`，发送方不能将 `complete` 显示成已保存回执。
- 换阶段或取消先关闭通道、等待旧写入完成，再复用同一个半文件。原生沿用接收目录及 SAF lease，不新增第二份永久文件。
- 浏览器在专用 Worker 中直接写 OPFS，不把整个接收文件装入内存；完成后点击下载交给浏览器。浏览器私有存储不是任意用户文件夹，用户另行下载的副本不受网页自动清理管理。
- SDP 去除内嵌 ICE，双方按阶段筛选 trickle candidates；局域网含私网、mDNS、ULA，以及与本机同 `/64` 的 IPv6 候选。候选分类是选路提示，连通性仍由 ICE 实际检测。

## Web 本机文件库

新版 Web 用两列网格列出当前浏览器、当前站点已保存的文件。退出或切换分组仍可查看；不同中心若属于不同 origin，其浏览器私有存储不能互读。库只枚举本应用已完成接收的 OPFS 文件，不把半文件当成成品，也不复制文件数据。

- 默认最新接收排序，可选最早、名称或大小；长按整卡进入编辑，可重命名、删除。
- 图片可预览；常见 UTF-8、UTF-16、GB18030 文本只读查看、复制。超过 8 MiB 时预览前段，按钮明确为“复制预览”，不冒充全文。
- 转发必须明确选择当前在线设备，保留不确定请求的同一 offer 身份以便重试。换组不自动发送旧文件，未登录时不提供转发。
- 自动清理默认一天，可设小时/天、类别、严格大于/小于 MiB。规则按当前站点保存在本机，作用于既有已收文件；不匹配规则的文件保留。下载到浏览器下载目录的副本不受此清理影响。
- 库中删除或清理后，接收坞同步失效旧缓存；下载时重新核对真实存储，不继续使用已删除文件的旧引用。

55 项定向检查及隔离 Web 构建通过。根使用真实主入口、OPFS Worker、两个实际分组和独立 Edge 完成跨 scope 枚举、未登录查看、两列布局、文本查看/复制动作、真实下载、重命名、图片解码、长按、当前组转发、时长/类别/大小清理与删除最后一项。复制动作使用隔离 stub，不操作系统剪贴板。日志 `artifacts/logs/web-library-real-opfs-final.log`，结果 `artifacts/tmp/web-library-acceptance/run-vvC4bB/result.json`。

Web 候选在 `artifacts/candidates/web-library/`，不是当前运行的 `web/dist`；iPad Safari 的文件库与下载仍需实机验收。

## 复现独立联调

在项目根目录执行，需现有 Flutter / MSVC / Edge。生成文件、浏览器独立 profile、合成身份与日志均留在项目内；不使用当前产品数据或浏览器标签。

```powershell
node scripts/build-rtc-probe.mjs --transfer
node web/tool/accept_rtc_native.mjs
# Web 文件库：真实主入口、OPFS、独立浏览器与合成分组。
node web/tool/accept_saved_library.mjs
```

构建脚本从 `client/tool/rtc_transfer_probe.dart` 生成隐藏的独立 Flutter 消费者到 `client/build/rtc-transfer-probe/`。联调入口重新构建自己的 Web fixture，启动随机端口中心和 headless Edge，结束后只关闭本次启动的进程。

更早的纯数据通道探针保留为 `node scripts/build-rtc-probe.mjs` 和 `node web/tool/probe_webrtc_native.mjs`；它只验证插件互通，不替代上面的生产传输检查。

## 部署与尚待验证

中心 `STUN_URLS` 默认空，仅使用 host candidates。需要 IPv4 NAT 公网候选时，部署者可显式配置 STUN；不接受 TURN，失败仍按现有 HTTPS 中继策略处理大文件确认。STUN 只帮助发现映射，不保证穿透成功。

Docker 已提供可选 `stun` profile：固定 coturn 官方镜像，以 STUN-only 模式仅发布 UDP 3478，不开放 TURN 文件中继。启用、三层检查和关闭命令见 [部署说明](../deploy/README.md)。Compose schema 与精确版本参数静态检查通过；开发机没有 Docker，容器启动和公网 UDP Binding 尚未验证，当前服务器未部署此服务。

Android 新增项目自有 data-only 适配器：局域网及未授权公网 attempt 使用非蜂窝 factory；只有公网阶段且本机蜂窝开关已开启的 attempt 才允许蜂窝，并持有独立 `requestNetwork` lease。关开关等待相关 native create、文件写入、通道和 lease 全部结束，其他非蜂窝会话保持。系统与中心控制连接不做全进程网络绑定。

被动监测器只观察网络，避免底层默认监测器暗中保活蜂窝。进程级初始化与 Activity / engine 的 factory 生命周期分开；Android 不再调用会遗留 initializer factory 的插件初始化。Windows 沿用插件，完整 teardown 按 dispose / close 幂等执行。实际 selected-pair 的网络类别及 IPv4 / IPv6 反馈到界面，无法识别时不冒称蜂窝。

11 项 Dart 回归、7 项 Java / Robolectric 回归及 Android 编译通过，analyze 无问题；日志在 `client/build/logs/{test-rtc-cellular-final,android-rtc-network-final,analyze-rtc-cellular-final}.log`。独立审核定位的关闭 owner 漏等、Windows 双 close 和跨 engine 初始化问题均回到原 owner 修复。新抽象下 Windows ↔ 浏览器双向续传通过，见 `artifacts/logs/rtc-network-policy-windows-interop.log`。

**Android JNI 真机数据通道、蜂窝 IPv6 和实际网络切换仍待验收**。策略及生命周期检查不能替代这些网络证据，Windows ↔ Edge 结果也不能代替 iPad Safari。

公网已上线group-password中心/Web，Windows1.0.1已启动；Android1.0.1按架构本地提供，尚未安装到真机。iPad Safari / vivo、校园 Wi-Fi、IPv6和蜂窝路径仍需对应真实环境验收。前台周期RTC轻量探测正在独立开发中，不因源码变化自动替换当前运行版本。
