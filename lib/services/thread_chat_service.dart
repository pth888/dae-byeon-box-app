import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_service.dart';

const kChatApiBaseUrl = String.fromEnvironment(
  'CHAT_API_BASE_URL',
  defaultValue: kApiBaseUrl,
);

// Set by the server launch/build configuration. No API keys are bundled here.
const kThreadChatAiEnabled = bool.fromEnvironment('CHAT_LLM_ENABLED', defaultValue: false) ||
    String.fromEnvironment('CHAT_LLM_ENABLED') == '1';
const kThreadChatProvider = String.fromEnvironment('CHAT_LLM_PROVIDER', defaultValue: 'groq');
const kThreadChatProviderLabel = kThreadChatProvider == 'xai' ? 'xAI Grok' : 'Groq';

class ThreadChatException implements Exception {
  const ThreadChatException(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}

class ChatThread {
  const ChatThread({required this.id, required this.mode, required this.title,
    required this.updatedAt, this.caseId});
  final String id;
  final String mode;
  final String title;
  final String? caseId;
  final DateTime updatedAt;
  bool get isAccident => mode == 'accident';

  factory ChatThread.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final mode = json['mode'];
    final caseId = json['case_id'];
    final date = DateTime.tryParse(json['updated_at']?.toString() ?? '');
    if (id is! String || !RegExp(r'^thread_[0-9a-f]{32}$').hasMatch(id) ||
        !const {'general', 'accident'}.contains(mode) || date == null ||
        json['title'] is! String ||
        (mode == 'general' && caseId != null) ||
        (mode == 'accident' && (caseId is! String ||
          !RegExp(r'^case_[0-9a-f]{32}$').hasMatch(caseId)))) {
      throw const ThreadChatException('대화 응답 형식이 올바르지 않습니다.');
    }
    return ChatThread(id: id, mode: mode as String, title: json['title'] as String,
      updatedAt: date, caseId: caseId as String?);
  }
}

class ThreadMessage {
  const ThreadMessage({required this.id, required this.role, required this.text,
    required this.createdAt, required this.requestId});
  final String id;
  final String role;
  final String text;
  final DateTime createdAt;
  final String requestId;
  bool get isUser => role == 'user';
  bool get isPending => id.startsWith('pending:');

  factory ThreadMessage.fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String || json['text'] is! String ||
        json['request_id'] is! String ||
        !const {'user', 'assistant'}.contains(json['role'])) {
      throw const ThreadChatException('메시지 응답 형식이 올바르지 않습니다.');
    }
    final date = DateTime.tryParse(json['created_at']?.toString() ?? '');
    if (date == null) throw const ThreadChatException('메시지 시각이 올바르지 않습니다.');
    return ThreadMessage(id: json['id'] as String, role: json['role'] as String,
      text: json['text'] as String, createdAt: date, requestId: json['request_id'] as String);
  }
}

class ChatThreadDetail {
  const ChatThreadDetail(this.thread, this.context);
  final ChatThread thread;
  final Map<String, dynamic>? context;
}

class ThreadReply {
  const ThreadReply(this.messages, this.complete, {this.errorCode, this.contextWindowed = false});
  final List<ThreadMessage> messages;
  final bool complete;
  final String? errorCode;
  final bool contextWindowed;
  bool get paused => errorCode == 'llm_paused';
}

