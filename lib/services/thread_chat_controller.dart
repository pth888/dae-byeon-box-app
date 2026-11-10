import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'auth_service.dart';
import 'case_service.dart';
import 'thread_chat_service.dart';

class ThreadChatState {
  const ThreadChatState({this.threads = const [], this.selected,
    this.messages = const [], this.context, this.loading = false,
    this.sending = false, this.listLoading = false, this.error,
    this.listError, this.retryText, this.retryRequestId});
  final List<ChatThread> threads;
  final ChatThread? selected;
  final List<ThreadMessage> messages;
  final Map<String, dynamic>? context;
  final bool loading;
  final bool sending;
  final bool listLoading;
  final String? error;
  final String? listError;
  final String? retryText;
  final String? retryRequestId;

  ThreadChatState copyWith({List<ChatThread>? threads, ChatThread? selected,
    List<ThreadMessage>? messages, Map<String, dynamic>? context, bool? loading,
    bool? sending, bool? listLoading, String? error, String? listError,
    String? retryText, String? retryRequestId, bool clearError = false,
    bool clearListError = false, bool clearRetry = false}) => ThreadChatState(
      threads: threads ?? this.threads, selected: selected ?? this.selected,
      messages: messages ?? this.messages, context: context ?? this.context,
      loading: loading ?? this.loading, sending: sending ?? this.sending,
      listLoading: listLoading ?? this.listLoading,
      error: clearError ? null : error ?? this.error,
      listError: clearListError ? null : listError ?? this.listError,
      retryText: clearRetry ? null : retryText ?? this.retryText,
      retryRequestId: clearRetry ? null : retryRequestId ?? this.retryRequestId);
}

class ThreadChatController extends StateNotifier<ThreadChatState> {
  ThreadChatController(this.service) : super(const ThreadChatState());
  final ThreadChatService service;
  int _revision = 0;
  int _listRevision = 0;
  bool _legacySynced = false;
  bool _current(int request) => mounted && request == _revision;

  void newChat() {
    ++_revision;
    state = ThreadChatState(threads: state.threads, listLoading: state.listLoading,
      listError: state.listError);
  }

  Future<void> refreshThreads() async {
    final request = ++_listRevision;
    state = state.copyWith(listLoading: true, clearListError: true);
    try {
      String? importError;
      if (!_legacySynced) {
        try {
          await service.syncLegacy();
          _legacySynced = true;
        } catch (_) {
          importError = '이전 사고 대화를 가져오지 못했습니다. 내역을 새로고침하면 다시 시도합니다.';
        }
      }
      final threads = await service.listThreads();
      if (!mounted || request != _listRevision) return;
      state = state.copyWith(threads: threads, listLoading: false, listError: importError);
    } catch (error) {
      if (!mounted || request != _listRevision) return;
      state = state.copyWith(listLoading: false, listError: _message(error));
    }
  }

  Future<void> openThread(ChatThread thread) async {
    final request = ++_revision;
    state = ThreadChatState(threads: state.threads, selected: thread,
      loading: true, listLoading: state.listLoading, listError: state.listError);
    try {
      final detail = await service.detail(thread.id);
      if (!_current(request)) return;
      final messages = await service.history(thread.id);
      if (!_current(request)) return;
      state = state.copyWith(selected: detail.thread, context: detail.context,
        messages: messages, loading: false);
    } catch (error) {
      if (!_current(request)) return;
      state = state.copyWith(loading: false, error: _message(error));
    }
  }

  Future<void> openAccident(String caseId) async {
    final request = ++_revision;
    state = ThreadChatState(threads: state.threads, loading: true,
      listLoading: state.listLoading, listError: state.listError);
    try {
      final thread = await service.createThread(caseId: caseId);
      if (!_current(request)) return;
      await openThread(thread);
      if (mounted) await refreshThreads();
    } catch (error) {
      if (!_current(request)) return;
      state = state.copyWith(loading: false, error: _message(error));
    }
  }

