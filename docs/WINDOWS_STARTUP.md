# Windows 启动

在 **设置 → 启动 → 开机自启动** 打开开关。默认不自动开启；启用后，在当前用户登录Windows时后台启动GlobalSend，不弹主窗口。

也可以直接运行：

```powershell
& 'E:\Programs\GlobalSend\GlobalSend.exe' --background
```

- 启动托盘和原有接收服务，不切换前台、不创建第二个实例；已有实例时安静退出本次启动。
- 点击托盘或不带参数打开GlobalSend，可以恢复主窗口。后台收到内容时仍按接收设置展示，不改变原有收件行为。
- 同时传入文件或文件夹时，保留原有“打开窗口并加入待发送”操作，不自动发送。`--`之后的参数只作为文件名处理。
- 开关使用当前用户的[Windows Run启动项](https://learn.microsoft.com/windows/win32/setupapi/run-and-runonce-registry-keys)，名称为`GlobalSend`，命令是带引号的完整程序路径加`--background`；不需要管理员权限。关闭只移除这一项，不修改其他程序。

本轮按用户要求不进行Windows运行/界面测试，不改变用户的开机启动开关。构建与静态检查记录随本地发布保存。
