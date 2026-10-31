# 发布记录：UI 改版（main@1fd3013 / Native 1.0.63+80 / Web ui-1.0.63）

## 1. 合并

- `ui/polish` → `main` 快进合并；HEAD `1fd3013`，工作区干净。

## 2. 原生正式版 1.0.63+80

| 项 | 值 |
| --- | --- |
| Windows | `E:\Programs\GlobalSend` 已替换并重启，`FileVersion 1.0.63+80`，pid 41400 |
| Android | `versionCode=80 / versionName=1.0.63`，12:29:20 安装成功，数据保留 |
| 发布包 | `GlobalSend-1.0.63-windows-x64.zip` 22,412,291 B；`GlobalSend-1.0.63-android-arm64-v8a.apk` 16,338,804 B |
| 源码提交 | `99c3357`（由主会话构建发布，已包含全部 Flutter UI 改动） |

## 3. Web 生产发布（本次完成）

| 项 | 值 |
| --- | --- |
| 镜像 | `globalsend:ui-1.0.63-20261031`（healthy） |
| 发布目录 | `/home/ubuntu/GlobalSend/releases/20261031-ui-163` |
| 回滚基线 | `globalsend:clipboard-1.0.59-20261031`（脚本内含 rollback + 90s 健康等待） |
| 源码 | `git archive HEAD` (1fd3013) 的 compose/Dockerfile/deploy/packages/server/web，2,007,040 B |
| 产物 | `index-FWUHkeDf.css` 102,025 B、`index-npBvZjKv.js` 291,189 B |
| 公网校验 | `/globalsend/health/ready` 200；`/globalsend/app/` 引用 `assets/index-FWUHkeDf.css`；实际下载 102,025 B，含 `--scrim`、`--control-sm`、`content-tabs{justify-content`、`repeat(2,minmax(0,1fr))` |
| 视觉证据 | `artifacts/screenshots/web-prod-ui-1.0.63.png`（1440×900，标题「加入分组」，无横向溢出） |

## 4. 评审提出的两条证据

- 两列网格：`70-integration.css` 用 `repeat(2,minmax(0,1fr))`，手机 390 与桌面 1440 均为两列（`ui-polish-receive-mobile.jpg`、`ui-polish-receive-light.jpg`）。
- 950×650 剪贴板候选：`ui-polish-clipboard-950.jpg`（未确认建议卡 + 已确认待发送项，计数为 2，建议卡不计入）与 `ui-polish-clipboard-390.jpg`。

## 5. 未覆盖

- 设备侧验收（手机/模拟器手势、IME）不在本次范围；原生 81 由主会话继续。
