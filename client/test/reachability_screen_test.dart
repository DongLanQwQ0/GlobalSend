import 'system_font_fixture.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/reachability.dart';
import 'package:globalsend/reachability_screen.dart';
import 'package:globalsend/ui_tokens.dart';

void main() {
  setUpAll(loadSystemTestFonts);
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'selected device opens and refreshes only its grouped measured paths, then Esc returns',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <String>[];
      final monitor =
          ReachabilityMonitor(
              stages: (values) async => (
                lan: values.where((v) => v.contains('192.168')).toList(),
                public: values.where((v) => !v.contains('192.168')).toList(),
              ),
              probe: (address, _, _) async {
                calls.add(address);
                return (
                  reachable: !address.contains('240e'),
                  elapsedMs: 7,
                  error: address.contains('240e')
                      ? 'SocketException: Network is unreachable'
                      : '',
                );
              },
              relayProbe: (_, _, _) async =>
                  (reachable: true, elapsedMs: 63, error: ''),
            )
            ..connected = true
            ..center = 'https://123.207.180.163/globalsend'
            ..devices = [
              {
                'deviceId': 'phone',
                'name': '我的手机',
                'platform': 'android',
                'peer': {
                  'certificateSha256': 'pin',
                  'candidates': [
                    'https://192.168.1.2:9443',
                    'https://8.8.8.8:9443',
                    'https://[240e:473:8a0:acd:58ae:9dff:fe61:c089]:9443',
                  ],
                },
              },
              {
                'deviceId': 'other',
                'name': '另一个设备',
                'peer': {
                  'certificateSha256': 'pin',
                  'candidates': ['https://10.0.0.99:9443'],
                },
              },
            ];
      addTearDown(monitor.dispose);
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RepaintBoundary(
                      key: capture,
                      child: ReachabilityScreen(
                        monitor: monitor,
                        deviceId: 'phone',
                        deviceName: '我的手机',
                      ),
                    ),
                  ),
                ),
                child: const Text('打开检测'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开检测'));
      await tester.pumpAndSettle();
      expect(calls, hasLength(3));
      expect(calls.any((v) => v.contains('10.0.0.99')), false);
      expect(find.text('另一个设备'), findsNothing);
      expect(find.text('源地址与目标地址 · 以实际检测为准'), findsOneWidget);
      final sections = ['局域网', '公网 IPv4', '公网 IPv6', '中继'];
      final offsets = sections
          .map((label) => tester.getTopLeft(find.text(label)).dy)
          .toList();
      expect(offsets, orderedEquals([...offsets]..sort()));
      expect(find.text('中心可达'), findsOneWidget);
      expect(find.text('仅验证中心可达，未验证目标接收'), findsOneWidget);
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../artifacts/screenshots/device-reachability-detail.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.ensureVisible(
        find.text('SocketException: Network is unreachable'),
      );
      await tester.pumpAndSettle();
      expect(find.text('失败'), findsOneWidget);
      expect(find.text('7 ms'), findsNWidgets(3));
      expect(
        find.textContaining(RegExp(r'\d{2}:\d{2}:\d{2}')),
        findsNWidgets(4),
      );
      await tester.tap(find.byKey(const ValueKey('refresh-reachability')));
      await tester.pumpAndSettle();
      expect(calls, hasLength(6));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('打开检测'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Web RTC results retain real time and unknown IP/direction instead of inventing direct reachability',
    (tester) async {
      final now = DateTime.now();
      final monitor =
          ReachabilityMonitor(
              relayProbe: (_, _, _) async =>
                  (reachable: true, elapsedMs: 12, error: ''),
            )
            ..connected = true
            ..center = 'https://center.invalid'
            ..devices = [
              {
                'deviceId': 'web',
                'name': '平板浏览器',
                'platform': 'web',
                'rtc': {
                  'scopes': ['lan', 'public'],
                },
              },
            ];
      monitor.setRtcResults('self', [
        {
          'initiatorDeviceId': 'web',
          'responderDeviceId': 'self',
          'scope': 'public',
          'success': true,
          'elapsedMs': 28,
          'checkedAt': now.toIso8601String(),
          'expiresAt': now.add(const Duration(minutes: 1)).toIso8601String(),
        },
      ]);
      addTearDown(monitor.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme(),
          home: ReachabilityScreen(
            monitor: monitor,
            deviceId: 'web',
            deviceName: '平板浏览器',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本机：未提供\n对方：未提供'), findsNWidgets(2));
      expect(find.text('公网 · RTC'), findsOneWidget);
      expect(find.text('28 ms'), findsOneWidget);
      expect(find.text('成功'), findsOneWidget);
      expect(find.text('未测'), findsOneWidget);
      expect(find.text('中心可达'), findsOneWidget);
      expect(find.text('源地址与目标地址 · 以实际检测为准'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'refresh includes RTC and displays selected endpoints in this device direction only after success',
    (tester) async {
      tester.view.physicalSize = const Size(600, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime.now();
      final monitor = ReachabilityMonitor()
        ..connected = true
        ..devices = [
          {
            'deviceId': 'phone',
            'name': '我的手机',
            'rtc': {
              'scopes': ['lan', 'public'],
            },
          },
        ];
      addTearDown(monitor.dispose);
      var refreshes = 0;
      final capture = GlobalKey();
      final theme = Ui.theme();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.copyWith(
            appBarTheme: theme.appBarTheme.copyWith(
              titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                fontFamily: 'Microsoft YaHei',
              ),
            ),
          ),
          home: RepaintBoundary(
            key: capture,
            child: ReachabilityScreen(
              monitor: monitor,
              deviceId: 'phone',
              onRefresh: () async {
                refreshes++;
                monitor.setRtcResults('self', [
                  for (final success in [true, false])
                    {
                      'initiatorDeviceId': 'phone',
                      'responderDeviceId': 'self',
                      'scope': success ? 'lan' : 'public',
                      'success': success,
                      'initiatorAddress': '[2001:db8::2]:6000',
                      'responderAddress': '[2001:db8::1]:5000',
                      'elapsedMs': 8,
                      'checkedAt': now.toIso8601String(),
                      'expiresAt': now
                          .add(const Duration(minutes: 2))
                          .toIso8601String(),
                    },
                ]);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(refreshes, 1);
      expect(
        find.text('[2001:db8::1]:5000 → [2001:db8::2]:6000'),
        findsOneWidget,
      );
      expect(
        find.text('本机：[2001:db8::1]:5000\n对方：[2001:db8::2]:6000'),
        findsOneWidget,
      );
      expect(find.text('失败'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('refresh-reachability')));
      await tester.pumpAndSettle();
      expect(refreshes, 2);
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../artifacts/screenshots/rtc-selected-endpoints.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an unfinished handshake is displayed as untested with no fabricated latency',
    (tester) async {
      final wait = Completer<ProbeResult>();
      final monitor =
          ReachabilityMonitor(
              stages: (values) async => (lan: values, public: <String>[]),
              probe: (_, _, _) => wait.future,
              relayProbe: (_, _, _) async =>
                  (reachable: true, elapsedMs: 2, error: ''),
            )
            ..connected = true
            ..center = 'https://center.invalid'
            ..devices = [
              {
                'deviceId': 'phone',
                'name': '手机',
                'peer': {
                  'candidates': ['https://10.0.0.2:8787'],
                  'certificateSha256': 'pin',
                },
              },
            ];
      addTearDown(monitor.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme(),
          home: ReachabilityScreen(monitor: monitor, deviceId: 'phone'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('未测'), findsNWidgets(2));
      expect(find.text('0 ms'), findsNothing);
      wait.complete((reachable: true, elapsedMs: 9, error: ''));
      await tester.pumpAndSettle();
      expect(find.text('9 ms'), findsOneWidget);
      expect(find.text('未测'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
