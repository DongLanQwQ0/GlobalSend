import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/receive_dock_window.dart';
import 'package:globalsend/system_bridge.dart';

import 'system_font_fixture.dart';

const reference = {
  'id': 'copied:source:batch:folder',
  'sourceDeviceId': 'source',
  'sourceName': 'DongLan',
  'offerId': 'batch',
  'itemId': 'folder',
  'name': 'Course files',
  'kind': 'directory',
  'state': '',
};
Map<String, dynamic> dockPayload() => {
  'serial': 0,
  'arrivalGeneration': 1,
  'referenceRevision': 1,
  'serverKey': 'center',
  'items': <Map<String, dynamic>>[],
  'copiedFiles': [reference],
  'appearance': {'mode': 'dark', 'accent': 'rose'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(SystemBridge.channel, (_) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(ReceiveDockApp.channel, null);
    messenger.setMockMethodCallHandler(SystemBridge.channel, null);
  });
  testWidgets(
    'dock can show references without receipts, pull or dismiss them, but never export their nonexistent local bytes',
    (tester) async {
      await tester.runAsync(loadSystemTestFonts);
      tester.view.physicalSize = const Size(480, 184);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <MethodCall>[];
      final capture = GlobalKey();
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        calls.add(call);
        return call.method == 'ready' ? dockPayload() : null;
      });
      await tester.pumpWidget(
        RepaintBoundary(key: capture, child: const ReceiveDockApp()),
      );
      await tester.pumpAndSettle();
      debugPrintSynchronously('reference dock mounted');
      expect(find.text('可拉取 1 项'), findsOneWidget);
      expect(find.text('Course files'), findsOneWidget);
      await tester.tap(find.text('Course files'));
      await tester.pumpAndSettle();
      debugPrintSynchronously('reference pull invoked');
      final pull =
          calls.where((call) => call.method == 'action').last.arguments as Map;
      expect(pull['action'], 'pullCopiedFile');
      expect(pull['serverKey'], 'center');
      expect(pull['id'], reference['id']);
      expect(pull['itemIds'], isEmpty);
      expect(calls.any((call) => call.method == 'dragOut'), isFalse);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '忽略此条目',
        ),
      );
      await tester.pumpAndSettle();
      debugPrintSynchronously('reference dismiss invoked');
      expect(
        (calls.where((call) => call.method == 'action').last.arguments
            as Map)['action'],
        'dismissCopiedFile',
      );
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final directory = await Directory(
          '../artifacts/tmp/copied-files-client/render',
        ).create(recursive: true);
        await File('${directory.path}/windows-dock.rgba')
            .writeAsBytes(data!.buffer.asUint8List());
        await File('${directory.path}/windows-dock.json').writeAsString(
          jsonEncode({'width': image.width, 'height': image.height}),
        );
        image.dispose();
        debugPrintSynchronously('reference dock readback complete');
      });
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
