import 'dart:convert';
import 'dart:io';

enum UpdatePlatform { windows, android, ios }

class AppReleaseVersion implements Comparable<AppReleaseVersion> {
  const AppReleaseVersion(this.major, this.minor, this.patch, [this.build = 0]);
  final int major, minor, patch, build;
  static AppReleaseVersion? parse(String value, {int? build}) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+(\d+)|-build(\d+))?$')
        .firstMatch(value.trim());
    if (match == null) return null;
    return AppReleaseVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
      build ?? int.tryParse(match[4] ?? match[5] ?? '') ?? 0,
    );
  }

  String get name => '$major.$minor.$patch';
  String get full => '$name+$build';
  String get display => build > 0 ? full : name;
  @override
  int compareTo(AppReleaseVersion other) {
    final a = [major, minor, patch, build],
        b = [other.major, other.minor, other.patch, other.build];
    for (var i = 0; i < a.length; i++) {
      final difference = a[i].compareTo(b[i]);
      if (difference != 0) return difference;
    }
    return 0;
  }
}

class PlatformUpdate {
  const PlatformUpdate({
    required this.platform,
    required this.version,
    required this.assetName,
    required this.downloadUrl,
    required this.releaseUrl,
    required this.size,
  });
  final UpdatePlatform platform;
  final AppReleaseVersion version;
  final String assetName, downloadUrl, releaseUrl;
  final int size;
  String get notificationKey => '${platform.name}/${version.full}';
  Map<String, dynamic> toJson() => {
    'platform': platform.name,
    'version': version.name,
    'build': version.build,
    'asset': assetName,
    'downloadUrl': downloadUrl,
    'releaseUrl': releaseUrl,
    'size': size,
  };
}

typedef UpdateManifestLoader = Future<Map<String, dynamic>> Function(
  String url,
);

abstract interface class UpdateFeed {
  Future<List<Map<String, dynamic>>> releases();
  Future<Map<String, dynamic>> manifest(String url);
  void close();
}

bool _uploaded(Map<String, dynamic> asset) =>
    asset['state'] == 'uploaded' &&
    (asset['size'] as num? ?? 0) > 0 &&
    (asset['browser_download_url'] as String? ?? '').startsWith('https://');

bool _compatible(String name, UpdatePlatform platform, String architecture) {
  final lower = name.toLowerCase();
  switch (platform) {
    case UpdatePlatform.windows:
      if (!(lower.endsWith('.exe') ||
          lower.endsWith('.msi') ||
          lower.endsWith('.zip') && lower.contains('windows')))
        return false;
      if (lower.contains('arm64')) return architecture == 'arm64';
      if (lower.contains('x64') || lower.contains('x86_64'))
        return architecture == 'x64';
      return true;
    case UpdatePlatform.android:
      if (!lower.endsWith('.apk')) return false;
      if (lower.contains('arm64') || lower.contains('v8a'))
        return architecture == 'arm64-v8a';
      if (lower.contains('armeabi') || lower.contains('armv7'))
        return architecture == 'armeabi-v7a';
      if (lower.contains('x86_64') || lower.contains('x64'))
        return architecture == 'x86_64';
      if (lower.contains('x86')) return architecture == 'x86';
      return true; // An ABI-independent APK is a universal package.
    case UpdatePlatform.ios:
      return lower.endsWith('.ipa') && !lower.contains('simulator');
  }
}

