import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/ui_tokens.dart';

void main() {
  testWidgets('a newly queued widget fades in and settles without moving', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: UiAppear(child: SizedBox(width: 40, height: 40)),
        ),
      ),
    );
    final fadeFinder = find.descendant(
      of: find.byType(UiAppear),
      matching: find.byType(FadeTransition),
    );
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, lessThan(1));
    expect(tester.getSize(find.byType(SizedBox).last), const Size(40, 40));

    await tester.pumpAndSettle();
    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);
    expect(tester.getSize(find.byType(SizedBox).last), const Size(40, 40));
  });
}
