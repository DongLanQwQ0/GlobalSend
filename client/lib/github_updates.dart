import 'dart:convert';
import 'dart:io';

import 'network_proxy.dart';

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
    this.assetApiUrl = '',
  });
  final UpdatePlatform platform;
  final AppReleaseVersion version;
  final String assetName, downloadUrl, releaseUrl, assetApiUrl;
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
    if (assetApiUrl.isNotEmpty) 'assetApiUrl': assetApiUrl,
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
  Object? manifestFailure;
  StackTrace? manifestFailureStack;
  final candidates =
      <
        ({
          Map<String, dynamic> release,
          List<Map<String, dynamic>> packages,
          Map<String, dynamic>? metadata,
          AppReleaseVersion? namedVersion,
          AppReleaseVersion? hint,
        })
      >[];
  for (final release in releases) {
    if (release['draft'] == true || release['prerelease'] == true) continue;
    final assets = List<Map<String, dynamic>>.from(
      release['assets'] ?? const [],
    ).where(_uploaded).toList();
    final packages = assets
        .where((asset) => _compatible(asset['name'], platform, architecture))
        .toList();
    if (platform == UpdatePlatform.windows) {
      packages.sort(
        (a, b) => (a['name'] as String).toLowerCase().endsWith('.zip')
            ? (b['name'] as String).toLowerCase().endsWith('.zip')
                  ? 0
                  : -1
            : (b['name'] as String).toLowerCase().endsWith('.zip')
            ? 1
            : 0,
      );
    }
    if (packages.isEmpty) continue;
    final metadata = assets
        .where(
          (asset) => asset['name'] == 'globalsend-update-${platform.name}.json',
        )
        .firstOrNull;
    final namedVersions = packages
        .map((asset) => _filenameVersion(asset['name']))
        .toList();
    final namedVersion = namedVersions.every((version) => version != null)
        ? (namedVersions.whereType<AppReleaseVersion>().toList()..sort()).last
        : null;
    candidates.add((
      release: release,
      packages: packages,
      metadata: metadata,
      namedVersion: namedVersion,
      hint:
          namedVersion ??
          AppReleaseVersion.parse(release['tag_name'] as String? ?? ''),
    ));
  }
  candidates.sort(
    (a, b) => b.hint == null
        ? a.hint == null
              ? 0
              : -1
        : a.hint == null
        ? 1
        : b.hint!.compareTo(a.hint!),
  );
  for (final candidate in candidates) {
    final (:release, :packages, :metadata, :namedVersion, hint: _) = candidate;
    final floor = best?.version ?? installed;
    // Explicit platform filenames rule out older semantic versions, not tags:
    // a mixed release can carry a different platform version. Same-version
    // builds still require its authoritative manifest.
    if (namedVersion != null &&
        _semanticVersion(namedVersion).compareTo(_semanticVersion(floor)) < 0)
      continue;
    if (metadata != null) {
      try {
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
      } catch (failure, stack) {
        // One historical asset's outage must not discard another valid offer.
        manifestFailure ??= failure;
        manifestFailureStack ??= stack;
      }
    } else {
      // Older releases remain usable without inventing a new manifest contract.
      // Versioned filenames win over a global tag; this also handles mixed
      // platform versions in a release. A manifest carries same-version builds.
      for (final package in packages) {
        final version =
            _filenameVersion(package['name']) ??
            AppReleaseVersion.parse(release['tag_name'] as String? ?? '');
        if (version == null || version.compareTo(installed) <= 0) continue;
        if (best == null || version.compareTo(best.version) > 0) {
          best = _offer(platform, version, package, release);
        }
      }
    }
  }
  if (best == null && manifestFailure != null) {
    Error.throwWithStackTrace(manifestFailure, manifestFailureStack!);
  }
  return best;
}

AppReleaseVersion _semanticVersion(AppReleaseVersion value) =>
    AppReleaseVersion(value.major, value.minor, value.patch);
AppReleaseVersion? _filenameVersion(String name) => AppReleaseVersion.parse(
  RegExp(
        r'globalsend[-_](v?\d+\.\d+\.\d+(?:\+\d+|-build\d+)?)',
        caseSensitive: false,
      ).firstMatch(name)?[1] ??
      '',
);

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
  assetApiUrl: asset['url'] as String? ?? '',
);

/// Public GitHub API only: no embedded account token and no installer proxying
/// through the user's center. ETags also revalidate replacement metadata assets
/// published under the same release tag and download URL.
class GitHubUpdateFeed implements UpdateFeed {
  GitHubUpdateFeed({HttpClient? client})
    : client = client ?? NetworkProxy.client() {
    this.client.connectionTimeout = const Duration(seconds: 8);
  }
  final HttpClient client;
  static const repository = 'DongLanQwQ0/GlobalSend';
  final _responses = <String, ({String? etag, Object value})>{};
  final _assetUrls = <String, String>{};

  Future<Object> _json(String url, {bool asset = false}) async {
    final cached = _responses[url];
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'GlobalSend update checker',
    );
    request.headers.set(
      HttpHeaders.acceptHeader,
      asset ? 'application/octet-stream' : 'application/vnd.github+json',
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
      for (final release in rows) {
        for (final asset in List<Map<String, dynamic>>.from(
          release['assets'] ?? const [],
        )) {
          if (asset['url'] is String &&
              asset['browser_download_url'] is String) {
            _assetUrls[asset['browser_download_url']] = asset['url'];
          }
        }
      }
      if (rows.length < 100) return result;
    }
  }

  Future<Map<String, dynamic>> manifest(String url) async =>
      Map<String, dynamic>.from(
        await _json(
          _assetUrls[url] ?? url,
          asset: _assetUrls.containsKey(url),
        ).timeout(const Duration(seconds: 12)) as Map,
      );
  void close() => client.close(force: true);
}
