## 1.0.46 已交付状态（2026-10-29 16:24）

- Windows 完整包已更新并重启：`E:\Programs\GlobalSend`，运行文件版本 1.0.46+55。
- Android arm64 APK 已构建：`artifacts/releases/GlobalSend-1.0.46-android-arm64-v8a.apk`，16,291,168 字节，无打包字体。手机无线连接超时，未安装，最后确认手机仍为 1.0.43+52；不宣称已推送。
- 中心与 Web 已部署 `globalsend:multi-group-20261029-1620`。健康、multiGroup/relayStreaming 能力、原有设备/文件/记录与卷保留均验证通过；Caddy 未替换，安装包路径仍为 410。
- 链接识别修复：截图中 `https://zds.zju.edu.cn` 后的中文说明不再进入链接。中文路径、查询参数、IDN、IPv6、平衡括号保留；三端使用同组回归样例。Web 257 项、Flutter 链接 5 项通过。
- 微信聊天实际插入、vivo 交互手感和 Windows 物理触屏拖放仍未验收；Windows 物理 UI 自动化停止约束保持。IPA 仍未启动。

## 1.0.46 候选：多组、选路和流式中继（2026-10-29）

- 多组已实现：一个设备身份同时加入多组、设备并集按 ID 去重、设置内加入/退出、共享文本按组切换，不清本地文件或历史。详见 `MULTI_GROUP.md`。
- 已测通路径不再被 1 秒探测预算的分片过早淘汰；按 LAN → 公网 → 中继回落。探测/决策约 1 秒，已证实路径的新建传输握手有基于 RTT 的 1–3 秒完整窗口。
- 中继新增上传同时接收：按已提交块转发，最后一字节等待完整校验；保留断点续传。旧中心兼容原流程。
- 接收坞空白点击打开主窗口，拖动不误触打开，卡片和按钮继续各自响应。
- Android 真实跨 UID 对照发现 Downloads URI 的文件路径授权不足；增加同一 MediaStore 行的 typed URI 读授权。Android 36 原模拟器的图片/普通文件路径读取已通过，不等于微信聊天插入已验收。
- 已通过中心 63 项、Web 256 项、Flutter 选路/接收坞/真实中心 40 项及新增双尺寸界面渲染。`dart analyze lib` 无问题。全项目 analyze 仍有既有 tool 夹的 Flutter tools 引用/探针接口错误，未将其视作通过。
- 当前处于构建/部署准备：新版本尚未声明安装。Windows 物理 UI 自动化保持停止；微信实际插入和 OEM 手感仍待真机确认。IPA 不构建，安装包不上中心。

# 实施记录

## 2026-10-29 当前交付：Windows 1.0.45+54，Android APK已构建、待USB推送

- Android展开坞的透明边缘缩放热区从4dp扩大到12dp，四角20dp；按钮优先响应，不加粗边框，不增加屏幕遮挡。滚动容器的左侧留白改为可滚动内边距，内容延伸到整体圆角外沿，移除窗格elevation形成的外部阴影层。
- 31项接收坞/操作栏检查通过；新增滚动外沿渲染检查通过。已查看压缩渲染；vivo实际边界和触感仍待手机连接后确认。
- 44构建任务已终止，未形成新版APK，也未完成发布；现有安装记录仍为43。45同时包含44已定位的微信`_data`兼容修复，详见`WECHAT_DRAG_COMPAT.md`。微信目标插入及真实路径跨应用读取仍待真机验收。
- 45完整Windows包已替换至`E:\Programs\GlobalSend`并重启，PID33044响应，文件版本读回1.0.45+54。Android APK读回1.0.45/versionCode54，16,271,788字节；双方均无字体文件。实体USB设备当前未连接，推送失败，手机最后确认仍43+52。备份`backups/native-state/20261029-142820-pre-1.0.45`。源码提交5663f38；GitHub推送因低速超时未完成，远端最后确认b38cc3b。不构建IPA、不托管安装包。

## 2026-10-29 当前本地交付：Windows / Android 1.0.43+52

- 43源码1231bd4仅对vivo纯图片批次补齐同图相册实测的photo_type_flags零数组，不改变URI、原件或系统拖放。检查覆盖数组数量、URI保持、混合内容与其它厂商不添加该字段；通过后构建完整Windows包、重启PID8284，并经USB安装启动手机，读回1.0.43/versionCode52。APK16,270,000字节；备份 `backups/native-state/20261029-122850-pre-1.0.43`。
- 用户确认：正常聊天窗口仍无图片/附件，单补图片标记未解决。相册、超级截图及其它来源可以拖入；不能把问题限定为相册专用协议，也不能以系统接受回执证明聊天插入。接下来应区分URI解析/数据列与授权行为，不再继续猜相册标记值。
- 用户离开后USB设备已消失；不再发起需确认的安装或请求新端口。只读接收端安装包尚未取得，当前不能给出其内部解析逻辑的结论。已在公共工具目录安装DEX索引器，并以本项目43 APK作探针控制：provider的Log.isLoggable/Log.d调用保留，未被R8剔除；无日志不能推断目标未请求文件。GitHub源推送两种TLS后端均握手失败，远端仍停留此前版本；本地提交和实际已安装版本分开记录。

### 1.0.42 位置记忆与同图对照证据

- Windows41完整包已更新重启，PID14196响应；手机首次安装被系统拒绝，用户明确同意重试后成功覆盖安装并启动，实际读回versionName1.0.41/versionCode50。APK16,269,036字节，最终产品源码c7fa5ae，备份 `backups/native-state/20261029-111713-pre-1.0.41`。
- 普通本地/SAF文件统一具名只读URI；描述符、asset偏移和typed stream透传，无字节复制；目录原有URI不变。外部文件读取与3秒后是否移除绑定，7项文件/混合拖放/保留检查及1项asset-only检查通过。
- 真机41日志发现vivo拖影服务`com.vivo.globaldragdrop`（UID10119）在投放前读取文件，微信（UID10362）只查元数据、未打开；用户同一聊天窗口相册可插入、GlobalSend不可，菜单上投放会出现“该页面位置不支持插入”的分享面板。不能把系统预览读取或分享面板当作聊天已插入。
- 42源码b51bbe2已加入位置/尺寸/状态持久化（横竖屏独立位置、先定位后建窗、前台恢复为把手）和vivo预览读取排除；相关位置、旋转、冷恢复及预览检查通过。原有短屏恢复检查发现归一化位置越界，已修正并通过定向复验。Windows完整包已更新重启，PID36224响应，文件版本1.0.42+51；APK16,269,916字节，已生成但未安装到手机。备份 `backups/native-state/20261029-114734-pre-1.0.42`。
- 用户接入USB后，实体手机10AG5S1SR4005X7覆盖安装42成功，实际读回versionName1.0.42/versionCode51，MainActivity启动，PID18214。压缩截图确认主界面已连接、保留主题及原有设备；未清数据。安装日志 `artifacts/logs/phone-1.0.42-usb-install.log`，位置记忆的OEM手感仍待实测。
- USB真机同图对照已完成：GlobalSend与vivo相册均导出单项image/png及content URI，接收器取得授权且可读；相册authority为media，额外提供photo_type_flags=[0]，GlobalSend使用dock-files及本地拖动关联字段。报告 `artifacts/reports/phone-42-globalsend-clip.json`、`phone-42-gallery-clip.json`。差异尚不能单独证明微信拒收的根因。相册合成测试图已通过工具专用删除按钮清理，保存的插入引用为空；未删除用户照片。
- 位置记忆已增加真实冷启动证据：将贴边把手移动到(1161,1691)，仅强停并重启GlobalSend，重建后仍为(1161,1691)、55×221px。验后恢复原高度。报告 `artifacts/reports/phone-42-placement-before-restart.txt` 与 `phone-42-placement-after-restart.txt`。左右动画手感及横竖屏的OEM验收仍独立保留。

## 2026-10-29 历史交付：1.0.40+49

- 手机已通过10.196.4.142:38805依次覆盖安装1.0.37、1.0.38、1.0.39、1.0.40，均保留数据；最新实际读回versionName1.0.40/versionCode49。Windows完整包已更新并重启，PID37448。
- 左右贴边使用同一个绘制时钟，移动、尺寸、透明度同时变化。原生窗口只在动画两端调整范围；Android14及以上关闭系统额外位移动画。真实手机窗口属性已读回`NO_MOVE_ANIMATION`，避免右侧完成收拢后再次从旧原点移动。
- 操作栏改到最右竖排，右侧1dp、宽38dp；默认232×116dp，最小152×92dp。移除调整图标，直接拖四边或四角缩放；空白跟随按下偏移移动，按钮、卡片长按和横向滚动保留。新收件自动展开，卡片独立进入、退出及让位动画；每项×透明背景、36dp触控，复制后提示。
- 开关打开且权限可用时，运行时恢复/重新进入应用自动恢复为贴边把手，关闭开关则不重建。系统强行停止后仍需先重新启动应用。
- 相关框架几何、左右同进度、恢复、复制反馈、卡片进出与边缘缩放检查通过；压缩Canvas渲染已查看。微信仍未修复：预开同一聊天窗口时相册成功、GlobalSend失败，系统接受回执导致暂存引用误进入移除倒计时。独立真机接收器可读两张图片，不代替微信验收，当前开启无内容的本应用URI诊断等待重现。
- APK16,267,316字节，冷状态备份 `backups/native-state/20261029-105350-pre-1.0.40`；验签、零打包字体检查通过。产品源码f54789d已推送，GitHub公开包仍v1.0.35-build44；中心/Web没有本轮OS悬浮窗源码变化，不重启，不托管安装包，未构建IPA。

## 2026-10-29 历史交付：1.0.37+46

- Android坞的数量与对应图标相距4dp，卡片去掉“接收／暂存”分类页脚。接收用绿色、暂存用主题色；绿色主题下接收偏黄、暂存偏冷。图片充满整张卡片，保持比例居中裁剪并沿圆角收边，移除叠在右上角。
- 修复向内拉出把手后，手指抬起会再次收起的问题。1.0.36的横竖屏定位修复保留：安全区域、贴边方向和手动尺寸恢复，不清内容。
- 源码4554d5f；原生布局、图片裁剪与配色25项检查通过，随后新增的左右把手松手检查通过；真实Android Canvas压缩渲染已查看。动画自然程度、OEM旋转手感和微信文件拖入未用框架结果代替实机验收。
- Windows完整包已更新并重启至1.0.37+46；APK16,264,496字节、ZIP22,354,741字节，验签和零打包字体检查通过。冷状态备份 `backups/native-state/20261029-095656-pre-1.0.37`。
- 新地址恢复后先安装1.0.35，再覆盖安装1.0.36，安装返回Success并请求启动；1.0.36安装后的版本/画面读回因ADB掉线未完成。当前ADB无设备，1.0.37未推送，保留手机数据。公开GitHub仍为v1.0.35-build44，中心/Web无本轮源码变化，未触发IPA。

## 2026-10-29 历史交付：1.0.35+44

- 暂存坞内容随窗口同步滑动/收拢，移除顶栏关闭/收起/打开按钮；数量在图标前，内容双击打开主应用，长按保持系统拖放。展开半透明，收起更淡；可见12×48dp，透明触控18×72dp。
- 设置合并为“接收与暂存坞”开关，关闭立即隐藏并禁止后续自动弹窗，保留通知回退。每项右上角直接移除，尾部同尺寸清空卡片；成功投放标红，3秒后清除引用，窗口隐藏后仍计时，轻点或新拖动取消整批移除。
- 新图片每次打开最多建议一次，8秒自动收起，已展示图片不再因刷新/重建重复出现。Flutter图片7项、设置开关2项检查通过；原生窗格18项及新关闭/通知回退检查通过，最终把手透明边缘与框架触控命中检查通过。源码ddff6ae，压缩渲染已查看。旧API28通知套件因本地缺少对应SDK jar未运行，改变的分支在SDK34检查，不把依赖错误记为产品通过。
- Windows完整安装已更新重启，PID30652响应，15文件与构建候选长度一致。APK16,263,292字节、ZIP22,354,750字节，无打包字体；GitHub v1.0.35-build44四个资产uploaded。备份 `F:\Codes\Java\GlobalSend\backups\native-state\20261029-082744-pre-1.0.35`。
- 手机实际已安装到1.0.32+41，随后USB消失，指定无线10.196.4.142:44737超时；33/34/35均未推送，不清数据、不扫描端口。微信文字可拖入而图片/文件失败仍未修复或验收；文件URI接收器已补充读取检查并构建，待同台手机恢复连接后对照定位。
- 中心/Web无源码差异，公开健康检查通过；不为原生版本号重启，不托管安装包，未触发IPA。证据 `artifacts/reports/shelf-1.0.35-checks.json`。

## 2026-10-29 历史交付：1.0.32+41

- Android 暂存坞顶栏六个区域均可拖动；轻点与静止长按全部拖出保持原功能。边缘把手12×48dp，贴边/展开240ms，窗口几何与固定尺寸内容交叉过渡，快速反向不被旧动画结束覆盖。
- Windows完整安装重启，PID31408响应；vivo安装-r返回Success，真实versionName1.0.32/versionCode41，主界面已连接。APK16,262,916字节、ZIP22,354,424字节，无打包字体。备份 `F:\Codes\Java\GlobalSend\backups\native-state\20261029-074722-pre-1.0.32`。
- 动画定向检查通过并查看压缩Android Canvas渲染；真机已看到正常暗色暂存坞。设备随后出现用户操作，停止自动输入；连续贴边/展开的实体手感未冒称验收。
- 中心/Web没有源码变更，现有部署健康复查通过，不为原生版本号重启。未触发IPA。报告 `artifacts/reports/shelf-1.0.32-checks.json`；实际安装以 `artifacts/releases/latest-local.json` 为准。

## 2026-10-28 历史交付：1.0.31+40

- 真实AVD的首次关联图发现原生页贴近状态栏；原Android owner补齐systemBars/displayCutout Insets，保持正文24dp内边距，重复dispatch不累加。两项实际WindowInsets dispatch及布局边界检查通过。
- Windows完整1.0.31+40已更新并启动，PID42444、Responding=true，15文件与构建候选长度一致；正式arm64 APK16,261,892字节，ZIP22,354,465字节，验签和零打包字体检查通过。源代码54ffea9已推送，冷状态备份 `backups/native-state/20261028-230939-pre-1.0.31`。
- 独立x86_64验证APK17,531,908字节，已交Chrona在原共享AVD稳定点更新，只复核改变的安全区，不重跑有效ABI组。此前真实Binder/首次关联4项、零fake请求已通过且报告被消费；Android实际列表/接收通知/浏览器链路继续由Chrona负责，真实手机随后由Chrona的USB owner完成1.0.31覆盖安装并确认版本；设备已释放给GlobalSend。安装与消费分开记录于 `artifacts/reports/integration-1.0.30-handoff.json` 及后续联调报告。
- 中心/Web沿用下节已验收的 `globalsend:url-integration-20261028-224537`，本轮只有原生安全区变化，不再次重启中心。GitHub公开版仍1.0.29，IPA未触发。

