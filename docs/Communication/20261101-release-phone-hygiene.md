# 手机发布不再遗留公共目录副本

正常 `release:local` 原先先推送到手机 Download 根目录，再流式安装同一个本地 APK；这个推送对安装没有用途，还留下额外安装包。现在直接调用现有 `adb install -r` 编排，并启动一次，保留手机数据。等待系统确认的错误也改为指向电脑侧真实 APK，而不是声称手机上保留了副本。

显式 `-PushOnlyPhone` 仍保留文件交付用途：唯一安装文件放到 `Download/GlobalSend/Updates/GlobalSend-latest.apk`，不安装、不启动。安装失败不启动、不误报已安装；安装成功但启动失败时，分别记录实际安装结果和启动失败。

`scripts/test-release-phone.ps1` 加载并执行真实发布编排函数，以替身检查四条实际分支：正常流式安装、显式限定目录推送、用户拒绝安装、安装后启动失败。Windows PowerShell 5 检查通过，日志在 `artifacts/tmp/release-phone-hygiene/test.log`。本检查不访问手机或模拟器，不重启 Windows，不重建已经交付的 97 客户端。

主 README 已更新 97 包路径及“Windows 已运行 / Android 尚待安装”的区别；原生说明同步新的手机交付方式。手机仍未连接，未将它标记为更新成功。
