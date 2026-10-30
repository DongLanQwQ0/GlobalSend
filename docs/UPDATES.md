# 版本更新

原生客户端在“设置 → 更新”手动检查；启动时自动检查，运行期间每六小时检查一次，重新进入应用时补查到期检查。只读取公开的 GitHub Release，不需要用户登录 GitHub，也不自动下载或安装。

- Windows 仅检查匹配架构的 ZIP / EXE / MSI；Android 检查匹配 ABI 的 APK。
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

Windows和手机当前已更新为 **1.0.55+66**，源码 `beed89f`。55新增本机ABI的普通链接投递，iPad等手动打开设备接收已有文本协议，不需要升级接收端、中心或Web。13项Dart、真实本地中心HTTP/WS、15项原生桥检查通过；Chrona调用端由其owner完成配套构建与UI验收，实际iPad收到仍待确认。55未发布为GitHub Release，也不把包放中心。安装记录见[本机发布记录](../artifacts/releases/latest-local.json)。

以下保留54版用户已验收基线：

2026-10-30本地Windows和Android已更新为 **1.0.54+65**。手机USB安装成功并读回65版，包含增强触感、把手惯性和透明矢量安装图标；用户确认本轮没有问题。左右滚动的146帧无卡顿采样及原生回归证据保留。54尚未发布为GitHub Release，中心无安装包；本轮未进行Windows界面测试，也未构建新IPA。详情以[本机发布记录](../artifacts/releases/latest-local.json)为准。

此前公开版：

Windows与真实vivo均已更新 **1.0.50+59**，手机USB安装成功并读回版本。50新增Windows开机自启动与`--background`参数；按用户要求未进行Windows交互测试，未替用户启用启动项。49的APK安装功能用户已确认可用。[50版Release](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.50-build59)提供Windows ZIP、Android APK与对应清单。[iOS 1.0.53（62）](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.53-build62)移除设置中的系统分享和默认目标，接入系统分享面板的设备建议，保留分享后唤起和唯一ID定向发送接口。IPA与iOS清单已发布，由用户手动安装。51版分享已获用户确认，53版唤起、建议显示与定向发送待实机验收。53没有Windows/Android文件，不应向这两个平台通知更新；各平台按自己的包和版本判断。

2026-10-29通过GitHub API确认仓库为public，1.0.48三平台包及三份更新清单均为uploaded。当前版本实际“设置 → 检查更新”和手机通知仍需界面验收。此前1.0.28的公开客户端检查遇到GitHub网络超时，保留为历史未通过结果，不用资产上传成功冒充整条客户端更新检查通过。

客户端选包、重复通知、检查时机及通知按钮分别有自动检查；Android通知在主机框架中验证。iOS更新通知代码已通过本次macOS原生编译，实际通知仍需签名安装后的设备验收。
