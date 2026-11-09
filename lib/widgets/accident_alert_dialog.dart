// lib/widgets/accident_alert_dialog.dart
//
// 충격 감지 → 초동 대처 시작 화면 (전체 화면, 테슬라 스타일 큰 카운트다운)
//   1) 15초 카운트다운: 충격 강도·보호자 표시, "지금 시작" / "오작동입니다"
//   2) 15초 동안 반응이 없으면 같은 화면에서 119·보호자에게 문자를 보내고 결과를 보여준다
//        119 는 시연만, 보호자 문자는 안드로이드에서 실제 발송
//        (아이폰·아이패드·블랙박스 테스트 충격은 시연)
//   3) 결과를 보여주면서 10초 카운트다운 → 초동 대처 1단계로 이동
//
// 팝업 창이 아니라 사고 감지 화면(AccidentDetectionScreen)의 본문 전체로 그린다.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/emergency_contact_service.dart';
import '../services/emergency_dispatch_service.dart';
import '../utils/theme.dart';

/// 응답을 기다리는 시간
const int kAccidentCountdownSeconds = 15;

/// 문자 발송 결과를 보여준 뒤 1단계로 넘어가기까지의 시간
const int kAfterDispatchSeconds = 10;

/// 넓은 화면(아이패드)에서도 가운데 이 너비 안에 모은다
const double _kMaxContentWidth = 560;

enum _Phase { countdown, sending, sent }

class AccidentAlertDialog extends ConsumerStatefulWidget {
  const AccidentAlertDialog({
    super.key,
    this.gForce,
    this.deviceName,
    this.isTestEvent = false,
    required this.onAccident,
    required this.onDismiss,
  });

  final double? gForce;
  final String? deviceName;
  final bool isTestEvent;

  /// 초동 대처 1단계로 이동 ("지금 시작" 또는 문자 발송 후 10초)
  final VoidCallback onAccident;

  /// "오작동입니다" 또는 문자 발송 후 "닫기"
  final VoidCallback onDismiss;

  @override
  ConsumerState<AccidentAlertDialog> createState() =>
      _AccidentAlertDialogState();
}

