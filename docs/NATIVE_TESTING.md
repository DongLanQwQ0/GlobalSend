# 原生客户端：运行与验收

当前Windows和Android为 **1.0.55+66**，本地完整包与手机均已更新；iPad手动安装包保持1.0.53（62）。当前安装、发布和验收状态见[短步骤](QUICK_TEST.md)，剩余实机项目见[验收清单](UI_ACCEPTANCE.md)。本文下方保留初轮开发记录，其中的版本、端口、模拟器和构建路径仅适用于当时，不作为当前操作入口。

## 运行 Windows（1.0.1历史入口）

源码：`client/`。Release 目录中的 EXE、DLL、data 文件夹需要一起保留，不能只复制 EXE。以下为1.0.1隔离构建入口；已有窗口时不要重复启动：

```powershell
$env:GLOBALSEND_DATA_DIR = 'F:\Codes\Java\GlobalSend\artifacts\native-state'
& 'F:\Codes\Java\GlobalSend\client\build\group-password-1.0.1\windows\x64\runner\Release\globalsend.exe'
```

项目验收使用这个环境变量保存配置、游标、接收坞、文件引用及凭据密文；默认接收目录也在项目内。未设置时，状态使用系统应用目录；用户可在“设置 → 存储”另选接收位置。密文不能当作跨机器可移植备份：Windows DPAPI 绑定当前 Windows 用户，Android 私钥存在系统 Keystore。

首次地址已预填 `https://123.207.180.163/globalsend`，仍可自定义；名称自动获取，填写至少十位组密码即可连接。相同中心、相同密码直接同组，无邀请码、配对或建组确认，已有登录自动恢复。本机开发中心可显式允许HTTP并填写 `http://127.0.0.1:8787`；已有中心和正在编辑的地址不被默认值覆盖。不要在报告/截图中展示组密码。

## 已实现的路径

- Dart `HttpClient` / WS 负责中心控制通道：一次性 WS ticket、心跳、抖动重连、游标补收；不通过 WS 传文件。
- 独立文本条目保留全文，复制只复制该条；同一事件重放不重复入坞，不吞掉人工重复发送。发送超时保留事件 ID 供再次提交。
- 默认同组自动接收保存，接收坞开关可切回逐项勾选确认；未选文件被拒绝，各文件独立进度、取消和失败重试。最多两个接收/上传工作并行；其他文件排队。
- 中继采用中心确认 offset 的分块上传。下载流式写 `.part`，检查大小和 SHA-256 后改名，再提交 received；损坏文件不确认、不显示为可用成品。
- 原生 sender 建立双栈 HTTPS listener，向中心发布带有效期的候选地址和长期证书身份。receiver 精确 pin 中心返回的 X509 DER SHA-256，做随机 nonce 挑战，再持单次票据拉取。sender 必须向中心验证票据后才能给出文件字节。
- 原生自动接收依次尝试局域网、公网、已授权蜂窝公网，再回退中继；手动指定路径失败不降级。发送端不再用八秒计时器抢先选中继，peer 传输不并行占用中继字节。
- Android 用户打开“允许蜂窝传输”后，默认网络直连失败才尝试 Java 蜂窝路径：获取一个 cellular `Network`，用同一个 Network 做 DNS、TLS/challenge 和真实下载。不绑定整个进程；控制通道保持原网络。Java 直接流入磁盘并发送进度，不通过通道搬运文件块；蜂窝直传不设流量上限。
- 取消会中止本地下载/peer 源流并通知中心。peer 和中继支持 Range/If-Range 恢复，最终大小与摘要通过后才确认；已确认的其他文件保持可用。
- Windows 打开及 Explorer 定位文件；Android 调用本机文件处理应用。接收文件名由本机安全处理，不接受远端绝对路径。

## 安全约束

中心连接始终使用正常 CA、主机名及有效期校验；没有全局忽略证书错误。仅 peer 客户端在隔离的 TLS context 中接受配对范围内中心提供的精确证书。Java peer 同样检查 DER 指纹和有效期；中心 bearer 不发送到 peer。当前信任中心参与配对与分发身份，不是端到端加密系统。

Windows 使用 `CryptProtectData/CryptUnprotectData`；Android 使用 non-exportable AndroidKeyStore AES-GCM key。文件中只保存受系统保护的密文，应用状态不保存明文 token 或私钥。证书/私钥按中心独立保存，不能每次启动重生；当前自签证书有效期 365 天，身份更换需撤销旧设备后重新配对。

## 已有证据

2026-10-24 本地工具链记录：

