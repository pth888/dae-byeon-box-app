// lib/services/push_service.dart
//
// FCM(원격 푸시) 수신 + 백엔드 토큰 등록
//
// 역할:
//   1) firebase_messaging 으로 이 기기의 FCM 토큰을 얻는다.
//   2) 얻은 토큰을 백엔드에 등록한다:  PUT /api/v1/push/tokens
//        { "provider": "fcm", "token": "...", "device_label": "..." }
//   3) 블랙박스가 사고를 감지하면 백엔드가 이 기기로 푸시를 보낸다.
//      그 푸시를 수신하면( data.type == "accident" ) 사고 트리거 콜백을 호출한다.
//
// 흐름:  블박(충격 감지) → 백엔드 /device-events → FCM 푸시 → 이 서비스 수신
//                                                             → onAccidentPush 콜백
//                                                             → SensorNotifier.triggerFromExternal()
//
// 사용 패키지: firebase_messaging, dio, flutter_riverpod
//   (firebase_core / firebase_options 는 이미 main.dart 에서 초기화됨)
//
// NOTE: 서버 쪽 FCM 발송이 아직 Mock 이면 실제 푸시는 오지 않는다.
//       앱 구조는 완성해 두고, 서버가 실제 발송을 켜면 바로 동작한다.

import 'dart:async';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_service.dart';
import 'case_service.dart';

// 사고 푸시가 왔을 때 전달되는 정보
class AccidentPush {
  final double? lat;
  final double? lon;
  final String? caseId;
  final double? gForce;

  const AccidentPush({this.lat, this.lon, this.caseId, this.gForce});

  factory AccidentPush.fromData(Map<String, dynamic> data) {
    double? toD(dynamic v) => v == null ? null : double.tryParse(v.toString());
    return AccidentPush(
      lat: toD(data['lat']),
      lon: toD(data['lon']),
      caseId: data['case_id']?.toString(),
      gForce: toD(data['g_force'] ?? data['dynamic_g'] ?? data['gforce']),
    );
  }
}

enum AppPushType {
  accident,
  analysisReady,
  analysisNeedsInput,
  analysisFailed,
}

class AppPushEvent {
  const AppPushEvent({
    required this.type,
    required this.caseId,
    this.jobId,
    this.reportId,
    this.accident,
  });

  final AppPushType type;
  final String caseId;
  final String? jobId;
  final String? reportId;
  final AccidentPush? accident;

  static AppPushEvent? tryParse(Map<String, dynamic> data) {
    final rawType = data['type']?.toString();
    final caseId = data['case_id']?.toString();
    if (caseId == null || caseId.isEmpty) return null;
    final type = switch (rawType) {
      'accident' || 'impact' || 'device_event' => AppPushType.accident,
      'analysis_ready' => AppPushType.analysisReady,
      'analysis_needs_input' => AppPushType.analysisNeedsInput,
      'analysis_failed' => AppPushType.analysisFailed,
      _ => null,
    };
    if (type == null) return null;
    final jobId = data['job_id']?.toString();
    if (type != AppPushType.accident && (jobId == null || jobId.isEmpty)) {
      return null;
    }
    final reportId = data['report_id']?.toString();
    if ((type == AppPushType.analysisReady ||
            type == AppPushType.analysisNeedsInput) &&
        (reportId == null || reportId.isEmpty)) {
      return null;
    }
    return AppPushEvent(
      type: type,
      caseId: caseId,
      jobId: jobId,
      reportId: reportId,
      accident:
          type == AppPushType.accident ? AccidentPush.fromData(data) : null,
    );
  }
}

class PushEventDispatcher {
  const PushEventDispatcher({
    required this.onAccidentReceived,
    required this.onAccidentOpened,
    required this.onAnalysis,
  });

  final void Function(AccidentPush push) onAccidentReceived;
  final void Function(AccidentPush push) onAccidentOpened;
  final void Function(AppPushEvent event) onAnalysis;

  void dispatch(Map<String, dynamic> data, {bool opened = false}) {
    final event = AppPushEvent.tryParse(data);
    if (event == null) return;
    if (event.type != AppPushType.accident) {
      onAnalysis(event);
      return;
    }
    final accident = event.accident;
    if (accident == null) return;
    if (opened) {
      onAccidentOpened(accident);
    } else {
      onAccidentReceived(accident);
    }
  }
}

