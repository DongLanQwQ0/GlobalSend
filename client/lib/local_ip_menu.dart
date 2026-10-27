import 'app_icon.dart';

import 'package:flutter/material.dart';

import 'local_ip_addresses.dart';
import 'ui_tokens.dart';

/// Returns one plain IP address. The caller owns adding it to the send queue.
Future<String?> showLocalIpMenu(
  BuildContext context,
  Future<List<LocalIpAddress>> Function() read,
) {
  return showDialog<String>(
    context: context,
    builder: (_) => _LocalIpMenu(read: read),
  );
}

class _LocalIpMenu extends StatefulWidget {
  const _LocalIpMenu({required this.read});
  final Future<List<LocalIpAddress>> Function() read;
  @override
  State<_LocalIpMenu> createState() => _LocalIpMenuState();
}

class _LocalIpMenuState extends State<_LocalIpMenu> {
  late final addresses = widget.read();
  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 440,
        maxHeight:
            MediaQuery.sizeOf(context).height *
            (MediaQuery.sizeOf(context).width >= 720 ? .82 : .72),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 12, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '本机地址',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const AppIcon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: FutureBuilder<List<LocalIpAddress>>(
                future: addresses,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const SizedBox(
                      height: 96,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snapshot.hasError || snapshot.data!.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        snapshot.hasError ? '无法获取地址' : '暂无 IP 地址',
                        style: const TextStyle(color: Ui.muted),
                      ),
                    );
                  }
                  return ListView(
                    key: const ValueKey('local-ip-list'),
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(right: 8),
                    children: [
                      for (final sourceId
                          in snapshot.data!
                              .map((address) => address.source?.id ?? '')
                              .toSet()) ...[
                        Builder(
                          builder: (context) {
                            final source = snapshot.data!
                                .firstWhere(
                                  (address) =>
                                      (address.source?.id ?? '') == sourceId,
                                )
                                .source;
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(2, 12, 2, 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    source?.title ?? '本机网卡',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (source != null &&
                                      source.subtitle.isNotEmpty) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      source.subtitle,
                                      style: const TextStyle(
                                        color: Ui.muted,
                                        fontSize: 12,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          },
                        ),
                        for (final address in snapshot.data!.where(
                          (address) => (address.source?.id ?? '') == sourceId,
                        ))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Material(
                              color: Ui.input,
                              borderRadius: Ui.fieldRadius,
                              child: ListTile(
                                key: ValueKey(
                                  'local-ip-${sourceId.isEmpty ? '' : '$sourceId-'}${address.address}',
                                ),
                                shape: const RoundedRectangleBorder(
                                  borderRadius: Ui.fieldRadius,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 4,
                                ),
                                title: Text(
                                  address.address,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.5,
                                  ),
                                ),
                                subtitle: Text(
                                  address.categoryLabel,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Ui.muted,
                                  ),
                                ),
                                onTap: () =>
                                    Navigator.pop(context, address.address),
                              ),
                            ),
                          ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
