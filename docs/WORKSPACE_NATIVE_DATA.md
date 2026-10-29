# 工作区数据接口

## 待发送保留原文件与目录引用

- `SendController.stageInputs(paths, texts)`：文件按外部路径或可持续读取的 content URI 加入待发；目录通过 `readFolderEntries` / `DockPlatform.directoryEntries` 枚举，不生成 ZIP。
- `stageDirectory(path)` 与 `chooseSendDirectory()`：Windows 使用目录选择器；Android 使用 SAF 目录树。`_directorySources` 保留目录来源，`stagedDirectoryNames` 仅存显示名称。
- 发送目录时，`FolderEntry` 保存真实来源和 `relativePath`；目录项包含根目录、子目录及空目录，文件项单独传输。接收方按真实结构直接写入接收目录。中心不支持 `folderTransfer` 时提示升级，不回退为压缩包。
- `removeStagedFile(path)` 仅移除待发引用；系统分享等功能创建、且已无引用的应用临时源才会释放。
- `stageClipboard()` 在用户点击或粘贴时读取一次。Windows 支持文件、目录、位图和文字；Android 按 ClipData 的 URI/文字导入。未开启后台剪贴板监听。

`DockEntry.sourceReference` 保存外部来源。`requeueDockEntry(item)` 支持文本、普通文件和目录；目录重发重新枚举原树，不重新打包。原件被删除后移除相应引用，暂不可读不等于文件已删除。

## 卡片、引用和删除

- `ContentPreview(location:, name:, text:, fit:, compact:)` 提供限尺寸图片缩略图和文本摘要。文本、图片的卡片重点为内容预览；路径、路由等进入详情。
- `createdAtMillis`、`receivedAtMillis` 持久化记录时间；旧快照未知时间为 0，不伪造为今天。接收列表和坞中最近内容优先。
- `deleteDockEntry(item)` 删除发送记录时仅删引用；接收文件按现有文件库 ownership 删除，进行中的传输先取消。隐藏 ID 持久保存，服务端重拉不让删除卡片重现。
- `requeueDockEntry` 和窗口内回投复用来源，支持继续转发。实际外部拖放由各平台导出接口和目标应用的可接收类型决定。
- 本地文件与历史按客户端身份保留，加入或切换组不会另建身份、复制文件或清空历史。

## 多组共享编辑

`GroupSharedText` 按本地身份和 `groupId` 独立维护文档。WS hello 后连接当前组并读取；断线保留草稿，重新连接获取最新修订。加入其它组不换设备令牌。组选择器只切换共享文档，不停止文件传输。

- `sharedText` / `sharedTextRemote`：本地草稿 / 最新远端正文。
- `sharedTextDirty`、`sharedTextConflict`、`sharedTextRevision`、`sharedTextStatus`：UI 使用；正常同步不显示冗余状态，失败时提示。
- `setSharedTextDraft(value)`：约 400 ms 防抖提交；UI 在 IME composing 结束后调用。
- `retrySharedText()`：保留本地草稿，以最新 revision 提交；`useRemoteSharedText()` 采用远端版本。
- `selectSharedGroup(groupId)`：在已加入组之间切换。HTTP 请求带该 `groupId`；WS 更新也按组派发，不能将另一组的正文写入当前框。

PUT 使用 `baseRevision`，409 从 `ApiException.response.current` 获取冲突版本。发送中继续输入不被自身 ACK 回滚；同步的修改仍可撤销。本功能不读取系统剪贴板，也不通知、不唤起接收页面。

## 对应实现与有效证据

- `client/lib/folder_transfer.dart`、`controller.dart`：当前目录枚举、逐文件收发与重发；历史归档辅助文件不是当前传输入口。
- `artifacts/reports/folder-direct-transfer.md`：真实原生目录收发证据。
- `artifacts/logs/multi-group-web-accepted.log`：Web 控制器及真实中心/OPFS 目录链路回归。
- `artifacts/logs/multi-group-native-tests.log`：原生选路、接收坞、真实中心共享文档回归。
- `artifacts/logs/multi-group-final-native-acceptance-fixed.log`：多组真实中心及双尺寸界面验证。

实际安装版本、真机验收缺口见 `PROGRESS.md`、`UI_ACCEPTANCE.md`。早期归档/ZIP 的实验日志仅用于历史问题追踪。
