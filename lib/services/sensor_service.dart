// lib/services/sensor_service.dart
//
// 담당 기능: 3.1 스마트폰 내부 센서 연동 사고 자동 감지 (E-Call 가상화)
//   - sensors_plus 패키지로 가속도·자이로 센서 구독
//   - 임계값 초과 시 사고 감지 → 자동 창 팝업 + GPS 긴급 SMS 발송
//
// 사용 패키지:
//   sensors_plus: ^4.0.2        (pubspec.yaml dependencies)
//   geolocator: ^11.0.0
//   flutter_local_notifications: ^17.1.2
//   url_launcher: ^6.2.5        (SMS 발송)
//   flutter_riverpod: ^2.4.9    (상태 관리)

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth_service.dart';
import 'case_service.dart';
import 'consent_service.dart';
import 'notification_service.dart';

/// 충격 감지 임계값 (G-Force)
/// 중력(1G)을 뺀 순수 충격 기준. 가만히 있으면 0G, 일반 급제동 ≈ 0.8G.
/// 백엔드·블랙박스와 맞춰 1.5G 이상을 충격으로 본다.
const double kImpactThresholdG = 1.5;

const double _kGravity = 9.81;

/// 이 값보다 작은 흔들림(센서 잡음)은 0G 로 표시한다.
const double _kNoiseFloorG = 0.05;

/// 중력 방향을 따라가는 속도 (클수록 천천히 따라감)
const Duration _kGravityTimeConstant = Duration(seconds: 1);

/// 홈 화면 숫자 갱신 간격 (이 사이의 최대 충격을 보여준다)
const Duration _kDisplayInterval = Duration(milliseconds: 100);

/// 충격 감지 상태 (Riverpod StateNotifier)
class SensorState {
  final bool isMonitoring;
  final bool isImpactDetected;
  final double currentGForce;
  final DateTime? detectedAt;
  final String? caseId;
  final String? errorMessage;

  const SensorState({
    this.isMonitoring = false,
    this.isImpactDetected = false,
    this.currentGForce = 0.0,
    this.detectedAt,
    this.caseId,
    this.errorMessage,
  });

  SensorState copyWith({
    bool? isMonitoring,
    bool? isImpactDetected,
    double? currentGForce,
    DateTime? detectedAt,
    String? caseId,
    String? errorMessage,
  }) =>
      SensorState(
        isMonitoring: isMonitoring ?? this.isMonitoring,
        isImpactDetected: isImpactDetected ?? this.isImpactDetected,
        currentGForce: currentGForce ?? this.currentGForce,
        detectedAt: detectedAt ?? this.detectedAt,
        caseId: caseId ?? this.caseId,
        errorMessage: errorMessage,
      );
}

class SensorNotifier extends StateNotifier<SensorState> {
  SensorNotifier(
    this._ref, {
    Stream<AccelerometerEvent>? accelerometerEvents,
  })  : _accelerometerEvents = accelerometerEvents,
        super(const SensorState()) {
    _wasAuthorized = _isAuthorized;
    _ref.listen<ConsentState>(consentControllerProvider, (_, __) {
      _onAuthorizationChanged();
    });
    _ref.listen<AuthState>(authProvider, (_, __) {
      _onAuthorizationChanged();
    });
  }

  final Ref _ref;
  final Stream<AccelerometerEvent>? _accelerometerEvents;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  DateTime? _lastImpactTime;
  int _authorizationGeneration = 0;
  late bool _wasAuthorized;
  bool _monitoringRequested = false;

  // 중력 추정값 (x, y, z). 폰이 어느 방향으로 놓여 있든 이 값을 빼서 순수 충격만 본다.
  List<double>? _gravity;
  DateTime? _lastSampleAt;
  DateTime? _lastDisplayAt;
  double _displayPeak = 0;

  // 블랙박스(외부) 신호로 트리거된 마지막 시각.
  // 블박이 주 감지자이므로, 블박 신호 직후에는 폰 센서 중복 감지를 막는다.
  DateTime? _lastExternalTrigger;

