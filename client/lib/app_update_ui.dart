import 'package:flutter/material.dart';

import 'app_icon.dart';
import 'app_updates.dart';
import 'github_updates.dart';
import 'system_bridge.dart';
import 'ui_tokens.dart';

class AppUpdatesScope extends InheritedNotifier<AppUpdates> {
  const AppUpdatesScope({
    super.key,
    required AppUpdates updates,
    required super.child,
  }) : super(notifier: updates);
  static AppUpdates? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppUpdatesScope>()?.notifier;
}

Future<void> openUpdate(BuildContext context, AppUpdates updates) async {
  final offer = updates.available;
  if (offer == null) return;
  try {
    await SystemBridge.openWebUrl(Uri.parse(offer.downloadUrl));
  } catch (_) {
    if (context.mounted)
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('无法打开下载页面')));
  }
}

class UpdateCheckControl extends StatelessWidget {
  const UpdateCheckControl({super.key});
  @override
  Widget build(BuildContext context) {
    final updates = AppUpdatesScope.maybeOf(context);
    if (updates == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                updates.status,
                key: const ValueKey('update-status'),
                style: TextStyle(
                  fontSize: Ui.textXs,
                  color: Ui.colors(context).textSecondary,
                ),
              ),
            ),
            const SizedBox(width: Ui.space2),
            TextButton(
              key: const ValueKey('check-updates'),
              onPressed: updates.busy
                  ? null
                  : () => updates.check(manual: true),
              child: const Text('检查更新'),
            ),
          ],
        ),
        if (updates.available != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => openUpdate(context, updates),
              child: Text(
                updates.build.platform == UpdatePlatform.ios
                    ? '下载 IPA'
                    : '下载新版',
              ),
            ),
          ),
        if (updates.build.platform == UpdatePlatform.ios &&
            updates.notificationsAllowed == false)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () async {
                try {
                  await updates.requestNotificationPermission();
                } catch (_) {
                  if (context.mounted)
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(content: Text('请在系统设置中允许通知')),
                    );
                }
              },
              child: const Text('允许更新通知'),
            ),
          ),
      ],
    );
  }
}

/// Update offers are separate from incoming file/text receipts: never activate
/// the receive dock, change the current route, or steal editor focus.
class AppUpdateNotice extends StatelessWidget {
  const AppUpdateNotice({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final updates = AppUpdatesScope.maybeOf(context);
    final offer = updates?.available;
    final visible =
        updates?.showBanner == true && offer != null && updates!.foreground;
    if (visible)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted &&
            updates.foreground &&
            identical(offer, updates.available))
          updates.presented();
      });
    return Overlay.wrap(
      child: Stack(
        children: [
          child,
          if (visible)
            Positioned(
              top: Ui.space1,
              left: Ui.space3,
              right: Ui.space3,
              child: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: Material(
                      key: const ValueKey('update-notice'),
                      color: Ui.colors(context).surface,
                      elevation: Ui.elevationModal,
                      shape: RoundedRectangleBorder(
                        borderRadius: Ui.cardRadius,
                        side: BorderSide(color: Ui.colors(context).line),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          Ui.space3,
                          Ui.space1,
                          Ui.space1,
                          Ui.space1,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'GlobalSend ${offer.version.display} 可更新',
                                style: const TextStyle(fontSize: Ui.textSm),
                              ),
                            ),
                            TextButton(
                              onPressed: () => openUpdate(context, updates),
                              child: Text(
                                updates.build.platform == UpdatePlatform.ios
                                    ? '下载 IPA'
                                    : '下载',
                              ),
                            ),
                            IconButton(
                              tooltip: '稍后',
                              onPressed: updates.dismiss,
                              icon: const AppIcon(Icons.close, size: 20),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