## 2026-10-28 本机集成候选：1.0.30+39

- 独立 URL 意图队列与 `openUrlIntentV1` 能力已实现，格式见 [ABI v1](INTEGRATION_ABI_V1.md)。普通文本、共享编辑和文件记录不触发自动打开。
- 中心镜像 `globalsend:url-integration-20261028-224537` 已部署，公开 info 返回 `openUrlIntents=true`；Web 资源与冻结候选一致。切换前无活动传输，42设备、15组、96传输、149文件及原能力记录一致，Caddy 与数据卷未变，安装包路由仍410。冷备、回滚和验收记录位于 `artifacts/deploy/20261028-224537-url-integration`。
- Windows完整1.0.30+39已更新到 `E:\Programs\GlobalSend` 并重启，PID46760、Responding=true，15个包文件长度与构建候选一致。Windows实际运行端已向中心发布新能力，浏览器启动移出UI线程。正式arm64 APK为16,261,512字节、ZIP22,354,413字节，验签与零打包字体检查通过，状态备份在 `backups/native-state/20261028-225610-pre-1.0.30`。
- Android Messenger/本机关联与持久结果回放13项检查、Flutter真实中心HTTP/WS/去重及旧启动回归12项通过；新原生关联页和Flutter恢复提示压缩渲染已查看。真实手机尚未安装1.0.30；Chrona消费arm64包时发现共享AVD为x86_64，另从相同源码269bd73构建x64验证包，不复制AVD或替换正式arm64包。GitHub公开版仍1.0.29，尚未触发IPA。
- Chrona 独占已有 AVD / ADB；GlobalSend 提供隔离本地中心1507，不读取或移交用户既有凭据、不修改Windows用户当前组。跨应用 Binder、首次关联、实际系统浏览器和8765网页可达分别验收，不用注入启动器测试替代。
- 1.0.29 Web 已在原持久浏览器身份实测亮暗/主题色、跟随系统、Esc/点击遮罩关闭及切换页签保留草稿；已移除仅用于验收的自有草稿，未发送内容或修改组内共享。记录 `artifacts/reports/browser-1.0.29-acceptance.json`。

## 2026-10-28 当前交付：1.0.29+38

- Android 原生拖影去掉硬编码浅绿，读取与主界面相同的主题；原生系统拖放机制保留。亮、暗、中性、主题色及系统明暗检查通过，已查看真实 Android Canvas 渲染。
- 新增独立文件暂存坞：接收 / 暂存分区，边缘 36×72 dp 收起把手，点击/内拉展开，实际 OS 窗口变大变小，背景不遮罩。多批多文件和文本导入在工作线程执行，不进入待发送或接收记录；单项 / 当前标签全部沿用系统拖出。
- 系统报告拖放成功后，仅暂存引用 3 秒移除；点击一次取消，失败/取消/回投不删。单项移出、独立持久化、应用回前台收起、设置入口已接上。原始文件和收到的文件不自动删除。
- Windows / Web 内外拖影改为实际图像中心锚点。外观增加跟随系统；Android 发送区增加应用安装包选择，拆分应用保留全部 APK 的真实目录。移除应用图标绿色底，Windows/Android 图标保留透明；Apple 资源目录要求不透明，用中性底，不重新添加绿底。
- Flutter 主题/保留草稿/选择应用/拖影回归通过；Android 分区、实际窗口尺寸、混合导入、系统成功回执、3 秒取消和 APK 导出检查通过；Windows 原生代码及 Shell 拖图检查通过。Web 类型检查、构建与主题/锚点检查通过。
- Windows 完整安装已更新并启动，PID 35448，Responding=true。APK 16,232,012 字节（约15.48 MiB），ZIP22,341,980字节，包内字体为零。ADB 无在线设备，手机仍最后确认1.0.28+37，没有安装或真机交互验收宣称。未启动IPA。
- GitHub `v1.0.29-build38` 已发布 Windows / Android 包与对应清单，四个资产均 uploaded，Tag 源码为 `48c65ed83c7003a1b0279ac60b49d9d458d98b16`。发布脚本修复 PowerShell 5 将首次 release-not-found 的 stderr 当成终止异常的问题，实际首次创建新版本并上传通过；中心不托管安装包。
- 中心 / Web 镜像 `globalsend:shelf-theme-20261028-214157` 已上线，新 JS `index-COgOQ6TQ.js` 实际资源核对通过。切换前无活动传输；149个文件及设备、分组、事件库存和卷一致，Caddy 未替换，安装包路由仍410。
- Chrona 跨应用联动只完成接口调查与双方收敛方案，见 `CHRONA_INTEGRATION_DRAFT.md`，没有新增外部调用服务或远程自动打开意图。

本版功能见 [暂存坞说明](TEMPORARY_SHELF.md)，设备实测仍以 [UI 验收](UI_ACCEPTANCE.md) 为准。下方为旧版历史。

## 2026-10-28 当前交付：1.0.28+37

- 后续恢复：用户提供 `10.195.39.39:43975`，已连接同一 V2527A，直接复用现有 APK 推送、`adb install -r` 返回 Success、MainActivity 启动，实际 versionName1.0.28/versionCode37、PID14031。未重构建、未清数据，也未重启无关 Windows 客户端。压缩启动截图见原收发工作区及电脑设备，应用错误日志为空；文件库与后台/拖放仍需实际交互验收。此前下文所记 ADB 中断是原构建阶段的历史结果。

- Windows 完整包已替换并启动于 `E:\Programs\GlobalSend`；产品版本 1.0.28+37、15 个包文件与构建目录长度一致，进程响应。Android arm64 APK 已构建并验签，16,223,540 字节，无打包字体；Windows ZIP 22,346,697 字节。
- 实际文件选择器已接入并行只读 readiness：同范围先用已测通的 HTTPS／反向 HTTPS／RTC，再尝试未知形式；内网→公网→中继顺序保留。文件授权和写入器仍互斥。39 项定向检查通过，真实本地 TLS 反向收文件在前向无响应时约 26–180 ms 完成，不能代替真实蜂窝验收。
- 此前文件目录异常阻断登录、缺失文档判断、接收坞即时删除及预热复用、长按不切换多选、按平台检查 GitHub 更新的源码均在本次包内。Windows/Android 包及两份更新清单已发布到 GitHub v1.0.28-build37，源码为 `40acbd9511853f1e34a97d21a92947a196fa04c9`；中心不托管安装包。
- 用户已解除 Android 暂停更新限制。构建前 ADB `10.196.4.142:36241` 确认 V2527A 的 1.0.23+32；构建期间连接断开，既定重试拒绝连接，设备与 mDNS 列表为空，推送和安装未完成。用户再次离开后继续无人值守，不扫描端口、不追问地址、不把离开重新解释为禁止推包。
- 中心/Web 本轮无适用代码变化，保留已上线 `globalsend:interaction-fixes-20261028-193816`。原生稳定前不启动 IPA。公开更新检查复测遇到 GitHub 清单/Release 网络超时，未记为成功；文件资产状态另由 GitHub API 确认均 uploaded。
- 完整应用根组件的 Esc 设置/顶层弹窗顺序检查通过，含实际更新提示层；未复现之前桌面上的无反应，未据此修改产品键盘代码。桌面输入当前返回拒绝访问，实际原生键盘投递和物理触屏仍待可交互桌面验收。手机目录恢复、后台小窗与系统拖放需更新后实测。

当前手动步骤见 [UI 验收](UI_ACCEPTANCE.md)，运行清单见 [快速测试](QUICK_TEST.md)。下方均为对应日期和版本的历史记录，不覆盖本节状态或后续用户决定。

## 2026-10-26：Android保留手动全屏，不新增无障碍权限

- 用户明确选择“不新增无障碍权限，保留当前手动全屏”。当前Android有界小窗加手动全屏为接受方案，自动桌面识别不再作为实现缺口或授权依赖。
- 已同步UI_DESIGN、UI_ACCEPTANCE、QUICK_TEST、README及实施状态。核对现有单项/批次全屏按钮均接入expandReceivedWindow；没有新增服务或产品代码，不需重构建。1.0.15的设备安装与真实交互验收缺口仍保留。

## 1.0.15 小窗坐标 / 接收坞遗漏修正

- 后续完成审计发现Android把Flutter局部pan delta累加到宿主窗口原点，窗口自身位移会反馈进下一次delta。安装SDK flutter.jar反汇编确认单位变换及MotionEvent.getX/getY；已改MainActivity只观察真实触摸，raw屏幕坐标锚定DOWN窗口几何，Flutter只声明带原DOWN时间的手势意图。Java10/10、Widget3/3、analyze无问题；无新权限、输入注入、第二engine或系统拓扑推断。报告 `android-window-coordinate-repair.md`。
- Windows UI-only接收坞补齐卡片空白右键菜单，保留正文右键选择语义；失败/中继待确认有明确状态与回主窗处理入口，没有本地文件时不显示加入待发；正常完成移除旧速度。dock6项检查及后续实际字体失败态/完成速度检查通过，压缩渲染已查看。
- 已按release:local构建原生1.0.15+16，Windows完整更新并重启，PID36300、版本一致、Responding=true。APK18,967,505字节，签名及实际package/version/ABI/minSDK确认；ZIP25,278,658字节。ADB仍拒绝已知地址，未安装，不询问新地址、不使用其它项目模拟器。
- 发布前冷备 `backups/native-state/20261026-223107-pre-1.0.15`；中心/Web本次没有源码变化，保留1.0.14的已上线镜像，不为版本数字重建服务器。运行清单 `GlobalSend-1.0.15-manifest.json`。
- Windows只读检查返回GlobalSend窗口，UIA为null；重新选择该实际窗口后，Sky实际像素捕获返回 `IGraphicsCaptureItemInterop.CreateForMonitor ... 0x80070057`，停止该路径，未注入输入或改用其它捕获helper。完整目标仍有真实触屏/后台/OEM合成及Android精确桌面自动全屏缺口，见UI_ROUND2_STATUS完成审计，不能标complete。

## 1.0.14 第二轮工作区 / 独立接收坞

- Windows1.0.14+15已构建、完整更新至 `E:\Programs\GlobalSend` 并启动，文件版本确认一致、进程响应。Android arm64 APK签名校验通过、18,968,657字节；已知无线ADB地址拒绝连接，保留待推送，不询问新地址、不操作其它项目模拟器。Windows ZIP25,280,199字节；安装包不上传服务器。
- 原生/Web重排：全局横排文本/剪贴板，右栏接收/已发送/文件库标签，方形待发、紧凑设备、共享编辑增高且正常静默。图片放大并取消文件名，元数据压紧，行尾/空白可拖内容、正文选字；整卡点击/多选，Esc分层回退，文件页空白双击外开。
- Windows独立UI-only接收坞按真实主窗焦点分流，不改变主窗bounds；同一controller持有网络/文件状态。触屏E_NOINTERFACE改为实际触点驱动桌面OLE，原生拖影与COPY，取消释放自身输入；mock与生产CPP编译已验证，实体触屏跨应用仍待用户验收。
- Android有界小窗改为约半屏高、最大360×420dp、初始右下，提供移动/缩放把手与屏内约束，20dp圆角/texture渲染。6项Java与3项Dart布局/交互检查通过；实际vivo后台与圆角表现未冒称通过，精确系统窗口拓扑自动全屏仍未完成。
- 本地历史跨组/中心统一，移除旧身份独立入口；审查发现并修复旧session覆盖归档编辑及删除重现。全局修订与墓碑贯穿恢复/迟到事件。发布前冷备 `backups/native-state/20261026-221250-pre-1.0.14`；实际迁移37条文本全部保留，7条被隐藏的文件引用原路径均已不存在，无现存原件被当作失效引用。只读盘点见 `ui-round2-history-installed-migration.json`。
- 自动选路统一1秒总决策预算，入口并行预探测、真实取消HTTP/RTC与旧writer，保持长传输、断点、手动模式和大中继确认。刷新重新发布自身地址并组播，Web兼容协商显式refresh，续期/广播事件不形成回声。
- Web145项单测、18个固定profile浏览器场景/17项交互、构建完成；Native针对性界面/历史/宿主/窗口/选路检查通过。说明与实际缺口集中于 `docs/UI_ACCEPTANCE.md` 和各round2报告。
- 中心/Web已上线镜像 `globalsend:workspace-1.0.14-20261026-220919`，app healthy，public discoveryRefresh=true，HTML/JS/CSS/worker逐字节匹配冻结候选；安装包路由仍410。数据盘点一致、仅重建app、Caddy不变。第一次只读冷盘点失败自动恢复，修正盘点时机后重试成功，冷备与回滚在 `20261026-220919-pre-workspace-1.0.14-retry`；详见部署报告。SendTo快捷方式已安装，安装数据指针不打入ZIP。

## 1.0.13 Windows 修复版；Android 待构建

- 用户在两端报告 `Unsupported operation: Cannot modify an unmodifiable list`。以只读平台通道原始回包复现，堆栈落在共用 `PlatformVault.read` 的 finally/fillRange：凭据已解码，但清理操作改写engine拥有的只读buffer，使连接失败；格式错误也会被该清理错误覆盖。
- 已改为复制到自身可写buffer后解码/清理，不修改平台消息；Windows与Android使用同一段实现。修复前两项复现均失败，修复后vault7项通过，目标文件静态分析无问题。日志 `artifacts/logs/vault-readonly-before.log` / `vault-readonly-after.log` / `vault-readonly-analyze.log`。
- Windows已按用户新授权构建1.0.13+14，完整覆盖到 `E:\Programs\GlobalSend` 并重启；本次同时落实Windows默认设备名读取当前USERNAME，手动名称不变。vault7项、设备设置8项通过。设备设置旧用例仍将已撤销设备计入列表，本次改为明确断言self/phone/offline三项，符合既有撤销过滤合同；原失败记录保留。发布清单 `artifacts/releases/GlobalSend-1.0.13-manifest.json`。
- 只构建和更新Windows；Android及Web/中心仍为1.0.12，Android共用源码修复尚未打包。客户端真实连接由用户继续手动验收。

## 2026-10-26 19:04：全部运行端交付手动验收

