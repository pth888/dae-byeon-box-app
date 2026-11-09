import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_service.dart';
import 'consent_service.dart';
import 'device_service.dart';

typedef AccessTokenProvider = Future<String?> Function();
typedef SavedDeviceProvider = Future<({String? id, String? name})> Function();

final RegExp _backendCaseIdPattern = RegExp(r'^case_[0-9a-f]{32}$');

final activeCaseProvider = StateProvider<String?>((ref) => null);

String? authenticatedPrincipal(AuthState state) {
  if (state.status != AuthStatus.authenticated) return null;
  final email = state.email?.trim().toLowerCase();
  return email == null || email.isEmpty ? null : email;
}

class CaseServiceException implements Exception {
  const CaseServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class CaseAuthenticationException extends CaseServiceException {
  const CaseAuthenticationException() : super('로그인이 필요합니다.');
}

class InvalidBackendCaseException extends CaseServiceException {
  const InvalidBackendCaseException([super.message = '유효한 사고 사건을 확인할 수 없습니다.']);
}

class MissingBackendDeviceException extends CaseServiceException {
  const MissingBackendDeviceException()
      : super('마이페이지에서 본인 블랙박스 기기를 먼저 등록해 주세요.');
}

class SupersededCaseOperationException extends CaseServiceException {
  const SupersededCaseOperationException()
      : super('더 최근의 사고 사건 요청이 처리되어 이전 요청을 취소했습니다.');
}

class CollectionConsentRequiredException extends CaseServiceException {
  const CollectionConsentRequiredException()
      : super('사고 자료 수집 전에 개인정보 및 위치정보 동의가 필요합니다.');
}

class BackendCase {
  const BackendCase({
    required this.id,
    required this.deviceId,
    required this.title,
    required this.status,
    required this.createdAt,
    this.lat,
    this.lon,
    this.demoMode = false,
    this.fixedRoadPlace,
  });

  final String id;
  final String deviceId;
  final String title;
  final String status;
  final DateTime createdAt;
  final double? lat;
  final double? lon;
  final bool demoMode;
  final int? fixedRoadPlace;
  bool get isDemo => demoMode;

  factory BackendCase.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final deviceId = json['device_id'];
    final title = json['title'];
    final status = json['status'];
    final createdAtRaw = json['created_at'];
    final createdAt = createdAtRaw is String
        ? DateTime.tryParse(createdAtRaw)?.toUtc()
        : null;
    final policy = json['road_policy'];
    final fixedPlace =
        policy is Map && policy['locked'] == true ? policy['place'] : null;
    if (policy is Map &&
        policy['locked'] == true &&
        (fixedPlace is! int || fixedPlace < 0 || fixedPlace > 7)) {
      throw const InvalidBackendCaseException('서버의 고정 도로유형 정보가 올바르지 않습니다.');
    }
    if (id is! String ||
        !_backendCaseIdPattern.hasMatch(id) ||
        deviceId is! String ||
        deviceId.isEmpty ||
        title is! String ||
        status is! String ||
        createdAt == null) {
      throw const InvalidBackendCaseException('서버의 사고 사건 응답이 올바르지 않습니다.');
    }
    return BackendCase(
      id: id,
      deviceId: deviceId,
      title: title,
      status: status,
      createdAt: createdAt,
      lat: (json['lat'] as num?)?.toDouble(),
      lon: (json['lon'] as num?)?.toDouble(),
      demoMode: json['demo_mode'] == true,
      fixedRoadPlace: fixedPlace is int ? fixedPlace : null,
    );
  }
}

class BackendHardwareEvent {
  const BackendHardwareEvent({
    required this.eventId,
    required this.deviceId,
    required this.sourceDeviceId,
    required this.deviceName,
    required this.triggeredAt,
    required this.source,
    required this.isTestEvent,
    this.impactG,
    this.caseId,
  });

  final String eventId;
  final String deviceId;
  final String sourceDeviceId;
  final String deviceName;
  final DateTime triggeredAt;
  final String source;
  final bool isTestEvent;
  final double? impactG;
  final String? caseId;

