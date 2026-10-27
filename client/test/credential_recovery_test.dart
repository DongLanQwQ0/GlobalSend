import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/credential_recovery.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receive_destination.dart';
import 'package:globalsend/vault.dart';

class RecoveryController extends SendController {
  RecoveryController(Directory directory, PlatformVault vault)
    : super(
        vault: vault,
        stateDirectory: () async => directory,
        documentsDirectory: () async => directory,
      );
  int starts = 0;
  bool failCommit = false;
  Completer<void>? commitEntered, commitGate;
  final forwarded = <List<String>>[];
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> commitCredentialProfile(
    ServerProfile previous,
    ServerProfile recovered,
    Map<String, dynamic> state, {
    required bool Function() canCommit,
  }) async {
    commitEntered?.complete();
    await commitGate?.future;
    if (failCommit) {
      throw const FileSystemException('synthetic active-pointer write failure');
    }
    await super.commitCredentialProfile(
      previous,
      recovered,
      state,
      canCommit: canCommit,
    );
  }

  @override
  Future<void> offer(
    String target,
    List<String> paths, {
    String? routePreferenceOverride,
    Map<String, String>? displayNames,
  }) async {
    forwarded.add(paths);
  }
}

class BackupFailureVault extends PlatformVault {
  BackupFailureVault(Directory root) : super(directory: () async => root);
  @override
  Future<void> backupProtectedFiles(Directory destination) async {
    throw const FileSystemException('synthetic backup denied');
  }
}

class RestartIdentityVault extends PlatformVault {
  RestartIdentityVault(this.storageKey);
  final String storageKey;
  final reads = <String>[], writes = <String>[];
  @override
  Future<String?> read({required String key}) async {
    reads.add(key);
    if (key == 'token_$storageKey') return 'public-test-replacement-token';
    if (key.startsWith('peer_${storageKey}_')) return null;
    throw const VaultException(
      operation: 'read',
      code: 'OLD_IDENTITY_MUST_NOT_BE_READ',
    );
  }