- 用户明确要求部署至最新，并提供 `10.195.39.39:43075`。1.0.12 APK推送到手机Download，覆盖安装返回Success，MainActivity已启动，设备包信息确认versionCode13/versionName1.0.12；未清数据、未操作手机界面。
- Windows现有完整1.0.12+13包已重启，PID36076，Responding=true。服务器Docker确认同版镜像running，ready正常；公开Web四资源与冻结候选一致，安装包路由仍410，未上传安装包，也未无意义重建已是最新版的中心。
- UI/交互交由用户手动验收；Android精确判断桌面后自动全屏/小窗仍是明确未完成项，不算已交付能力。

## 当前交付：2026-10-26，1.0.12 全界面排版重整

- 18:12后续对照：仅关闭测试宿主CPU采样器、保留原测试/断言/渲染，原中断交互组22/22和最后手机server/dropdown 1/1完整通过；产品源码/SDK/运行版均未修改，无需重构建。对应联跑缺口已补齐，真实设备及Android精确桌面策略仍未完成；详见 `native-host-diagnostic-1.0.12.md` 与 `ui-goal-completion-audit-1.0.12.md`。
- 最终独立视觉验收查看9份最终压缩渲染，未发现阻止交付的明显布局缺陷，按当前版收敛；报告 `artifacts/reports/ui-final-visual-acceptance-1.0.12.md`。既有 tester 转储的窄范围诊断将异常高可信定位到 Dart 原生采样/帧链遍历，未修改 SDK 或据此计整组通过；报告 `native-host-diagnostic-1.0.12.md`。
- 用户新增截图指出留白、贴边标签、下拉/输入不统一和冗余展开，并要求全面检查。已按 [界面规范](UI_DESIGN.md) 完成 Native/Web 的连接与恢复、工作区、设置、正文编辑/查看、收件网格、菜单和文件库重排，并统一实际组件/样式规则。
- 统一 8/12/16/24/32 间距、外置标签、字段/按钮高度与圆角，正文独立编辑区采用接近 4:3 的矩形；Windows 实际 934×611 客户区左栏继续保持内部滚动而非整体滚动。独立细节审阅的 10 项已分配执行，报告 `artifacts/reports/ui-detail-audit-1.0.12.md`。
- Native 1.0.12+13 已构建，Windows 完整更新至 `E:\Programs\GlobalSend` 并启动，发布 PID45176；实际 UIA 确认新恢复连接布局、外置字段和独立服务器/诊断入口，无旧“更多”。APK 18,911,865 字节（18.91MB）、ZIP 25,212,230 字节；签名校验及 ABI/versionCode 检查通过。33077 三次已知地址重连超时，未推送手机，最后核实手机为1.0.9，未追问或绕过安装权限。
- Web/中心已上线 `globalsend:workspace-1.0.12-20261026-162254`，公开四文件逐字节匹配冻结候选，安装包路由仍410；前后27设备、13组、28传输、40文件和3条共享记录一致，events184一致。CSS构建输出38,927字节，未新增大字体/图片依赖。
- Native独立surface10、字段/IME10及恢复/阅读/库/图片等检查有效；Web85项回归、46个实际浏览器状态与11项交互、8项接收smoke通过。Windows Flutter测试宿主在大组合与末次server/dropdown流程出现同偏移0xC0000005，未算整组通过；完整联跑与真实设备缺口保留。报告 `native-ui-1.0.12.md` / `web-ui-unified-1.0.12.md`；交付清单 `GlobalSend-1.0.12-manifest.json`。

## 1.0.11 历史交付：收件小窗与凭据恢复

- Web/中心已上线 `globalsend:workspace-1.0.11-20261026-150646`。接收多选只保留选择标志、内容和信息，不显示实际已停用的复制/菜单等动作；所有卡片选择标志统一左上。最终定向浏览器 8 项通过，公开四文件与冻结候选一致，安装包仍不托管；中心原数据清单一致。
- Native 1.0.11+12 已构建并更新 Windows，ZIP 25,210,627 字节。Android 同宿主有界窗口的三项评审问题已修复：每次启动独立 ACK、普通窗口恢复清理锁屏/亮屏标志、旧批次关闭按原生 arrival 代次校验；Java20、窗口5项与幂等关闭1项通过，Windows 同代次原生门禁及完整 release 编译通过。
- Windows 凭据验证确认同用户/认证登录上下文/Session 中旧受保护数据报 `0x8009000B`，不判定永久损坏。已交付默认重试旧身份与明确确认后独立存储新身份的恢复入口，旧密文/历史/文件保留；原子提交及真实 startPeer 重启分支、恢复 UI 检查通过，未代用户执行恢复。见 `artifacts/reports/windows-vault-recovery-1.0.11.md`。
- 15:59 已启动 Windows，发布记录 `GlobalSend-1.0.11-manifest.json`；手机33077在构建后断开，已知地址重试均超时，APK 未推送，不修改权限或追问地址。当前真实设备触屏/后台/小窗合成验收与精确 Android 桌面拓扑策略仍保留缺口。

## 1.0.10 历史交付：接收多选、共享编辑与批次强调

- Windows 1.0.10+11 已完整更新到 `E:\Programs\GlobalSend` 并启动，PID 31684。APK 18,875,597 字节（18.88 MB）、ZIP 25,178,526 字节。APK 已推送 `10.196.4.142:46447` 的 Download，但覆盖安装返回 `INSTALL_FAILED_ABORTED: User rejected permissions`；手机仍为 1.0.9/code10，未绕过权限、未清数据，也不向无人值守用户询问新地址。
- Native/Web 接收多选：整卡选择所有类型，全选/取消全选、批量删除，复制只计文本；取消恢复原动作。共享编辑静默，手机键盘保持节点/输入连接；多项新收件按 ID 聚合滚动网格，托盘/延期不丢项。移除重复大标题，“媒体”接系统图片/视频 Picker。
- Windows 触屏链路修复缓存触点、异步文件准备及 capture 生命周期；真实触屏跨应用落下仍未验收。Windows 后台收件按桌面/小窗环境临时最大化或小尺寸，失败才通知，结束恢复持久窗口状态。
- Android 后台先请求授权 Activity、实际恢复失败才通知；真实新版本独立提醒，同条编辑和复制动作保持 item 身份。该 vivo 未声明标准 freeform，厂商小窗与精确桌面拓扑尚未实现；真实后台稳定性和系统图库仍需设备结果。
- 检查：Native 最终 UI 10 项、数据/真实本地中心/媒体链路 12 项、通知/服务 Java 14 项；媒体 Java 15 项、Dart 4 项；Windows 触屏针对性与原生生命周期检查；Web 73 项和真实固定 profile Edge 38 项通过。旧全量 widget 运行失败未计通过。当前 Windows UI 捕获返回 GetCursorPos 拒绝访问（0x80070005），停止进一步 UI 操作；不把进程已启动当作最新实际画面验收。
- Docker/Web 已切换 `globalsend:workspace-1.0.10-20261026-143957`，公开资源与最终候选逐字节一致，安装包路径含 Range/HEAD 仍 410。切换前后 27 设备、13 组、28 传输、40 文件及 3 条共享文本记录一致；独立健康检查、冷备和回滚脚本保留。当前部署 `artifacts/deploy/current-workspace-deployment.json`；完整范围与缺口见 [当前验收](UI_ACCEPTANCE.md)。

## 1.0.9 历史交付：收件通知与文本选择

> 1.0.9 后续已在 13:39:33 通过用户新地址覆盖安装；下文保留当时的待推送状态。当前运行版本以上方 1.0.10 记录为准。

- Windows 1.0.9+10 已完整更新至 `E:\Programs\GlobalSend` 并启动。新收件由不卸载的应用外层监听，调用原生通知并恢复托盘/最小化窗口；通知点击回到接收预览。修复了过去 UI 卸载后仅更新 controller、却不唤起窗口的缺口。
- 手机 1.0.8 已通过用户给的新地址 `10.196.4.142:43615` 推送、覆盖安装并启动；随后无线 ADB 再断开。1.0.9 已构建，18,869,260 字节，暂未推送；旧地址拒绝连接，已请用户提供新地址或 USB。Windows ZIP 25,172,046 字节。
- Android 修复 Activity 原生前后台状态与通知同步、迟到 Dart 前台信号覆盖后台状态、通知点击把收件弹层关掉的问题。新增“悬浮通知”通道设置入口，保留全屏通知及文字“复制”；实际后台稳定性需安装 1.0.9 后验证。
- 正文鼠标拖动/触屏长按只做选择复制，不触发整卡外拖；文件仍可整卡拖出，文本从标题/空白拖出。Web 同步分离文字与拖出区域，并在选择期间延迟全页重绘，避免刷新清空选区。
- Native 7 项选择/托盘/通知/触屏核心、1 项通知设置、10 项阅读/链接检查通过；Windows 原生托盘/最小化恢复通过；Android 通知 7 项通过。Web 66 项及隔离浏览器真实选字/刷新保留、标题拖出、网址点击和工作区检查通过。含截图的 Native 组合运行遇到 host 退出 79，不计通过；相应核心已在无截图定向运行通过。
- Web/Docker 已升级 `globalsend:receipt-selection-20261026-132618`，公开资源与冻结候选一致，安装包仍不托管。报告 `artifacts/reports/receipt-notification-1.0.9.md`。手机后台/锁屏的重复收件与 Windows 当前桌面的系统横幅显示仍需实机确认，不将通知对象或组件测试当作实机稳定性结果。

## 1.0.8 历史交付：直接打开网址

- Windows 1.0.8+9 已完整更新至 `E:\Programs\GlobalSend` 并启动，Web 已上线；APK 18,864,984 字节，Windows ZIP 25,164,307 字节。手机构建期间 ADB 断开，仅剩模拟器，旧无线地址连接被拒绝；未向错误设备安装。手机最后成功安装仍为 1.0.7，待用户重连。
- Native 消息/卡片/收件弹层/文本文件预览中的网址可直接点开；只读阅读器可选择正文，已发消息编辑保持原入口并实时列出当前网址。Web 消息卡片、阅读器、收件弹层和文本预览同步支持。识别 http/https/www，不访问远端生成预览。
- 65 项 Web 定向测试、11 项 Native 定向测试及 analyze/TS/build 通过。隔离 Edge 实际点击收件网址后打开新标签，原整卡拖出、复制、Esc、编辑和手机布局回归通过；压缩截图已查看。未进行手机触控或系统剪贴板操作。
- Docker 已切换至 `globalsend:web-links-20261026-114025`，healthy；公开 Web 四文件与冻结候选逐字节相同，安装包路径仍 410，未上传安装包。升级前后 26 个设备、12 个组、27 个传输、37 个文件记录一致，Caddy 未重启。
- 发布中发现无手机时标准脚本未更新本地发布记录，已改为 Windows 更新后立即记下 phonePending；手机成功后再记安装完成，保留明确的部分交付状态。
- 记录 `artifacts/reports/web-links-1.0.8.md`、`artifacts/deploy/current-web-links-deployment.json`。APK 本地可用；待手机重新连接 ADB 后由 root 推送、覆盖安装和启动。

## 1.0.7 历史交付：中心与 Web 同步升级

- Windows 1.0.7+8 已完整更新至 `E:\Programs\GlobalSend` 并启动；真机通过 ADB 覆盖安装 1.0.7/code8，已启动，安装包副本在 `Download/GlobalSend-latest.apk`。APK 18,787,052 字节，Windows ZIP 25,083,089 字节。
- Native/Web 掉线设备保留 30 秒，灰色“离线 · 可尝试”，可点击发送或转发；重连立即恢复，到期自动移除。64 项 Web、5 项中心、14 项 Native 定向测试通过，详见 `artifacts/reports/discovery-grace-30s.md`。
- 公网 Docker 已切换至 `globalsend:ui-grace-20261026-111529`，健康状态 healthy，新增共享文本与 RTC probe 功能。仅重建 app，Caddy/TLS 及其他应用未动；原 21 个设备、10 个组、22 个传输和 32 个文件记录在切换前后保持一致。
- 公网真实验证同组发现、共享文本双向 WS 通知、离线发送文本后通过 HTTP 事件补收并 ACK；Web 四个文件与冻结候选逐字节一致，安装包路径含 Range 均为 410。早先验收脚本误把 WS 当作重连历史通道，已按实际 HTTP cursor 合约修正后通过，未改产品行为。
- 当前部署记录 `artifacts/deploy/current-ui-grace-deployment.json`，公网结果 `artifacts/deploy/20261026-111529-ui-grace/public-result.json`。完整冷备与独立回滚脚本在服务器 `/home/ubuntu/GlobalSend/backups/20261026-111529-pre-ui-grace/`。安装包未上传服务器。
- 本次仅安装、启动并核对版本；未操作手机触控或系统剪贴板。Android 后台/锁屏、Windows 实体触屏跨应用的既有实机验收缺口仍保留。

## 1.0.6 历史交付：首次打开黑屏修复

### 1.0.6当前交付

- 手机发送页新增“文件”和“图片/视频”按钮，分别调用任意文件/图片视频多选，先入待发区。3项Native针对测试和实际手机尺寸渲染通过，Web也同步按钮（61项相关测试、TS/build、17项隔离浏览器检查通过）。
- 用户新授权每次原生构建后更新`E:\Programs\GlobalSend`并重启、向ADB手机推送。因此新增标准入口`npm run release:local`及`scripts/Release-Local.ps1`，不清应用数据、不上传安装包。手机已从1.0.2覆盖至1.0.6/code7，APK副本在Download/GlobalSend-latest.apk。
- Windows单实例在Flutter之前持互斥锁，重复打开激活原窗口；进程级启动竞争/托盘/最小化/崩溃恢复通过。真实已发布1.0.6重复打开时第二进程退出0，主PID16340不变，记录`artifacts/reports/windows-1.0.6-live-single-instance.json`。
- 用户报告1.0.5初次黑屏后已修复因果：首帧前HWND隐藏被误当托盘状态，Dart卸载界面。现在UI意图初始true，仅明确托盘隐藏才卸载，首帧显示统一经过生命周期；原生回归和完整桥编译通过。实际1.0.6冷启动压缩画面已查看，正常显示已连接、收发卡片；`artifacts/screenshots/windows-1.0.6-cold-start.preview.jpg`。
- 发布脚本遇到WindowsPowerShell把Java stderr当异常，以及Stop-Process返回后资源尚映射两项实错，已分别按native退出码判定、等待进程完整退出修复。最终发布记录`artifacts/releases/latest-local.json`及`GlobalSend-1.0.6-manifest.json`；Windows正在E盘运行，手机安装/启动成功。KeepRunning验收进程持有当前窗口，不终止。
- 验证手机按钮时曾误点QQ“发送”：未先核对前台App，是否发出内容未确定，已即时告知用户并停止手机触控。两份误采集XML自动删除被策略拒绝，需用户手动移除；不绕过。记录`artifacts/reports/phone-ui-input-incident-20261026.md`。此操作不计手机选择器验收。

