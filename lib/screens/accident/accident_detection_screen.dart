// lib/screens/accident/accident_detection_screen.dart
// 테슬라 미니멀 스타일 - 큰 카운트다운
//
// 충격 감지 → 15초 카운트다운
//   - "지금 시작": 운전자가 응답함 → 초동 대처로 이동 (긴급 알림 없음)
//   - "오작동입니다": 닫기
//   - 응답 없음(0초): 119·보호자 긴급 알림 → 완료 화면
//       119 는 시연만, 보호자 문자는 안드로이드에서 실제 발송
//       (아이폰·아이패드·테스트 충격은 시연 화면만)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/case_service.dart';
import '../../services/emergency_contact_service.dart';
import '../../services/emergency_dispatch_service.dart';
import '../../services/hardware_event_service.dart';
import '../../services/sensor_service.dart';
import '../../utils/theme.dart';
import '../../widgets/emergency_mini_map.dart';

/// 응답을 기다리는 시간
const int kEmergencyCountdownSeconds = 15;

enum _Phase { countdown, sending, sent }

class AccidentDetectionScreen extends ConsumerStatefulWidget {
  const AccidentDetectionScreen({super.key, this.caseId, this.hardwareEvent});

  final String? caseId;

  /// 블랙박스 충격 알림으로 열린 경우의 이벤트 (휴대폰 센서면 null)
  final HardwareEvent? hardwareEvent;

  /// 이 화면이 이미 떠 있는지 (같은 충격으로 여러 번 열리지 않게)
  static bool get isOpen => _openCount > 0;
  static int _openCount = 0;

  @override
  ConsumerState<AccidentDetectionScreen> createState() =>
      _AccidentDetectionScreenState();
}