  factory BackendHardwareEvent.fromJson(Map<String, dynamic> json) {
    final eventId = json['event_id'];
    final deviceId = json['device_id'];
    final sourceDeviceId = json['source_device_id'];
    final deviceName = json['device_name'];
    final triggeredAt = json['trigger_utc'];
    final source = json['source'];
    final parsedTime =
        triggeredAt is String ? DateTime.tryParse(triggeredAt)?.toUtc() : null;
    final impactRaw = json['impact_g'];
    final caseId = json['case_id'];
    if (eventId is! String ||
        eventId.isEmpty ||
        deviceId is! String ||
        deviceId.isEmpty ||
        sourceDeviceId is! String ||
        sourceDeviceId.isEmpty ||
        deviceName is! String ||
        parsedTime == null ||
        source is! String ||
        (caseId != null && caseId is! String)) {
      throw const CaseServiceException('충격 이벤트 응답이 올바르지 않습니다.');
    }
    final impactG = impactRaw is num &&
            impactRaw.isFinite &&
            impactRaw >= 0 &&
            impactRaw <= 100
        ? impactRaw.toDouble()
        : null;
    return BackendHardwareEvent(
      eventId: eventId,
      deviceId: deviceId,
      sourceDeviceId: sourceDeviceId,
      deviceName: deviceName,
      triggeredAt: parsedTime,
      source: source,
      isTestEvent: json['test_event'] == true,
      impactG: impactG,
      caseId: caseId as String?,
    );
  }
}

class BackendReport {
  const BackendReport({
    required this.id,
    required this.caseId,
    required this.version,
    required this.text,
    required this.createdAt,
    required this.analysis,
  });

  final String id;
  final String caseId;
  final int version;
  final String text;
  final DateTime createdAt;
  final Map<String, dynamic> analysis;

  factory BackendReport.fromJson(
    Map<String, dynamic> json, {
    required String expectedCaseId,
  }) {
    final id = json['id'];
    final caseId = json['case_id'];
    final version = json['version'];
    final text = json['text'];
    final createdAtRaw = json['created_at'];
    final createdAt = createdAtRaw is String
        ? DateTime.tryParse(createdAtRaw)?.toUtc()
        : null;
    final analysisRaw = json['analysis'];
    if (id is! String ||
        id.isEmpty ||
        caseId != expectedCaseId ||
        version is! int ||
        text is! String ||
        createdAt == null ||
        analysisRaw is! Map) {
      throw const CaseServiceException('서버의 분석 리포트 응답이 올바르지 않습니다.');
    }
    return BackendReport(
      id: id,
      caseId: caseId as String,
      version: version,
      text: text,
      createdAt: createdAt,
      analysis: Map<String, dynamic>.from(analysisRaw),
    );
  }
}

class CasePage {
  const CasePage({required this.items, required this.nextCursor});

  final List<BackendCase> items;
  final String? nextCursor;
}

class ReportPage {
  const ReportPage({required this.items, required this.nextCursor});

  final List<BackendReport> items;
  final String? nextCursor;
}

class CaseService {
  CaseService({
    required Dio dio,
    required AccessTokenProvider accessToken,
    required SavedDeviceProvider savedDevice,
    required String? Function() activeCase,
    required void Function(String?) onActiveCaseChanged,
    bool Function()? canCollect,
  })  : _dio = dio,
        _accessToken = accessToken,
        _savedDevice = savedDevice,
        _activeCase = activeCase,
        _onActiveCaseChanged = onActiveCaseChanged,
        _canCollect = canCollect ?? (() => true);

  final Dio _dio;
  final AccessTokenProvider _accessToken;
  final SavedDeviceProvider _savedDevice;
  final String? Function() _activeCase;
  final void Function(String?) _onActiveCaseChanged;
  final bool Function() _canCollect;
  int _activationRequest = 0;

  void invalidatePendingActivation() {
    ++_activationRequest;
  }

  static bool isBackendCaseId(String? value) =>
      value != null && _backendCaseIdPattern.hasMatch(value);

