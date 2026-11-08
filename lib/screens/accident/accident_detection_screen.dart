// lib/screens/accident/accident_detection_screen.dart
// 테슬라 미니멀 스타일 - 큰 카운트다운

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/case_service.dart';
import '../../services/hardware_event_service.dart';
import '../../services/sensor_service.dart';
import '../../utils/theme.dart';

class AccidentDetectionScreen extends ConsumerStatefulWidget {
  const AccidentDetectionScreen({super.key, this.caseId, this.hardwareEvent});

  final String? caseId;

  /// 블랙박스 충격 알림으로 열린 경우의 이벤트 (휴대폰 센서면 null)
  final HardwareEvent? hardwareEvent;

  @override
  ConsumerState<AccidentDetectionScreen> createState() =>
      _AccidentDetectionScreenState();
}

class _AccidentDetectionScreenState
    extends ConsumerState<AccidentDetectionScreen> {
  int _countdown = 10;
  bool _resolvingCase = false;

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  void _startCountdown() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      setState(() => _countdown--);
      if (_countdown <= 0) {
        _onAccident();
        return false;
      }
      return true;
    });
  }

  Future<void> _onAccident() async {
    if (!mounted || _resolvingCase) return;
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
        child: Padding(
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$_countdown',
                        style: TextStyle(
                          color: _countdown <= 3
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
                        '$_countdown초 후 자동으로 초동 대처를 시작합니다',
                        style: const TextStyle(
                          color: AppTheme.textSub,
                          fontSize: 14,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                      if (widget.hardwareEvent != null) ...[
                        const SizedBox(height: 28),
                        _HardwareEventInfo(event: widget.hardwareEvent!),
                      ],
                    ],
                  ),
                ),
              ),

              // 하단 버튼들
              GestureDetector(
                onTap: _resolvingCase ? null : _onAccident,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    color: AppTheme.pointWhite,
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Center(
                    child: Text(
                      _resolvingCase ? '사고 사건 확인 중' : '지금 시작',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: _onDismiss,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF3A3A3E)),
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: const Center(
                    child: Text(
                      '오작동입니다',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
