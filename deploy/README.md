# 中心部署与恢复

中心是一个 Node 24 单进程单体，SQLite 存元数据，中继文件独立存储。2026-10-25 已在用户指定的 Ubuntu x86_64 服务器实际构建并运行 Docker + Caddy，服务入口为 **https://123.207.180.163/globalsend**。Windows 开发机本身仍未安装 Docker。

## 先在本机用起来

在项目根目录执行：

```powershell
npm --prefix web ci
npm --prefix web run build
npm --prefix server ci
npm --prefix server run build
npm --prefix server run dev
```

默认 `http://127.0.0.1:8787/app/`。设备填写同一个至少 **10 位的组密码**，直接加入同组；新密码自动建组。API 继续使用 `groupKey` 字段。服务器仅保存实例专用 HMAC 索引，密码通过 HTTPS 请求体提交。

新登记只接受组密码，不再读取 bootstrap 秘密文件或接受邀请码；旧已登记 token、设备身份与历史仍可重连。`ALLOW_GROUP_CREATION`、`MAX_GROUPS`、`MAX_DEVICES_PER_GROUP` 不再控制主流程，旧 `compose.legacy-bootstrap.yaml` 仅作无操作兼容文件。

同组仅展示在线设备；离线自身保留最小身份供设置和重连。客户端收到 WebSocket `hello` 后发布 IPv4/IPv6、当前 HTTPS 证书与 RTC 能力。公告只在进程内存保留 **30 分钟**，每次上传刷新；最后一条设备 WebSocket 断开立即移除公告及相关临时授权。相关读取会清理过期地址，后台每 **30 秒**实际清理一次。SQLite 旧 `peers` 地址启动时清空，新地址不写入数据库；传输历史、已收文件和长期 token 不受此清理影响。

可通过 `PORT`、`HOST`、`DATA_DIR`、`RELAY_DIR`、`STATIC_DIR` 指定独立测试实例。显式配置的相对路径以进程工作目录为准；默认静态目录固定为项目 `web/dist`。不要用不同进程同时打开同一数据目录；不支持多 worker/副本。

### 网页与中继共用一个中心

API、WebSocket、文件中继和网页由同一个 Node 进程、同一个端口提供，Docker 只需一个 `app` 服务。网页默认以当前网页来源及路径前缀作为中心，无需再填中继地址。

`WEB_ENABLED=true` 默认开启网页；在 `.env` 中设为 `false` 后重建 app，可只运行 API 和中继。关闭网页仅禁用 `/app/` 静态路由及中心首页跳转，不影响原生客户端、WebSocket、健康检查和文件接收；此时不需要静态资源。开发用 Vite 不参与生产部署。

例如 `PUBLIC_BASE_URL=https://example.com/send`：网页 `/send/app/`，API `/send/api/v1`，WebSocket `/send/api/v1/ws`，健康检查 `/send/health/ready`。反代保留 `/send` 前缀。安装包路由无论网页是否开启，均返回 410，不托管安装包。

## Linux Docker + 自带 Caddy

1. 准备 Docker Engine 和 Compose v2；域名 DNS 指向服务器，开放 80/443。确保数据卷有足够磁盘空间。
2. 复制 `.env.example` 为 `.env`，填写 `PUBLIC_HOST` 与 `PUBLIC_BASE_URL`。例：`send.example.com` 与 `https://send.example.com`。
3. 启动中心，无需 bootstrap secret 文件：

```sh
docker compose up -d --build
```

主机管理员可读数据卷和文件，MVP 中心可读文本与中继文件。

`app` 为 UID 1000 非 root、只读根文件系统、无 capabilities、无 Docker socket。只暴露内部 8787；Caddy 暴露 80/443。应用数据、临时中继、证书分卷持久化。新命名卷继承镜像中 `/data`、`/relay` 的所有权；迁移旧卷时应先停服并核对目录权限，不对未知目录递归改权。

### 公网 IP + /globalsend（当前部署）

`globalsend` 是 URL 路径前缀，不是子域名。客户端中心地址填写 `https://123.207.180.163/globalsend`；Web 地址为 `/globalsend/app/`，直接访问 `/globalsend` 会自动跳转。

公网 IP 使用单独覆盖配置，不把自签证书当作可信 HTTPS：

```dotenv
PUBLIC_HOST=123.207.180.163
PUBLIC_BASE_URL=https://123.207.180.163/globalsend
ACME_CA=https://acme-v02.api.letsencrypt.org/directory
CADDY_DATA_VOLUME=globalsend_caddy_ip_production
```

```sh
docker compose -f compose.yaml -f deploy/compose.ip.yaml up -d --build
```

