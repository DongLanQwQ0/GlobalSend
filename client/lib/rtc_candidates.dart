import 'dart:io';

/// ICE routing hints. Reachability still comes from ICE connectivity checks.
class RtcCandidatePolicy {
  RtcCandidatePolicy(this.scope, this.localAddresses);
  final String scope;
  final List<InternetAddress> localAddresses;

  static String withoutCandidates(String sdp) => sdp
      .split(RegExp(r'\r?\n'))
      .where(
        (line) =>
            !line.startsWith('a=candidate:') && line != 'a=end-of-candidates',
      )
      .join('\r\n');

  bool allows(String candidate) {
    final parts = candidate.trim().split(RegExp(r'\s+'));
    if (parts.length < 8 || parts[6] != 'typ') return false;
    final type = parts[7], host = parts[4];
    if (!['host', 'srflx', 'prflx'].contains(type)) return false;
    if (host.toLowerCase().endsWith('.local')) {
      return scope == 'lan' && type == 'host';
    }
    final address = InternetAddress.tryParse(host);
    if (address == null || address.isMulticast || address.isLoopback) {
      return false;
    }
    final private = privateAddress(address);
    final samePrefix =
        address.type == InternetAddressType.IPv6 &&
        localAddresses.any(
          (local) =>
              local.type == InternetAddressType.IPv6 &&
              List.generate(
                8,
                (i) => local.rawAddress[i] == address.rawAddress[i],
              ).every((value) => value),
        );
    return scope == 'lan'
        ? type == 'host' && (private || samePrefix)
        : !private && !address.isLinkLocal;
  }

  static bool privateAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.isLoopback || address.isLinkLocal) return true;
    if (address.type == InternetAddressType.IPv4) {
      return bytes[0] == 10 ||
          bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31 ||
          bytes[0] == 192 && bytes[1] == 168 ||
          bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127;
    }
    if (bytes.take(10).every((value) => value == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255) {
      return privateAddress(InternetAddress.fromRawAddress(bytes.sublist(12)));
    }
    return (bytes[0] & 0xfe) == 0xfc ||
        bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0;
  }
}
