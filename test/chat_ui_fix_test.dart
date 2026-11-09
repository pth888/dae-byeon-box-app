import 'dart:async';

import 'package:blackbox_driver_care/screens/chatbot/chatbot_screen.dart';
import 'package:blackbox_driver_care/services/chat_service.dart';
import 'package:blackbox_driver_care/services/auth_service.dart';
import 'package:blackbox_driver_care/services/thread_chat_service.dart';

import 'support/thread_chat_fakes.dart';
import 'package:blackbox_driver_care/services/model_analysis_service.dart';
import 'package:blackbox_driver_care/widgets/floating_chatbot_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CaseChatMessage message(
    String id,
    String text, {
    ChatRole role = ChatRole.user,
    String? kind,
    int minute = 0,
  }) =>
      CaseChatMessage(
        id: id,
        role: role,
        text: text,
        kind: kind,
        createdAt: DateTime.utc(2026, 10, 17, 1, minute),
      );

  group('internal chat records', () {
    test('hides only strictly valid user road and analysis records', () async {
      const road =
          '{"type":"road_selection","place":1,"other_action":null,"revision":1}';
      const feedback =
          '{"type":"analysis_feedback","facts":{"bad_weather":true},"keywords":["빗길"]}';
      const malformedFeedback =
          '{"type":"analysis_feedback","facts":{"made_up":true},"keywords":["빗길"]}';
      final service = _ControlledChatService(history: [
        message('road', road),
        message('feedback', feedback, minute: 1),
        message('malformed', malformedFeedback, minute: 2),
        message('assistant-json', road, role: ChatRole.assistant, minute: 3),
        message('ordinary', '{"question":"실제 사용자 JSON"}', minute: 4),
      ]);
      final notifier = ChatbotNotifier(
        chatService: service,
        caseId: 'case-a',
        userId: 'driver-a',
      );

      await notifier.loadHistory();

      expect(
        notifier.state.messages.map((item) => item.id),
        ['malformed', 'assistant-json', 'ordinary'],
      );
      expect(notifier.state.messages.first.text, malformedFeedback);
      expect(notifier.state.messages[1].text, road);
      expect(
        notifier.state.messages.map((item) => item.text),
        isNot(contains('도로유형 선택을 저장했습니다.')),
      );
    });

    test('keeps malformed analysis-shaped user JSON visible', () async {
      const malformed = <String>[
        '{"type":"analysis_feedback","facts":{"bad_weather":1},"keywords":[]}',
        '{"type":"analysis_feedback","facts":{},"keywords":[""]}',
        '{"type":"analysis_feedback","facts":{},"keywords":[],"extra":true}',
        '{"type":"analysis_feedback","facts":{},"keywords":null}',
      ];
      final notifier = ChatbotNotifier(
        chatService: _ControlledChatService(
          history: [
            for (var index = 0; index < malformed.length; index++)
              message('$index', malformed[index], minute: index),
          ],
        ),
        caseId: 'case-a',
        userId: 'driver-a',
      );

      await notifier.loadHistory();

      expect(notifier.state.messages.map((item) => item.text), malformed);
    });

    test('uses provenance before the bounded legacy shape fallback', () async {
      const reserved =
          '{"type":"road_selection","place":1,"other_action":null,"revision":1}';
      final notifier = ChatbotNotifier(
        chatService: _ControlledChatService(history: [
          message('conversation', reserved, kind: 'conversation'),
          message('internal', 'not-json', kind: 'internal', minute: 1),
          message('legacy', reserved, kind: 'legacy', minute: 2),
        ]),
        caseId: 'case-a',
        userId: 'driver-a',
      );

      await notifier.loadHistory();

      expect(notifier.state.messages.single.id, 'conversation');
      expect(notifier.state.messages.single.text, reserved);
    });
  });

  group('optimistic chat state', () {
    test('blocks sending until history loads and preserves loaded messages',
        () async {
      final history = Completer<List<CaseChatMessage>>();
      final send = Completer<ChatSendResult>();
      final service = _ControlledChatService(
        historyRequests: [history],
        send: send,
      );
      final notifier = ChatbotNotifier(
        chatService: service,
        caseId: 'case-a',
        userId: 'driver-a',
      );

      final loading = notifier.loadHistory();
      expect(notifier.state.isLoadingHistory, isTrue);
      expect(
        await notifier.sendMessage('기록 전에 보낸 질문'),
        ChatSendOutcome.failed,
      );
      expect(service.sent, isEmpty);

      history.complete([message('old', '기존 대화')]);
      await loading;
      final sending = notifier.sendMessage('새 질문');

      expect(
        notifier.state.messages.map((item) => item.text),
        ['기존 대화', '새 질문'],
      );
      send.complete(ChatSendResult(
        messages: [
          message('server-question', '새 질문', minute: 1),
          message('server-answer', '새 답변', role: ChatRole.assistant, minute: 2),
        ],
        llm: const ChatLlmResult(
          provider: 'real',
          status: ChatLlmStatus.complete,
        ),
      ));
      await sending;

      expect(
        notifier.state.messages.map((item) => item.id),
        ['old', 'server-question', 'server-answer'],
      );
    });

    test(
        'shows question immediately then replaces pending with server messages',
        () async {
      final send = Completer<ChatSendResult>();
      final service = _ControlledChatService(send: send);
      final notifier = ChatbotNotifier(
        chatService: service,
        caseId: 'case-a',
        userId: 'driver-a',
      );

      final sending = notifier.sendMessage('  질문입니다  ');

      expect(notifier.state.isAwaitingReply, isTrue);
      expect(notifier.state.messages, hasLength(1));
      expect(notifier.state.messages.single.text, '질문입니다');
      expect(notifier.state.messages.single.isUser, isTrue);

      send.complete(ChatSendResult(
        messages: [
          message('server-question', '질문입니다'),
          message('server-answer', '답변입니다',
              role: ChatRole.assistant, minute: 1),
        ],
        llm: const ChatLlmResult(
          provider: 'real',
          status: ChatLlmStatus.complete,
        ),
      ));
      expect(await sending, ChatSendOutcome.sent);

      expect(notifier.state.isAwaitingReply, isFalse);
      expect(
        notifier.state.messages.map((item) => item.id),
        ['server-question', 'server-answer'],
      );
      expect(
        notifier.state.messages.where((item) => item.text == '질문입니다'),
        hasLength(1),
      );
    });

    test('keeps an explicitly sent reserved-shape JSON message', () async {
      const raw =
          '{"type":"road_selection","place":1,"other_action":null,"revision":1}';
      final send = Completer<ChatSendResult>();
      final notifier = ChatbotNotifier(
        chatService: _ControlledChatService(send: send),
        caseId: 'case-a',
        userId: 'driver-a',
      );

      final sending = notifier.sendMessage(raw);
      send.complete(ChatSendResult(
        messages: [message('server-json-question', raw)],
        llm: const ChatLlmResult(
          provider: 'real',
          status: ChatLlmStatus.complete,
        ),
      ));
      await sending;

      expect(notifier.state.messages.single.id, 'server-json-question');
      expect(notifier.state.messages.single.text, raw);
    });

    test('removes unsaved pending question on consent failure', () async {
      final send = Completer<ChatSendResult>();
      final notifier = ChatbotNotifier(
        chatService: _ControlledChatService(send: send),
        caseId: 'case-a',
        userId: 'driver-a',
      );

      final sending = notifier.sendMessage('동의가 필요한 질문');
      expect(notifier.state.messages.single.text, '동의가 필요한 질문');
      send.completeError(const ExternalAiConsentRequiredException());

      expect(await sending, ChatSendOutcome.externalAiConsentRequired);
      expect(notifier.state.messages, isEmpty);
      expect(notifier.state.isAwaitingReply, isFalse);
      expect(notifier.state.notice, contains('선택 동의'));
    });

    test('reconciles an unknown transport result without losing old history',
        () async {
      final initialHistory = Completer<List<CaseChatMessage>>();
      final reconciledHistory = Completer<List<CaseChatMessage>>();
      final send = Completer<ChatSendResult>();
      final service = _ControlledChatService(
        historyRequests: [initialHistory, reconciledHistory],
        send: send,
      );
      final notifier = ChatbotNotifier(
        chatService: service,
        caseId: 'case-a',
        userId: 'driver-a',
      );
      final loading = notifier.loadHistory();
      initialHistory.complete([message('old', '기존 대화')]);
      await loading;

      final sending = notifier.sendMessage('전송 결과 미상 질문');
      send.completeError(StateError('transport disconnected'));
      reconciledHistory.complete([
        message('old', '기존 대화'),
        message('saved-question', '전송 결과 미상 질문', minute: 1),
        message('saved-answer', '서버에 남은 답변',
            role: ChatRole.assistant, minute: 2),
      ]);

      expect(await sending, ChatSendOutcome.failed);
      expect(
        notifier.state.messages.map((item) => item.id),
        ['old', 'saved-question', 'saved-answer'],
      );
      expect(
        notifier.state.notice,
        '전송 결과를 확인하지 못했습니다. 대화 기록을 다시 확인해 주세요.',
      );
    });

    test('keeps the pending question when reconciliation cannot find the turn',
        () async {
      final reconciledHistory = Completer<List<CaseChatMessage>>();
      final send = Completer<ChatSendResult>();
      final service = _ControlledChatService(
        historyRequests: [reconciledHistory],
        send: send,
      );
      final notifier = ChatbotNotifier(
        chatService: service,
        caseId: 'case-a',
        userId: 'driver-a',
      );

      final sending = notifier.sendMessage('확인되지 않은 질문');
      send.completeError(StateError('transport disconnected'));
      reconciledHistory.complete([message('old', '기존 대화')]);
      await sending;

      expect(
        notifier.state.messages.map((item) => item.text),
        ['기존 대화', '확인되지 않은 질문'],
      );
      expect(
        notifier.state.messages.where((item) => item.id.startsWith('pending:')),
        hasLength(1),
      );
    });

    test('latest overlapping history request wins', () async {
      final first = Completer<List<CaseChatMessage>>();
      final second = Completer<List<CaseChatMessage>>();
      final service = _ControlledChatService(historyRequests: [first, second]);
      final notifier = ChatbotNotifier(
        chatService: service,
        caseId: 'case-a',
        userId: 'driver-a',
      );

      final firstLoad = notifier.loadHistory();
      final secondLoad = notifier.loadHistory();
      second.complete([message('new', '최신 기록')]);
      await secondLoad;
      first.complete([message('old', '오래된 기록')]);
      await firstLoad;

      expect(notifier.state.messages.single.id, 'new');
      expect(notifier.state.isLoadingHistory, isFalse);
    });

    test('late send completion after dispose does not update state or throw',
        () async {
      final send = Completer<ChatSendResult>();
      final notifier = ChatbotNotifier(
        chatService: _ControlledChatService(send: send),
        caseId: 'case-a',
        userId: 'driver-a',
      );

      final sending = notifier.sendMessage('질문');
      notifier.dispose();
      send.complete(ChatSendResult(
        messages: [message('answer', '답변', role: ChatRole.assistant)],
        llm: const ChatLlmResult(
          provider: 'real',
          status: ChatLlmStatus.complete,
        ),
      ));

      expect(await sending, ChatSendOutcome.sent);
    });
  });

  testWidgets('renders a truthful waiting status while the reply is pending',
      (tester) async {
    final send = Completer<ChatSendResult>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatServiceProvider.overrideWithValue(
            _ControlledChatService(send: send),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ChatbotSheet(caseId: 'case-a', userId: 'driver-a'),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '화면 질문');
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    expect(find.text('화면 질문'), findsOneWidget);
    expect(find.text('AI 답변을 기다리는 중'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('분석 중'), findsNothing);
    expect(find.textContaining('도구'), findsNothing);

    send.complete(ChatSendResult(
      messages: [
        message('question', '화면 질문'),
        message('answer', '화면 답변', role: ChatRole.assistant, minute: 1),
      ],
      llm: const ChatLlmResult(
        provider: 'real',
        status: ChatLlmStatus.complete,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('AI 답변을 기다리는 중'), findsNothing);
    expect(find.text('화면 질문'), findsOneWidget);
    expect(find.text('화면 답변'), findsOneWidget);
  });

  testWidgets('busy submit paths preserve the draft and do not send again',
      (tester) async {
    final send = Completer<ChatSendResult>();
    final service = _ControlledChatService(send: send);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          home: Scaffold(
            body: ChatbotSheet(caseId: 'case-a', userId: 'driver-a'),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '첫 질문');
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '보존할 초안');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.tap(find.text('과실 비율이 뭔가요?'));
    await tester.pump();

    expect(service.sent, ['첫 질문']);
    expect(find.text('보존할 초안'), findsOneWidget);

    send.complete(ChatSendResult(
      messages: [message('question', '첫 질문')],
      llm: const ChatLlmResult(
        provider: 'real',
        status: ChatLlmStatus.complete,
      ),
    ));
    await tester.pumpAndSettle();
  });

  testWidgets('history loading blocks every submit path without clearing draft',
      (tester) async {
    final history = Completer<List<CaseChatMessage>>();
    final service = _ControlledChatService(historyRequests: [history]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          home: Scaffold(
            body: ChatbotSheet(caseId: 'case-a', userId: 'driver-a'),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '기록 로딩 중 초안');
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.tap(find.text('과실 비율이 뭔가요?'));
    await tester.pump();

    expect(service.sent, isEmpty);
    expect(find.text('기록 로딩 중 초안'), findsOneWidget);

    history.complete(const []);
    await tester.pumpAndSettle();
  });

  testWidgets('thread chat stays in a modal sheet and remains keyboard-safe',
      (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1170, 1944);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => ThreadChatTestAuth()),
          threadChatServiceProvider.overrideWithValue(ControlledThreads()),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showChatbotSheet(
                    context,
                    caseId: 'case-a',
                    userId: 'driver-a',
                  ),
                  child: const Text('open chat'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open chat'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('open chat'), findsOneWidget);

    await tester.tap(find.byType(TextField));
    for (var toggle = 0; toggle < 3; toggle++) {
      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('AI 연결은 보류 중입니다. 대화 기록과 추가 진술을 저장할 수 있습니다.'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.getBottomRight(find.byType(TextField)).dy,
        lessThanOrEqualTo(648 - 300),
      );

      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('AI 연결은 보류 중입니다. 대화 기록과 추가 진술을 저장할 수 있습니다.'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    }
  });
}

class _ControlledChatService extends ChatService {
  _ControlledChatService({
    this.history = const [],
    this.send,
    this.historyRequests = const [],
  }) : super(accessToken: _token);

  final List<CaseChatMessage> history;
  final Completer<ChatSendResult>? send;
  final List<Completer<List<CaseChatMessage>>> historyRequests;
  final List<String> sent = [];
  int _historyIndex = 0;

  static Future<String?> _token() async => 'token';

  @override
  Future<List<CaseChatMessage>> fetchHistory(String caseId) {
    if (_historyIndex < historyRequests.length) {
      return historyRequests[_historyIndex++].future;
    }
    return Future.value(history);
  }

  @override
  Future<ChatSendResult> sendMessage(
    String caseId,
    String text, {
    List<String> fileIds = const [],
    VehicleMovements? movements,
  }) {
    sent.add(text);
    return send?.future ??
        Future.value(const ChatSendResult(
          messages: [],
          llm: ChatLlmResult(
            provider: 'mock',
            status: ChatLlmStatus.mock,
          ),
        ));
  }
}
