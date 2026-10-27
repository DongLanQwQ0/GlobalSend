import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

import 'receive_dock_host_test.dart' show DockHostController;
import 'system_font_fixture.dart';

class ProgressHostController extends DockHostController {
  final controls = <String>[];
  @override
  Future<void> accept(DockEntry item, bool yes) async => controls.add('accept');
  @override
  Future<void> receive(
    DockEntry item, {
    bool preferDirect = false,
    String? routeOverride,
  }) async => controls.add('receive');
  @override
  Future<void> retry(DockEntry item) async => controls.add('retry');
  @override
  Future<void> pause(DockEntry item) async => controls.add('pause');
  @override
  Future<void> resume(DockEntry item) async => controls.add('resume');
  @override
  Future<void> cancel(DockEntry item) async => controls.add('cancel');
  @override
  Future<void> approveRelay(DockEntry item) async =>
      controls.add('approveRelay');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> frame(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  for (final presentation in ['main', 'dock']) {
    testWidgets(
      'incoming host routes pre-byte progress to $presentation with unchanged serial and no focus activation',
      (tester) async {
        tester.view.physicalSize = const Size(950, 650);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = ProgressHostController();
        controller.profile = ServerProfile(
          baseUrl: 'https://fixture.invalid',
          instanceId: 'fixture',
          deviceId: 'self',
        );
        controller.api = CenterApi(
          'https://fixture.invalid',
          token: 'public-fixture',
        );
        controller.connected = true;
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
          calls.add(call);
          if (call.method == 'windowVisible') return true;
          if (call.method == 'presentReceiveDock') {
            return {
              'presentation': presentation,
              'arrivalGeneration': (call.arguments as Map)['serial'],
              'shown': true,
            };
          }
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
        );
        await tester.pumpWidget(GlobalSendApp(controller: controller));
        await frame(tester);
        final entry = DockEntry(
          id: 'early',
          kind: 'file',
          title: 'early.bin',
          source: 'phone',
          status: 'accepted',
          route: 'pending',
        );
        controller.dock.add(entry);
        controller.pendingReceipts[entry.id] = entry;
        controller.latestReceipt = entry;
        controller.receiptSerial = 1;
        controller.changed();
        await frame(tester);
        final first =
            calls
                    .lastWhere((call) => call.method == 'presentReceiveDock')
                    .arguments
                as Map;
        expect((first['items'] as List).single['status'], 'accepted');
        expect((first['items'] as List).single['localPath'], '');
        expect(controller.receiptPresentedExternally, presentation == 'dock');
        final flags = <bool>[];
        void observe() => flags.add(controller.receiptPresentedExternally);
        controller.addListener(observe);
        entry.status = 'downloading';
        entry.route = 'direct';
        entry.progress = .4;
        controller.changed();
        await frame(tester);
        controller.removeListener(observe);
        expect(flags, everyElement(presentation == 'dock'));
        final progress =
            calls
                    .lastWhere((call) => call.method == 'presentReceiveDock')
                    .arguments
                as Map;
        expect(progress['serial'], 1);
        expect((progress['items'] as List).single['id'], 'early');
        expect((progress['items'] as List).single['progress'], .4);
        if (presentation == 'main') expect(find.text('接收中 40%'), findsWidgets);
        expect(
          calls.where(
            (call) => [
              'activateWindow',
              'showReceivedWindow',
              'restoreWindow',
            ].contains(call.method),
          ),
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets(
    'dock transfer controls dispatch to the existing controller without activating main',
    (tester) async {
      final controller = ProgressHostController();
      final entry = DockEntry(
        id: 'control',
        kind: 'file',
        title: 'control.bin',
        source: 'phone',
        status: 'offered',
      );
      controller.dock.add(entry);
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        calls.add(call);
        if (call.method == 'windowVisible') return true;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      await tester.pumpWidget(GlobalSendApp(controller: controller));
      await frame(tester);
      for (final action in [
        'receive',
        'pause',
        'resume',
        'cancel',
        'retry',
        'approveRelay',
      ]) {
        await messenger.handlePlatformMessage(
          SystemBridge.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('receiveDockAction', {'action': action, 'id': entry.id}),
          ),
          (_) {},
        );
        await frame(tester);
      }
      expect(controller.controls, [
        'accept',
        'pause',
        'resume',
        'cancel',
        'retry',
        'approveRelay',
      ]);
      expect(calls.where((call) => call.method == 'activateWindow'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
