# Windows 触屏拖放

1.0.83+108 修正原生触点交给 OLE 的时机。长按准备卡片拖影在后台完成；准备回复只标记就绪，不在这条异步消息里转换触点。随后由同一触点的真实输入消息接管；如果 Windows 已经提供了触屏/笔的鼠标兼容流，直接沿用，不再转换一次。

移动、抬手和跨应用投放继续由系统 OLE 处理，复用窗口内外的同一拖影和数据对象。旧的逐事件 `SendInput` 与低级鼠标钩子分支已移除。准备期间松手、取消或触点被替换会结束该次准备，不消耗下一次触点；转换失败会保留实际 Windows 错误码。

## 当前证据

- 隐藏 HWND 组件检查覆盖真实消息上下文、已有系统兼容流、准备期间抬手、1000次移动、捕获交接、drop/cancel、触点编号复用和主窗口/接收坞隔离。
- 生产源文件 MSVC `/W4 /WX` 编译通过；既有文件/目录准备及取消组件检查通过。
- 证据：`artifacts/tmp/windows-touch-native-20261102/RESULT.md` 及同目录两个构建日志。
- 按用户要求，没有操作实际 Windows 桌面、剪贴板或触屏。实际触屏跨应用投放及拖影连续性仍待用户验收；组件里的系统转换和 OLE 回调替身不能代替它。

截图当次旧版本没有保存 `GetLastError`，无法追溯那一次系统拒绝的确切原因。当前修复针对可从源码证明的异步接管和重复转换问题。

## 系统接口

[ConvertPrimaryPointerToMouseDrag](https://learn.microsoft.com/en-us/windows/win32/winmsg/winuser/nf-winuser-convertprimarypointertomousedrag) 将正在进行的主触点转换为系统鼠标消息流；[DoDragDrop](https://learn.microsoft.com/en-us/windows/win32/api/ole2/nf-ole2-dodragdrop) 负责目标检测与 OLE 投放。应用不再自行逐次注入移动和松手。
