# Web 系统通知

在设置中点击“系统通知”开关，浏览器同意后启用。后台收到普通文本、文本更新或文件时显示系统通知；点击返回对应接收项。组内共享编辑不发送通知。前台仍使用应用内接收页。

文件只在首次到达、可下载和接收完成时更新通知，不按进度反复提醒。后续阶段沿用同一个通知并静默更新；服务器文件已就绪只表示“可下载”，不等于已保存在本机。

## 哪些环境可以使用

- 使用浏览器认定的安全上下文（通常为受信任证书的 HTTPS，本机 localhost 开发亦可）。使用 IP 地址不是单独的阻碍，实际以 `window.isSecureContext` 和 API 能力为准。普通 HTTP 局域网地址不能启用。
- 桌面使用同源 Service Worker 的通知，无法注册时尝试浏览器 `Notification`。是否显示悬浮提示、声音由浏览器、系统通知与专注模式决定。[MDN：通知 API](https://developer.mozilla.org/en-US/docs/Web/API/Notifications_API/Using_the_Notifications_API)、[安全上下文](https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Secure_Contexts)
- iPad/iPhone 需要支持该功能的 iPadOS/iOS，并将网页“添加到主屏幕”，从主屏幕图标打开。Safari 普通标签页不能据此获得系统通知能力。Apple 从 iOS/iPadOS 16.4 开始支持主屏幕 Web App 通知，权限请求必须由用户直接点击触发。[WebKit：iOS/iPadOS Web App 通知](https://webkit.org/blog/13878/)
- 用户拒绝、不支持或暂时无法显示时，保留正常应用内接收，不会每条消息再请求权限。浏览器中更改授权后可回设置重新启用。

## 页面关闭或被挂起后

本版通知由仍运行的页面收到 WebSocket/轮询事件后调用 `showNotification`。Service Worker 只负责显示和点击返回，没有建立另一个常驻连接。页面被系统挂起、关闭或浏览器退出后，**不能保证继续接收新消息或文件**。

这不是“关闭页面仍收推送”的完整 Web Push。后者还需要浏览器 Push 订阅、服务端发送器及订阅持久化；本版没有新增 VAPID 私钥、外部推送服务或收费服务。[Apple：完整 Web Push 的服务端与订阅组成](https://developer.apple.com/documentation/usernotifications/sending-web-push-notifications-in-web-apps-and-browsers)

## 开发接口

`web/src/notifications.ts` 的 `WebNotifications`：

```ts
const notifications = new WebNotifications({
  onOpen: itemId => openReceiptWhenSessionReady(itemId),
  onChange: () => renderSettings(),
});

// 必须从设置开关的 click/tap 直接调用。
await notifications.requestEnable();
notifications.setEnabled(false);

void notifications.notify({
  id: eventId, revision, kind: 'text', phase: 'updated',
  title: senderName, body: text, itemId: receiptId,
});
```

`kind` 为 `text/file/shared`，`phase` 为 `incoming/ready/received/updated`；同事件/版本去重，文件处理 incoming、ready 与 received。初次历史加载不要调用 notify。helper 根据页面可见性/焦点决定是否显示系统通知，不替代接收 UI。创建时通知 URL 的 itemId 在 microtask 中回调，应用应等会话和历史恢复后定位。

静态文件位于 `web/public`，随 Vite 复制到 `/globalsend/app/` 或自定义部署子路径，不要求服务器新增 API。worker 没有 fetch/cache 拦截，不缓存旧版页面，也不接收完整 Web Push。点击优先聚焦已开的本应用窗口并传递 itemId；没有窗口时打开同应用路径的接收 URL。[MDN：notificationclick](https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorkerGlobalScope/notificationclick_event)

## 验收

1. 初次加载及收消息不自动弹权限；点击设置开关才询问。
2. 切到其他应用后发文本和修改文本，通知一次；点击回对应内容。
3. 发送文件：到达提醒一次，完成仅更新，不跟每个进度 tick 响。
4. 组共享不通知；拒绝通知仍可正常接收。
5. iPad 普通标签页提示添加主屏幕；主屏幕 Web App 需在真实设备确认授权与后台限制。

独立逻辑测试覆盖同源子路径、许可时机、前后台、去重、文件静默更新、worker 点击路由、iPad 条件和 fallback。它们不替代真实浏览器/系统通知和 iPad 实机验收。