  Future<BackendCase?> selectLatestHardwareCase() async {
    final request = ++_activationRequest;
    final response = await _authorizedRequest(
      (token) {
        _requireActivation(request);
        return _dio.get(
          '/api/v1/cases/latest-hardware',
          options: Options(headers: _bearer(token)),
        );
      },
    );
    _requireActivation(request);
    if (response.statusCode != 200) {
      throw CaseServiceException(
        _apiMessage(response, '최신 블랙박스 영상을 확인할 수 없습니다.'),
      );
    }
    final rawCase = _envelope(response)['case'];
    if (rawCase == null) return null;
    final parsed = BackendCase.fromJson(_map(rawCase));
    _onActiveCaseChanged(parsed.id);
    return parsed;
  }

  /// Reads the latest hardware case without changing the active case.
  Future<BackendCase?> peekLatestHardwareCase() async {
    final response = await _authorizedRequest(
      (token) => _dio.get(
        '/api/v1/cases/latest-hardware',
        options: Options(headers: _bearer(token)),
      ),
    );
    if (response.statusCode != 200) {
      throw CaseServiceException(
        _apiMessage(response, '최신 블랙박스 영상을 확인할 수 없습니다.'),
      );
    }
    final rawCase = _envelope(response)['case'];
    return rawCase == null ? null : BackendCase.fromJson(_map(rawCase));
  }

  Future<List<BackendHardwareEvent>> peekRecentHardwareEvents() async {
    final response = await _authorizedRequest(
      (token) => _dio.get(
        '/api/v1/hardware-events',
        queryParameters: const {'limit': 20},
        options: Options(headers: _bearer(token)),
      ),
    );
    if (response.statusCode != 200) {
      throw CaseServiceException(
        _apiMessage(response, '블랙박스 충격 이벤트를 확인할 수 없습니다.'),
      );
    }
    final rawEvents = _envelope(response)['events'];
    if (rawEvents is! List) {
      throw const CaseServiceException('충격 이벤트 목록 응답이 올바르지 않습니다.');
    }
    return rawEvents
        .map((item) => BackendHardwareEvent.fromJson(_map(item)))
        .toList(growable: false);
  }

  Future<BackendCase> selectOwnedCase(String caseId) async {
    if (!isBackendCaseId(caseId)) {
      throw const InvalidBackendCaseException();
    }
    final request = ++_activationRequest;
    final response = await _authorizedRequest(
      (token) {
        _requireActivation(request);
        return _dio.get(
          '/api/v1/cases/$caseId',
          options: Options(headers: _bearer(token)),
        );
      },
    );
    _requireActivation(request);
    if (response.statusCode != 200) {
      throw CaseServiceException(_apiMessage(response, '사고 사건을 확인할 수 없습니다.'));
    }
    final parsed = BackendCase.fromJson(_dataMap(response, 'case'));
    if (parsed.id != caseId) {
      throw const InvalidBackendCaseException('요청한 사고 사건과 서버 응답이 일치하지 않습니다.');
    }
    _onActiveCaseChanged(parsed.id);
    return parsed;
  }

