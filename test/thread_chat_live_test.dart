import 'package:blackbox_driver_care/screens/chatbot/thread_chat_screen.dart';
import 'package:blackbox_driver_care/services/auth_service.dart';
import 'package:blackbox_driver_care/services/consent_service.dart';
import 'package:blackbox_driver_care/services/thread_chat_service.dart';
import 'package:blackbox_driver_care/utils/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/thread_chat_fakes.dart';

void main() {
  for (final accident in [false, true]) {
    testWidgets('consented ${accident ? 'accident' : 'general'} chat sends directly without an extra popup',
        (tester) async {
      expect(kThreadChatAiEnabled, isTrue);
      final service = _ReplyingThreads();
      await tester.pumpWidget(ProviderScope(overrides: [
        authProvider.overrideWith((ref) => ThreadChatTestAuth()),
        consentControllerProvider.overrideWith((ref) => _Consented()),
        threadChatServiceProvider.overrideWithValue(service),
      ], child: MaterialApp(theme: AppTheme.lightTheme,
        home: ThreadChatScreen(initialCaseId: accident ? 'case-a' : null))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('과실 비율이 뭔가요?'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(service.sent, ['과실 비율이 뭔가요?']);
      expect(find.text('서버에서 받은 답변입니다.'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is SelectableText && w.data == '과실 비율이 뭔가요?'), findsOneWidget);
      expect(find.textContaining('AI 연결은 보류 중'), findsNothing);
      expect(tester.takeException(), isNull);
    }, skip: !kThreadChatAiEnabled);
  }
}

class _Consented extends ConsentController {
  _Consented() : super(service: ConsentService(accessToken: () async => null)) {
    state = const ConsentState(status: ConsentLoadStatus.ready,
      snapshot: ConsentSnapshot(version: 'test', grants: {
        ConsentDocument.privacy: true, ConsentDocument.externalAi: true,
      }));
  }
}

class _ReplyingThreads extends ControlledThreads {
  final sent = <String>[];
  @override
  Future<ThreadReply> send(String id, String text, String requestId) async {
    sent.add(text);
    final stamp = DateTime.now();
    return ThreadReply([
      ThreadMessage(id: 'saved-user', role: 'user', text: text, createdAt: stamp, requestId: requestId),
      ThreadMessage(id: 'saved-answer', role: 'assistant', text: '서버에서 받은 답변입니다.',
        createdAt: stamp.add(const Duration(milliseconds: 1)), requestId: requestId),
    ], true);
  }
}
