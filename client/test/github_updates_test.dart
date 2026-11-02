import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/github_updates.dart';

Map<String, dynamic> asset(
  String name, {
  int size = 100,
  String state = 'uploaded',
}) => {
  'name': name,
  'state': state,
  'size': size,
  'browser_download_url': 'https://github.com/download/$name',
};
Map<String, dynamic> release(
  String tag,
  List<Map<String, dynamic>> assets, {
  bool draft = false,
  bool prerelease = false,
}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/release/$tag',
  'assets': assets,
  'draft': draft,
  'prerelease': prerelease,
};
Future<PlatformUpdate?> select(
  List<Map<String, dynamic>> rows,
  UpdatePlatform platform, {
  String installed = '1.0.20+20',
  String arch = 'arm64-v8a',
  Map<String, Map<String, dynamic>> manifests = const {},
}) => selectPlatformUpdate(
  releases: rows,
  platform: platform,
  installed: AppReleaseVersion.parse(installed)!,
  architecture: arch,
  loadManifest: (url) async => manifests[url.split('/').last]!,
);
void main() {
  test('loads the newest platform manifest without requesting clearly older packages', () async {
    final calls = <String>[];
    final rows = [
      release('v1.0.20', [
        asset('GlobalSend-1.0.20-windows-x64.zip'),
        asset('globalsend-update-windows.json'),
      ]),
      release('v1.0.80', [
        asset('GlobalSend-1.0.80-windows-x64.zip'),
        {
          ...asset('globalsend-update-windows.json'),
          'browser_download_url': 'https://github.com/latest-manifest',
        },
      ]),
    ];
    final result = await selectPlatformUpdate(
      releases: rows,
      platform: UpdatePlatform.windows,
      architecture: 'x64',
      installed: const AppReleaseVersion(1, 0, 79, 103),
      loadManifest: (url) async {
        calls.add(url);
        if (url != 'https://github.com/latest-manifest')
          throw StateError('old manifest must not be fetched');
        return {
          'schema': 1,
          'platform': 'windows',
          'version': '1.0.80',
          'build': 104,
          'assets': ['GlobalSend-1.0.80-windows-x64.zip'],
        };
      },
    );
    expect(result!.version.full, '1.0.80+104');
    expect(calls, ['https://github.com/latest-manifest']);
  });
  test('an independent manifest failure neither erases a valid offer nor masquerades as no updates', () async {
    final valid = release('v1.0.80', [
      asset('GlobalSend-1.0.80-windows-x64.zip'),
      {
        ...asset('globalsend-update-windows.json'),
        'browser_download_url': 'https://github.com/valid',
      },
    ]);
    final broken = release('v1.0.10', [
      asset('GlobalSend-windows.zip'),
      {
        ...asset('globalsend-update-windows.json'),
        'browser_download_url': 'https://github.com/broken',
      },
    ]);
    final failure = StateError('asset unavailable');
    Future<Map<String, dynamic>> load(String url) async {
      if (url.endsWith('broken')) throw failure;
      return {
        'schema': 1,
        'platform': 'windows',
        'version': '1.0.80',
        'build': 104,
        'assets': ['GlobalSend-1.0.80-windows-x64.zip'],
      };
    }

    final result = await selectPlatformUpdate(
      releases: [broken, valid],
      platform: UpdatePlatform.windows,
      architecture: 'x64',
      installed: const AppReleaseVersion(1, 0, 79, 103),
      loadManifest: load,
    );
    expect(result!.version.full, '1.0.80+104');
    await expectLater(
      selectPlatformUpdate(
        releases: [broken],
        platform: UpdatePlatform.windows,
        architecture: 'x64',
        installed: const AppReleaseVersion(1, 0, 79, 103),
        loadManifest: load,
      ),
      throwsA(same(failure)),
    );
  });
  test(
    'an old mixed tag does not exclude a newer unversioned platform manifest',
    () async {
      final result = await select(
        [
          release('v1.0.10', [
            asset('GlobalSend-iPad-unsigned.ipa'),
            asset('globalsend-update-ios.json'),
          ]),
        ],
        UpdatePlatform.ios,
        installed: '1.0.79+103',
        manifests: {
          'globalsend-update-ios.json': {
            'schema': 1,
            'platform': 'ios',
            'version': '1.0.80',
            'build': 104,
            'assets': ['GlobalSend-iPad-unsigned.ipa'],
          },
        },
      );
      expect(result!.version.full, '1.0.80+104');
    },
  );
  test(
    'download asset API is retained separately from the browser download link',
    () async {
      final result = await select(
        [
          release('v1.0.80', [
            {
              ...asset('GlobalSend-1.0.80-windows-x64.zip'),
              'url': 'https://api.github.com/repos/test/releases/assets/42',
            },
          ]),
        ],
        UpdatePlatform.windows,
        arch: 'x64',
      );
      expect(result!.downloadUrl, startsWith('https://github.com/'));
      expect(
        result.assetApiUrl,
        'https://api.github.com/repos/test/releases/assets/42',
      );
      expect(result.toJson()['assetApiUrl'], result.assetApiUrl);
    },
  );
  test('Windows prefers a complete ZIP over an installer in the same platform release', () async {
    final result = await select(
      [
        release('v1.0.30', [
          asset('GlobalSend-1.0.30-windows-x64.exe'),
          asset('GlobalSend-1.0.30-windows-x64.zip'),
        ]),
      ],
      UpdatePlatform.windows,
      arch: 'x64',
    );
    expect(result!.assetName, endsWith('.zip'));
  });
  test('version compares numeric semver and same-version build', () {
    expect(
      AppReleaseVersion.parse('1.0.10')!
          .compareTo(AppReleaseVersion.parse('v1.0.9')!),
      greaterThan(0),
    );
    expect(
      AppReleaseVersion.parse('1.0.26+36')!
          .compareTo(AppReleaseVersion.parse('1.0.26+35')!),
      greaterThan(0),
    );
    expect(AppReleaseVersion.parse('preview'), isNull);
  });
  test(
    'a Windows-only release never notifies Android or iPhone/iPad',
    () async {
      final rows = [
        release('v2.0.0', [asset('GlobalSend-2.0.0-windows-x64.zip')]),
      ];
      expect(await select(rows, UpdatePlatform.android), isNull);
      expect(await select(rows, UpdatePlatform.ios), isNull);
      expect(
        (await select(rows, UpdatePlatform.windows, arch: 'x64'))!.version.name,
        '2.0.0',
      );
    },
  );
  test('a newer unrelated release does not hide an older compatible platform asset', () async {
    final rows = [
      release('v1.0.30', [asset('GlobalSend-1.0.30-windows-x64.zip')]),
      release('v1.0.23', [asset('GlobalSend-1.0.23-android-arm64-v8a.apk')]),
    ];
    expect(
      (await select(rows, UpdatePlatform.android))!.version.name,
      '1.0.23',
    );
  });
  test('draft, prerelease, incomplete, empty and wrong ABI packages are not updates', () async {
    final rows = [
      release('v1.0.30', [asset('GlobalSend-1.0.30.apk')], draft: true),
      release('v1.0.30', [asset('GlobalSend-1.0.30.apk')], prerelease: true),
      release('v1.0.30', [asset('GlobalSend-1.0.30.apk', state: 'new')]),
      release('v1.0.30', [asset('GlobalSend-1.0.30.apk', size: 0)]),
      release('v1.0.30', [asset('GlobalSend-1.0.30-android-x86_64.apk')]),
    ];
    expect(await select(rows, UpdatePlatform.android), isNull);
    expect(
      await select([
        release('v1.0.30', [asset('GlobalSend-1.0.30-simulator.ipa')]),
      ], UpdatePlatform.ios),
      isNull,
    );
  });
  test(
    'mixed releases compare actual per-platform versions, not the release tag',
    () async {
      final rows = [
        release('v1.0.26', [
          asset('GlobalSend-1.0.26-windows-x64.zip'),
          asset('GlobalSend-1.0.23-android-arm64-v8a.apk'),
          asset('GlobalSend-iPad-unsigned.ipa'),
          asset('globalsend-update-ios.json'),
        ]),
      ];
      expect(
        await select(rows, UpdatePlatform.android, installed: '1.0.24+33'),
        isNull,
      );
      final ipa = await select(
        rows,
        UpdatePlatform.ios,
        installed: '1.0.23+32',
        manifests: {
          'globalsend-update-ios.json': {
            'schema': 1,
            'platform': 'ios',
            'version': '1.0.24',
            'build': 33,
            'assets': ['GlobalSend-iPad-unsigned.ipa'],
          },
        },
      );
      expect(ipa!.version.full, '1.0.24+33');
      expect(ipa.assetName, 'GlobalSend-iPad-unsigned.ipa');
    },
  );
  test(
    'same-version builds require an uploaded matching manifest asset',
    () async {
      final rows = [
        release('v1.0.26', [
          asset('GlobalSend-1.0.26-windows-x64.zip'),
          asset('globalsend-update-windows.json'),
        ]),
      ];
      final metadata = {
        'schema': 1,
        'platform': 'windows',
        'version': '1.0.26',
        'build': 36,
        'assets': ['GlobalSend-1.0.26-windows-x64.zip'],
      };
      expect(
        (await select(
          rows,
          UpdatePlatform.windows,
          arch: 'x64',
          installed: '1.0.26+35',
          manifests: {'globalsend-update-windows.json': metadata},
        ))!.version.build,
        36,
      );
      expect(
        await select(
          rows,
          UpdatePlatform.windows,
          arch: 'x64',
          installed: '1.0.26+36',
          manifests: {'globalsend-update-windows.json': metadata},
        ),
        isNull,
      );
      expect(
        await select(
          rows,
          UpdatePlatform.windows,
          arch: 'x64',
          manifests: {
            'globalsend-update-windows.json': {
              ...metadata,
              'assets': ['not-uploaded.zip'],
            },
          },
        ),
        isNull,
      );
    },
  );
}