class AccidentPushRouter {
  AccidentPushRouter({
    required Future<bool> Function(String caseId) validateOwnedCase,
    required Object Function() authGeneration,
    required bool Function() canCollect,
    required void Function(AccidentPush push) onOpen,
  })  : _validateOwnedCase = validateOwnedCase,
        _authGeneration = authGeneration,
        _canCollect = canCollect,
        _onOpen = onOpen;

  final Future<bool> Function(String caseId) _validateOwnedCase;
  final Object Function() _authGeneration;
  final bool Function() _canCollect;
  final void Function(AccidentPush push) _onOpen;
  int _latestRequest = 0;

  Future<bool> handle(AccidentPush push) async {
    final caseId = push.caseId;
    if (!CaseService.isBackendCaseId(caseId) || !_canCollect()) {
      return false;
    }
    final request = ++_latestRequest;
    final generation = _authGeneration();
    try {
      if (!await _validateOwnedCase(caseId!)) return false;
    } catch (_) {
      return false;
    }
    if (request != _latestRequest ||
        _authGeneration() != generation ||
        !_canCollect()) {
      return false;
    }
    _onOpen(push);
    return true;
  }
}

class AnalysisPushRouter {
  AnalysisPushRouter({
    required Future<bool> Function(AppPushEvent event) validateEvent,
    required Object Function() authGeneration,
    required void Function(String caseId, String jobId, String reportId)
        onReady,
    required void Function(String caseId, String jobId) onNeedsInput,
    required void Function(String caseId, String jobId) onFailed,
  })  : _validateEvent = validateEvent,
        _authGeneration = authGeneration,
        _onReady = onReady,
        _onNeedsInput = onNeedsInput,
        _onFailed = onFailed;

  final Future<bool> Function(AppPushEvent event) _validateEvent;
  final Object Function() _authGeneration;
  final void Function(String caseId, String jobId, String reportId) _onReady;
  final void Function(String caseId, String jobId) _onNeedsInput;
  final void Function(String caseId, String jobId) _onFailed;
  final Set<String> _handled = <String>{};

  Future<bool> handle(AppPushEvent event) async {
    if (event.type == AppPushType.accident) return false;
    final key =
        '${event.type.name}:${event.caseId}:${event.jobId}:${event.reportId}';
    if (_handled.contains(key)) return false;
    final generation = _authGeneration();
    try {
      if (!await _validateEvent(event)) return false;
    } catch (_) {
      return false;
    }
    if (_authGeneration() != generation) return false;
    if (!_handled.add(key)) return false;
    switch (event.type) {
      case AppPushType.analysisReady:
        _onReady(event.caseId, event.jobId!, event.reportId!);
      case AppPushType.analysisNeedsInput:
        _onNeedsInput(event.caseId, event.jobId!);
      case AppPushType.analysisFailed:
        _onFailed(event.caseId, event.jobId!);
      case AppPushType.accident:
        return false;
    }
    return true;
  }
}