class ThreadChatService {
  ThreadChatService({Dio? dio, required Future<String?> Function() accessToken,
    int Function()? sessionGeneration})
    : _dio = dio ?? Dio(BaseOptions(baseUrl: kChatApiBaseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 100),
        validateStatus: (status) => status != null && status < 600)),
      _accessToken = accessToken, _generation = sessionGeneration ?? (() => 0);

  final Dio _dio;
  final Future<String?> Function() _accessToken;
  final int Function() _generation;
  static const _root = '/api/v1/chat/threads';

  Future<Map<String, dynamic>> _request(String method, String path,
      {Map<String, dynamic>? body, Map<String, dynamic>? query,
      bool allowEmpty = false}) async {
    final generation = _generation();
    final token = await _accessToken();
    if (generation != _generation()) {
      throw const ThreadChatException('로그인 계정이 변경되었습니다.');
    }
    if (token == null || token.isEmpty) {
      throw const ThreadChatException('로그인이 필요합니다.');
    }
    try {
      final response = await _dio.request(path, data: body, queryParameters: query,
        options: Options(method: method, headers: {'Authorization': 'Bearer $token'}));
      if (generation != _generation()) {
        throw const ThreadChatException('로그인 계정이 변경되었습니다.');
      }
      final raw = response.data;
      if (allowEmpty && response.statusCode == 204) return const {};
      if (response.statusCode != 200 && response.statusCode != 201) {
        final error = raw is Map ? raw['error'] : null;
        throw ThreadChatException(
          error is Map && error['message'] is String ? error['message'] as String :
            '대화 서버에 연결하지 못했습니다. 잠시 후 다시 시도해 주세요.',
          code: error is Map ? error['code'] as String? : null);
      }
      if (raw is! Map || raw['data'] is! Map) {
        if (allowEmpty) return const {};
        throw const ThreadChatException('대화 서버 응답이 올바르지 않습니다.');
      }
      return Map<String, dynamic>.from(raw['data'] as Map);
    } on DioException {
      throw const ThreadChatException('대화 서버에 연결하지 못했습니다. 다시 시도해 주세요.');
    }
  }

  Future<List<ChatThread>> listThreads() async {
    final all = <String, ChatThread>{};
    final seen = <String>{};
    String? cursor;
    do {
      final data = await _request('GET', _root,
        query: {'limit': 100, if (cursor != null) 'cursor': cursor});
      final list = data['threads'];
      if (list is! List) throw const ThreadChatException('대화 목록이 올바르지 않습니다.');
      for (final raw in list) {
        final thread = ChatThread.fromJson(Map<String, dynamic>.from(raw as Map));
        all[thread.id] = thread;
      }
      cursor = data['next_cursor'] as String?;
      if (cursor != null && !seen.add(cursor)) {
        throw const ThreadChatException('대화 목록의 페이지 정보가 올바르지 않습니다.');
      }
    } while (cursor != null);
    return all.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> syncLegacy() async {
    final seen = <String>{};
    String? cursor;
    do {
      final data = await _request('POST', '/api/v1/chat/import-legacy',
        body: {if (cursor != null) 'cursor': cursor});
      cursor = data['next_cursor'] as String?;
      if (cursor != null && !seen.add(cursor)) {
        throw const ThreadChatException('이전 사고 대화의 페이지 정보가 올바르지 않습니다.');
      }
    } while (cursor != null);
  }

  Future<ChatThread> createThread({String? caseId}) async {
    final data = await _request('POST', _root, body: {
      'mode': caseId == null ? 'general' : 'accident',
      if (caseId != null) 'case_id': caseId,
    });
    final result = ChatThread.fromJson(Map<String, dynamic>.from(data['thread'] as Map));
    if (result.caseId != caseId) {
      throw const ThreadChatException('선택한 사고와 대화가 일치하지 않습니다.');
    }
    return result;
  }

  Future<ChatThreadDetail> detail(String id) async {
    final data = await _request('GET', '$_root/$id');
    final thread = ChatThread.fromJson(Map<String, dynamic>.from(data['thread'] as Map));
    if (thread.id != id) throw const ThreadChatException('요청한 대화와 응답이 일치하지 않습니다.');
    final context = data['context'] == null ? null :
      Map<String, dynamic>.from(data['context'] as Map);
    if ((!thread.isAccident && context != null) ||
        (thread.isAccident && context?['case_id'] != thread.caseId)) {
      throw const ThreadChatException('사고 JSON과 선택한 대화가 일치하지 않습니다.');
    }
    return ChatThreadDetail(thread, context);
  }

  Future<List<ThreadMessage>> history(String id) async {
    final all = <String, ThreadMessage>{};
    final seen = <String>{};
    String? cursor;
    do {
      final data = await _request('GET', '$_root/$id/messages',
        query: {'limit': 100, if (cursor != null) 'cursor': cursor});
      for (final raw in data['messages'] as List) {
        final message = ThreadMessage.fromJson(Map<String, dynamic>.from(raw as Map));
        all[message.id] = message;
      }
      cursor = data['next_cursor'] as String?;
      if (cursor != null && !seen.add(cursor)) {
        throw const ThreadChatException('메시지의 페이지 정보가 올바르지 않습니다.');
      }
    } while (cursor != null);
    return all.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  /// 대화방 하나를 삭제한다.
  /// 챗봇 서버의 이 대화와 메시지만 지운다. 사고·과실 분석 기록·영상 API는 호출하지 않는다.
  Future<void> deleteThread(String id) async {
    if (!RegExp(r'^thread_[0-9a-f]{32}$').hasMatch(id)) {
      throw const ThreadChatException('삭제할 대화를 찾을 수 없습니다.');
    }
    try {
      await _request('DELETE', '$_root/$id', allowEmpty: true);
    } on ThreadChatException catch (e) {
      // 이미 지워진 대화면 성공으로 본다
      if (e.code == 'thread_not_found') return;
      if (e.code == 'method_not_allowed') {
        throw const ThreadChatException(
            '아직 서버에서 대화 삭제를 지원하지 않습니다.', code: 'method_not_allowed');
      }
      rethrow;
    }
  }

  Future<ThreadReply> send(String id, String text, String requestId) async {
    final data = await _request('POST', '$_root/$id/messages',
      body: {'text': text, 'request_id': requestId});
    final llm = Map<String, dynamic>.from(data['llm'] as Map);
    return ThreadReply((data['messages'] as List).map((raw) =>
      ThreadMessage.fromJson(Map<String, dynamic>.from(raw as Map))).toList(),
      llm['status'] == 'complete', errorCode: llm['error_code'] as String?,
      contextWindowed: llm['context_windowed'] == true);
  }
}

final threadChatServiceProvider = Provider<ThreadChatService>((ref) {
  final auth = ref.read(authProvider.notifier);
  return ThreadChatService(accessToken: auth.validAccessToken,
    sessionGeneration: () => auth.sessionGeneration);
});