下方保留此前1.0.4交付与验收记录；原手机后台/锁屏与实体触屏跨应用验收缺口不因本次安装而计通过。

本次恢复已完成手机按钮、发布重启、单实例及黑屏修复。用户触发交付与随后两次目标续跑均仍缺Android后台/锁屏、Windows实体触屏跨应用结果；没有可继续独立开发的已知缺陷，不重复构建或改走被拒绝的设备操作路径。目标再次标记blocked，等待用户提供1.0.6实机结果后由root修复或完成验收。当前E盘Windows窗口及后台接收保持运行，不终止用户正在使用的应用。

## 1.0.4历史交付

> 最新候选1.0.4+5已完成本地Windows/arm64构建及Web同步修改，未替换用户窗口、未安装手机、未部署。Windows用隔离身份实际接收PNG/HTML后已关闭。手机后台/锁屏、系统回收、实体触屏跨应用落下仍待实机确认。

### 1.0.4交付

- Windows：`artifacts/releases/GlobalSend-1.0.4-windows-x64.zip`，25,629,733字节，24项，EXE 1.0.4+5；raw `client/build/workspace-1.0.4/windows/x64/runner/Release/`。
- Android：`artifacts/releases/GlobalSend-1.0.4-android-arm64-v8a.apk`，18,778,916字节（18.78MB），versionCode5/API24+，仅arm64的4个SO，内部测试签名验证通过。其他ABI仍为1.0.2。
- Web最终候选：`artifacts/candidates/web-workspace-1.0.4-ui-final`，JS `index-DZ-qfu3N.js`，CSS `index-CH24kdsW.css`。未部署，不是前一轮不带ui的1.0.4候选。
- 默认设备点击即发/成功消费，多选进入后确认；新收件单例突出预览、复制/拖出/Esc、不打断编辑；右键菜单、定位、连接徽标/设置动画、即时刷新；Windows默认950×650/记忆/托盘卸载UI和草稿恢复；Android消息通知/后台/显式弹出权限，移除旧浮坞。
- Native最终934×611客户区检查、普通滚轮浏览目标、单发清批和收件弹层3项通过；真实中心控制器5项通过；手机/桌面图片HTML实际渲染与设置1.3倍字体2项通过。Root已查看最终压缩截图。其他新增交互的独立通过日志见`artifacts/reports/native-ui-1.0.4.md`；早先host AV的组合suite不计通过。
- Web完整102项及最终相关60项通过，TS/build通过；当前源真实独立Edge/本地中心17项交互全部通过，含幂等重试、真实文件/图片预览、移动网格和动画/减少动画分支。记录`artifacts/reports/web-ui-1.0.4.md`。
- Android弹出Java6项、合并/最终APK权限已检查；记录`artifacts/reports/android-popup-1.0.4.md`。Windows托盘组件及实际Shell定位证据在对应report。构建/签名和原生后台实机不是同一项证据。
- 清理脚本的手动执行报告`artifacts/reports/cleanup-manual-20261026-100843-461.json`记录37项目标、1,357,738,405字节已删除；Root现查37条路径均已不存在。agent没有绕过原删除策略限制。
- 包清单：`artifacts/releases/GlobalSend-1.0.4-manifest.json`；使用/待测步骤：`docs/QUICK_TEST.md`。下方保留阶段实施记录。

### 当前验收依赖

当前源码、候选和已通过证据已交付，未发现需要继续改写UI的具体缺陷。完成状态仍取决于两个真实设备结果：用户在1.0.4上确认Android切后台/锁屏接收及通知复制最新正文，以及Windows手指/笔长按整卡跨应用落下。此前设备操作策略拒绝仍有效，不更换工具或拆命令重试。用户反馈失败步骤/截图后由root修复；收到通过结果后完成最终验收。首次交付后续跑核对尚无这些结果，目标保持active，不以重复构建或旧组件测试代替。

交付后连续三次目标续跑仍缺少同一组实机结果，且无其他未完成的独立开发项；目标转为blocked（等待实机验收），不标完成。当前接续条件由用户提供上述1.0.4实机通过结果或失败步骤/截图；root随后据此修复或完成验收。候选、源码与证据保留，不再重复构建或绕过设备操作限制。

### 1.0.4追加需求与当前验收

- 续跑以现有源为准：此前worker已不在live列表，已分别接续Native UI/Web UI/Android后台弹出三个完整owner，未与存活worker冲突。Native UI独占Flutter test槽；root负责整合与最终构建，版本源已更新为1.0.4+5。
- Windows窗口/托盘源已接入，bounds/关闭托盘/保留HWND/恢复最大化原生测试通过，Dart持久化和共享channel两项通过。WinMain参数警告的独立编译失败已修好并单独编译通过；完整新版应用构建与UI生命周期验收仍待完成。记录`artifacts/reports/windows-tray-1.0.4.md`。
- Android悬浮坞service、SYSTEM_ALERT_WINDOW/SPECIAL_USE权限、controller发布循环与UI入口已删除，应用内拖放/SAF/通知/后台接收保留；对应生产Java17依赖编译通过。后台弹出正在接平台显式许可路径。
- 用户要求的手动清理脚本已交付`scripts/Clean-OldArtifacts.ps1`，默认预览、`-Delete`才删。agent未运行删除模式；后续手动执行结果见上方最新交付记录。

- 2026-10-26发送交互以用户最新决定为准：默认点设备立即发送，成功清除确认批次；多选按钮进入勾选模式后确认发送多台。部分失败保留批次和目标进度，重试不重复已成功的目标/文本步骤；发送中新增内容留待下一次。Native/Web UI owners正在同步；controller批量API及针对检查已落源。
- 本次清理范围包括releases及其他项目旧build/candidate产物。重新核对37个可删目标共1,357,738,405字节，3个含链接目录跳过；删除仍在工具启动前被策略拒绝，实际删除0项。报告`artifacts/reports/cleanup-20261026.json`，未绕过拒绝。
- 另追加：新内容突出弹层可拖出/按Esc关闭、设备即时刷新、右键菜单、Windows默认950×650/窗口位置大小记忆/托盘卸载UI、设置动画和连接徽标、移除Android悬浮坞。Native与Web保留现有源改动继续实现，未切换用户运行版本。

- 用户追加：Android聊天通知（新消息/同步/远端编辑，点开应用、复制完整最新正文）、后台存活/监听/文件接收、Windows触屏拖出、Ctrl+V与剪贴板按钮兼容文本/图片/文件/文件夹。目标保留完整范围，不用1.0.3完成记录代替新增项验收。
- 通知owner `android_chat_notifications` 已完成并交出源码，真实中心事件/HTTP补收以及API36系统通知下拉、复制和点击通过；19项Android框架检查通过。`docs/RECEIVE_NOTIFICATIONS.md`记录接口与实际证据。
- Android运行owner `workspace_native_core` 已验证生产DragPreview的中文/圆角/真实缩略图、实际startDragAndDrop、文本/图片剪贴板入队、系统SAF选择和目录重打包；证据`artifacts/screenshots/android-workspace/runtime-results/{result,notification-result}.json`。根已查看相应压缩图片。
- 后台owner `android_background_receive` 拥有唯一长期FlutterEngine/FGS/Activity生命周期，正在让运行owner消费完整客户端的后台、熄屏、Activity重建与恢复证据。根已接入简洁后台开关、状态和电池设置入口；尚不把Service存在视作真实后台收发通过。
- Windows触控：根已修手势竞争（仅鼠标Pan，手指/笔长按；短滑保留滚动），并接入原生WinRT pointer drag而非鼠标左键驱动OLE；鼠标原入口保留。同时移除Windows后端错误的目录拒绝。4项目标widget检查通过，含通知从旧reader返回接收页。原生实际WinRT HWND拖拽manager、Copy数据格式及teardown通过；真实触屏跨应用落下仍待当前候选构建后确认。
- 原生WinRT初次检查在错误的COM释放顺序下AV/延迟退出，未计通过；已将WinRT apartment生命周期移至入口、先释放对象再注销，随后实际native检查正常通过。日志`artifacts/logs/windows-touch-runtime.log`。
- 根另以独立1.0.3真实Windows可执行文件+新本地中心，完成2段真实消息及PNG/HTML两个真实文件保存；数据只在`artifacts/tmp/workspace-live-windows/run-62s6r5`，已关闭该独立进程/中心，未碰用户Desktop旧窗口。该次窗口隐藏，不能当桌面交互验收。
- 全格式粘贴owner `windows_clipboard_paste` 持有SystemBridge/Windows clipboard及Ctrl+V小接线，正在实际验证格式与焦点语义；保留现有触控/通知/后台UI改动。最终本地构建版本统一1.0.4+5，1.0.3包保留不覆盖，不自动部署/安装用户手机。

### 本轮实施范围与分工

- 桌面：左右两窗格。发送区按工具栏、可滚动待发送、可滚动正方形圆角设备、共享文本组织；接收区两列网格。移动端同内容分为发送/接收两个分页。
- 工具栏仅文本和剪贴板两种快捷添加，竖线后放已发送、文件库。文件/文件夹通过添加入口与全窗口拖放加入，文件夹以保留目录层级的ZIP传输。
- 文本先确认入待发送；选设备后统一发送。共享编辑与发送草稿、系统剪贴板分开，支持组内实时双向更新。
- 卡片优先图片缩略图/文本摘要、名称、大小、时间；路由及保存位置放详情。发送源保持引用，移除发送记录不删除原文件；失效引用清除。
- Native UI由workspace_native_ui负责，native数据/目录打包/Android拖出预览由workspace_native_core负责，Web由workspace_web_ui负责；根负责共享文本中心协议、整合与验收。
- 已实现中心共享文本GET/PUT/WS和SQLite持久化；三项实际HTTP/WS检查及中心全量33项检查、构建通过。证据：`artifacts/logs/shared-text-server.log`、`workspace-server-tests.log`、`workspace-server-build.log`。

### 1.0.3交付与验收

- Windows：`artifacts/releases/GlobalSend-1.0.3-windows-x64.zip`，25,553,153字节、完整23项，EXE实际版本1.0.3+4。原始Release：`client/build/workspace-1.0.3/windows/x64/runner/Release/`。
- Android：`artifacts/releases/GlobalSend-1.0.3-android-arm64-v8a.apk`，18,748,168字节（18.75MB，低于20,000,000），versionName1.0.3 / versionCode4 / API24+，测试签名验证通过；只含arm64-v8a的4个必要SO。其他ABI本轮未重建，1.0.2旧包保留且未覆盖。
- 最终Web：`artifacts/candidates/web-workspace-1.0.3-readable`，JS `index-BKcpD4d9.js`、CSS `index-CnyMJvjk.css`。此前不带readable的工作区候选不是最终交付。中心：`server/dist/index.js`。
- 构建日志：`artifacts/logs/workspace-windows-release-1.0.3.log`（62.5s）、`workspace-android-arm64-release-1.0.3.log`（76.9s）。原生全lib及新增integration analyze无问题。APK签名/版本/ABI证据：`android-1.0.3-arm64-v8a-{signature,metadata}.log`。
- 实际Flutter widget渲染已检查1280×900、1000×720、390×844、键盘和设置1.3倍字体；最终图片/HTML已等待读取，灰色虚线遮罩“松手”可读，卡片菜单不覆盖摘要。Native UI完整35项及最终3项针对检查通过；核心11项通过。初次共享TEMP运行中断不计通过，最终使用各自项目内TEMP。
- 根用真实中心加两个原生控制器验证GET/PUT/WS双向共享编辑、并发草稿保留/显式覆盖、清空同步，且无消息卡片/文件副作用：`artifacts/logs/workspace-shared-text-integration.log`。Web另以两个真实隔离浏览器context完成同合同和IME检查：`artifacts/tmp/web-workspace-shared/run-xbCEsT/result.json`。
- Web布局实测1200×800、1000×720、390×844待发/设备/共享区无挤出，图片和HTML实际预览、全窗拖入、历史编辑、滚动保留已过。Web ZIP由Windows实际解压核对Unicode路径、空目录和字节。Web98项及时间末改3项针对检查通过，TS与最终bundle成功。
- 最后卡片可读性调整：Web主卡片标题/正文14px、元信息12px，不再在移动/compact缩到10px；390×844定向实测新邀请/消息时间标签正常换行、无卡片内部横向溢出，两列4卡底763px在容器底831px内。压缩图`web-workspace-phone-receive-receipt-labels.preview.jpg`已实际查看；证据`artifacts/tmp/web-workspace-redesign/receipt-labels-evidence.json`、`artifacts/logs/web-receipt-labels-render.log`。
- Native C++手动剪贴板桥接和既有OLE导入测试通过，Android Java17编译通过；物理Android SAF选择、系统剪贴板和新的跨应用拖出卡片图像尚未实机验收，未以widget/编译替代。
- 原生文件发送保留外部引用；目录ZIP只在传输中保留，所有关联终态后释放，历史引用原目录、重发再打包。Web仅当前页持有外部File引用，不复制发送源到OPFS；刷新后不能恢复外部引用或持续检测磁盘删除。接收时间使用实际本机接收记录；无证据的旧Web历史明确标注邀请/消息时间。
- 共享文本与新Web需升级中心后使用；当前公网未切换，本轮未上传任何安装包。清单：`artifacts/releases/GlobalSend-1.0.3-manifest.json`。

- 白纸编辑器与拖放修复版已完成两平台 Release 构建；手机覆盖安装及启动成功，Windows 经项目启动入口启动新进程 PID 43800（12:10:25）。之后实体 Escape 停止界面操作，未取得新版窗口或跨应用拖放的实机证据。
- 用户已决定继续使用前一 paper 包自行测试；本轮只开发、检查与隔离构建，不部署中心、不安装或重启客户端，不操作设备或现有浏览器。
- 新源码已接入整卡拖出、Windows 全窗口拖入、在线目标与重命名、文本查看/消息编辑同步、两列本地文件库、直接接收目录、24 小时保留与筛选清理、连接检测及选路缓存。两端隔离候选已构建并冻结，未安装或启动，见文末交付位置。
- 检查证据按对应范围记录；组合 suite 的 `did-not-complete` 不计为通过。SAF、跨应用拖放、新网络策略和新版窗口仍待切候选后实机验收。
- Web 新源码已加入全文查看/原位编辑、WebRTC、OPFS 两列文件库、预览/显式转发与可配置清理；Android 已接入按次公网蜂窝策略，中心新增授权信令和可选 STUN 部署配置。Windows ↔ 浏览器生产传输及真实 Web 文件库已实测；iPad Safari、实际公网与 Android JNI / 蜂窝 RTC 仍有缺口，见文末。未部署。

