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
        padding: const EdgeInsets.fromLTRB(
          Ui.space4,
          Ui.space2,
          Ui.space2,
          Ui.space4,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '本机地址',
                    style: TextStyle(
                      fontSize: Ui.textXl,
                      height: Ui.leadingTight,
                      fontWeight: Ui.weightLabel,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const AppIcon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: Ui.space2),
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
                      padding: const EdgeInsets.symmetric(vertical: Ui.space4),
                      child: Text(
                        snapshot.hasError ? '无法获取地址' : '暂无 IP 地址',
                        style: TextStyle(
                          color: snapshot.hasError
                              ? Ui.colors(context).danger
                              : Ui.colors(context).textSecondary,
                          fontSize: Ui.textSm,
                        ),
                      ),
                    );
                  }
                  return ListView(
                    key: const ValueKey('local-ip-list'),
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(right: Ui.space1),
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
                              padding: const EdgeInsets.only(
                                top: Ui.space2,
                                bottom: Ui.space1,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    source?.title ?? '本机网卡',
                                    style: TextStyle(
                                      fontSize: Ui.textXs,
                                      fontWeight: Ui.weightLabel,
                                      color: Ui.colors(context).textSecondary,
                                    ),
                                  ),
                                  if (source != null &&
                                      source.subtitle.isNotEmpty) ...[
                                    const SizedBox(height: Ui.space0),
                                    Text(
                                      source.subtitle,
                                      style: TextStyle(
                                        color: Ui.colors(context).textSecondary,
                                        fontSize: Ui.text2xs,
                                        height: Ui.leadingCompact,
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
                            padding: const EdgeInsets.only(bottom: Ui.space1),
                            child: Material(
                              color: Ui.colors(context).surfaceMuted,
                              borderRadius: Ui.fieldRadius,
                              child: ListTile(
                                key: ValueKey(
                                  'local-ip-${sourceId.isEmpty ? '' : '$sourceId-'}${address.address}',
                                ),
                                shape: const RoundedRectangleBorder(
                                  borderRadius: Ui.fieldRadius,
                                ),
                                minTileHeight: Ui.touch,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: Ui.space3,
                                  vertical: Ui.space0,
                                ),
                                title: Text(
                                  address.address,
                                  style: const TextStyle(
                                    fontSize: Ui.textSm,
                                    height: Ui.leadingNormal,
                                  ),
                                ),
                                subtitle: Text(
                                  address.categoryLabel,
                                  style: TextStyle(
                                    fontSize: Ui.text2xs,
                                    color: Ui.colors(context).textSecondary,
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
