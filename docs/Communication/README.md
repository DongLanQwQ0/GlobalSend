# Agent 协作入口

本目录用于 GlobalSend 主 Agent 与外部 Agent 沟通需求、接口、代码归属和交付。路径：`F:\Codes\Java\GlobalSend\docs\Communication`。

## 如何开始

外部 Agent 先阅读项目根目录的 `AGENTS.md`、本文件及本目录最新留言，再发布一份需求确认：功能目标、涉及平台、计划修改范围、依赖主 Agent 的接口。新功能的具体需求由用户提供，目前尚未登记。

每条留言独立保存为 UTF-8 Markdown 文件，例如 `20261031-110000-external-feature.md`。文件名包含时间和发送方；不要覆写对方的留言。回复时引用原留言文件名。

留言只需包含与本次协作有关的信息：

- 发给谁、需要什么决定或接口；
- 自己负责的功能及拟修改文件；
- 当前结果、阻塞项和下一步；
- 交付时附实际文件或提交、运行方式、已完成的检查及尚未验证的行为。

## 修改与集成

- 同一文件或紧耦合接口只保留一个写入方。改动重叠时，先留言确定归属，再开始修改；已存在的未提交内容不得覆盖或回退。
- 外部 Agent 负责新增功能及其必要检查；主 Agent 负责跨模块协调、集成和最终交付。功能需求与文件归属确认前，可先只读调查。
- 默认复用当前 checkout，不自行创建新 worktree。提交只包含自己负责的文件；禁止 `git add .`、整树清理或重置他人改动。
- 构建、设备操作、浏览器配置和发布遵循项目及用户现行约定。需要共用手机、模拟器、浏览器 profile 或发布窗口时，先协调占用；源码检查不能代替实机验收。
- 不在留言中放入密码、组密钥、token 或私钥。项目日志和临时文件放在项目内。

## 当前实时通道

外部UI集成者已建立 `scripts/agentbus.mjs` 本机HTTP通道，消息留存在本目录 `bus/transcript.jsonl`，`THREADS.md` 是生成的摘要，不手工改写。GlobalSend主会话使用 `external` 身份，UI集成者使用 `orchestrator` 身份。

```sh
node scripts/agentbus.mjs status --json
node scripts/agentbus.mjs inbox --as external --json
node scripts/agentbus.mjs wait --as external --timeout 120s --mark --json
node scripts/agentbus.mjs send --from external --to orchestrator --kind answer --subject "交付回复" --ref m000001 --body-file path/to/message.md
```

命令在项目根目录运行。先检查现有服务，不重复启动或停止对方的服务；浏览器profile和设备占用仍需明确协调。文件或消息存在不代表已接收、批准或执行，处理后回复具体采用的决定、实际结果和后续负责人。服务地址从运行元数据读取，只使用本机回环，不暴露到公网。
