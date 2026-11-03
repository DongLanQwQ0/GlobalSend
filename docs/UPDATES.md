# 版本更新

在“设置 → 更新”管理更新。Windows、Android 的“自动检查更新”和“自动下载并更新”默认开启，也可关闭后手动检查、下载或安装。启动及每六小时检查 GitHub，重新进入应用时补查到期检查；只匹配当前平台和架构的更新，不需要登录 GitHub。安装包直接从 GitHub 下载，不经过中心服务器。

自动检查和下载使用 GitHub 的匿名公开资源接口，外部下载仍保留浏览器链接。候选按实际平台文件版本处理；旧清单失败不会抹掉已找到的有效更新，全部候选失败则显示实际错误，不假报“已是最新”。不为更新悄悄启用代理或携带账号 token。

## Windows 与 Android 自动更新

- **Windows**：自动下载完整 ZIP。前台不打断编辑；转入后台且传输、系统拖放和接收坞操作均结束时，保存队列、内容草稿与窗口位置，再由独立更新程序核对并替换完整程序，自动更新始终后台重启，不抢焦点。替换失败恢复旧程序，可在更新设置重试。手动“安装更新”无需等待后台，但也不能中断拖放、移动/调整、菜单或滚动；准备好的辅助进程会等待结束事件，不反复重启。仅提供 EXE/MSI 的旧发行保留外部下载入口。
- **Android**：自动下载对应 ABI 的 APK。应用前台时调起系统安装；后台下载就绪后显示通知，进入应用继续。首次可能需要允许“安装未知应用”，授权后返回可继续；系统安装确认仍由用户完成。取消后保留已下载包，可点“安装更新”重试，不反复自动弹出。覆盖安装保留应用数据。
- 下载逐块写入应用专用 `updates` 目录，显示进度；未完成的包不能安装，失败可续传。已完成的待安装包与设置在重启后保留。关闭自动下载并更新会停止当前自动下载和后续自动安装，手动安装仍可使用。
- 安装前及最终退出前再次确认空闲；新任务或交互在准备阶段开始时推迟替换，不中断文件或拖放。“取消更新”可停止下载或等待中的安装；关闭自动更新也会撤销自动安装等待。只保存更新恢复所需的文本草稿和编辑状态，不明文保存组密码。

## iPad / iPhone

iOS 保留检查及通知，下载 IPA 后仍用原账号手动签名安装；不自动下载、签名或安装 IPA。

- Windows 自动更新优先匹配架构的完整 ZIP；Android 检查匹配 ABI 的 APK。
- iPhone、iPad 共用真机 IPA 更新通道，下载后仍需自行签名。
- Release 没有本平台文件、文件未上传完成，或版本不比当前版本新，都不通知。
- 前台使用可关闭的提示条，不打断编辑；后台使用独立的版本更新通知，不打开接收页面。移动端遵循系统通知权限。
- iOS 被挂起或退出后不能依靠应用内定时器持续访问 GitHub；下次启动或恢复时补查。此功能不使用 APNs。

## 发布本地已构建的包

先通过本地原生发布流程构建并确认版本。脚本默认只核对包内容并生成平台清单；加 `-Publish` 才上传到 GitHub。中心服务器不托管安装包。

```powershell
# 在项目根目录执行；版本、构建号和源码提交应来自这次构建。
.\scripts\Publish-GitHubRelease.ps1 -Platform windows `
  -Package .\artifacts\releases\GlobalSend-1.0.35-windows-x64.zip `
  -Version 1.0.35 -BuildNumber 44 `
  -SourceCommit ddff6aed46feba7de65a2443e9e5734a3d35e2af