  @override
  Future<void> write({required String key, required String value}) async {
    // Exercise real startPeer through fresh identity generation, but do not put
    // any generated private key on disk or bind a test listener.
    writes.add(key);
    throw StateError('synthetic stop after fresh identity generation');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late PlatformVault vault;
  late HttpServer server;
  late ServerProfile profile;
  late RecoveryController controller;
  late File protectedFile, localFile, retiredSource;
  var enrollments = 0, sealFails = false, unlockFails = true;
  setUp(() async {
    enrollments = 0;
    sealFails = false;
    unlockFails = true;
    final parent = Directory(
      '../artifacts/client/build/credential-recovery-tests',
    );
    await parent.create(recursive: true);
    root = await parent.createTemp('synthetic-');
    ReceiveDestination.registryDirectoryForTesting = () async =>
        Directory('${root.path}/registry');
    vault = PlatformVault(directory: () async => root);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('/devices/enroll')) {
        enrollments++;
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(body['groupKey'], 'public-test-group');
        request.response.write(
          jsonEncode({
            'device': {
              'deviceId': 'replacement-device',
              'groupId': 'replacement-group',
            },
            'groupId': 'replacement-group',
            'deviceToken': 'public-test-replacement-token',
          }),
        );
      } else {
        await request.drain<void>();
        request.response.write(
          jsonEncode({'protocolVersion': 1, 'instanceId': 'same-center'}),
        );
      }
      await request.response.close();
    });
    profile = ServerProfile(
      baseUrl: 'http://127.0.0.1:${server.port}',
      instanceId: 'same-center',
      deviceId: 'original-device',
      groupId: 'original-group',
      name: '原设备',
    );
    controller = RecoveryController(root, vault)
      ..root = root
      ..profile = profile;
    controller.profiles.add(profile);
    final savedDirectory = Directory(
      '${root.path}/GlobalSend/${profile.key}/${profile.deviceId}/old-file-id',
    );
    await savedDirectory.create(recursive: true);
    localFile = await File('${savedDirectory.path}/保留文件.txt')
        .writeAsBytes([10, 20]);
    retiredSource = await File('${root.path}/原临时源.bin').writeAsBytes([30, 40]);
    controller.dock = [
      DockEntry(
        id: 'old-text',
        kind: 'text',
        title: '文字',
        source: 'original-device',
        outgoing: true,
        text: '保留的原消息',
      ),
      DockEntry(
        id: 'old-file',
        kind: 'file',
        title: '保留文件.txt',
        source: 'peer',
        fileId: 'old-file-id',
        transferId: 'old-transfer-id',
        status: 'received',
        localPath: localFile.absolute.path,
        size: 2,
      ),
    ];
    controller.sources['old-outgoing-id'] = retiredSource.absolute.path;
    await controller.handleNativeDockEvent({
      'type': 'nativeDrop',
      'dropId': 'owned-old-source',
      'paths': [retiredSource.absolute.path],
      'temporaryPaths': [retiredSource.absolute.path],
    });
    controller.stagedFiles
        .clear(); // The old transfer, not a new batch, owns it.
    await controller.refreshSavedFiles();
    await controller.save();
    protectedFile = await vault.file('token_${profile.key}');
    await protectedFile.writeAsBytes([51, 52, 53]);
    await (await vault.file('peer_${profile.key}_${profile.deviceId}'))
        .writeAsBytes([61, 62]);
    messenger.setMockMethodCallHandler(PlatformVault.channel, (call) async {
      if (call.method == 'unseal') {
        if (unlockFails && (call.arguments as Uint8List).first != 71) {
          throw PlatformException(
            code: 'VAULT_UNSEAL_FAILED',
            details: {'windowsError': 0x8009000b},
          );
        }
        return Uint8List.fromList(utf8.encode('public-test-retained-token'));
      }
      if (sealFails) {
        throw PlatformException(
          code: 'VAULT_SEAL_FAILED',
          details: {'windowsError': 5},
        );
      }
      return Uint8List.fromList([71, 72, 73]);
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(PlatformVault.channel, null);
    for (final path in controller.stagedFiles.toList()) {
      await controller.removeStagedFile(path);
    }
    controller.dispose();
    await controller.save();
    await server.close(force: true);
    await root.delete(recursive: true);
    ReceiveDestination.registryDirectoryForTesting = null;
  });

  Future<void> blocked() async {
    await expectLater(
      controller.connect(profile.baseUrl, development: true),
      throwsA(isA<VaultException>()),
    );
  }

  test('unlock failure preserves original identity/history and retry never enrolls', () async {
    await blocked();
    expect(controller.api, isNull);
    expect(profile.deviceId, 'original-device');
    expect(controller.dock.map((e) => e.id), ['old-text', 'old-file']);
    expect(controller.connection, '登录凭据暂不可用');
    expect(controller.message, isNot(contains('PlatformException')));
    expect(enrollments, 0);
    unlockFails = false;
    await controller.connect(profile.baseUrl, development: true);
    expect(controller.credentialProblem, isNull);
    expect(profile.deviceId, 'original-device');
    expect(controller.starts, 1);
    expect(enrollments, 0);
    expect(await protectedFile.readAsBytes(), [51, 52, 53]);
  });

