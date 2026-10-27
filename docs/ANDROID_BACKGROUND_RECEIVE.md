# Android 后台接收

连接后默认开启后台接收，通知栏会保留接收状态。切到其他应用、熄屏或关闭应用页面时，接收引擎与文件任务不依赖页面继续存在。

## 使用

- 设置中的“后台接收”可开关；常驻通知也能“暂停后台”。关闭后台不影响前台正常收发，回到前台会恢复前台连接，不会擅自重新开启后台服务。
- “电池设置”打开本应用的系统后台运行授权。深度休眠中的即时消息需要系统允许应用不受电池优化限制；服务存在本身不等于网络始终可用。
- 消息通知与后台状态通知分开。文本消息、同步、编辑的通知与复制入口由接收通知模块提供。已移除悬浮接收坞及其悬浮窗权限，不影响应用内拖放或后台接收服务。
- 应用被系统回收后，系统允许重启服务时会重新读取本机登录和任务状态，恢复连接与可续传任务。退出分组会停止后台会话。强行停止应用或厂商禁止后台运行时，需要再次打开应用或在系统中解除限制。

## 实现

- `NativeReceiveRuntime` 在 application context 上创建一次 FlutterEngine，注册一次系统、凭据、网络、RTC、SAF、通知和后台通道。Dart 控制器与网络任务由该 engine 继续执行。
- `MainActivity` 只 attach/detach 页面与需要当前 Activity 的操作，`shouldDestroyEngineWithHost()` 为 false。SAF 文件描述符、网络执行器和正在进行的导入不在 Activity 销毁时释放；桥接仅弱引用当前 Activity，后台 I/O 使用 application context。
- `BackgroundReceiveService` 为实际跨设备文本连续性声明 `remoteMessaging`，为经网络与外部设备交互的文件接收声明 `connectedDevice`。不把长期监听伪装成短任务或无限 `dataSync`。服务使用独立低重要性通知和 `START_STICKY`，不建立重复唤醒、闹钟或重启循环。
- 初次开启从可见页面启动，合法的系统服务重启、开机完成或应用替换恢复使用已有用户设置。Android 拒绝后台启动时保留真实状态，返回前台后重试。
- 空闲监听不持有 CPU 唤醒锁；实际文件任务期间使用十分钟限时锁，并仅在任务仍活动时续租。完成、取消或服务停止释放锁。不改变全局 Wi-Fi、蜂窝或电源设置。
- Dart 的 `BackgroundReceive.ready()` 在登录恢复判定后才发送初始会话状态，避免进程恢复时暂时未读出登录就错误停止服务。相同状态不重复写入平台，状态回调不产生发送循环。

## 官方依据

- [前台服务类型](https://developer.android.com/develop/background-work/services/fgs/service-types)：remoteMessaging 对应跨设备文本连续性；connectedDevice 对应需要网络等连接的外部设备交互。
- [从后台启动前台服务的限制](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)：首次启动采用可见页面，恢复遵守平台允许的情形。
- [Flutter 缓存引擎](https://docs.flutter.dev/add-to-app/android/add-flutter-screen)：engine 可跨 Activity 存活，并用于 Service 中的非 UI 网络逻辑。
- [Doze 与应用待机](https://developer.android.com/training/monitoring-device-state/doze-standby)：电池优化会限制网络，系统授权入口与实际接收结果分别记录。

## 验收记录

- `artifacts/logs/background-java-compile.log`：生产生命周期与桥接 Java 17 编译通过。
- `artifacts/logs/received-background-android-tests.log`：联合19项通过，覆盖通知、后台开关持久化、未登录恢复、原生拖放、SAF以及替换 Activity 仍可继续写入原接收描述符。
- `scripts/build-background-android-probe.mjs` 生成独立 `dev.globalsend.backgroundprobe`，使用生产 Java 与生产 Dart 控制器；debug 标志仅用于读取隔离的 synthetic 观测数据，不能分发此测试包。构建日志 `artifacts/logs/background-android-probe-build.log`。
- `client/tool/background_receive_center.mjs` 为隔离本机中心；没有公网部署或用户数据。
- API36完整consumer已实际启动、通过系统通知授权并自动登录；前台服务确实处于 foreground，类型 `0x210`，Dart与服务均报告同一个缓存engine。记录：`artifacts/logs/android-background-runtime-result.json`。
- Home、结束Activity、熄屏传输、Doze对照、通知暂停及系统回收恢复尚未执行：后续组合命令在进程创建前被工具策略拒绝，未拆命令或另路重试。拒绝记录：`artifacts/logs/android-background-refused-command.txt`。前台基线只证明运行接线，不证明这些后台行为；验收入口和既有状态已交根任务处理权限依赖。
