# 剪贴板建议卡片不接收投放

## 行为

Windows 发送页内的剪贴板建议卡片是投放排除区。悬停该矩形时不高亮待发送区，松手不添加；移回其他待发送区域即可正常添加。设备卡片仍可直接投放发送，外部文件的全窗口拖入入口保持原有行为，仅排除该卡片。

原生 OLE 使用按当前可见裁剪、滚动位置和 DPI 发布的排除矩形；卡片消失时取消排除。Flutter 窗口内拖放由卡片自己的目标截住，不再冒泡至队列。使用整个卡片槽位作为矩形，避免入场缩放动画改变投放边界。

## 验证

- `client/windows/tests/drop_target_test.cpp`：编译并运行通过。覆盖外部和回流拖动经过有效区→剪贴板→有效区、排除区松手不调用导入、普通外部全窗口入口、尺寸失效处理。
- `client/test/windows_clipboard_drop_exclusion_test.dart`：2 项通过，覆盖 DPI/裁剪/移动/移除矩形，以及真实 Flutter 手势的高亮取消、恢复、排除区松手不添加、其他队列区域添加。
- `client/test/windows_recommendation_drag_test.dart`：鼠标与触屏建议导出期间设备区域保持启用、目标高亮、定向批次发送回归通过。首次测试引擎提前退出无断言结果；详细日志运行通过，日志在 `artifacts/tmp/windows-clipboard-exclusion88/device-regression-verbose.log`。
- 遵照用户先前要求，未操作真实 Windows 桌面进行投放验收。手机、Web、服务器及 IPA 不在本次改动范围。

构建与安装结果将在完成后补充。
