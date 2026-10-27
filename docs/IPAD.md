# iPad：下载未签名 IPA，手动签名安装

在 GitHub 仓库打开 **Actions → iPad unsigned IPA → Run workflow**。构建成功后，在该次运行的 **Artifacts** 下载 `GlobalSend-iPad-unsigned-运行编号`，解压取得 `GlobalSend-iPad-unsigned.ipa`，交给你自己的签名工具签名，再安装到 iPad。

推送 `main` 上的客户端、打包脚本或此工作流变更也会自动构建。产物保留 14 天；签名证书、Apple 账号、描述文件和 TestFlight 都不参与这条流水线。安装包只保存在 GitHub Actions 和本地，不放到 GlobalSend 中心服务器。

## 当前构建

- Flutter 3.47.2，与现有原生客户端一致；GitHub macOS 26 / Xcode。
- iPhoneOS 真机 arm64，最低 iOS / iPadOS 15；不是模拟器包。
- `flutter build ios --release --no-codesign` 先生成 `Runner.app`，再用 macOS `ditto` 包装成标准 `Payload/Runner.app` 结构的 IPA。
- 签名工具需要处理应用及其嵌入的 frameworks。能否安装和签名有效期由你的签名方式决定，CI 构建成功不代表已经在 iPad 安装。

## 第一版的范围

沿用 Flutter 页面、中心组发现、文字、文件、HTTPS / WebRTC 传输及本地文件库。补齐 iOS 设备名称、打开网址、Keychain 本机凭据桥；本地网络访问第一次需要系统授权。应用文稿可从“文件”App 中访问。

iOS 系统拖出、接收目录的外部文件夹授权、后台接收通知及新照片建议还需分别适配和真机验收；不把 Android 的后台服务和小窗直接套到 iPad。默认接收到应用文稿目录，当前 iOS 版不保证长期后台监听。

## 在 Mac 上复现

```bash
cd client
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign --no-pub
cd ..
bash scripts/package-ios-unsigned.sh
```

输出：`artifacts/releases/GlobalSend-iPad-unsigned.ipa`。Windows 无法本地运行 Xcode，首个有效 iOS 编译结果以 GitHub Actions 为准。
