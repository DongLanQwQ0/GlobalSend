# 悬浮窗停留两秒切换设备：Windows / Android

用户确认两端都要。外部内容进入悬浮窗并持续停留两秒，显示可发送设备；继续拖到目标设备后松手，才发送本次投放内容。不到两秒就离开、取消或结束拖动，不切换；悬浮窗隐藏也取消等待。Android 未满两秒松手仍是原有暂存导入。

## 接入真实入口

- Android：根窗口管理进入/离开与两秒等待；把手先展开，进入设备模式后沿用已有设备列表、悬停高亮和帧同步边沿滚动。内容只在 DROP 时读取：应用内拖动复用原会话，外部文件保留系统 URI 授权直到后台复制完成，然后进入现有定向发送入口。不会先塞进暂存或接收记录，也不发送其他草稿。
- Windows：扩展现有 OLE DropTarget 的跟踪回调，使投放尚未启用时也能观察停留，保留 Shell 原生拖动影像。接收坞的展示引擎显示来自主控制器的设备列表，通过现有物理像素区域发布器登记目标。DROP 解析原始文件/文字，交由唯一主控制器定向发送；展示引擎不另建网络会话。设备模式只淡出原接收内容，不卸载正在拖出的来源控件。
- 两端停留本身均不发送；切换后继续指向设备并松手才发送。Windows 设备列表支持指针停在边缘时按帧滚动。

## 验证记录

- Android `ReceiveOverlayDeviceTargetsTest` 的相关八项通过：两秒边界、连续位置事件、重复 START 不重置、离开/结束/隐藏取消、快速暂存、把手展开后切换、真实文件仅在 DROP 后读取、目标设备 ID/原文、既有导出与滚动。结果：`artifacts/tmp/android-dock-hover89/android-accepted.xml`。
- 同类旧的空白双击用例在本次候选和原 HEAD 均失败，原 HEAD 对照记录为 `blank-baseline.log/xml`。该用例的暂停 VSync 与窗口遍历需要单独处理；未改动产品的双击分支。
- Windows OLE 导入测试通过：尚不可投放时仍能跟踪，不提前读取内容；目标启用后成功接收，结束停止跟踪。接收坞控件的两秒切换、取消、设备去重/高亮、区域发布和边沿滚动通过；主控制器只发送投放批次，原草稿保留。既有独立接收坞路由/删除/首帧/延迟回执四项回归通过。
- 实际控件渲染已检查：`render/incoming-device-mode.jpg`（Android），`windows/device-mode.jpg`（Windows），均在上述任务目录内。Flutter 测试引擎出现过无断言的提前退出；分开用例并保留阶段日志后通过。
- 本次未控制真实 Windows 桌面或手机进行新手势验收；之前的手机界面操作暂停仍保留。

## 本地交付

- 源码：`2bbb6550f461382e55243910c5ad1b6d7f8961ff`。Windows 桥接坐标已显式编码为 codec 支持的整数类型，原生构建通过。
- `npm run release:local -- -DeferPhone` 成功，完整替换并重启 `E:\Programs\GlobalSend`；实际文件版本 `1.0.72+89`，PID 19660。
- Android APK：`artifacts/releases/GlobalSend-1.0.72-android-arm64-v8a.apk`，16,370,000 字节。包元数据确认 `versionName=1.0.72`、`versionCode=89`。尚未推送或安装，手机仍保留最后确认的 `1.0.68+85`。
- Windows ZIP：`artifacts/releases/GlobalSend-1.0.72-windows-x64.zip`，22,420,915 字节。两个包均通过无字体文件检查。
- 构建及实际产物证据：`artifacts/tmp/android-dock-hover89/release-build.log`、`delivery.json`、`apk-version.txt`。
- 待手机操作恢复后，覆盖安装 APK 并进行新悬停手势的实机验收。未操作真实 Windows 桌面做投放测试，未更新 Web/服务器，安装包未上传中心服务器，也未构建 IPA。
