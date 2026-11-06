# GlobalSend

自托管的跨设备文本与文件接收坞，正式支持 **Windows、Android、iOS、iPadOS、Web**。原生客户端使用 Flutter；iOS 与 iPadOS 共用 IPA，分别适配交互。中心通过 Docker 部署，Web 自动连接本站，原生客户端可自定义中心。详见[平台范围](docs/PLATFORMS.md)。

## 开始使用

应用内 **设置 → 使用指南** 按平台说明核心操作：[Android](docs/guides/android.md)、[iPad](docs/guides/ipad.md)、[Windows](docs/guides/windows.md)、[Web](docs/guides/web.md)。Android 指南重点讲解悬浮暂存坞；未连接时原生首页也提供指南入口。

网页版：[GlobalSend](https://123.207.180.163/globalsend/app/)。Windows/Android 的中心地址为 `https://123.207.180.163/globalsend`。

新版入组只需同一中心和**至少 10 位的相同组密码**，设备名称自动获取，也可修改。不需要邀请码、互相配对或首次建组确认。发现只通过中心完成；仅在线组员互换 IPv4/IPv6 地址，地址上传后 30 分钟到期，最后一个连接断开立即撤下。文件仍按局域网 → 公网 → 中继传输，复用已测通路径并保留手动选择；最后使用的中继已支持边上传边接收，不再等待整份上传。

同一设备可以同时加入多个组：**设置 → 分组 → 加入分组**。各组在线设备按设备 ID 合并去重，不按名称或 IP 合并；共享文本按组独立切换，加入/切组不清本地文件和历史。详见 [多组连接](docs/MULTI_GROUP.md)。

Windows 和 Android 当前为 **1.0.89+114**；Windows 完整目录已更新并重启于 `E:\Programs\GlobalSend`，Android 已覆盖安装并保留数据。Web 与中心同步上线。Windows剪贴板同步开关和目标在重启/重连后恢复，旧版未保存的偏好首次升级需设置一次；文件复制引用完成后按完成时间进入暂存前列，不重复下载或弹收件强调页。默认只清理两天前、小于200 KB的图片文件；文件库支持分类筛选。自动更新见[更新说明](docs/UPDATES.md)，开机自启动与后台参数见[启动说明](docs/WINDOWS_STARTUP.md)。

Windows：[运行最新版](E:/Programs/GlobalSend/globalsend.exe) / [1.0.89+114 完整 ZIP](artifacts/releases/GlobalSend-1.0.89-windows-x64.zip)。不要单独复制 EXE。顶部“剪贴板”与正式内容卡均支持原生拖放；[触屏交接](docs/WINDOWS_TOUCH_DRAG.md)已通过原生组件与编译检查，实际跨应用操作由用户验收。指定设备[剪贴板同步](docs/CLIPBOARD_SYNC.md)与[文件复制推送](docs/COPIED_FILES.md)为独立设置。

Android [1.0.89+114 arm64 APK，约16.5 MB](artifacts/releases/GlobalSend-1.0.89-android-arm64-v8a.apk)已在手机运行，无打包字体。113的暂存与接收图片投放微信均已由用户确认成功，114保留该兼容修复；兼容副本不进入系统相册，普通收件正常索引。Android/iPhone不写系统图片剪贴板，iPad保留；文本复制、图片接收/预览/拖放不变。临时拖放诊断已关闭并从手机清理；实际版本见[本机发布记录](artifacts/releases/latest-local.json)。

iPad / iPhone 的[**1.0.89 (114) 未签名 IPA**](artifacts/releases/ios-1.0.89-build114/GlobalSend-iPad-unsigned.ipa)已按约定最后构建。[Mac 工作流](https://github.com/DongLanQwQ0/GlobalSend/actions/runs/41460934497)已完成真实提供方检查、iOS主应用与分享扩展编译及打包。实际包两个目标均为114/arm64，共享组模板匹配，无内置字体，支持iPhone和iPad；iPhone禁用系统图片写入，iPad保留。iPad微信及跨应用按需拖放仍由用户手动签名安装后验收，不把QQ或Android结果替代为iPad/iPhone结果。说明见[iPad输入与窗口说明](docs/IOS_NATIVE_INPUT_AND_WINDOW_LAYOUT.md)，下载见[分平台发布](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.89-build114)。**中心不托管安装包。**

网页版刷新即可使用新版；使用步骤见 [实机测试](docs/QUICK_TEST.md)，原 pnpm 入口仍指标准开发构建。

已上线版本包含 WebRTC，并完成 Windows ↔ 浏览器的真实双向断点续传。浏览器直接接收至 OPFS，再由用户下载；不要求摄像头或麦克风。验证入口和平台缺口见 [WebRTC 开发验收](docs/WEBRTC_DEVELOPMENT.md)。

Web 的“本机文件”两列库支持图片/文本预览、排序、多选、重命名、删除和显式转发；退出或换组不隐藏同站点已存文件。清理默认一天，可设时长、类别和大小。

## 收发工作区

1.0.59 新增[剪贴板建议](docs/CLIPBOARD_SUGGESTIONS.md)：发送页及 Android 暂存坞可点击添加当前剪贴板，不自动发送；Web 在已有读取权限时显示建议，未授权时保留剪贴板按钮。

- **外观**：设置中可切换亮色、暗色、中性灰或跟随系统，以及绿、蓝、紫、玫瑰、琥珀、石板六种主题色。即时生效、在本机记住，不随分组切换；图片保持原色，Android 系统拖影同步使用当前配色。
- **Android 暂存坞**：设置“接收与暂存坞”开关控制，接收和暂存分开。可贴边收起、多批拖入、单项或全部系统拖出；成功暂存项标红，3秒后移除引用，轻点或再次拖动取消整批移除。原文件与接收记录不删除，见 [说明](docs/TEMPORARY_SHELF.md)。发送区“应用”可选择本机安装包；拆分应用按目录保留全部 APK。
- **收发工作区**：桌面左右双窗格，标题旁横排文本/剪贴板，右栏上方接收/已发送/文件库标签；移动端底部提供发送、接收、历史、文件四项导航。默认点设备发送并清除成功批次，多选后确认。待发方卡与紧凑设备各自滚动；点待发空白输入文本，共享区保持可见。Windows默认950×650，左栏整体不滚动。
- **内容预览与拖放**：接收两列卡片展示图片缩略图、文本/HTML摘要、大小和时间，路由与位置进入详情。文件与文本卡片整卡拖出，文本保留复制按钮。Windows整窗口拖入，使用灰色虚线“松手”遮罩；Android沿用系统原生拖放。
- **网址**：消息、收件弹层和文本文件预览识别 `http://`、`https://`、`www.`。点击直接使用浏览器打开；复制保留全文，已发送文字仍可编辑。
- **文件夹与引用**：选择或拖入目录后按目录结构直接接收，保留子目录和空目录，不再转换为 ZIP。原生普通发送文件与文件夹保留外部引用；删除发送历史不删除原件，原件消失后移除引用。Web仅在当前页持有外部 `File` 引用，刷新后不能恢复磁盘引用或持续检测源文件删除。
- **共享文本**：同组设备实时双向编辑，中文输入期间不打断；并发编辑保留草稿，可选择远端或保留本地。不通知、不唤起、不进入收件页面，与发送草稿和系统剪贴板独立。
- **文件复制推送**：Windows 设置中开启“文件复制推送”，再选择目标。关闭时禁用目标选择但保留已选设备；未选目标不推送。复制文件或文件夹后，只有指定设备的共享区与悬浮坞出现可拉取条目，点击才传输，不提前上传、不广播到整个组、不改待发草稿。Web 同样支持接收与拉取，见[说明](docs/COPIED_FILES.md)。
- **轻量阅读器**：原生和 Web 都支持收到文字只读查看/复制、已发消息原位编辑；原生常见 UTF-8 / 带 BOM 的 UTF-16 文件可预览。
- **新内容与窗口**：单项大预览、多项网格，支持拖出、复制和Esc。多选通过按钮进入，单击选择，长按仅拖放，返回退出多选；右键与更多共用菜单。Windows记住窗口bounds，托盘卸载主界面而保留接收核心；有焦点在主窗接收，失焦使用独立右下接收坞，不改主窗口尺寸位置。新版源码预热并复用坞的 UI-only engine，关闭后释放卡片和图片缓存，避免每次收件重新启动引擎。
- **Android后台**：保留接收服务；使用独立有界系统悬浮窗，不以 Activity 的全屏透明遮罩模拟小窗。默认展开232×116dp，可移动/缩放、圆角，支持细把手及1.5倍透明触控区；双击内容区返回主应用，只在设置中关闭。悬浮窗无法显示时使用通知，文本通知支持复制。按用户选择不新增无障碍权限、不自动检测桌面；长期后台稳定性仍取决于系统调度。
- **本地文件库**：两列显示本机全部已保存文件，离线、换中心或退出分组后仍可看，按时间、名称或大小排序；通过“多选”或“编辑”进入选择，可重命名、删除或显式转发。目录检查不再作为登录的前置步骤；缺失文件清理引用，暂不可读的目录保留记录。刚掉线的设备在 30 秒内也可尝试发送。图片支持缩略图和缩放预览。
- **接收与清理**：普通收件平铺在接收目录，同名加 `(n)`，真实传输的文件夹仍保留目录树；旧编号目录只迁移已登记的文件及引用，见[目录布局](docs/RECEIVE_STORAGE_LAYOUT.md)。Windows或Android可在“设置 → 存储”选择目录，直接写入，不留第二份永久副本。默认清理两天前、严格小于200 KB的图片，可设置时长、类别和大小。清理仅删除本应用登记的接收文件，不删除原发送文件或用户其它文件。
- **连接**：刷新、启动、恢复及获焦点重新发布自身 IPv4/IPv6 与 RTC 能力，中心通知同组。原生 HTTPS 地址对、反向 HTTPS 和可用 RTC 的只读检测并行；实际文件选择优先复用已测通形式，同范围按测量延迟排序，按 LAN→公网→中继回落。连接选择共用约一秒预算，未知形式不独占预算；只让一个文件写入器工作，关闭旧连接后才回落。已连传输不限一秒。保留手动选路、断点与大中继确认；真实蜂窝、校园网络仍需实机验收。

本版构建、定向逻辑检查和原生渲染检查已完成，Web 新资源已上线。手机后台/系统回收、实体触屏跨应用拖放及当前浏览器交互仍待实际验收。短步骤见 [实机测试](docs/QUICK_TEST.md)。

## 开发入口

iPad 未签名真机包通过 GitHub Actions 构建，下载后手动签名安装，见 [iPad 构建说明](docs/IPAD.md)。

原生版本构建、复制到`E:\Programs\GlobalSend`并重启、ADB推送/覆盖安装/启动统一使用`pnpm run release:local`；细节见[原生说明](client/README.md)。

GitHub 平台更新检查与发布入口见[版本更新](docs/UPDATES.md)。客户端只提示自己平台的新包，不因其他平台的 Release 误报；安装包不经过中心服务器。

需要 Node.js 24.19+（24.x）和 pnpm 11.8（`npm install -g pnpm@11.8.0` 或 `corepack enable`）。server 与 web 各自维护一份 `pnpm-lock.yaml`，根目录不使用 pnpm workspace，与原有模块边界一致；client 的 Dart 依赖仍由 pub 管理，见 `client/pubspec.lock`。两个子项目各有一份 `pnpm-workspace.yaml`，只承载依赖构建批准（`allowBuilds`，目前为 esbuild），不声明 `packages`，因此不构成 workspace。

```sh
pnpm run setup   # server + web 各执行 pnpm install --frozen-lockfile
pnpm run build
pnpm test
pnpm run dev
```

`pnpm run dev` 同时启动中心与 Web 开发服务，Ctrl+C 关闭本次启动的两个进程树。在原生客户端填写中心地址及至少十位组密码，Web 使用页面所在中心；相同密码直接加入同组，其他组不可见。

### 五端开发与测试

中心与 Web 在本机即可开发和验证；原生客户端共用一份 Flutter 代码，但需要在对应平台主机上构建，系统能力（拖放、托盘、悬浮坞、分享扩展）只能在目标平台检查。

| 目标 | 开发运行 | 自动检查 | 前置条件 |
| --- | --- | --- | --- |
| 中心 | `pnpm run dev`（热重载）或 `pnpm start`（用已编译产物） | `pnpm test` 中的 server 部分 | Node 24.19+、pnpm 11.8 |
| Web | `pnpm run dev` | `pnpm test` 中的 web 部分 | 同上；真实浏览器行为另按[实机测试](docs/QUICK_TEST.md) |
| Windows 客户端 | `flutter run -d windows` | `cd client && flutter test` | **Windows 主机** + Visual Studio C++ 工具链 + Flutter |
| Android 客户端 | `flutter run -d <设备>` | `cd client && flutter test` | Android SDK + Flutter + 已连接设备 |
| iOS / iPadOS 客户端 | `flutter build ios --debug --no-codesign`（编译检查） | `cd client && flutter test` | **macOS 主机** + Xcode + CocoaPods；可安装 IPA 走[手动工作流](docs/IPAD.md) |

`pnpm test` 只覆盖中心与 Web。原生测试集中在 `client/test`，需要单独执行 `flutter test`；`scripts/` 下的发布与构建脚本（`Release-Local.ps1`、`build-android*.mjs`、`Publish-GitHubRelease.ps1`）按 Windows 主机编写，在其它系统上请直接使用 `flutter` 命令。macOS 与 Linux 只作为构建 iOS/iPadOS 包的主机环境，不在正式支持平台范围内。

组密码用于入组，已有设备凭据可直接恢复登录。新登记不再接受引导码或邀请码；旧设备无需重新配对，文件与历史保留。设备地址仅保存在中心进程内，不作为永久设备清单。

Flutter SDK 使用现有的 `E:\Programs\flutter`，Android SDK 为 `F:\Android\Sdk`。原生客户端的具体运行与构建说明见 `client/README.md`。

允许构建和运行后，`pnpm start` 使用已编译中心；`pnpm run client:windows` 启动已构建的 Windows Debug，`pnpm run client:windows -- --release` 明确选择 Release。启动器不自动构建，也不悄悄改用另一配置；当前运行的旧版窗口不会因源码变化自动升级。

根入口统一使用 `artifacts/local-center/` 保存本地中心数据，`artifacts/native-state/` 保存客户端状态与接收文件，临时文件留在 `artifacts/tmp/`。显式设置的部署目录仍优先，不改全局环境。直接在 `server/` 启动则沿用该模块的目录约定。

## 文件放置

项目专用测试数据、截图、日志、下载和临时文件统一放 `artifacts/`；构建产物保留在各模块的 `dist/` 或 `client/build/`。不要把本项目测试数据留在系统 Downloads 或用户 AppData。

工具链和可复用缓存使用公共位置，例如现有 `F:\Android\Sdk`、`F:\Android\GradleCache`；新的公共下载缓存优先放 F 盘，不复制或迁移已有工具链。

## 当前设计

- WS 只传文本、在线通知与协商，不承载大文件。
- 同组文件默认自动接收，保留手动确认、取消与重试；文本独立成条。直连不设流量上限；中继默认超过 32 MiB 需确认，阈值可在设置调整。
- 自定义中心配置按服务器实例隔离，不跨服务器复用设备凭据。
- 同中心退出后切换分组，也隔离设备、接收坞、游标与待发送任务；不持久化 group 密钥。
- 默认依次选择局域网、公网、中继，保留手动指定；手动失败不暗中改路。原生之间优先使用 HTTPS 拉取/反向推送，Web 互通使用 WebRTC。
- 原生大文件优先直传；超过 32 MiB 需中继时，默认先确认。蜂窝直传不设流量上限，开关按中心保存。
- 中心是受信任服务，可读取转发文本与中继文件。TLS 不等同于端到端加密。
- 移动端不承诺无限后台在线或后台读取剪贴板。

## 规划、协议与证据

- [项目规划](PROJECT_PLAN.md)：需求分层、选型、模块边界和完整验收条件。
- [API v1](docs/API.md)：实际字段、授权、状态与恢复规则。
- [实施记录](docs/PROGRESS.md)：当前运行证据与未完成项。
- [部署与备份](deploy/README.md)：Docker 配置、本地停服备份入口与原路径恢复要求。

原型、构建通过、实际跨网络传输与真机验收分别记录；不以其中一项代替其他项。

2026-10-25：用户已恢复构建与联调授权。中心/Web 构建及回归通过，Windows 新 Release 已生成；公网 Docker/可信 IP HTTPS、文本与中继文件链路、备份恢复已实跑。Android APK 与实际设备结果见 `docs/NATIVE_TESTING.md`，不以源码或桌面测试替代真机验收。