## 2026-10-24

进入实现阶段。服务端、Web、Flutter 各由一个代理负责，主代理负责跨端集成、运行验收与交付。

### 已得到的工具链证据

- Flutter doctor：Flutter 3.47.2 / Dart 3.13.2 可执行，MSVC 2022 与 Windows SDK 可用。
- Android SDK 在 `F:\Android\Sdk`；已装 API 36/37 与 build-tools 36.0.0。
- 当前 JAVA_HOME 的目录虽名为 java21，实际 Java 为 22.0.2，需按 Gradle 兼容性检查。
- Android 部分 SDK 许可证尚未接受；不能将自动接受许可藏在构建脚本内。
- Maven Google 网络检查超时；若构建失败需依据实际日志区分下载和代码问题。
- Flutter doctor 检测到 V2527A / Android 16，但尚未安装或操作该设备。
- 当前 PATH 未找到 Docker；容器实跑验收尚不可用。不会以 Compose 文件存在代替部署成功。

### 当前接口合同

`docs/API.md` 为 v1 接口来源，服务端单一维护；客户端消费相同字段与状态。初次纵切使用 HTTPS 文件中继，原生直连仍是后续必须完成的总目标，不视为已经交付。

### 已完成的运行验收

- 中心构建与 10 项服务端测试通过，含真实 SQLite 持久化/重启、并发幂等、权限、WS、文件完整性失败隔离及直传授权。日志：`artifacts/logs/server-validation.log`。
- Web TypeScript/release 构建及 12 项单测通过；逐块增量摘要不整文件读入内存。
- 主代理使用实际内置浏览器和真实本地中心，完成首设备引导、一次性邀请码加入第二会话、双端在线。
- 文本实际发送、点击复制、人工相同文本保留两项、合并复制均通过；重载后未重复入坞，脚本标签作为普通文本显示。
- 一次邀请 3 个文件：中文名 58 字节、2.5 MiB 多块文件、零字节文件。接收前等待授权，确认后逐项就绪。
- 真实下载 2,621,440 字节文件，逐字节与源文件一致；页面显示交给浏览器下载，没有伪报最终保存。下载已移至 `artifacts/downloads/sample-2.5MiB.bin`。
- 实际中心进程重启后，浏览器自动重连，原来的 5 项接收内容保持且无重复。
- 自定义地址 `http://127.0.0.1:18788/team` 导航到 `/team/app/`，新中心独立显示配对入口；返回原中心后恢复原接收坞。
- 配对页与接收坞已检查真实渲染，截图及压缩预览在 `artifacts/screenshots/`。实际浏览器控制台未见 error/warn。

### 原生端正在集成

Flutter 协议与组件初轮测试通过；Windows release 首轮构建成功。为避免额外安装 ATL，原生凭据保护使用 Windows DPAPI / Android Keystore；后续新增路径和 peer HTTPS 代码正在最终构建。Windows 桌面 UI 与 Web 的实际互通尚未验收。

### 外部依赖与未取得的验收

- iPad Safari 与 vivo 真机尚未通过验收。用户尚未确认在连接手机上安装测试 APK；不操作物理设备。
- 内置浏览器 viewport 覆盖 API 调用后，实测 innerWidth 仍为 1280，不能将截图当成 1024/窄屏通过证据；该项仍待可控视口或真实设备。
- Android wrapper 下载 Gradle 9.3.1 超时；使用现有公共缓存 Gradle 9.6.1 的单次离线尝试又缺 Kotlin 2.2.20，不能替代标准 wrapper 构建通过证据。
- Docker/正式 TLS 尚未实跑。用户确认正式服务器还未选定，先允许本地直接运行中心；不等待远程环境而停下本地开发。

### 产物位置规则

用户新增明确要求：项目专用测试、构建、截图、日志、临时目录与下载均留在本项目；工具链/可复用缓存放公共位置，新下载优先 F 盘。已加入长期记忆，测试临时目录已改到项目内；本次浏览器下载也已移回项目。

已知早期旧残留：`C:\Users\DongLan\AppData\Local\Temp\globalsend-config-lkvClL`，仅含本次失败测试生成的 73,728 字节 SQLite 文件。原代理清理被工具策略拒绝，未绕过或扩大清理范围；此项需用户手动处理。后续测试不再使用系统 temp。

另有两份 npm 日志在修正相对路径配置时写到项目父目录：`F:\Codes\Java\artifacts\logs\npm-server\2026-10-24T15_58_48_505Z-debug-0.log`（874 字节）与 `F:\Codes\Java\artifacts\logs\npm-web\2026-10-24T15_58_48_705Z-debug-0.log`（859 字节）。移回及清理命令整体被策略拒绝，未执行、未绕过。现在三处 `.npmrc` 的实际日志路径配置已修正为当前项目内，不再使用 `../artifacts`。

## 2026-10-25：组密钥与开发阶段

默认入组已改为 group 密钥：同 key 同组，首次可建组，跨组隔离；设备撤销与显式轮换分开。中心、Web 与原生端本轮源码均已交接。

用户要求停止测试前，中心 group-key 构建与 13 组测试完成，另有 v2 迁移和同组完整文件传输证据；Web 17 项测试及构建完成，含同中心切组状态清理和异步代次隔离。这些仅覆盖当时源码，不自动覆盖后续改动。

用户先按 Esc 停止 Computer Use，随后明确要求“先别测试，注重开发，稍后再测试”。已停止后续测试、analyze、构建、设备/浏览器/部署验收，不关闭原生客户端或重启现有中心。原生代理唯一仍活跃的 Android 构建 handle 32697 已通过 Ctrl-C 停止；其他项目 Gradle 未操作。

接下来只开发源码和必要协议/文档：Windows 系统拖放与可选自动剪贴板同步，Android 可选悬浮接收坞与拖放适配，下载断点恢复，以及 Web 接收坞本地清理/过期。新改动均待用户允许后再验证，不能使用先前通过记录宣称新版本已验收。

### 停止验证后完成的源码

- 中心增加单 HTTP Range、ETag/If-Range 和新下载票据重连；旧整文件 GET 保持兼容。自动剪贴板来源由中心派生，限制 8 KiB 与最长 5 分钟保留。默认生产组密钥模式不再强制 bootstrap secret，旧首设备入口改为可选兼容配置。
- Web 增加本机移除/清理已完成项、防补收重新出现、设备/组级本地隔离、正文过期清理、独立长文阅读、键盘多选复制、离线状态与自动剪贴板来源提示。浏览器仍不自动读取或写入剪贴板。
- 原生端接通组密钥加入/轮换、同中心切组清理、逐文件接收、Windows 拖入确认及 OLE 拖出、显式单目标自动剪贴板、Android 用户启用的浮坞及标准拖放/分享入口。组密钥复制带 no-sync 私有标记；关闭剪贴板同步后原生层停止监听正文。
- 原生 peer/relay 与 Java 下载接入 Range 恢复：新票据重试，206 校验偏移，200 覆盖重写，最终摘要通过才确认接收；新文件以独立目录保留安全原名，不迁移旧文件。中心同时修复分块写入在等待磁盘检查期间遇到撤销/取消的状态竞态，避免重新生成失管文件。
- 根开发入口统一目录配置：`npm start` 对已编译中心使用项目内本地状态，`npm run client:windows` 明确启动 Debug（可显式选择 Release），不自动编译或替换配置。开发服务的 npm 日志也显式留在根 `artifacts/logs/`。

上述均为源码交付，尚未构建或运行验证；现有 `dist`、旧 Release 和运行中的 8787 服务不因此自动包含新功能。

原生新增 `desktop_drop` 精确依赖 0.8.4 仅写入声明，尚未解析依赖或更新生成注册文件。Flutter 引擎被回收后的独立常驻收包、OEM 私有 vivo 协议及系统级任意位置接收条仍未实现；当前浮坞依赖应用通信引擎存活。具体源码范围与后续验收入口见 `client/README.md`、`docs/NATIVE_TESTING.md`。后续按用户安排恢复验证，当前不扩展新功能或替换运行产物。

### 本地备份开发补充

新增 `scripts/backup.mjs` 与 `npm run backup:local`：由操作者先停服，显式指定实例 data/relay，备份完整目录至项目 `backups/`，包含 WAL/SHM；兼容早期 data/relay 嵌套布局，不重复复制中继文件。失败副本留 `.incomplete-` 标记，完成后才发布目录；遇符号链接/junction/特殊文件中止。清单记录原目录，恢复要求回到相同绝对路径，不冒充路径迁移工具。此入口尚未执行，当前服务未停、未读取业务数据库，升级/恢复验收仍待后续安排。

### 便利优先与路径选择：新增开发要求

用户要求减少操作、打开即用，同时保证一定安全并保留手动选择。原生/Web 分别开发同组默认自动接收与手动确认开关；原生开发最近中心自动恢复、简化入组、自动 LAN→公网 IP→中继及手动路径指定。保留组隔离、TLS、完整性、路径与资源保护；剪贴板/浮坞仍显式开启。手动路径失败不自动换路，Web 仍如实使用中继。这些为本轮开发中要求，不代表已运行通过。

中心已追加兼容的 routePreference 合同与能力字段，写入原有 offer JSON，无需 SQL schema 升级。非 auto 为发送方固定约束：relay 拒直连票据，lan/public 拒中继路径；中心只强制直连/中继边界，不伪称可观察真实 LAN/公网路由。旧 offer 缺省 auto。Web 已接默认记住设备与自动接受、手动开关及重连补选中继；强制 LAN/公网的邀请显示原生能力要求，不自动改路。上述仅源码，现运行服务与 dist 均未更新。

原生本轮源码已交接：最近中心启动恢复及离线重试、首次中心/设备名/group 一次提交、登录后折叠配置、同组自动接收与手动开关。自动选路分 LAN→公网默认网→已授权蜂窝公网→中继；手动发送约束优先于本机接收偏好，逐项记录选路和原因，删除发送方八秒抢先中继计时。发送文件可通过“换路径重发”复用源文件引用生成新 offer，仅取消旧单项；接收方本机手动偏好失败可改自动重试，但不能覆盖发送方硬约束。换组重置自动接收，普通同组重连保留开关；路径偏好按中心保存。未运行任何测试、分析、构建、依赖解析或 GUI/设备操作。

主代理另已在原生源码补 sendText/offer/enroll 的会话代次与 API 身份检查，避免 await 后复用新中心 API 或将旧响应注入新队列；sendStaged 只发送本次确认的快照，不连带发送后来拖入内容。此修改同样未经测试或构建。

## 2026-10-25：恢复验证与公网 Docker 实跑

用户回复“允许你全权操作”后，恢复构建与联调；随后提供 ConnectToServer.ps1 并要求 Docker 部署、禁止读取 SSH 私钥。仅查看连接脚本，调用现有 OpenSSH 身份文件连接，没有读取、复制或输出私钥内容。

- 中心构建与 16 项测试通过；Web 类型检查、生产构建与 24 项测试通过。具体日志见 `artifacts/logs/server-route/` 和 `artifacts/logs/web-*-validation.log`。
- 原生 analyze 无问题、18 项测试通过，含真实 1.2 MB LAN 保存、直连失败回退中继、手动不降级、换路径重发、Range 与会话隔离；Windows 标准 Release 构建通过。当前最终包与 Android 进展由 `docs/NATIVE_TESTING.md` 记录。
- 本地原中心当时已无监听，先做完整停服备份到 `backups/2026-10-25T01-47-39-410Z-RjsheU`。实际读取备份 SQLite：完整性正常、实例元数据及记录数与源一致，三份中继文件逐字节一致。之后用新版启动本地 8787，现 session 11236。
- 实际本地浏览器完成新 group 一步加入、自动接收三文件（中文名/1,200,000 字节/空文件）、文本双向/ACK与点击复制、真实下载字节一致、关闭自动接收后只接所选项、拒绝项在重新开启与刷新后不复活，刷新自动恢复登录。没有控制台 warning/error。下载已即时从工具默认 Downloads 移回 `artifacts/downloads/ui-多块验收.bin`；截图压缩预览在 `artifacts/screenshots/web-acceptance-preview.jpg`。
- 实际 Windows 新 EXE 连接页已前台检查；发现未知中心误显示“不允许建组”，已修正并增量生成新版。配对/系统拖放/真实 Windows↔Web GUI 全链路尚未完成，不能由控制器集成代替。
- 公网服务器 Ubuntu x86_64，Docker 29.9.2 / Compose 5.6.1。项目位于 `/home/ubuntu/GlobalSend/releases/20261025-0955`，独立 globalsend app+caddy 容器；其他项目保持运行。生产 IP 证书由 Let's Encrypt 签发，增加 `default_sni` 后无 SNI 客户端也能校验证书；先 staging 实验，再用独立生产证书卷，不关闭证书验证。
- 用户在云控制台放行 TCP 443 后，本机公网直连 HTTPS ready 200；`/globalsend` 308 到 `/globalsend/app/`。公网浏览器页面已实际渲染，压缩截图 `artifacts/screenshots/public-entry-preview.jpg`。
- 公网外部协议集成完整通过：路径前缀、默认 CA 验证、真实 WS Host/Origin、同 key 双设备文本/ACK、中文/>1 MiB/0 byte 多文件与真实下载字节、单次票、manual 路径约束。日志 `artifacts/logs/remote/public-external-smoke.log`；测试使用独立生成组与数据，不读取用户正文。
- 远端 app 容器重建后保留实例、测试凭据与文件；停服复制持久卷到项目备份，再恢复到独立卷启动真实 app，身份、凭据、文件验证通过。原生产卷不被恢复测试覆盖。日志 `artifacts/logs/remote/{remote-smoke-20261025,backup-recreate-20261025,restore-check-20261025}.log`。

真实 Android/vivo、iPad Safari、校园网/蜂窝、公网 IP 原生直连及系统拖放仍需对应设备与网络。当前 adb 没有已连接设备；这些缺口保留在完整目标内。

### 公网默认客户端与界面停止点

Windows 已追加预填公网中心且保留自定义/已保存地址优先；受影响 5 项 widget 检查有效通过、analyze 无问题、标准 Release 重构完成。当前冻结完整包为 `artifacts/releases/windows-public-default-20261025-101658/` 与同名 ZIP，早先 windows-validated 包不是最终默认地址版。合并运行 widget 与启动 suite 曾出现 harness did-not-complete，无产品断言失败；单独受影响 widget 的 JSON 报告已成功，不以异常运行充当通过。

