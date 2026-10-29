# Android 打开安装包

在接收、文件库或暂存坞打开 `.apk`，交给系统安装器处理。首次使用时，按系统提示允许来自 **GlobalSend** 的安装，然后继续；安装确认由用户完成。

49版补齐 `REQUEST_INSTALL_PACKAGES` 声明；自选目录将APK报为普通文件或ZIP时，按显示名称恢复APK类型，保留原URI并附带读取授权，不复制接收文件。普通文件和目录继续使用原来的查看方式。

`.apks`、`.xapk`或包含多个分包的文件夹不是单个APK，目前不自动合并安装。

来源授权说明：[Android Developers](https://android-developers.googleblog.com/2017/08/making-it-safer-to-get-apps-on-android-o.html)。

1.0.49（58）已覆盖安装到vivo，实际版本读回一致；6项针对性框架测试通过。用户确认“already work”，本项验收通过，不再重复测试。记录：`artifacts/reports/android-apk-open49.json`。本轮未进行Windows界面测试，iOS不受此Android专属修复影响。
