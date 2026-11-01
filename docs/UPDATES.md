# 版本更新

在“设置 → 更新”管理更新。Windows、Android 的“自动检查更新”和“自动下载并更新”默认开启，也可关闭后手动检查、下载或安装。启动及每六小时检查 GitHub，重新进入应用时补查到期检查；只匹配当前平台和架构的更新，不需要登录 GitHub。安装包直接从 GitHub 下载，不经过中心服务器。

## Windows 与 Android 自动更新

- **Windows**：自动下载完整 ZIP。前台不打断编辑；窗口转入后台且没有传输时，保存队列、内容草稿与窗口位置，再由独立更新程序解压、核对实际版本并替换完整程序，最后恢复原来的前台/后台状态。替换失败恢复旧程序；失败原因显示在更新设置中，可手动重试。手动“安装更新”无需等待转入后台，但仍等待传输空闲。仅提供 EXE/MSI 的旧发行保留外部下载入口。
- **Android**：自动下载对应 ABI 的 APK。应用前台时调起系统安装；后台下载就绪后显示通知，进入应用继续。首次可能需要允许“安装未知应用”，授权后返回可继续；系统安装确认仍由用户完成。取消后保留已下载包，可点“安装更新”重试，不反复自动弹出。覆盖安装保留应用数据。
- 下载逐块写入应用专用 `updates` 目录，显示进度；未完成的包不能安装，失败可续传。已完成的待安装包与设置在重启后保留。关闭自动下载并更新会停止当前自动下载和后续自动安装，手动安装仍可使用。
- 安装前再次确认没有正在传输的任务；新任务在准备阶段开始时，推迟替换，不中断文件。只保存更新恢复所需的文本草稿和编辑状态，不明文保存组密码。

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

Windows与Android均已覆盖更新并启动 **1.0.77+101**，中心已上线`clipboardImages`能力，Web按既有图片流程接收自动截图。手机安装Success并读回101版，保留数据；不操作Windows界面。Windows图片剪贴板写入与自动截图发送已接入，实际系统粘贴留给用户验收；生产控制器/真实中心/LAN与WIC格式转换检查通过，见[自动剪贴板同步](CLIPBOARD_SYNC.md)。98版文件引用拉取已由用户确认，99开关联动和100统一卡片继续保留。GitHub Windows/Android公开通道为[1.0.68+85](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.68-build85)，iOS通道为最后构建并发布的[1.0.77+101](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.77-build101)，实际IPA已核对，由用户手动签名安装。101的Release仅含IPA与iOS清单，不向Windows/Android通知不存在的平台更新。中心不托管安装包。版本、功能和证据见[iPad说明](IPAD.md)及[本机发布记录](../artifacts/releases/latest-local.json)。

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
