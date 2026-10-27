import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late PlatformVault vault;
  setUp(() async {
    final parent = Directory('../artifacts/client/build/vault-tests');
    await parent.create(recursive: true);
    root = await parent.createTemp('synthetic-');
    vault = PlatformVault(directory: () async => root);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(PlatformVault.channel, null);
    await root.delete(recursive: true);
  });

  test(
    'reading a read-only native credential buffer succeeds without mutating it',
    () async {
      final file = await vault.file('read-only');
      await file.writeAsBytes([7, 8]);
      final bytes = Uint8List.fromList(utf8.encode('public fixture token'));
      final envelope = const StandardMethodCodec()
          .encodeSuccessEnvelope(bytes)
          .asUnmodifiableView();
      messenger.setMockMessageHandler(PlatformVault.channel.name, (
        message,
      ) async {
        expect(
          const StandardMethodCodec().decodeMethodCall(message!).method,
          'unseal',
        );
        return envelope;
      });
      expect(await vault.read(key: 'read-only'), 'public fixture token');
      expect(const StandardMethodCodec().decodeEnvelope(envelope), bytes);
      expect(await file.readAsBytes(), [7, 8]);
    },
  );

  test('invalid read-only credential data preserves the format error instead of a cleanup error', () async {
    final file = await vault.file('read-only-invalid');
    await file.writeAsBytes([9, 10]);
    final envelope = const StandardMethodCodec()
        .encodeSuccessEnvelope(Uint8List.fromList([255]))
        .asUnmodifiableView();
    messenger.setMockMessageHandler(
      PlatformVault.channel.name,
      (_) async => envelope,
    );
    await expectLater(
      vault.read(key: 'read-only-invalid'),
      throwsA(
        isA<VaultException>().having(
          (error) => error.code,
          'code',
          'VAULT_FORMAT_FAILED',
        ),
      ),
    );
    expect(await file.readAsBytes(), [9, 10]);
  });

  test('missing credential is distinct from a failed unlock and never invokes unseal', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(PlatformVault.channel, (_) async {
      calls++;
      return null;
    });
    expect(await vault.read(key: 'missing'), isNull);
    expect(calls, 0);
    final file = await vault.file('existing');
    await file.writeAsBytes([1, 2, 3]);
    messenger.setMockMethodCallHandler(PlatformVault.channel, (call) async {
      expect(call.method, 'unseal');
      throw PlatformException(
        code: 'VAULT_UNSEAL_FAILED',
        message: 'native detail must not appear in UI',
        details: {'operation': 'unseal', 'windowsError': 2148073483},
      );
    });
    await expectLater(
      vault.read(key: 'existing'),
      throwsA(
        isA<VaultException>()
            .having((e) => e.operation, 'operation', 'read')
            .having((e) => e.windowsError, 'Windows error', 0x8009000b)
            .having(
              (e) => e.diagnostic,
              'safe diagnostic',
              'VAULT_UNSEAL_FAILED / 0x8009000B',
            )
            .having(
              (e) => e.toString(),
              'actionable UI',
              contains('重试或选择重新入组'),
            ),
      ),
    );
    expect(await file.readAsBytes(), [1, 2, 3]);
  });

  test('seal failure retains the exact previous protected file', () async {
    final file = await vault.file('retained');
    await file.writeAsBytes([7, 8, 9]);
    messenger.setMockMethodCallHandler(PlatformVault.channel, (_) async {
      throw PlatformException(
        code: 'VAULT_SEAL_FAILED',
        details: {'windowsError': 5},
      );
    });
    await expectLater(
      vault.write(key: 'retained', value: 'public test fixture'),
      throwsA(
        isA<VaultException>().having((e) => e.operation, 'operation', 'write'),
      ),
    );
    expect(await file.readAsBytes(), [7, 8, 9]);
    expect((await file.parent.list().toList()).length, 1);
  });

  test('same-path writes serialize across vault instances and replace only with protected bytes', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    var calls = 0;
    messenger.setMockMethodCallHandler(PlatformVault.channel, (call) async {
      expect(call.method, 'seal');
      final number = ++calls;
      if (number == 1) {
        entered.complete();
        await gate.future;
      }
      return Uint8List.fromList([99, number]);
    });
    final first = vault.write(key: 'serial', value: 'first public fixture');
    await entered.future;
    final other = PlatformVault(directory: () async => root);
    final second = other.write(key: 'serial', value: 'second public fixture');
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    gate.complete();
    await Future.wait([first, second]);
    expect(await (await vault.file('serial')).readAsBytes(), [99, 2]);
    expect(
      (await (await vault.file('serial')).parent.list().toList()).length,
      1,
    );
  });

  test('backup copies protected files only and never calls unseal', () async {
    final file = await vault.file('backup');
    await file.writeAsBytes([55, 66]);
    await File('${file.parent.path}/incomplete.tmp').writeAsBytes([1]);
    messenger.setMockMethodCallHandler(PlatformVault.channel, (_) async {
      fail('backup must not decrypt');
    });
    final backup = Directory('${root.path}/recovery/vault');
    await vault.backupProtectedFiles(backup);
    final saved = await backup.list().toList();
    expect(saved, hasLength(1));
    expect(await (saved.single as File).readAsBytes(), [55, 66]);
    expect(await file.readAsBytes(), [55, 66]);
  });

  test('invalid decoded content is an explicit preserved-credential format failure', () async {
    final file = await vault.file('bad-format');
    await file.writeAsBytes([9, 10]);
    messenger.setMockMethodCallHandler(
      PlatformVault.channel,
      (_) async => Uint8List.fromList([255]),
    );
    await expectLater(
      vault.read(key: 'bad-format'),
      throwsA(
        isA<VaultException>().having(
          (e) => e.code,
          'code',
          'VAULT_FORMAT_FAILED',
        ),
      ),
    );
    expect(await file.readAsBytes(), [9, 10]);
  });
}
