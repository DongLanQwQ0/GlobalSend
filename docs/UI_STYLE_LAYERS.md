# Web 样式分层与视觉维护

`web/src/style.css` 只剩一份 `@import` 清单，真正的样式在 `web/src/styles/` 的 8 个层里。
拆分是逐字节无损的：把各层按顺序拼回去，与拆分前的单文件完全相等，所以任何视觉差异都来自设计改动本身。

## 为什么要拆

1. **并行不改同一个文件**：一次改版里 8 个作者同时动一个 58KB 的 CSS，必然互相覆盖。一层一个文件，所有权清晰。
2. **级联顺序可读**：文件名带序号，后层按需覆盖前层，不再靠 `!important` 抢优先级。
3. **回归可定位**：某页面样式坏了，先看对应层。

## 层清单（顺序即级联顺序）

| 文件 | 职责 |
| --- | --- |
| `00-foundation.css` | **契约层**：token、元素默认样式、按钮/输入原语、共用工具类、剪贴板建议卡、地址选择器 |
| `10-connection.css` | 中心连接、入组表单、字段、错误与连接横幅 |
| `20-workspace.css` | 应用外壳：顶栏、页签、左右分栏、发送/接收面板、工具行 |
| `30-surfaces.css` | 模态外壳、文档型文本面、设置卡、回执卡片网格 |
| `40-content.css` | 历史、库、反馈（toast/空态/错误）、遗留入口 |
| `50-cards.css` | 预览优先卡片、浮层操作、传输条 |
| `60-details.css` | 紧凑操作行、外观设置、多组控件 |
| `70-integration.css` | 跨层集成决策：分栏比例、卡片流式列、统一遮罩、移动端卡片比例 |

`00-foundation.css` 与 `70-integration.css` 由集成者独占，其余层按表面归属。

## Token 契约

```
间距  --space-0:4 --space-1:8 --space-2:12 --space-3:16 --space-4:24 --space-5:32 --space-6:40 --space-7:48 --space-8:64
圆角  --radius-xs:6 --radius-sm:8 --radius-control:10 --radius-field:10 --radius-card:14 --radius-panel:18 --radius-pill
字号  --text-2xs:.75 --text-xs:.8125 --text-sm:.875 --text-base:1 --text-lg:1.125 --text-xl:1.375 --text-2xl:1.75
行高  --leading-tight:1.25 --leading-normal:1.55 --leading-relaxed:1.7
控件  --control-compact:32 --control-sm:36 --control-md:44 --control-lg:48 --icon-sm --icon-md
阴影  --shadow-0 --shadow-1 --shadow-2 --shadow-3 --shadow-inset
遮罩  --scrim（模态统一遮罩，暗色自动加深）
焦点  --ring --ring-strong
动效  --ease --duration-fast:110ms --duration:170ms --duration-slow:260ms
层叠  --layer-header:10 --layer-dock:20 --layer-overlay:100 --layer-toast:200
```

### 调色板是运行时的，不要在 CSS 里改

`appearance.ts` 在启动和切换主题时把下面这些变量**内联**写到 `document.documentElement`：
`--canvas --surface --field --soft --line --green --text --muted --red --on-accent --warning`。

内联样式优先级高于样式表，所以：

- 新颜色一律 `var(...)` 或 `color-mix(in srgb, var(--green) 8%, var(--surface))`；
- 暗色只用 `[data-theme=dark]` 调整派生量（阴影、遮罩、叠加层），不要重定义上面那组；
- 不要写死 `rgba(255,255,255,…)`：暗色下会发白。

## 守卫测试

```
cd web
node --experimental-strip-types --test test/style_coverage.test.ts
```

它做三件事：

1. **基线覆盖**：`test/style_coverage.baseline.json` 记录了「markup 在用且被样式覆盖」的 class；任何一条规则被删光都会失败。
2. **层完整性**：8 个层文件都在，且都被 `style.css` 导入。
3. **异常重复**：同名 class 出现次数超常（多半是复制粘贴事故）会失败。

故意退役规则时用 `STYLE_BASELINE=write` 重新生成基线，并在提交说明里写清为什么可以删。

## 视觉证据

```
node web/tool/preview_ui_polish.mjs                  # 真实 main.ts + 真实样式，合成数据
$env:UI_POLISH_BASELINE='1'; node web/tool/preview_ui_polish.mjs   # 改版前对照
```

- 输出：`artifacts/screenshots/ui-polish-*.jpg` 与 `artifacts/reports/ui-polish-visual.json`；
- 复用固定 Edge profile（`artifacts/browser-profile/edge`），串行占用，不新建身份；
- 断言：任何分辨率下都不得出现横向溢出；
- 另有 `web/tool/style_gallery.html`（vite dev 打开 `/tool/style_gallery.html`）逐块展示全部表面，可切主题与容器宽度。

## 加一个新表面

1. 在 `web/src/styles/` 新建 `NN-<surface>.css`（编号决定顺序）；
2. 在 `web/src/style.css` 里按顺序加一行 `@import`；
3. 只用 Token 契约里的量，不新造颜色；
4. 跑守卫测试；
5. 用 `preview_ui_polish.mjs` 或在画廊里加一段，确认亮/暗、桌面/手机都不溢出。
