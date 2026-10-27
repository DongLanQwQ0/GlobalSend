# GlobalSend 项目规划

日期：2026-10-24。本文为技术决策与验收基线；项目现已进入实现，当前证据与缺口见 `docs/PROGRESS.md`。

## 1. 目标与范围

构建 Windows、Android 和 iPad Safari 之间的轻量跨网络传输工具。以中心服务器协调发现，以统一接收坞管理独立文本与文件；原生端尽量直传，失败可回退。同步首先指文本/剪贴板事件同步，不在 MVP 中引入目录双向同步。

新增确定要求：**客户端支持自定义中心服务器；中心服务器使用 Docker 部署。**

2026-10-25 最新确定：**仅由中心分组发现，至少十位组密码，相同密码直接加入同组。** 不使用邀请码、互相配对、首次建组确认或离线设备管理。在线组员互换 IPv4/IPv6；每次地址公告保留三十分钟，最后一个 WS 连接断开立即清除。已有设备自动重连，保留文件和历史。

同日交互调整：**便利优先，同时保留必要安全与手动选择。** 默认启动恢复上次登录中心，同组文件自动接收；仍可切回手动确认。原生路径默认依次尝试局域网直连、公网 IPv4/IPv6 直连、中继；也可手动指定其中一类路径。手动指定失败需明确显示，不暗中改路；自动模式有界回退。组认证/隔离、TLS、路径安全、文件完整性和资源上限保留，剪贴板及悬浮窗仍需主动启用。

同日体验调整：**接收和发送优先，设置收起，文案简短。** 移动端使用“接收 / 发送”导航，桌面采用双栏；只在需要操作时给出必要提示。蜂窝直传不设流量上限；为减少中继流量，单文件超过 32 MiB 时，中继自动接收或直连回退需本机确认。发送方指定中继不代替接收方确认；混合批次不通过自动接收小文件而误拒大文件。

### MVP 必须交付

- Windows/Android 独立 Flutter 应用；iPad Safari 前台可用的 Web。
- 原生自定义 HTTPS 中心地址；Web 自动使用本站中心；设备名称自动获取，可手动修改。
- 十位以上组密码直接入组，只显示本组在线设备，不设置配对或离线管理入口。
- 双向文本、多文件传输；同组默认自动接收，可切回逐项手动确认；非同组来源不能发送。
- 接收坞保留每段文本独立性，支持复制、长文查看；文件逐项进度、打开/下载、取消与失败重试。
- 断线重连、事件幂等、逐文件恢复、有限期中继与清理。
- 原生直传与中继的路径和失败原因可见；Safari 提供真实的上传进度与下载交接状态。
- TLS、授权、路径安全、大小/空间限制及敏感日志控制。

### 建议紧随 MVP

多段文本选择合并复制、重复内容提示、Windows 托盘。Windows 系统拖入/拖出按原始阶段先做独立原型；随后追加的整卡拖出、全窗口拖入与保存位置要求，现已列入下方本轮交付范围。

### 后续追加的交付要求

- **接收与发送**：正常设备栏自动显示在线设备，离线设备不占发送列表；本机名称可设置。Windows 整个窗口接收文件/文字拖入，接收卡片整卡可拖出；Android 接收卡长按拖出，文件库长按进入编辑，保留普通点击和滚动。
- **文字与图片**：已发消息可编辑原记录并同步接收方，收到消息只读、可选中和复制全部。常见文本文件可直接预览；图片有缩略图及缩放预览。查看器与输入框保持简洁，并保留中文输入法正在组合的内容。
- **本机文件库**：两列列出本应用已保存的文件，默认按最新接收排序，也可按时间、名称、大小排序；支持重命名、删除及显式转发到当前在线设备。离线、换中心或退出分组不隐藏已保存文件；在线设备、接收坞历史和认证仍按原信任域隔离，不自动把旧组内容发到新组。
- **保存位置**：可选 Windows 文件夹和 Android 系统目录；接收直接写到该位置，不保留第二份永久副本。新设置仅影响新任务，已有半文件仍在原位置续传；取消失败任务也要释放半文件。
- **清理**：默认保留 **24 小时**，可按小时/天设置，并选择图片、视频、音频、文本、压缩包、其他类别及大小条件。自选目录内由本应用接收的文件也按规则删除；不扫描删除目录中原有文件，不删除发送源文件或用户另行导出的副本。
- **连接检测**：运行时定期探测同组在线设备公布的候选，网卡变化后重新发布与检测；可达候选按内网、公网、中继排列。同阶段按连通性、延迟选用，保留手动模式；诊断要保留具体失败地址和原因。