  // ── 모니터링 시작 ────────────────────────────────────────
  void startMonitoring() {
    // 웹: 가속도 센서(sensors_plus) 미지원 — 충격 감지는 하드웨어/네이티브 전용
    if (kIsWeb) return;
    _monitoringRequested = true;
    if (state.isMonitoring) return;
    if (!_isAuthorized) {
      state = state.copyWith(
        errorMessage: '센서 시작 전에 개인정보 및 위치정보 동의가 필요합니다.',
      );
      return;
    }
    state = state.copyWith(isMonitoring: true);

    // 가속도 센서 구독 (sensors_plus)
    _accelSub = (_accelerometerEvents ??
            accelerometerEventStream(
              // 충격은 수십 ms 안에 끝나므로 촘촘히 읽는다 (약 20ms)
              samplingPeriod: SensorInterval.gameInterval,
            ))
        .listen(_onAccelerometerEvent);
  }

  // ── 모니터링 중지 ────────────────────────────────────────
  void stopMonitoring() {
    _monitoringRequested = false;
    _stopMonitoring();
  }

  void _stopMonitoring() {
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _accelSub = null;
    _gyroSub = null;
    _resetFilter();
    state = state.copyWith(
      isMonitoring: false,
      isImpactDetected: false,
      currentGForce: 0,
    );
  }

  bool get _isAuthorized =>
      _ref.read(authProvider).status == AuthStatus.authenticated &&
      _ref.read(consentControllerProvider).canCollect;

  bool _isAuthorizedFor(int generation) =>
      generation == _authorizationGeneration && _isAuthorized;

  void _onAuthorizationChanged() {
    final authorized = _isAuthorized;
    if (authorized == _wasAuthorized) return;
    _wasAuthorized = authorized;
    if (!authorized) {
      _invalidateAuthorization();
    } else if (_monitoringRequested) {
      startMonitoring();
    }
  }

  void _invalidateAuthorization() {
    _authorizationGeneration++;
    _stopMonitoring();
    state = const SensorState();
  }

  // ── 가속도 이벤트 처리 ───────────────────────────────────
  void _onAccelerometerEvent(AccelerometerEvent event) {
    final authorization = _authorizationGeneration;
    if (!_isAuthorizedFor(authorization) || !state.isMonitoring) return;
    final now = DateTime.now();
    final gForce = _impactG(event, now);

    // 홈 화면 숫자: 100ms 마다 그 사이의 최대값으로 갱신 (임계값을 넘으면 바로)
    if (gForce > _displayPeak) _displayPeak = gForce;
    if (_lastDisplayAt == null ||
        now.difference(_lastDisplayAt!) >= _kDisplayInterval ||
        gForce >= kImpactThresholdG) {
      state = state.copyWith(currentGForce: _displayPeak);
      _displayPeak = 0;
      _lastDisplayAt = now;
    }

    // 임계값 초과 & 중복 감지 방지 (5초 쿨다운)
    if (gForce >= kImpactThresholdG) {
      // 블박(주 감지자)이 방금 신호를 보냈으면 폰 센서는 양보(보조 역할).
      // 블박 신호 후 15초 이내의 폰 센서 감지는 같은 사고로 보고 무시한다.
      if (_lastExternalTrigger != null &&
          now.difference(_lastExternalTrigger!) < const Duration(seconds: 15)) {
        return;
      }

      if (_lastImpactTime == null ||
          now.difference(_lastImpactTime!) > const Duration(seconds: 5)) {
        _lastImpactTime = now;
        _onImpactDetected(gForce, now, authorization);
      }
    }
  }