class AnalysisPushEventVerifier {
  AnalysisPushEventVerifier({
    Dio? dio,
    required Future<String?> Function() accessToken,
  })  : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: kApiBaseUrl,
              validateStatus: (status) => status != null && status < 500,
            )),
        _accessToken = accessToken;

  final Dio _dio;
  final Future<String?> Function() _accessToken;

  Future<bool> validate(AppPushEvent event) async {
    if (event.type == AppPushType.accident || event.jobId == null) return false;
    final token = await _accessToken();
    if (token == null || token.isEmpty) return false;
    final options = Options(headers: {'Authorization': 'Bearer $token'});
    final jobResponse = await _dio.get(
      '/api/v1/cases/${event.caseId}/jobs/${event.jobId}',
      options: options,
    );
    if (jobResponse.statusCode != 200) return false;
    final data = _data(jobResponse);
    final job = _mapOrNull(data['job']);
    if (job == null ||
        job['id'] != event.jobId ||
        job['case_id'] != event.caseId ||
        job['kind'] != 'analysis') {
      return false;
    }
    final report = _mapOrNull(data['report']);
    if (event.type == AppPushType.analysisReady ||
        event.type == AppPushType.analysisNeedsInput ||
        report != null) {
      if (report == null ||
          event.reportId == null ||
          report['id'] != event.reportId ||
          report['case_id'] != event.caseId ||
          job['status'] != 'done' ||
          !_matchesReportType(event.type, report)) {
        return false;
      }
      return _isLatestReport(event.caseId, event.reportId!, options);
    }
    if (event.type != AppPushType.analysisFailed ||
        (job['status'] != 'failed' && job['status'] != 'dead')) {
      return false;
    }
    return !await _hasNewerReport(
      event.caseId,
      _date(job['finished_at']) ??
          _date(job['started_at']) ??
          _date(job['available_at']),
      options,
    );
  }

  Future<bool> _isLatestReport(
    String caseId,
    String reportId,
    Options options,
  ) async {
    final latest = await _latestReport(caseId, options);
    return latest?['id'] == reportId;
  }

  Future<bool> _hasNewerReport(
    String caseId,
    DateTime? jobTime,
    Options options,
  ) async {
    final latest = await _latestReport(caseId, options);
    if (latest == null) return false;
    final reportTime = _date(latest['created_at']);
    return jobTime == null ||
        (reportTime != null && reportTime.isAfter(jobTime));
  }

  Future<Map<String, dynamic>?> _latestReport(
    String caseId,
    Options options,
  ) async {
    final response = await _dio.get(
      '/api/v1/cases/$caseId/reports',
      queryParameters: {'limit': 1},
      options: options,
    );
    if (response.statusCode != 200) return null;
    final reports = _data(response)['reports'];
    if (reports is! List || reports.isEmpty) return null;
    return _mapOrNull(reports.first);
  }

  static bool _matchesReportType(
    AppPushType type,
    Map<String, dynamic> report,
  ) {
    final analysis = _mapOrNull(report['analysis']);
    final status = analysis?['status'];
    final model = _mapOrNull(analysis?['model']);
    final needsInput = model?['needs_user_input'];
    final needsRoad = needsInput is List && needsInput.contains('road');
    return switch (type) {
      AppPushType.analysisReady => status == 'complete',
      AppPushType.analysisNeedsInput => status == 'incomplete' && needsRoad,
      AppPushType.analysisFailed =>
        status == 'unavailable' || (status == 'incomplete' && !needsRoad),
      AppPushType.accident => false,
    };
  }

  static Map<String, dynamic> _data(Response<dynamic> response) {
    final body = response.data;
    if (body is! Map || body['data'] is! Map) return const {};
    return Map<String, dynamic>.from(body['data'] as Map);
  }

  static Map<String, dynamic>? _mapOrNull(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

class PushRegistrationException implements Exception {
  const PushRegistrationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PushRegistrationClient {
  PushRegistrationClient({required Dio dio}) : _dio = dio;

  final Dio _dio;
  String? _registrationId;
  String? _accessToken;

  Future<void> register({
    required String token,
    required String accessToken,
    required bool isIOS,
  }) async {
    final response = await _dio.put(
      '/api/v1/push/tokens',
      data: PushService.registrationPayload(token, isIOS: isIOS),
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    if (response.statusCode != 200) {
      final code = response.data is Map
          ? (response.data as Map)['error'] is Map
              ? ((response.data as Map)['error'] as Map)['code']
              : null
          : null;
      throw PushRegistrationException(
        code == 'push_token_conflict'
            ? '이 푸시 토큰은 다른 계정에 등록되어 있습니다.'
            : '푸시 토큰을 등록하지 못했습니다.',
      );
    }
    final data = AnalysisPushEventVerifier._data(response);
    final registration = AnalysisPushEventVerifier._mapOrNull(
      data['registration'],
    );
    final registrationId = registration?['id'];
    if (registrationId is! String || registrationId.isEmpty) {
      throw const PushRegistrationException('푸시 등록 응답이 올바르지 않습니다.');
    }
    _registrationId = registrationId;
    _accessToken = accessToken;
  }

  Future<void> unregister() async {
    final registrationId = _registrationId;
    final accessToken = _accessToken;
    if (registrationId == null || accessToken == null) return;
    final response = await _dio.delete(
      '/api/v1/push/tokens/$registrationId',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    if (response.statusCode != 200 && response.statusCode != 404) {
      throw const PushRegistrationException('푸시 토큰 연결을 해제하지 못했습니다.');
    }
    _registrationId = null;
    _accessToken = null;
  }
}

// 백그라운드(앱 종료/백그라운드 상태) 메시지 핸들러.
// 반드시 최상위 함수여야 한다. (firebase_messaging 요구사항)
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  // 백그라운드에서는 UI 트리거가 어려우므로, 시스템 알림 표시는
  // 서버가 notification 페이로드로 함께 보내면 OS가 자동 표시한다.
  // 여기서는 별도 처리 없이 둔다. (앱을 열면 onMessageOpenedApp 로 이어짐)
}

class PushService {
  PushService(this._ref) {
    _dio = Dio(BaseOptions(
      baseUrl: kApiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Content-Type': 'application/json'},
      validateStatus: (code) => code != null && code < 500,
    ));
    _registrations = PushRegistrationClient(dio: _dio);
  }

  final Ref _ref;
  late final Dio _dio;
  late final PushRegistrationClient _registrations;
  // 웹에서는 Firebase 를 초기화하지 않으므로, 객체 생성 시점이 아니라
  // 실제 사용 시점(네이티브에서만 호출됨)에 접근하도록 지연 초기화한다.
  FirebaseMessaging get _fcm => FirebaseMessaging.instance;

  bool _initialized = false;
  bool _initialMessageReadDone = false;
  Future<void>? _initialMessageRead;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  String? lastRegistrationError;

  // 수신은 로컬 경고 상태를 준비하고, 사용자가 연 알림만 화면을 전환한다.
  void Function(AccidentPush push)? onAccidentPush;
  void Function(AccidentPush push)? onAccidentOpened;
  void Function(AppPushEvent event)? onAnalysisPush;

  static Map<String, String> registrationPayload(
    String token, {
    required bool isIOS,
  }) =>
      {
        'provider': 'fcm',
        'token': token,
        'device_label': isIOS ? 'iOS device' : 'Android device',
      };

  // Subscribe before session restoration; opening an alert must not wait on token registration.
  Future<void> listen() async {
    // 웹은 FCM(네이티브 푸시) 미사용 — 결과 조회·표시 전용이므로 no-op.
    if (kIsWeb) return;
    if (!_initialized) {
      _initialized = true;
      _subscriptions.add(_fcm.onTokenRefresh.listen(_sendTokenToBackend));
      _subscriptions.add(FirebaseMessaging.onMessage.listen(
        (message) => _handleMessage(message, opened: false),
      ));
      _subscriptions.add(FirebaseMessaging.onMessageOpenedApp.listen(
        (message) => _handleMessage(message, opened: true),
      ));
    }
    if (!_initialMessageReadDone) {
      await (_initialMessageRead ??= _readInitialMessage());
    }
  }

  Future<void> _readInitialMessage() async {
    try {
      final initial = await _fcm.getInitialMessage();
      _initialMessageReadDone = true;
      if (initial != null) _handleMessage(initial, opened: true);
    } on Object catch (error) {
      lastRegistrationError = error.toString();
    } finally {
      _initialMessageRead = null;
    }
  }

  Future<void> initialize() async {
    if (kIsWeb) return; // 웹: FCM 미사용
    await listen();
    if (!_initialMessageReadDone) await listen();
    try {
      await _fcm.requestPermission(alert: true, badge: true, sound: true);
      await registerToken();
    } on Object catch (error) {
      lastRegistrationError = error.toString();
    }
  }

  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    onAccidentPush = null;
    onAccidentOpened = null;
    onAnalysisPush = null;
  }

  // ── 현재 기기의 FCM 토큰을 얻어 백엔드에 등록 ────────────
  Future<void> registerToken() async {
    if (kIsWeb) return; // 웹: FCM 미사용
    try {
      final token = await _fcm.getToken();
      if (token != null) {
        await _sendTokenToBackend(token);
      }
    } on Object catch (error) {
      lastRegistrationError = error.toString();
    }
  }

  Future<void> _sendTokenToBackend(String token) async {
    final access = await _ref.read(authProvider.notifier).validAccessToken();
    if (access == null) return; // 로그인 안 돼 있으면 등록 보류

    await _registrations.register(
      token: token,
      accessToken: access,
      isIOS: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS,
    );
    if (_initialMessageReadDone) lastRegistrationError = null;
  }

  Future<void> endSession() async {
    try {
      await _registrations.unregister();
    } finally {
      if (!kIsWeb) await _fcm.deleteToken(); // 웹: FCM 미사용
    }
  }

  // ── 수신 메시지 처리 ─────────────────────────────────────
  void _handleMessage(RemoteMessage message, {required bool opened}) {
    PushEventDispatcher(
      onAccidentReceived: (push) => onAccidentPush?.call(push),
      onAccidentOpened: (push) => onAccidentOpened?.call(push),
      onAnalysis: (event) => onAnalysisPush?.call(event),
    ).dispatch(message.data, opened: opened);
  }
}

// ── Provider ──────────────────────────────────────────────
final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(ref);
  ref.onDispose(service.dispose);
  return service;
});
