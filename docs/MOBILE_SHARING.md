# 手机与 iPad 系统分享

## 使用

- 在照片、视频、文件或浏览器的系统分享菜单中选择 **GlobalSend**。打开应用后，内容会进入待发送区。
- 接收/已发送/文件库的“分享”调用系统分享面板，原文件不转换、不移动。
- “全部拖拽”可一次带出多个文件和文本。Android 使用系统 ClipData；iPad 使用多个 NSItemProvider。目标应用能接收哪些类型，由目标应用决定。
- iPad 分享扩展显示“已加入待发送”后点完成，再打开 GlobalSend。扩展不使用私有方法强制唤起主应用。

## iPad 手动签名

Apple 的[能力支持表](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)目前在免费的 Apple Developer 列中也列明支持 App groups（2026-10-29 核对了原表图标）。所以不以购买会员作为前提；免费 Apple ID 的手动签名仍需为主应用、扩展签入匹配的 App Group，开发者模式不能替代该配置。

构建产物包含：

```text
Payload/Runner.app/
  GlobalSend.entitlements
  PlugIns/ShareExtension.appex/
    GlobalSend.entitlements
```

这两份文件是已展开组 ID 的签名模板，不是已经取得授权的签名。手动签名时：

1. 保留并签名 `ShareExtension.appex`，不要在侧载工具里移除扩展。
2. 为主应用和分享扩展配置相同的 App Group，并确认两个 provisioning profile 都授权该组；签名器不能仅保留主应用权限。
3. 更新时保持同一主应用 Bundle ID、扩展 Bundle ID 和组 ID，避免被 iPad 当成另一款应用。

项目默认配置在 `client/ios/ShareConfig.xcconfig`：

```text
GLOBALSEND_APP_BUNDLE_ID=dev.globalsend.globalsend
GLOBALSEND_APP_GROUP_ID=group.dev.globalsend.globalsend
```

若扩展提示 App Group 未授权，应修正重签后的两份权限/配置文件；不能据此断定必须付费。主应用的“用其他应用打开/Open In”独立支持普通文件导入，主应用未取得组容器时会使用自己的接收队列。

本项目不收集 Apple 账号、私钥或签名材料。实际重签和 iPad 安装验收由设备上的签名结果决定。

## 队列与文件生命周期

系统授予的临时 URI/NSItemProvider 表示会先复制到应用可持续访问的接收目录，原件不动。所有文件准备好后才原子写入批次 manifest。主应用读取 pending、成功加入并保存待发送区后 ack；ack 只移除 manifest，不删除已经加入待发送区的文件。

Android 合并 ClipData 和 EXTRA_STREAM，按 URI 去重，同时保留多个文本、URL及附带说明。普通文件保持原始字节，预览不支持也能分享和传输。系统文件管理器分享的目录/Tree URI 会按原目录结构导入，包含空目录，不压缩为 ZIP。iPad 在 NSItemProvider 回调返回前复制临时文件，避免回调结束后临时表示消失。[Apple API 说明](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation%28fortypeidentifier%3Acompletionhandler%3A%29)

Android 发出分享时同时提供 URI、ClipData 和只读 grant；多项使用 ACTION_SEND_MULTIPLE。[Android 系统分享说明](https://developer.android.com/develop/ui/compose/sharing/send)

## 设备验收

1. Android 分享两张图片、图片+视频、PDF、未知扩展名文件、两段文本/URL及包含子目录/空目录的文件夹到 GlobalSend；确认待发送内容完整、没有重复。
2. 分享后关闭/重新打开应用；确认待发送仍在。清空待发送后不应重新出现已确认的分享批次。
3. 选中多项后使用“全部拖拽”，拖到另一款支持多项的应用；拖回发送区域时，Android 不再复制自己的原件。
4. iPad 在 Files 分享多文件，完成后打开应用；再测试冷启动和运行中 Open In 文件。确认主 App/扩展的组权限匹配。
5. iPad 切换选择后再开始拖动，必须拖出新选择；拖动期间收到新内容，当前原生拖动源保持不变，下次拖动才应用更新。

本地检查覆盖了 Android 框架及持久化队列、Dart 通道参数和 iOS 项目结构。iOS Swift 编译由 macOS GitHub Action 执行；安装后的系统分享与跨应用手势仍需设备验收。
