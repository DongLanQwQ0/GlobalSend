import 'system_font_fixture.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/local_ip_addresses.dart';
import 'package:globalsend/local_ip_menu.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/ui_tokens.dart';

import 'widget_test.dart' show PreviewController;

class IpMenuController extends PreviewController {
  int addressReads = 0;
  @override
  Future<List<LocalIpAddress>> localIpAddresses() async {
    addressReads++;
    return addressesFromInterfaces([
      {
        'id': 'wlan0',
        'name': 'wlan0',
        'kind': 'Wi-Fi',
        'addresses': [
          '240e:473:8a0:acd:58ae:9dff:fe61:c089',
          'fd00::7',
          '8.8.8.8',
          '192.168.1.8',
        ],
      },
      {
        'id': 'tun0',
        'name': 'tun0',
        'kind': 'VPN',
        'addresses': ['198.18.0.1'],
      },
    ]);
  }
}

void main() {
  setUpAll(loadSystemTestFonts);
  TestWidgetsFlutterBinding.ensureInitialized();

  test('addresses sort in the requested four groups and numeric order', () {
    final addresses = sortLocalIpAddresses([
      '240e::2',
      '10.0.0.12',
      '8.8.8.8',
      'fd00::1',
      '10.0.0.2',
      '169.254.1.1',
      '100.100.1.2',
      '172.31.1.1',
      '172.32.1.1',
      '127.0.0.1',
      '::1',
      'fe80::1%25',
    ]);
    expect(
      addresses.map((entry) => entry.group.index),
      orderedEquals(
        [...addresses.map((entry) => entry.group.index)].toList()..sort(),
      ),
    );
    expect(
      addresses
          .where((entry) => entry.group == LocalIpGroup.ipv4Local)
          .map((entry) => entry.address),
      ['10.0.0.2', '10.0.0.12', '100.100.1.2', '169.254.1.1', '172.31.1.1'],
    );
    expect(
      addresses.singleWhere((entry) => entry.address == '172.32.1.1').group,
      LocalIpGroup.ipv4Public,
    );
    expect(
      addresses.singleWhere((entry) => entry.address == 'fe80::1%25').group,
      LocalIpGroup.ipv6Local,
    );
  });

  test('extracts plain IPs, preserves interface scope and deduplicates IPv6 spelling', () {
    final values = sortLocalIpAddresses([
      'https://192.168.1.5:8787/path',
      '192.168.1.5',
      'https://[240e::2]:8787',
      '240e:0:0:0:0:0:0:2',
      'fe80::1%wlan0',
      'https://[fe80::1%25wlan0]:8787',
      'example.com',
      '0.0.0.0',
      '::',
      '224.0.0.1',
      'ff02::1',
    ]);
    expect(values.map((entry) => entry.address), [
      '192.168.1.5',
      'fe80::1%wlan0',
      '240e::2',
    ]);
  });

  test('removes the whole loopback range including mapped and URL forms', () {
    expect(
      sortLocalIpAddresses([
        '127.0.0.1',
        '127.8.4.2',
        '127.255.255.255:8787',
        'http://127.100.1.1:8080',
        '::1',
        'https://[::1]:8787',
        '::ffff:127.0.0.2',
        'https://[::ffff:7f00:3]:8787',
      ]),
      isEmpty,
    );
  });

  test(
    'retains source and duplicate IP across interfaces with scoped link-local',
    () {
      final values = addressesFromInterfaces([
        {
          'id': 'wifi',
          'name': 'wlan0',
          'kind': 'Wi-Fi',
          'internet': true,
          'addresses': [
            '240e::1',
            '192.168.1.8',
            'fd00::1',
            '8.8.8.8',
            'fe80::1',
            '192.168.1.8',
          ],
        },
        {
          'id': 'vpn',
          'name': 'tun0',
          'kind': 'VPN',
          'addresses': ['192.168.1.8', '198.18.0.1', 'fe80::1'],
        },
        {
          'id': 'ims',
          'name': 'rmnet_data1',
          'kind': 'IMS 通话网络',
          'internet': false,
          'addresses': ['240e:573::1'],
        },
      ]);
      expect(values.where((ip) => ip.address == '192.168.1.8'), hasLength(2));
      expect(
        values.singleWhere((ip) => ip.address == 'fe80::1%wlan0').source!.kind,
        'Wi-Fi',
      );
      expect(
        values.singleWhere((ip) => ip.address == 'fe80::1%tun0').source!.kind,
        'VPN',
      );
      expect(
        values
            .singleWhere((ip) => ip.address == '240e:573::1')
            .source!
            .internet,
        false,
      );
      final wifi = values.where((ip) => ip.source!.id == 'wifi').toList();
      expect(wifi.map((ip) => ip.group.index), orderedEquals([0, 1, 2, 2, 3]));
      expect(
        values.singleWhere((ip) => ip.address == '198.18.0.1').categoryLabel,
        'IPv4 保留',
      );
      expect(values.every((ip) => ip.source!.owner.isEmpty), isTrue);
    },
  );

  test(
    'native reader consumes OS metadata rather than discarding interface names',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        expect(call.method, 'localIpInterfaces');
        return [
          {
            'id': 'interface-guid',
            'name': 'Wi-Fi',
            'description': 'System adapter description',
            'kind': 'Wi-Fi',
            'addresses': ['192.168.1.8', '127.0.0.1'],
          },
        ];
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      final values = await readLocalIpAddresses();
      expect(values, hasLength(1));
      expect(values.single.source!.title, 'Wi-Fi');
      expect(values.single.source!.subtitle, 'System adapter description');
    },
  );

  for (final mobile in [false, true]) {
    testWidgets(
      'brand opens grouped addresses and stages the exact chosen IP ${mobile ? 'phone' : 'desktop'}',
      (tester) async {
        final c = IpMenuController()
          ..api = CenterApi('https://example.invalid', token: 'test-only')
          ..profile = ServerProfile(
            baseUrl: 'https://example.invalid',
            instanceId: 'fixture',
            deviceId: 'self',
          )
          ..connected = true;
        tester.view.physicalSize = mobile
            ? const Size(390, 844)
            : const Size(934, 611);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
          if (call.method == 'windowVisible') return true;
          return null;
        });
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          messenger.setMockMethodCallHandler(SystemBridge.channel, null);
        });
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: GlobalSendApp(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('local-ip-menu')));
        await tester.pumpAndSettle();
        expect(c.addressReads, 1);
        expect(find.text('本机地址'), findsOneWidget);
        final headers = LocalIpGroup.values
            .map((group) => tester.getTopLeft(find.text(group.label)).dy)
            .toList();
        expect(headers, orderedEquals([...headers]..sort()));
        expect(find.text('wlan0'), findsOneWidget);
        expect(find.text('Wi-Fi'), findsOneWidget);
        await tester.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '../artifacts/screenshots/local-ip-sources-${mobile ? 'phone' : 'desktop'}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        final scrollable = find.descendant(
          of: find.byKey(const ValueKey('local-ip-list')),
          matching: find.byType(Scrollable),
        );
        await tester.scrollUntilVisible(
          find.text('tun0'),
          100,
          scrollable: scrollable,
        );
        await tester.pumpAndSettle();
        expect(find.text('VPN'), findsOneWidget);
        expect(find.text('IPv4 保留'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('local-ip-wlan0-192.168.1.8')),
          -100,
          scrollable: scrollable,
        );
        await tester.tap(
          find.byKey(const ValueKey('local-ip-wlan0-192.168.1.8')),
        );
        await tester.pumpAndSettle();
        expect(c.stagedTexts, ['192.168.1.8']);
        expect(find.text('本机地址'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('local-ip-menu')));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('本机地址'), findsNothing);
        expect(c.stagedTexts, ['192.168.1.8']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'empty and failed address reads are visible without exceptions or empty headings',
    (tester) async {
      var fail = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showLocalIpMenu(context, () async {
                  if (fail) throw const SocketException('fixture');
                  return [];
                }),
                child: const Text('地址'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('地址'));
      await tester.pumpAndSettle();
      expect(find.text('暂无 IP 地址'), findsOneWidget);
      expect(find.text('IPv4 内网'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      fail = true;
      await tester.tap(find.text('地址'));
      await tester.pumpAndSettle();
      expect(find.text('无法获取地址'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
