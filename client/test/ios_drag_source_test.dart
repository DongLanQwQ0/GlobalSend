import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/file_share.dart';
import 'package:globalsend/ios_drag_source.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/text_selection_surface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FileShareBridge.channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FileShareBridge.channel, null);
  });

  Future<void> mount(WidgetTester tester, Widget source) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: source)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Map source() =>
      ((calls.lastWhere((c) => c.method == 'setDragSources').arguments
                      as Map)['sources']
                  as List)
              .single
          as Map;

  testWidgets(
    'iOS exports only card-sized real pixels and actual text payload',
    (tester) async {
      await mount(
        tester,
        IOSDragSource(
          entry: DockEntry(
            id: 'text-one',
            kind: 'text',
            title: '文本',
            source: '',
            text: 'https://example.test/真实文本',
          ),
          enabled: true,
          child: const SizedBox(
            width: 160,
            height: 120,
            child: ColoredBox(color: Color(0xff234567), child: Text('真实文本')),
          ),
        ),
      );
      expect(source()['texts'], ['https://example.test/真实文本']);
      expect(source()['previewWidth'], 160);
      expect(source()['previewHeight'], 120);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(IOSDragSource)),
      );
      await tester.pump();
      await tester.runAsync(() async {
        for (
          var i = 0;
          i < 100 && !calls.any((c) => c.method == 'setDragPreview');
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      final preview =
          calls.singleWhere((c) => c.method == 'setDragPreview').arguments
              as Map;
      expect(preview['width'], 160);
      expect(preview['height'], 120);
      final pixels = preview['rgba'] as Uint8List;
      expect(pixels.length, 160 * 120 * 4);
      expect(pixels.take(4), [0x23, 0x45, 0x67, 0xff]);
      expect(
        calls.where((c) => c.method == 'prepareDragSource').single.arguments,
        containsPair('blocked', false),
      );
      await gesture.up();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'iOS media suggestion registers a lazy original asset and dismisses only accepted drops',
    (tester) async {
      var accepted = 0;
      await mount(
        tester,
        IOSDragSource.media(
          assetId: 'photo-library-id',
          enabled: true,
          onDragAccepted: () => accepted++,
          child: const SizedBox(width: 120, height: 120, child: Text('图片建议')),
        ),
      );
      expect(source()['mediaAssetId'], 'photo-library-id');
      expect(source()['label'], '媒体');
      expect(source()['paths'], isEmpty);
      expect(source()['texts'], isEmpty);
      for (final operation in ['cancel', 'copy']) {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          FileShareBridge.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('nativeDrag', {
              'active': false,
              'local': true,
              'sessionActive': false,
              'mediaAssetId': 'photo-library-id',
              'operation': operation,
            }),
          ),
          (_) {},
        );
        await tester.pump();
        expect(accepted, operation == 'copy' ? 1 : 0);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'iOS clipboard drag dismisses only after an accepted native drop',
    (tester) async {
      var accepted = 0;
      await mount(
        tester,
        IOSDragSource.clipboard(
          revision: '401',
          enabled: true,
          onDragAccepted: () => accepted++,
          child: const SizedBox(width: 120, height: 120, child: Text('剪贴板')),
        ),
      );
      Future<void> event(String revision, String operation) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          FileShareBridge.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('nativeDrag', {
              'active': false,
              'local': true,
              'sessionActive': false,
              'clipboardRevision': revision,
              'operation': operation,
            }),
          ),
          (_) {},
        );
        await tester.pump();
      }

      await event('401', 'cancel');
      await event('different', 'copy');
      expect(accepted, 0);
      await event('401', 'copy');
      expect(accepted, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'iOS clipboard card registers a native clipboard revision, never a placeholder payload',
    (tester) async {
      await mount(
        tester,
        const IOSDragSource.clipboard(
          revision: '401',
          enabled: true,
          child: SizedBox(width: 120, height: 120, child: Text('文件 · 点按添加')),
        ),
      );
      expect(source()['clipboardRevision'], '401');
      expect(source()['paths'], isEmpty);
      expect(source()['texts'], isEmpty);
      expect(source()['label'], '剪贴板');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('iOS card controls are excluded from native lift', (
    tester,
  ) async {
    await mount(
      tester,
      IOSDragSource(
        entry: DockEntry(
          id: 'with-control',
          kind: 'text',
          title: '文本',
          source: '',
          text: 'body',
        ),
        enabled: true,
        child: SizedBox(
          width: 160,
          height: 120,
          child: Center(
            child: ContentDragControl(
              child: TextButton(onPressed: () {}, child: const Text('复制')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(
      calls.where((c) => c.method == 'prepareDragSource').single.arguments,
      containsPair('blocked', true),
    );
    expect(calls.where((c) => c.method == 'setDragPreview'), isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
}
