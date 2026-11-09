import 'package:blackbox_driver_care/widgets/accident_alert_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app({double? g, VoidCallback? accident, VoidCallback? dismiss}) =>
      MaterialApp(
        home: Scaffold(
          body: AccidentAlertDialog(
            gForce: g,
            onAccident: accident ?? () {},
            onDismiss: dismiss ?? () {},
          ),
        ),
      );

  testWidgets('missing received g is not fabricated from the threshold',
      (tester) async {
    await tester.pumpWidget(app());
    expect(find.text('충격 강도 측정값 없음'), findsOneWidget);
    expect(find.textContaining('1.5G'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shows received g and advances only once after countdown',
      (tester) async {
    var accepted = 0;
    await tester.pumpWidget(app(g: 2.8, accident: () => accepted++));
    expect(find.text('충격 강도: 2.8G'), findsOneWidget);
    await tester.pump(const Duration(seconds: 14));
    expect(accepted, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(accepted, 1);
    await tester.tap(find.text('네, 사고 났어요'));
    await tester.pump(const Duration(seconds: 20));
    expect(accepted, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dismissal cancels the countdown without advancing',
      (tester) async {
    var accepted = 0;
    var dismissed = 0;
    await tester.pumpWidget(
        app(accident: () => accepted++, dismiss: () => dismissed++));
    await tester.tap(find.text('아니요, 괜찮아요'));
    await tester.pump(const Duration(seconds: 20));
    expect(dismissed, 1);
    expect(accepted, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