  Future<bool> send(String text, {String? requestId}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.loading || state.sending) return false;
    // Groq 무료 한도(분당 8,000토큰)에 맞춰 질문 길이를 줄여 둔다
    if (trimmed.runes.length > kThreadChatMaxChars) {
      state = state.copyWith(
          error: '메시지는 $kThreadChatMaxChars자 이하로 입력해 주세요.');
      return false;
    }
    final request = _revision;
    final id = requestId ?? const Uuid().v4();
    state = state.copyWith(sending: true, clearError: true);
    try {
      var selected = state.selected;
      if (selected == null) {
        selected = await service.createThread();
        if (!_current(request)) return false;
        state = state.copyWith(selected: selected);
      }
      state = state.copyWith(messages: [
        ...state.messages.where((m) => !(m.isPending && m.requestId == id)),
        if (!state.messages.any((m) => m.requestId == id && m.isUser && !m.isPending))
          ThreadMessage(id: 'pending:$id', role: 'user', text: trimmed,
            createdAt: DateTime.now(), requestId: id),
      ]);
      final reply = await service.send(selected.id, trimmed, id);
      if (!_current(request)) return false;
      final messages = <String, ThreadMessage>{
        for (final m in state.messages)
          if (!(m.isPending && m.requestId == id)) m.id: m,
        for (final m in reply.messages) m.id: m,
      }.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      state = state.copyWith(messages: messages, sending: false,
        error: reply.paused ? null
          : reply.complete ? (reply.contextWindowed
          ? '전체 기록은 보존하고, 최근 대화와 이번 질문에 관련된 진술을 골라 참고했습니다.' : null)
          : const {'groq_not_configured', 'grok_not_configured'}.contains(reply.errorCode)
          ? '질문은 저장됐습니다. 서버에 AI API 키와 모델을 설정해 주세요.'
          : '질문은 저장됐지만 AI 답변을 받지 못했습니다. 다시 시도할 수 있습니다.',
        clearError: reply.paused || (reply.complete && !reply.contextWindowed), clearRetry: reply.complete || reply.paused,
        retryText: reply.complete || reply.paused ? null : trimmed,
        retryRequestId: reply.complete || reply.paused ? null : id);
      // A failed context refresh must not turn a successfully saved reply into a failed send.
      try {
        final detail = await service.detail(selected.id);
        if (_current(request)) state = state.copyWith(context: detail.context);
      } catch (_) {
        if (_current(request) && state.error == null) {
          state = state.copyWith(error: '답변은 저장됐습니다. JSON을 다시 확인하려면 대화를 다시 열어 주세요.');
        }
      }
      if (mounted) await refreshThreads();
      return reply.complete || reply.paused;
    } catch (error) {
      if (!_current(request)) return false;
      state = state.copyWith(sending: false, error: _message(error),
        retryText: trimmed, retryRequestId: id);
      return false;
    }
  }

  /// 대화 삭제. 실패하면 사용자에게 보여줄 문구를, 성공하면 null 을 돌려준다.
  Future<String?> deleteThread(ChatThread thread) async {
    try {
      await service.deleteThread(thread.id);
    } catch (error) {
      return _message(error);
    }
    if (!mounted) return null;
    final remaining = state.threads.where((t) => t.id != thread.id).toList();
    if (state.selected?.id == thread.id) {
      // 보고 있던 대화를 지웠으면 새 대화 화면으로
      ++_revision;
      state = ThreadChatState(threads: remaining, listLoading: state.listLoading,
        listError: state.listError);
    } else {
      state = state.copyWith(threads: remaining);
    }
    return null;
  }

  Future<bool> retry() async {
    final text = state.retryText;
    if (text == null) return false;
    return send(text, requestId: state.retryRequestId);
  }

  static String _message(Object error) => error is ThreadChatException
    ? error.message : '대화를 불러오지 못했습니다. 다시 시도해 주세요.';
}

final threadChatControllerProvider = StateNotifierProvider.autoDispose
  .family<ThreadChatController, ThreadChatState, String>((ref, instance) {
    ref.watch(authProvider.select(authenticatedPrincipal));
    return ThreadChatController(ref.read(threadChatServiceProvider));
  });
