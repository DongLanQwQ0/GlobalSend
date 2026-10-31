# GlobalSend local releases

- The public project/product name is exactly `GlobalSend`, with this capitalization.
- Native release workflow: `npm run release:local`. After each successful native build, update the complete Windows bundle in `E:\Programs\GlobalSend` and restart GlobalSend; push the APK to the connected physical Android phone, install with `adb install -r`, and launch it. Preserve application data. Do not host installers on the server.
- When Android builds or updates are explicitly on hold, use `npm run release:local -- -WindowsOnly` for Windows. It builds/replaces/restarts the complete Windows bundle without building an APK, accessing ADB or changing the phone; keep its last confirmed version in the release record.
- Stabilize and accept Windows and Android first; build the IPA last. The iPad workflow is manual-only (`workflow_dispatch`), not triggered by source pushes. Do not start an IPA build during ongoing Windows/Android fixes.
- Keep project-specific builds, logs, screenshots and temporary files inside this project. Reusable SDK/cache/download content belongs on F:. Do not read the user's SSH private keys.
- Preserve the single-instance protocol, tray receiver lifetime, existing state and transfer entry points when editing native startup or release tooling.
- Browser automation must reuse the same established persistent profile and preserve login state. Never create a new profile per run (including random or mkdtemp user-data-dir). Run profile-sharing browser jobs serially; if occupied, wait or reuse the existing session rather than deleting locks, force-closing the user's browser, or switching to a fresh profile. Keep per-run reports/screenshots separate from the persistent profile.

## 实现与检查原则

- 禁止偷懒省事：不能用简单计时器、静默丢弃、禁用功能或增加用户操作来替代正确的业务逻辑。修改必须覆盖实际入口、状态变化和相关平台，不以解释、计划或孤立测试代替修复。
- 优先投入交互、性能和失败恢复。先理解用户如何操作，再决定状态和生命周期；不能把“后台发现”当作“用户已看到”，不能在用户操作中移除正在操作的内容。
- 仅保留针对真实风险的必要保护：系统权限与授权、组间访问隔离、原始文件及用户数据的删除边界。不额外叠加无依据的确认、限制、重复检查或安全功能，不为假想风险增加前置条件。
- 检查以实际事件和状态变化驱动；复用仍然有效的结果，合并重复检查，减少无必要的检查频率。检查失败应处理具体原因，不通过提高护栏、静默回退或反复重试掩盖问题。
- 验证围绕改动后的真实行为与失败路径。完成必要的自动检查和获准的实际操作后交付，不扩展无关矩阵、不反复验证已验收且未受影响的功能。
- 跨会话消息仅用于同时运行且已存在的资源或写入冲突，并明确冲突对象和需要的调整。不发送例行进度、重复确认、无关转述，也不为尚未开始的独立工作反复协调。