  test('explicit recovery snapshots ciphertext/history then switches identity and keeps file library forwardable', () async {
    await blocked();
    final originalSavedId = controller.savedFiles.single.id;
    await controller.recoverCredentialEnrollment('原设备', 'public-test-group');
    expect(enrollments, 1);
    expect(profile.deviceId, 'original-device');
    expect(controller.profile!.deviceId, 'replacement-device');
    expect(controller.profile!.groupId, 'replacement-group');
    expect(controller.profile!.storageKey, isNot(profile.storageKey));
    expect(controller.profile!.legacyPeerIdentity, isFalse);
    expect(controller.starts, 1);
    expect(controller.credentialProblem, isNull);
    expect(controller.dock, isEmpty);
    expect(controller.sources, isEmpty);
    expect(await localFile.readAsBytes(), [10, 20]);
    expect(await retiredSource.readAsBytes(), [30, 40]);
    final record = controller.credentialRecoveryRecords.single;
    expect(record.profile['deviceId'], 'original-device');
    final archived = await record.history();
    expect((archived['dock'] as List).map((e) => e['id']), [
      'old-text',
      'old-file',
    ]);
    expect(archived['sources']['old-outgoing-id'], retiredSource.absolute.path);
    final savedCipher = File(
      '${record.directory.path}/vault/${protectedFile.uri.pathSegments.last}',
    );
    expect(await savedCipher.readAsBytes(), [51, 52, 53]);
    expect(await protectedFile.readAsBytes(), [51, 52, 53]);
    expect(
      await (await vault.file('token_${controller.profile!.storageKey}'))
          .readAsBytes(),
      [71, 72, 73],
    );
    controller.devices.add({
      'deviceId': 'new-peer',
      'name': '新设备',
      'online': true,
    });
    expect(controller.forwarded, isEmpty);
    await controller.forwardSavedFiles('new-peer', [originalSavedId]);
    expect(controller.forwarded, [
      [localFile.absolute.path],
    ]);
    final committed = ServerProfile.fromJson(
      (jsonDecode(
        await File('${root.path}/profiles.json').readAsString(),
      ) as List).single,
    );
    final replacement = RecoveryController(root, vault)
      ..root = root
      ..profile = committed;
    replacement.profiles.add(committed);
    try {
      await replacement.connect(committed.baseUrl, development: true);
      expect(replacement.profile!.deviceId, 'replacement-device');
      expect(replacement.allowLegacyPeerIdentity, isFalse);
      expect(
        replacement.credentialRecoveryRecords.single.profile['deviceId'],
        'original-device',
      );
    } finally {
      replacement.dispose();
    }
  });

  test('failed pointer commit keeps old active profile, token and current history intact', () async {
    await blocked();
    final previousPointer = await File('${root.path}/profiles.json')
        .readAsBytes();
    final previousHistory = await File(
      '${root.path}/${profile.storageKey}.json',
    ).readAsBytes();
    controller.failCommit = true;
    await expectLater(
      controller.recoverCredentialEnrollment('原设备', 'public-test-group'),
      throwsA(isA<FileSystemException>()),
    );
    expect(identical(controller.profile, profile), isTrue);
    expect(profile.deviceId, 'original-device');
    expect(await protectedFile.readAsBytes(), [51, 52, 53]);
    expect(
      await File('${root.path}/profiles.json').readAsBytes(),
      previousPointer,
    );
    expect(
      await File('${root.path}/${profile.storageKey}.json').readAsBytes(),
      previousHistory,
    );
    expect(controller.dock, hasLength(2));
    expect(controller.starts, 0);
  });

  test('actual disk commit cancellation leaves the previous pointer and history while isolating prepared state', () async {
    await blocked();
    final oldPointer = await File('${root.path}/profiles.json').readAsBytes();
    final oldHistory = await File('${root.path}/${profile.storageKey}.json')
        .readAsBytes();
    final candidate = ServerProfile.fromJson({
      ...profile.toJson(),
      'storageId': 'synthetic-replacement',
      'deviceId': 'uncommitted-device',
      'legacyPeerIdentity': false,
    });
    await expectLater(
      CredentialRecoveryStore(root, vault).commitIdentity(
        storageKey: candidate.storageKey,
        state: {'dock': <dynamic>[]},
        profiles: [candidate.toJson()],
        canCommit: () => false,
      ),
      throwsStateError,
    );
    expect(await File('${root.path}/profiles.json').readAsBytes(), oldPointer);
    expect(
      await File('${root.path}/${profile.storageKey}.json').readAsBytes(),
      oldHistory,
    );
    expect(
      await File('${root.path}/${candidate.storageKey}.json').exists(),
      isTrue,
    );
    expect(await protectedFile.readAsBytes(), [51, 52, 53]);
  });

