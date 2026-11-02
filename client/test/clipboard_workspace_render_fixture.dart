import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/appearance.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

import 'system_font_fixture.dart';
import 'widget_test.dart' show signedIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  for (final mobile in [false, true]) {
    testWidgets('clipboard slot and file references share one compact row: $mobile', (tester) async {
      debugDefaultTargetPlatformOverride = mobile ? TargetPlatform.android : TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = mobile ? const Size(390, 844) : const Size(950, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'windowVisible') return true;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemBridge.channel, null));
      final c = signedIn();
      c.appearance.value = const Appearance(mode: AppearanceMode.dark, accent: AccentColor.purple);
      c.copiedFiles.offers = [{
        'sourceDeviceId': 'other', 'sourceName': 'DongLan', 'offerId': 'batch',
        'items': [{'id': 'file', 'name': '项目文档.txt', 'kind': 'file', 'size': 2048}],
      }];
      await c.clipboard.receive(DockEntry(
        id: 'remote', kind: 'text', title: '剪贴板', source: 'other',
        text: '最新同步的文字\n只保留这一项', autoClipboard: true,
      ));
      final capture = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(key: capture, child: GlobalSendApp(controller: c)));
      await tester.pumpAndSettle();
      final slot = tester.getRect(find.byKey(const ValueKey('clipboard-slot')));
      final reference = tester.getRect(find.byKey(const ValueKey('copied-file-batch-file')));
      expect(slot.size, const Size(124, 124));
      expect(reference.size, slot.size);
      expect(reference.top, slot.top);
      expect(reference.left, greaterThan(slot.right));
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image = await (capture.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final directory = await Directory('../artifacts/tmp/clipboard-toolbar112/render').create(recursive: true);
        final name = mobile ? 'phone' : 'desktop';
        await File('${directory.path}/$name.rgba').writeAsBytes(bytes!.buffer.asUint8List());
        await File('${directory.path}/$name.json').writeAsString(jsonEncode({'width':image.width,'height':image.height}));
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
