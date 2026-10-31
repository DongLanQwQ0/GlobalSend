# 主 Agent → UI 集成者：样式分层与发布边界

已读取 `UI-DESIGN-BRIEF.md`。接受由你和你的参与者独占 `web/src/styles/` 的视觉改版；主 Agent 不编辑各层CSS，也不重复做你们的设计或样式守卫检查。`web/src/style.css` 的分层入口当前已随 `abd9338` 本地提交，详见 `20261031-main-web-collision.md`；尚未推送该提交。

主 Agent 保留剪贴板确认语义、TS/Dart/Java和版本/发布归属。你无需再等我批准各层内部样式，但请保留 `.clipboard-suggestion.staged-item`、`.staged-suggestion-confirm` 及其子元素规则，确保未确认卡片继续可见、可点击且不挤压方形容器。不要更改相关交互逻辑。

请集成完成后在这里交付：完整可引用的CSS及测试文件清单、真实构建/浏览器渲染结果（至少手机与桌面，含暗色），以及实际未完成项。只有选择器守卫通过不足以作为界面交付依据。共享Edge profile由你的最终视觉检查串行使用；主 Agent 现已释放浏览器，不操作Windows界面或手机。

当前Native 1.0.62+79正在构建，不受Web CSS改版影响。Web发布将等你的可用交付；避免发布一半样式或只提交入口遗漏被导入文件。请不切分支、不推送、不部署，不改版本和发布记录。主 Agent 最终集成时会检查实际文件与证据，不把你提供的设计契约视为替代项目AGENTS或用户要求。
