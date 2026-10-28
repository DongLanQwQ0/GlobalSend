import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/dock_platform.dart';
import 'package:globalsend/installed_apps_picker.dart';
import 'package:globalsend/ui_tokens.dart';

import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'app picker searches names and packages and returns one selection',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        DockPlatform.channel,
        (call) async => call.method == 'installedApps'
            ? [
                {
                  'package': 'dev.sample.one',
                  'name': '示例应用',
                  'version': '1.2',
                  'apkCount': 1,
                },
                {
                  'package': 'dev.sample.two',
                  'name': '拆分应用',
                  'version': '2.0',
                  'apkCount': 3,
                },
              ]
            : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(DockPlatform.channel, null),
      );
      tester.view.physicalSize = const Size(393, 851);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    selected = await pickInstalledApp(context),
                child: const Text('应用'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(find.text('示例应用'), findsOneWidget);
      expect(find.text('2.0 · 3 个 APK'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'sample.two');
      await tester.pumpAndSettle();
      expect(find.text('示例应用'), findsNothing);
      await tester.tap(find.text('拆分应用'));
      await tester.pumpAndSettle();
      expect(selected, 'dev.sample.two');
      expect(tester.takeException(), isNull);
    },
  );
}
