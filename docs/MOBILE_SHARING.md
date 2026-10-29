# 手机与 iPad 系统分享

## 使用

- 在照片、视频、文件或浏览器的系统分享菜单中选择 **GlobalSend**。打开应用后，内容会进入待发送区。
- 接收/已发送/文件库的“分享”调用系统分享面板，原文件不转换、不移动。
- “全部拖拽”可一次带出多个文件和文本。Android 使用系统 ClipData；iPad 使用多个 NSItemProvider。目标应用能接收哪些类型，由目标应用决定。
- iPad 52版在保存分享内容后，使用与LocalSend相同的响应链URL唤起方式打开GlobalSend，自动显示待发送。系统拒绝唤起时，保留原来的手动打开入口和已保存的批次。

## iPad 手动签名

Apple 的[能力支持表](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)目前在免费的 Apple Developer 列中也列明支持 App groups（2026-10-29 核对了原表图标）。所以不以购买会员作为前提；免费 Apple ID 的手动签名仍需为主应用、扩展签入匹配的 App Group，开发者模式不能替代该配置。

构建产物包含：

```text
Payload/Runner.app/
  GlobalSend.entitlements
  PlugIns/ShareExtension.appex/
    GlobalSend.entitlements
```

这两份文件是已展开组 ID 的签名模板，不是已经取得授权的签名。手动签名时：

1. 保留并签名 `ShareExtension.appex`，不要在侧载工具里移除扩展。
2. 为主应用和分享扩展配置相同的 App Group，并确认两个 provisioning profile 都授权该组；签名器不能仅保留主应用权限。
3. 更新时保持同一主应用 Bundle ID、扩展 Bundle ID 和组 ID，避免被 iPad 当成另一款应用。

项目默认配置在 `client/ios/ShareConfig.xcconfig`：

```text
GLOBALSEND_APP_BUNDLE_ID=dev.globalsend.globalsend
GLOBALSEND_APP_GROUP_ID=group.dev.globalsend.globalsend
```

### iloader 重签

