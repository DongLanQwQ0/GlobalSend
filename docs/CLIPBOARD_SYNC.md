# 自动剪贴板同步

110修复设置开关的原生参数错误：开启、更换目标和关闭都会取消上一笔图片写入，现在均按Windows原生契约传入操作参数表，不再触发 `BAD_ARGUMENT: Expected operation map`。严格参数回归先复现同一异常，修复后三项检查通过，包含文件复制推送共存及旧图片取消。证据在 `artifacts/tmp/clipboard-settings110/`，未操作用户的真实系统剪贴板。

Windows在设置中打开“同步剪贴板”，选择一个目标设备。101版起，后续复制的文字和截图都会自动发送到该目标，不加入或清空待发送草稿。文件/文件夹复制仍由独立的“文件复制推送”控制，仅发布指定设备可点击拉取的引用。

若接收端也是Windows，在接收端打开同一选项并选择来源设备。接收完成后，文字或图片同时进入系统剪贴板，可直接Ctrl+V。未开启接收端同步时，仍正常保留收件，不改它的系统剪贴板。Android、iPad和Web按普通图片文件接收，保留预览、复制入口及原有拖放能力，不在移动端后台读取剪贴板。

## 图片沿用普通文件传输

来源监听系统剪贴板版本与格式。PNG、DIB、DIBV5、Bitmap截图在后台读取成应用自有PNG/BMP源文件，绑定该次系统版本；读取前已被替换则放弃旧快照。通过原有SHA校验、去重、暂停/取消、断点与内网→公网→中继选路传输，继续遵守中继32MiB确认设置。中心只增加一个图片剪贴板标记，不增加二进制接口或第二套数据通道。

`POST /transfers`可传可选的`clipboard:true`，仅用于单张图片；普通请求不变。中心将来源设备ID和传输ID写入返回的`transfer.clipboard`，重试、查询和重启后保持一致；设备访问仍限于已有传输双方。能力标记是`info.features.clipboardImages`，旧中心需升级后才能自动同步图片。

Windows接收端通过系统WIC在工作线程生成PNG、DIB、DIBV5格式，再写入剪贴板。来源标记和系统禁止监视/云同步的标记沿用原有规则，避免双向回环。新复制替换待发送内容，较新的远程内容不会被较晚完成的旧图片覆盖；关闭同步或改目标会取消尚未完成的图片写入。正常状态不增加说明，失败才在设置中显示状态。

## 101的检查与边界

- 真实本地中心与生产SendController：截图自动发给唯一目标、局域网PNG逐字节送达、目标剪贴板桥调用一次、重复对账不再写、原草稿保留、未选设备不可见。剪贴板桥以替身模拟，不读取或改变用户的真实Windows剪贴板。
- C++系统桥编译通过；WIC实际BMP/PNG转换检查确认PNG签名、DIB/DIBV5尺寸、颜色与往返一致，未创建窗口或访问OS剪贴板。
- 新剪贴板覆盖旧待发、私人/空内容取消旧计时器、进行中截图过期清理自有快照检查通过；原有文字/文件拖出与指定目标文件推送回归通过。
- 中心检查覆盖来源身份、目标隔离、请求重试、重启后元数据、普通文件兼容与非图片标记错误；中心构建通过。

证据位于`artifacts/tmp/clipboard-image101-*`及`artifacts/tmp/clipboard-image101/`。首次真实链路发现原有带后缀文件使用octet-stream，已仅在图片同步入口按内容识别MIME；普通发送原契约保留。测试宿主HTTP替身和参数误匹配的初次失败记录保留，最终真实HTTP链路通过。不把桥替身检查当作Windows实际粘贴验收。

## 交付 1.0.77+101

源码`7ff4185`。完整Windows与Android release构建通过，APK验签通过，两端无打包字体。Windows完整目录已覆盖并重启，实际产品版本`1.0.77+101`，PID8372；APK16,384,060 B，Windows ZIP22,452,848 B。在当前手机持有者明确让出后，流式`adb install -r`返回Success，读回`versionCode=101`、`versionName=1.0.77`、`lastUpdateTime=2026-11-01 22:06:47`，启动一次并立即交还，保留数据，没有触控其它应用或创建手机测试文件。

中心镜像`globalsend:clipboard-image-1.0.77-20261101`已上线且healthy，实例ID保持不变，实际公开info已报告`clipboardImages:true`；网页JS/CSS返回200并保持既有UI，截图按原有图片接收流程处理。安装包路由410，无安装包上传。实际部署见`artifacts/deploy/current-workspace-deployment.json`，公开证据`artifacts/tmp/clipboard-image101-deploy/public.json`。

构建日志`artifacts/logs/release-clipboard-image101-resumed.log`及`release-local-1.0.77-{windows,android}.log`；手机日志`artifacts/tmp/clipboard-image101/phone-*101.*`；原生安装状态`artifacts/releases/latest-local.json`。Windows实际系统剪贴板由用户手动验收。最后从同源码tag运行IPA工作流[41314577696](https://github.com/DongLanQwQ0/GlobalSend/actions/runs/41314577696)成功，iOS专属清单与IPA已发布。实际包`artifacts/releases/ios-1.0.77-build101/GlobalSend-iPad-unsigned.ipa`，14,848,620 B；主应用与扩展版本101、arm64、共享组模板匹配、零字体，核对记录`artifacts/tmp/clipboard-image101/ios101-verified.json`。用户手动签名安装，不操作iPad。
