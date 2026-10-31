# Android 剪贴板长按拖放：1.0.68+85

## 行为

- 发送页剪贴板按钮及剪贴板建议卡：点按维持添加行为，长按直接交给 Android 系统拖放；拖动本身不加入待发送，也不自动发送。
- 悬浮坞剪贴板建议：同样支持长按系统拖放，离开悬浮坞后复用设备投递模式和边缘滚动。
- 文本、图片、文件均使用原有系统数据及 URI 引用，不为拖动预先导入一份待发送副本。
- 取消拖放保留建议；成功投放后移除对应建议。投回暂存坞成为普通暂存内容。批量拖动仍不包含未确认建议。
- 长按读取剪贴板时不重建手指下的建议卡，原生导出继续复用已有会话、权限与主题预览。

## 检查与交付

- 原生用例覆盖文字取消/投回待发送、投回暂存、图片与文件 URI、悬浮坞长按及设备模式。证据在 `artifacts/tmp/clipboard85/android-final.log`（其他四项）和 `overlay-final.log`（修正 ViewGroup 拖放测试桩后通过的悬浮坞项）。
- Flutter 两项测试通过：长按按钮/建议不确认、不发送；点按仍添加。Android 手势夹具与 Windows 布局夹具分文件运行，避免测试进程内切换平台。证据：`artifacts/tmp/clipboard85/flutter-final.log`。
- 源码：`0dfee258cb797d6bec0922a2aefec2ccc035cba5`。
- Windows 完整包已替换并重启：`E:\Programs\GlobalSend`，文件版本 `1.0.68+85`，PID 38328；本轮未操作 Windows 界面。
- APK：`artifacts/releases/GlobalSend-1.0.68-android-arm64-v8a.apk`，16,364,140 B，无字体文件。
- 手机 `10.194.175.80:36197` 已覆盖安装，读回 `versionName=1.0.68 / versionCode=85`，更新时间 2026-10-31 15:41:07。数据保留，未自动唤起或控制手机界面。
- 首次流式安装卡住且手机无确认提示；仅停止本次 adb 安装客户端，APK 以 11.5 MB/s 上传至 `/data/local/tmp/GlobalSend/clipboard85/update.apk`，本地覆盖安装成功。临时 APK 与任务目录已删除。证据：`phone-apk-push.log`、`phone-local-install.log`、`phone-version.txt`。
- 实机长按和目标应用投放由用户验收；本轮为 Android 功能修改，Web/服务端未改动，未重复部署，也未构建 IPA。
