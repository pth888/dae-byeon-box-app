import 'package:blackbox_driver_care/widgets/road_question_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final road in [1, 6]) {
    testWidgets(
        'secondary movement is optional and can be cleared for road $road',
        (tester) async {
      String? action;
      await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(builder: (context, setState) {
          return Scaffold(
            body: RoadQuestionWidget(
              selectedPlace: road,
              selectedAction: action,
              onChanged: (_, nextAction) => setState(() => action = nextAction),
            ),
          );
        }),
      ));
      expect(find.text('상대 차량 움직임 (선택)'), findsOneWidget);
      expect(action, isNull);
      final key = Key(road == 1 ? 'road-action-left' : 'road-action-entering');
      await tester.tap(find.byKey(key));
      await tester.pump();
      expect(action, isNotNull);
      await tester.tap(find.byKey(key));
      await tester.pump();
      expect(action, isNull);
    });
  }

  testWidgets('shows all eight road choices and signal question mappings',
      (tester) async {
    int? place;
    String? action;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        return Scaffold(
          body: RoadQuestionWidget(
            selectedPlace: place,
            selectedAction: action,
            onChanged: (nextPlace, nextAction) => setState(() {
              place = nextPlace;
              action = nextAction;
            }),
          ),
        );
      }),
    ));

    for (var code = 0; code < 8; code++) {
      expect(find.byKey(Key('road-option-$code')), findsOneWidget);
    }

    await tester.tap(find.byKey(const Key('road-option-1')));
    await tester.pump();
    expect(find.text('사고 직전 상대 차는 어떻게 움직이고 있었나요?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('road-action-left')));
    await tester.pump();
    expect(place, 1);
    expect(action, 'left');

    await tester.tap(find.byKey(const Key('road-action-straight_other')));
    await tester.pump();
    expect(action, 'straight_other');
  });

  testWidgets('switching roads clears incompatible answer and changes question',
      (tester) async {
    int? place = 1;
    String? action = 'right';

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        return Scaffold(
          body: RoadQuestionWidget(
            selectedPlace: place,
            selectedAction: action,
            onChanged: (nextPlace, nextAction) => setState(() {
              place = nextPlace;
              action = nextAction;
            }),
          ),
        );
      }),
    ));

    await tester.tap(find.byKey(const Key('road-option-6')));
    await tester.pump();
    expect(place, 6);
    expect(action, isNull);
    expect(
      find.text('사고 직전 상대 차는 회전교차로에서 어떤 상태였나요?'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('road-action-lane_change')));
    await tester.pump();
    expect(action, 'lane_change');

    await tester.tap(find.byKey(const Key('road-option-4')));
    await tester.pump();
    expect(place, 4);
    expect(action, isNull);
    expect(find.byKey(const Key('road-secondary-question')), findsNothing);
  });

  testWidgets('busy state prevents road changes', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RoadQuestionWidget(
          selectedPlace: 0,
          selectedAction: null,
          isBusy: true,
          onChanged: (_, __) => calls++,
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('road-option-1')));
    await tester.pump();
    expect(calls, 0);
  });

  testWidgets('selected road keeps its label centered and selected semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RoadQuestionWidget(
          selectedPlace: 4,
          selectedAction: null,
          onChanged: (_, __) {},
        ),
      ),
    ));

    final selected = find.byKey(const Key('road-option-4'));
    // 체크 아이콘 없이 칩 색으로만 선택을 보여준다 (글자가 밀리지 않게)
    expect(
      find.descendant(of: selected, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
    expect(
      tester.getSemantics(selected),
      matchesSemantics(
        isSelected: true,
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasSelectedState: true,
        hasTapAction: true,
        hasFocusAction: true,
        label: '고속도로',
      ),
    );
    semantics.dispose();
  });
}
