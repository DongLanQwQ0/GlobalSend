# Android 文件打开与悬浮窗触觉反馈

## 打开文件不再依赖断开的插件通道

`open_filex 5.0.0` 的 Android 插件在 `onDetachedFromActivity()` 移除 `open_file` 通道，但 `onAttachedToActivity()` 没有重新安装它。GlobalSend 复用后台 FlutterEngine，宿主 Activity 重建后，普通路径的打开请求因此会出现截图中的 MissingPluginException。

Android 的普通路径与 SAF URI 现在统一进入现有 `ReceiveDestination → ReceiveDirectory → AndroidFileOpener`：原生打开器保留 MIME、APK 安装器及只读 URI 授权；普通文件复用包内已有的 FileProvider，不使用拖拽专用的十分钟 URI，也不复制文件。SAF URI 保持原身份；原始路径被 scoped storage 隐藏时，沿用已有的文档授权映射。其他平台继续使用原先的打开方式。未修改公共 PubCache 插件或用户文件。

## 悬浮窗反馈按实际动作触发

- 展开、进入“发送至设备”：明确的长按级反馈。切入设备模式只震动一次，初次静态高亮不叠加另一次轻震。
- 改变目标设备：轻刻度反馈；同一设备内的连续位置事件不重复。边沿滚动只有跨到新目标才反馈。
- 分类切换、复制、移除、忽略建议：点击反馈。清空、建议加入暂存、投放成功或失败分别反馈结果；取消待删除也有确认反馈。
- 移动窗口、抓住缩放边缘、拖动贴边把手：起步反馈；操作完成、贴边收起时反馈。惯性滚动和动画逐帧不震动。
- 新收件和再次收到同一内容有反馈；同一收件的进度/展示刷新不反馈。组内共享仍不进入收件提醒。
- 长按开始系统拖动沿用系统反馈，拖动无法启动会给失败反馈；没有强制忽略系统触觉设置，也没有新增震动权限。

## 验证

- 原生定向回归通过：本地文件、APK、SAF、Activity 重建后复用通道、真实原文读取、文件被删除时返回读失败而非 MissingPlugin；保留既有 APK/MIME 和外部文档读取回归。
- Windows 宿主的 Robolectric 无法使用 AndroidX 的 Linux 文件根路径匹配，因此文件打开用例仅替换 URI 创建这一步，通道、宿主重连、打开 Intent、MIME、授权和文件内容仍被检查。构建后还需核对包内实际 FileProvider 声明。
- 设备模式的两秒反馈、目标切换/重复悬停、成功投放、复制/移除/清空、新收件/被动刷新通过。把手起步/松手/惯性无重复反馈通过；原有展开/拖入与重复位置不震动的回归也通过。
- Dart 文件引用、SAF 描述符读取、文本预览和图片缩略图四项回归通过。
- 证据：`artifacts/tmp/android-open-haptics90/accepted.log`、`open-accepted.xml`、`controls-accepted.xml`、`handle-haptics.log`、`read-regression.log`。

## 本地交付：1.0.73+90

- 源码：`2496075d6924c2332fe753363f2012e62f3ab814`。
- 完整构建成功；Windows 已替换并重启于 `E:\Programs\GlobalSend`，实际文件版本 `1.0.73+90`、PID 10668。
- Android：`artifacts/releases/GlobalSend-1.0.73-android-arm64-v8a.apk`，16,368,972 字节，包元数据为 `versionName=1.0.73 / versionCode=90`。本轮未推送、安装或启动手机应用。
- Windows：`artifacts/releases/GlobalSend-1.0.73-windows-x64.zip`，22,420,661 字节。两个产物均通过无字体文件检查。
- 已核对实际 APK 的 FileProvider authority、`exported=false`、URI 授权及 `FILE_PROVIDER_PATHS` 资源。资源压缩后实际路径为 `res/oS.xml`，文件/缓存/外部存储等原有路径配置存在，不是仅检查源清单。
- 证据：上述任务目录中的 `release-build.log`、`delivery.json`、`apk-version.txt`、`file-provider.txt`、`file-provider-paths.txt`。
- 手机操作暂停保持，触感与真实系统查看器仍需新包实机验收。未操作真实 Windows 桌面做功能测试，未更新 Web/服务器或构建 IPA，安装包未上传中心服务器。