- Flutter 3.47.2 / Dart 3.13.2；Windows MSVC Build Tools 2022 可用于 Release。
- `flutter analyze`：无问题。
- `flutter test --concurrency=1 --dart-define=SCREENSHOT=true`：9 项通过。涵盖 URL 前缀/凭据隔离/拒绝重定向、重放幂等、手工重复文本独立、损坏文件不 ACK、真实 loopback HTTPS peer 精确 pin/nonce/单次授权/300 KB 流式传输，以及桌面/390 px 布局和全文操作。
- Windows Release 已成功构建。最终桌面 UI 与跨 Web 联调由主代理在交接 build 上执行，不能把组件截图当作实机验收。
- `MainActivity.java` 使用已有 Android 36 `android.jar`、Flutter embedding JAR 和缓存 AndroidX，通过 `javac --release 17 -proc:none` 类型编译。这个检查不等于 APK 构建或 Android 运行成功。
- APK 构建未通过：模板 Gradle 9.3.1 wrapper 下载两次超时；另用已有 F 盘 Gradle 9.6.1 离线缓存尝试，缺少 `org.jetbrains.kotlin.jvm:2.2.20`。未替换 wrapper，未接受 SDK license，未安装或升级系统工具。缓存版本替代尝试不视作原 wrapper 通过。

截图 `client/build/client-preview-review.jpg` 为组件实际布局，使用本机中文和 Material 字体；它不证明真实平台文件选择器、DPAPI/Keystore 或跨网路由成功。

## 重跑命令

在 `client/` 中设置本次命令的 `TEMP/TMP=client/build/tmp`；测试临时目录为 `client/build/test-tmp`，截图/日志放 `client/build`，不使用用户全局临时目录。新增可复用工具链缓存使用 `F:\Android\GradleCache`；不迁移已有缓存，不改全局环境变量。

```powershell
New-Item -ItemType Directory -Force build/tmp | Out-Null
$env:TEMP = (Resolve-Path build/tmp).Path
$env:TMP = $env:TEMP
$env:PUB_CACHE = 'F:\Caches\PubCache'
$env:GRADLE_USER_HOME = 'F:\Android\GradleCache'
& 'E:\Programs\flutter\bin\flutter.bat' analyze
$previousDataDir = $env:GLOBALSEND_DATA_DIR
try {
  $env:GLOBALSEND_DATA_DIR = Join-Path (Get-Location).Path 'build/test-tmp/startup-command'
  & 'E:\Programs\flutter\bin\flutter.bat' test --concurrency=1
} finally {
  $env:GLOBALSEND_DATA_DIR = $previousDataDir
}
& 'E:\Programs\flutter\bin\flutter.bat' build windows --release
```

需要 Android build 时使用已有 SDK `F:\Android\Sdk`、实际 Java 22.0.2（目录名 `D:\Minecraft\java21`）、`GRADLE_USER_HOME=F:\Android\GradleCache`。先解决下载依赖和 license 条件，禁止用源码编译结果代替 APK。

## 初轮设备/真实网络清单（历史）

1. Windows↔Web 实际配对、文本双向、真实多文件选择/打开、重启后密文解密与接收坞恢复；切中心不串 token/文本/任务。
2. Android APK 构建后，在明确授权的设备验证文件管理器 content URI、Keystore、打开文件、拒绝权限、取消及旋转/前后台恢复；本轮未安装或探测手机。
3. vivo 的 Wi-Fi/蜂窝并存，校园 Wi-Fi 无法到 PC IPv6 但蜂窝可达；记录实际 Network handle、IPv4/IPv6、超时和路径，不把官方 API 存在写成 vivo 已验证。
4. PC IPv6 变化、校园入站过滤、Windows 防火墙阻断、手机蜂窝关闭；均须明确失败原因并保持中继可用。不要为验收擅自改防火墙。
5. 断网/中心重启/源文件改动/磁盘不足/同名中文零字节文件，逐文件恢复且不确认损坏文件。
6. iPad Safari 仍属于 Web 侧实机范围；原生进度及类型检查不能证明 Safari 下载落盘或后台常驻。

该初轮未进行真实设备安装、校园网探测、Windows 防火墙修改或系统 license 接受；后续证据与当前缺口见文末。


## 2026-10-25 源码交接：暂停验证后的变更

> 以下为历史交接记录。2026-10-26已按用户要求移除悬浮接收坞和SYSTEM_ALERT_WINDOW权限；原生应用内拖放、分享导入和独立后台接收继续保留。旧浮坞的启停/权限验收不再适用于当前源码。

用户要求先开发、稍后测试。本节之后未运行新的 analyze、test、build、设备或浏览器验收。上面的旧记录仅针对当时版本，不能覆盖当前源码。

### 产物与执行状态

- 旧 Release `client/build/windows/x64/runner/Release/globalsend.exe` 与主代理启动的 PID 28800 保持原样；本轮未关闭窗口、未覆盖产物。旧产物不含当前分组密钥、逐项接收及本节新能力。
- 暂停时本代理 Android Gradle 运行句柄 32697 已用 Ctrl+C 终止（exit 1），没有留下继续运行的本代理测试或构建；不终止其他项目 Gradle。
- 之前另有真实中心双 Dart 控制器集成三项通过：同 key 入组、不同组拒绝、真实 WS 双向文本、约 1.2 MB pinned HTTPS direct 和 peer 关闭后的 relay+最终 received。其证据在 `client/build/test-tmp/full-stack-bb0b3e97`；它不覆盖暂停后新增源码。

