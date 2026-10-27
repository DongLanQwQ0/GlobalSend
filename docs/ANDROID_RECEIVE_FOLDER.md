# Android 接收位置

默认位置保存在应用本地，无需所有文件访问权限。设置中的现有“清除”动作可恢复默认位置；已收到内容沿用现有迁移规则，旧目录不可读的引用保留以便恢复。

## Download/GlobalSend

1. 在接收设置打开“管理所有文件权限”，由用户在 Android 系统页面允许 GlobalSend。
2. 回到应用，选择 `Download/GlobalSend`，或用文件夹选择器选本机主存储中的其他目录。
3. 接收直接写入选择的目录，不先保留一份应用内副本。文件重名仍按原有规则避让，自动清理仅处理登记的应用接收文件。

应用只打开系统授权页，不自行授予权限。未允许时，默认位置和支持现有读写方式的目录仍可用。该入口适用于 Android 11 及以上；旧系统继续使用原文件夹选择器。

## 本次失败的实际原因

实体 vivo 的 `GlobalSendDestination` 日志记录：`provider=com.android.externalstorage.documents, writable=true, cause=ErrnoException, errno=13`。系统已给出 SAF 文件描述符，但原接收链需要经 `/proc/self/fd` 再次打开，重开时被系统拒绝（EACCES）。此前“请选择本机目录”不能准确解释这个本机目录失败。

新路径在取得所有文件权限后，对系统主存储返回真实路径；已有该提供者的应用接收文件遇到上述描述符重开失败时，也可继续读写同一个真实文件。没有复制到别处，也不把第三方/云盘 URI 猜成磁盘路径。未授权时不走真实路径。

这不是改变 SAF 的授权范围。Android 明确说明，全文件权限允许共享存储的直接路径访问，但 SAF 自身仍有独立限制；部分其他应用私有目录即使有该权限也不可访问。

## 验证边界

Java 定向检查使用受控 DocumentsProvider 与 Android 权限状态，覆盖未授权不可选、授权页不暗中授予、主存储树/文件定位、真实写入与断点、probe清理及原件保留。实体手机还需用户在系统设置授权后，再验 `Download/GlobalSend`；不能把测试影子权限当作手机已授权。

参考：[Android 全文件访问](https://developer.android.com/training/data-storage/manage-all-files)、[SAF 文件与目录](https://developer.android.com/training/data-storage/shared/documents-files)。
