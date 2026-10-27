import 'dart:io';

import 'local_ip_addresses.dart';

/// One concrete source-address/remote-address pair, or an explicit Android
/// cellular Network. Empty sourceAddress means the OS selects the source IP.
class CandidateRoute {
  const CandidateRoute({
    required this.address,
    required this.lan,
    this.sourceAddress = '',
    this.sourceName = '系统路由',
    this.cellular = false,
  });
  final String address, sourceAddress, sourceName;
  final bool lan, cellular;
  String get key => '$cellular|$sourceAddress|$address';
}

InternetAddress? literalCandidateAddress(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https') return null;
  return InternetAddress.tryParse(uri.host.replaceAll(RegExp(r'^\[|\]$'), ''));
}

bool isDirectIp(InternetAddress ip) {
  var b = ip.rawAddress;
  if (b.length == 16 &&
      b.take(10).every((v) => v == 0) &&
      b[10] == 255 &&
      b[11] == 255) {
    return isDirectIp(InternetAddress.fromRawAddress(b.sublist(12)));
  }
  if (ip.isLoopback ||
      ip.isLinkLocal ||
      ip.isMulticast ||
      b.every((v) => v == 0))
    return false;
  if (b.length == 4) {
    return !(b[0] == 0 ||
        b[0] >= 240 ||
        b[0] == 198 && (b[1] == 18 || b[1] == 19) ||
        b[0] == 192 &&
            b[1] == 0 &&
            (b[2] == 2 || b[2] == 0 && b[3] != 9 && b[3] != 10) ||
        b[0] == 198 && b[1] == 51 && b[2] == 100 ||
        b[0] == 203 && b[1] == 0 && b[2] == 113);
  }
  return !(b[0] == 0x20 && b[1] == 1 && b[2] == 0x0d && b[3] == 0xb8);
}

bool isPublishableLocalAddress(LocalIpAddress address) {
  final ip = InternetAddress.tryParse(address.address.split('%').first);
  return ip != null &&
      isDirectIp(ip) &&
      !(address.source?.kind == 'IMS 通话网络' &&
          address.source?.internet == false);
}

bool isPrivateRouteIp(InternetAddress ip) {
  final b = ip.rawAddress;
  if (b.length == 4) {
    return b[0] == 10 ||
        b[0] == 172 && b[1] >= 16 && b[1] <= 31 ||
        b[0] == 192 && b[1] == 168 ||
        b[0] == 100 && b[1] >= 64 && b[1] <= 127;
  }
  if (b.take(10).every((v) => v == 0) && b[10] == 255 && b[11] == 255) {
    return isPrivateRouteIp(InternetAddress.fromRawAddress(b.sublist(12)));
  }
  return (b[0] & 0xfe) == 0xfc || b[0] == 0xfe && (b[1] & 0xc0) == 0xc0;
}

bool _samePrefix(InternetAddress a, InternetAddress b) {
  if (a.type != InternetAddressType.IPv6 || b.type != InternetAddressType.IPv6)
    return false;
  for (var i = 0; i < 8; i++) {
    if (a.rawAddress[i] != b.rawAddress[i]) return false;
  }
  return true;
}

/// Private addresses on different prefixes can be routed (e.g. campus VLANs),
/// so only address-family and explicitly unusable-source facts prune pairs.
List<CandidateRoute> planCandidateRoutes(
  List<String> candidates,
  List<LocalIpAddress> locals, {
  bool allowCellular = false,
  bool androidCellular = false,
}) {
  final local = locals.where(isPublishableLocalAddress).toList();
  final routes = <String, CandidateRoute>{};
  void add(CandidateRoute route) => routes[route.key] = route;
  for (final value in candidates.toSet()) {
    final remote = literalCandidateAddress(value);
    if (remote == null || !isDirectIp(remote)) continue;
    final family = local
        .where(
          (address) =>
              InternetAddress(address.address.split('%').first).type ==
              remote.type,
        )
        .toList();
    final private = isPrivateRouteIp(remote);
    final sameLink = family.any(
      (address) => _samePrefix(
        InternetAddress(address.address.split('%').first),
        remote,
      ),
    );
    if (family.isNotEmpty) {
      add(CandidateRoute(address: value, lan: private || sameLink));
    }
    for (final source in family) {
      if (androidCellular && source.source?.kind == '蜂窝网络') continue;
      add(
        CandidateRoute(
          address: value,
          sourceAddress: source.address,
          sourceName: source.source?.title ?? '本机地址',
          lan:
              private ||
              _samePrefix(
                InternetAddress(source.address.split('%').first),
                remote,
              ),
        ),
      );
    }
    // A permitted cellular lease may bring up IPv6 after this snapshot. Do not
    // discard it merely because Wi-Fi/default routing has no IPv6 address.
    if (androidCellular && allowCellular && !private) {
      add(
        CandidateRoute(
          address: value,
          lan: false,
          sourceName: '蜂窝网络（系统绑定）',
          cellular: true,
        ),
      );
    }
  }
  final values = routes.values.toList();
  values.sort(
    (a, b) =>
        (a.lan
                ? 0
                : a.cellular
                ? 2
                : 1)
            .compareTo(
              b.lan
                  ? 0
                  : b.cellular
                  ? 2
                  : 1,
            ),
  );
  return values;
}