```

核对输出后，用相同参数加 `-Publish` 发布。Android 用 `-Platform android` 和 APK；iOS 用 `-Platform ios` 和 IPA。脚本读取 Windows EXE 产品版本、Android APK 元数据或 IPA 主应用 plist，版本不匹配就停止。Android 入口适用于本项目显式 ABI 构建、不追加 split-APK 版本码偏移的包。

发布使用现有 `F:\Programs\GitHubCLI\bin\gh.exe` 登录，不读取认证 token。Tag 为 `v版本-build构建号`；已存在的 Tag 必须指向同一源码提交。各平台清单独立，例如 `globalsend-update-windows.json`，只列出实际上传的对应包；同一 Release 可包含多个平台，不能把 Windows 版本号冒充手机版本。

iPad Actions 仍仅由 `workflow_dispatch` 手动触发。Windows、Android 稳定后再运行；成功生成真机 IPA 后，工作流发布 IPA 及其实际版本清单。不因源码推送启动 IPA 构建。

## 当前验收边界

当前本机 Windows 已覆盖更新并重启 **1.0.95+120**，两端接收坞外部悬停1秒进入设备模式、移出1秒恢复，可反复触发；[120检查记录](../artifacts/reports/dock-hover120.md)包含具体时序与源拖动保留检查。Android120的APK已构建，但无实体手机连接，尚未安装，最后确认手机仍117。GitHub公开Windows/Android仍为 **1.0.92+117**，中心/Web保留117，iOS/iPadOS的实际IPA为 **1.0.89+114**。安装/部署状态以[本机发布记录](../artifacts/releases/latest-local.json)为准。

Windows真实自更新/系统剪贴板和Android应用内安装确认仍需各自实机验收；ADB覆盖安装不能替代应用内更新流程。IPA继续由用户手动签名安装，不提前发布未构建的iOS清单。

115发布后，以生产更新选择器匿名读取真实GitHub Release和清单：Windows/Android从113正确找到115，iOS从113找到114；各端已安装自身最新版时均不再提示更新，iOS没有因115 Release而误报。共检查30条Release，读取17份元数据，耗时20.5秒，未下载安装包、未操作应用或系统剪贴板。证据`artifacts/tmp/release115/public-feed.json`；这是公开选包链路检查，不代替系统通知或安装验收。

### 105版的历史检查

当时发布 **1.0.81+105**：Windows完整客户端已更新并启动；APK为16,431,707字节，Windows ZIP为22,530,094字节，均无打包字体。手机由其它任务使用后断开，当时尚未覆盖105、最后实际读回为1.0.79+103；新包保留在本地与[GitHub 105版](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.81-build105)，不以包生成代替手机安装。Web分区拖放反馈已在中心上线，105没有新的Web/中心产品改动，没有重复部署相同代码。

105真实匿名检查21条Release，Windows/Android各读取1份清单，约5.2秒选出各自105包。生产下载器已完整下载22,527,511字节的104版Windows ZIP，实际版本及ZIP内容核对通过；105实际包由发布脚本另行读回版本。此前github.com下载入口在当前网络失败，改用同一GitHub公开资源API后通过，未改变代理设置。证据：`artifacts/tmp/completion104/public-feed-before.json`、`public-download.json`，以及`artifacts/tmp/completion105/public-feed.json`。

当时构建的105 IPA为14,913,965字节，主应用与扩展均为真机arm64/105，App Group配置一致，无打包字体；实际包和iOS独立清单已发布，交用户手动签名安装。核对记录：`artifacts/tmp/completion105/ios-verified.json`。

自动更新引擎、真实HTTP续传、草稿恢复、Windows隐藏辅助程序替换与回滚、平台筛选和操作门禁检查通过。新增22项公网更新合同检查、15项交互/取消回归及单helper等待31秒后取消均通过。Android安装器与权限检查通过；实际FileProvider读取仍需在Android应用内安装时确认。按用户要求未操作真实Windows界面，真实自更新与实体触屏由用户验收。见 `artifacts/reports/completion105.json`、[Windows更新机制](WINDOWS_SELF_UPDATE.md)和[本机发布记录](../artifacts/releases/latest-local.json)。

101版截图自动发送、98版文件引用拉取及iPad基本跨应用拖放已由用户确认。Windows接收截图后实际Ctrl+V仍因无第二台Windows而未验；105的iPad卡片拖影、剪贴板及媒体建议拖动需用户安装后确认，见[iPad说明](IPAD.md)。

### 历史交付：1.0.57+68

当时Windows和Android均已更新并启动 **1.0.57+68**，构建源码`a965322`；APK为16,305,744字节，手机覆盖安装保留数据。57修复媒体建议拖入待发区丢失后缀、旧无后缀图片预览，以及Windows 11原生触屏OLE交接。自动检查与组件渲染通过；真实手机新增MediaStore图片、数字ID URI拖入待发、保留`.jpg`与缩略图/预览、主页面设备发送到独立接收器均已通过，收到2591字节与fixture完全一致。测试媒体和分组已清理。Windows触屏实机投放、Android相机视频建议和暂存坞设备模式直接转发当时仍待验收。详见[修复与证据](NATIVE_FIXES_1_0_57.md)。57未发布为GitHub Release，也不把包放中心。

56 的 Android 媒体建议已移到暂存末尾，清空后保留双击空白格，空列表先留一屏空白再左滑到建议。57版已补充真实新增图片的发现与发送验收。

55版本机ABI普通链接投递继续保留；iPad等设备使用已有文本协议，不需要升级接收端、中心或Web。13项Dart、真实本地中心HTTP/WS、15项原生桥检查通过，首个配套Chrona0.15.70/232的原生检查和UI复审通过；真实iPad收件仍由用户确认。

以下保留54版用户已验收基线：

2026-10-30本地Windows和Android已更新为 **1.0.54+65**。手机USB安装成功并读回65版，包含增强触感、把手惯性和透明矢量安装图标；用户确认本轮没有问题。左右滚动的146帧无卡顿采样及原生回归证据保留。54尚未发布为GitHub Release，中心无安装包；本轮未进行Windows界面测试，也未构建新IPA。详情以[本机发布记录](../artifacts/releases/latest-local.json)为准。

此前公开版：

Windows与真实vivo均已更新 **1.0.50+59**，手机USB安装成功并读回版本。50新增Windows开机自启动与`--background`参数；按用户要求未进行Windows交互测试，未替用户启用启动项。49的APK安装功能用户已确认可用。[50版Release](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.50-build59)提供Windows ZIP、Android APK与对应清单。[iOS 1.0.53（62）](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.53-build62)移除设置中的系统分享和默认目标，接入系统分享面板的设备建议，保留分享后唤起和唯一ID定向发送接口。IPA与iOS清单已发布，由用户手动安装。51版分享已获用户确认，53版唤起、建议显示与定向发送待实机验收。53没有Windows/Android文件，不应向这两个平台通知更新；各平台按自己的包和版本判断。

2026-10-29通过GitHub API确认仓库为public，1.0.48三平台包及三份更新清单均为uploaded。当前版本实际“设置 → 检查更新”和手机通知仍需界面验收。此前1.0.28的公开客户端检查遇到GitHub网络超时，保留为历史未通过结果，不用资产上传成功冒充整条客户端更新检查通过。

客户端选包、重复通知、检查时机及通知按钮分别有自动检查；Android通知在主机框架中验证。iOS更新通知代码已通过本次macOS原生编译，实际通知仍需签名安装后的设备验收。
