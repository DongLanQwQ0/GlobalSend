# 接收坞悬停与恢复 · 1.0.95+120

## 已实现

- Windows接收坞、Android悬浮坞：外部内容连续悬停1秒进入“发送至设备”；未满1秒就移出会取消进入。
- 移出1秒恢复普通内容；返回会取消恢复，继续保持设备模式。恢复后可再次悬停1秒进入，同一次拖动可反复触发。重复EXITED不延长恢复期限。
- 离开立即停止边缘滚动并取消设备高亮，悬停本身不发送。原目标高亮、边缘滚动、Android触感反馈及实际投递入口保留。
- Android从本坞拖出内容即显示设备的原行为保留。恢复普通内容与结束拖动分开处理，不销毁仍在进行的本地拖动、源View或文件提供方；结束/关闭清理待执行回调。
- 两平台教程同步更新；生成源为`packages/guides/usage.json`，不单独手改生成文件。

## 有效证据

- Flutter：`receive_dock_device_hover_test.dart`及`receive_dock_update_interaction_test.dart`共3项通过。覆盖999/1000ms、提前移出、返回取消、重复移出、反复重入、边缘滚动/目标区域及只发送投放批次。
- Android：`ReceiveOverlayDeviceTargetsTest`全部16项通过，结果保存为`artifacts/tmp/dock-hover120/android-accepted.xml`；新测试覆盖外部内容三次进出、源内容两次恢复/再进入、源与暂存保留。既有晚取URI、提前投放、实际投递/反馈、滚动与显示行为也通过。
- 分析没有error或warning；保留原有5条if括号风格info。教程6份生成结果一致。Windows组件实际渲染已查看，图片`artifacts/tmp/dock-hover120/windows-device-mode.jpg`不是实体桌面合成测试。
- 原生构建成功、APK验签通过，Windows包与APK均无字体文件；实际EXE读回`1.0.95+120`，APK读回`versionName=1.0.95 / versionCode=120`。

### 排查记录

首次Android检查遇到旧Pub缓存C盘路径与F盘项目的Kotlin增量缓存冲突；离线pub get恢复F盘公共缓存，定向Gradle检查使用正确引用的`-Pkotlin.incremental=false`。没有更换依赖版本。

测试的暂停VSync会阻塞窗口遍历后的同步Handler；精确时间边界由暂停时钟的外部拖入测试覆盖，本地源保留测试使用正常VSync检查恢复与再次进入。另一条既有文件引用测试单独运行通过、整类运行出现`Cannot cast ShadowViewGroup to NativeDragView`，统一整类的View/ViewGroup原生拖放shadow后，16项全通过。测试结束主动交付模拟的ENDED，避免悬挂源租约。未通过删除产品保护或跳过失败测试获得通过。

日志位于`artifacts/tmp/dock-hover120/`：`windows-tests.log`、`android-accepted.log`、`analyze-final.log`、`release.log`；初始失败日志保留。

## 本地交付

- 源码：`7da04a7b8e48fa63e5568b350cc79f81df2daad9`。
- Windows完整覆盖`E:\Programs\GlobalSend`并重启，进程28972。本地ZIP `artifacts/releases/GlobalSend-1.0.95-windows-x64.zip`，22,612,382字节。
- APK `artifacts/releases/GlobalSend-1.0.95-android-arm64-v8a.apk`，16,495,287字节。
- 仅检测到共享模拟器，没有实体手机；最后提供的`10.195.25.59:34553`连接超时。未操作模拟器，未推送手机，手机最后确认117。实体手机重新连接后才能覆盖安装120并实机验收。
- 没有进行用户Windows界面/触屏操作或手机操作。中心/Web保留117，IPA仍114；本地交付阶段未发布GitHub，安装包不放中心。

## GitHub 发布

按用户后续“release GitHub”指令，2026-11-03发布[1.0.95（120）](https://github.com/DongLanQwQ0/GlobalSend/releases/tag/v1.0.95-build120)，GitHub实际publishedAt为`2026-11-03T13:42:03Z`。正式非草稿、非预发布，latest端点已确认120。

Windows ZIP 22,612,382字节、Android APK 16,495,287字节及两份更新清单均为`uploaded`。远端两份清单已下载回读：各自platform/asset正确，version=1.0.95、build=120、sourceCommit均为`7da04a7b8e48fa63e5568b350cc79f81df2daad9`，实际标签SHA一致。源码及发布记录已推送main，未提交工作区其它修改。

直连GitHub超时后，单次发布命令复用系统已有的`127.0.0.1:7890`代理，不改系统代理、不读取认证token。证据`artifacts/tmp/github-release120/remote.json`、`latest.json`和`remote-manifests/`。IPA保持114，没有新iOS清单；发布没有操作手机或服务器。
