# 接收目录布局

普通文件直接写入接收目录，不再建立设备、传输或文件编号目录，也不先下载到另一处再复制。

```text
GlobalSend/
  照片.jpg
  照片 (1).jpg
  笔记.txt
  课程资料/             ← 用户实际发送的文件夹
    讲义.pdf
    图片/示意图.png
    空目录/
```

## 平台与断点

- Windows、Android、iOS 共用原生接收入口。默认目录为应用原有接收根目录中的 `GlobalSend`；已选择的接收目录保持不变。Android 已授权目录继续使用原来的 URI/描述符，不增加永久副本。
- 新接收任务直接占用最终文件名。同名文件使用 `名称 (n).扩展名`，不覆盖原件。尚未完成时，断点记录的 `partialPath` 就是这个最终位置；完成后只更新状态和系统索引。
- Web 自选目录同样直接写入。默认浏览器存储使用统一的 `globalsend-received-v1/received` 数据目录；各会话目录仅保存索引，不再保存编号 `.data` 文件。索引 `layout: 2` 表示新布局。
- 真实文件夹保留根目录、相对路径和空目录；历史与收件仍聚合为根文件夹卡片。目录成员不打散为普通文件。

## 旧版本升级

启动时迁移本应用已登记的旧编号层级。保留记录 ID、接收时间、摘要、重名原件和目录结构，并记录旧路径到新位置的持久映射。历史、已发送引用、待发送引用、断点和文件复用均使用新位置。

原生迁移先登记本次创建的目标，再复制已有字节；索引提交后才删除旧原件。中途退出时，只回滚已登记的未提交目标，然后从保留的原件继续。正在使用的迁移副本不会被清理。Web 使用相同的复制/提交日志，并跳过仍由其他接收器持有的旧文件句柄。

只沿已确认的旧应用路径删除空编号父目录。用户文件、未知目录、用户空目录以及真实发送的空目录不做递归清理。不可读或被占用的旧位置保留记录，供恢复权限或解除占用后继续处理。

Android 的迁移结果仍经过现有 `publish` 入口：先登记收件来源，再更新系统文件索引，不重复成为媒体建议。

新建或续写最终接收文件时，原生端先 `rememberOrigin` 登记来源，再向接收器交出可写位置；此时不扫描未完成文件，完成后仍正常 `publish`。因此长传输的最终图片文件不会被另一条系统索引回调误认为外部新图片。

Android 独立暂存坞另有原生持久路径映射。Dart 索引提交后，先等待原生映射落盘与引用更新，再移除旧文件。原生暂存加载在检查文件是否存在前解析此映射，并可读取旧版本已提交的 `saved-files.json` 映射；IO 加载与界面合并之间也会重新解析，避免不同启动顺序丢失暂存条目。真正删除的外部原件仍按原来的缺失文件规则清除。

## 本轮验证

- `client/test/receive_flat_layout_test.dart`：6 项，覆盖最终位置、重名、断点重启、旧文件迁移、引用/复用、空壳边界与中断回滚。
- `client/test/receive_migration_test.dart` 与 `saved_files_destination_test.dart`：13 项，覆盖目录迁移、真实树、SAF 租约、引用提交和旧提供程序不可读。
- `client/test/saved_files_test.dart`：7 项；目录复用与快速选路相关回归 25 项通过。原生真实中心的目录中继、HTTPS 直连及单文件复用检查亦通过。
- Web 库与新布局检查 9 项通过；真实中心的 70 文件树、Range 重启、引用转发及直接写入自选目录等 4 项通过。TypeScript 检查通过。
- 已更新旧的目录物理路径验收断言。浏览器、实机及 Windows 界面未在此任务中操作；iOS 使用共享 Dart 存储实现，未在本机运行 iOS 系统。

Android 原生暂存引用补充检查：`ReceivedPathRelocationsTest` 7 项通过，覆盖先加载/后加载、IO 与 main 合并之间迁移、旧版本已提交的 Dart 映射、进程重启、真正删除与写前来源登记。实际 MethodChannel 检查确认成功回执之前，原生映射已落盘且暂存引用已更新，此后才模拟 Dart 删除旧文件。既有 `TemporaryShelfTest`、`ReceiveDirectoryTest`、`ReceivedFilePublicationTest` 29 项通过。Dart 新桥顺序与接收/迁移回归也通过，分析无错误或警告。

对应日志：`artifacts/logs/native-reference-relocations-tests.log`、`artifacts/logs/native-reference-channel-tests.log`、`artifacts/logs/receive-native-reference-final.log`。

实际 Web 树证据：`artifacts/tmp/web-folder-center-tXvNfl`、`artifacts/tmp/web-folder-external-U5MrEc`。原生迁移日志：`artifacts/logs/receive-flat-migration-tests.log`；分析日志：`artifacts/logs/receive-flat-analyze.log`（无错误或警告，现有风格提示保留）。
