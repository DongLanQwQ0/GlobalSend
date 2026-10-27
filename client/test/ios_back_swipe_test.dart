import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/ios_back_swipe.dart';

void main() {
  for (final dialog in [false, true]) {
    testWidgets(
      'iPad back edge dismisses ${dialog ? 'dialog' : 'detail'} without requiring the top left button',
      (tester) async {
        final key = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.iOS),
            navigatorKey: key,
            builder: (_, child) =>
                IosBackSwipe(navigatorKey: key, child: child!),
            home: const Scaffold(body: Text('home')),
          ),
        );
        if (dialog) {
          key.currentState!.push(
            DialogRoute<void>(
              context: key.currentContext!,
              builder: (_) => const Dialog(
                child: SizedBox(width: 300, height: 300, child: Text('detail')),
              ),
            ),
          );
        } else {
          key.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('detail')),
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('ios-back-swipe-edge')),
          findsOneWidget,
        );
        await tester.dragFrom(const Offset(8, 350), const Offset(220, 0));
        await tester.pumpAndSettle();
        expect(key.currentState!.canPop(), isFalse);
        expect(find.text('detail'), findsNothing);
      },
    );
  }
}
