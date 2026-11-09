import 'dart:async';

import 'package:blackbox_driver_care/services/auth_service.dart';
import 'package:blackbox_driver_care/services/thread_chat_service.dart';

ChatThread thread(String id, {String mode = 'general'}) => ChatThread(
      id: id,
      mode: mode,
      title: id,
      caseId: mode == 'accident' ? 'case-a' : null,
      updatedAt: DateTime.utc(2026, 11, 9),
    );


class ControlledThreads extends ThreadChatService {
  ControlledThreads() : super(accessToken: () async => 'token');

  final pending = <String, Completer<ChatThreadDetail>>{};
  Completer<ThreadReply>? reply;
  bool complete = true;
  String? lastRequest;

  @override
  Future<List<ChatThread>> listThreads() async => [];

  @override
  Future<void> syncLegacy() async {}

  @override
  Future<ChatThread> createThread({String? caseId}) async =>
      thread(caseId ?? 'general', mode: caseId == null ? 'general' : 'accident');

  @override
  Future<ChatThreadDetail> detail(String id) async => pending[id]?.future ??
      Future.value(ChatThreadDetail(thread(id,
          mode: id == 'case-a' ? 'accident' : 'general'),
          id == 'case-a' ? {'case_id': id} : null));

  @override
  Future<List<ThreadMessage>> history(String id) async => [];

  @override
  Future<ThreadReply> send(String id, String text, String requestId) async {
    lastRequest = requestId;
    return reply?.future ?? Future.value(ThreadReply([], complete));
  }
}

class ThreadChatTestAuth extends AuthNotifier {
  ThreadChatTestAuth() : super(restoreSession: false, initialAccessToken: 'token') {
    state = const AuthState(status: AuthStatus.authenticated, email: 'driver@example.com');
  }
}
