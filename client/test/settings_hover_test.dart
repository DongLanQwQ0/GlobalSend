import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/appearance.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/ui_tokens.dart';

import 'widget_test.dart' as fixture;
import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  for (final mode in [AppearanceMode.dark, AppearanceMode.light]) {
    testWidgets('settings action hover is inset and rounded in ${mode.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(950, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        SystemBridge.channel,
        (call) async => call.method == 'windowVisible' ? true : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      final c = fixture.signedIn()
        ..info = {
          'features': {'multiGroup': true},
        };
      c.profile!.groupId = 'g1';
      c.profile!.groups = [
        {'groupId': 'g1', 'name': '分组 1'},
      ];
      await c.appearance.set(
        mode: mode,
        accent: mode == AppearanceMode.dark
            ? AccentColor.rose
            : AccentColor.blue,
      );
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: GlobalSendApp(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final group = find.byKey(const ValueKey('settings-group-g1'));
      final list = find
          .descendant(
            of: find.byKey(const ValueKey('settings-list')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(group, 400, scrollable: list);
      await Scrollable.ensureVisible(tester.element(group), alignment: .2);
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(2, 2));
      addTearDown(mouse.removePointer);

      Future<Uint8List> pixels(String? label) async {
        final bytes = await tester.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final bytes = data!.buffer.asUint8List();
          if (label != null) {
            final directory = await Directory(
              '../artifacts/tmp/settings-hover95/render',
            ).create(recursive: true);
            await File('${directory.path}/${mode.name}-$label.rgba')
                .writeAsBytes(bytes);
            await File('${directory.path}/${mode.name}-$label.json')
                .writeAsString(
                  jsonEncode({'width': image.width, 'height': image.height}),
                );
          }
          image.dispose();
          return bytes;
        });
        return bytes!;
      }

      int colorAt(Uint8List data, Offset point) {
        final i = (point.dy.floor() * 950 + point.dx.floor()) * 4;
        return (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
      }

      for (final target in [
        group,
        find.byKey(const ValueKey('settings-disconnect')),
      ]) {
        await mouse.moveTo(const Offset(2, 2));
        await tester.pumpAndSettle();
        final before = await pixels(null), bounds = tester.getRect(target);
        final tile = tester.widget<ListTile>(target),
            context = tester.element(target);
        final shape = ListTileTheme.of(context).shape as RoundedRectangleBorder;
        expect(shape.borderRadius, Ui.fieldRadius);
        expect(
          tile.contentPadding,
          const EdgeInsets.symmetric(horizontal: Ui.space3),
        );
        expect(Theme.of(context).hoverColor, Ui.colors(context).hoveredSubtle);
        await mouse.moveTo(bounds.center);
        await tester.pumpAndSettle();
        final after = await pixels(target == group ? 'group' : 'disconnect');
        final corner = bounds.topLeft + const Offset(1, 1),
            center = Offset(bounds.center.dx, bounds.top + 4);
        expect(
          colorAt(after, corner),
          colorAt(before, corner),
          reason: 'hover must not paint a rectangular corner',
        );
        expect(
          colorAt(after, center),
          isNot(colorAt(before, center)),
          reason: 'subtle feedback remains visible inside the rounded row',
        );
      }
      expect(c.profile!.groupId, 'g1');
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }
}
