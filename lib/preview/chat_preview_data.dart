// Data adapter used only by main_chat_preview.dart. No external AI or API calls.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../services/case_service.dart';
import '../services/thread_chat_service.dart';

final previewCases = [
  BackendCase(id: 'case_${'a' * 32}', deviceId: 'preview-device',
    title: '주차장 사고 (예시)', status: 'complete', createdAt: DateTime.utc(2026, 11, 9, 7, 40)),
  BackendCase(id: 'case_${'b' * 32}', deviceId: 'preview-device',
    title: '교차로 사고 (예시)', status: 'complete', createdAt: DateTime.utc(2026, 11, 2, 18, 20)),
];

class PreviewCases extends CaseService {
  PreviewCases() : super(dio: Dio(), accessToken: () async => 'preview-only',
    savedDevice: () async => (id: 'preview-device', name: '예시 기기'),
    activeCase: () => null, onActiveCaseChanged: (_) {});

  @override
  Future<CasePage> listCases(
      {int limit = 20, String? cursor, bool hasReports = false}) async =>
    CasePage(items: previewCases, nextCursor: null);

  @override
  Future<BackendCase> selectOwnedCase(String caseId) async =>
    previewCases.firstWhere((item) => item.id == caseId);
}

class PreviewThreadService extends ThreadChatService {
  PreviewThreadService({String? saved, required void Function(String) persist})
      : _persist = persist, super(accessToken: () async => 'preview-only') {
    try {
      final value = saved == null ? null : jsonDecode(saved);
      if (value is List) {
        _records.addAll(value.map((item) => Map<String, dynamic>.from(item as Map)));
        for (final record in _records) { ChatThread.fromJson(record); }
      }
    } catch (_) { _records.clear(); }
    if (_records.isEmpty) _seed();
  }

  final void Function(String) _persist;
  final List<Map<String, dynamic>> _records = [];
  String _id(String prefix) => '${prefix}_${const Uuid().v4().replaceAll('-', '')}';
  void _save() => _persist(jsonEncode(_records));
  Map<String, dynamic> _record(String id) => _records.firstWhere((item) => item['id'] == id);
  Map<String, dynamic> _clone(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

  @override
  Future<void> deleteThread(String id) async {
    _records.removeWhere((item) => item['id'] == id);
    _save();
  }

  Map<String, dynamic> _context(BackendCase item) => {
    'schema_version': 1, 'case_id': item.id, 'case_title': item.title,
    'report_version': 1, 'report_id': 'preview-report', 'status': 'ready',
    'analysis': {'source': 'preview_example',
      'summary': '화면 확인용 예시 자료입니다. 실제 분석·과실 판단이 아닙니다.',
      'law': {'status': 'preview_only', 'note': '실제 LAW JSON은 운영 서버에서 조회합니다.'}},
    'user_provided_facts': <Map<String, dynamic>>[],
  };

  Map<String, dynamic> _newRecord({BackendCase? accident}) {
    final stamp = DateTime.now().toUtc().toIso8601String();
    return {'id': _id('thread'), 'mode': accident == null ? 'general' : 'accident',
      'case_id': accident?.id, 'title': accident?.title ?? '새 채팅',
      'created_at': stamp, 'updated_at': stamp,
      'context': accident == null ? null : _context(accident),
      'messages': <Map<String, dynamic>>[]};
  }

  void _seed() {
    final record = _newRecord(accident: previewCases.first);
    _records.add(record);
    _append(record, '저는 주차장 통로에서 직진 중이었어요.', 'preview-statement');
    final general = _newRecord();
    _records.add(general);
    _append(general, '블랙박스 영상 보관에 대해 궁금해요.', 'preview-general');
    _save();
  }

  Map<String, dynamic> _append(Map<String, dynamic> record, String text, String requestId) {
    final messages = record['messages'] as List;
    final existing = messages.cast<Map>().where((m) => m['request_id'] == requestId);
    if (existing.isNotEmpty) return Map<String, dynamic>.from(existing.first);
    final stamp = DateTime.now().toUtc().toIso8601String();
    final message = {'id': _id('msg'), 'role': 'user', 'text': text,
      'created_at': stamp, 'request_id': requestId};
    messages.add(message);
    record['updated_at'] = stamp;
    if (record['mode'] == 'general' && record['title'] == '새 채팅') {
      record['title'] = String.fromCharCodes(text.runes.take(32));
    }
    final context = record['context'];
    if (context is Map) {
      (context['user_provided_facts'] as List).add({'message_id': message['id'],
        'text': text, 'created_at': stamp, 'source': 'user_statement', 'verified': false});
    }
    return message;
  }

  @override
  Future<void> syncLegacy() async {}

  @override
  Future<List<ChatThread>> listThreads() async => _records.map(ChatThread.fromJson).toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<ChatThread> createThread({String? caseId}) async {
    if (caseId != null) {
      final old = _records.where((r) => r['case_id'] == caseId);
      if (old.isNotEmpty) return ChatThread.fromJson(old.first);
    }
    final record = _newRecord(accident: caseId == null ? null :
      previewCases.firstWhere((item) => item.id == caseId));
    _records.add(record);
    _save();
    return ChatThread.fromJson(record);
  }

  @override
  Future<ChatThreadDetail> detail(String id) async {
    final record = _clone(_record(id));
    return ChatThreadDetail(ChatThread.fromJson(record),
      record['context'] == null ? null : Map<String, dynamic>.from(record['context'] as Map));
  }

  @override
  Future<List<ThreadMessage>> history(String id) async =>
    (_record(id)['messages'] as List).map((m) =>
      ThreadMessage.fromJson(Map<String, dynamic>.from(m as Map))).toList();

  @override
  Future<ThreadReply> send(String id, String text, String requestId) async {
    final message = _append(_record(id), text, requestId);
    _save();
    return ThreadReply([ThreadMessage.fromJson(message)], false, errorCode: 'llm_paused');
  }
}
