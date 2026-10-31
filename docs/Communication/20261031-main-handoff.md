# 主 Agent → 外部 Agent：新增功能接入

状态：通信入口已建立，等待用户提供新增功能需求。

## 当前正在修改的功能

主 Agent 正在实现未确认的剪贴板建议卡：发送页待发送区域和 Android 悬浮窗暂存区均展示；点击后才加入对应列表，未确认时不计数、不参与直接发送或全部拖出。

当前 HEAD：`8f9ca8c`。以下文件有主 Agent 的未提交改动，暂由主 Agent 独占写入；外部 Agent 如需修改，请先通过本目录协商：

```text
client/lib/screen.dart
client/lib/clipboard_suggestions.dart
client/test/clipboard_suggestion_widget_test.dart
client/test/clipboard_suggestions_test.dart
client/android/app/src/main/java/dev/globalsend/globalsend/ReceiveOverlay.java
client/android/app/src/test/java/dev/globalsend/globalsend/AndroidDragTest.java
web/src/style.css
web/src/workspace_view.ts
web/test/convenience.test.ts
web/tool/accept_clipboard_suggestion.mjs
```

此列表是交接时快照，开始修改前仍需检查实际 `git status` 和相关 diff。版本文件、发布记录和公共发布流程由主 Agent 统一维护，不并行升级、部署或切换设备版本。

## 外部 Agent 下一步

收到用户的新功能说明后，回复本文件，列出功能目标、平台、计划修改范围及所需接口。重叠文件确认归属后即可开发，无需逐文件请求批准；独立模块可在明确需求后直接推进。

## 设备与验收边界

- 当前不得测试 Windows 界面；构建、更新和重启仍按现行项目约定执行。
- 手机操作需协调占用，不能假定手机空闲；不操作聊天或自动发送聊天消息。
- Android 模拟器只复用公共的 `Chrona_Classroom_36`，禁止复制；浏览器自动化复用已有 persistent profile，串行使用。
- 已有设备高亮和 Android 接收文件可见性由用户验收通过，不因新功能重复打开旧问题。

主 Agent 将在继续工作时读取本目录新留言并写入回复。尚未向外部 Agent 发送启动消息，尚无外部 Agent 接收确认。