class _AccidentAlertDialogState extends ConsumerState<AccidentAlertDialog> {
  int _countdown = kAccidentCountdownSeconds;
  int _afterCountdown = kAfterDispatchSeconds;
  _Phase _phase = _Phase.countdown;
  Timer? _timer;
  bool _acknowledged = false;
  EmergencyDispatchResult? _result;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _acknowledged || _phase != _Phase.countdown) {
        timer.cancel();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 5 && _countdown > 0) HapticFeedback.heavyImpact();
      if (_countdown <= 0) {
        timer.cancel();
        _dispatch();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _complete(VoidCallback callback) {
    if (_acknowledged) return;
    _acknowledged = true;
    _timer?.cancel();
    callback();
  }

  // ── 15초 무응답: 119·보호자 문자 ─────────────────────────
  Future<void> _dispatch() async {
    if (!mounted || _acknowledged || _phase != _Phase.countdown) return;
    setState(() => _phase = _Phase.sending);
    EmergencyContact? contact;
    try {
      contact = await ref.read(emergencyContactProvider.notifier).current();
    } catch (_) {
      contact = null;
    }
    final result = await ref.read(emergencyDispatcherProvider).dispatch(
          contact: contact,
          testEvent: widget.isTestEvent,
        );
    if (!mounted || _acknowledged) return;
    setState(() {
      _result = result;
      _phase = _Phase.sent;
    });
    // 결과를 보여주고 10초 뒤 1단계로
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _acknowledged) {
        timer.cancel();
        return;
      }
      setState(() => _afterCountdown--);
      if (_afterCountdown <= 0) {
        timer.cancel();
        _complete(widget.onAccident);
      }
    });
  }

  String get _impactText {
    final g = widget.gForce;
    final impact = g == null || !g.isFinite || g < 0
        ? '충격 강도 측정값 없음'
        : '충격 강도: ${g.toStringAsFixed(1)}G';
    return widget.deviceName == null ? impact : '${widget.deviceName} · $impact';
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (_phase) {
      _Phase.countdown => _countdownView(),
      _Phase.sending => _sendingView(),
      _Phase.sent => _sentView(_result!),
    };
    return MediaQuery(
      // 아이패드 '볼드체 텍스트' 설정이 켜져 있으면 한글 획이 겹쳐 보여서 끈다
      data: MediaQuery.of(context).copyWith(boldText: false),
      child: PopScope(
        canPop: false,
        child: ColoredBox(
          color: AppTheme.bgBlack,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
              child: Center(
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: _kMaxContentWidth),
                  child: body,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 1. 15초 카운트다운 ─────────────────────────────────
  Widget _countdownView() {
    final contact = ref.watch(emergencyContactProvider);
    return Column(
      children: [
        const SizedBox(height: 40),
        _topLabel('충격 감지됨'),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _bigNumber(_countdown, warn: _countdown <= 5),
                  const SizedBox(height: 24),
                  const Text(
                    '충격이 감지되었습니다',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          _impactText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 15),
                        ),
                      ),
                      if (widget.isTestEvent) ...[
                        const SizedBox(width: 8),
                        _chip('테스트 충격', AppTheme.warningOrange),
                      ],
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '응답이 없으면 $_countdown초 후\n119와 보호자에게 문자를 보냅니다',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppTheme.textSub,
                      fontSize: 14,
                      height: 1.5,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(height: 12),
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
                      Flexible(
                        child: Text(
                          contact == null
                              ? '보호자 미등록 · 마이페이지에서 등록할 수 있어요'
                              : '보호자 ${contact.label}',
                          style: const TextStyle(
                              color: AppTheme.textHint, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        _primaryButton('지금 시작', () => _complete(widget.onAccident)),
        const SizedBox(height: 12),
        _outlineButton('오작동입니다', () => _complete(widget.onDismiss)),
      ],
    );
  }

  // ── 2. 보내는 중 ────────────────────────────────────────
  Widget _sendingView() {
    return Column(
      children: [
        const SizedBox(height: 40),
        _topLabel('충격 감지됨'),
        const Expanded(
          child: Center(
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
                  '응답이 없어 119와 보호자에게\n문자를 보내는 중입니다',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      height: 1.5,
                      fontWeight: FontWeight.w300),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── 3. 문자 발송 결과 + 10초 뒤 1단계 ───────────────────
  Widget _sentView(EmergencyDispatchResult r) {
    final demo = r.demoReason != null;
    final address = r.location?.address;
    return Column(
      children: [
        const SizedBox(height: 40),
        _topLabel('긴급 문자 발송됨'),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _bigNumber(_afterCountdown, size: 96),
                  const SizedBox(height: 18),
                  const Text(
                    '119와 보호자에게 문자를 발송했습니다',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$kAccidentCountdownSeconds초 동안 응답이 없어 사고 위치를 알렸습니다\n'
                    '$_afterCountdown초 후 초동 대처 1단계로 넘어갑니다',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppTheme.textSub,
                      fontSize: 14,
                      height: 1.5,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(height: 26),
                  _statusRow(Icons.local_hospital_outlined, '119 긴급 신고',
                      '시연', AppTheme.warningOrange),
                  const SizedBox(height: 10),
                  _guardianRow(r),
                  const SizedBox(height: 10),
                  _statusRow(
                    Icons.place_outlined,
                    r.location == null
                        ? '위치를 확인하지 못해 위치 없이 보냈습니다'
                        : (address ??
                            '${r.location!.latitude.toStringAsFixed(5)}, ${r.location!.longitude.toStringAsFixed(5)}'),
                    null,
                    null,
                  ),
                  if (demo) ...[
                    const SizedBox(height: 12),
                    Text(
                      r.demoReason!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppTheme.warningOrange,
                          fontSize: 12,
                          height: 1.4),
                    ),
                  ],
                  const SizedBox(height: 22),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '보낸 문자 내용',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                  const SizedBox(height: 8),
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
                        color: AppTheme.textSub,
                        fontSize: 13,
                        height: 1.6,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        _primaryButton('지금 1단계로', () => _complete(widget.onAccident)),
        const SizedBox(height: 12),
        _outlineButton('닫기', () => _complete(widget.onDismiss)),
      ],
    );
  }

  Widget _guardianRow(EmergencyDispatchResult r) {
    final name = r.contact == null ? '보호자' : '보호자 ${r.contact!.label}';
    return switch (r.guardian) {
      GuardianSmsStatus.sent => _statusRow(
          Icons.sms_outlined, name, '전송 완료', AppTheme.successGreen),
      GuardianSmsStatus.simulated => _statusRow(
          Icons.sms_outlined, name, '시연', AppTheme.warningOrange),
      GuardianSmsStatus.noContact => _statusRow(Icons.person_off_outlined,
          '보호자 미등록 (마이페이지에서 등록)', '미등록', AppTheme.textSub),
      GuardianSmsStatus.permissionDenied => _statusRow(
          Icons.sms_failed_outlined,
          '$name · 문자 권한 없음',
          '실패',
          AppTheme.errorRed),
      GuardianSmsStatus.failed => _statusRow(Icons.sms_failed_outlined,
          '$name · 문자 전송 실패', '실패', AppTheme.errorRed),
    };
  }

  // ── 공통 조각 ───────────────────────────────────────────
  Widget _topLabel(String text) {
    return Row(
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
        Text(
          text,
          style: const TextStyle(
            color: AppTheme.errorRed,
            fontSize: 13,
            fontWeight: FontWeight.w400,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _bigNumber(int value, {bool warn = false, double size = 160}) {
    return Text(
      '$value',
      style: TextStyle(
        color: warn ? AppTheme.errorRed : Colors.white,
        fontSize: size,
        fontWeight: FontWeight.w100,
        height: 1.1,
        letterSpacing: -4,
      ),
    );
  }

  Widget _statusRow(IconData icon, String title, String? chip, Color? color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2A2E)),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(title,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
          ),
          if (chip != null && color != null) ...[
            const SizedBox(width: 10),
            _chip(chip, color),
          ],
        ],
      ),
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w500)),
    );
  }

  Widget _primaryButton(String label, VoidCallback onTap) {
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
}
