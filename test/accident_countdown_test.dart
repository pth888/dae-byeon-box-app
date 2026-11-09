import 'package:blackbox_driver_care/widgets/accident_alert_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app({
    double? g,
    bool testEvent = false,
    VoidCallback? accident,
    VoidCallback? dismiss,
  }) =>
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: AccidentAlertDialog(
              gForce: g,
              isTestEvent: testEvent,
              onAccident: accident ?? () {},
              onDismiss: dismiss ?? () {},
            ),
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

  testWidgets(
      'no response for 15s shows the sent message, then advances once after 10s',
      (tester) async {
    var accepted = 0;
    await tester
        .pumpWidget(app(g: 2.8, testEvent: true, accident: () => accepted++));
    expect(find.text('충격 강도: 2.8G'), findsOneWidget);

    await tester.pump(const Duration(seconds: 14));
    expect(accepted, 0);
    await tester.pump(const Duration(seconds: 1));
    // 문자 발송 처리(위치·연락처 확인)가 끝날 때까지
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(find.textContaining('문자를 발송했습니다'), findsOneWidget);
    expect(accepted, 0);

    for (var i = 0; i < kAfterDispatchSeconds + 2; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(accepted, 1);
    await tester.pump(const Duration(seconds: 20));
    expect(accepted, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('answering during the countdown advances without sending',
      (tester) async {
    var accepted = 0;
    await tester.pumpWidget(app(accident: () => accepted++));
    await tester.tap(find.text('지금 시작'));
    await tester.pump(const Duration(seconds: 30));
    expect(accepted, 1);
    expect(find.textContaining('문자를 발송했습니다'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dismissal cancels the countdown without advancing',
      (tester) async {
    var accepted = 0;
    var dismissed = 0;
    await tester.pumpWidget(
        app(accident: () => accepted++, dismiss: () => dismissed++));
    await tester.tap(find.text('오작동입니다'));
    await tester.pump(const Duration(seconds: 30));
    expect(dismissed, 1);
    expect(accepted, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
