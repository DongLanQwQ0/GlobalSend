# 本机消息总线（agentbus）

约定通信仍以本目录的 Markdown 为准；总线是**加速通道**，不替代留言。

## 形态

- 单一真源：`bus/transcript.jsonl`（一行一条 JSON，`seq` 单调递增，`thread` 由 `refs` 继承）。
- 两种传输，自动选择：`bus/run/server.json` 存活且有 `/health` 应答 → HTTP 长轮询（消息到达即唤醒）；
  否则直接追加写文件并用文件锁串行化。功能等价，只是等待退化为轮询。
- 只监听 `127.0.0.1`，默认端口 8722（刻意避开中心服务的 8787）。每次启动生成随机 token，写在 `bus/run/server.json`。
- 运行时文件（`bus/run/`、`bus/lock`、`bus/ack/`）已 gitignore；`transcript.jsonl`、`leases.json`、`THREADS.md` 入库。

## 命令

```
npm run bus -- status                          # 通道健康、各 agent 未读数、当前租约
npm run bus -- send --from A --to B --kind question --subject "标题" --body-file note.md
npm run bus -- inbox --as B [--all]            # 未读 / 全部
npm run bus -- wait --as B --timeout 60s       # 阻塞等；0 收到 / 3 超时 / 2 用法错
npm run bus -- watch --as B                    # 持续打印
npm run bus -- ack --as B [--seq N]
npm run bus -- log --tail 20 | show m000012
npm run bus -- lease --owner A path...         # 文件租约，冲突退出码 5
npm run bus -- leases
npm run bus -- doctor                          # 全 PASS 退出码 0，异常 4
```

也可以 `node scripts/agentbus.mjs <命令>`。`--body-file -` 从 stdin 读，适合管道与多行 Markdown。

## 消息形状

```json
{ "seq": 12, "id": "m000012", "at": "2026-10-31T02:50:19.000Z",
  "from": "main", "to": "orchestrator",
  "kind": "question", "thread": "m000010", "subject": "一句话",
  "body": "Markdown", "refs": ["m000010"], "attachments": [], "meta": {} }
```

`to` 支持单个名字、逗号分隔多个、或 `*` 广播；`from` 与收件名必须匹配 `[a-z0-9][a-z0-9._-]{0,63}`。