这些是交付要求；源码、包和设备证据分别记录在 `docs/PROGRESS.md`。WebRTC 已随 rtc-library 上线，Windows ↔ 浏览器双向断点续传已实测；iPad Safari、公网与蜂窝网络仍需实机验收。保留的 reverse-direct 旧包不含 WebRTC。

### MVP 稳定后

Windows 自动剪贴板同步与回环防护、Android 可选悬浮接收坞、vivo 跨应用拖放、Windows 原生拖放完善、后台接收增强、批量导出。WebRTC 已进入当前开发范围；STUN 由中心显式配置，不引入隐藏的 TURN 大文件中继。

移动端不承诺后台持续读剪贴板、无限常驻或绕过系统限制。源附件最后在“移”字处截断，未推断缺失需求。

## 2. 环境检查与边界

- 当前目录 `F:\Codes\Java\GlobalSend` 在检查时为空。
- Flutter：`E:\Programs\flutter`；缓存版本元数据为 Flutter 3.47.2、Dart 3.13.2。
- Android SDK：`F:\Android\Sdk`，与现有 `ANDROID_HOME` 一致。
- 当前命令可用：Node.js v24.19.0、Python 3.14.0；Java 来自 `D:\Minecraft\java21`。
- Flutter 未出现在当前 PATH 查找结果中，后续可使用绝对路径，不需要先修改全局 PATH。
- 后续 Flutter doctor 已确认 MSVC/Windows SDK 可用；Windows 首轮构建成功。Android 仍有 SDK 许可和依赖下载待解决，Docker/真实设备尚未验收；详细结果见实施记录。

## 3. 技术选型

### 中心：Node.js + TypeScript + Fastify + WebSocket + SQLite

| 比较项 | Python / FastAPI | Node.js / TypeScript |
| --- | --- | --- |
| HTTP、WS 与校验 | 成熟，声明式模型便利 | 成熟，Fastify 使用 JSON Schema |
| 与独立 Web 协同 | 需维护 Python/TS 契约边界 | 可共享 Schema、运行时校验和协议测试样例 |
| 部署 | Python 镜像及锁定依赖 | Node 镜像及锁定依赖 |
| 主要注意事项 | 异步服务内不可阻塞；进程内连接不跨 worker 共享 | 不阻塞事件循环；SQLite 原生依赖需验证镜像构建 |

**推荐 Node，而非因为未经测量的性能优势。** 当前规模下，两者足够；独立 Web 同用 TypeScript，可减少契约重复维护。Flutter 仍依据同一协议实现 Dart 模型，不声称三端源码完全复用。

初期单进程、单副本；SQLite 只存元数据，文件存磁盘。实现已选定 Node.js 24.19 的内置 `node:sqlite`，不再引入需额外原生编译的 npm SQLite 驱动；使用短元数据事务，文件传输保持有界分块和流式读取。不引入 Redis、PostgreSQL 或微服务。

