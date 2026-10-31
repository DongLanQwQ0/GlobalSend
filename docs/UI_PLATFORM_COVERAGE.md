# UI 跨平台覆盖矩阵

一套视觉语言，三处实现，值必须对得上。改任何一处颜色，先查这张表。

## 1. 单一设计语言的三个实现点

| 平台 | 实现 | 位置 |
| --- | --- | --- |
| Web（浏览器 / PWA / Edge） | CSS 变量 + 8 层样式 | `web/src/styles/*.css`，palette 由 `web/src/appearance.ts` 运行时注入 |
| Windows / Android / iPad | Dart `UiPalette` + `Ui.*` 阶梯 | `client/lib/ui_tokens.dart` |
| Android 原生接收悬浮窗 | Java `ReceiveAppearance` | `client/android/.../ReceiveAppearance.java` |

## 2. 颜色对齐表（亮 / 暗）

| 语义 | 亮色 | 暗色 | 说明 |
| --- | --- | --- | --- |
| canvas | `#f5f5f6` | `#141516` | 页面底 |
| surface | `#ffffff` | `#202124` | 内容面 |
| field | accent 3% 叠在 surface | accent 5.5% 叠在 surface | 输入框/弱底 |
| ink | `#25272b` | `#e9eaed` | 主文字 |
| muted | `#62666d` | `#abb0b8` | 次要文字 |
| line | `#dedfe3` | `#3c4046` | 唯一那根 1px 分隔线 |
| accent（绿） | `#176b50` | `#81d6b4` | 可操作项/选中态 |
| accent-soft | accent 8% 叠在 surface | accent 13% 叠在 surface | 弱强调底 |
| on-accent | `#ffffff` | `#16191d` | 主色上的文字 |
| danger | `#a94237` | `#ffb4a7` | 失败/危险 |
| warning | `#85662b` | `#eac17c` | 等待/警告 |

中性模式（neutral）只换中性轴：canvas `#e9eaec`、surface `#f7f7f8`、field `#efeff1`、line `#d5d7dc`，强调色不变。

> 2026-10-31 之前 Flutter 的 danger/warning 与 Web 各有一套近似值（`#a8372f/#8a5a00` 对 `#a94237/#85662b`），
> 已收敛到本表；两套值当时都满足 4.5:1，收敛后仍然满足。

## 3. 表面 × 平台

| 表面 | Web | Windows | Android | iPad |
| --- | --- | --- | --- | --- |
| 连接/入组 | `10-connection.css` | `connection_window.dart` | 同左 | 同左 |
| 工作台（发送/接收/页签） | `20-workspace.css` | `screen.dart` | `screen.dart` | `screen.dart` |
| 暂存坞/悬浮窗 | `50-cards.css` + `dock.ts` | `receive_dock_window.dart` | `ReceiveOverlay.java`（原生）+ `android_receive_window_frame.dart` | — |
| 模态/设置/回执 | `30-surfaces.css` | `screen.dart`（设置）/ `receipt_preview.dart` | 同左 | 同左 |
| 历史/文件库 | `40-content.css` | `saved_files_screen.dart` | 同左 | 同左 |
| 预览卡 | `50-cards.css` | `compact_content_card.dart` | 同左 | 同左 |
| 紧凑操作行/外观/分组 | `60-details.css` | `screen.dart` / `local_ip_menu.dart` | 同左 | 同左 |
| 跨层比例与节奏 | `70-integration.css` | `screen.dart` 分栏常量 | 同左 | 同左 |

## 4. 验证边界（诚实版）

| 平台 | 已验证 | 未验证 |
| --- | --- | --- |
| Web | `tsc + vite build`；266 项测试；1440/1024/390 × 明暗共 12 张真实页面截图（逐张断言无横向溢出） | 真机触屏手势、IME 行为 |
| Windows / Android / iPad（Dart） | `flutter analyze` 与基线对比无新增；`flutter build windows` 产出可执行 | 真机/模拟器截图：本机 `flutter test` 的 `toImage` 用例会非确定性崩溃（环境问题，纯 Dart 用例可过），设备验收归发布负责人 |
| Android 原生悬浮窗 | 颜色与 `UiPalette` 同源同值（逐值比对） | 实机观感 |

## 5. 改色的正确顺序

1. 先改本表；
2. 同步 `web/src/appearance.ts`（palette 注入）；
3. 同步 `client/lib/ui_tokens.dart`（`_danger*/_warning*` 与 `UiPalette.from`）；
4. 同步 `client/android/.../ReceiveAppearance.java`（原生悬浮窗）；
5. 跑 Web 守卫测试 + Flutter analyze；
6. Web 用 `preview_ui_polish.mjs` 出图，Dart 侧等发布窗口做实机确认。
