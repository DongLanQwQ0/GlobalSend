# UI 集成者 → 主 Agent：跨平台 UI 覆盖与手机安装（需知会）

## 1. 我在你手机上做了什么

- 用当前 `ui/polish` 工作区构建了 release APK（1.0.62+79，与已装版本同号、同 debug 签名），
  `adb -s 10.195.59.196:42953 install -r` 覆盖安装成功，**应用数据保留**（分组、历史、暂存都在）。
- 构建产物：`client/build/app/outputs/flutter-apk/app-release.apk`（94.4 MB），只在本机，未发布、未推送。
- 只做了启动与截图，没有发送/删除/接收任何内容；系统夜间模式被我临时切过一次，已还原。

如果你要为发布重打分发包，直接从同一工作区重打即可，不需要回滚我的安装。

## 2. Flutter 侧这次改了什么（覆盖 Windows / Android / iPad）

5 个作者，按文件切分、互不越界，全部只做「样式字面量 → token」替换：

| 文件组 | 内容 |
| --- | --- |
| `screen.dart` | 顶栏、页签、分栏、待发坞、设备磁贴、工具栏、移动端与设置页 |
| `receive_dock_window.dart`、`android_receive_window_frame.dart`、`compact_content_card.dart` | 悬浮坞、Android 窗框、紧凑卡片 |
| `saved_files_screen.dart`、`saved_image_preview.dart`、`recent_photos_view.dart` | 文件库、图片预览、最近照片 |
| `receipt_preview.dart`、`text_viewer.dart`、`content_drag_surface.dart` | 回执、阅读器、拖拽浮层 |
| `reachability_screen.dart`、`credential_recovery_screen.dart`、`app_update_ui.dart`、`local_ip_menu.dart`、`url_intent_notice.dart`、`bulk_file_drag.dart`、`main.dart` | 诊断页、凭据恢复、更新提示、IP 菜单、提示条、批量拖拽、外壳主题动画 |

顺带把 Flutter 的 danger/warning 色收敛到与 Web 完全同值（`#a94237/#ffb4a7`、`#85662b/#eac17c`），
Android 原生悬浮窗 `ReceiveAppearance.java` 本来就与 `UiPalette` 同值，无需改。

## 3. 验证

```
flutter analyze --no-pub          → 402 issues（与改动前基线 402 完全一致，新增 0）
flutter build apk --release      → app-release.apk 94.4 MB，安装成功
flutter build windows --release  → 见下文（正在跑）
```

真机截图（Pixel 级 1216×2640，vivo V2527A）：

| 文件 | 内容 |
| --- | --- |
| `artifacts/screenshots/android-ui-polish-main.png` | 工作台（暗色，紫强调） |
| `artifacts/screenshots/android-ui-polish-light.png` | 工作台（亮色） |
| `artifacts/screenshots/android-ui-polish-settings.png` | 设置页（分段控件、色板、卡片分区） |

## 4. 看到但不属于样式层的问题

1. 设备字体是手写体（用户系统字体），导致「跟随系统」四个字在分段控件里换行。正常字体下不换行，属字体宽度问题，不是 token 问题。
2. 顶部 5 个分类芯片在 1216px 宽下刚好铺满，最后一项贴边；再窄就会触发横向滚动。
3. `.dart` 侧没有任何结构/Key/文案改动，`find.text` / `find.byKey` 类用例不受影响；`flutter test` 在本机仍会因 `toImage` 用例崩溃（环境问题，与本轮无关）。
