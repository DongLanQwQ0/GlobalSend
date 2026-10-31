# UI 集成者 → 主 Agent：样式分层候选交付（ui/polish）

状态：Web 视觉候选已完成并通过构建、266 项测试与三个宽度 × 明暗双主题的真实渲染检查。未切分支、未推送、未部署、未改版本号与发布记录。

## 1. 交付内容（全部为实际文件，字节数为实测）

### 样式本体：8 层，112,383 字节（集成后终值）

| 文件 | 字节 | 职责 |
| --- | --- | --- |
| `web/src/style.css` | 556 | 仅 `@import` 清单（8 行） |
| `web/src/styles/00-foundation.css` | 9,988 | token 契约、元素默认样式、按钮/输入原语 |
| `web/src/styles/10-connection.css` | 7,894 | 连接/入组 |
| `web/src/styles/20-workspace.css` | 30,727 | 应用外壳 |
| `web/src/styles/30-surfaces.css` | 15,546 | 模态/文档面/设置/回执 |
| `web/src/styles/40-content.css` | 20,543 | 历史/库/反馈 |
| `web/src/styles/50-cards.css` | 12,976 | 预览卡/浮层/传输条 |
| `web/src/styles/60-details.css` | 12,339 | 紧凑操作行/外观/分组 |
| `web/src/styles/70-integration.css` | 2,370 | 跨层集成（分栏比例、卡片流式列、统一遮罩、页签、控件高度裁决、移动端比例） |

拆分是**逐字节无损**的：各层按序拼接与拆分前单文件完全相等（脚本断言），所以视觉差异只来自设计改动。

### 守卫与证据工具

| 文件 | 字节 | 说明 |
| --- | --- | --- |
| `web/test/style_coverage.test.ts` | 4,481 | 基线覆盖 + 层完整性 + 异常重复 |
| `web/test/style_coverage.baseline.json` | 4,741 | 219 个「markup 在用且被覆盖」的 class |
| `web/tool/preview_ui_polish.mjs` | 11,714 | 真实 main.ts + 真实样式，合成数据，CDP 截图 |
| `web/tool/style_gallery.html` | 56,185 | 开发期画廊（9 区块 / 219 class） |
| `web/tool/style_gallery.ts` | 4,875 | 画廊主题与容器宽度驱动，只 import style/appearance/icons |
| `client/lib/ui_tokens.dart` | 31,236 | Flutter 设计 token 升级（API 零删除零改名） |
| `scripts/agentbus.mjs` | 36,143 | 本机消息总线（HTTP 长轮询 + 文件回退 + 文件租约） |
| `docs/UI_STYLE_LAYERS.md` | 4,587 | 分层维护说明 |

## 2. 构建与测试（真实输出）

```
npm --prefix web run build   → tsc --noEmit 通过；index-DjDDmRCH.css 101,743 B（gzip 15.79 kB）
                              index-D36hs-gJ.js 291.19 kB（gzip 87.04 kB）
npm --prefix web test        → 266 tests / 266 pass / 0 fail（含新增 3 项样式守卫）
node scripts/agentbus.mjs doctor → 8 项 PASS
flutter analyze (client)     → 403 → 402，新增 0（error 48 / warning 2 与基线一致）
```

CSS 体积从 56.5 kB 增至 101.3 kB（gzip 11.2 → 15.7 kB），增量几乎全部是四态（hover/active/focus-visible/disabled）、
暗色派生量与设置/回执分区规则；没有引入字体、图标库或图片。

## 3. 渲染证据（真实 app 页面，不是画廊）

`web/tool/preview_ui_polish.mjs` 用 esbuild 打包**真实 `web/src/main.ts`** 与**真实 8 层样式**，只注入合成的
设备/传输/主题状态，然后用固定 Edge profile 在 1440×900、1024×768、390×844 三档下截图，逐张断言
`documentElement.scrollWidth <= innerWidth`（无横向溢出）。

| 组 | 张数 | 路径 |
| --- | --- | --- |
| 改版后 | 12（501,425 B） | `artifacts/screenshots/ui-polish-*.jpg` |
| 改版前对照（`UI_POLISH_BASELINE=1`，用 8f9ca8c 的原单文件 CSS） | 12（491,867 B） | `artifacts/screenshots/ui-baseline-*.jpg` |
| 结构化探针 | 1 | `artifacts/reports/ui-polish-visual.json` |

覆盖状态：连接页（亮/暗/手机）、接收面板（1440 亮/暗、1024、390 亮/暗）、已发送、文件库、设置弹窗（亮/暗）。
画廊 `web/tool/style_gallery.html` 是**补充材料**，用于逐块查看组件，不作为 app 页面证据。

## 3.1 集成裁决（两个跨层冲突）

8 个层各自完成后仍有 2 处需要统一口径，我在 `70-integration.css` 里一次性裁掉，没有回头改作者的文件：

1. **紧凑控件高度**：`60-details` 把 `.content-toolbar>button` 压到 32px，`20-workspace` 声明 36px，同特异性后置覆盖。
   裁决：密集元数据行才用 32，**所有工具行按钮统一 36**（`--control-sm`）。
2. **设备瓷片状态条压字**：`.target-status` 绝对定位在底部，两行设备名末行会被盖 4–6px。
   裁决：瓷片底部预留状态带高度，设备名收敛为单行 + 省略号。

## 4. 与你的边界（已遵守）

- 未改 `main.ts` / `workspace_view.ts` / 任何 Dart、Java、测试或发布脚本；未动版本号、`docs/PROGRESS.md`、`docs/UI_ACCEPTANCE.md`；
- 剪贴板建议卡 `.clipboard-suggestion.staged-item`、`.staged-suggestion-confirm`（含 strong/small/svg 与内层 `.icon-button`）保留在 `00-foundation.css`，交互语义未变；
- 浏览器串行复用 `artifacts/browser-profile/edge`，通过 `web/tool/browser_profile.mjs` 租用，未新建 profile、未删锁、未强退。

## 5. 未完成 / 需要你或用户拍板

1. **`abd9338` 缺 `web/src/styles/`**：单独检出该提交时 8 条 `@import` 全部 404。集成时请把整个 `styles/` 一起入库。
2. 我这边**没有提交**（按约定不做 git 写操作）。`git status` 会看到 `web/src/styles/`、`scripts/agentbus.mjs`、
   `web/test/style_coverage.*`、`docs/Communication/*`、`docs/UI_STYLE_LAYERS.md`、`package.json`、`.gitignore` 的改动。
3. Flutter 侧只做 token 层；`flutter test` 在本机宿主上带截图用例会非确定性崩溃（与本次改动无关，纯 Dart 调色板用例连过两次），
   所以 App 端观感需要真机/模拟器确认，我没有把它标成已验收。
4. 真机上值得看两处：暗色 Modal/AppBar 阴影层次；412dp 窄屏下设置页标签与 popupMenu 是否挤压。

## 6. 复现

```
cd web && node --experimental-strip-types --test test/style_coverage.test.ts
node web/tool/preview_ui_polish.mjs
$env:UI_POLISH_BASELINE='1'; node web/tool/preview_ui_polish.mjs
```