  test('save arriving during commit follows the committed replacement pointer, never the old identity', () async {
    await blocked();
    final oldHistory = await File('${root.path}/${profile.storageKey}.json')
        .readAsBytes();
    controller.commitEntered = Completer<void>();
    controller.commitGate = Completer<void>();
    final recovery = controller.recoverCredentialEnrollment(
      '原设备',
      'public-test-group',
    );
    await controller.commitEntered!.future;
    final queuedSave = controller.save();
    controller.commitGate!.complete();
    await recovery;
    await queuedSave;
    final committed = ServerProfile.fromJson(
      (jsonDecode(
        await File('${root.path}/profiles.json').readAsString(),
      ) as List).single,
    );
    expect(committed.deviceId, 'replacement-device');
    expect(committed.storageId, isNotEmpty);
    expect(committed.storageKey, controller.profile!.storageKey);
    expect(
      await File('${root.path}/${profile.storageKey}.json').readAsBytes(),
      oldHistory,
    );
    expect(
      (jsonDecode(
        await File('${root.path}/${committed.storageKey}.json').readAsString(),
      ) as Map)['dock'],
      isEmpty,
    );
  });

  test('restarted replacement identity does not read the old generic peer key even before its first peer key exists', () async {
    await blocked();
    await controller.recoverCredentialEnrollment('原设备', 'public-test-group');
    final committed = ServerProfile.fromJson(
      (jsonDecode(
        await File('${root.path}/profiles.json').readAsString(),
      ) as List).single,
    );
    final auditVault = RestartIdentityVault(committed.storageKey);
    final restarted = RecoveryController(root, auditVault)
      ..root = root
      ..profile = committed;
    restarted.profiles.add(committed);
    try {
      await restarted.connect(committed.baseUrl, development: true);
      restarted.info = {
        'features': {'direct': true},
      };
      await restarted.startPeer(); // The real identity-load/generation method.
      expect(auditVault.reads, [
        'token_${committed.storageKey}',
        'peer_${committed.storageKey}_${committed.deviceId}',
      ]);
      expect(auditVault.writes, [
        'peer_${committed.storageKey}_${committed.deviceId}',
      ]);
      expect(
        restarted.peerStatus,
        contains('synthetic stop after fresh identity generation'),
      );
      expect(enrollments, 1);
    } finally {
      restarted.dispose();
    }
  });

  test('failed new-token protection does not switch old identity or replace protected bytes', () async {
    await blocked();
    sealFails = true;
    await expectLater(
      controller.recoverCredentialEnrollment('原设备', 'public-test-group'),
      throwsA(isA<VaultException>()),
    );
    expect(enrollments, 1);
    expect(profile.deviceId, 'original-device');
    expect(controller.dock, hasLength(2));
    expect(controller.sources['old-outgoing-id'], retiredSource.absolute.path);
    expect(await protectedFile.readAsBytes(), [51, 52, 53]);
    expect(controller.credentialRecoveryRecords, hasLength(1));
    expect(controller.starts, 0);
  });

  test('existing enrollment also keeps its original local identity when credential protection fails', () async {
    await blocked();
    controller.api = CenterApi(
      profile.baseUrl,
      token: 'public-test-original-token',
    );
    sealFails = true;
    await expectLater(
      controller.adoptEnrollment({
        'device': {'deviceId': 'not-committed-device'},
        'groupId': 'other-group',
        'deviceToken': 'public-test-new-token',
      }, 'new name'),
      throwsA(isA<VaultException>()),
    );
    expect(profile.deviceId, 'original-device');
    expect(profile.groupId, 'original-group');
    expect(controller.api!.token, 'public-test-original-token');
    expect(controller.dock, hasLength(2));
    expect(await protectedFile.readAsBytes(), [51, 52, 53]);
  });

  test('invalid recovery password and backup failure never enroll or modify the old vault', () async {
    await blocked();
    await expectLater(
      controller.recoverCredentialEnrollment('原设备', 'short'),
      throwsFormatException,
    );
    expect(enrollments, 0);
    final other = RecoveryController(root, BackupFailureVault(root))
      ..root = root
      ..profile = profile
      ..credentialProblem = controller.credentialProblem;
    other.profiles.add(profile);
    try {
      await expectLater(
        other.recoverCredentialEnrollment('原设备', 'public-test-group'),
        throwsA(isA<FileSystemException>()),
      );
      expect(enrollments, 0);
      expect(profile.deviceId, 'original-device');
      expect(await protectedFile.readAsBytes(), [51, 52, 53]);
    } finally {
      other.dispose();
    }
  });
}
