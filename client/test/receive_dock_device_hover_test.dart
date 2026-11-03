import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receive_dock_window.dart';
import 'package:globalsend/system_bridge.dart';

import 'receive_dock_window_test.dart' show payload;
import 'windows_recommendation_drag_test.dart' show RecommendationController;
import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> hover(
    WidgetTester tester,
    bool active, {
    double x = 70,
    String target = '',
  }) async {
    await messenger.handlePlatformMessage(
      ReceiveDockApp.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('dropHover', {
          'active': active,
          'x': x,
          'y': 80.0,
          'targetDeviceId': target,
        }),
      ),
      (_) {},
    );
    await tester.pump();
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(ReceiveDockApp.channel, null);
    messenger.setMockMethodCallHandler(SystemBridge.channel, null);
  });
  testWidgets(
    'one second dwell and exit grace repeat, cancel on reentry and publish scroll-aware device regions',
    (tester) async {
      tester.view.physicalSize = const Size(480, 184);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final geometry = <Map>[];
      final data = payload(1, ['original'])
        ..addAll({
          'serverKey': 'center',
          'devices': [
            for (var i = 0; i < 8; i++)
              {
                'deviceId': 'id-$i',
                'name': '设备 $i',
                'platform': i.isEven ? 'windows' : 'android',
              },
            {'deviceId': 'id-0', 'name': '重复设备', 'platform': 'android'},
          ],
        });
      final actions = <MethodCall>[];
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        if (call.method == 'ready') return data;
        actions.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'queueDropBounds')
          geometry.add(call.arguments as Map);
        return null;
      });
      final capture = GlobalKey();
      debugPrintSynchronously('before dock mount');
      await tester.pumpWidget(
        RepaintBoundary(key: capture, child: const ReceiveDockApp()),
      );
      debugPrintSynchronously('after dock first frame');
      await tester.pumpAndSettle();
      debugPrint('dock hover fixture mounted');
      await hover(tester, true);
      await tester.pump(const Duration(milliseconds: 900));
      await hover(tester, false);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('发送至设备'), findsNothing);
      await hover(tester, true);
      await tester.pump(const Duration(milliseconds: 999));
      expect(find.text('发送至设备'), findsNothing);
      await hover(tester, true, x: 75);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('发送至设备'), findsOneWidget);
      debugPrint('dock dwell threshold accepted');
      expect(geometry.last['enabled'], true);
      expect(geometry.last['serverKey'], 'center');
      final devices = geometry.last['devices'] as List;
      expect(devices.map((v) => v['deviceId']).toSet().length, devices.length);
      expect(devices.first['deviceId'], 'id-0');
      await hover(tester, true, target: 'id-0');
      await tester.pumpAndSettle();
      final selected = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('dock-device-id-0')),
      );
      expect(
        ((selected.decoration as BoxDecoration).border as Border).top.width,
        2,
      );
      await tester.runAsync(() async {
        debugPrint('capturing dock targets');
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final folder = Directory(
          '../artifacts/tmp/android-dock-hover89/windows',
        );
        await folder.create(recursive: true);
        await File('${folder.path}/device-mode.rgba')
            .writeAsBytes(bytes!.buffer.asUint8List());
        await File('${folder.path}/device-mode.json').writeAsString(
          jsonEncode({'width': image.width, 'height': image.height}),
        );
        image.dispose();
        debugPrint('dock target snapshot saved');
      });
      await hover(tester, true, x: 479);
      for (var i = 0; i < 35; i++)
        await tester.pump(const Duration(milliseconds: 16));
      final scroll = tester
          .widget<ListView>(find.byKey(const ValueKey('dock-device-strip')))
          .controller!;
      expect(scroll.offset, greaterThan(0));
      expect(
        actions.where((c) => c.method == 'action'),
        isEmpty,
      ); // Hover never sends.
      await hover(tester, false);
      await tester.pump(const Duration(milliseconds: 999));
      expect(find.text('发送至设备'), findsOneWidget);
      await hover(tester, true);
      await tester.pump(const Duration(milliseconds: 1100));
      expect(find.text('发送至设备'), findsOneWidget);
      await hover(tester, false);
      await tester.pump(const Duration(milliseconds: 600));
      await hover(
        tester,
        false,
      ); // Duplicate exits must not extend the deadline.
      await tester.pump(const Duration(milliseconds: 399));
      expect(find.text('发送至设备'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('发送至设备'), findsNothing);
      expect(geometry.last['enabled'], false);
      expect(find.byKey(const ValueKey('dock-tile-original')), findsOneWidget);
      for (var cycle = 0; cycle < 2; cycle++) {
        await hover(tester, true);
        await tester.pump(const Duration(milliseconds: 999));
        expect(find.text('发送至设备'), findsNothing);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pumpAndSettle();
        expect(find.text('发送至设备'), findsOneWidget);
        await hover(tester, false);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.text('发送至设备'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'receiver direct drop uses primary controller and sends only the dropped batch',
    (tester) async {
      final c =
          RecommendationController(
              Directory('../artifacts/tmp/android-dock-hover89/host'),
            )
            ..profile = ServerProfile(
              baseUrl: 'https://fixture.invalid',
              instanceId: 'fixture',
              deviceId: 'self',
            )
            ..api = CenterApi('https://fixture.invalid', token: 'fixture')
            ..devices = [
              {'deviceId': 'self', 'name': '本机', 'online': true},
              {'deviceId': 'phone', 'name': '手机', 'online': true},
            ]
            ..connected = true;
      c.stagedTexts.add('保留草稿');
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'windowVisible') return true;
        return null;
      });
      await tester.pumpWidget(GlobalSendApp(controller: c));
      await tester.pumpAndSettle();
      await messenger.handlePlatformMessage(
        SystemBridge.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('receiveDockAction', {
            'action': 'dropToDevice',
            'dropId': 'receiver-fixture',
            'serverKey': c.profile!.key,
            'targetDeviceId': 'phone',
            'texts': ['实际投放的文本'],
            'paths': <String>[],
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(c.delivered.single['targets'], ['phone']);
      expect(c.delivered.single['texts'], ['实际投放的文本']);
      expect(c.stagedTexts, ['保留草稿']);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