### 当前源码可调用链路

1. `screen.dart → controller.dart`：默认 groupKey 入组、强密钥生成、轮换、退出、同中心切组清理；逐项文件接收与品牌资源。
2. Windows `DropTarget → stageInputs → sendStaged → offer/texts`；接收图标手势 `dragOut → SystemBridge → system_integration.cpp → OLE`。新成品路径按 profile/device/file 分目录，basename 为安全原名；旧保存路径继续可用。
3. Windows 显式同步开关 `setClipboardSync → clipboardWatch → WM_CLIPBOARDUPDATE → /texts clipboard:{}`；接收事件经 origin/root 去环后私有写入。自动条目内存保留、过期清理、不写历史。分组密钥复制走 `SystemBridge.copy(private:true)`，不进入自动同步。
4. Android 权限/启停按钮 `dockCommand → DockCoordinator → ReceiveDockService`；Flutter 收包后限频更新已有服务。hide/restore/stop 和撤权处理；不创建第二通信引擎。系统拖放与分享导入到应用私有目录、暂存、明确确认发送；拖出经短时只读 DockShareProvider URI。
5. 中继与 peer `.part → Range/If-Range → 200重写/206校验 → 最终size/hash → rename → received`。ETag 精确 `"sha256-<64hex>"`；每次网络重试新取一次票据，中心上传偏移与本地 receivedBytes 分开。

### 后续获准时再做的验证

- 先解析新增精确依赖 desktop_drop 0.8.4，更新 lock/生成平台注册文件；当前未运行 pub。依次进行 Dart/Java/C++ 编译与针对现有路径的检查，不把旧 Release 当新源码通过。
- groupKey：同中心退出→不同 key 加入不残留旧 target/队列/游标；轮换与撤销是不同动作；旧令牌仍合法的设备保持会话。
- Windows 拖入文件/纯文本/目录拒绝；拖出中文及同名文件保留 basename、Escape取消、拒绝目标不移动原文件。
- Windows 自动同步关闭时无正文读取；开启只对选中目标，新复制重复同文仍发送；远端回环抑制、快速复制节流、秘密标记、密钥生成前后复制、切组/断线/关闭行为、5分钟内存清理。
- Android 浮坞权限拒绝/撤回、通知拒绝、前后台切换/引擎销毁、不自动后台拉起；隐藏恢复关闭；标准共享与content URI授权过期、超限、磁盘不足；vivo与目标应用真实拖入/拖出。
- Range：中断后重启/重试保持partialPath与本地字节；200重写、206错偏移/错ETag拒绝、416满长后仍校验hash；peer默认网络→蜂窝重取票，失败→relay；损坏完整文件不可received。

APK、Windows 新源码构建、上述高级系统交互以及 vivo/真实校园网仍待后续授权验收。独立后台常驻收包、OEM 私有 vivo 协议未实现，不列作仅待验证。

## 2026-10-25：打开即用及手动选路源码交接

本节新增代码仍未执行 analyze、test、build、pub、GUI、设备或网络验证，未替换旧 Release、未操作运行窗口。