参考：[Fastify Schema 校验](https://fastify.dev/docs/latest/Reference/Validation-and-Serialization/)、[官方 WebSocket 插件](https://github.com/fastify/fastify-websocket)、[FastAPI WebSocket](https://fastapi.tiangolo.com/advanced/websockets/)、[Node 事件循环约束](https://nodejs.org/en/learn/asynchronous-work/dont-block-the-event-loop)。

### 客户端：原生 Flutter，Web 使用 Vite + TypeScript + DOM/CSS

Windows/Android 共享接收坞、任务调度和主要业务规则；系统能力通过平台适配器调用，Android 必要原生代码优先 Java。

Flutter Web 可以支持应用式界面和 Safari，优势是界面/业务复用；独立 Web 的优势是直接使用浏览器文本选择、文件输入、下载与触控语义。**本项目推荐独立轻量 Web，不默认引入 React。** 多维护一套薄视图，换取更直接的浏览器交互；共享协议、状态含义和测试样例。

验证时在同一 iPad、Safari、网络上比较 release 原型：冷启动可操作时间、首屏实际下载量、中文输入/长文选择、20 次点击复制、文件多选、队列滚动、后台返回。若独立 Web 满足需求就保留；只有复用收益实际超过维护成本，且 Flutter Web 也通过上述真机项目，才切换。没有实测前不下包体、内存或速度结论。

参考：[Flutter Web FAQ](https://docs.flutter.dev/platform-integration/web/faq)、[WebKit 剪贴板说明](https://webkit.org/blog/10855/async-clipboard-api/)。

## 4. 自定义中心服务器

### 原生客户端

1. 输入 `https://host[:port][/base-path]`，可保存多个配置，MVP 同时仅激活一个。
2. 标准 URL 解析：拒绝用户名密码、查询参数、fragment；保留路径前缀及大小写，正确处理 IPv6 地址与端口。
3. 访问能力端点取得协议版本、服务器实例 ID、配额与功能，再恢复登录或填写组密码。此步骤不发送其他服务器令牌。
4. 以“规范化 base URL + instance_id”为信任域。凭据、设备、队列、游标与授权隔离；相同 instance_id 不足以允许向另一 URL 发送凭据。
5. 切换时确认处理未完成任务，停止旧重连和连接，再加载新配置；未发文本不自动转发到新中心。旧记录可保留于旧配置，不混入新接收坞。
6. 服务器重装导致实例 ID 变化时重新登录。跨源重定向不继承原认证头。

默认正常 CA、主机名和有效期验证。生产环境不提供“忽略所有证书错误”。本地开发的 HTTP 仅作为明确标识的不安全开发配置，不自动降级。

### Web

每个中心同源提供 `base-path/app/`，网页自动使用本站中心，正常入组不要求填写服务地址。高级设置保留更换中心；更换后导航至新中心网页，独立恢复登录或输入组密码。浏览器按 origin 隔离存储，应用还区分 base path 与实例 ID。

认证采用同源 HTTP 会话或短期令牌；WS 使用短时一次性 ticket，长期设备令牌不放 URL。ticket 不进入访问日志；WS 单独验证 Origin。浏览器 WebSocket 接口不能像原生 HTTP 客户端一样随意添加 Authorization 请求头。[WebSocket API](https://developer.mozilla.org/en-US/docs/Web/API/WebSocket/WebSocket)

## 5. 通信架构与网络选择

```text
Windows Flutter ─── HTTPS/WSS ─── 中心：组密码 / 在线地址 / 文本 / 协商
Android Flutter ─── HTTPS/WSS ─── 同一中心
iPad Safari     ─── HTTPS/WSS ─── 同源 Web + 同一中心

Windows ←──── HTTPS / WebRTC 文件直传 ────→ Android / Web
                  失败 ↓
            中心 HTTPS 分块中继
```

### 控制通道

- 客户端主动连中心，不运行组播或独立局域网发现；中心只向本组在线设备交换候选地址。
- WS 承载小文本、在线通知、文件协商和路由协商；文件字节不走中心 WS。
- IPv4/IPv6 及 RTC ICE/SDP 地址仅保存在中心内存，上传后三十分钟到期；最后一个 WS 断开立即删除公告和当前直连授权。客户端同步停止该设备的探测，不保留离线地址列表。
- 在线状态按连接/心跳租约计算，区分在线、离线、状态未知；服务器重启后不恢复虚假在线状态。
- 带抖动的指数退避重连，网络变化可立即触发一次重试。补收使用游标与事件 ID，过期历史不无限重放。

### 原生文件路径

1. 在明确总超时内尝试候选路径，IPv4/IPv6 有界错峰竞速，不把 IPv6 存在当成可达证明。
   默认先局域网候选，再公网 IPv4/IPv6 候选，均不可达最后中继；不同阶段不同时抢跑。私网地址仅是局域网候选，不证明处于同一局域网或实际可达。没有公网候选时明确跳过该阶段，不假定 NAT 已开放。
2. 探测单位为“地址、端口、网络、地址族”；完成 TCP、TLS 身份验证和随机挑战应用层响应才视为成功。不跨网公布链路本地 IPv6。
3. 在同一阶段内尝试接收端拉取与反向推送：LAN 拉取/反向推送 → 公网拉取/反向推送 → 中继。手机能连接电脑、反向不可达时，手机发送也应能利用该连接方向；不能仅因发送方无法入站就回退中继。反向推送源码及本地真实链路已完成，设备与真实公网验证见实施记录。
4. Android 默认网络失败且用户允许流量时，Java 获取蜂窝 `Network`，使用该网络的 DNS 与 socket 建立真实传输。探测和数据流必须使用同一网络。
5. 不通过全进程网络绑定改变所有连接；平台通道仅传任务、文件引用、进度，不搬运每个文件块。
6. 网络丢失后重建连接并恢复任务，不声称 TCP 自动迁移到另一网络。所有直连失败后走 HTTPS 中继，用户可禁用蜂窝文件传输。

路径设置保留“自动 / 局域网直连 / 公网直连 / 中继”。手动模式只使用指定类别，失败后由用户重试或切回自动；蜂窝授权独立，不因选择公网而默认开启。偏好按中心隔离，传输开始时捕获选择，不将新设置套到进行中的旧任务。Web 通过 WebRTC 尝试局域网、公网，最后使用 HTTPS 中继。

发送方手动路径通过 offer 的 routePreference 固定为本次传输约束；接收端本地路径偏好仅在 offer 为 auto 时生效。Web 同样遵守手动 LAN/公网约束，失败不偷偷走中继。旧 offer 没有该字段时等同 auto。

原生 peer TLS 使用中心本组在线公告中的当前证书指纹。同组已登录设备可直接更新自己的证书和地址，不锁定永久配对身份，也不要求撤销重配。中心 HTTPS 校验保持正常。

参考：[Android Network](https://developer.android.com/reference/android/net/Network)、[ConnectivityManager](https://developer.android.com/reference/android/net/ConnectivityManager)、[Flutter 平台通道](https://docs.flutter.dev/platform-integration/platform-channels)、[双栈连接 RFC 8305](https://www.rfc-editor.org/info/rfc8305/)。

### Safari 文件路径

WebRTC 数据通道用于浏览器直传，失败后使用同源 HTTPS 中继。HTTPS 页面不能用原生的私有证书 pinning 直接 fetch peer，因此不照搬原生 HTTPS 路径。STUN 可选且默认关闭，不引入隐藏 TURN 文件中继。

Safari 下载交给浏览器，不为进度显示把大文件整体转为内存 Blob。区分“文件就绪”“已交浏览器下载”和真实落盘；网页不能把无法观测的落盘标成成功。复制在点击手势内直接使用已收到的文本，失败显示可选择文本。后台/锁屏后允许连接暂停，回到前台重新连接并对账，不依赖后台 JS 常驻。

参考：[混合内容规则](https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Mixed_content)、[WebKit 剪贴板 API](https://webkit.org/blog/10855/async-clipboard-api/)。

## 6. 小协议与接收坞模型

### 协议约束

- 公共信封：`protocolVersion, eventId, type, sourceDeviceId, targetDeviceId, createdAt, expiresAt, payload`。服务端从认证身份确认来源，不能相信客户端自报来源。
- 文本 ACK 区分“中心接受”和“目标接收”；文件再区分“中继保存”和“最终接收端完成”。
- 至少一次投递 + 幂等落库；不承诺网络层恰好一次。人工重复发送生成新 eventId；自动重试沿用原 ID。
- 批次先发 offer，接收端依据当前同组自动接收设置或逐项手动选择提交 accept，之后签发限定设备、文件、操作与有效期的传输授权；撤销和取消使授权失效。自动接收不重新接受已拒绝、取消或过期项。
- 文件采用固定大小分块 HTTP 上传/读取。原型起点为 1 MiB 块、单文件顺序写入、小并发文件队列，数值可测量调整。
- 持久化已提交偏移/块状态，重复块幂等，内容冲突拒绝；中继与最终接收端各有自己的确认状态，不能混用。
- 临时文件完成长度与完整性校验后再提交；原生端完成后改名/导出。使用流式摘要验证传输完整性，不整文件装入内存。
- 一项失败不回滚其他项；重试保留 itemId，新增 attemptId。中心重启与直连转中继后根据接收方状态恢复。

### 接收坞不是普通日志列表

| 对象 | 关键字段/责任 |
| --- | --- |
| ServerProfile | baseUrl、instanceId、deviceId、credentialRef，隔离信任域 |
| ReceiveBatch | batchId、发送设备、时间；只负责一次发送的分组 |
| DockItem | itemId、batchId、类型、来源、接收时间、过期时间 |
| TextPayload | 完整独立文本；展开/折叠仅为视图状态 |
| FilePayload | fileId、显示名、大小、MIME、storageRef；不把绝对路径当跨端协议 |
| TransferAttempt | 路径、进度、状态、错误码、重试次数 |
| LocalActionState | 复制、打开、定位等本地动作，独立于传输成功状态 |

基本状态：`offered → awaitingConsent → queued → transferring → ready`；分支为 `rejected / canceled / failed / expired`。批次汇总子项状态，不以单一失败覆盖整批。

原生文件路径、Android content URI 与 Safari 下载句柄留在平台适配层。Web 文件就绪与浏览器保存分开建模。

同 eventId/itemId 重放不重复入坞；不同事件内容相同只提示，不吞掉人工重复发送。高级剪贴板同步使用 originDeviceId/sourceEventId，标记远端写入，避免生成新同步源。

### 模块边界

`profile/auth` 管中心与组登录；`control` 管 WS、在线和补收；`transfer` 管逐项任务/直连/回退；`dock` 管分组、查看与选择；`storage` 管持久化、临时文件和清理；`platform` 管剪贴板、文件操作、Java 网络桥与系统拖放；`ui` 只消费状态和提交操作，不自行重试网络。

## 7. Docker 部署合同

默认使用 Linux 容器，Compose 两服务：

- `app`：Node 单进程，服务 API、WS、静态 Web；仅在内部网络暴露应用端口。
- `caddy`：对外 80/443、TLS 与反向代理。已有反代时提供 app-only 方案，不叠加多层代理。
- `app_data` 卷保存 SQLite、实例身份及必要密钥；`relay_data` 卷保存受配额限制的临时文件；Caddy 证书数据单独持久化。
- `.env.example` 仅列非秘密配置：公开基础 URL、路径前缀、文件上限、总配额、并发、TTL、日志级别。敏感值使用受权限保护的 secret 文件；Compose secrets 是文件挂载，不等于自动加密存储。
- 非 root、明确可写目录、只读根文件系统、日志轮转、无 Docker socket 挂载。使用固定发布标签和锁文件。
- `/health/live` 检查进程；`/health/ready` 检查迁移、数据库和存储。健康检查失败本身不保证 Docker 自动重启。
- 代理请求体和超时与分块匹配，不将完整大文件先缓冲到应用内存。首次公共 HTTPS 需要域名、正确 DNS 和证书验证可达性。
- 更新前备份，版本化数据库迁移，验证就绪、客户端重连和文件恢复；不兼容迁移回滚需恢复配套备份。SQLite 使用在线备份 API 或停服备份，不能热拷贝一个 db 文件忽略 WAL。

`Dockerfile`、`compose.yaml`、`.env.example`、代理示例和部署/升级/恢复说明现已生成；配置静态检查已做，容器实跑仍待部署环境。

参考：[Docker volumes](https://docs.docker.com/engine/storage/volumes/)、[Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/)、[Compose 健康依赖](https://docs.docker.com/compose/how-tos/startup-order/)、[Caddy HTTPS](https://caddyserver.com/docs/automatic-https)、[SQLite backup](https://www.sqlite.org/backup.html)。

## 8. 安全、隐私与存储

面向自用设备，只需至少十位组密码。相同密码直接加入稳定 groupId，未知密码自动成组，不增加建组开关、随机生成或保存密码确认。中心保存密码的 HMAC 索引，不保存可恢复明文。

每台设备保留独立 token；设备列表、在线通知、文本、文件与直传授权均限制在本组。同中心更换分组不能加载旧组队列、凭据或待发送内容。group 密钥只用于加入，不作为端到端加密密钥。

客户端移除设备撤销、密码轮换及离线管理流程；新登记不再支持 bootstrap/邀请码。已登记设备 token 继续有效，自动重连不要求重新输入密码。离线只撤下网络地址，不删除用户文件和历史。

MVP 中心被视为受信任服务：可接触转发文本和中继文件；原生直连文件不经过中心。TLS 不是跨中心的端到端加密。若要求中心管理员也无法读取内容，必须在实现传输协议前改为端到端加密方案，并同时覆盖 Web 密钥保存与设备验证。

- 文件落盘名由接收端生成；原始文件名只作显示，拒绝路径穿越和保留名，处理重名和磁盘不足。
- 上传前预占配额，逐块核实实际大小；配置单文件上限、全局临时空间、设备并发、TTL 与磁盘预留。
- 文本自动同步默认关闭；提供明确同步范围、保留期与手动清理。
- 中心文本补收和中继均有有限保留期，接收确认后尽早删除；与本机文件库保留期分别管理。本机默认按接收时间保留 24 小时，包括自选接收目录中本应用创建的文件；用户另行导出的副本不属于自动清理范围。
- 日志不记录文本正文、长期令牌、配对秘密或完整下载授权。撤销设备立即断连并取消未完成授权。
- Android 凭据使用系统安全存储；Windows 同样使用平台凭据保护，不写入普通明文设置文件。Web 不在 localStorage 长期保存高权限管理密钥。

## 9. 实施顺序与阶段出口

| 阶段 | 实际工作 | 出口证据 |
| --- | --- | --- |
| P0 技术探针 | 工具链检查；最小 HTTPS/WSS；Windows/vivo 双网络与 IPv6；Safari 复制/多文件/下载；独立拖放探针 | 记录设备/OS/版本、实际路由、成功与失败条件，不用插件声明代替实测 |
| P1 中心与文本纵切 | Docker 单体、实例身份、配对/撤销、自定义中心、在线、文本与幂等接收坞 | Windows/Android 跨网互发；A/B 切服无令牌串用；容器重建保留身份；断线不重复入坞 |
| P2 多文件纵切 | 接收授权、逐项队列、直连、中继、分块恢复、配额/清理 | 双向多文件；一个失败其余可用；切网/中心重启后恢复；最终文件校验正确 |
| P3 Safari 与 MVP 收口 | 同源 Web、触控、上传/下载、前台恢复、三端完整回归 | iPad 实际上传和在 Files 打开下载文件；显示真实状态；所有 MVP 条目通过 |
| P4 高级交互 | 原生拖放、自动剪贴板、悬浮坞、后台增强 | 按平台独立验收，权限拒绝和撤销可恢复，不影响基础传输 |

不一次生成完整工程。每阶段先做一条真实可运行链路，再扩大范围；原生直连探针可与中继基础串行推进，不能因某个网络不可达而放弃整体 MVP。

### 必测矩阵

1. 同 Wi-Fi、不同网络、校园 Wi-Fi 阻断 PC IPv6、蜂窝可达 PC IPv6；每次记录实际路径而非仅地址。
2. Wi-Fi 与蜂窝同时存在、蜂窝禁用、移动数据授权拒绝、IPv6 变化、Windows 防火墙阻断；均须有界失败并提供可用回退。
3. 3 段文本与 3 个文件混合接收；重复人工文本仍为两项，网络重放只入坞一次；一项失败后只重试失败项。
4. 中文/空格/同名/零字节文件、超限、恶意路径、磁盘不足、重复块、错证书、未配对设备、撤销设备。
5. 传输中断网、中心重启、直传转中继；状态依据接收确认，半文件不冒充完成文件。
6. 中心 A/B 切换，含端口和路径前缀；凭据/历史/未发内容/传输授权不串服。
7. iPad 点击复制、文件多选、真实下载打开、锁屏/后台再回前台；不误报最终保存和后台在线。
8. Docker 全新部署、重建容器、保留数据、备份恢复、版本升级；验证 WS 代理与大文件分块限制。
9. 高级阶段分别测试 Windows Explorer 拖入/拖出；vivo 文件管理器/相册的 content URI 权限；悬浮窗拒权、撤权、关闭与恢复。
10. 单向可达时双向传文件：发送方不可入站、接收方可入站仍走直传；LAN 反向可达、公网正向也可达时先 LAN。切方向/阶段沿用同一半文件，旧连接停止写入后才允许下一次尝试，中心不承载直传文件字节。
11. 本机文件库跨重启/退出/切中心仍完整；当前接收坞不混入旧组消息，转发必须选择当前在线目标。检查两列、排序、长按编辑、文本/图片预览及所有保存文件的清理结果。
12. 更改接收目录后，旧半文件仍在原目录续传；默认目录、自选 Windows 目录及 Android SAF 取消失败任务后都释放本应用的半文件。清理时长、类别与大小共同作用，只删除登记的接收文件。

Android 后台服务不是无限保活机制。面向 Android 15+ 的 dataSync 前台服务存在运行时限；具体后台策略按实际系统版本验证。[Android 官方限制](https://developer.android.com/develop/background-work/services/fgs/timeout)。跨应用拖放还取决于对端提供的数据与权限：[Android 拖放](https://developer.android.com/develop/ui/views/touch-and-input/drag-drop/multi-window)、[Windows 数据传输接口](https://learn.microsoft.com/en-us/windows/win32/com/data-transfer-interfaces)。

## 10. 当前结论与下一步

技术栈、协议和部署源码已落地，中心与 Web 已进入真实本地联调；仍按上述完整矩阵验收，不以局部通过判定整体验收完成。

2026-10-25 用户先要求仅开发，后明确恢复全权操作并提供公网 Ubuntu Docker 服务器，指定 IP 路径 `https://123.207.180.163/globalsend`。该部署已实际完成可信 HTTPS、WS/文件、容器重建与独立备份恢复；中心/Web 与原生控制器回归已通过，Windows 新 Release 已生成。

vivo 已完成文本双向、Web 中继收文件和原生 LAN 收文件。当前先完成界面与文案重构，再继续 Windows/Android/iPad、校园网/蜂窝和系统拖放验收。证据与未完成项见 `docs/PROGRESS.md`、`docs/NATIVE_TESTING.md`。
