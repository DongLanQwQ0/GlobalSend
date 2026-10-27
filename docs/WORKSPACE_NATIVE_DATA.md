# 新工作区的数据接口

## 待发送与目录

- `SendController.stageInputs(paths, texts)`：普通文件保留外部路径引用；目录在应用专属状态目录流式归档，保留根目录和空目录。
- `chooseSendDirectory()`：Windows 目录选择器；Android SAF 只读目录选择器。Android provider 在后台线程归档，不一次加载全部文件。
- `stagedDirectoryNames[path]`：目录原名；传输对象是 `目录名.zip`，接收方收到 ZIP，不自动解压。
- `removeStagedFile(path)`：移除队列并释放只由待发项持有的临时源。
- `stageClipboard()`：用户点击后读取一次。Windows 支持文件/目录路径、位图和文字；Android 按 ClipData 的 URI/文字导入。未开启后台剪贴板监听。

目录归档只作为传输源：有活动/重试传输时保留；所有引用的传输均终止后释放。`DockEntry.sourceReference` 保存原目录引用，历史重发调用 `requeueDockEntry(item)` 重新打包。普通文件不额外生成发送副本。

## 卡片、引用和删除

- `ContentPreview(location:, name:, text:, fit:, compact:)` 为图片显示限解码尺寸的缩略图，为文本/HTML/代码读取前 4 KiB 摘要。
- `createdAtMillis`、`receivedAtMillis` 持久化显示时间；旧快照未知时间为 0，不伪造为今天。
- `deleteDockEntry(item)` 删除发送记录时仅删引用；接收文件通过现有文件库 ownership 删除；进行中的传输先取消。隐藏 ID 持久保存，服务端重拉不会让删除卡片重现。
- 每轮本地维护移除已被外部删除的发送引用。`requeueDockEntry` 支持文本、普通文件、目录。
- Windows 可向外拖出原目录；Android 历史原目录不提供直接外拖，应重新加入待发。接收的 ZIP 和普通文件仍可拖出。

## 组内共享编辑

`GroupSharedText` 独立维护一个组文档。控制器在 WS hello 后连接并读取，断线保留草稿，切换会话清空文档。旧中心没有 `features.groupSharedText` 时不发送请求。

- `sharedText`：当前本地草稿；`sharedTextRemote`：最新远端文本。
- `sharedTextDirty`、`sharedTextConflict`、`sharedTextRevision`、`sharedTextStatus`：供 UI 呈现。
- `setSharedTextDraft(value)`：400 ms 防抖提交；UI 在 IME composing 结束后调用。
- `retrySharedText()`：冲突后保留本地并以最新 revision 提交。
- `useRemoteSharedText()`：采用远端。

PUT 使用 `baseRevision`，409 读取 `ApiException.response.current`。并发更新保留本地草稿，不自动覆盖；发送中继续输入不会被自身 ACK 回滚。本功能不读取系统剪贴板。

## 本轮证据

- `artifacts/logs/workspace-native-core-tests.log`：11 项通过，涵盖真实文件目录结构、临时归档多活动引用/完成释放/原目录重发、删除引用不删原件、持久隐藏、共享编辑 fake API 冲突和写入中继续输入。
- `artifacts/logs/workspace-core-analyze.log`：所改 Dart 数据/预览源码无分析问题。
- `artifacts/logs/workspace-java-compile.log`：当前 Android 目录、拖出预览、Activity 分发桥接通过 Java 17 编译。
- `artifacts/logs/workspace-windows-bridge-compile.log`：新增手动剪贴板 C++ 桥接在 `/W4 /WX` 下编译通过，既有 OLE 导入用例通过。

共享文档真实中心 HTTP/WS、最终 UI 渲染和 Release 构建由根任务与 UI owner 集成。Android 真机 SAF、剪贴板、跨应用新拖出图像仍需实机使用验证；Java 编译不代表该项验收。