iloader 2.4.0/2.4.1（分别使用isideload 0.5.0/0.5.2）将主应用标识改为`原Bundle ID.团队ID`，并为主应用及扩展分配`group.重签后主应用Bundle ID`。它不会同步改写GlobalSend自定义的`GLOBALSEND_APP_GROUP_ID`配置。因此，旧版仅查固定组名，会把“正在查找错误的组”误报为“未授权”。这是GlobalSend的兼容缺陷，不需要重新生成密钥。签名行为见[上游实现](https://github.com/nab138/isideload/blob/main/isideload/src/sideload/sideloader.rs)。

51版保留原组优先；原组不可用时，再使用重签后的主应用标识查找对应共享组。扩展从宿主应用读取同一个标识，不使用扩展自己的标识。容器仍由iPadOS检查实际授权；不会以应用私有目录冒充扩展共享目录。若两种组均不可用，才提示检查主应用与扩展的签名。

在iloader中使用原账号覆盖安装修复版IPA，并保留`ShareExtension`。不要卸载旧应用或更换账号、Bundle ID；本次适配不需要提供Apple ID密码、证书或私钥。签名器未保留重签IPA时，可查签名日志，不要求用户提供不存在的文件。

主应用的“用其他应用打开/Open In”独立支持普通文件导入，主应用未取得组容器时仍使用自己的接收队列。未修复的48版IPA仍需原签名组名与运行配置完全匹配。

本项目不收集 Apple 账号、私钥或签名材料。实际重签和 iPad 安装验收由设备上的签名结果决定。

## 分享后直接发送（iOS / iPadOS 52版）

默认只打开应用并加入待发送，不自行选择设备。在 **设置 → 系统分享 → 分享后发送到** 选择一次目标设备后，后续系统分享会打开GlobalSend，并自动将这一批分享内容发给该设备，无需再点设备卡片。切回“仅加入待发送”即可取消默认目标。

目标记录使用 **中心标识 + deviceId**，名称仅展示。`deviceId`由中心注册时分配UUID，同一身份改名、换IP和切组不改变ID；重新注册身份会获得新ID。多组内重复出现的同一ID仍是同一设备。目标暂不可用或已换到其他中心时，保留本批待发送并显示失败，不改发同名设备，也不捎带原有草稿。相同分享批次只自动尝试一次，失败后可手动重试。

### 定向调用接口

```text
globalsend://send?requestId=<UUID>&serverKey=<中心标识>&deviceId=<设备ID>&text=<URL编码的正文>
```

- `requestId`：每次新调用生成一个UUID。同一请求重复到达不会重复发送。
- `serverKey`：客户端`ServerProfile.key`，即规范化中心地址与服务实例ID以换行连接后计算的SHA-256十六进制值。不包含组密码或登录token。
- `deviceId`：中心`GET /devices`返回的唯一ID，不是设备名或IP。目标仍须属于当前中心可发送的组内设备。
- `text`：完整正文，按URL查询参数编码；支持换行、中文、`+`和`&`。调用只发送该正文，不发送待发区其他内容。

分享附件通过扩展保存到共享收件箱；唤起入口为`globalsend://share?batchId=<UUID>`。扩展批次可携带`target: {serverKey, deviceId, name}`指定收件人，文件不塞入URL，不使用外部传入的磁盘路径读取文件。

此唤起方式参考[LocalSend分享扩展](https://github.com/localsend/localsend/blob/main/app/ios/ShareExtension/ShareViewController.swift)使用的[share_handler响应链实现](https://github.com/ShoutSocial/share_handler/blob/main/share_handler_ios/ios/Models/Classes/ShareHandlerIosViewController.swift)。保存成功后再请求唤起；不同iPadOS版本和来源应用的实际前台切换仍需实机验收。它不自动安装、不自动更换账号。

## 队列与文件生命周期

系统授予的临时 URI/NSItemProvider 表示会先复制到应用可持续访问的接收目录，原件不动。所有文件准备好后才原子写入批次 manifest。主应用读取 pending、成功加入并保存待发送区后 ack；ack 只移除 manifest，不删除已经加入待发送区的文件。

Android 合并 ClipData 和 EXTRA_STREAM，按 URI 去重，同时保留多个文本、URL及附带说明。普通文件保持原始字节，预览不支持也能分享和传输。系统文件管理器分享的目录/Tree URI 会按原目录结构导入，包含空目录，不压缩为 ZIP。iPad 在 NSItemProvider 回调返回前复制临时文件，避免回调结束后临时表示消失。[Apple API 说明](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation%28fortypeidentifier%3Acompletionhandler%3A%29)

Android 发出分享时同时提供 URI、ClipData 和只读 grant；多项使用 ACTION_SEND_MULTIPLE。[Android 系统分享说明](https://developer.android.com/develop/ui/compose/sharing/send)

## 设备验收

1. Android 分享两张图片、图片+视频、PDF、未知扩展名文件、两段文本/URL及包含子目录/空目录的文件夹到 GlobalSend；确认待发送内容完整、没有重复。
2. 分享后关闭/重新打开应用；确认待发送仍在。清空待发送后不应重新出现已确认的分享批次。
3. 选中多项后使用“全部拖拽”，拖到另一款支持多项的应用；拖回发送区域时，Android 不再复制自己的原件。
4. iPad 在 Files 分享多文件，完成后打开应用；再测试冷启动和运行中 Open In 文件。确认主 App/扩展的组权限匹配。
5. iPad 切换选择后再开始拖动，必须拖出新选择；拖动期间收到新内容，当前原生拖动源保持不变，下次拖动才应用更新。

本地检查覆盖了 Android 框架及持久化队列、Dart 通道参数和 iOS 项目结构。iOS Swift 编译由 macOS GitHub Action 执行；安装后的系统分享与跨应用手势仍需设备验收。
