# UI 一致性准则与审计

准则来源：`docs/Communication/UI-DESIGN-BRIEF.md`。文档没写到的部分，按「统一、一致、不能有残缺动画、必须衔接、不准闪切」执行。

## 1. 自动审计

```
node web/tool/ui_audit.mjs        # 输出 artifacts/reports/ui-consistency.json
```

它扫两处：

| 范围 | 规则 |
| --- | --- |
| `web/src/styles/*.css` | 硬编码颜色 / 非法时长（只允许 110·170·260ms）/ 布局属性过渡 / 多余的 `!important` / hover 位移缺少过渡 |
| `client/lib/*.dart` | 裸 `Duration(milliseconds: N)` 与 `Curves.*`（应走 `Ui.duration*` / `Ui.ease`） |

当前结果：**CSS 0 条**；Dart 剩 2 条已知例外（`group_shared_text.dart` 400ms 去抖、`rtc_probe.dart` 350ms 探测退避，都不是视觉过渡），审计退出码 0。

## 2. 这轮发现并修掉的问题

| 问题 | 影响 | 处理 |
| --- | --- | --- |
| 90 条 `:hover/:active` 规则只改颜色，元素没有过渡 | 悬停、按下、选中都是瞬间跳变（闪切） | `00-foundation.css` 增加全局颜色过渡：`background-color / border-color / color / box-shadow / fill / stroke`，110ms + `--ease`；元素自定义过渡仍然优先 |
| 切换主题时整屏颜色瞬变 | 亮↔暗像断电 | 同上，主题变量变化被同一组过渡吃掉 |
| 遮罩关键帧写死 `#191b1f00/#191b1f66` | 与 `--scrim` 两套值，暗色下遮罩不一致 | 改为 `transparent → var(--scrim)`，全站一个遮罩源 |
| 11 处 `:active` 位移没有 transform 过渡 | 审计误报 | 判定为「按压反馈应当即时」，审计规则收敛为只看 `:hover` |
| Dart 侧 18 处裸时长、3 处裸曲线 | 两端动效节奏不一致 | 收敛到 `Ui.durationFast/Normal/Slow` 与 `Ui.ease` |

## 3. 动效契约（两端同一套）

| 语义 | Web | Flutter | 用途 |
| --- | --- | --- | --- |
| fast | `110ms` | `Ui.durationFast` | 悬停/按下/选中/焦点这类即时反馈 |
| normal | `170ms` | `Ui.durationNormal` | 弹层、页签、主题切换 |
| slow | `260ms` | `Ui.durationSlow` | 大面板、坞展开 |
| 缓动 | `var(--ease)` | `Ui.ease` | 两端同为 `cubic-bezier(.2,.7,.2,1)` |

规则：只对 `color / background-color / border-color / box-shadow / transform / opacity` 做过渡；
`width / height / margin / padding / grid-template` 一律不插值；`prefers-reduced-motion` 或 Flutter `disableAnimations` 下全部退化为瞬时。

## 4. 已知的「还差一段」——需要渲染层配合（尚未做）

1. **页签切换的内容区没有淡入**：`main.ts` 的 `render()` 会整体重绘工作区并还原焦点/滚动，
   纯 CSS 的入场动画会在每次重绘时重放（进度刷新也会闪），所以没敢加。
   正确做法：在渲染时给内容容器一个一次性 class（或 `data-view` 变化时触发 170ms 淡入），这需要改 `main.ts`，属主会话的 TS 所有权。
2. **toast 只有进场没有退场**：节点在 3500ms 后被 `remove()`，没有离场过渡。
   正确做法：移除前加 `.leaving` 类并等 `transitionend`（同样需要 JS）。
3. 详情托盘、文件预览等模态已有 `settings-enter/exit` 与 `backdrop-enter/exit`，无需补。

## 4.1 Flutter 侧本轮补齐的 5 处瞬变

| 位置 | 原状 | 现在 |
| --- | --- | --- |
| `compact_content_card.dart` 选中边框 | Material shape 直切 | `TweenAnimationBuilder` 插值颜色/线宽，170ms `Ui.ease`（并关掉 Material 自带的 200ms 隐式 shape，避免两条时间线打架） |
| `screen.dart` 连接徽标 | accent ↔ warning 瞬间换色 | `ColorTween` 170ms |
| `reachability_screen.dart` 地址三态 | 瞬间换色 | `ColorTween` 170ms |
| `screen.dart` 进度条 | `if (working)` 挂载/卸载，2px 跳动 | 恒定 2px 占位 + 透明度 110ms，未工作时才不挂载 |
| `ui_tokens.dart` / `app_icon.dart` 勾选 | 图标瞬现 | `AnimatedScale` + `AnimatedOpacity` 110ms |

| `ui_tokens.dart` 外观分段控件 | 「跟随系统」在窄屏/宽字体下换行成两行 | 每段标题改成 `FittedBox(scaleDown)` + `maxLines: 1`，并按 `Ui.space2` 收紧段内边距；Web 端 `.appearance-modes button` 本来就是 `white-space: nowrap`，两端现在都不会换行 |

全仓 `Curves.*` 已为 0；`client/lib` 内不再有 401ms 以下的过渡字面量（剩余时长都是网络超时、退避、去抖、纯计时）。

## 5. 行为一致性清单（两端对齐后的约定）

| 行为 | Web | Flutter |
| --- | --- | --- |
| 悬停 | 提亮/加深 + 一级影，`transform` 抬 3-7px | 桌面端同源（`hovered` / `elevationRaised`） |
| 按下 | 去影 + 0.5–1px 下沉，即时生效 | `pressed` 叠层 |
| 焦点 | `outline: 2px var(--green)`，滚动容器内改内嵌 | `focusRing` + `Ui.ease` |
| 禁用 | 45% 不透明度 + 禁点光标 | `disabledInk/Fill/Line`（统一 45%） |
| 选中 | `accentSoft` 底 + `accent` 边 | `selected` / `selectedLine` |
| 主题切换 | 颜色属性 110ms 过渡 | `themeAnimationDuration = Ui.durationNormal` + `UiPalette.lerp` |