- `ServerProfile` 新增 `autoReceive`（默认 true）、发送及接收路径偏好；`recent-center.json` 记录最近中心 key。启动先匿名核对实例再加载该中心 token，失败十秒后重试，不把旧 token 发给重装实例。已有旧 profiles 可恢复最后一个已登录中心；显式退出后不偷偷改连另一个中心。
- `screen.dart` 首次可一次填写中心、名称和 group 密钥并提交；已登录设置折叠。默认同组自动接收/保存，不自动打开；开关关闭后保留逐项选择。发送区拖放在工作中禁用，防并发 perform 意外解锁待发移除。
- `reconcile → acceptSelected → updateTransfer → receive` 领取 offered 项，领取锁按 generation/transfer 避免并发重复；只领取当前认证设备的入站批次，不再领取拒绝/取消/过期项。ready 中继和已同意 direct 项自动进入保存，失败保留重试及取消。没有把没有设备授权的匿名请求变成自动接收。
- 发送 `routePreference:auto|lan|public|relay`；自动模式省略字段兼容旧中心，手动模式要求 `features.routePreference`。`DockEntry` 保存发送方约束、已选本机接收模式、attemptId、实际路由、原因和错误；发送方非 auto 为硬约束，本机偏好不能覆盖。每次操作捕获模式，设置不改写在途任务。仅本机偏好手动且发送方 auto 的失败项提供“改为自动并重试”。
- 发送条目的“换路径重发”菜单复用 `sources[fileId]` 与保存的目标设备，取消旧单项后产生新 transfer/file ID 和指定模式，不重新选择文件、不改同批其他项。autoReceive 同组重连保留，groupId 变化重置 true；发送/接收路径偏好按中心保存。旧 offer 约束不可改写，接收端不能用自动重试绕过发送方约束。
- `PeerTransport.candidateStages → _pullByStages` 串行 LAN、默认网络公网、已授权蜂窝公网；各阶段内部有界探测，成功后传文件。设备 pin、nonce 和一次性票据保留，每次阶段/网络更换新取票。自动模式最后才 `/relay`；手动 LAN/public 不自动降级，relay 不探测直连。移除发送方八秒强制中继，避免抢跑 LAN/public 探测。Java 使用调用方筛选的公网候选，探测与文件绑定同一 Network，探测阶段预算约七秒并接入取消。
- 候选发布不让大量私网接口挤掉全部公网；私网/IPv6 同前缀仅作为先试顺序，真实连通仍由 TLS 与挑战建立。未实现自动 NAT 穿透或 UPnP；没有真实公网候选时显示原因后按自动策略中继。窗口路径标签取实际阶段，不把 Safari 中继算作原生 IP 直连。
- `sendText/offer/enroll/adoptEnrollment` 延续会话守卫；补收保存/ACK 与迟到的认证失败也不修改新会话。剪贴板显式开关去掉重复确认弹窗，仍不默认启用；系统权限与敏感内容/来源去环保留。

后续恢复验证时，重点覆盖：冷启动已有登录、中心离线后恢复及实例变化、一步入组失败重试、自动接收与手动开关/取消/重放、LAN 与公网同时可达仍先 LAN、LAN 失败→公网→中继、公网默认网失败后仅在授权时用蜂窝、所有手动模式禁止静默改路、旧中心 capability 缺失、在途修改偏好/重启恢复、发送方与接收方设置冲突，以及分块/断点最终摘要。当前不以源码链路代替这些实际证据。

## 2026-10-25：恢复验证后的有效证据

用户已授权恢复构建和测试。本节为当前候选的证据，前面的暂停记录保留为历史。

- `flutter pub get` 完成 `desktop_drop 0.8.4` 与对应 lock/平台注册更新。分析修复了 `HttpConnectionInfo.localAddress` 不存在的真实编译错误，以及 widget mock 的新增可选参数签名；最终 analyze 无问题。
- **18 项测试通过**，日志 `client/build/logs/test-convenience-final.log`。真实隔离中心/两控制器以临时端口运行，证据目录 `client/build/test-tmp/full-stack-c7ccc3ad`：双向 WS 文本，约 1.2 MB pinned HTTPS LAN 自动接收并完整保存；关闭自动接收保持 offered、明确接受后保存；peer 关闭后 LAN 不可达且无公网候选，自动回退 relay；发送方 manual LAN 失败保持 direct、没有中继字节；“换路径重发”取消旧单项、复用原文件以新 relay offer 完成。
- 范围检查另覆盖：最近中心自动恢复、重装实例不收到旧 token、保存等待期间切服不发送旧文本、迟到 401 不撤销新会话；peer 从 12,345 字节的 `.part` 经真实 TLS/ETag/Range 追加到 300,000 字节；relay 匹配 206 追加、200 覆盖和错偏移拒绝；损坏文件不 ACK，手动选择及桌面/390 px 组件布局。公网成功、Wi-Fi/蜂窝真实路由不在这些 loopback 证据内。
- **标准 Windows Release 构建通过**，日志 `client/build/logs/windows-release-final.log`。完整冻结包 `artifacts/releases/windows-validated-20261025-100514/` 与同名 `.zip`；包含未检测中心时“连接后读取中心的建组规则”文案修正。旧 Release 已完整备份至 `artifacts/releases/windows-before-validation-20261025-094810/`。主代理拥有后续 GUI 启动、实际拖放/复制及跨 Web 验收。
- 本次首次 pub 解析的新 `desktop_drop/universal_platform` 曾落默认 C 缓存，已移到 `F:\Caches\PubCache`；只复用本项目所需的旧依赖及其包管理器 metadata 到 F，没有迁移整个旧缓存或更改全局环境。后续命令显式使用 F Pub 缓存，TEMP/TMP/测试数据仍在本项目。
- Android 原始 wrapper 指定的 **Gradle 9.3.1-all** 已取得并通过官方 sidecar 传输完整性检查，未换 Gradle 版本。NDK **28.2.13676358 / r28c** 官方 Windows ZIP 按 Google repository 校验后安装到 `F:\Android\Sdk\ndk\28.2.13676358`，旧 27 保留。已读取该包 `android-sdk-license`（2019-01-16）；sdkmanager 使用既有许可进入下载，没有接受新许可或执行全量 yes。Java 代理下载实际停在 HTTP 读取，改用同一官方分发的直接下载；NDK按独立 ZIP 方式安装，不声称 sdkmanager 操作完成。

