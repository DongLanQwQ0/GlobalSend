# Windows 拖动到设备修复：1.0.70+87

## 原因与修复

86 版已能从建议卡开始原生拖动，但导出调用使用 `perform()`，在等待 OLE 投放结果期间把 `working` 置为 true。发送页据此禁用了 `NativeQueueDropHost`，并将待发送区、设备区域从原生投放注册表清空。结果是卡片能拖起，设备却不能成为目标。

现在将原生导出生命周期标记为 `performExport()`：等待原生拖放时保留仍可见的队列和设备投放区域；设置页、非当前路由、接收弹层等真实隐藏条件仍保持原有行为。剪贴板建议、媒体建议、普通文件/文本卡片、组内共享和多项原生导出均接入同一入口，避免拖出窗口再返回时重复注销目标。

## 本次回归覆盖完整交互状态

- 修复前，用未完成的原生导出 Future 保持拖动，观察到已发布的区域变为 `enabled=false`，用例失败。证据：`artifacts/tmp/windows-suggestions87/device-drop-before.log`。
- 修复后，鼠标和触屏分别导出剪贴板、图片，等待投放期间区域始终启用；目标设备真实绘制范围的中心落在已发布的物理像素矩形内。
- 原生设备悬停事件只高亮目标卡片，不高亮另一台设备、不显示全窗口遮罩。渲染 JPEG 已检查：`artifacts/tmp/windows-suggestions87/device-hover.jpg`。
- 模拟原生目标投放事件后，发送入口收到匹配设备 ID、服务器上下文及真实文本/文件路径，只发送投放的批次，保留原有草稿；取消拖放则不发送、不确认建议。
- 上述控件回归通过，日志为 `device-drop-accepted.log`。真实控制器的设备定向发送/失败保留、Windows 消息桥、Android 剪贴板入口回归也分别通过，日志在同一目录。
- 遵照用户先前要求，未自动操作真实 Windows 桌面；本次设备投放证据为控件及控制器自动回归，不是已向用户真实设备传输文件的记录。

## 已交付

- 源码：`6309cffb033bacc809e2a25e2a5dbadeb3b52882`。
- `npm run release:local -- -WindowsOnly` 成功；完整替换并重启 `E:\Programs\GlobalSend`，实际文件版本 `1.0.70+87`，PID 27488，无字体文件。
- Windows 包：`artifacts/releases/GlobalSend-1.0.70-windows-x64.zip`。
- 手机保留 `1.0.68+85`，未访问 ADB；Web、服务器、GitHub Release 和 IPA 均未变更。