  Future<BackendCase?> findHardwareEventCase(String eventId, String deviceId,
      {DateTime? triggeredAt}) async {
    final response = await _authorizedRequest((token) => _dio.get(
          '/api/v1/cases/by-event',
          queryParameters: {
            'device_id': deviceId,
            'event_id': eventId,
            if (triggeredAt != null)
              'trigger_utc': triggeredAt.toUtc().toIso8601String()
          },
          options: Options(
              headers: _bearer(token),
              validateStatus: (status) => status != null && status < 500),
        ));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw CaseServiceException(
          _apiMessage(response, '해당 충격의 사고 사건을 확인할 수 없습니다.'));
    }
    final result = BackendCase.fromJson(_dataMap(response, 'case'));
    if (result.deviceId != deviceId) {
      throw const InvalidBackendCaseException('충격 기기와 사고 사건의 기기가 일치하지 않습니다.');
    }
    return result;
  }

  Future<BackendCase> resolveForAccident({
    String? caseId,
    double? lat,
    double? lon,
    DateTime? occurredAt,
  }) async {
    if (caseId != null) return selectOwnedCase(caseId);
    return createSensorCase(lat: lat, lon: lon, occurredAt: occurredAt);
  }

  Future<BackendCase> resolveActiveOrCreate({
    double? lat,
    double? lon,
    DateTime? occurredAt,
  }) async {
    return createSensorCase(lat: lat, lon: lon, occurredAt: occurredAt);
  }

  Future<BackendCase> createSensorCase({
    double? lat,
    double? lon,
    DateTime? occurredAt,
  }) async {
    if (!_canCollect()) throw const CollectionConsentRequiredException();
    if ((lat == null) != (lon == null)) {
      throw const CaseServiceException('사고 위치의 위도와 경도가 모두 필요합니다.');
    }
    final request = ++_activationRequest;
    final device = await _savedDevice();
    _requireActivation(request);
    final deviceId = device.id;
    if (deviceId == null || deviceId.isEmpty) {
      throw const MissingBackendDeviceException();
    }
    final instant = (occurredAt ?? DateTime.now()).toUtc();
    final response = await _authorizedRequest(
      (token) {
        _requireActivation(request);
        return _dio.post(
          '/api/v1/cases',
          data: {
            'device_id': deviceId,
            'title': 'Phone sensor event ${_utcTitle(instant)}',
            if (lat != null) 'lat': lat,
            if (lon != null) 'lon': lon,
          },
          options: Options(headers: _bearer(token)),
        );
      },
    );
    _requireActivation(request);
    if (response.statusCode != 201) {
      throw CaseServiceException(_apiMessage(response, '사고 사건을 만들 수 없습니다.'));
    }
    final parsed = BackendCase.fromJson(_dataMap(response, 'case'));
    if (parsed.deviceId != deviceId) {
      throw const InvalidBackendCaseException('등록된 기기와 생성된 사고 사건이 일치하지 않습니다.');
    }
    _onActiveCaseChanged(parsed.id);
    return parsed;
  }

  Future<CasePage> listCases(
      {int limit = 20, String? cursor, bool hasReports = false}) async {
    final response = await _authorizedRequest(
      (token) => _dio.get(
        '/api/v1/cases',
        queryParameters: {
          'limit': limit,
          if (cursor != null) 'cursor': cursor,
          if (hasReports) 'has_reports': true
        },
        options: Options(headers: _bearer(token)),
      ),
    );
    if (response.statusCode != 200) {
      throw CaseServiceException(_apiMessage(response, '사고 이력을 불러올 수 없습니다.'));
    }
    final data = _envelope(response);
    final rawItems = data['cases'];
    if (rawItems is! List) {
      throw const CaseServiceException('서버의 사고 이력 응답이 올바르지 않습니다.');
    }
    return CasePage(
      items: rawItems
          .map((item) => BackendCase.fromJson(_map(item)))
          .toList(growable: false),
      nextCursor: _optionalCursor(data['next_cursor']),
    );
  }

  Future<ReportPage> listReports(
    String caseId, {
    int limit = 20,
    String? cursor,
  }) async {
    if (!isBackendCaseId(caseId)) throw const InvalidBackendCaseException();
    final response = await _authorizedRequest(
      (token) => _dio.get(
        '/api/v1/cases/$caseId/reports',
        queryParameters: {'limit': limit, if (cursor != null) 'cursor': cursor},
        options: Options(headers: _bearer(token)),
      ),
    );
    if (response.statusCode != 200) {
      throw CaseServiceException(_apiMessage(response, '분석 리포트를 불러올 수 없습니다.'));
    }
    final data = _envelope(response);
    final rawItems = data['reports'];
    if (rawItems is! List) {
      throw const CaseServiceException('서버의 분석 리포트 응답이 올바르지 않습니다.');
    }
    return ReportPage(
      items: rawItems
          .map((item) => BackendReport.fromJson(
                _map(item),
                expectedCaseId: caseId,
              ))
          .toList(growable: false),
      nextCursor: _optionalCursor(data['next_cursor']),
    );
  }

  Future<void> deleteReports(String caseId) async {
    if (!isBackendCaseId(caseId)) throw const InvalidBackendCaseException();
    final response = await _authorizedRequest((token) => _dio.delete(
          '/api/v1/cases/$caseId/reports',
          options: Options(headers: _bearer(token)),
        ));
    final data = response.statusCode == 200 ? _envelope(response) : null;
    if (response.statusCode != 200 ||
        data?['case_id'] != caseId ||
        data?['status'] != 'reports_deleted' ||
        data?['media_preserved'] != true) {
      throw CaseServiceException(response.statusCode == 409
          ? '분석 진행 중에는 기록을 삭제할 수 없습니다. 완료 후 다시 시도해 주세요.'
          : _apiMessage(response, '분석 기록을 삭제하지 못했습니다.'));
    }
  }

  Future<void> deleteCase(String caseId) async {
    if (!isBackendCaseId(caseId)) throw const InvalidBackendCaseException();
    final response = await _authorizedRequest(
      (token) => _dio.delete(
        '/api/v1/cases/$caseId',
        options: Options(headers: _bearer(token)),
      ),
    );
    final data = response.statusCode == 202 ? _envelope(response) : null;
    if (response.statusCode != 202 ||
        data?['case_id'] != caseId ||
        data?['status'] != 'delete_requested') {
      throw CaseServiceException(
          _apiMessage(response, '사고 삭제 요청을 접수하지 못했습니다.'));
    }
    if (_activeCase() == caseId) {
      ++_activationRequest;
      _onActiveCaseChanged(null);
    }
  }

  Future<Response<dynamic>> _authorizedRequest(
    Future<Response<dynamic>> Function(String token) request,
  ) async {
    final token = await _accessToken();
    if (token == null || token.isEmpty) {
      throw const CaseAuthenticationException();
    }
    return request(token);
  }

  void _requireActivation(int request) {
    if (request != _activationRequest) {
      throw const SupersededCaseOperationException();
    }
  }
}