- 项目插件实际需要 API 34（open_filex）、35（jni/jni_flutter）、36（desktop_drop）。新增缺少的 `platforms;android-35` 与 `platforms;android-34` 后，**原标准 wrapper APK Release 构建成功**（333.3 秒），日志 `client/build/logs/android-release-platform34.log`；没有用已有更高 Gradle 替代。原产物 `client/build/app/outputs/flutter-apk/app-release.apk`，交付副本 `artifacts/releases/GlobalSend-1.0.0-android-public-default-debug-signed.apk`，56,864,618 字节。release 配置沿用模板 debug signingConfig，既有签名凭据未更换；这是自用调试签名安装包，不是商店正式签名。
- 公网默认地址采用 `const String.fromEnvironment('GLOBALSEND_DEFAULT_CENTER', defaultValue: 'https://123.207.180.163/globalsend')`。该最小 UI 改动后只补受影响检查：analyze 无问题，五项 widget JSON 报告全部 success（`client/build/logs/test-default-widget-debug.log`），包括默认地址、已保存自定义中心优先、异步加载不覆盖用户输入。组合运行 widget 与非 widget startup suite 两次出现 `did-not-complete`，未定位组合 harness 原因；未将它写成产品断言通过。此前 18 项完整通过仍是未改传输/存储逻辑的有效证据。
- 最终含默认地址的 **Windows 标准 Release 重构成功**，日志 `client/build/logs/windows-release-default-center.log`，冻结完整包 `artifacts/releases/windows-public-default-20261025-101658/` 与同名 `.zip`。最终 APK 使用相同默认地址源码。

用户实体 Escape 后曾停止界面与手机操作；下节记录后来恢复授权后的当前结果，以上暂停状态只代表当时。

## 2026-10-25：紧凑界面与中继流量确认

### 当前使用方式

- 手机默认「接收」，底栏切「发送」；Windows 左侧发送、右侧接收。已登录时不再堆叠连接表单和功能说明，服务器、设备、自动接收、手动路径、剪贴板和浮坞收进右上「设置」。首次连接只填服务器、设备名称、分组密钥；旧协议和明文开发选项折叠在「更多」。
- 文件显示「待接收 / 接收中 / 已保存 / 已送达」与实际路径「局域网 / 公网 / 中继」。完成条目不再显示进行中的说明。文字保持独立条目，可复制、展开、多选合并复制。
- 大文件直连失败后显示「需中继」，点「改用中继」才请求中继。默认阈值 **32 MiB**，设置可改，按单文件判断。发送方强制中继不代表接收方同意大流量：含超阈值文件的中继批次整批等「接收」，避免 `/accept` 把暂未同意的大文件误拒。明确选择本机中继路径表示本机同意；已经待确认的旧条目不会因改设置或重启自动放行。
- 「允许蜂窝传输」不设字节或文件大小上限，按已保存中心持久化；新设备默认关闭。中继阈值不限制局域网、公网或已授权蜂窝直连。取消/拒绝条目不会被重放复活。

### 字体与实际渲染

`client/assets/fonts/` 内置 GlobalSend Sans Regular/Semibold（共 4,699,652 字节，每字重 7,812 个字符），从官方 Noto Sans SC 生成静态子集，覆盖 GB2312、拉丁、数字、中文标点及源码界面用字；收到的罕见字符由平台字体补齐。Flutter 和 Android 浮坞主文字均使用资产字体，不随 vivo 手写主题改写。原始 OFL 1.1、来源及生成信息随资产交付；派生名不使用上游保留名称 Source。可复用原字体保存在 `F:\Caches\Fonts\NotoSansSC`，生成脚本 `client/tool/build_ui_fonts.py`。上游许可：[Google Fonts / Noto Sans SC OFL](https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/OFL.txt)。

已检查 390×844 手机与 1280×900 桌面的真实组件渲染，主代理也已查看并通过该方向。压缩预览：`client/build/compact-mobile.preview.jpg`、`client/build/compact-desktop.preview.jpg`。这些是组件渲染，不代替 vivo/Windows 实际窗口验收。

### 当前候选证据