  /// 중력을 뺀 순수 충격 (G). 가만히 있으면 0 근처.
  ///
  /// 가속도 센서 값에는 항상 중력(약 1G)이 들어 있어서 그대로 쓰면 정지 상태에서도 1G 가 나온다.
  /// 저역 통과 필터로 중력 방향을 추정해 빼고, 남은 크기만 충격으로 본다.
  double _impactG(AccelerometerEvent event, DateTime now) {
    final x = event.x, y = event.y, z = event.z;
    final gravity = _gravity;
    double impact;
    if (gravity == null) {
      // 첫 값: 중력 방향을 모르므로 크기에서 1G 를 뺀다
      final magnitude = sqrt(x * x + y * y + z * z);
      impact = (magnitude - _kGravity).abs() / _kGravity;
      _gravity = magnitude > 0
          ? [
              x * _kGravity / magnitude,
              y * _kGravity / magnitude,
              z * _kGravity / magnitude,
            ]
          : [0, 0, _kGravity];
    } else {
      final lx = x - gravity[0], ly = y - gravity[1], lz = z - gravity[2];
      impact = sqrt(lx * lx + ly * ly + lz * lz) / _kGravity;

      // 중력 추정값을 천천히 따라가게 갱신 (폰 방향이 바뀌어도 1초쯤이면 맞춰짐)
      final last = _lastSampleAt;
      var dt = last == null
          ? 0.02
          : now.difference(last).inMicroseconds / 1000000.0;
      if (dt <= 0) dt = 0.001;
      if (dt > 0.5) dt = 0.5;
      final tau = _kGravityTimeConstant.inMicroseconds / 1000000.0;
      final alpha = tau / (tau + dt);
      gravity[0] = alpha * gravity[0] + (1 - alpha) * x;
      gravity[1] = alpha * gravity[1] + (1 - alpha) * y;
      gravity[2] = alpha * gravity[2] + (1 - alpha) * z;
    }
    _lastSampleAt = now;
    return impact < _kNoiseFloorG ? 0 : impact;
  }

  void _resetFilter() {
    _gravity = null;
    _lastSampleAt = null;
    _lastDisplayAt = null;
    _displayPeak = 0;
  }

  // ── 외부(블랙박스/푸시) 신호로 사고 트리거 ───────────────
  // 블박이 충격을 감지해 백엔드를 거쳐 FCM 푸시가 오면 PushService 가 이 메서드를 부른다.
  // 블박이 주 감지자이므로, 이 경로가 폰 센서보다 우선한다.
  //   lat/lon: 블박이 보낸 GPS 좌표(있으면 사용)
  //   gForce : 블박이 보낸 충격 수치(없으면 임계값으로 대체)
  Future<void> triggerFromExternal({
    required String? caseId,
    double? lat,
    double? lon,
    double? gForce,
  }) async {
    final authorization = _authorizationGeneration;
    if (!_isAuthorizedFor(authorization)) return;
    final now = DateTime.now();
    _lastExternalTrigger = now;

    if (!CaseService.isBackendCaseId(caseId)) {
      state = state.copyWith(
        errorMessage: '사고 푸시에 유효한 사건 ID가 없습니다.',
      );
      return;
    }

    try {
      await _ref.read(caseServiceProvider).resolveForAccident(caseId: caseId);
    } catch (error) {
      if (!_isAuthorizedFor(authorization)) return;
      state = state.copyWith(errorMessage: error.toString());
      return;
    }
    if (!_isAuthorizedFor(authorization)) return;

    // 폰 센서 쿨다운과 동일하게 중복 방지
    if (_lastImpactTime != null &&
        now.difference(_lastImpactTime!) < const Duration(seconds: 5)) {
      return;
    }
    _lastImpactTime = now;

    final g = gForce ?? kImpactThresholdG;
    state = state.copyWith(
      isImpactDetected: true,
      currentGForce: g,
      detectedAt: now,
      caseId: caseId,
      errorMessage: null,
    );

    // 1) 로컬 푸시 알림 표시
    if (!_isAuthorizedFor(authorization)) return;
    await NotificationService.showImpactAlert(caseId: caseId!, gForce: g);
  }

