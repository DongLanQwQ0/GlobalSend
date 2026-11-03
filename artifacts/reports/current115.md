# 115：旧问题收尾与剪贴板文本修复

源码固定 `c9abb42d58236a3812dca0726d22e726e859b217`。新UI重排仍等用户需求文档，本次只处理原有问题及真实验收。

## 完成的修复和检查

- 自动剪贴板同步不再按验证码、token等词拦截，也不再单独限制8 KiB；来源与原生接收端及中心POST/PATCH一并修复。沿用普通文本长度上限，系统私有标记和防回环保留。
- 真实本地中心与生产控制器：旧关键词、48000字节中文、恰好100000个ASCII字符送达；超协议长度显示失败，旧槽位保留，仅指定目标可见，原草稿不变、普通收件数为0。系统剪贴板桥为替身，未操作Windows系统剪贴板。
- 中心创建/编辑/重试/显式转发以及超限、组间隔离、非目标事件检查通过；TypeScript typecheck通过。Dart analyze无错误/警告，既有代码风格info未作无关重排。
- 114手机目录拉取、置顶与完整目录系统拖回待发专项已完成并清理，见 `android114-directory-pull-drag.md`。未重测已通过且未变更的微信与设备高亮。

证据：`artifacts/tmp/clipboard-text115/result.json`、`artifacts/tmp/remaining114/text-fixed-center.log`、`server-text-policy.log`。初次检查发现中心仍有8 KiB独立限制后已修复；保留原失败，不把错误命令的零测试结果计为通过。

## 实际更新状态

| 平台 | 当前状态 |
| --- | --- |
| Windows | 标准完整构建、覆盖并重启成功；`E:\Programs\GlobalSend\globalsend.exe`实际版本1.0.90+115，PID17548。未进行真实界面、触屏或OS剪贴板测试。 |
| Android | APK已构建并验签，16,492,643字节，无打包字体。当前无ADB实体设备，旧地址10.196.131.180:44423拒绝连接；手机最后确认1.0.89+114，未假称推送。 |
| 中心/Web | `globalsend:clipboard-text-1.0.90-20261103` healthy，实例ID不变。真实公网大文本仅到指定目标、长文本编辑及Web入口资源/MIME检查通过。 |
| iOS/iPadOS | 当前可用IPA为114；等原生更新稳定后最后构建115，不提前替换iOS清单。用户手动签名安装。 |

Windows ZIP22,599,441字节。构建日志`artifacts/logs/release-clipboard-text115.log`及两平台release-local日志；部署与公开检查`artifacts/tmp/release115/`。安装包只放本地与GitHub，不上传中心。功能评审页仍仅本地，部署解包排除了该目录，没有上线未确认的UI方案。

## 下一步

ADB恢复后覆盖安装115并读回版本，保留数据，不终止Chrona。原生稳定后从同源码tag最后构建通用IPA。Windows真实重启偏好、触屏/虚拟桌面/系统坞，以及iPad目标应用行为仍由用户验收，不能用编译或组件检查代替。