- `flutter analyze --no-pub` 无问题，日志 `client/build/logs/analyze-compact-final.log`。
- 完整 **24 项测试通过**，日志 `client/build/logs/test-compact-final.log`；本次完整组合运行正常结束，未再出现旧 harness 的 did-not-complete。包括真实隔离中心、双控制器、WS 文本、pinned TLS LAN、不可达回退、手动不降级、Range、会话切换，以及新中继确认和布局测试。真实中心证据 `client/build/test-tmp/full-stack-6a20acfb`。
- `relay_consent_test.dart` 覆盖大/小中继混合批次整批保留、序列化/重放/偏好变化不绕确认、超阈值自动直连失败不请求 relay、小文件自动回退、显式确认后请求一次 relay、取消不复活、蜂窝与阈值持久化。阈值 fixture 用 1 MiB，不生成无用大文件。
- 新 APK 标准 wrapper Release 成功（40.8 秒），日志 `client/build/logs/android-release-compact.log`。冻结文件 `artifacts/releases/GlobalSend-1.0.0-compact-ui-android-debug-signed.apk`（60,796,053 字节）；沿用模板 debug signingConfig，仍是自用调试签名，不是商店正式签名。旧 APK 与旧 Windows 冻结包保留供回退。
- 新 Windows 标准 Release 成功（26.0 秒），日志 `client/build/logs/windows-release-compact.log`；完整包 `artifacts/releases/windows-compact-ui-20261025/` 与同名 `.zip`（16,200,515 字节）。构建前实际用户进程位于旧冻结目录，因此未关闭该进程或改动其身份/历史。

### 真机证据与剩余验收

在本次重设计之前，主代理已恢复设备操作并在 vivo 收到公网 Web 文本和三文件中继；真实 Windows headless peer 到 vivo 的 2,621,441 字节/中文/零字节三文件全部 received，实际路径 LAN，证据 `artifacts/live-native-peer/consumed-lan-auto-status.json`。该受控 peer 已按主代理确认消费完成后停止（session 68346 exit 0），未关闭用户应用或公网中心；测试 vault 不代表真实 DPAPI 验收。

新 UI 的 vivo/Windows 实际窗口渲染、设置入口和蜂窝开关由主代理验收。公网与蜂窝直连、系统拖放、浮坞跨应用、iPad Safari 仍需对应真实环境证据；不得用 LAN/headless/组件渲染替代。当前本代理未调用 GUI 或 adb。

主代理随后在恢复的 Windows 桌面实际检查新版：通过项目启动入口恢复原身份与记录，双栏、中文字体和独立设置显示正常。GUI 向 Web 发送单字符文本，Web 回发中文多行文本，双方实际接收；系统文件选择器发送 47 / 1,200,000 / 0 字节三文件，本地状态均为中继 ready（到中心，不是对方已保存）。截图 `artifacts/screenshots/windows-compact-{active,receive,settings}-preview.jpg`，状态摘要 `artifacts/logs/windows-compact-gui-transfer-state.json`。原项目状态已备份至 `artifacts/backups/native-before-compact-20261025/`；新版窗口保持运行。手机仍未连接，原生公网/蜂窝和系统拖放等缺口不变。

## 白纸编辑器与 Android 拖放修复：当前交付阶段

文本框已支持多行、字数、全文编辑、草稿/选区保留与 Ctrl+Enter；独立检查修复了中文候选未提交时误发送及返回焦点问题。Android 修复了监听覆盖、URI 授权过早释放和 MIME 错误；多文件只进入待发送区，触摸透传与重绑由 Android 框架检查覆盖。

有效证据分别为 12 项 UI、受影响 5 项子集、独立 4 项 IME/焦点、3 项控制器事件和 7 项 Android 框架检查。组合 suite 存在间歇 `did-not-complete`，不合并声称全部通过。组件预览位于 `client/build/paper-*.preview.jpg`。

用户当前使用的前一 paper/editor-drag 版两平台构建成功；手机随后覆盖安装并启动成功。Windows `data/app.so` 生成于 12:08:09，经项目入口启动 PID 43800（12:10:25，session 78138），旧进程已退出。之后实体 Escape 中止视觉检查，未获取新版窗口/手机 UI 证据，不能据安装或进程启动判定跨应用拖放成功。

用户接手两端接收测试；代理不再控制设备。后续源码与候选见下一节，不替换该运行版本。

## 上一候选：文件库、直接接收目录与网络检测

### 操作与数据语义

- **拖放**：接收卡片整卡可拖出，手机长按后拖动、Windows 按住拖动；Windows 整窗口可接文件或文字拖入。导入不自动发送，文件库长按则进入编辑。
- **设备与文字**：只显示在线发送目标，离线历史仍保留；设备可重命名。已发消息可编辑同步原消息，收到消息只读、可复制全部。文本文件支持 UTF-8/带 BOM 的 UTF-16 预览，超过 1 MiB 显示截断提示。
- **文件库**：两列、离线可看、时间/名称/大小排序，重命名、删除、在线转发；图片支持缩略图和缩放。仅已保存文件入库。
- **接收位置**：Windows 路径与 Android SAF 可选，直接写到目标，不保留第二份永久副本；预览、打开、重命名和删除通过同一文件身份操作。
- **清理**：默认 24 小时，设置可用小时/天；到期时间以接收时间计算，类别与大于/小于 MiB 条件同时匹配。清理会删除自选目录内本应用接收的文件，不扫描目录其他文件；原发送文件及另行导出的副本不受影响。
- **网络**：每分钟检测，网卡变化时重测与重新发布 IPv4/IPv6；仍先 LAN、再公网、最后中继，阶段内结合缓存可达性与延迟排序。手动模式不静默改路。Android 蜂窝 probe 保留逐 socket 网络选择与错误。

