import 'dart:async';

import 'package:blackbox_driver_care/preview/chat_preview_data.dart';
import 'package:blackbox_driver_care/screens/chatbot/thread_chat_screen.dart';
import 'package:blackbox_driver_care/services/auth_service.dart';
import 'package:blackbox_driver_care/services/thread_chat_service.dart';
import 'package:blackbox_driver_care/utils/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/thread_chat_fakes.dart';

void main() {
  testWidgets(
      'each quick question sends its own text instead of the draft or previous question',
      (tester) async {
    final service = PreviewThreadService(persist: (_) {});
    await tester.pumpWidget(ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => ThreadChatTestAuth()),
          threadChatServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
            theme: AppTheme.lightTheme, home: const ThreadChatScreen())));
    await tester.pumpAndSettle();

    const questions = [
      '과실 비율이 뭔가요?',
      '사고 후 신고 방법',
      '블랙박스 영상 보존',
      '보험사 연락 방법',
    ];
    for (final question in questions) {
      await tester.enterText(find.byType(TextField), '전송하지 않은 이전 초안');
      await tester.tap(find.text(question));
      await tester.pumpAndSettle();

      final threads = await service.listThreads();
      final created = threads.where((t) => t.title == question).single;
      final messages = await service.history(created.id);
      expect(messages.where((m) => m.isUser).map((m) => m.text), [question]);
      expect(
          find.byWidgetPredicate(
              (w) => w is SelectableText && w.data == question),
          findsOneWidget);
      // Quick questions must not consume an unrelated unsent draft.
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '전송하지 않은 이전 초안');

      await tester.tap(find.byTooltip('새 채팅'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid quick-question taps save only the first chosen question',
      (tester) async {
    final service = _DelayedPreview();
    await tester.pumpWidget(ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => ThreadChatTestAuth()),
          threadChatServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
            theme: AppTheme.lightTheme, home: const ThreadChatScreen())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('과실 비율이 뭔가요?'));
    await tester.tap(find.text('사고 후 신고 방법'));
    await tester.pump();
    service.release.complete();
    await tester.pumpAndSettle();

    final selected = (await service.listThreads())
        .where((t) => t.title == '과실 비율이 뭔가요?')
        .single;
    expect(
        (await service.history(selected.id))
            .where((m) => m.isUser)
            .map((m) => m.text),
        ['과실 비율이 뭔가요?']);
    expect((await service.listThreads()).where((t) => t.title == '사고 후 신고 방법'),
        isEmpty);
    expect(
        find.byWidgetPredicate(
            (w) => w is SelectableText && w.data == '과실 비율이 뭔가요?'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _DelayedPreview extends PreviewThreadService {
  _DelayedPreview() : super(persist: (_) {});
  final release = Completer<void>();

  @override
  Future<ThreadReply> send(String id, String text, String requestId) async {
    await release.future;
    return super.send(id, text, requestId);
  }
}
