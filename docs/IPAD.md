# iPad：下载未签名 IPA，手动签名安装

先完成 Windows、Android 的开发和稳定性验收，最后再构建 IPA。在 GitHub 仓库打开 **Actions → iPad unsigned IPA → Run workflow**。构建成功后，在该次运行的 **Artifacts** 下载 `GlobalSend-iPad-unsigned-运行编号`，解压取得 `GlobalSend-iPad-unsigned.ipa`，交给你自己的签名工具签名，再安装到 iPad。

工作流仅手动触发，推送源码不构建 IPA。Actions 产物保留 14 天；成功后另发布 IPA 与 iOS 更新清单到 GitHub Release。签名证书、Apple 账号、描述文件和 TestFlight 都不参与这条流水线。安装包不放到 GlobalSend 中心服务器。

若当前版本/构建号已有 Windows 或 Android Release，应选择它的源码 Tag 运行，让各平台对应同一源码提交。不要在已有版本号下从另一个提交覆盖包；新源码先增加构建号再触发。

最新为 **1.0.58（74）**，源码 `d51ee61`：[构建记录](https://github.com/DongLanQwQ0/GlobalSend/actions/runs/41082221792) / [GitHub 下载](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.58-build74)。本地文件：`artifacts/releases/ios-1.0.58-build74/GlobalSend-iPad-unsigned.ipa`，14,812,295 字节。主应用与分享扩展均为真机 arm64，App Group 模板匹配，无内置字体；未签名，需用原账号手动覆盖安装。

本版补齐 UIKit `UIDragInteraction` / `UIDropInteraction`：文件、媒体、网址和文本可拖入待发区，也可直接投到设备卡片，只发送投下的这一批、不带走其它草稿；收到的内容可系统拖出。文件夹按原目录结构传输、列表只展示根卡片。已发送文本保存成功即关闭。编译和归档检查已通过，实际拖入、拖出、分享建议、右滑返回与缩放仍需 iPad 安装后确认。

安装后先分享一张图片，确认打开GlobalSend并显示在待发送。需要直接发给设备时，先在GlobalSend给该设备正常发送一次，再到其他应用打开系统分享面板，选择第一排带GlobalSend标记的设备建议。建议是否显示及顺序由iPadOS决定；点击普通GlobalSend应用图标仍只加入待发送，不读取旧默认目标。指定设备分享应只发送本批，不包含原有草稿。详细入口及接口见[系统分享设备快捷项](MOBILE_SHARING.md#系统分享面板里的设备快捷项ios--ipados-53版)。

iloader会按当前账号改写共享组名称。51版起保留原组优先，原组不可用时识别重签后的宿主组；不要重新生成密钥或卸载旧应用。使用原账号覆盖安装，并保留分享扩展，详见[iloader兼容说明](MOBILE_SHARING.md#iloader-重签)。

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