### 检查与待验收项

对应有效日志见 `docs/PROGRESS.md` 本轮交接节：文件库/图片 5 项、目录 Dart 2 项、Windows 直接目录 1 项、Android 目录框架 5 项、可达性 4 项、网络桥与消息编辑 4 项及相应中心/Web 检查通过。连接检测窄屏页另 1 项通过，最终客户端 analyze 无问题。UI 合并运行未通过；3 项受影响子集单独通过，不能将其合并成整套通过。

Android 目录框架使用真实 DocumentsProvider/PFD 生命周期，但 Windows host 将 `ioPath` 替换为 provider backing file。设备上的 `/proc/self/fd` 直接写路径未验证；不支持所需 descriptor 的提供方会报错，不复制回应用目录作为替代。

本轮不部署中心、不安装或重启客户端，不操作设备。已发消息编辑同步及设备重命名要求中心一起升级；现公网未部署新 API。真实 SAF 提供方、跨应用来源/目标、网络切换/蜂窝可达性与 iPad Safari 仍需用户切换候选后验收。

### 已冻结候选与启动入口

- Windows：[完整 ZIP](../artifacts/releases/GlobalSend-1.0.0-library-network-20261025-windows.zip)，16,330,492 字节；Release 148.5 秒构建成功，日志 `client/build/logs/windows-release-library-network.log`。
- Android：[内部测试 APK](../artifacts/releases/GlobalSend-1.0.0-library-network-20261025-android-debug-signed.apk)，62,223,289 字节；`assembleRelease` 150.1 秒成功，日志 `client/build/logs/android-release-library-network.log`。沿用测试签名，不是商店正式签名。

需要切换时，先自行退出旧 Windows 窗口；保留现有项目身份和接收记录用以下隔离入口，不用指向旧标准构建的 npm 命令：

```powershell
$env:GLOBALSEND_DATA_DIR = 'F:\Codes\Java\GlobalSend\artifacts\native-state'
& 'F:\Codes\Java\GlobalSend\client\build\library-network-20261025\windows\x64\runner\Release\globalsend.exe'
```

两端候选仅生成；当前用户运行版未替换。直接双击解压包默认使用系统应用数据，首次需入组。短步骤见 [候选实机测试](QUICK_TEST.md)。

## 旧候选：反向直传与本机文件连续性

用户再次明确“先继续开发，暂不切换运行版本”。以下产物已生成，未安装/启动，未升级公网中心或 Web，未操作现有标签和设备。

- Windows：[完整 ZIP](../artifacts/releases/GlobalSend-1.0.0-reverse-direct-20261025-windows.zip)，16,350,893 字节；隔离 Release 构建 118.2 秒成功，日志 `client/build/logs/windows-release-reverse-direct.log`。
- Android：[测试签名 APK](../artifacts/releases/GlobalSend-1.0.0-reverse-direct-20261025-android-debug-signed.apk)，62,403,513 字节；Release 构建 168.2 秒成功，日志 `client/build/logs/android-release-reverse-direct.log`。包支持 API 24+、arm64-v8a/armeabi-v7a/x86_64。

新包包含上一候选的全部功能，并修复默认目录断线后改路径重试、取消失败项遗留半文件；文件库现在在退出/换中心后仍完整显示本机已保存文件。反向 HTTPS 推送需新中心及两端同时支持，旧对端继续使用拉取/中继。

真实本地中心与双控制器验证了 LAN 反向续传优先于另一个可达候选、完整文件/同一半文件/中心零字节、双向失败回退与手动 LAN 不降级；地址类别在 loopback 中注入，不能当作真实公网 IPv6 的证明。旧写入关闭后续传检查、原拉取/中继兼容、反向授权、桥接进度和客户端 analyze 均有有效证据，详见实施记录。

Windows 隔离入口更新为：

```powershell
$env:GLOBALSEND_DATA_DIR = 'F:\Codes\Java\GlobalSend\artifacts\native-state'
& 'F:\Codes\Java\GlobalSend\client\build\reverse-direct-20261025\windows\x64\runner\Release\globalsend.exe'
```

尚待允许切换后验证 vivo SAF `/proc` 直接读写、蜂窝主动上传到电脑 IPv6、真实跨应用拖放和新版窗口；iPad Safari 前台收发、复制与文本查看也仍需对应实机。此冻结包不含后续开发的 WebRTC。

## 后续源码：WebRTC

原生与 Web 源码已接入按阶段协商的 RTC 数据通道。Windows 生产传输组件 ↔ 浏览器生产组件 / OPFS Worker 在真实中心完成双向 1,049,307 字节、12,345 字节断点续传，以及双向空文件；文件完整，实际中继字节为 0。测试使用隐藏的独立 Flutter fixture，不启动 GlobalSend 产品或现有浏览器。

