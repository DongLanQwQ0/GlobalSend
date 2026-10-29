# Android 拖放格式对照

此工具是无网络的测试来源和接收器，不替代微信验收，也不会向聊天联系人发送内容。

## 构建与安装

在项目根目录执行：

```powershell
& D:\NodeJs\node.exe client/tool/android_shelf_acceptance/build.mjs
& F:\Android\Sdk\platform-tools\adb.exe -s $serial install -r artifacts/tmp/android-shelf-acceptance/shelf-acceptance.apk
& F:\Android\Sdk\platform-tools\adb.exe -s $serial shell am start -n dev.globalsend.shelfacceptance/.ShelfAcceptanceActivity
```

`$serial` 使用当前已经连接的实体手机，不扫描端口、不新建模拟器。

## 相册与 GlobalSend 对照

1. 长按本工具的测试图片，将它放入 GlobalSend 暂存坞。
2. 将该暂存项拖到本工具的接收区域。读取授权结果写入 `outcome.json`；ClipData 的格式记录写入 `globalsend-clip.json`。
3. 执行以下命令。本工具只创建一张自己的合成图片，然后使用 vivo 相册打开它；不会选择用户照片。

```powershell
& F:\Android\Sdk\platform-tools\adb.exe -s $serial shell am start -n dev.globalsend.shelfacceptance/.ShelfAcceptanceActivity --es probe gallery
```

4. 将相册中的合成图片拖回本工具接收区域，读取 `gallery-clip.json`。从图片非文字区域长按，避开相册OCR选择。比较 MIME、authority、Intent、extras 字段，不保存正文、文件名或完整 URI。
5. 结束后点击“移除本工具创建的相册测试图”。仅删除本工具保存的那一个 MediaStore 插入结果，不删除照片目录。完成清理后才卸载测试工具。

读取报告：

```powershell
& F:\Android\Sdk\platform-tools\adb.exe -s $serial shell run-as dev.globalsend.shelfacceptance cat files/globalsend-clip.json
& F:\Android\Sdk\platform-tools\adb.exe -s $serial shell run-as dev.globalsend.shelfacceptance cat files/gallery-clip.json
```

对照时保持目标窗口、文件内容和手势条件一致。相册图由此工具创建，因此工具读取该图本身不能证明跨应用授权成功；它用于比较拖放格式。GlobalSend 私有 provider 的实际读取结果则单独记录。

使用ADB保持拖动并切回接收器时，带 `-f 0x00020000 --es probe target`（REORDER_TO_FRONT），把接收器移到同任务中的相册上方，而不是销毁拖动来源。只启动根Activity而不带该标志会停留在相册顶层。

## 微信的完成条件

提前打开无菜单遮挡的同一个聊天窗口，分别拖入同一张合成图片。确认是否出现可发送的图片或附件预览；不自动点击“发送”。系统分享面板、原生接受回执、预览服务读取或本工具读取成功均不能代替这一步。

当前状态：USB手机已更新1.0.42。真实同图对照已取得：两者均为image/png、单项content URI；相册authority为media，包含photo_type_flags=[0]，GlobalSend为自己的dock-files provider，包含本地拖动关联字段。两次接收均可读取。合成相册测试图已清理。微信正常聊天窗口的插入结果仍需确认，元数据差异是下一步区分依据，尚不是根因结论。
