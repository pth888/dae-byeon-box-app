import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../services/auth_service.dart';
import '../../services/consent_service.dart';
import '../../services/thread_chat_controller.dart';
import '../../services/thread_chat_service.dart';
import '../../utils/theme.dart';
import '../../widgets/accident_case_picker_sheet.dart';

/// Each entry starts a new general draft. Only an explicitly supplied case opens
/// an accident conversation; the app-wide activeCaseProvider is not consulted.
class ThreadChatScreen extends ConsumerStatefulWidget {
  const ThreadChatScreen(
      {super.key, this.initialCaseId, this.keyboardVisible = false});
  final String? initialCaseId;
  // The outer sheet consumes the keyboard inset to position itself.
  final bool keyboardVisible;

  @override
  ConsumerState<ThreadChatScreen> createState() => _ThreadChatScreenState();
}

class _ThreadChatScreenState extends ConsumerState<ThreadChatScreen> {
  final _instance = const Uuid().v4();
  final _scaffold = GlobalKey<ScaffoldState>();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _lastMessageCount = 0;
  String? _inputThread;
  bool _preparingSend = false;
  int _conversationRevision = 0;

  static const _quickQuestions = [
    '과실 비율이 뭔가요?',
    '사고 후 신고 방법',
    '블랙박스 영상 보존',
    '보험사 연락 방법',
  ];

  ThreadChatController get controller =>
      ref.read(threadChatControllerProvider(_instance).notifier);

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      controller.refreshThreads();
      final id = widget.initialCaseId;
      if (id != null) controller.openAccident(id);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _newChat() {
    _conversationRevision++;
    controller.newChat();
    _input.clear();
    _lastMessageCount = 0;
  }

  Future<void> _chooseAccident() async {
    final identity = ref.read(authProvider).email;
    final id = await showAccidentCasePicker(
      context,
      currentCaseId:
          ref.read(threadChatControllerProvider(_instance)).selected?.caseId,
    );
    if (!mounted || id == null || identity != ref.read(authProvider).email) {
      return;
    }
    _conversationRevision++;
    _input.clear();
    _lastMessageCount = 0;
    await controller.openAccident(id);
  }

