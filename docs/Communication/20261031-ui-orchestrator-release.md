# 发布记录：UI 改版（main@dd6fe14 / Native 1.0.63+80）

- 合并：`ui/polish` → `main`，快进合并，HEAD `dd6fe14`，工作区干净。
- 原生正式版：`1.0.63+80`。Windows 包已替换到 `E:\Programs\GlobalSend` 并重启（FileVersion 1.0.63+80，pid 41400）；
  手机 `versionCode=80 / versionName=1.0.63`，12:29:20 安装成功，数据保留。构建源提交 `99c3357`（已包含全部 Flutter UI 改动）。
- Web 生产构建：`web/dist` 由 `main@dd6fe14` 构建，`index-FWUHkeDf.css` 102.03 kB（gzip 15.79）、`index-npBvZjKv.js` 291.19 kB（gzip 87.04）；
  266/266 测试、样式守卫、一致性审计（CSS 0 违规）通过。
- 生产 Web 部署：本机 `ssh ubuntu@123.207.180.163` 返回 `Permission denied (publickey)`，无法运行既有部署管线（`artifacts/deploy/*`），
  已把候选与步骤交给主会话由其管线发布。
- 已知未覆盖：未确认剪贴板建议卡 + 已确认待发送项的 950×650 截图（fixture 未补）。
