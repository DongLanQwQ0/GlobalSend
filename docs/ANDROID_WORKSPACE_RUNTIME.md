# Android 工作区运行验收

## 运行对象

项目专用 `GlobalSend_JNI_36` AVD，Android 16 / API 36 / x86_64。

独立消费程序 `dev.globalsend.workspaceprobe` 直接编译生产 Java 桥接源码快照。它没有 INTERNET 权限，只使用本地合成文本、图片和 DocumentsProvider 文件树，不安装到用户手机，也不覆盖 GlobalSend 主应用。

- 构建入口：`scripts/build-android-workspace-runtime.mjs`
- 消费程序：`client/build/workspace-android-runtime/workspace-runtime.apk`
- 源码快照：`client/build/workspace-android-runtime/production-snapshot.json`
- 测试活动/文件树：`client/tool/android/WorkspaceRuntimeActivity.java`、`WorkspaceDocumentsProvider.java`
- 通知消费活动：`client/tool/android/WorkspaceNotificationActivity.java`

`--reuse-production` 仅重新构建消费端，继续使用记录中的生产源码快照，避免其他 owner 正在修改生产源码时混入未完成的版本。

## 拖出预览、剪贴板和文件夹通过

证据：`artifacts/screenshots/android-workspace/runtime-results/result.json`。

- 实际构造生产 `DockCoordinator.DragPreview` 并通过 `View.DragShadowBuilder` 在 Android Canvas 渲染：中文文本、圆角外观、图片缩略图均已查看。
- 1400×900 图片实际缩略解码为 175×112，圆角外侧透明。
- 对预览卡片实际长按，生产 `startDragAndDrop` 成功启动。
- 显式读取系统剪贴板的中文文本和图片，生产 `nativeDrop` 事件进入消费端待发列表；27356 字节图片内容保持。
- 实际系统 SAF 选择器打开本地测试 provider，点击“使用此文件夹”并确认授权。生产归档包含 `资料/`、空目录、空文件、嵌套中文 HTML 和图片；原文件内容保持。
- 对同一 tree 下的嵌套 document 再归档，只包含 `nested/`，未错误归档整个 tree 根目录。

压缩后已查看：

- `artifacts/screenshots/android-workspace/runtime-results/drag-text.preview.jpg`
- `artifacts/screenshots/android-workspace/runtime-results/drag-image.preview.jpg`
- `artifacts/screenshots/android-workspace/runtime-results/screen.preview.jpg`

原始 PNG 保留在同目录。

## 聊天通知原生链路通过

直接消费生产 `ReceiveNotifications` 与 `ReceiveNotificationCopyReceiver`；证据：`artifacts/screenshots/android-workspace/runtime-results/notification-result.json`。

- 实际系统通知授权对话框选择允许。
- Android `MessagingStyle` 与 HIGH 通知渠道（importance 4）实际生效。
- 同一消息修改正文后更新原聊天，仍为一条消息。
- 第一版创建的复制 PendingIntent 经实际 receiver 复制出第二版正文。
- 文件通知没有文本复制操作；自动同步文本、组共享文本都有复制操作。
- 实际下拉通知栏，点击组共享消息的“复制”，应用读取剪贴板得到相同的共享正文。
- 实际点击单条共享/接收通知正文，启动或返回应用，分别消费到 `shared`、`receive` 路由。
- 切换组后清除该应用先前的通知。

实际通知栏压缩图：`artifacts/screenshots/android-workspace/runtime-results/notifications-shade.preview.jpg`。

本结果覆盖 Android 模拟器中的生产 Java 原生链路，不代表 vivo 跨应用拖放或完整 Flutter 应用的后台网络接收；后台 owner 提供候选后单独验收。
