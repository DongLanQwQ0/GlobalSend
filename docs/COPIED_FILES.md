# 文件复制推送

## 当前交互（112）

复制文件推送与自动剪贴板同步是独立开关，均只使用指定设备ID，不向整组广播。文件推送先发布文件名、类型、大小和引用，不上传正文；接收端在共享区、接收坞中显示方形引用卡。卡片复用内容卡片的圆角、背景、边线和弱化来源信息，右上角忽略，右下角拉取或重试。

引用状态为“未拉取 → 拉取中 → 本地可用”。点按拉取走普通选路传输，手动拉取不弹收件强调页。本地副本存在时点按打开、拖动直接复用，不再次下载；副本被移除后才重新拉取。关联使用来源、批次、条目和传输标识并持久保存，不用文件名猜测。

Windows、Android、iOS和iPadOS接入原生按需拖放：先将远端引用拖至目标，目标实际请求数据时拉取并交付。Windows使用虚拟文件与异步IStream，Apple使用NSItemProvider文件提供方，Android使用内容提供方。目录保持树形和空目录，不改成ZIP。Web可以拖出已下载的真实File；浏览器不提供同等的任意外部应用延迟文件交付接口，未下载引用仍需先拉取，不能用空File冒充。

进入待发送区的本地文件、文件夹、图片和文本都是正式内容，整卡支持拖动。Windows沿用原生OLE及触屏交接，Android沿用系统拖放，iOS/iPadOS登记真实UIKit文件/文本来源；Web使用原File与text/plain。移除按钮保持单独点击，拖动不删除草稿，也不把尚未确认的建议混进普通发送。

111的实际组件触摸、iOS提供方区域和Web浏览器处理已检查；真机投放与系统行为仍按对应平台单独验收。证据 `artifacts/tmp/copied-cards111/`、`client/test/staged_content_drag_test.dart` 及 `web/tool/accept_copied_files.mjs`。


开启此选项并指定目标设备后，Windows 复制的文件/文件夹只向这些设备公布可拉取条目。**不向整个组广播**；未指定目标不推送，同组未选设备既不接收通知，也不能查询或拉取该批次。设备按唯一 ID 区分，不按名称区分。

目标设备在组内共享区和悬浮暂存坞中看到条目，点按或原生拖放目标请求数据时才通过现有文件通道拉取；仅展示引用不上传正文。文件夹仍为单个条目，拉取后保留目录结构。来源只在本机保留原路径引用，中心只接收名称、类型、大小与不透明条目 ID。切换剪贴板或推送目标时撤回旧条目；关闭选项、来源最后一个连接断开时撤回，不保留离线文件分享服务。

## 中心协议

所有接口在 `/api/v1` 下，使用现有设备认证。

- `PUT /clipboard/files`：`{offerId,targetDeviceIds,items:[{id,name,kind,size?}]}`。`kind` 为 `file` 或 `directory`。目标必须显式给出且与来源有共同组。相同批次重试不重复通知；更换内容或目标时使用新批次 ID。
- `GET /clipboard/files`：仅返回发给本机、来源在线且仍在共同组中的条目。不返回其他被选目标的 ID；多组重合不重复展示。
- `DELETE /clipboard/files`：撤回本机批次，只通知该批次原指定目标，不通知其他组员。
- `POST /clipboard/files/:sourceDeviceId/pull`：`{offerId,requestId,itemIds}`。只有指定目标能请求。相同请求重试只唤起来源一次，来源收到 `clipboard.files.pull`。
- `GET /clipboard/files/pulls`：来源补取尚未处理的请求，供恢复连接后接续。
- `PUT /clipboard/files/pulls/:targetDeviceId/:requestId`：来源报告 `{state,error?}`，状态为 `sending/sent/failed`。`sent` 表示已提交到既有文件传输流程，实际文件进度与接收成功以该流程为准，不代表文件已经落盘。目标收到 `clipboard.files.pull.updated`；已终结状态不被旧回执退回。
- `GET /clipboard/files/pulls/:requestId`：目标查看自己的请求状态。