final caseApiDioProvider = Provider<Dio>((ref) => Dio(
      BaseOptions(
        baseUrl: kApiBaseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {'Content-Type': 'application/json'},
        validateStatus: (status) => status != null && status < 500,
      ),
    ));

final caseServiceProvider = Provider<CaseService>((ref) {
  late final CaseService service;
  ref.listen<String?>(authProvider.select(authenticatedPrincipal),
      (previous, next) {
    if (previous != next) {
      service.invalidatePendingActivation();
      ref.read(activeCaseProvider.notifier).state = null;
    }
  });
  service = CaseService(
    dio: ref.read(caseApiDioProvider),
    accessToken: () => ref.read(authProvider.notifier).validAccessToken(),
    savedDevice: () => ref.read(deviceServiceProvider).savedDevice(),
    activeCase: () => ref.read(activeCaseProvider),
    onActiveCaseChanged: (caseId) {
      ref.read(activeCaseProvider.notifier).state = caseId;
    },
    canCollect: () => ref.read(consentControllerProvider).canCollect,
  );
  ref.onDispose(service.invalidatePendingActivation);
  return service;
});

Map<String, String> _bearer(String token) => {'Authorization': 'Bearer $token'};

Map<String, dynamic> _envelope(Response<dynamic> response) {
  final body = response.data;
  if (body is! Map || body['data'] is! Map) {
    throw const CaseServiceException('서버 응답이 올바르지 않습니다.');
  }
  return Map<String, dynamic>.from(body['data'] as Map);
}

Map<String, dynamic> _dataMap(Response<dynamic> response, String key) =>
    _map(_envelope(response)[key]);

Map<String, dynamic> _map(Object? value) {
  if (value is! Map) {
    throw const CaseServiceException('서버 응답 항목이 올바르지 않습니다.');
  }
  return Map<String, dynamic>.from(value);
}

String? _optionalCursor(Object? value) {
  if (value == null) return null;
  if (value is String && value.isNotEmpty) return value;
  throw const CaseServiceException('서버 페이지 정보가 올바르지 않습니다.');
}

String _apiMessage(Response<dynamic> response, String fallback) {
  final body = response.data;
  if (body is Map && body['error'] is Map) {
    final message = (body['error'] as Map)['message'];
    if (message is String && message.isNotEmpty) return message;
  }
  return fallback;
}

String _utcTitle(DateTime instant) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${instant.year.toString().padLeft(4, '0')}-'
      '${two(instant.month)}-${two(instant.day)} '
      '${two(instant.hour)}:${two(instant.minute)}:${two(instant.second)} UTC';
}