  // ── 충격 감지 처리 ───────────────────────────────────────
  Future<void> _onImpactDetected(
    double gForce,
    DateTime detectedAt,
    int authorization,
  ) async {
    if (!_isAuthorizedFor(authorization)) return;
    String caseId;
    try {
      final created = await _ref.read(caseServiceProvider).resolveForAccident(
            occurredAt: detectedAt,
          );
      caseId = created.id;
    } catch (error) {
      if (!_isAuthorizedFor(authorization)) return;
      state = state.copyWith(errorMessage: error.toString());
      return;
    }
    if (!_isAuthorizedFor(authorization)) return;
    state = state.copyWith(
      isImpactDetected: true,
      currentGForce: gForce,
      detectedAt: detectedAt,
      caseId: caseId,
      errorMessage: null,
    );

    // 1) 로컬 푸시 알림 표시 (flutter_local_notifications)
    await NotificationService.showImpactAlert(caseId: caseId, gForce: gForce);
    if (!_isAuthorizedFor(authorization)) return;

    // 2) GPS 좌표 취득 (geolocator)
    //    10초간 무응답 시 자동 SMS 발송
    _scheduleAutoEmergencySms(
      detectedAt,
      authorization: authorization,
    );
  }

  // ── 10초 무응답 시 긴급 SMS 자동 발송 ───────────────────
  // externalLat/externalLon: 블박이 보낸 좌표가 있으면 폰 GPS 대신 이것을 사용
  void _scheduleAutoEmergencySms(
    DateTime detectedAt, {
    required int authorization,
    double? externalLat,
    double? externalLon,
  }) {
    Future.delayed(const Duration(seconds: 10), () async {
      // 아직 감지 상태라면 (사용자가 해제 안 했다면) 자동 발송
      if (!_isAuthorizedFor(authorization) || !state.isImpactDetected) return;

      // 블박 좌표가 있으면 그대로 사용 (폰 GPS 조회 생략)
      if (externalLat != null && externalLon != null) {
        await _sendEmergencySmsRaw(externalLat, externalLon, authorization);
        return;
      }

      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        if (!_isAuthorizedFor(authorization)) return;
        await _sendEmergencySms(position, authorization);
      } catch (_) {
        // 위치 취득 실패 시 최후 알려진 위치 사용
      }
    });
  }

  // ── 긴급 SMS 발송 (url_launcher) ────────────────────────
  // Android: sms: URI, iOS: sms: URI
  // telephony 패키지로 백그라운드 자동 발송 가능 (Android only)
  Future<void> _sendEmergencySms(Position position, int authorization) async {
    await _sendEmergencySmsRaw(
      position.latitude,
      position.longitude,
      authorization,
    );
  }

  // 좌표(위도/경도)로 직접 긴급 SMS 발송
  Future<void> _sendEmergencySmsRaw(
      double lat, double lon, int authorization) async {
    if (!_isAuthorizedFor(authorization)) return;
    final message = Uri.encodeComponent(
      '[Dae-Byeon-BOX 긴급 알림] '
      '충격이 감지되었습니다. '
      '위치: https://maps.google.com/?q=$lat,$lon '
      '발생 시각: ${DateTime.now()}',
    );

    // 119 신고 SMS
    final smsUri = Uri.parse('sms:119?body=$message');
    if (await canLaunchUrl(smsUri)) {
      if (!_isAuthorizedFor(authorization)) return;
      await launchUrl(smsUri);
    }
  }

  // ── 감지 상태 초기화 (사용자가 "괜찮아요" 누른 경우) ────
  void dismissAlert() {
    state = SensorState(
      isMonitoring: state.isMonitoring,
      currentGForce: state.currentGForce,
    );
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _gyroSub?.cancel();
    super.dispose();
  }
}

/// Riverpod Provider 노출
final sensorProvider =
    StateNotifierProvider<SensorNotifier, SensorState>((ref) {
  final notifier = SensorNotifier(ref);
  // 앱 시작 시 자동으로 모니터링 시작
  notifier.startMonitoring();
  return notifier;
});
