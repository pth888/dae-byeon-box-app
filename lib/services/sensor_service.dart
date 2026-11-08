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
/// 일반 급제동 ≈ 0.8G, 사고 수준 ≈ 2.5G 이상
const double kImpactThresholdG = 1.5;

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
              samplingPeriod: SensorInterval.normalInterval,
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
    state = state.copyWith(isMonitoring: false, isImpactDetected: false);
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
    // 합력 G-Force 계산: sqrt(x² + y² + z²) / 9.81
    final gForce = sqrt(
          event.x * event.x + event.y * event.y + event.z * event.z,
        ) /
        9.81;

    state = state.copyWith(currentGForce: gForce);

    // 임계값 초과 & 중복 감지 방지 (5초 쿨다운)
    if (gForce >= kImpactThresholdG) {
      final now = DateTime.now();

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
