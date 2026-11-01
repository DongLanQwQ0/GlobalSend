# 文件复制推送（接入中）

开启此选项并指定目标设备后，Windows 复制的文件/文件夹只向这些设备公布可拉取条目。**不向整个组广播**；未指定目标不推送，同组未选设备既不接收通知，也不能查询或拉取该批次。设备按唯一 ID 区分，不按名称区分。

目标设备在组内共享区和悬浮暂存坞中看到条目，点击才请求来源通过现有文件传输发送；未点击不上传文件内容。文件夹仍为单个条目，拉取后保留目录结构。来源只在本机保留原路径引用，中心只接收名称、类型、大小与不透明条目 ID。切换剪贴板或推送目标时撤回旧条目；关闭选项、来源最后一个连接断开时撤回，不保留离线文件分享服务。

## 中心协议

所有接口在 `/api/v1` 下，使用现有设备认证。

- `PUT /clipboard/files`：`{offerId,targetDeviceIds,items:[{id,name,kind,size?}]}`。`kind` 为 `file` 或 `directory`。目标必须显式给出且与来源有共同组。相同批次重试不重复通知；更换内容或目标时使用新批次 ID。
- `GET /clipboard/files`：仅返回发给本机、来源在线且仍在共同组中的条目。不返回其他被选目标的 ID；多组重合不重复展示。
- `DELETE /clipboard/files`：撤回本机批次，只通知该批次原指定目标，不通知其他组员。
- `POST /clipboard/files/:sourceDeviceId/pull`：`{offerId,requestId,itemIds}`。只有指定目标能请求。相同请求重试只唤起来源一次，来源收到 `clipboard.files.pull`。
- `GET /clipboard/files/pulls`：来源补取尚未处理的请求，供恢复连接后接续。
- `PUT /clipboard/files/pulls/:targetDeviceId/:requestId`：来源报告 `{state,error?}`，状态为 `sending/sent/failed`。目标收到 `clipboard.files.pull.updated`；已终结状态不被旧回执退回。
- `GET /clipboard/files/pulls/:requestId`：目标查看自己的请求状态。

`clipboard.files.changed` 是指定目标的刷新通知，不携带路径或文件内容。中心重启后不保留这些临时引用，来源恢复连接后重新发布当前复制批次。文件传输仍使用既有 offer/接收流程及内网→公网→中继选路，不添加第二套文件通道。

## 当前状态与下一步

中心接口、共享协议类型及 HTTP/WebSocket 定向测试已完成。3 项用例覆盖按目标通知/可见/拉取、同名设备按 ID 区分、未点击不创建传输或消息、重复请求、目录单条目、多组去重、换目标撤回、关闭/离线/重启生命周期；类型检查通过。证据：`artifacts/tmp/copied-files-targeted-tests.log`、`copied-files-targeted-typecheck.log`。

**尚未上线，也尚未在客户端提供此功能。** 下一步由本任务接入 Windows 文件复制事件与目标选择、按需发送，以及原生/Web 的共享区和悬浮窗条目；保留现有文本剪贴板、建议确认、待发送草稿和系统拖放。待客户端接通再构建与部署，不把中心接口通过测试当作整项完成。
