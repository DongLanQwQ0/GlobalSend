# GlobalSend UI 改版协作说明（ui/polish）

本文件是并行改版期间的**唯一契约**。所有参与者的可写范围、token 语义、视觉方向与验收方式都在这里；
与本文冲突的个人偏好一律让位。

## 0. 现状

- 分支 `ui/polish`（从 `main` 切出）；工作区存在用户尚未提交的 WIP，**任何人不得 revert / checkout / stash**。
- 本次只改**视觉样式**：不新增功能、不改交互逻辑、不改 TS 逻辑与 DOM 结构预期。
- `web/src/style.css` 已从单文件拆成按页面表面分层的 7 个文件，仅作为 `@import` 清单存在。
  拆分是**逐字节无损**的：拼接后与拆分前完全一致，所以“视觉回归”只可能来自本次改版本身。

## 1. 分层与所有权

| 层文件（web/src/styles/） | 负责的表面 | 归属 |
| --- | --- | --- |
| `00-foundation.css` | token、元素默认样式、按钮/输入原语、共用工具类 | **集成者独占**（其他 agent 只读） |
| `10-connection.css` | 中心连接、入组表单、字段、错误提示、连接横幅 | ui-connection |
| `20-workspace.css` | 应用外壳：顶栏、页签、分栏、发送/接收面板、工具行 | ui-workspace |
| `30-surfaces.css` | 模态外壳、文档型文本面、设置卡、回执卡片网格 | ui-surfaces |
| `40-content.css` | 历史、库、反馈（toast/空态/错误态）、遗留入口 | ui-content |
| `50-cards.css` | 预览优先卡片（操作浮层 + 元信息） | ui-cards |
| `60-details.css` | 紧凑操作行、外观设置、多组控件 | ui-details |

**一人一层，互不越界。** 需要新的共享 token？不要改 foundation，写在回报里由集成者裁决。

## 2. 硬约束（违反即回退）

1. 只允许写你名下那一个 CSS 文件；其余文件（含 `style.css`、`main.ts`、`index.html`）只读。
2. 不执行 git 写操作（add/commit/branch/stash/checkout/restore）。
3. 不装依赖、不跑 `vite build`、不启动 dev server；只允许跑样式守卫测试（见 §5）。
4. **保留你文件里出现的每一个 class 选择器**：可以改值、合并写法、加状态变体，不能消失。
5. 不新增全局元素选择器（`button{}`、`h2{}` 之类）——元素默认样式归 foundation。
6. 不用 `!important`（foundation 的 `prefers-reduced-motion` 全局块除外，也不属于你）。
7. 不引入外部字体、图标库、图片或任何网络资源。
8. 不写 JS，不假设新增包裹元素，不依赖尚未存在的 class。
9. **palette 变量由 JS 注入**（`appearance.ts` 运行时写在 `:root` 的内联样式上）：
   `--canvas --surface --field --soft --line --green --text --muted --red --on-accent --warning`
   在 CSS 里重定义它们无效且会造成暗色模式错乱，**禁止**。

## 3. Foundation 提供的 token

```
间距  --space-0:4  --space-1:8  --space-2:12  --space-3:16  --space-4:24  --space-5:32  --space-6:40  --space-7:48  --space-8:64
圆角  --radius-xs:6  --radius-sm:8  --radius-control:10  --radius-field:10  --radius-card:14  --radius-panel:18  --radius-pill
字号  --text-2xs:.75 --text-xs:.8125 --text-sm:.875 --text-base:1 --text-lg:1.125 --text-xl:1.375 --text-2xl:1.75
行高  --leading-tight:1.25  --leading-normal:1.55  --leading-relaxed:1.7
字体  --font-sans  --font-mono
阴影  --shadow-0:1px线  --shadow-1:贴地1级  --shadow-2:浮层  --shadow-3:模态  --shadow-inset
焦点  --ring（3px 半透明主色光晕）  --ring-strong
动效  --ease  --duration-fast:110ms  --duration:170ms  --duration-slow:260ms
层叠  --layer-header:10  --layer-dock:20  --layer-overlay:100  --layer-toast:200
```

## 4. 视觉方向（评审会按这 10 条打分）

1. **层级靠“面 + 一条线 + 一级影”**表达：canvas 打底，surface 承载内容，field/soft 表示可输入或弱选中。
   禁止同一元素叠两层描边或两个阴影来凑层级。
2. **4px 节奏**：容器内边距 16/24，行内元素 8/12；同一列表里所有条目间距必须一致。
3. **圆角收敛**：控件 10、卡片 14、面板 18、胶囊 999。同类元素必须同值，不要出现 13/15/17 这种手写值。
4. **字号有梯子**：正文 `--text-base`（中文行高 1.55 以上），辅助信息 `--text-xs`，标题 `--text-xl/2xl`；
   中文标题不要用 400 以下字重，小字号不要用 650 以上字重（会糊）。
5. **主色克制**：`var(--green)` 只用于可操作项、选中态、状态点。大面积底色用 canvas/surface，
   弱强调用 `color-mix(in srgb,var(--green) 8%,var(--surface))`，不要新造 hex。
6. **状态齐备**：`:hover`（提亮/下沉）、`:active`（去阴影）、`:focus-visible`（必须可见）、`:disabled`（45% 不透明度 + 禁点光标）。
7. **暗色不靠硬编码**：只在 `[data-theme=dark]` 下调整派生量（阴影、叠加层），
   颜色一律走 `var()` 或 `color-mix()`；禁写 `rgba(255,255,255,…)` 这类假定亮底的值。
8. **动效只碰** color/background-color/box-shadow/transform/opacity，时长 110–260ms，缓动 `var(--ease)`。
   不要给 layout 属性（width/height/grid-template/margin）加过渡。
9. **密度分级**：桌面行高 44–56，控件不小于 36；移动端（`@media (max-width:640px)`）触控目标不小于 44。
10. **无障碍**：不得移除 `:focus-visible`、`[aria-pressed]`、`[hidden]`、`[disabled]`、`.sr-only` 相关规则；
    正文与背景对比度不低于 4.5:1，大字号不低于 3:1。隐藏滚动条的既有约定保留。

## 5. 验收

在 `web/` 目录执行：

```
node --experimental-strip-types --test test/style_coverage.test.ts
```

必须 3 项全过。第一项是**基线守卫**：任何“markup 用到、但现在没有任何 CSS 规则”的 class 都会让它失败，
这就是并行改版不互相打穿的安全网。基线文件 `web/test/style_coverage.baseline.json` **不得手工编辑**。

## 6. 回报格式

用中文，四行以内说清：

1. 改了哪些块（选择器组 + 一句话意图）；
2. 用到的 token 与新增 token 诉求（如有）；
3. 需要人工看真实页面的风险点（2 条以内）；
4. 守卫测试结果（通过/失败 + 失败项）。
