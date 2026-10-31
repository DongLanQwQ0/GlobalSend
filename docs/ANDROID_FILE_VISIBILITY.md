# Android 接收文件在文件选择器中可见

接收完成后，对共享存储中的最终文件触发系统扫描，更新文件大小、类型及下载目录索引。普通文件与图片、视频使用同一收尾入口；不复制、不移动原件，也不新增权限。扫描异步执行，不阻塞收件提示和传输确认。

## 已定位的缺口

本地目录接收先写 `.part`，校验后改为正式文件名；此前没有显式更新最终文件的系统记录。在复用的 Android 36 模拟器中，TXT、PDF、JPEG、PNG 的实际字节已完整，系统索引仍记录为零字节；扫描最终路径后，大小与类型正确。下载提供方的子目录可以通过 MediaStore 获取内容，不能把它等同于 MT 直接列举磁盘文件。

完成文件及重复投递复用文件都从接收登记入口发布；更换接收目录迁移成功后也发布新路径。不会扫描正在下载的 `.part`、整棵用户目录或应用私有数据。SAF 本地存储文档解析为对应原件路径；云端等其它文档提供方继续负责自己的文件可见性。

## 验证

- 原生发布/目录检查：20 项通过；接收目录与迁移相关 Dart 检查：6 项通过。
- 实际 Android 系统验证：四种文件的 Files/Downloads 记录、正式名称、类型和大小正确，原始字节未改变；系统文件选择器显示四个文件，选中 TXT 后可读取相同正文。
- 真实本地中心 → 隔离 Android 客户端：生产接收控制器收到 71 字节 TXT，保存在指定 Download 子目录，中心和客户端均确认完成；只读检查器不调用扫描或移动，系统文件选择器直接显示该文件并可选中读取。
- 上述系统验证使用既有 `Chrona_Classroom_36`，没有创建或复制模拟器。实体手机已保留数据覆盖安装并读回1.0.60/code77，厂商文件选择器仍待实际接收确认。

证据保存在 `artifacts/tmp/publication77/`。生产入口为 `ReceivedFilePublication.java`、`ReceiveDirectory.java` 和 `ReceiveDestination.publish`；复现实验使用 `scripts/build-android-publication-check.mjs`。

依据：[系统扫描接口](https://developer.android.com/reference/android/media/MediaScannerConnection)、[Android 下载文档提供方](https://android.googlesource.com/platform/packages/providers/DownloadProvider/+/refs/heads/main/src/com/android/providers/downloads/DownloadStorageProvider.java)。