信令、控制器、旧 HTTPS 路径兼容、Web 主入口、渲染与构建的证据见 [WebRTC 开发验收](WEBRTC_DEVELOPMENT.md) 和实施记录。新源码已进一步接入 Android 每次公网连接的蜂窝授权策略；iPad Safari、公网及 Android JNI / 蜂窝 RTC 仍待实机验证。上面两份旧包和公网运行版保留，不受后续构建影响。

## 历史候选：RTC 与 Web 文件库

- Windows：[完整 ZIP](../artifacts/releases/GlobalSend-1.0.0-rtc-library-20261025-windows.zip)，25,400,421 字节；隔离构建 234.8 秒，日志 `client/build/logs/windows-release-rtc-library.log`。包内 23 项，已核对 EXE、数据和 WebRTC DLL，不能只复制 EXE。
- Android：[通用测试 APK](../artifacts/releases/GlobalSend-1.0.0-rtc-library-20261025-android-debug-signed.apk)，98,106,482 字节；Release 构建 173.4 秒，支持 API 24+、arm64 / ARMv7 / x86_64。APK v2 签名通过，无新增摄像头、录音、蓝牙或音频设置权限；仍是内部测试签名。
- Web：隔离候选 `artifacts/candidates/web-library/`，含两列本机文件库、图片/文本预览、显式转发和可配置清理；55 项定向检查、真实 OPFS / 主入口完整链及六场景渲染有证据。

Android 新 data-only bridge 仅在公网阶段并获本机授权时允许蜂窝。11 项 Dart、7 项 Java / Robolectric 及 Android 编译通过，关闭授权等待相关 create / writer / channel / lease；被动网络观察不暗中保活蜂窝。跨 engine 初始化及 Windows teardown 已修复；最新 Windows 生产传输与浏览器实际双向续传通过，见 `artifacts/logs/rtc-network-policy-windows-final-interop.log`。

未安装、启动或部署上述新候选。保留项目身份的启动命令与完整实机缺口见 [短步骤](QUICK_TEST.md)。Android JNI、蜂窝 IPv6、切网、SAF / 拖放与 iPad Safari 仍需对应设备；模拟策略和编译不代替实测。

## 当前1.0.1：组密码与在线地址

本地包：Windows `artifacts/releases/GlobalSend-1.0.1-windows-x64.zip`；Android `GlobalSend-1.0.1-android-{arm64-v8a,armeabi-v7a,x86_64}.apk`，分别18,606,000 / 16,440,676 / 19,859,208字节。完整包、签名、ABI及构建结果见实施记录；不再默认分发98 MB历史通用包，不在服务器托管安装包。

Windows 于2026-10-25 17:45通过新隔离EXE启动，使用 `artifacts/native-state`；启动前完整备份在 `artifacts/backups/native-before-group-password-20261025`，启动记录 `artifacts/logs/windows-group-password-live-launch.json`。实际窗口暴露发送/接收区、原历史、已保存图片和在线Web目标，说明旧登录和数据恢复成功。设置点击返回 `GetCursorPos failed: 拒绝访问 (0x80070005)`，重新选择窗口后单次重试仍失败，已停止输入并请求用户恢复桌面；不能据可读窗口树宣称点击、拖放或视觉实机验收通过。

本轮ADB没有物理手机。为补Android运行证据，在项目内新建独立 `GlobalSend_JNI_36` 虚拟设备，使用已有API36 x86_64镜像；没有使用或修改现有Chrona虚拟设备。专用消费者applicationId为 `dev.globalsend.rtcprobe`，不会覆盖用户GlobalSend。生成脚本 `scripts/build-rtc-android-probe.mjs` 在独立build目录快照生产Dart transport和Java bridge，日志/虚拟设备数据留在项目内。

独立消费者已实际安装、启动，控制接口返回idle；JNI库加载、PeerConnectionFactory创建及NetworkMonitor启动/关闭均有真实设备日志。Android虚拟网络→主机浏览器的LAN文件通道未连通，Web报“局域网不可达”，native新增进度0、中继字节0；没有把初始化成功写成文件互传通过。NAT/mDNS仅是待验证假设。诊断重试命令在执行前被工具策略拒绝，未换工具绕过。专用模拟器已通过console正常停止，两个所属进程均已消失，本次端口forward已移除。

结果 `artifacts/logs/android-jni-runtime-result.json`；设备日志 `android-jni-failed-device.log`、消费日志 `android-jni-real-interop.log` 均在 `artifacts/logs/`。失败运行目录 `artifacts/tmp/rtc-production-interop/run-KRO9pX` 保留；独立消费者脚本以后失败时会另存failure.json，新增诊断分支尚未执行。