class _AccidentDetectionScreenState
    extends ConsumerState<AccidentDetectionScreen> {
  int _countdown = kEmergencyCountdownSeconds;
  bool _resolvingCase = false;
  _Phase _phase = _Phase.countdown;
  Timer? _timer;
  EmergencyDispatchResult? _result;

  @override
  void initState() {
    super.initState();
    AccidentDetectionScreen._openCount++;
    _startCountdown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    AccidentDetectionScreen._openCount--;
    super.dispose();
  }

  void _startCountdown() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _phase != _Phase.countdown) {
        timer.cancel();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 5 && _countdown > 0) {
        HapticFeedback.heavyImpact();
      }
      if (_countdown <= 0) {
        timer.cancel();
        _dispatchEmergency();
      }
    });
  }

  // ── 응답 없음: 119·보호자 긴급 알림 ─────────────────────
  Future<void> _dispatchEmergency() async {
    if (!mounted || _phase != _Phase.countdown) return;
    setState(() => _phase = _Phase.sending);
    final contact =
        await ref.read(emergencyContactProvider.notifier).current();
    final result = await ref.read(emergencyDispatcherProvider).dispatch(
          contact: contact,
          testEvent: widget.hardwareEvent?.testEvent == true,
        );
    if (!mounted) return;
    setState(() {
      _result = result;
      _phase = _Phase.sent;
    });
  }

  Future<void> _onAccident() async {
    if (!mounted || _resolvingCase || _phase == _Phase.sending) return;
    _timer?.cancel();
    final hardware = widget.hardwareEvent;
    if (hardware != null) {
      // 블랙박스 충격: 휴대폰 센서 사건을 새로 만들지 않는다.
      // 영상(case_id)이 아직 없으면 초동 대처를 먼저 진행하고, 연결될 때까지 기다린다.
      ref.read(sensorProvider.notifier).dismissAlert();
      final caseId = hardware.caseId;
      context.goNamed('first-response', extra: <String, dynamic>{
        'case_id': caseId ?? '',
        'hardware_event': hardware,
      });
      return;
    }
    setState(() => _resolvingCase = true);
    try {
      final backendCase = await ref
          .read(caseServiceProvider)
          .resolveForAccident(caseId: widget.caseId);
      if (!mounted) return;
      ref.read(sensorProvider.notifier).dismissAlert();
      context.goNamed('first-response', extra: backendCase.id);
    } catch (error) {
      if (!mounted) return;
      setState(() => _resolvingCase = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  void _onDismiss() {
    _timer?.cancel();
    ref.read(sensorProvider.notifier).dismissAlert();
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgBlack,
      body: SafeArea(
        child: switch (_phase) {
          _Phase.countdown => _buildCountdown(),
          _Phase.sending => _buildSending(),
          _Phase.sent => _buildSent(_result!),
        },
      ),
    );
  }

  // ── 카운트다운 ─────────────────────────────────────────
  Widget _buildCountdown() {
    final contact = ref.watch(emergencyContactProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        children: [
          const SizedBox(height: 40),
          // 상단 경고 라벨
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: AppTheme.errorRed,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                '충격 감지됨',
                style: TextStyle(
                  color: AppTheme.errorRed,
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),

          // 중앙 큰 카운트다운
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$_countdown',
                      style: TextStyle(
                        color: _countdown <= 5
                            ? AppTheme.errorRed
                            : Colors.white,
                        fontSize: 160,
                        fontWeight: FontWeight.w100,
                        height: 1,
                        letterSpacing: -4,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '사고가 감지되었습니다',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '응답이 없으면 $_countdown초 후\n119와 보호자에게 위치를 보냅니다',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppTheme.textSub,
                        fontSize: 14,
                        height: 1.5,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          contact == null
                              ? Icons.person_off_outlined
                              : Icons.person_outline,
                          size: 15,
                          color: AppTheme.textHint,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          contact == null
                              ? '보호자 미등록 · 마이페이지에서 등록할 수 있어요'
                              : '보호자 ${contact.label}',
                          style: const TextStyle(
                            color: AppTheme.textHint,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    if (widget.hardwareEvent != null) ...[
                      const SizedBox(height: 28),
                      _HardwareEventInfo(event: widget.hardwareEvent!),
                    ],
                  ],
                ),
              ),
            ),
          ),

          // 하단 버튼들
          _primaryButton(
            _resolvingCase ? '사고 사건 확인 중' : '지금 시작',
            _resolvingCase ? null : _onAccident,
          ),
          const SizedBox(height: 12),
          _outlineButton('오작동입니다', _onDismiss),
        ],
      ),
    );
  }

  // ── 전송 중 ───────────────────────────────────────────
  Widget _buildSending() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
                strokeWidth: 2.5, color: Colors.white),
          ),
          SizedBox(height: 22),
          Text(
            '응답이 없어 긴급 알림을 보내는 중',
            style: TextStyle(color: Colors.white, fontSize: 17),
          ),
          SizedBox(height: 8),
          Text(
            '현재 위치를 확인하고 있습니다',
            style: TextStyle(color: AppTheme.textSub, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ── 완료 ─────────────────────────────────────────────
  Widget _buildSent(EmergencyDispatchResult r) {
    final demo = r.demoReason != null;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    color: AppTheme.surfaceDark,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.campaign_outlined,
                      color: AppTheme.errorRed, size: 28),
                ),
                const SizedBox(height: 18),
                Text(
                  demo ? '긴급 알림을 보냈습니다 (시연)' : '긴급 알림을 보냈습니다',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '$kEmergencyCountdownSeconds초 동안 응답이 없어 사고 위치를 알렸습니다 · ${_time(r.at)}',
                  style: const TextStyle(
                      color: AppTheme.textSub, fontSize: 13, height: 1.5),
                ),
                if (demo) ...[
                  const SizedBox(height: 16),
                  _notice(r.demoReason!, AppTheme.warningOrange,
                      Icons.info_outline),
                ],
                const SizedBox(height: 26),
                const Text('알림 대상', style: AppTheme.label),
                const SizedBox(height: 10),
                _statusRow(
                  icon: Icons.local_hospital_outlined,
                  title: '119 긴급 신고',
                  subtitle: '실제 서비스에서는 119 문자신고와 연동됩니다',
                  chip: '시연',
                  chipColor: AppTheme.warningOrange,
                ),
                const SizedBox(height: 10),
                _guardianRow(r),
                const SizedBox(height: 26),
                const Text('보낸 내용', style: AppTheme.label),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.cardDark,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF2A2A2E)),
                  ),
                  child: Text(
                    r.message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      height: 1.6,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                ),
                const SizedBox(height: 26),
                const Text('사고 위치', style: AppTheme.label),
                const SizedBox(height: 10),
                ..._location(r.location),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            children: [
              _primaryButton(
                _resolvingCase ? '사고 사건 확인 중' : '초동 대처 시작',
                _resolvingCase ? null : _onAccident,
              ),
              const SizedBox(height: 12),
              _outlineButton('홈으로', _onDismiss),
            ],
          ),
        ),
      ],
    );
  }

  Widget _guardianRow(EmergencyDispatchResult r) {
    final contact = r.contact;
    final title = contact == null ? '보호자' : '보호자 · ${contact.label}';
    switch (r.guardian) {
      case GuardianSmsStatus.sent:
        return _statusRow(
          icon: Icons.sms_outlined,
          title: title,
          subtitle: '긴급 문자를 보냈습니다',
          chip: '전송 완료',
          chipColor: AppTheme.successGreen,
        );
      case GuardianSmsStatus.simulated:
        return _statusRow(
          icon: Icons.sms_outlined,
          title: title,
          subtitle: '긴급 문자 전송 (시연)',
          chip: '시연',
          chipColor: AppTheme.warningOrange,
        );
      case GuardianSmsStatus.noContact:
        return _statusRow(
          icon: Icons.person_off_outlined,
          title: '보호자 미등록',
          subtitle: '마이페이지 > 비상 연락처에서 등록하면 보호자에게도 전송됩니다',
          chip: '미등록',
          chipColor: AppTheme.textSub,
        );
      case GuardianSmsStatus.permissionDenied:
        return _statusRow(
          icon: Icons.sms_failed_outlined,
          title: title,
          subtitle: '문자 권한이 없어 보내지 못했습니다. 마이페이지에서 비상 연락처를 다시 저장하면 권한을 요청합니다',
          chip: '권한 없음',
          chipColor: AppTheme.errorRed,
        );
      case GuardianSmsStatus.failed:
        return _statusRow(
          icon: Icons.sms_failed_outlined,
          title: title,
          subtitle: '문자를 보내지 못했습니다. 유심과 통신 상태를 확인하세요',
          chip: '전송 실패',
          chipColor: AppTheme.errorRed,
        );
    }
  }

  List<Widget> _location(EmergencyLocation? location) {
    if (location == null) {
      return [
        _notice('위치 권한이 없거나 현재 위치를 확인하지 못해 위치 없이 보냈습니다.',
            AppTheme.textSub, Icons.location_off_outlined),
      ];
    }
    return [
      EmergencyMiniMap(
        latitude: location.latitude,
        longitude: location.longitude,
      ),
      const SizedBox(height: 10),
      if (location.address != null)
        Text(
          location.address!,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      const SizedBox(height: 4),
      Text(
        '${location.latitude.toStringAsFixed(6)}, ${location.longitude.toStringAsFixed(6)}'
        '${location.isLastKnown ? ' · 마지막으로 확인된 위치' : ''}',
        style: const TextStyle(color: AppTheme.textHint, fontSize: 12),
      ),
    ];
  }

  Widget _statusRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required String chip,
    required Color chipColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2A2E)),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(color: Colors.white, fontSize: 15)),
                const SizedBox(height: 3),
                Text(subtitle,
                    style: const TextStyle(
                        color: AppTheme.textHint, fontSize: 12, height: 1.4)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: chipColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(chip,
                style: TextStyle(
                    color: chipColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  Widget _notice(String text, Color color, IconData icon) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(color: color.withOpacity(0.6)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(color: color, fontSize: 12.5, height: 1.5)),
          ),
        ],
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: AppTheme.pointWhite,
          borderRadius: BorderRadius.circular(100),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }

  Widget _outlineButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF3A3A3E)),
          borderRadius: BorderRadius.circular(100),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w400,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }

  static String _time(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}


/// 블랙박스 충격 정보 (전방/후방 · 충격 세기 · 시각 · 테스트 여부)
class _HardwareEventInfo extends StatelessWidget {
  const _HardwareEventInfo({required this.event});

  final HardwareEvent event;

  @override
  Widget build(BuildContext context) {
    final t = event.triggerUtc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2A2E)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                event.isRear ? Icons.flip_camera_android : Icons.videocam_outlined,
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                event.positionLabel,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
              if (event.testEvent) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.warningOrange),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '테스트',
                    style: TextStyle(color: AppTheme.warningOrange, fontSize: 11),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _item('충격 세기', event.impactLabel),
              const SizedBox(width: 28),
              _item('충격 시각', time),
            ],
          ),
        ],
      ),
    );
  }

  Widget _item(String label, String value) => Column(
        children: [
          Text(label,
              style: const TextStyle(color: AppTheme.textHint, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  color: Colors.white, fontSize: 16, fontWeight: FontWeight.w300)),
        ],
      );
}