用户确认连接手机后，ADB 后来实际识别 V2527A / Android 16 / API 36；一次目标包查询因系统 user 666 权限被拒，未安装、卸载或清理任何手机应用。随后用户实体 Escape 停止 Computer Use：主代理停止界面与手机操作，仅保留已启动的标准 APK 构建到终态。恢复真实设备/GUI 验收需要用户再次允许继续；现有公网 Docker 服务保持运行。

### Android 安装包已生成

已启动的标准 `flutter build apk --release --no-pub` 最终 exit 0，构建 333.3 秒。副本 `artifacts/releases/GlobalSend-1.0.0-android-public-default-debug-signed.apk`（56,864,618 字节），含公网默认中心。主代理仅做本地交付元数据/签名检查：包名 `dev.globalsend.globalsend`、版本 1.0.0 / 1、min API 24、target API 36、arm64-v8a/armeabi-v7a/x86_64，APK v2 签名验证通过。签名配置为 Flutter 模板 debug key，明确作为内部测试包，不声称正式商店签名或手机安装成功。没有恢复任何 GUI/adb 操作。

### vivo 实机链路与界面改版

用户回复“直接开始测试吧”后恢复设备操作，以 `adb install -r --user 0` 成功更新 vivo V2527A（Android 16 / API 36），保留应用数据；未修改手机全局网络设置。

- 公网 Web 与手机实际双向发送独立文本，收到 ACK；手机点击复制成功。
- Web 向手机发送中文文件（47 字节）、1,200,000 字节文件及空文件，手机均显示已保存，实际路径为中继。
- Windows 真实原生控制器探针向手机发送中文文件（69 字节）、2,621,441 字节文件及空文件，三项均确认保存，实际路径为 LAN。探针不是 Windows GUI 验收；完成后已停止。证据 `artifacts/live-native-peer/consumed-lan-auto-status.json`、`artifacts/screenshots/android-live-receive-preview.jpg`。
- 实测发现 Web 已收到保存回执却仍显示等待下载，已修复状态优先级，针对性回归与构建通过并部署公网。

用户要求蜂窝直传不限流量、中继尽量避免大流量；随后要求重做界面、精简文案。当前原生与 Web 分别重构发送/接收布局，将连接、高级路径及设备管理收进设置，去掉重复说明。中继单文件超过 32 MiB 采用本机确认；直连仍优先，不给蜂窝直传加硬性字节上限。此段为正在实现的设计，改版产物尚待实际渲染与设备验收。

Web 紧凑版已部署公网：发送/接收双栏、短状态与动作、折叠设置；大文件批次留手动接收，阈值按组保存。11 项局部回归、2 项单位回归与生产构建通过。主代理实际刷新公网页面，确认身份/历史保留、32.0 MiB 标签及新布局，压缩截图 `artifacts/screenshots/public-compact-preview.jpg`。旧镜像 `globalsend:before-compact-ui-20261025` 与远端源码副本保留；仅重建 globalsend app，健康检查通过。

原生改版已冻结：`artifacts/releases/windows-compact-ui-20261025/` 与同名 ZIP；`artifacts/releases/GlobalSend-1.0.0-compact-ui-android-debug-signed.apk`。analyze 无问题、24 项测试通过、两平台 Release 成功；新增中继确认、混合批次、恢复/取消与设置持久化检查。主代理查看手机/桌面压缩组件渲染，布局、短文案及内置中文字体通过，预览 `client/build/compact-{mobile,desktop}.preview.jpg`。

新原生包未完成设备窗口验收：尝试覆盖安装时 ADB 列表为空，已请求用户重连手机；Windows 未发现 GlobalSend 窗口，启动工具返回 `GetCursorPos` 拒绝访问，未绕过会话权限。旧设备数据未清理。等待手机连接和可交互桌面后继续实际界面检查。

### 响应式实测与手机接收首屏修正

继续目标时复查：ADB 仍无设备，桌面仍无可选择的 GlobalSend 窗口。转而使用浏览器视口接口检查当前公网 Web：820×1180 平板双栏及设置可读、无横向溢出；390×844 手机原单栏把接收坞推至 y633，首屏被发送表单占据。

已修正 ≤760 px 布局：增加“接收 / 发送”，默认直接显示接收。切换只更新视图属性，不重建表单；桌面保留双栏。2 项针对回归与生产构建通过，产物 `index-CqYpY4MR.js` / `index-BSQ7qbgE.css`，已部署公网 app 并通过健康检查。旧镜像 `globalsend:before-mobile-nav-20261025` 保留。

主代理在公网页面实际切换收发、输入草稿、往返切换后确认草稿保留；390 px 页面宽与内容宽一致，无横向溢出。压缩截图 `artifacts/screenshots/web-mobile-nav-preview.jpg`。最后清空本次测试草稿、恢复正常视口，确认 1280 px 同时显示发送与接收。此为浏览器响应式证据，iPad Safari 真机文件操作仍未验收。

仍待完成：Windows GUI 配对与互传、原生公网/蜂窝路径、切网、系统拖放、iPad Safari。已有链路成功不替代这些验收。

连续三轮复核的设备依赖仍未恢复：ADB 无设备；旧 Windows 进程 38176 存活，但 UI 工具没有可操作的 GlobalSend 窗口，先前启动返回会话访问拒绝。未终止该进程、未绕过访问限制。Web 改版与响应式修正已交付，下一步必须依赖用户重新连接手机并恢复可交互桌面；iPad 项还需要实际 Safari 设备。目标在此等待设备条件，不判定完成。

### 桌面恢复后的实际验收

用户确认桌面恢复后，新版 Windows 窗口可操作。直接打开冻结 EXE 使用独立的系统数据目录，显示连接页；关闭该未登录窗口后，停止旧版确切进程 38176，将原项目内状态完整备份到 `artifacts/backups/native-before-compact-20261025/`，通过既有 `node scripts/client.mjs --release` 入口运行新版，继续使用 `artifacts/native-state/`。原设备身份、目标与历史自动恢复，无需再次入组。当前运行句柄 78854，保留服务。

- 已实际查看连接页、登录后双栏及独立设置，中文资产字体正常；截图 `artifacts/screenshots/windows-compact-{connect,active,receive,settings}-preview.jpg`。
- Windows GUI 键盘输入“1”并发送，公网 Web 接收；Web 回发中文多行文本，Windows 独立条目显示，双向文本已有真实 GUI 证据。自动化 `type_text` 对 Flutter 输入未生效，改用实际键盘路径验证，没有将工具输入失败算作传输失败。
- Windows 系统文件对话框实际选中中文 47 字节、1,200,000 字节和空文件；本地持久状态三项均为 `ready / relay`。这证明已到中心，尚未证明 Web 下载保存。
- Web 打开系统文件选择后，工具返回隐藏 input 节点已消失；检查源码确认整页重绘会替换 file/resume input。正在修复为独立持久节点，避免慢选文件时被网络刷新移除。

手机 ADB 仍无设备。之后一次浏览器调用在分发前中止，本轮未重复浏览器操作；未将新文件接收、复制成功或完整系统拖放写成通过。

文件选择器修复已上线：`#file-input` / `#resume-file` 移出重绘根节点，只安装一次监听；选择后清空值支持再次选择同文件，切会话清除旧上下文，续传保留打开时的目标。14 项控制器/真实 DOM 与 17 项模型测试、类型检查和构建通过。公网 Docker 重建并健康，外部读取 HTML 200，短标题 `GlobalSend`、持久 input 与新 JS `index-yZJ07Mpx.js` 已生效。旧镜像 `globalsend:before-picker-fix-20261025` 保留。真实文件对话框重验仍待下一次浏览器操作；不能用 DOM 回归代替。

本轮 Windows GUI 状态摘要已写入 `artifacts/logs/windows-compact-gui-transfer-state.json`，仅含条目 ID、类型、方向、大小、状态和路径，不含正文或凭据。

## 文本编辑器重做与 Android 拖放修复

用户再次要求改善界面、文本框及 Android 文件拖拽。当前候选改为白纸编辑面、清晰焦点、字数、全文编辑和 Ctrl/⌘+Enter 发送；桌面发送栏约 42%，手机保留接收/发送。全文编辑保留草稿、选区，返回恢复焦点；中文候选未提交时不发送。主代理已查看手机发送、全文编辑、接收文件拖柄及桌面编辑的真实组件渲染，预览 `client/build/paper-*.preview.jpg`。

- Flutter：原 12 项交互测试通过，新增文件拖柄对应 5 项子集通过；独立复现并修复 IME 误发送及返回焦点问题，4 项针对检查通过。组合 suite 仍有间歇 `did-not-complete`，未当作全绿；有效日志为 `test-paper-interactions-final.log`、`test-paper-affected-verbose.log`、`test-editor-ime-{inline,full-refresh}-verbose.log`、`test-editor-full-focus-final.log`。控制器新增拖入/导入快照消费，3 项事件检查通过。
- Android：修复 `desktop_drop` 与原生根监听冲突、URI 授权过早释放、错误 MIME；FlutterView 内的被动叶子 View 接收完整拖放事件，普通触摸穿透。多文件仅暂存，已保存文件长按拖出。独立框架检查又修复换 FlutterView 后残留拖入高亮，最终 7 项框架检查通过，涵盖触摸透传、重绑及持权直到复制完成。日志 `client/build/logs/android-drag-independent-passed.log`；源码交接 `artifacts/android-drag-handoff.md`。
- Web：同一 textarea 保留草稿/选区，展开编辑、快捷键及 IME 绘制处理已完成，17 项相关 DOM 检查和生产构建通过。新产物 `index-CXE7F3_H.js` / `index-CmAMXLGd.css` 尚未部署；主代理浏览器调用未分发，独立协作者也收到 `Browser is not available: iab`，实际浏览器视觉仍缺证据。公网仍运行已验证的文件选择器修复版。
- 供用户使用的简短步骤：`docs/QUICK_TEST.md`。

用户随后要求尽快在两端启动，ADB 当时已识别手机。一次启动操作被实体 Escape 中止，后台 APK 构建句柄 79136、Windows 构建句柄 74077 随后均成功收尾。

获准恢复后，手机 `adb install -r --user 0` 返回 Success，应用启动成功；Windows 经项目启动入口（session 78138）运行新 PID 43800，启动时间 12:10:25，旧进程已退出。对应 Windows `data/app.so` 生成时间为 12:08:09。随后视觉检查再次遭实体 Escape，未获取新窗口或手机 UI 验收证据。用户接手测试后，代理停止设备控制；新版跨应用拖放仍待用户实测结果。

## 文件库、接收目录与网络增强：本轮源码交接

### 使用行为

- 接收卡片支持手机长按、Windows 按住拖动整卡；Windows 窗口内任意区域可拖入文件或文字，导入后只进待发送区。
- 设备栏、发送与转发目标只显示在线设备，presence 更新自动显示/隐藏；重命名通知同组设备，离线历史保留。
- 已发文字可编辑原消息并同步对方，不生成另一条新消息；收到文字只读、可复制全部。常见 UTF-8/带 BOM 的 UTF-16 文本文件支持只读预览，大文件显示前 1 MiB 的预览提示。
- 文件库两列显示已保存文件，离线可看；默认接收时间倒序，也可按名称、大小排序。文件库长按进入编辑，提供重命名、删除和向在线设备转发；图片有缩略图和缩放预览。文件库长按编辑与接收卡片长按拖出分属不同界面。
- 自选接收位置直接写入 Windows 文件夹或 Android SAF 目录，不保留第二份永久接收副本。默认按接收时间保留 24 小时，可改小时/天；清理类别与严格大于/小于 MiB 条件组合生效。删除包括自选目录内本应用记录的接收文件，不扫描其他文件，也不删除原发送文件或另行导出的副本。
- 每分钟检测连接，网卡变化时提前重测并重新发布 IPv4/IPv6；自动阶段仍为 LAN → 公网 → 中继，阶段内按缓存可达性和延迟排序。手动模式保留；Android 蜂窝探测按 socket 选择网络并保留错误，不绑定全进程。

### 已取得的源码证据

- 文件库与图片：`client/build/logs/test-saved-files-screen-storage-final.log` 5 项通过，覆盖两列/排序/长按编辑、重命名/转发/删除、缩放、错误回退及 content URI 句柄释放；离线恢复与清理筛选分别见 `test-saved-files-offline-final.log`、`test-saved-files-filters-final.log`。
- 接收目录：`receive-destination-dart-test.log` 2 项通过；`test-saved-files-destination-windows-final.log` 证明直接写入所选 Windows 目录、保留重名文件且只清理注册文件。Android DocumentsProvider 框架 fixture 5 项通过，日志 `receive-directory-framework-test.log`；Windows host 用真实 Provider/PFD 生命周期，但将 `ioPath` 映射到 backing file，不能证明 vivo `/proc/self/fd` 直接写路径。实际 SAF 提供方仍待设备验收，合同见 `artifacts/receive-destination-handoff.md`。
- 网络与消息：`test-reachability-final.log` 4 项、`test-network-controller-text-final.log` 4 项通过；覆盖分阶段排序、网卡变化、过期缓存、离线目标排除、原生 socket 探测桥及消息原位编辑/只读接收。
- UI 合并检查未通过，不写成全绿；受影响的目标保持、在线列表和筛选草稿 3 项单独通过，日志 `test-ui-failed-targets-final.log`。连接检测窄屏页另 1 项通过，见 `test-reachability-screen.log`。最终 `analyze-editor-settings-final.log` 为全客户端分析无问题。
- 中心重命名、文字编辑持久化各 1 项通过，见 `artifacts/logs/server-device-rename-test.log`、`server-text-edit-test.log`；Web 在线管理与编辑事件模型各 1 项通过，见 `web-online-settings-management-final.log`、`web-text-edit-model-test.log`。

以上是本地源码与检查证据，不会更新用户正在使用的客户端或公网中心。已发消息编辑同步依赖新中心 API；本轮未部署，现公网不据此宣称支持。新 Web 未实现文件库或 WebRTC，当前中继是实现选择，不是 iPad/Safari 的系统限制。

### 候选构建与交付

- Windows Release 成功（148.5 秒），日志 `client/build/logs/windows-release-library-network.log`。隔离 EXE 为 `client/build/library-network-20261025/windows/x64/runner/Release/globalsend.exe`；完整包 `artifacts/releases/GlobalSend-1.0.0-library-network-20261025-windows.zip`，16,330,492 字节，含 EXE、DLL 和 `data/app.so`。原标准开发构建与用户运行进程未替换。
- Android `assembleRelease` 成功（150.1 秒），日志 `client/build/logs/android-release-library-network.log`。冻结包 `artifacts/releases/GlobalSend-1.0.0-library-network-20261025-android-debug-signed.apk`，62,223,289 字节，沿用内部测试签名；未覆盖安装或启动。
- 本轮中心和 Web 未部署。消息编辑同步与设备重命名需新中心 API，不能由候选 APK/ZIP 的构建成功推定现公网可用。

