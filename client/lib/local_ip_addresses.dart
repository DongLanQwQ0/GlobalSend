import 'dart:io';

import 'system_bridge.dart';

enum LocalIpGroup {
  ipv4Local('IPv4 内网'),
  ipv4Public('IPv4 公网'),
  ipv6Local('IPv6 内网'),
  ipv6Public('IPv6 公网');

  const LocalIpGroup(this.label);
  final String label;
}

class LocalIpSource {
  const LocalIpSource({
    required this.id,
    required this.name,
    this.displayName = '',
    this.description = '',
    this.kind = '',
    this.owner = '',
    this.internet,
  });
  final String id;
  final String name;
  final String displayName;
  final String description;
  final String kind;
  final String owner;
  final bool? internet;

  String get title => displayName.isEmpty ? name : displayName;
  int get order => switch (kind) {
    'Wi-Fi' => 0,
    '以太网' => 1,
    '蜂窝网络' => 2,
    'IMS 通话网络' => 3,
    'VPN' => 4,
    _ => 5,
  };
  String get subtitle => <String>{
    if (kind.isNotEmpty && kind != title) kind,
    if (name.isNotEmpty && name != title) name,
    if (owner.isNotEmpty) owner,
    if (description.isNotEmpty && description != title && description != name)
      description,
  }.join(' · ');
}

class LocalIpAddress {
  const LocalIpAddress(
    this.address,
    this.group, {
    this.source,
    this.reserved = false,
  });
  final String address;
  final LocalIpGroup group;
  final LocalIpSource? source;
  final bool reserved;
  String get categoryLabel => reserved
      ? (group == LocalIpGroup.ipv4Local ? 'IPv4 保留' : 'IPv6 保留')
      : group.label;
}

/// Reads local interfaces only: no probes, public-IP service or traffic.
Future<List<LocalIpAddress>> readLocalIpAddresses() async {
  if (Platform.isAndroid || Platform.isWindows) {
    return addressesFromInterfaces(await SystemBridge.localIpInterfaces());
  }
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    includeLinkLocal: true,
  );
  return addressesFromInterfaces([
    for (final network in interfaces)
      {
        'id': network.index.toString(),
        'name': network.name,
        'addresses': [for (final ip in network.addresses) ip.address],
      },
  ]);
}

/// De-duplicates inside each interface, never across distinct interfaces.
List<LocalIpAddress> addressesFromInterfaces(
  Iterable<Map<String, dynamic>> interfaces,
) {
  final result = <LocalIpAddress>[];
  for (final network in interfaces) {
    final name = network['name'] as String? ?? '';
    final source = LocalIpSource(
      id: network['id']?.toString() ?? name,
      name: name,
      displayName: network['displayName'] as String? ?? '',
      description: network['description'] as String? ?? '',
      kind: network['kind'] as String? ?? '',
      owner: network['owner'] as String? ?? '',
      internet: network['internet'] as bool?,
    );
    result.addAll(
      sortLocalIpAddresses(
        (network['addresses'] as List).cast<String>(),
        source: source,
      ),
    );
  }
  result.sort((a, b) {
    final kind = (a.source?.order ?? 5).compareTo(b.source?.order ?? 5);
    if (kind != 0) return kind;
    final title = (a.source?.title ?? '').toLowerCase().compareTo(
      (b.source?.title ?? '').toLowerCase(),
    );
    if (title != 0) return title;
    final id = (a.source?.id ?? '').compareTo(b.source?.id ?? '');
    if (id != 0) return id;
    return _compareIps(a, b);
  });
  return result;
}

List<LocalIpAddress> sortLocalIpAddresses(
  Iterable<String> values, {
  LocalIpSource? source,
}) {
  final unique = <String, LocalIpAddress>{};
  for (final value in values) {
    var host = value.trim();
    final encodedZone = host.contains('://');
    if (encodedZone) {
      host = Uri.tryParse(host)?.host ?? '';
    } else if (InternetAddress.tryParse(host.split('%').first) == null) {
      host = Uri.tryParse('//$host')?.host ?? '';
    }
    host = host.replaceAll(RegExp(r'^\[|\]$'), '');
    final zoneAt = host.indexOf('%');
    var zone = zoneAt < 0
        ? ''
        : encodedZone
        ? host.substring(zoneAt).replaceFirst('%25', '%')
        : host.substring(zoneAt);
    var ip = InternetAddress.tryParse(
      zoneAt < 0 ? host : host.substring(0, zoneAt),
    );
    if (ip == null) continue;
    // IPv4-mapped literals inherit the IPv4 scope, including 127/8.
    final bytes = ip.rawAddress;
    if (bytes.length == 16 &&
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255) {
      ip = InternetAddress.fromRawAddress(bytes.sublist(12));
      zone = '';
    }
    if (ip.isLoopback ||
        ip.isMulticast ||
        ip.rawAddress.every((byte) => byte == 0)) {
      continue;
    }
    if (ip.type == InternetAddressType.IPv6 &&
        ip.isLinkLocal &&
        zone.isEmpty &&
        source != null &&
        source.name.isNotEmpty) {
      zone = '%${source.name}';
    }
    final canonical =
        InternetAddress.fromRawAddress(ip.rawAddress).address + zone;
    unique[canonical] = LocalIpAddress(
      canonical,
      _group(ip),
      source: source,
      reserved: _reserved(ip),
    );
  }
  return unique.values.toList()..sort(_compareIps);
}

bool _reserved(InternetAddress ip) {
  final b = ip.rawAddress;
  if (b.length == 4) {
    return b[0] == 0 ||
        b[0] >= 240 ||
        b[0] == 198 && (b[1] == 18 || b[1] == 19) ||
        b[0] == 192 &&
            b[1] == 0 &&
            (b[2] == 2 || b[2] == 0 && b[3] != 9 && b[3] != 10) ||
        b[0] == 198 && b[1] == 51 && b[2] == 100 ||
        b[0] == 203 && b[1] == 0 && b[2] == 113;
  }
  return b[0] == 0x20 && b[1] == 1 && b[2] == 0x0d && b[3] == 0xb8;
}

LocalIpGroup _group(InternetAddress ip) {
  final b = ip.rawAddress;
  final local =
      _reserved(ip) ||
      ip.isLinkLocal ||
      (b.length == 4
          ? b[0] == 10 ||
                b[0] == 172 && b[1] >= 16 && b[1] <= 31 ||
                b[0] == 192 && b[1] == 168 ||
                b[0] == 100 && b[1] >= 64 && b[1] <= 127
          : (b[0] & 0xfe) == 0xfc || b[0] == 0xfe && (b[1] & 0xc0) == 0xc0);
  return b.length == 4
      ? (local ? LocalIpGroup.ipv4Local : LocalIpGroup.ipv4Public)
      : (local ? LocalIpGroup.ipv6Local : LocalIpGroup.ipv6Public);
}

int _compareIps(LocalIpAddress a, LocalIpAddress b) {
  final category = a.group.index.compareTo(b.group.index);
  if (category != 0) return category;
  final ab = InternetAddress(a.address.split('%').first).rawAddress;
  final bb = InternetAddress(b.address.split('%').first).rawAddress;
  for (var i = 0; i < ab.length; i++) {
    final byte = ab[i].compareTo(bb[i]);
    if (byte != 0) return byte;
  }
  return a.address.compareTo(b.address);
}
