# Windows 文本拖出为 TXT · 1.0.93+118

## 行为

- 文本卡片、文本详情、建议/自动剪贴板槽位和接收坞沿用共同的 Windows 原生拖放入口。同一次 OLE 数据对象保留 `CF_UNICODETEXT`，并新增 `FileGroupDescriptorW` / `FileContents`。
- 桌面或资源管理器接收为 `GlobalSend 文本.txt`，UTF-8 含 BOM，中文、表情和原换行保留。文件名冲突由目标系统处理。
- 文本目标及 GlobalSend 内部投放仍可读取原文字；不伪造 `CF_HDROP`，不提前写入缓存或历史，取消时没有导出文件。
- 每次文件读取返回独立的内存 IStream，延续原有异步复制生命周期、系统拖影及鼠标/触屏路径。

## 检查

- `client/windows/test/text_drag_file_test.cpp`：实际 Windows Shell 文件夹 IDropTarget 创建项目专用目录中的 TXT，字节内容一致；验证文本/虚拟文件并存、枚举索引、独立流、内部回投。测试产物已删除，无真实桌面投放或系统剪贴板操作。
- 既有 `drag_data_test.cpp` 通过：Unicode、原文件/文件夹路径、Shell 私有拖影/IStream、窗口内回投、跨线程 COM 和异步复制生命周期。
- 日志：`artifacts/tmp/text-drag118/test.log`、`regression.log`。最初测试错误地假定 IStream EOF 必须 S_FALSE，并在异步复制关闭独占句柄前读目标，已按实际 Windows 语义修正检查。

## 交付

`pnpm run release:local -WindowsOnly`成功，源码`81e8fc4a9c6a77fd815de2eb13ce24a9247016b5`。完整目录覆盖至`E:\Programs\GlobalSend`并重启，实际EXE为`1.0.93+118`，进程9164。本地ZIP为`artifacts/releases/GlobalSend-1.0.93-windows-x64.zip`，22,608,641字节，无字体文件。

本轮仅更新 Windows；Android/中心/Web 保留117，IPA保留114，未另发GitHub Release。真实桌面/Explorer手势由用户验收，不操作用户的Windows界面进行测试。
