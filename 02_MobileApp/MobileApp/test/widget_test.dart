
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuro_sense/main.dart';

void main() {
  testWidgets('SailmCalm logo renders', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SailboatMark(),
        ),
      ),
    );

    expect(find.byType(SailboatMark), findsOneWidget);
  });
}
