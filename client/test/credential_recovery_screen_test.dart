import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/credential_recovery.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/vault.dart';

class RecoveryUiController extends SendController {
  RecoveryUiController() {
    profile = ServerProfile(
      baseUrl: 'https://example.invalid',
      instanceId: 'fixture',
      deviceId: 'original-device',
      name: '原设备',
    );
    profiles.add(profile!);
    credentialProblem = const VaultException(
      operation: 'read',
      code: 'VAULT_UNSEAL_FAILED',
      windowsError: 0x8009000b,
    );
  }
  int retries = 0;
  final enrollments = <String>[];
  @override
  Future<void> init() async {}
  @override
  Future<String> systemDeviceName() async => '本机';
  @override
  Future<void> refreshGroupDevices() async {}
  @override
  Future<void> connect(String address, {bool development = false}) async {
    retries++;
  }

  @override
  Future<void> recoverCredentialEnrollment(String name, String groupKey) async {
    enrollments.add(groupKey);
    profile!.deviceId = 'replacement-device';
    credentialProblem = null;
    api = CenterApi('https://example.invalid', token: 'public-test-fixture');
    changed();
  }
}

class UiRecoveryRecord extends CredentialRecoveryRecord {
  UiRecoveryRecord()
    : super(Directory('unused-synthetic-history'), {
        'profileKey': 'fixture',
        'profile': {'name': '原设备'},
        'createdAt': '2026-10-26T08:00:00.000Z',
      });
  @override
  Future<Map<String, dynamic>> history() async => {
    'dock': [
      DockEntry(
        id: 'old-sent',
        kind: 'text',
        title: '文字',
        source: 'original-device',
        outgoing: true,
        text: '原消息完整保留，只读查看',
      ).toJson(),
    ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemBridge.channel,
          (call) async => call.method == 'windowVisible' ? true : null,
        );
  });
  setUpAll(() async {
    final font = FontLoader('GlobalSendSans');
    for (final weight in ['Regular', 'Semibold']) {
      font.addFont(
        Future.value(
          ByteData.sublistView(
            await File('assets/fonts/GlobalSendSans-$weight.ttf').readAsBytes(),
          ),
        ),
      );
    }
    await font.load();
    await (FontLoader('MaterialIcons')..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                'E:/Programs/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
              ).readAsBytes(),
            ),
          ),
        ))
        .load();
  });

  Future<void> show(
    WidgetTester tester,
    RecoveryUiController c,
    GlobalKey key,
  ) async {
    tester.view.physicalSize = const Size(950, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: GlobalSendApp(controller: c),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final target = File(
        '../artifacts/screenshots/vault-recovery-$name-1.0.11.png',
      );
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'recovery defaults to retry; enrollment requires explicit confirmation and a valid group password',
    (tester) async {
      final c = RecoveryUiController(), key = GlobalKey();
      await show(tester, c, key);
      expect(find.text('重试原身份'), findsOneWidget);
      expect(find.byKey(const ValueKey('group-password')), findsNothing);
      expect(find.textContaining('PlatformException'), findsNothing);
      expect(c.enrollments, isEmpty);
      await capture(tester, key, 'blocked-desktop');
      await tester.ensureVisible(find.byKey(const ValueKey('connect-primary')));
      await tester.tap(find.byKey(const ValueKey('connect-primary')));
      await tester.pumpAndSettle();
      expect(c.retries, 1);
      expect(c.enrollments, isEmpty);
      await tester.tap(find.byKey(const ValueKey('credential-reenroll')));
      await tester.pumpAndSettle();
      expect(find.text('创建新的设备身份，保留本机文件和旧记录。'), findsOneWidget);
      await capture(tester, key, 'confirm-desktop');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.enrollments, isEmpty);
      expect(c.profile!.deviceId, 'original-device');
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      await capture(tester, key, 'blocked-phone');
      await tester.ensureVisible(
        find.byKey(const ValueKey('credential-reenroll')),
      );
      await tester.tap(find.byKey(const ValueKey('credential-reenroll')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('credential-recovery-confirm')),
      );
      await tester.pumpAndSettle();
      expect(find.text('请输入 10–256 字符的组密码'), findsOneWidget);
      expect(c.enrollments, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('credential-recovery-password')),
        'public-test-group',
      );
      await tester.tap(
        find.byKey(const ValueKey('credential-recovery-confirm')),
      );
      await tester.pumpAndSettle();
      expect(c.enrollments, ['public-test-group']);
      expect(c.profile!.deviceId, 'replacement-device');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'old identity history remains reachable and opens messages read-only',
    (tester) async {
      final c = RecoveryUiController()
        ..credentialRecoveryRecords.add(UiRecoveryRecord());
      final key = GlobalKey();
      await show(tester, c, key);
      await tester.tap(find.byKey(const ValueKey('credential-history')));
      await tester.pumpAndSettle();
      expect(find.text('旧身份记录'), findsOneWidget);
      await tester.tap(find.text('原设备 · 只读'));
      await tester.pumpAndSettle();
      expect(find.text('原消息完整保留，只读查看'), findsOneWidget);
      await capture(tester, key, 'history-desktop');
      await tester.tap(find.text('原消息完整保留，只读查看'));
      await tester.pumpAndSettle();
      final content = find.byKey(const ValueKey('text-viewer-input'));
      expect(
        find.descendant(of: content, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: content, matching: find.byType(EditableText)),
        findsNothing,
      );
      expect(find.text('保存并同步'), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(c.enrollments, isEmpty);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