  Future<bool> _consentToSend() async {
    if (!kThreadChatAiEnabled) return true;
    if (!ref.read(consentControllerProvider).canUseExternalAi) {
      final manage = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('외부 AI 동의가 필요해요'),
          content: const Text(
            '대화 내용과 선택한 사고의 분석 JSON·추가 진술을 '
            '$kThreadChatProviderLabel으로 전송해 답변을 생성합니다. 동의 관리에서 외부 AI 선택 동의를 확인해 주세요.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('동의 관리'),
            ),
          ],
        ),
      );
      if (mounted && manage == true) context.push('/consents');
      return false;
    }
    return true;
  }

  Future<void> _send({String? suggestion, bool retry = false}) async {
    final before = ref.read(threadChatControllerProvider(_instance));
    if (_preparingSend || before.loading || before.sending) return;
    // Capture the tapped label before any asynchronous consent or API work.
    // A quick question never reads or consumes the unrelated composer draft.
    final text = (suggestion ?? _input.text).trim();
    if (!retry && text.isEmpty) return;
    final identity = ref.read(authProvider).email;
    final selected = before.selected?.id;
    final revision = _conversationRevision;
    _preparingSend = true;
    try {
      if (!await _consentToSend() || !mounted) return;
      if (revision != _conversationRevision ||
          identity != ref.read(authProvider).email ||
          selected !=
              ref.read(threadChatControllerProvider(_instance)).selected?.id) {
        return;
      }
      if (retry) {
        await controller.retry();
      } else {
        if (suggestion == null && _input.text.trim() == text) _input.clear();
        await controller.send(text);
      }
    } finally {
      _preparingSend = false;
    }
  }

  void _openHistory() {
    controller.refreshThreads();
    _scaffold.currentState?.openDrawer();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (previous?.email != next.email || previous?.status != next.status) {
        _input.clear();
        _lastMessageCount = 0;
      }
    });
    final auth = ref.watch(authProvider);
    if (auth.status != AuthStatus.authenticated) {
      return const Scaffold(body: Center(child: Text('로그인 후 대화를 이용해 주세요.')));
    }
    final state = ref.watch(threadChatControllerProvider(_instance));
    final selected = state.selected;
    final keyboardVisible =
        widget.keyboardVisible || MediaQuery.viewInsetsOf(context).bottom > 0;
    if (_inputThread != selected?.id) {
      _inputThread = selected?.id;
      _lastMessageCount = 0;
    }
    if (_lastMessageCount != state.messages.length) {
      _lastMessageCount = state.messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }
      });
    }
    return Scaffold(
      key: _scaffold,
      backgroundColor: AppTheme.bgBlack,
      resizeToAvoidBottomInset: false,
      drawer: _historyDrawer(state),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              children: [
                _header(state),
                if (selected?.isAccident == true) _contextBanner(state),
                Expanded(
                  child: state.loading
                      ? const Center(child: CircularProgressIndicator())
                      : state.messages.isEmpty
                          ? _welcome(state, keyboardVisible: keyboardVisible)
                          : _messages(state),
                ),
                if (!keyboardVisible) _caseSelectButton(state),
                if (state.sending)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 10),
                        Text(
                          kThreadChatAiEnabled
                              ? 'AI 답변을 기다리고 있어요'
                              : '메시지를 저장하고 있어요',
                          style: TextStyle(
                            color: AppTheme.textSub,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (state.error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          state.error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppTheme.warningOrange,
                            fontSize: 12,
                          ),
                        ),
                        if (state.retryText != null) ...[
                          const SizedBox(height: 10),
                          _retryButton(
                            label: '답변 다시 요청',
                            onPressed: state.sending
                                ? null
                                : () => _send(retry: true),
                          ),
                        ] else if (selected != null) ...[
                          const SizedBox(height: 10),
                          _retryButton(
                            label: '대화 다시 불러오기',
                            onPressed: () => controller.openThread(selected),
                          ),
                        ],
                      ],
                    ),
                  ),
                if (!keyboardVisible)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Text(
                      legalReferenceWarning,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppTheme.warningOrange,
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ),
                _composer(state),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 10),
                  child: Text(
                    kThreadChatAiEnabled
                        ? 'AI는 실수할 수 있습니다. 사고·법률 안내는 참고용입니다.'
                        : 'AI 연결은 보류 중입니다. 대화 기록과 추가 진술을 저장할 수 있습니다.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textHint, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ThreadChatState state) => Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppTheme.textHint,
              borderRadius: BorderRadius.circular(100),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '문처리',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            decoration: const BoxDecoration(
                              color: kThreadChatAiEnabled
                                  ? Colors.greenAccent
                                  : AppTheme.textHint,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            state.selected?.isAccident == true
                                ? 'AI 상담 · 사고 대화'
                                : 'AI 상담 · 일반 대화',
                            style: const TextStyle(
                              color: AppTheme.textSub,
                              fontSize: 11,
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '새 채팅',
                  onPressed: _newChat,
                  color: AppTheme.textSub,
                  icon: const Icon(Icons.edit_square, size: 20),
                ),
                IconButton(
                  tooltip: '채팅 닫기',
                  color: AppTheme.textSub,
                  icon: const Icon(Icons.close_rounded, size: 24),
                  onPressed: () {
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    } else {
                      context.go('/');
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      );

  Widget _caseSelectButton(ThreadChatState state) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: state.loading ? null : _chooseAccident,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.pointWhite,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: const StadiumBorder(),
            ),
            icon: const Icon(Icons.video_library_outlined, size: 18),
            label: Text(
              state.selected?.isAccident == true ? '상담할 사고 변경' : '상담할 사고 선택',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
        ),
      );

  Widget _contextBanner(ThreadChatState state) {
    final context = state.context;
    final facts = (context?['user_provided_facts'] as List?)?.length ?? 0;
    final ready = context?['status'] == 'ready';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Material(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.folder_open_outlined, size: 22),
          title: Text(
            state.selected!.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            context == null
                ? '사고 JSON을 불러오는 중'
                : ready
                    ? '분석 v${context['report_version']} · 추가 진술 $facts개'
                    : '분석 대기 중 · 추가 진술 $facts개',
          ),
          trailing: const Icon(Icons.data_object, size: 20),
          onTap: context == null ? null : () => _showContext(context),
        ),
      ),
    );
  }

  void _showContext(Map<String, dynamic> value) {
    final owner = ref.read(authProvider).email;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surfaceDark,
      builder: (ctx) => Consumer(
        builder: (ctx, accountRef, _) {
          if (accountRef.watch(authProvider).email != owner) {
            return const SafeArea(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('계정이 변경되어 사고 기록을 닫았습니다.'),
              ),
            );
          }
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(ctx).height * 0.75,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    title: const Text('이 사고의 대화 기록 JSON'),
                    subtitle: const Text('원본 분석과 검증되지 않은 사용자 진술을 구분해 보관합니다.'),
                    trailing: IconButton(
                      tooltip: '닫기',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: SelectableText(
                        const JsonEncoder.withIndent('  ').convert(value),
                        style: const TextStyle(fontSize: 12, height: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _welcome(ThreadChatState state, {required bool keyboardVisible}) =>
      LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                      child: _bubble(
                        text: state.selected?.isAccident == true
                            ? '선택한 사고에 대해 이야기해 주세요. 추가로 알려주시는 내용은 이 사고의 대화에 기록됩니다.'
                            : '안녕하세요! 문처리입니다. 궁금한 점을 편하게 물어보세요. 사고 상담은 아래에서 사고를 선택해 주세요.',
                        isUser: false,
                      )),
                  if (!keyboardVisible) _suggestions(state),
                ]),
          ),
        ),
      );

  Widget _suggestions(ThreadChatState state) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final question in _quickQuestions)
              InkWell(
                onTap: state.loading || state.sending
                    ? null
                    : () => _send(suggestion: question),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.north_east_rounded,
                        color: AppTheme.textHint,
                        size: 16,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          question,
                          style: const TextStyle(
                            color: AppTheme.textSub,
                            fontSize: 14,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _bubble({
    required String text,
    required bool isUser,
    bool pending = false,
  }) =>
      LayoutBuilder(
        builder: (context, constraints) => Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            crossAxisAlignment:
                isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (!isUser)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8, left: 2),
                  child: Text(
                    '문처리',
                    style: TextStyle(
                      color: AppTheme.textHint,
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              Container(
                // 답변은 표가 들어가는 경우가 많아 폭을 넓게 쓴다
                constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * (isUser ? 0.78 : 1.0)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: isUser ? AppTheme.pointWhite : AppTheme.surfaceDark,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isUser)
                      SelectableText(
                        text,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 14,
                          fontWeight: FontWeight.w300,
                          height: 1.5,
                        ),
                      )
                    else
                      MarkdownBody(
                        data: tidyChatMarkdown(text),
                        selectable: true,
                        styleSheet: _answerStyle,
                      ),
                    if (pending)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          '전송 확인 중',
                          style:
                              TextStyle(fontSize: 10, color: AppTheme.textHint),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _messages(ThreadChatState state) => ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
        itemCount: state.messages.length,
        itemBuilder: (ctx, index) {
          final message = state.messages[index];
          return _bubble(
            text: message.text,
            isUser: message.isUser,
            pending: message.isPending,
          );
        },
      );

  /// 오류 아래 다시 시도 버튼 (가운데, 테두리 있는 알약 모양)
  Widget _retryButton({required String label, VoidCallback? onPressed}) =>
      Center(
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            disabledForegroundColor: AppTheme.textHint,
            side: const BorderSide(color: Color(0xFF5A5A5E)),
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            minimumSize: const Size(0, 40),
            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ),
      );

  Widget _composer(ThreadChatState state) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 24, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: '대화 내역',
              onPressed: _openHistory,
              color: Colors.white,
              icon: const Icon(Icons.notes_rounded, size: 22),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceDark,
                  borderRadius: BorderRadius.circular(100),
                ),
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 8000,
                  enabled: !state.loading && !state.sending,
                  textInputAction: TextInputAction.newline,
                  cursorColor: Colors.white,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w300,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    counterText: '',
                    filled: false,
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                    hintText: '메시지 입력',
                    hintStyle: TextStyle(
                      color: AppTheme.textHint,
                      fontSize: 14,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filled(
              tooltip: '메시지 전송',
              style: IconButton.styleFrom(
                backgroundColor: AppTheme.pointWhite,
                foregroundColor: Colors.black,
                minimumSize: const Size(46, 46),
              ),
              onPressed: state.loading || state.sending ? null : () => _send(),
              icon: const Icon(Icons.arrow_upward_rounded, size: 20),
            ),
          ],
        ),
      );

  Widget _historyDrawer(ThreadChatState state) => Drawer(
        backgroundColor: const Color(0xFF15161A),
        child: SafeArea(
          child: Column(
            children: [
              ListTile(
                title: const Text('대화 내역', style: TextStyle(fontSize: 18)),
                trailing: IconButton(
                  tooltip: '내역 새로고침',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed:
                      state.listLoading ? null : controller.refreshThreads,
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('새 채팅'),
                    onPressed: () {
                      Navigator.pop(context);
                      _newChat();
                    },
                  ),
                ),
              ),
              if (state.listLoading)
                const LinearProgressIndicator(minHeight: 2),
              if (state.listError != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    state.listError!,
                    style: const TextStyle(
                      color: AppTheme.warningOrange,
                      fontSize: 12,
                    ),
                  ),
                ),
              Expanded(
                child: ListView(
                  children: [
                    _historySection(
                      '사고별 대화',
                      state.threads.where((t) => t.isAccident).toList(),
                      state,
                    ),
                    _historySection(
                      '일반 대화',
                      state.threads.where((t) => !t.isAccident).toList(),
                      state,
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '대화 내역은 로그인한 계정별로 저장됩니다.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSub),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _historySection(
    String title,
    List<ChatThread> threads,
    ThreadChatState state,
  ) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 16, 8),
            child: Text(
              title,
              style: const TextStyle(color: AppTheme.textSub, fontSize: 12),
            ),
          ),
          if (threads.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 16, 8),
              child: Text(
                '저장된 대화가 없어요',
                style: TextStyle(color: AppTheme.textHint, fontSize: 12),
              ),
            ),
          for (final thread in threads)
            ListTile(
              selected: state.selected?.id == thread.id,
              selectedTileColor: const Color(0xFF292A30),
              leading: Icon(
                thread.isAccident
                    ? Icons.folder_outlined
                    : Icons.chat_bubble_outline,
                size: 18,
              ),
              title: Text(
                thread.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                _date(thread.updatedAt),
                style: const TextStyle(fontSize: 10, color: AppTheme.textHint),
              ),
              trailing: IconButton(
                tooltip: '대화 삭제',
                icon: const Icon(Icons.delete_outline_rounded,
                    size: 20, color: AppTheme.textHint),
                onPressed: () => _confirmDelete(thread),
              ),
              onTap: () {
                Navigator.pop(context);
                _conversationRevision++;
                _input.clear();
                controller.openThread(thread);
              },
              onLongPress: () => _confirmDelete(thread),
            ),
        ],
      );

  /// 대화 삭제 확인 → 삭제
  /// 챗봇 대화만 지운다. 사고 기록·과실 분석·영상은 그대로 둔다.
  Future<void> _confirmDelete(ChatThread thread) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: const Text('대화 삭제',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: Text(
          '"${thread.title}" 대화를 삭제할까요?\n\n'
          '이 대화의 메시지만 지워집니다. 사고 기록, 과실 분석 결과, 영상은 그대로 남습니다.\n'
          '삭제한 대화는 되돌릴 수 없습니다.',
          style: const TextStyle(
              color: AppTheme.textSub, fontSize: 13.5, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소', style: TextStyle(color: AppTheme.textSub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: AppTheme.errorRed)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final wasSelected =
        ref.read(threadChatControllerProvider(_instance)).selected?.id ==
            thread.id;
    final error = await controller.deleteThread(thread);
    if (!mounted) return;
    if (error == null && wasSelected) {
      _conversationRevision++;
      _input.clear();
      _lastMessageCount = 0;
    }
    messenger.showSnackBar(
        SnackBar(content: Text(error ?? '대화를 삭제했습니다.')));
  }

  String _date(DateTime value) {
    final date = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}.${two(date.month)}.${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }
}

// ── 챗봇 답변 표시 스타일 ───────────────────────────────────
const _answerText = TextStyle(
  color: Colors.white,
  fontSize: 14,
  fontWeight: FontWeight.w300,
  height: 1.5,
);
const _tableLine = Color(0xFF3A3A3E);

final _answerStyle = MarkdownStyleSheet(
  p: _answerText,
  strong: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
  em: const TextStyle(color: Colors.white, fontStyle: FontStyle.italic),
  h1: const TextStyle(
      color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600, height: 1.4),
  h2: const TextStyle(
      color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600, height: 1.4),
  h3: const TextStyle(
      color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600, height: 1.4),
  h4: const TextStyle(
      color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600, height: 1.4),
  listBullet: _answerText,
  a: const TextStyle(color: Colors.white, decoration: TextDecoration.underline),
  code: const TextStyle(
    color: Colors.white,
    backgroundColor: Color(0xFF2C2C2E),
    fontSize: 13,
  ),
  codeblockDecoration: BoxDecoration(
    color: const Color(0xFF2C2C2E),
    borderRadius: BorderRadius.circular(8),
  ),
  // 인용(> 주의 ...) : 밝은 파란 배경 대신 왼쪽 선만 있는 어두운 상자
  blockquote: const TextStyle(
      color: Color(0xFFD1D1D6), fontSize: 13.5, fontWeight: FontWeight.w300, height: 1.5),
  blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
  blockquoteDecoration: const BoxDecoration(
    color: Color(0xFF262628),
    border: Border(left: BorderSide(color: AppTheme.warningOrange, width: 3)),
  ),
  horizontalRuleDecoration: const BoxDecoration(
    border: Border(top: BorderSide(color: _tableLine, width: 1)),
  ),
  // 표
  tableHead: const TextStyle(
      color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600, height: 1.4),
  tableBody: const TextStyle(
      color: Color(0xFFE5E5EA), fontSize: 13, fontWeight: FontWeight.w300, height: 1.45),
  tableHeadAlign: TextAlign.left,
  tableBorder: const TableBorder(
    top: BorderSide(color: _tableLine),
    bottom: BorderSide(color: _tableLine),
    horizontalInside: BorderSide(color: _tableLine),
    verticalInside: BorderSide(color: Color(0xFF2A2A2D)),
  ),
  tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
  tableColumnWidth: const FlexColumnWidth(),
  tableCellsDecoration: const BoxDecoration(color: Color(0xFF1A1A1C)),
);

/// LLM 답변을 화면에 맞게 다듬는다.
///   - 표 칸 안의 <br> 는 줄바꿈 대신 " · " 로 (마크다운 표는 칸 안 줄바꿈을 못 함)
///   - 표 밖의 <br> 는 줄바꿈
///   - \text{..}, \times, \frac{a}{b} 같은 수식 기호를 일반 글자로
///   - "**과실 비율(결함률)**은" 처럼 괄호·따옴표 뒤에 조사가 붙으면 굵게가 안 먹는 문제 보정
String tidyChatMarkdown(String raw) {
  final br = RegExp(r'<br\s*/?>', caseSensitive: false);
  final lines = raw.replaceAll('\r', '').split('\n').map((line) {
    final isTableRow = line.trimLeft().startsWith('|');
    return line.replaceAll(br, isTableRow ? ' · ' : '\n');
  });
  var s = lines.join('\n');

  // 수식 → 일반 글자
  s = s
      .replaceAll(RegExp(r'\\\[|\\\]|\\\(|\\\)|\$\$'), '')
      .replaceAllMapped(RegExp(r'\\text\{([^{}]*)\}'), (m) => m[1]!)
      .replaceAllMapped(
          RegExp(r'\\frac\{([^{}]*)\}\{([^{}]*)\}'), (m) => '(${m[1]}) ÷ (${m[2]})')
      .replaceAll(r'\times', '×')
      .replaceAll(r'\div', '÷')
      .replaceAll(r'\cdot', '·')
      .replaceAll(r'\%', '%')
      .replaceAll(r'\leq', '≤')
      .replaceAll(r'\geq', '≥');

  // 굵게 보정: 닫는 ** 앞이 문장부호이고 바로 뒤에 글자가 오면 아주 얇은 공백을 넣는다
  s = s.replaceAllMapped(
    RegExp(r'''(\*\*[^*\n]+?[)\]"'’”.,:;!?%])\*\*(?=[가-힣A-Za-z0-9])'''),
    (m) => '${m[1]}**\u200A',
  );
  // 여는 ** 앞이 글자이고 바로 뒤가 문장부호면 같은 방식으로 보정
  s = s.replaceAllMapped(
    RegExp(r'''(?<=[가-힣A-Za-z0-9])\*\*(?=[("'‘“\[])'''),
    (m) => '\u200A**',
  );
  return s;
}
