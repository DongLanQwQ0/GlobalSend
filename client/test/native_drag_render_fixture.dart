import 'package:flutter_test/flutter_test.dart';

/// GPU readback is an engine callback outside fake async. Let the small native
/// drag snapshot complete before checking the platform-export callback.
Future<void> pumpNativeDrag(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pump();
}