`clipboard.files.changed` 是指定目标的刷新通知，不携带路径或文件内容。中心重启后不保留这些临时引用，来源恢复连接后重新发布当前复制批次。文件传输仍使用既有 offer/接收流程及内网→公网→中继选路，不添加第二套文件通道。

## 初版接入与历次交付记录（98–111）

中心接口、共享协议类型及 HTTP/WebSocket 定向测试已完成。3 项用例覆盖按目标通知/可见/拉取、同名设备按 ID 区分、未点击不创建传输或消息、重复请求、目录单条目、多组去重、换目标撤回、关闭/离线/重启生命周期；类型检查通过。证据：`artifacts/tmp/copied-files-targeted-tests.log`、`copied-files-targeted-typecheck.log`。

原生客户端源码现已接入：Windows 的 `CF_HDROP` 文件复制事件、单独的“文件复制推送”开关与明确目标选择、后台来源处理、共享区可拉取条目，以及 Android 暂存坞同源条目。默认关闭。99版起先开启开关，再选择目标；关闭时禁用目标下拉框，但保留已选设备。没有目标时保持已开启、待选择，不监听或发布文件引用，也不自动选第一台设备。配置保存在本机 `copied-files.json`，不会发送到整个组；关闭文本剪贴板同步也不会中断已经指定目标的文件复制监听。文件夹仅检查根节点，点击后才调用原有 `offer`，不进入或清空待发草稿。快速复制通过有序撤回/发布避免旧 DELETE 删除新条目；更换目标后尚未开始发送的请求不会继续发送给旧设备。

Android 条目不冒充已经接收或已经暂存的本地文件，不能在下载前拖出；点按后拉取，叉号仅忽略本机显示，不删除来源。正常下载完成的文件继续使用现有接收、预览和系统拖放入口。原生条目更新保留滚动位置，拖放进行中不重建被拖元素。

检查：4 项客户端状态用例、1 项真实控制器入口用例、2 项实际组件用例、1 项 Android 原生窗口/方法通道用例通过。包含目录单条目、不预传内容、明确目标选择、草稿不变、停止文本同步后文件监听仍有效、连续复制、失败/撤回、快速回执及点按/忽略。Dart 分析无 error/warning；Java 已通过定向 Gradle 编译。组件实际渲染以系统字体查看，新增下载图标由既有 Material 矢量生成器生成，没有打包字体。日志/渲染在 `artifacts/tmp/copied-files-client*`；测试宿主并行渲染曾 `did not complete`，保留原记录，最终单引擎串行渲染通过，不把未完成运行当作通过。

Windows 独立接收坞和 Web 共享区已接通相同引用。Windows 坞分别显示“收到”和“可拉取”数量，引用不进入接收记录或批量拖出集合；点按拉取、叉号忽略由唯一的主引擎处理。新增引用使用独立的到达版本，不修改真实收件序号；拉取进度更新不会重复播放到达动画。Web 通过原有认证和中心事件刷新，没有新增轮询；离开会话后旧响应不能恢复条目，正在编辑共享文本时不重建输入框。两端重复点按只发起一个进行中的拉取请求，失败后可重试。

新增检查：8 项原生模型/控制器/主引擎/独立窗口用例通过，原有接收坞主引擎 4 项和鼠标/触屏批量拖出 3 项通过；旧批量拖出测试已更新为当前“立即进入原生 OLE”的行为，不再等待出窗才导出。Web 3 项状态测试、类型检查和生产构建通过。固定浏览器配置下实际点按完成“指定目标引用 → 普通文件传输 → 浏览器本地文件”，核对原文件内容与名称，确认点击前没有传输、未选设备不可见、目录单条目、草稿不变、撤回条目消失；950×650 和 390×844 实际渲染已查看。

此次实际联调还发现浏览器刚接收完的文件对象沿用 OPFS 内部名称，重启读取时才恢复真实文件名。已在存储完成入口统一保留来源文件名与 MIME，避免立即拖出/转发丢失文件名与后缀；原传输及存储路径不变。