`Caddyfile.ip` 显式选择 ACME `shortlived` profile，签发可信 IP 证书并自动维护续期；`default_sni` 处理不发送 SNI 的 IP 客户端。云安全组须持续允许入站 TCP 80/443，不要在首次签发后关闭验证端口。生产证书卷必须持久化。首次可使用 staging CA 验证连通，但 staging 要使用独立 CADDY_DATA_VOLUME，不能把测试证书卷用于正式服务。依据：[Let's Encrypt IP 证书](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)、[Caddy ACME 配置](https://caddyserver.com/docs/caddyfile/directives/tls)。

当前 app 源码目录：`/home/ubuntu/GlobalSend/releases/20261025-173223-group-password`。当前 app 使用四份 Compose 文件，下载兼容文件无操作：

```sh
cd /home/ubuntu/GlobalSend/releases/20261025-173223-group-password
sudo docker compose -p globalsend -f compose.yaml -f deploy/compose.ip.yaml -f deploy/compose.downloads.yaml -f deploy/compose.release.yaml ps
```

`deploy/compose.release.yaml` 固定当前 app 镜像 `globalsend:group-password-20261025-173223`。数据卷仍为 `globalsend_app_data`、`globalsend_relay_data`，TLS 卷仍为 `globalsend_caddy_ip_production`。本轮仅重建 app；运行中的 Caddy 仍关联旧部署目录 `20261025-163425-rtc`，其路由和 TLS 未变。不要删除这个旧目录、操作其他项目容器或运行 `down -v`。

2026-10-25 17:37（北京时间）已上线组密码中心和冻结的新版 Web；公网健康、10 位密码自动同组、组隔离、在线 IPv4/IPv6 公告、最后一条 WS 断开清理、旧 token 重连、中文消息/ACK、准确静态资源均通过。原实例、14 个原设备及 7 个原分组保留。STUN profile **未启动**，`STUN_URLS` 为空，UDP 3478 未调整。

**安装包仅本地交付，不再使用服务器流量托管。** `/globalsend/releases` 及所有子路径均返回 410，包括下载页、默认 APK、备用通用 APK 和 Windows ZIP；Range 请求也不能获取包体。中心与网页版继续正常服务。`deploy/compose.downloads.yaml` 已改为兼容 no-op，现有四文件管理命令仍有效，未来重建不再挂载下载目录。历史服务器文件未删除；当前进程的闲置只读挂载会在以后正常重建 Caddy 时移除，无公开路由可以访问它。

升级前停服快照与旧镜像记录位于 `/home/ubuntu/GlobalSend/backups/20261025-173223-pre-group-password`；旧镜像标签为 `globalsend:pre-group-password-20261025-173223`。回滚执行该目录 `rollback.sh`，仅切回旧 app 镜像、复用当前卷，不覆盖当前数据库或重启 Caddy。独立新版健康脚本为同目录 `health.sh`。构建、切换和验收记录副本位于 `artifacts/logs/remote/group-password/`，完整交接为 `artifacts/deploy/group-password-deployment-report.md`。

2026-10-25 实际证据：公网默认 CA 校验通过、`/globalsend/health/ready` 返回 200、前缀 Web 页面真实渲染；生产 Host/Origin WebSocket、双设备文本/ACK、中文名/>1 MiB/空文件中继及逐字节一致、单次下载票、手动路径约束均通过。容器重建保留实例/凭据/字节；停服快照已恢复到独立卷并启动真实 app，再次验证身份、凭据和文件。快照保存在服务器项目 `backups/20261025-first-deployment`，日志副本在本地 `artifacts/logs/remote/`。实际短期证书续期尚未等待到期观察，当前已配置自动维护与持久卷。

### 自有域名或现有反代

`PUBLIC_BASE_URL=https://example.com/send` 时，页面是 `/send/app/`，API 是 `/send/api/v1`，就绪是 `/send/health/ready`。反代必须**保留 /send 前缀**，支持 WebSocket 升级，不重写成根路径。

已有宿主反代时仅启动 app：

```sh
docker compose -f compose.yaml -f deploy/compose.existing-proxy.yaml up -d --build app
```

该覆盖文件把 8787 仅绑定宿主 loopback。反代转发 `127.0.0.1:8787`，保留 WebSocket 和路径；不要记录 URI 中的一次性 ticket。不要公开 app 的无 TLS 端口。

### 可选：自托管 STUN，帮助 IPv4 NAT 发现公网映射

`stun` profile 使用官方固定版本 **`coturn/coturn:4.18.0-r0`**，以 `--stun-only` 运行。它只回复地址发现请求，不转发文件，不分配 TURN 中继。仅发布 **UDP 3478**；不开放 TCP 3478、5349 或 TURN relay 端口段。默认不启动，也不自动填写 `STUN_URLS`，原部署命令保持有效。

需要使用时，在 `.env` 显式填写可达地址；下面的 IP 是当前服务器示例，不是不可更改的内置地址：

```dotenv
STUN_URLS=stun:123.207.180.163:3478
```

先在云安全组和主机防火墙允许入站 **UDP 3478**，再在项目根目录执行。此操作会升级中心镜像；在允许切换运行版本后使用。这里仅提供部署源码，尚未调整当前服务器规则或部署 STUN。

```sh
# 当前公网 IP 部署；使用域名时去掉 -f deploy/compose.ip.yaml。
docker compose -f compose.yaml -f deploy/compose.ip.yaml --profile stun config -q
docker compose -f compose.yaml -f deploy/compose.ip.yaml --profile stun up -d --build app stun
docker compose -f compose.yaml -f deploy/compose.ip.yaml --profile stun ps
docker compose -f compose.yaml -f deploy/compose.ip.yaml --profile stun logs --tail=40 stun
```

在已有部署上，此入口只更新 app 和新增 stun，不重建 Caddy 或删除持久卷。全新部署仍须按前文启动 Caddy。STUN 不使用 HTTPS 路径，因此地址是 `stun:IP:3478`，不是 `/globalsend/stun`；不需要证书、组密钥、TURN 用户名或 `external-ip` 自动探测。

分三层验证，不能用服务器本地成功代替公网可达：

```sh
# 1. 容器内确认 UDP Binding 回复。应看到 IPv4/XOR-MAPPED-ADDRESS 信息。
docker compose --profile stun exec -T stun turnutils_stunclient -p 3478 -t 2000 127.0.0.1

# 2. 在另一网络的 Docker 主机验证公网 UDP；此命令不发布任何本地端口。
docker run --rm --entrypoint /usr/bin/turnutils_stunclient coturn/coturn:4.18.0-r0 -p 3478 -t 3000 123.207.180.163

# 3. 中心 /info 的 rtc.iceServers 应包含刚配置的 STUN URL。
curl --fail --silent --show-error https://123.207.180.163/globalsend/api/v1/info
```

映射查询成功后，再用客户端的公网直连验收确认实际选中的 ICE 路径。STUN 不能保证穿透所有 NAT，也不能把 IPv4-only 设备变成 IPv6 设备；没有可达共同地址族或 UDP 被阻断时，仍按原策略最后使用 HTTPS 中继。关闭时先清空 `STUN_URLS`、重建 app，再执行 `docker compose --profile stun stop stun`；不要删除数据卷。

版本与参数依据：[官方镜像发布 4.18.0-r0](https://github.com/coturn/coturn/releases/tag/docker%2F4.18.0-r0)、[该版本 Dockerfile](https://github.com/coturn/coturn/blob/docker/4.18.0-r0/docker/coturn/debian/Dockerfile)、[4.18.0 服务参数](https://github.com/coturn/coturn/blob/4.18.0/README.turnserver)、[官方 STUN 验证工具](https://github.com/coturn/coturn/blob/4.18.0/README.turnutils)。4.18.0 的 DTLS 和 CLI 默认关闭，不再使用已删除的 `--no-dtls` / `--no-cli`；也不能同时指定 `--no-udp-relay` 和 `--no-tcp-relay`，应使用 `--stun-only`。

本地验收状态：Windows 开发机没有 Docker，已做 Compose YAML/schema 和精确版本参数静态检查；未拉镜像、启动容器、打开端口或修改安全组。容器启动与真实公网 UDP 回复需在后续获准部署时执行上面命令验收。

### 配额与状态

默认每文件 2 GiB、全局临时配额 10 GiB、TTL 24 小时、1 MiB 块、发送设备最多 64 个活跃文件。offer 提前预占完整文件大小，拒绝/取消/过期释放。原生直传确认后释放预占；未完成直传仍预占，便于回退。另保留 64 MiB 物理磁盘空间。配额不是 Docker 卷硬配额，服务器还应监控真实磁盘、日志与备份空间。

代理需要允许略大于 1 MiB 的请求体，不缓存整文件上传。下载直接流式输出，反代需保留 Range、If-Range、ETag 和 Content-Range。原生断点下载每次重连先申请新的一次性下载票，再按本地已保存偏移发送单个 Range；206 才能按校验过的偏移追加，200 必须覆盖重写。取消/过期令未来下载授权失效。浏览器中继文件交给下载器不等于保存完成，不自动发 received；新版 WebRTC 在 OPFS 落盘及完整性校验后提交 direct received，用户另行下载仍是独立动作。

2026-10-25 恢复验证后，中心 TypeScript 类型检查与 release 构建通过，16 项服务端测试通过。新增回归覆盖 Range/ETag/If-Range、新单次票据重连、发送方路径约束重启持久化、默认 auto 的旧 offer 幂等兼容，以及在磁盘检查挂起期间取消上传后不产生孤儿文件。既有组隔离与真实 WebSocket 检查继续通过。日志在项目 `artifacts/logs/server-route/build.log`、`test.log`。这不等同于 Docker、真实 LAN/公网和设备验收；自动剪贴板具体系统行为仍由客户端验收。

发送方手动指定局域网/公网直连时，中心禁止该 offer 使用中继；指定中继时禁止 direct-ticket。自动模式由接收端顺序尝试 LAN、公网，再选中继。相关字段与错误码见 `docs/API.md`，部署无需新增环境变量或改变 SQLite schema 版本。

`/health/live` 证明进程响应；`/health/ready` 检查数据库与存储可写。Docker 的 unhealthy 本身不会自动重启容器。`restart: unless-stopped` 处理进程退出；宿主监控负责持续 unhealthy 的通知和人工处理。

## 备份、升级和回滚

### 本地直接运行的中心

先手动停止中心，并保持停止直到复制完成，再执行项目内脚本。脚本不替你停进程，也不打开或修改源数据库。**当前暂停验证期间不要执行下面命令**；脚本为新增源码，尚未运行验收。

```powershell
# 根 npm start 使用的默认目录；只有实例实际使用这些目录时才照抄。
npm run backup:local -- --server-stopped --data-dir artifacts/local-center/data --relay-dir artifacts/local-center/relay

# 早期直接从 server 启动、且没有指定目录的实例使用下列目录。
npm run backup:local -- --server-stopped --data-dir server/data --relay-dir server/data/relay
```

按实际启动时的 DATA_DIR / RELAY_DIR 选择其中一条，不要把目录不同的空实例当成当前实例。脚本强制显式提供两个目录；`--server-stopped` 是操作者确认，不是服务已停止的检测结果。输出留在项目 `backups/`，包含 data、relay、复制清单和原始绝对目录，SQLite 的 WAL/SHM 若存在也一起保留。内嵌的 relay 只复制到独立 relay 目录一次；遇到符号链接、junction 或特殊文件则中止。失败副本保留 `.incomplete-` 名称，不能用于恢复。

备份包含实例身份、token 相关秘密、文本和中继文件，应视作敏感数据。POSIX 创建权限限制为目录 0700 / 文件 0600；Windows 还需通过备份父目录的 NTFS ACL 限定访问。部署配置、外部 secret 和 TLS 代理数据另行安全保留，不会自动打包。

恢复时保持中心停止，先另存当前数据，再将备份内 data/relay 分别复制回清单记录的**原绝对目录**，不要混合新旧数据库/WAL 或仅覆盖部分文件。数据库的中继路径是绝对路径，本脚本不做跨路径迁移。恢复对应应用版本与配置后再启动中心；尚需后续验证身份保留、已有设备重连及未完成传输恢复。

### Docker 卷

备份前记录镜像版本、`.env`、Compose/Caddy 配置。**不要在运行期间仅复制 globalsend.sqlite 而遗漏 WAL。** 最简单可靠的自用备份是短暂停服，完整复制卷：

```sh
mkdir -p backups/2026-10-24
docker compose stop app
docker compose cp app:/data backups/2026-10-24/data
docker compose cp app:/relay backups/2026-10-24/relay
docker compose start app
```

将示例日期改成实际备份日期。复制失败也要恢复 app，随后排查再重做。中继是有 TTL 的临时数据，若不备份 relay，则恢复后相关任务会标记 STORAGE_LOST，不能声称文件可恢复。Caddy `/data` 的证书与账户信息也要安全备份，或允许由 ACME 重新签发。

升级：完成上述备份 → 保留旧镜像标签 → 获取目标版本源码 → `docker compose up -d --build app` → 检查就绪 → 验证已有配对、WS 重连、文本补收和半文件续传。SQLite schema 当前版本 3（增加组密钥 HMAC 索引、永久退役记录，兼容原有 peer/transport）；启动执行兼容迁移。不用漂移 latest 标签。若未来版本有不兼容迁移，回滚同时恢复对应版本数据库/relay 备份，不能只切换旧镜像。

恢复：先 `docker compose stop app`，确保备份和当前数据可独立保留；将完整备份目录复制到停服容器挂载卷，核对 UID 1000 可读写，再 `docker compose start app`。不得用 `docker compose down -v` 作为升级命令，它会删除持久数据。恢复后 instanceId 应不变，否则客户端需重新确认配对。

## 上线验收

目标 Linux 镜像构建、可信 IP HTTPS、WS、路径前缀、真实多块文件、容器重建身份保持与独立备份恢复已有上述证据。仍需在实际 iPad Safari、Android 和 Windows 完成跨设备上传/打开、网络切换以及系统拖放验收；模拟协议客户端或本地 Chromium 不能代替这些真机结果。
