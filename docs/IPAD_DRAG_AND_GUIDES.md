# iPad 拖影、图片后缀与四端指南

## 102 版修复

- iPad 长按仅抬起所选卡片，不抬起整个 Flutter 页面。抬起、移动和取消使用卡片自身像素，不从 GPU 页面视图获取空白截图。
- 剪贴板建议可直接拖动。开始手势时读取系统真实 item providers，不将“文本”“图片”等提示标签当作拖放内容。
- `.pic`、无后缀及错误图片后缀根据实际容器补齐；PNG、JPEG、WebP、GIF、BMP、HEIC/HEIF、AVIF 不转码。iPad 分享、剪贴板和拖入共用导入器；原生和 Web 发送入口也处理占位名称。目录树成员保留原名称和相对路径，原始文件不改名。
- 设置增加“使用指南”，未连接的原生首页也可打开。Android、iPad、Windows、Web 分别说明各平台操作，Android 重点介绍悬浮暂存坞。

指南统一编辑源为 `packages/guides/usage.json`。执行 `npm run guides:generate` 更新应用内容及 `docs/guides`；构建检查生成物是否同步。没有增加字体或教程运行依赖。

## 样本与检查

用户提供的 `977.pic` 实际为 PNG，65,017 字节。使用这份样本的真实中心提交验证得到 `977.png` / `image/png`；原文件未修改，同一文件作为目录成员时保持 `Album/977.pic`。

- 原生样本与目录树：`artifacts/tmp/ipad102/image-transfer-final.log`，对应 `names-*/result.json`。
- Web 样本：`artifacts/tmp/ipad102/web-977-result.json`；Web 发送和目录回归：`web-image-names.log`。
- 设置入口、Esc 返回及未保存草稿保留：`artifacts/tmp/ipad102/guide-entry-final.log`。
- 原生指南实际绘制与 Web 固定浏览器配置检查：`artifacts/tmp/platform-guides102`。
- Swift 导入回归随 iPad 工作流在 macOS 上运行；UIKit 实际卡片强调和跨应用拖影仍由新版 iPad 真机确认。

## 已接受的行为

101 版自动截图发送已由用户确认通过；Windows 接收截图后实际 Ctrl+V 因暂无第二台 Windows，仍保留为未验。iPad 基本跨应用拖放已由用户确认成功；这不代替 102 的单卡强调、拖影和剪贴板建议拖动验收。

新 IPA 在 Windows/Android 构建稳定后生成，仍由用户用 iloader 手动签名安装，不操作用户的 iPad。