原生生产控制器的真实中心链路也已通过：三台同名、不同 ID 的隔离客户端中，来源复制普通文件和目录，只有指定接收端出现两个引用，点击前没有文件任务。接收端通过生产 `pullCopiedFileSelection`、HTTP/WebSocket 与来源生产 `offer` 建立局域网 TLS 直传，实际落盘正文、空文件、子目录和空目录均正确。目录折叠为一张卡，六个传输成员只形成两个接收根条目；来源草稿与原文件未改变，未选设备没有引用或传输。撤回引用不移除已经接收的文件，收件具备导出状态，重新加入待发仍引用本地文件/目录，不生成 ZIP 或目录副本。用例是 `client/test/copied_files_center_integration_test.dart`，日志 `artifacts/tmp/copied-files-native-center.log`，隔离中心和数据在 `artifacts/tmp/copied-files-native-center/`；未启动或测试真实 Windows 界面，也未操作手机。

证据：`artifacts/tmp/copied-files-native-final-tests.log`、`copied-files-dock-host-regression.log`、`copied-files-dock-bulk-regression.log`、`copied-files-web-tests.log`、`copied-files-web-build.log`、`copied-files-browser/result.json`；窗口与网页 JPEG 在相邻 render/browser 目录。首次测试宿主发生原生访问异常退出，详细记录保留为 `copied-files-host-debug.log`；将窗口渲染与主引擎入口分开后完整通过，不把崩溃运行计为通过。

## 交付 1.0.75+98

源提交 `85c1275`。完整 Windows C++ 和 Android release 构建成功，APK 已验签，16,383,608 B；两端字体文件均为 0。Windows 完整目录已覆盖 `E:\Programs\GlobalSend` 并重启，读回文件版本 `1.0.75+98`。未触控测试真实 Windows 或共享模拟器。

中心/Web 已部署至 `https://123.207.180.163/globalsend/app/`，容器 `globalsend:copied-files-1.0.75-20261101` 健康；公开 info 已包含 copiedFiles，实际 JS/CSS 返回 200、MIME 正常，安装包目录仍为 404，未上传安装包。实例 ID 保持不变，旧镜像作为部署脚本的回退目标。部署证据在 `artifacts/tmp/copied-files-deploy/`。

手机已在明确交接后完成流式覆盖安装并启动：`10.197.184.141:39343`，安装返回 Success，读回 `versionCode=98`、`versionName=1.0.75`、`lastUpdateTime=2026-11-01 20:08:16`。仅安装、读回版本和启动一次，未触控其它页面、操作另一应用、访问共享模拟器或创建手机测试文件；完成即交还设备。日志位于 `artifacts/tmp/copied-files-client/phone-install98.log`、`phone-version98.txt`、`phone-launch98.log`。手机实际拉取仍待交互验收；不能用浏览器或原生组件检查冒充真机通过。发布状态见 `artifacts/releases/latest-local.json`。

用户已确认98版实际“复制 → 手机显示条目 → 点按拉取”成功。继续遵守不测试真实 Windows 的限制。随后追加的99版设置调整：两个目标下拉框均随各自开关禁用/启用，关闭不丢失已选设备；文件复制推送首次允许先开启、再选目标，未选目标不监听、不发布。状态、持久化、实际组件点按和深色渲染检查通过，证据在 `artifacts/tmp/copied-files-switch-targets99*` 与 `artifacts/tmp/copied-files-client/render/switch-targets99.jpg`。这次不改中心或Web。