用户自行切换候选后继续真实 SAF、整卡跨 App 拖放、网卡变化/蜂窝路径、新目录清理与新版窗口验收。步骤及保留项目登录的隔离 EXE 命令见 `docs/QUICK_TEST.md`。

## 继续开发：本机文件连续性与反向直传

用户明确暂不切换运行版本，本轮只改源码和隔离检查，不安装、启动或部署。

- 修复失败接收取消后半文件残留：默认目录、自选 Windows 目录、SAF URI 都清理本应用对应半文件。默认目录任务断线后即使更改接收位置，重试仍在原位置续传，不另建副本。4 项针对回归通过，见 `client/build/logs/test-partial-lifecycle-final.log`。
- 文件库现在显示本应用在本机保存的全部文件，不因换中心或退出分组而隐藏。当前接收坞和设备仍按会话隔离；跨组文件只有用户明确选择当前在线目标时才转发。未登录页面也保留文件库入口。2 项数据/界面检查通过，见 `test-library-continuity.log`。
- 已补原生 HTTPS 反向推送：同一阶段先拉取、再尝试发送方主动连接接收方，最后才进入下一阶段。真正双控制器与中心通过 LAN 反向续传，优先于测试中另一个可达的公网候选；文件完整、仅一个成品、中心 offset 与实际中继文件字节均为 0。同一检查还验证新能力双方均不可达时回退、手动 LAN 失败不降级，以及完成进度不误用中继 offset。地址类别在 loopback 中注入，不能据此声称真实校园网已验证。见 `test-reverse-direct-integration.log`（2 项）。
- 停止旧 push 写入后，在同一半文件上建立新 attempt 的真实 socket 生命周期检查通过；原有拉取/中继/手动路径集成检查也通过，见 `test-reverse-direct-final.log` 前两项与 `test-reverse-legacy-compat.log`。修复了完成状态覆盖回退原因、direct 完成进度误读中继 offset 为 0 的问题。
- 中心反向票据方向、收件同意、阶段、单次使用和 attempt 失效检查，以及原拉取授权兼容检查，共 2 项通过，见 `artifacts/logs/server-reverse-authorization-test.log`。Dart 桥接参数/进度隔离 2 项通过，见 `test-network-push-bridge.log`；原拉取和反向推送均支持带尾斜线的 HTTPS origin，见 `test-reverse-direct-origins-final.log`。Android 逐 Network pinned 上传已编译，见 `android-reverse-java-compile.log`；蜂窝实际传输仍待 vivo 验收。
- Web 补齐收到文字只读查看、全选/复制全部和已发消息原位编辑，草稿跨刷新与关闭保留，输入法组合不触发保存；8 项 DOM 回归及生产构建通过。独立 headless Edge 使用真实 UI/CSS 检查平板和手机尺寸，均无横向溢出，编辑保存状态正常；预览在 `artifacts/screenshots/web-reader-*.preview.jpg`，工具为 `web/tool/preview_text_reader.mjs`。这不替代 iPad Safari 真机验收。

反向推送需新中心与两端都支持；该冻结候选不含后续开发的 WebRTC。当前未进行实机切换或公网部署。

### 本节新候选

- Windows 隔离 Release 构建 118.2 秒成功，ZIP 为 `artifacts/releases/GlobalSend-1.0.0-reverse-direct-20261025-windows.zip`（16,350,893 字节）；22 项含 EXE、DLL 和 app.so，日志 `client/build/logs/windows-release-reverse-direct.log`。
- Android Release 构建 168.2 秒成功，APK 为 `artifacts/releases/GlobalSend-1.0.0-reverse-direct-20261025-android-debug-signed.apk`（62,403,513 字节），包/ABI/最低版本已读回，日志 `client/build/logs/android-release-reverse-direct.log`。仍为内部测试签名。
- 最终客户端分析无问题，见 `analyze-reverse-direct-final.log`。中心与 Web 生产构建通过，尚未部署。

以上新包包含本节改动，上一版 library-network 包保留。安装/启动和 vivo SAF、蜂窝 IPv6、跨 App 拖放、iPad Safari 验收待用户允许切换后继续。

## 继续开发：WebRTC 文件直传

保持用户“暂不切换运行版本”的决定。本轮仅源码、独立隐藏 fixture、随机端口测试中心及 headless Edge；未安装/启动产品、操作手机或当前标签，也未部署公网。

- 中心新增五分钟 RTC 能力注册和接收者控制的 per-file 信令。SDP/ICE 仅临时交换给两位参与者，不写持久事件；与 HTTPS pull/push、中继及取消互斥。真实 HTTP/WS 三项通过，旧授权/手动路径三项兼容通过；中心构建及 Node24 strip-types 源码入口通过。日志 `server-rtc-{endpoints-test,legacy-compat-test,build,source-import}.log`。
- 原生和 Web 都接入 data-only `globalsend-file-v1`：16 KiB 分块、512 KiB 提交窗口、同一半文件续传。原生 controller 仍按同阶段 HTTPS 拉取/反向推送优先，再 RTC，最后进入下一阶段或中继。成功完整性及最终回执沿用 `/received`。
- 根使用真实生产原生 transport 与浏览器 channel / OPFS Worker，在本机实际网卡候选上完成双向 1,049,307 字节，从 12,345 字节半文件续传。原生逐字节一致、浏览器磁盘 SHA 一致；两项最终 direct/received，中心 offset 与实际中继文件字节均 0。空文件另双向通过。日志 `rtc-production-native-browser{,-empty}.log`；证据目录 `artifacts/tmp/rtc-production-interop/run-I62WNu/`、`run-p5UDQz/`。没有外部 STUN/TURN，不以本机结果推定跨公网。
- 联调实际发现并修复插件默认媒体 offer（显式关闭 audio/video）、浏览器 ICE `usernameFragment` 多余字段、成功提前 stop 的结束竞态、hash 耗时误触45秒通道超时、重复 close 未等磁盘写完的竞态。`complete` 统一只表示字节落盘，最终 hash/received 再确认保存。
- 原生定向七项通过（候选、controller、旧 HTTPS/relay 全栈），另四项 controller 检查含旧写入结束后消费新 attempt；analyze 无问题。Android Java 与 WebRTC 插件编译成功，1m32s；首次依赖解析失败通过 exact audioswitch 的 JitPack repository 规则修复，未改公共缓存。日志 `client/build/logs/test-rtc-native-final.log`、`test-rtc-controller-handoff.log`、`analyze-rtc-native-final.log`、`android-rtc-java-compile-final.log`。
- Web 默认自动直连，手动 LAN/公网不降级；大文件中继需确认，直连不套中继上限。OPFS Worker 直接落盘、支持续传和24小时清理；用户手动下载副本不由网页清理。41项定向检查、类型检查和隔离生产构建通过；真实 Edge 四尺寸收发与选路控件无溢出，根看过压缩桌面/手机截图。见 `web-rtc-{targeted-test,build,route-visual}.log` 和 `artifacts/screenshots/web-rtc-routes-*.preview.jpg`。

源码与复现入口已保留在 `client/tool/rtc_{probe_main,transfer_probe}.dart`、`scripts/build-rtc-probe.mjs`、`web/tool/accept_rtc_native.mjs`。Web 隔离候选为 `artifacts/candidates/web-rtc/`（`index-Cj2rKsox.js`）；当前 `web/dist` 未改。没有生成新的 RTC 产品 ZIP/APK，既有 reverse-direct 冻结包不含此功能。

Android RTC 目前固定排除蜂窝网卡；原生对端的授权蜂窝 HTTPS 保留，但 Android ↔ Web 的蜂窝 IPv6 RTC 仍未完成。已查精确插件/API，`low_cost` 不能替代禁止蜂窝，factory也不能原位更新mask；下一开发项是项目内 Android data-only adapter，按授权使用独立 factory，复用现有 Dart 信令/分块，不改公共插件缓存或全进程网络。iPad Safari、跨公网及全部设备验收仍待允许切换后进行。详细规则和复现见 `docs/WEBRTC_DEVELOPMENT.md`。

## 继续开发：按次蜂窝策略与完整 Web 文件库

上一节的 Android RTC 蜂窝源码缺口已继续实现；真实网络验收仍待恢复切版。

- Android 项目内 data-only bridge 使用两个固定策略 factory，仅公网且已授权的 attempt 允许蜂窝，独占本次 `requestNetwork` lease；局域网 / 未授权帧受 selected-pair 网络 gate 约束。被动 detector 只观察网络，不使用默认监测器暗中持有的 mobile lease，不绑定全进程网络。网络类别及 IPv4 / IPv6 更新到状态。
- 独立只读审核发现并修复三项：关闭中的 owner 从追踪表消失导致 revoke 提前返回、Windows plugin 重复 close 报错、Android plugin initializer factory 生命周期与跨 engine 重初始化冲突。Android 现由进程级 `RtcRuntime` 单次官方初始化，自有 factory 随 engine 释放；Windows dispose / close 幂等各一次。
- 11 项 Dart 回归、7 项 Java / Robolectric 与 Android 编译通过，analyze 无问题。证据 `client/build/logs/test-rtc-cellular-final.log`、`android-rtc-network-final.log`、`analyze-rtc-cellular-final.log`；精确 AAR 的初始化与默认蜂窝 lease 字节码证据在 `artifacts/toolchain-metadata/rtc-aar-*.txt`。这些不是 Android JNI 真机证明。
- 根在最终 teardown 源码下重新构建隐藏消费端，真实 Windows ↔ 浏览器生产通道双向 1,049,307 字节、12,345 字节续传再次通过，字节/hash 完整、中继 0。日志 `artifacts/logs/rtc-network-policy-windows-final-{build,interop}.log`，结果 `artifacts/tmp/rtc-production-interop/run-G3mRiU/result.json`。
- Web 本机库跨同 origin scope 枚举已保存文件，退出/换组仍可查看，不复制数据；两列、排序、长按编辑、重命名、删除、图片/文本预览、显式转发在线设备。默认一天，小时/天及类别/严格大小规则在本机保存并作用既有文件。修复大段 UTF8 截断误识别、接收坞缓存联动和长列表关闭入口。55 项定向检查、类型检查及隔离构建通过；六场景实际 Edge 渲染无溢出，压缩图已查看。
- 根用真实主入口、Worker/OPFS、两个实际分组完成完整库链路，包括真实下载、重命名保字节/MIME、图片解码、整卡长按、旧组不发送、当前组显式转发、时长/类别/大小清理、手动删除最后一项、下载副本保留。日志 `artifacts/logs/web-library-real-opfs-final.log`，结果 `artifacts/tmp/web-library-acceptance/run-vvC4bB/result.json`。复制按钮验证使用独立 stub，没有操作系统剪贴板。
- 可选自托管 STUN 已加入 Docker profile，固定 coturn 4.18.0-r0、STUN-only、仅 UDP 3478。默认不启动、`STUN_URLS` 不自动填写；Compose 官方 schema 与精确版本参数静态检查通过。开发机无 Docker，未拉镜像、运行容器、改端口或部署公网，UDP Binding 尚待获准部署后验收。入口和关闭命令在 `deploy/README.md`。

### 当前新候选

Windows ZIP `artifacts/releases/GlobalSend-1.0.0-rtc-library-20261025-windows.zip`（25,400,421 字节），隔离 Release 构建 234.8 秒；23 项中已核对 EXE、数据与 WebRTC DLL。Android 通用 APK `artifacts/releases/GlobalSend-1.0.0-rtc-library-20261025-android-debug-signed.apk`（98,106,482 字节），Release 构建 173.4 秒；API 24+、arm64/ARMv7/x86_64，APK v2 签名通过，无摄像头/录音/蓝牙/音频设置新增权限。两者未启动或安装。

Web 隔离候选 `artifacts/candidates/web-library/`（`index-CgsmvXgs.js` / `index-6XfWDQ7N.css` / `rtc_storage.worker-D6cJkgmK.js`）未替换 `web/dist`，公网未部署。原 reverse-direct 等候选保留。Windows 一次构建的专用工具配置在项目内 `client/client/build/rtc-library-tool-config/`；整目录整理操作被工具策略拒绝，未绕过，最终产品位于上述正常 build / releases 位置。

仍需恢复切版后验收 Android JNI / 蜂窝 IPv6 / 实际换路、vivo SAF 与跨应用拖放、Windows 新窗口和 iPad Safari。周期检测目前覆盖原生 HTTPS 地址；WebRTC 候选在文件协商时测试，不能把能力注册当作空闲期的周期可达性证据。

## 已上线一版；安装包改为仅本地、按架构分发

用户授权后，新中心 / Web 部署到 `/home/ubuntu/GlobalSend/releases/20261025-163425-rtc`，镜像 `globalsend:rtc-20261025-163425`。公网健康、WSS/文本/编辑/ACK/设备名/RTC 能力通过；原 instanceId、原九设备/三组及数据、证书卷保留。部署、独立健康检查及回滚入口在 `artifacts/deploy/rtc-deployment-report.md`。Windows 经现有项目身份启动新版，原记录可读；备份在 `artifacts/backups/native-before-rtc-library-20261025-163155/`。

首次把三种 ABI 的 98,106,482 字节通用 APK 作为默认下载，是分发选择错误。用户要求按架构分开、20 MB 内且不要挂服务器。已移除全部安装包及下载页公开路由，HEAD/Range 410，Web/health 200，WSS 心跳通过，未重启 app/Caddy。未来 Compose 不再挂安装包目录；现有闲置只读 mount 留待正常维护移除。没有上传后续压缩包。验收 `artifacts/deploy/package-hosting-disabled-result.json`。

本地 vivo / arm64 包已实测 **18,603,360 字节（18.6 MB / 17.74 MiB）**，路径 `artifacts/releases/GlobalSend-1.0.0-android-arm64-v8a.apk`，versionCode 1、API24+、仅 arm64-v8a，APK v2 签名通过，四个必要 native SO 齐全。使用 Android 标准安装时 native 库解压，不删传输功能；APK 大小与安装后占用不同。证据 `artifacts/logs/android-compact-arm64-{result,metadata,signature}.json/log`、`client/build/logs/android-release-arm64-compressed.log`。

可复用入口 `node scripts/build-android.mjs` 默认 arm64；`--abi=armeabi-v7a` / `--abi=x86_64` 分架构，`--universal` 仅兼容用途。真实发现：`--target-platform` 不过滤依赖 AAR 的其他 ABI；本 SDK 会在后期覆盖默认 NDK filters，且通过环境传自定义 Gradle 属性未生效。现用明确 `--android-project-arg=globalsendAbi=...`、`disable-abi-filtering=true`，项目可选 ABI filter 保留直接 Flutter 构建的原默认；`globalsendCompressNative=true` 生成压缩 SO。不要使用另一个 code2001 的内部 split 实验包作正常更新。

