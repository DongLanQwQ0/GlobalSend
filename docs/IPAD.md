# iPad：下载未签名 IPA，手动签名安装

先完成 Windows、Android 的开发和稳定性验收，最后再构建 IPA。在 GitHub 仓库打开 **Actions → iPad unsigned IPA → Run workflow**。构建成功后，在该次运行的 **Artifacts** 下载 `GlobalSend-iPad-unsigned-运行编号`，解压取得 `GlobalSend-iPad-unsigned.ipa`，交给你自己的签名工具签名，再安装到 iPad。

工作流仅手动触发，推送源码不构建 IPA。Actions 产物保留 14 天；成功后另发布 IPA 与 iOS 更新清单到 GitHub Release。签名证书、Apple 账号、描述文件和 TestFlight 都不参与这条流水线。安装包不放到 GlobalSend 中心服务器。

若当前版本/构建号已有Windows或Android Release，应选择它的源码Tag运行，让各平台对应同一源码提交。不要在已有版本号下从另一个提交覆盖包；新源码先增加构建号再触发。Windows与真实手机均已更新1.0.50+59。本轮iOS专属修复不替换两端运行版本；[1.0.51（60）IPA构建](https://github.com/DongLanQwQ0/GlobalSend/actions/runs/40885596381)已成功，源码`6727591`，包括iloader重签后的共享组识别修复。

本地文件：`artifacts/releases/ios-1.0.51-build60/GlobalSend-iPad-unsigned.ipa`，14,723,485字节。主应用与分享扩展均为1.0.51（60），App Group模板一致且已展开，没有内置字体。也可从[GitHub Release](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.51-build60)下载。macOS已编译并运行共享组选择回归检查；iPhoneOS主应用与扩展编译通过。用户选择使用iloader手动覆盖安装，尚未确认本版iPad分享结果。

iloader会按当前账号改写共享组名称。51版保留原组优先，原组不可用时识别重签后的宿主组；不要重新生成密钥或卸载旧应用。使用原账号覆盖安装，并保留分享扩展，详见[iloader兼容说明](MOBILE_SHARING.md#iloader-重签)。

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
