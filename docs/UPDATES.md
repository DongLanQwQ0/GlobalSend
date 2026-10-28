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
  -Package .\artifacts\releases\GlobalSend-1.0.29-windows-x64.zip `
  -Version 1.0.29 -BuildNumber 38 `
  -SourceCommit 48c65ed83c7003a1b0279ac60b49d9d458d98b16
```

核对输出后，用相同参数加 `-Publish` 发布。Android 用 `-Platform android` 和 APK；iOS 用 `-Platform ios` 和 IPA。脚本读取 Windows EXE 产品版本、Android APK 元数据或 IPA 主应用 plist，版本不匹配就停止。Android 入口适用于本项目显式 ABI 构建、不追加 split-APK 版本码偏移的包。

发布使用现有 `F:\Programs\GitHubCLI\bin\gh.exe` 登录，不读取认证 token。Tag 为 `v版本-build构建号`；已存在的 Tag 必须指向同一源码提交。各平台清单独立，例如 `globalsend-update-windows.json`，只列出实际上传的对应包；同一 Release 可包含多个平台，不能把 Windows 版本号冒充手机版本。

iPad Actions 仍仅由 `workflow_dispatch` 手动触发。Windows、Android 稳定后再运行；成功生成真机 IPA 后，工作流发布 IPA 及其实际版本清单。不因源码推送启动 IPA 构建。

## 当前验收边界

Windows **1.0.29+38** 已安装运行；Android 同版 APK 已构建，当前 ADB 无在线设备，手机最后确认仍为 **1.0.28+37**。设置中的实际更新检查此前在 Windows 1.0.27 验证。当前[公开 Release](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.29-build38)含 Windows ZIP、Android arm64 APK 及各自清单；无新 IPA。

GitHub API 已确认 1.0.29 四个资产均上传完成，证据 `artifacts/reports/github-release-1.0.29.json`。当前版本实际“设置 → 检查更新”和手机通知仍需界面验收。此前 1.0.28 的公开客户端检查遇到 GitHub 网络超时，保留为历史未通过结果，不用资产上传成功冒充整条客户端更新检查通过。

客户端选包、重复通知、检查时机及通知按钮分别有自动检查；Android 通知在主机框架中验证。iOS 原生通知代码需在原生端稳定后下一次 IPA 构建和真机安装时验收，不因为发布其他平台包就触发 IPA 构建。
