import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:globalsend/system_bridge.dart';

/// A native fixture confirms OLE ownership for this exact export session.
Future<void> signalNativeDragStarted(Map<String, Object> arguments) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        SystemBridge.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('outgoingDragStarted', {
            'dragSessionId': arguments['dragSessionId'],
          }),
        ),
        (_) {},
      );
}

/// GPU readback is an engine callback outside fake async. Let the small native
/// drag snapshot complete before checking the platform-export callback.
Future<void> pumpNativeDrag(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pump();
}