## 已统一：中心组密码、在线地址与最简连接界面

用户最新确定：只由中心组发现；组密码至少十位，同密码直接加入同组；在线组员交换 IPv4/IPv6，IP 上传三十分钟到期，末 WS 离线立即删除当前公告并停止显示/探测；不要邀请码、互相配对、离线设备管理或附加确认流程。既有身份/token/文件历史保留以便自动重连，地址不当成永久信任清单。

分工：rtc_center 持有 server/protocol/API 与发布；rtc_native 持有 client/lib/必要 Java/tests；rtc_web 持有 Web 源码/tests。三条线已冻结并完成合并消费。中心现声明 `enrollment.mode=group-password`、min10、`discovery.onlineOnly=true/peerTtlSeconds=1800`；peer/RTC 在实际 WS hello 后发布，首次和重连立即重发。新登记引导/邀请码已退役；同组已登录设备可更新自己当前证书和 IP，不再永久锁证书、要求撤销重配。

原生自动系统名、显式恢复系统名、剪贴板无重复副标题/独立目标、单行中继确认标签已纳入1.0.1。Web 已合并自动本站中心、自动设备名与设置“自动命名”、十位密码及删除旧流程；常规页面不再要求手填服务地址。Safari 只能自动辨认设备类型，不能获取系统自定义名称。

根维护的真实消费工具 `web/tool/accept_rtc_native.mjs` 已补两设备真实 WSS hello 后发布 RTC，`accept_saved_library.mjs` 已去旧入组字段；新合同下续传/文件库消费通过。新的1.0.1分架构包包含本轮全部修复；早先交付的1.0.0保留为历史包。

一次远端任务误建了空目录 `F:\Programs\Server\artifacts\logs\remote\packages-disabled`，没有文件；清理被工具策略拒绝，未换工具绕过。正确日志都在项目内；不影响当前服务，但此空目录尚待可获准的清理方式。

### 十位组密码：合并消费证据

- Web 新流程 80 项通过，类型检查、隔离构建和六场景渲染通过。正常页仅填写组密码，本站中心自动使用；高级自定义入口保留。根已查看本轮手机入组和设置压缩图。
- 真实生产 Windows transport 与新 Web / 中心再次完成双向 1,049,307 字节、12,345 字节续传，完整性通过，中继字节为零。两设备先真实 WS hello 再发布能力，日志 `artifacts/logs/rtc-group-password-consumer.log`，结果 `artifacts/tmp/rtc-production-interop/run-taALvP/result.json`。运输层未改，复用其有效的已构建生产 consumer，不额外重建。
- 真实 Web 主入口、OPFS Worker、两组在线设备的文件库消费通过，包括改名保字节、文本/图片预览、实际下载、整卡长按、仅转发当前组、按时长/类别/大小清理、保留下载副本。日志 `artifacts/logs/web-group-library-consumer.log`，结果 `artifacts/tmp/web-library-acceptance/run-XALk6f/result.json`。
- 原生发现/名称/取消19项、新中心真实HTTPS拉取/反向/中继/手动兼容3项通过；最新hello重连、密码直入、双输入首页及无离线列表检查通过。分析无问题，Android Java编译52秒成功；根已查看本轮真实入组页压缩图 `artifacts/screenshots/group-password-setup.preview.jpg`。Android实机取消探测和JNI仍待设备验收。
- 中心26项通过，类型检查、构建及Node24源码入口通过。IP/当前证书只存在进程Map，启动清旧SQL peer记录；GET设备/直连/RTC访问先清过期项，不会返回过期IP。空闲后台每30秒扫描，闲置RAM过期项最多额外30秒移除；RTC逐ICE/SDP同样真正清理。

### 1.0.1 本地客户端交付

Windows Release 构建228.5秒，隔离EXE `client/build/group-password-1.0.1/windows/x64/runner/Release/globalsend.exe`；完整包 `artifacts/releases/GlobalSend-1.0.1-windows-x64.zip`，25,398,987字节，24个ZIP条目，已核对EXE/DLL/app.so与产品版本。证据 `client/build/logs/windows-release-group-password.log`、`artifacts/logs/windows-group-password-package.json`。

Android release按ABI逐个构建和冻结，API24+、versionName1.0.1、versionCode2、APK v2签名通过，四个必要native SO齐全且压缩；不删除功能，也未安装或上传：

| 本地文件（artifacts/releases/） | 字节 | 十进制MB |
| --- | ---: | ---: |
| GlobalSend-1.0.1-android-arm64-v8a.apk | 18,606,000 | 18.6 |
| GlobalSend-1.0.1-android-armeabi-v7a.apk | 16,440,676 | 16.4 |
| GlobalSend-1.0.1-android-x86_64.apk | 19,859,208 | 19.9 |

三个包均低于20,000,000字节。ABI/签名/体积结果见 `artifacts/releases/GlobalSend-1.0.1-android-packages.json` 与 `artifacts/logs/android-group-password-*-{package.json,metadata.log,signature.log}`，构建日志在 `client/build/logs/android-group-password-*.log`。

### 新版公网

新release `/home/ubuntu/GlobalSend/releases/20261025-173223-group-password`，镜像 `globalsend:group-password-20261025-173223`；独立health通过，原instanceId `77f2d3ed-1595-48d9-9ebd-3f526b0547d3`保留。备份 `/home/ubuntu/GlobalSend/backups/20261025-173223-pre-group-password`，旧镜像 `globalsend:pre-group-password-20261025-173223`；部署定位在 `artifacts/deploy/current-group-password-deployment.json`，完整报告与独立回滚命令在 `artifacts/deploy/group-password-deployment-report.md`。Caddy未重启，仍挂旧release目录的配置，不能删除 `20261025-163425-rtc`。

公网已实测十位密码同组/跨组隔离、真实WSS/中文ACK、IPv4/IPv6交换、证书刷新、多socket直到最后关闭才撤下地址、旧token重连且无旧地址。冻结Web资源与公网响应一致，六个安装包相关路径含Range HEAD均410。原14设备、7组、114事件、14传输、24文件记录及11个relay文件共3,475,173字节保留，新SQL peers为0。验收 `artifacts/deploy/public-group-password-result.json`、`artifacts/logs/remote/group-password/retention-result.json`。

本轮没有上传安装包、启STUN、改端口、操作用户标签或启动/安装客户端。公网没有等待实际三十分钟；过期真实删除由受控时钟的endpoint/registry测试覆盖，公网确认1800秒寿命与断线立即清理。Android/iPad真机与跨公网候选可达性仍需设备验收。

## 继续开发：前台RTC轻量周期检测（源码1.0.2，未发布）

上个目标回合为实际进展：十位密码中心/Web上线并完成1.0.1客户端分架构交付。本回合继续补周期检测的浏览器缺口，不将HTTPS周期探测误当成已测试RTC，也不把编译或JNI初始化当成Android文件互传通过。

### 已完成并冻结的源码

- 专用 `globalsend-probe-v1` nonce/echo，不创建文件offer，不使用文件库、OPFS、收发回执或文件中继。每设备单并发，字典序确定唯一发起者；仅同组在线、前台且包含浏览器的一对设备参与。
- 40秒前台租约/20秒刷新，约两分钟一轮；LAN后公网，12秒结束会话，结果两分钟有效。隐藏、离线及已知网络切换会取消并清结果，结束后关闭通道和PC。中心每秒清理短时状态，不写SQL事件。
- Android探测在Dart与Java两层固定禁蜂窝lease、禁外部ICE；不加STUN/TURN。浏览器无法选择底层网络，不能宣称探测已强制非蜂窝。Safari未暴露网络变化事件时，在前台/WS变化/下一周期更新，不能承诺持续在线切网立即可知。
- 结果用于连接检测和同范围RTC优先；不改变局域网→公网→中继、手动路径或真实文件失败重试。`fec0::/10`在native HTTPS/RTC与Web归内网，不误作公网。原生连接检测不再硬编码“Web端暂用中继”。
- Web设置修为“中继确认阈值”，删除冗余说明，32 MiB策略不变；原生现有单行确认标签含义正确，不重复重做。系统凭据读取失败的旧“重新配对”文案改为“重新连接”。

`rtc_native`为总owner，持有原生与整体验收；`rtc_center`完成独立registry/API，`rtc_web`完成浏览器monitor。接口见 `client/lib/rtc_probe.dart`、`web/src/rtc_probe.ts` 与 `docs/API.md` 的Foreground RTC reachability probes。本轮只源码，不部署、不替换产品；`client/pubspec.yaml`前移为下一版1.0.2+3，冻结的1.0.1包保留。

### 有效证据

- Windows发起/浏览器回应：真实nonce/echo、通道/PC成对关闭、隐藏/离线取消及零transfer/events/relay副作用，`artifacts/tmp/rtc-reachability-interop/run-lltbfc/result.json`。
- 浏览器发起/Windows回应：双方创建＝关闭、真实RTT1 ms，`artifacts/tmp/rtc-reachability-interop/run-hZFstw/result.json`。结果限定本机Windows↔浏览器真实局域网候选，不作为跨公网或iPad证明。
- 重建现有生产文件消费者后，双向各1,049,307字节、12,345字节续传、字节/hash一致、中继0。日志 `artifacts/logs/build-rtc-file-compatibility.log`、`rtc-probes-file-compatibility.log`；结果 `artifacts/tmp/rtc-production-interop/run-YF6s21/result.json`。没有重复空文件矩阵。
- Native31项与分析通过，Java policy准确计数7/7及编译通过；中心30项与构建/源码入口通过；Web91项、最后文案/地址分类两项和类型检查通过。日志 `client/build/logs/test-rtc-probes*.log`、`android-rtc-probes.log`、`artifacts/logs/server-rtc-probes-*.log`、`web-rtc-probe-all-tests.log`、`web-relay-copy-site-local-test.log`。根已看本轮Web手机设置压缩渲染；后续短标签不会沿用旧含义。

### 实际设备进展与阻塞

Windows1.0.1在原进程不存在时，经备份后以原项目身份启动（17:45，记录 `artifacts/logs/windows-group-password-live-launch.json`），实际窗口树显示原历史、图片与在线Web目标。设置点击两次均报 `GetCursorPos failed: 拒绝访问 (0x80070005)`，已停止UI输入；没有换工具绕过。桌面恢复后再做真实点击/拖放验收，负责人为用户解锁/关闭安全提示，root续验。

物理手机ADB未连接；root新建项目内独立API36 x86_64 AVD与独立applicationId消费者，没有复用其他项目设备或覆盖用户应用。JNI库、factory和网络监测实际运行；Android虚拟网络↔主机Web的LAN文件通道未连通，native进度0/relay0，NAT/mDNS原因尚未证实。诊断重试在执行前被工具策略拒绝，未绕过。专用AVD已正常停止，所属进程消失且本次forward移除。完整结果 `artifacts/logs/android-jni-runtime-result.json`，复现生成器 `scripts/build-rtc-android-probe.mjs`。

当时待验：物理手机JNI/SAF/跨应用拖放、校园/蜂窝IPv6、Windows真实交互和iPad Safari。用户随后明确允许停止继续打磨；这些保留为已知未验项目，不再自动追测。当前运行产品仍是1.0.1和已上线group-password中心/Web。

## 用户允许停止后的保存点

已停止新增任务和检查，全部子任务收束，无新部署或设备安装。当前服务与Windows1.0.1保留，不为停止目标而关闭用户使用中的应用。

停止前已经发起的1.0.2构建自然结束：Windows Release位于 `client/build/rtc-probes-1.0.2/windows/x64/runner/Release/`，252.6秒构建成功，未另打ZIP或启动；Android三架构已冻结为本地APK：arm64-v8a 18,627,780字节、armeabi-v7a 16,463,600字节、x86_64 19,885,308字节，均低于20,000,000字节。未继续做本轮签名/ABI读回验收，也未安装或上传。日志 `client/build/logs/windows-release-1.0.2.log`、`android-release-1.0.2-*.log`。

Web初步候选 `artifacts/candidates/web-1.0.2` 已构建（JS `index-Dm4uUPcY.js`、CSS `index-BgECREDc.css`、原worker）。它不含随后保存的阈值输入连续性修复，不应当作最终发布候选直接上线。

停止前已完成的最后一处源码修复：Web“中继确认阈值”输入64但未提交时，被周期render重置为32。已以单控件draft及复用number input修复，监听器不累积；change才提交，空值不误存0。独立Edge复现与修后五次render/真实选区插入/单次change提交、类型检查已通过，证据 `artifacts/logs/web-relay-limit-input-{before,after}.log`；未追加单元矩阵、未重建最终Web包或发布。其他设置草稿和用户页面未改动。

以后若用户要求发布1.0.2，先从当前源码重新构建Web候选；周期RTC能力需要中心与Web同时升级。现阶段不继续这些操作，也不把尚未完成的真机验收描述成已经通过。

## 按新请求构建最新版本：1.0.2+3

仅恢复本地构建与交付，不恢复产品开发、全面测试、部署或设备操作。已检查native源码、pubspec/lock与Gradle配置均早于现有1.0.2 Release产物，复用有效构建，不为重复生成同一native包重跑编译。

- Windows完整包 `artifacts/releases/GlobalSend-1.0.2-windows-x64.zip`，25,420,427字节、23个ZIP条目；实际产品版本1.0.2+3，EXE/DLL/data/app.so完整。
- Android三个本地APK分别18,627,780 / 16,463,600 / 19,885,308字节，均小于20,000,000字节。已读回versionName1.0.2、versionCode3、各自唯一ABI与四个必要SO，APK签名验证通过。
- Web从含最后阈值输入修复的源码重新构建至 `artifacts/candidates/web-1.0.2-final`：JS `index-DWCh6iEp.js`、CSS `index-BgECREDc.css`、worker不变。类型检查与生产构建通过；不要再使用旧 `web-1.0.2` 候选。
- 中心最新类型检查/生产构建通过，输出 `server/dist/index.js`。新增周期RTC检测需要中心支持 `rtcProbes`；本次未部署中心或Web。

交付清单 `artifacts/releases/GlobalSend-1.0.2-manifest.json`；新构建日志 `artifacts/logs/web-1.0.2-final-build.log`、`server-1.0.2-final-build.log`，APK读回与签名日志 `android-1.0.2-*-{metadata,signature}.log`。README与短步骤已更新最新包入口。当前用户运行窗口未替换，安装包未上传服务器。
