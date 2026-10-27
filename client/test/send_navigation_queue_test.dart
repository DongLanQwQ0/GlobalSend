import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/system_bridge.dart';

import 'widget_test.dart' show signedIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemBridge.channel,
          (call) async => call.method == 'windowVisible' ? true : null,
        );
  });
  for (final mobile in [true, false]) {
    testWidgets(
      'send opens first and queue stays one square row ${mobile ? 'phone' : 'desktop'}',
      (tester) async {
        tester.view.physicalSize = mobile
            ? const Size(390, 844)
            : const Size(934, 611);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = signedIn()
          ..stagedTexts.addAll(List.generate(8, (i) => '待发送第 ${i + 1} 项'));
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: GlobalSendApp(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        final queue = find.byKey(const ValueKey('send-queue'));
        expect(tester.getSize(queue).height, 180);
        if (mobile) {
          final send = find.widgetWithText(NavigationDestination, '发送');
          final receive = find.widgetWithText(NavigationDestination, '接收');
          expect(
            tester.getCenter(send).dx,
            lessThan(tester.getCenter(receive).dx),
          );
          expect(
            tester
                .widget<NavigationBar>(find.byType(NavigationBar))
                .selectedIndex,
            0,
          );
          await tester.tap(receive);
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('receive-scroll')), findsOneWidget);
          await tester.tap(send);
          await tester.pumpAndSettle();
          expect(c.stagedTexts.length, 8);
        }
        final list = find.byKey(const ValueKey('send-queue-list'));
        expect(tester.widget<ListView>(list).scrollDirection, Axis.horizontal);
        final scroll = tester.widget<ListView>(list).controller!;
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: tester.getCenter(list),
            scrollDelta: const Offset(0, 140),
          ),
        );
        await tester.pumpAndSettle();
        expect(scroll.offset, greaterThan(0));
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        final tiles = find.descendant(
          of: list,
          matching: find.byType(AspectRatio),
        );
        final first = tester.getRect(tiles.at(0)),
            second = tester.getRect(tiles.at(1));
        expect(first.width, closeTo(first.height, .1));
        expect(first.top, second.top);
        expect(second.left, greaterThan(first.right));
        await tester.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '../artifacts/screenshots/send-navigation-queue-${mobile ? 'phone' : 'desktop'}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.drag(list, const Offset(-650, 0));
        await tester.pumpAndSettle();
        expect(find.text('待发送第 8 项'), findsOneWidget);
        expect(tester.getSize(queue).height, 180);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
}
