import 'app_icon.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'peer.dart';
import 'reachability.dart';
import 'ui_tokens.dart';

class ReachabilityScreen extends StatefulWidget {
  const ReachabilityScreen({
    super.key,
    required this.monitor,
    this.deviceId,
    this.deviceName,
    this.onRefresh,
  });
  final ReachabilityMonitor monitor;
  final String? deviceId, deviceName;
  final Future<void> Function()? onRefresh;

  @override
  State<ReachabilityScreen> createState() => _ReachabilityScreenState();
}

class _ReachabilityScreenState extends State<ReachabilityScreen> {
  ReachabilityMonitor get monitor => widget.monitor;
  bool _refreshing = false;
  bool get running =>
      _refreshing ||
      (widget.deviceId == null
          ? monitor.running
          : monitor.checkingDevice(widget.deviceId!));

  @override
  void initState() {
    super.initState();
    if (widget.deviceId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(refresh());
      });
    }
  }

  Future<void> refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      if (widget.onRefresh != null) {
        await widget.onRefresh!();
      } else if (widget.deviceId == null) {
        await monitor.refresh();
      } else {
        await monitor.refreshDevice(widget.deviceId!);
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: monitor,
    builder: (context, _) {
      final devices = monitor.devices
          .where(
            (device) =>
                widget.deviceId == null ||
                device['deviceId'] == widget.deviceId,
          )
          .toList();
      final error = widget.deviceId == null
          ? monitor.lastError
          : monitor.deviceError(widget.deviceId!);
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.maybePop(context),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: Text(
                widget.deviceName ?? '连接检测',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                IconButton(
                  key: const ValueKey('refresh-reachability'),
                  tooltip: '立即检测',
                  onPressed: running || !monitor.connected ? null : refresh,
                  icon: const AppIcon(Icons.refresh),
                ),
              ],
            ),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    const Text(
                      '源地址与目标地址 · 以实际检测为准',
                      style: TextStyle(color: Ui.muted, fontSize: 13),
                    ),
                    if (!monitor.connected)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text('连接中心后可检测'),
                      ),
                    if (running)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                    if (error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 20),
                    if (devices.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        child: Center(
                          child: Text(
                            widget.deviceId == null ? '暂无在线设备' : '设备已离线或不在当前组',
                          ),
                        ),
                      ),
                    for (final device in devices) _device(context, device),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _device(BuildContext context, Map<String, dynamic> device) {
    final id = device['deviceId'] as String;
    final results = monitor.forDevice(id).toList();
    final peer = device['peer'];
    final expiry = peer is Map
        ? DateTime.tryParse(peer['expiresAt'] as String? ?? '')
        : null;
    final expired = expiry != null && !expiry.isAfter(DateTime.now());
    if (peer is Map && !expired) {
      for (final address in List<String>.from(
        peer['candidates'] as List? ?? [],
      )) {
        if (results.any(
          (result) => result.address == address && !result.cellular,
        ))
          continue;
        final host = Uri.tryParse(address)?.host
            .replaceAll(RegExp(r'^\[|\]$'), '');
        final ip = host == null ? null : InternetAddress.tryParse(host);
        results.add(
          AddressCheck(
            deviceId: id,
            address: address,
            scope: ip != null && PeerTransport.privateAddress(ip)
                ? ReachabilityScope.lan
                : ReachabilityScope.public,
            reachable: false,
            tested: false,
            error: monitor.untestedReason(address),
            checkedAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
      }
    }
    final rtc = device['rtc'];
    if (rtc is Map) {
      for (final scope in List<String>.from(rtc['scopes'] as List? ?? [])) {
        final category = scope == 'lan'
            ? ReachabilityScope.lan
            : ReachabilityScope.public;
        if (!results.any(
          (result) => result.transport == 'rtc' && result.scope == category,
        )) {
          results.add(
            AddressCheck(
              deviceId: id,
              address: 'WebRTC',
              scope: category,
              reachable: false,
              tested: false,
              transport: 'rtc',
              checkedAt: DateTime.fromMillisecondsSinceEpoch(0),
            ),
          );
        }
      }
    }
    if (monitor.center.isNotEmpty &&
        !results.any((result) => result.scope == ReachabilityScope.relay)) {
      results.add(
        AddressCheck(
          deviceId: id,
          address: monitor.center,
          scope: ReachabilityScope.relay,
          reachable: false,
          tested: false,
          checkedAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
      );
    }
    final sections = <String, List<AddressCheck>>{};
    for (final result in results) {
      sections.putIfAbsent(_section(result), () => []).add(result);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                device['name'] as String? ?? widget.deviceName ?? '设备',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (device['platform'] == 'web')
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '浏览器未公开 IP 时，显示 RTC 通道检测结果',
                    style: TextStyle(
                      color: Ui.muted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              if (expired)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '直连地址已过期，等待设备更新',
                    style: TextStyle(color: Ui.muted, fontSize: 12),
                  ),
                ),
              if (results
                  .where((result) => result.scope != ReachabilityScope.relay)
                  .isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    '尚无直连地址或 RTC 检测结果',
                    style: TextStyle(color: Ui.muted, fontSize: 13),
                  ),
                ),
              for (final label in const [
                '局域网',
                '公网 IPv4',
                '公网 IPv6',
                '公网 · RTC',
                '公网',
                '中继',
              ])
                if (sections.containsKey(label)) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 20, bottom: 8),
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Ui.muted,
                      ),
                    ),
                  ),
                  for (final result in sections[label]!)
                    _address(context, result),
                ],
            ],
          ),
        ),
      ),
    );
  }

  String _section(AddressCheck result) {
    if (result.scope == ReachabilityScope.lan) return '局域网';
    if (result.scope == ReachabilityScope.relay) return '中继';
    if (result.transport == 'rtc') return '公网 · RTC';
    final host = Uri.tryParse(result.address)?.host
        .replaceAll(RegExp(r'^\[|\]$'), '');
    final ip = host == null ? null : InternetAddress.tryParse(host);
    return ip == null
        ? '公网'
        : ip.type == InternetAddressType.IPv6
        ? '公网 IPv6'
        : '公网 IPv4';
  }

  Widget _address(BuildContext context, AddressCheck result) {
    final relay = result.scope == ReachabilityScope.relay;
    final rtc = result.transport == 'rtc';
    final color = !result.tested
        ? Ui.muted
        : result.reachable
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;
    final status = !result.tested
        ? '未测'
        : result.reachable
        ? (relay ? '中心可达' : '成功')
        : '失败';
    final time = result.checkedAt.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    final today = DateTime.now();
    final sameDay =
        today.year == time.year &&
        today.month == time.month &&
        today.day == time.day;
    final timestamp =
        '${sameDay ? '' : '${two(time.month)}/${two(time.day)} '}${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Ui.input,
          borderRadius: Ui.fieldRadius,
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AppIcon(
                    !result.tested
                        ? Icons.schedule
                        : result.reachable
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 17,
                    color: color,
                  ),
                  const SizedBox(width: 7),
                  Text(status, style: TextStyle(color: color, fontSize: 13)),
                  if (result.tested) ...[
                    const SizedBox(width: 12),
                    Text(
                      '${result.elapsedMs} ms',
                      style: const TextStyle(color: Ui.muted, fontSize: 12),
                    ),
                    const Spacer(),
                    Flexible(
                      child: Text(
                        timestamp,
                        style: const TextStyle(color: Ui.muted, fontSize: 11),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 7),
              SelectableText(
                result.reachable &&
                        result.sourceEndpoint.isNotEmpty &&
                        result.targetEndpoint.isNotEmpty
                    ? '${result.sourceEndpoint} → ${result.targetEndpoint}'
                    : '本机：${result.sourceEndpoint.isNotEmpty
                          ? result.sourceEndpoint
                          : result.sourceAddress.isEmpty
                          ? '未提供'
                          : result.sourceAddress}\n${relay ? '中心' : '对方'}：${result.targetEndpoint.isNotEmpty
                          ? result.targetEndpoint
                          : rtc && result.address == 'WebRTC'
                          ? '未提供'
                          : result.address}',
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 4),
              Text(
                relay
                    ? '仅验证中心可达，未验证目标接收'
                    : rtc
                    ? 'RTC 通道往返检测'
                    : result.sourceAddress.isNotEmpty
                    ? result.sourceName
                    : result.cellular
                    ? '蜂窝网络（系统绑定）'
                    : '系统路由',
                style: const TextStyle(
                  color: Ui.muted,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
              if (result.error.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  result.error,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: result.tested
                        ? Theme.of(context).colorScheme.error
                        : Ui.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
