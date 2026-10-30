# 1.0.57：媒体文件名与 Windows 触屏拖放

本地发布：Windows 和 Android **1.0.57+68** 已覆盖并启动，构建源码 `a965322`；Android APK 已通过签名、无字体包检查，16,305,744 字节。手机原先暂缓，用户提供新地址后于2026-10-30 16:51覆盖安装成功，已确认版本68/1.0.57及进程存在，保留应用数据。安装记录在 `artifacts/releases/latest-local.json`。

## 修复

- Android 暂存坞媒体建议拖到待发送区：重新读取媒体库显示名称和 MIME，为无后缀的图片/视频补全后缀。保留原始 URI，不改名、不复制源文件。待发区显示名独立保存，发送沿用该名称；系统分享和外部拖入也使用同一后缀规则。
- 已收到的无后缀图片：按前 32 字节识别图片，接收、历史、文件库、接收坞和详情可直接预览。两个用户样本均为有效 JPEG，无需重发或修改原文件。
- Windows 11 触屏拖出：使用系统 `ConvertPrimaryPointerToMouseDrag` 接入 OLE，由 Windows 提供移动和松手事件。生产路径不再逐帧 `SendInput`，不安装低级鼠标钩子；跨窗口捕获交接和离开源窗口不再误取消拖动。系统接口不可用时保留鼠标拖放，不回退到模拟触屏输入。

## 已有证据

- 实际两个 JPEG 经 Flutter 解码；接收/历史卡片、紧凑接收坞、待发预览组件的图片像素已渲染并查看。
- LAN 与真实本地中心中继传输测试包含无后缀 JPEG：目标收到 `.jpg`，字节一致，原文件保留。原有文件夹树传输断言保留。
- 同进程 `nativeDrop` 测试确认 URI 不变、待发显示名和 outbox 有后缀、移出及清空释放显示名，不复制媒体。
- Android 原生媒体命名与 provider stat 检查通过；stat 的原始名称不变，显示提示为 `.jpg`。
- Windows 隐藏 HWND 的 OLE/输入替身检查通过：1000 次指针移动无模拟输入，转换期间捕获交接、跨窗离开、松手与取消语义符合预期。此检查未操作用户桌面。

## 留给实机验收

- Windows 触屏拖动的实际流畅度与向桌面/其他应用投放。按用户要求，本轮不进行 Windows 界面自动操作。
- Android 暂存媒体建议拖入待发区、发送后的文件名和图片预览。新版已安装启动，实际手指拖放尚待验收；手机已交还 Chrona 会话串行使用，本轮不并发触控。

Windows 系统接口文档：[ConvertPrimaryPointerToMouseDrag](https://learn.microsoft.com/en-us/windows/win32/winmsg/winuser/nf-winuser-convertprimarypointertomousedrag)。本机 Windows 11 的接口导出已只读确认。