99已完成Windows和Android完整构建，源提交 `c78de30`；Windows完整覆盖并重启，读回 `1.0.75+99`。APK 16,383,628 B，验签通过、两端无内置字体；在同设备任务明确让出后，流式覆盖安装Success，读回 `versionCode=99`、`versionName=1.0.75`、`lastUpdateTime=2026-11-01 20:36:54` 并启动一次，保留数据，立即交还设备。手机日志在 `artifacts/tmp/copied-files-client/phone-*99.*`。最后使用相同源码的手动工作流 [41307291358](https://github.com/DongLanQwQ0/GlobalSend/actions/runs/41307291358)成功构建IPA并发布iOS专属更新清单。已下载至 `artifacts/releases/ios-1.0.75-build99/GlobalSend-iPad-unsigned.ipa`，14,846,945 B；实际检查主应用与扩展版本99、arm64、共享组模板匹配和零字体，证据 `artifacts/tmp/copied-files-client/ios99-verified.json`。由用户手动签名安装，不操作iPad。

## 统一引用卡片 1.0.76+100

主界面与Windows独立坞共用 `CopiedFileReferenceCard`，复用现有内容卡片的圆角、边线、主题前景与弱背景；主界面保持紧凑横排，坞内保持正方形。来源放在底部小字，移除放右上角，拉取/重试用右下角图标表示；准备中只显示进度与状态，不重复添加操作说明。Android坞同步底部左对齐的文件名/来源和主题失败色，Web使用相同的卡片/颜色token与角落操作。引用尚未下载时仍不冒充本地文件，不加入拖出集合；不改指定目标、文件夹根条目与生产拉取流程。

主界面实际点按、准备中不可重复拉取、右上角忽略、独立坞主引擎动作检查通过，代码分析无error/warning。Web四项状态/视图检查、类型检查、生产构建和固定浏览器配置的真实点击拉取通过，950/390渲染已查看。Android原生窗口方法通道检查与实际卡片绘制通过；这不是手机实测。证据 `artifacts/tmp/copied-files-style100-*`、`artifacts/tmp/copied-files-client/render/*style100.jpg`、`artifacts/tmp/copied-files-client/style100-android/copied-reference.jpg` 和 `artifacts/tmp/copied-files-browser/`。首次组合Flutter宿主发生did-not-complete，独立入口通过；首次Web测试发现extensionless导入无法由Node解析，已统一为显式.ts入口后通过；首次Gradle命令参数转义错误已修正。上述检查先于完整构建，实际安装与部署结果见下文。

100完整Windows/Android release构建成功，源码 `921bae5`；Windows已覆盖并重启，实际产品版本 `1.0.76+100`，PID 26592。APK 16,383,024 B、Windows ZIP 22,441,977 B，两端字体文件为零、APK验签通过。收到当前持有者明确让出安装窗口后，Android流式覆盖安装Success，读回 `versionCode=100`、`versionName=1.0.76`、`lastUpdateTime=2026-11-01 21:02:10`，保留数据并启动一次后立即交还，没有触控页面或操作其它应用。手机日志 `artifacts/tmp/copied-files-client/phone-*100.*`。构建日志 `artifacts/logs/release-copied-files-style100.log` 和 `release-local-1.0.76-{windows,android}.log`，安装状态 `artifacts/releases/latest-local.json`。最后从同源码tag手动触发IPA工作流 [41309364210](https://github.com/DongLanQwQ0/GlobalSend/actions/runs/41309364210)，已成功构建并发布iOS100清单。实际包 `artifacts/releases/ios-1.0.76-build100/GlobalSend-iPad-unsigned.ipa`，14,848,004 B；主应用/扩展版本100、arm64、共享组模板匹配，无字体，由用户手动签名安装，核对记录 `artifacts/tmp/copied-files-client/ios100-verified.json`。

Web100已上线：镜像 `globalsend:copied-files-style-1.0.76-20261101`、容器healthy，实例ID不变，实际公开JS/CSS返回200并包含新卡片规则。旧98镜像保留为脚本回退目标，没有新增备份或上传安装包；现有禁用的安装包URL返回410。部署记录 `artifacts/deploy/current-workspace-deployment.json`，证据 `artifacts/tmp/copied-files-style100-deploy/`。

本轮误建的空部署包 `server/artifacts/tmp/copied-files-deploy/source.tar`（0 B）删除被执行策略拦截，留在项目内等待清理；未改换工具绕过拦截。正确源包位于 `artifacts/tmp/copied-files-deploy/source.tar`，不含安装包。
