# iPad：下载未签名 IPA，手动签名安装

先完成 Windows、Android 的开发和稳定性验收，最后再构建 IPA。在 GitHub 仓库打开 **Actions → iPad unsigned IPA → Run workflow**。构建成功后，在该次运行的 **Artifacts** 下载 `GlobalSend-iPad-unsigned-运行编号`，解压取得 `GlobalSend-iPad-unsigned.ipa`，交给你自己的签名工具签名，再安装到 iPad。

工作流仅手动触发，推送源码不构建 IPA。Actions 产物保留 14 天；成功后另发布 IPA 与 iOS 更新清单到 GitHub Release。签名证书、Apple 账号、描述文件和 TestFlight 都不参与这条流水线。安装包不放到 GlobalSend 中心服务器。

若当前版本/构建号已有 Windows 或 Android Release，应选择它的源码 Tag 运行（例如 `v1.0.28-build37`），让各平台对应同一源码提交。不要在已有版本号下从另一个提交覆盖包；若要构建更新后的源码，先增加构建号再手动触发。当前 Android 新包尚未安装验收，因此暂不触发新 IPA。

## 当前构建

- Flutter 3.47.2，与现有原生客户端一致；GitHub macOS 26 / Xcode。
- iPhoneOS 真机 arm64，最低 iOS / iPadOS 15；不是模拟器包。
- `flutter build ios --release --no-codesign` 先生成 `Runner.app`，再用 macOS `ditto` 包装成标准 `Payload/Runner.app` 结构的 IPA。
- 签名工具需要处理应用及其嵌入的 frameworks。能否安装和签名有效期由你的签名方式决定，CI 构建成功不代表已经在 iPad 安装。

## 第一版的范围

沿用 Flutter 页面、中心组发现、文字、文件、HTTPS / WebRTC 传输及本地文件库。补齐 iOS 设备名称、打开网址、Keychain 本机凭据桥；本地网络访问第一次需要系统授权。应用文稿可从“文件”App 中访问。

移动端新增“新图片建议”：回到应用时检查最近一天内、首次开启前十分钟之后创建的本机图片，最多展示六张。点击缩略图加入待发送，不自动传输；可在设置中关闭。首次需要照片权限，有限访问时只检查已授权图片，不下载 iCloud 原图。已添加或忽略的图片不重复建议。

iOS 系统分享和多文件系统拖出已接入，签名需保留分享扩展及匹配的 AppGroup，见 [系统分享](MOBILE_SHARING.md)。这些交互与新照片建议仍需 iPad 真机验收。外部接收文件夹授权和后台接收通知仍待适配；默认接收到应用文稿目录，当前 iOS 版不保证长期后台监听。

## 在 Mac 上复现

```bash
cd client
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign --no-pub
cd ..
bash scripts/package-ios-unsigned.sh
```

输出：`artifacts/releases/GlobalSend-iPad-unsigned.ipa`。Windows 无法本地运行 Xcode，首个有效 iOS 编译结果以 GitHub Actions 为准。