/// Select actual downloadable platform assets, not a repository-wide "latest"
/// release. iPhone and iPad intentionally use the same physical-device IPA lane.
Future<PlatformUpdate?> selectPlatformUpdate({
  required List<Map<String, dynamic>> releases,
  required UpdatePlatform platform,
  required AppReleaseVersion installed,
  required UpdateManifestLoader loadManifest,
  String architecture = '',
}) async {
  PlatformUpdate? best;
  for (final release in releases) {
    if (release['draft'] == true || release['prerelease'] == true) continue;
    final assets = List<Map<String, dynamic>>.from(
      release['assets'] ?? const [],
    ).where(_uploaded).toList();
    final packages = assets
        .where((asset) => _compatible(asset['name'], platform, architecture))
        .toList();
    if (packages.isEmpty) continue;
    final metadata = assets
        .where(
          (asset) => asset['name'] == 'globalsend-update-${platform.name}.json',
        )
        .firstOrNull;
    if (metadata != null) {
      final manifest = await loadManifest(metadata['browser_download_url']);
      if (manifest['schema'] != 1 || manifest['platform'] != platform.name)
        continue;
      final version = AppReleaseVersion.parse(
        manifest['version'] as String? ?? '',
        build: manifest['build'] as int?,
      );
      final names = List<String>.from(
        manifest['assets'] ??
            [if (manifest['asset'] is String) manifest['asset']],
      );
      final package = packages
          .where((asset) => names.contains(asset['name']))
          .firstOrNull;
      if (version == null ||
          package == null ||
          version.compareTo(installed) <= 0)
        continue;
      if (best == null || version.compareTo(best.version) > 0) {
        best = _offer(platform, version, package, release);
      }
    } else {
      // Older releases remain usable without inventing a new manifest contract.
      // Versioned filenames win over a global tag; this also handles mixed
      // platform versions in a release. A manifest carries same-version builds.
      for (final package in packages) {
        final filename = RegExp(
          r'globalsend[-_](v?\d+\.\d+\.\d+(?:\+\d+|-build\d+)?)',
          caseSensitive: false,
        ).firstMatch(package['name']);
        final version = AppReleaseVersion.parse(
          filename?[1] ?? release['tag_name'] as String? ?? '',
        );
        if (version == null || version.compareTo(installed) <= 0) continue;
        if (best == null || version.compareTo(best.version) > 0) {
          best = _offer(platform, version, package, release);
        }
      }
    }
  }
  return best;
}

PlatformUpdate _offer(
  UpdatePlatform platform,
  AppReleaseVersion version,
  Map<String, dynamic> asset,
  Map<String, dynamic> release,
) => PlatformUpdate(
  platform: platform,
  version: version,
  assetName: asset['name'],
  downloadUrl: asset['browser_download_url'],
  releaseUrl: release['html_url'],
  size: (asset['size'] as num).toInt(),
);

/// Public GitHub API only: no embedded account token and no installer proxying
/// through the user's center. ETags also revalidate replacement metadata assets
/// published under the same release tag and download URL.
class GitHubUpdateFeed implements UpdateFeed {
  GitHubUpdateFeed({HttpClient? client}) : client = client ?? HttpClient() {
    this.client.connectionTimeout = const Duration(seconds: 8);
    this.client.findProxy = HttpClient.findProxyFromEnvironment;
  }
  final HttpClient client;
  static const repository = 'DongLanQwQ0/GlobalSend';
  final _responses = <String, ({String? etag, Object value})>{};

  Future<Object> _json(String url) async {
    final cached = _responses[url];
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'GlobalSend update checker',
    );
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    if (cached?.etag != null)
      request.headers.set(HttpHeaders.ifNoneMatchHeader, cached!.etag!);
    final response = await request.close();
    if (response.statusCode == HttpStatus.notModified && cached != null) {
      await response.drain<void>();
      return cached.value;
    }
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok)
      throw HttpException('GitHub HTTP ${response.statusCode}');
    final value = jsonDecode(body) as Object;
    _responses[url] = (
      etag: response.headers.value(HttpHeaders.etagHeader),
      value: value,
    );
    return value;
  }

  Future<List<Map<String, dynamic>>> releases() async {
    final result = <Map<String, dynamic>>[];
    for (var page = 1; ; page++) {
      final value = await _json(
        'https://api.github.com/repos/$repository/releases?per_page=100&page=$page',
      ).timeout(const Duration(seconds: 12));
      final rows = List<Map<String, dynamic>>.from(value as List);
      result.addAll(rows);
      if (rows.length < 100) return result;
    }
  }

  Future<Map<String, dynamic>> manifest(String url) async =>
      Map<String, dynamic>.from(
        await _json(url).timeout(const Duration(seconds: 12)) as Map,
      );
  void close() => client.close(force: true);
}
