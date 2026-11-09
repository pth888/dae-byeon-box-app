// lib/widgets/accident_alert_dialog.dart
//
// 충격 감지 → 초동 대처 시작 화면 (사고 감지 화면 안에 그려지는 창 하나)
//   1) 15초 카운트다운: "네, 사고 났어요" / "아니요, 괜찮아요"
//   2) 15초 동안 반응이 없으면 같은 창에서 119·보호자에게 문자를 보내고 결과를 보여준다
//        119 는 시연만, 보호자 문자는 안드로이드에서 실제 발송
//        (아이폰·아이패드·블랙박스 테스트 충격은 시연)
//   3) 결과를 보여준 뒤 10초 카운트다운 → 초동 대처 1단계로 이동

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

/// 앱에 들어 있는 한글 글꼴(보통·굵게)만 쓴다.
const String _kFont = 'NotoSansKR';

const TextStyle _titleStyle = TextStyle(
    fontFamily: _kFont,
    fontSize: 17,
    fontWeight: FontWeight.w700,
    color: Colors.white,
    height: 1.35);
const TextStyle _bodyStyle = TextStyle(
    fontFamily: _kFont,
    fontSize: 13.5,
    fontWeight: FontWeight.w400,
    color: Colors.white,
    height: 1.5);

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

  /// 초동 대처 1단계로 이동 ("네, 사고 났어요" 또는 문자 발송 후 10초)
  final VoidCallback onAccident;

  /// "아니요, 괜찮아요" 또는 문자 발송 후 "닫기"
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
  Widget build(BuildContext context) => MediaQuery(
        // 아이패드 '볼드체 텍스트' 설정이 켜져 있으면 한글 획이 겹쳐 보여서 끈다
        data: MediaQuery.of(context).copyWith(boldText: false),
        child: PopScope(
          canPop: false,
          child: switch (_phase) {
            _Phase.countdown => _countdownDialog(),
            _Phase.sending => _sendingDialog(),
            _Phase.sent => _sentDialog(_result!),
          },
        ),
      );

  // ── 1. 15초 카운트다운 ─────────────────────────────────
  Widget _countdownDialog() {
    final contact = ref.watch(emergencyContactProvider);
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: _titleStyle,
      contentTextStyle: _bodyStyle,
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 22),
      title: const Row(
        children: [
          Icon(Icons.warning_amber, color: Colors.red, size: 28),
          SizedBox(width: 8),
          Expanded(child: Text('충격이 감지되었습니다')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_impactText, textAlign: TextAlign.center),
            if (widget.isTestEvent) ...[
              const SizedBox(height: 6),
              _chip('테스트 충격', AppTheme.warningOrange),
            ],
            const SizedBox(height: 14),
            Text(
              '$_countdown',
              style: TextStyle(
                fontFamily: _kFont,
                fontSize: 40,
                fontWeight: FontWeight.w400,
                height: 1.2,
                color: _countdown <= 5 ? Colors.red : null,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '사고가 발생했나요?\n응답이 없으면 119와 보호자에게 문자를 보냅니다.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              contact == null
                  ? '보호자 미등록 · 마이페이지에서 등록할 수 있어요'
                  : '보호자 ${contact.label}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontFamily: _kFont, fontSize: 12, color: AppTheme.textSub),
            ),
            const SizedBox(height: 22),
            _buttons(
              primary: '네, 사고 났어요',
              onPrimary: () => _complete(widget.onAccident),
              secondary: '아니요, 괜찮아요',
              onSecondary: () => _complete(widget.onDismiss),
            ),
          ],
        ),
      ),
    );
  }

  // ── 2. 보내는 중 ────────────────────────────────────────
  Widget _sendingDialog() {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: _titleStyle,
      contentTextStyle: _bodyStyle,
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: 8),
          SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(height: 18),
          Text('응답이 없어 119와 보호자에게\n문자를 보내는 중입니다',
              textAlign: TextAlign.center),
        ],
      ),
    );
  }

  // ── 3. 문자 발송 결과 + 10초 뒤 1단계 ───────────────────
  Widget _sentDialog(EmergencyDispatchResult r) {
    final demo = r.demoReason != null;
    final address = r.location?.address;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: _titleStyle,
      contentTextStyle: _bodyStyle,
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 22),
      title: const Row(
        children: [
          Icon(Icons.campaign_outlined, color: Colors.red, size: 28),
          SizedBox(width: 8),
          Expanded(child: Text('119와 보호자에게\n문자를 발송했습니다')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '$kAccidentCountdownSeconds초 동안 응답이 없어 사고 위치를 알렸습니다.',
              style: TextStyle(
                  fontFamily: _kFont, fontSize: 13, color: AppTheme.textSub),
            ),
            const SizedBox(height: 14),
            _row(Icons.local_hospital_outlined, '119 긴급 신고', '시연',
                AppTheme.warningOrange),
            const SizedBox(height: 8),
            _guardianRow(r),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.place_outlined,
                    size: 16, color: AppTheme.textSub),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    r.location == null
                        ? '위치를 확인하지 못해 위치 없이 보냈습니다'
                        : (address ??
                            '${r.location!.latitude.toStringAsFixed(5)}, ${r.location!.longitude.toStringAsFixed(5)}'),
                    style: const TextStyle(fontFamily: _kFont, fontSize: 12.5),
                  ),
                ),
              ],
            ),
            if (demo) ...[
              const SizedBox(height: 12),
              Text(
                r.demoReason!,
                style: const TextStyle(
                    fontFamily: _kFont,
                    fontSize: 11.5,
                    color: AppTheme.warningOrange,
                    height: 1.4),
              ),
            ],
            const SizedBox(height: 14),
            const Text('보낸 문자 내용',
                style: TextStyle(
                    fontFamily: _kFont,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF3A3A3E)),
              ),
              child: Text(r.message,
                  style: const TextStyle(
                      fontFamily: _kFont,
                      fontSize: 12.5,
                      height: 1.5,
                      color: AppTheme.textSub)),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                '$_afterCountdown초 후 초동 대처 1단계로 넘어갑니다',
                style: const TextStyle(
                    fontFamily: _kFont,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white),
              ),
            ),
            const SizedBox(height: 14),
            _buttons(
              primary: '지금 1단계로',
              onPrimary: () => _complete(widget.onAccident),
              secondary: '닫기',
              onSecondary: () => _complete(widget.onDismiss),
            ),
          ],
        ),
      ),
    );
  }

  /// 위: 빨간 버튼(주 동작) · 아래: 테두리 버튼. 둘 다 창 너비만큼.
  Widget _buttons({
    required String primary,
    required VoidCallback onPrimary,
    required String secondary,
    required VoidCallback onSecondary,
  }) {
    const shape = StadiumBorder();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 48,
          child: ElevatedButton(
            onPressed: onPrimary,
            style: ElevatedButton.styleFrom(
              // 테마의 위아래 여백(18) 때문에 글자 아래가 잘려서 0 으로 둔다
              padding: const EdgeInsets.symmetric(horizontal: 16),
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: shape,
            ),
            child: Text(primary,
                style: const TextStyle(
                    fontFamily: _kFont,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 48,
          child: OutlinedButton(
            onPressed: onSecondary,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              foregroundColor: Theme.of(context).colorScheme.onSurface,
              side: const BorderSide(color: Color(0xFF5A5A5E)),
              shape: shape,
            ),
            child: Text(secondary,
                style: const TextStyle(
                    fontFamily: _kFont,
                    fontSize: 14,
                    fontWeight: FontWeight.w400)),
          ),
        ),
      ],
    );
  }

  Widget _guardianRow(EmergencyDispatchResult r) {
    final name = r.contact == null ? '보호자' : '보호자 ${r.contact!.label}';
    return switch (r.guardian) {
      GuardianSmsStatus.sent =>
        _row(Icons.sms_outlined, name, '전송 완료', AppTheme.successGreen),
      GuardianSmsStatus.simulated =>
        _row(Icons.sms_outlined, name, '시연', AppTheme.warningOrange),
      GuardianSmsStatus.noContact => _row(Icons.person_off_outlined,
          '보호자 미등록 (마이페이지에서 등록)', '미등록', AppTheme.textSub),
      GuardianSmsStatus.permissionDenied => _row(Icons.sms_failed_outlined,
          '$name · 문자 권한 없음', '실패', AppTheme.errorRed),
      GuardianSmsStatus.failed => _row(Icons.sms_failed_outlined,
          '$name · 문자 전송 실패', '실패', AppTheme.errorRed),
    };
  }

  Widget _row(IconData icon, String title, String chip, Color color) {
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 10),
        Expanded(
            child: Text(title,
                style: const TextStyle(fontFamily: _kFont, fontSize: 13.5))),
        const SizedBox(width: 8),
        _chip(chip, color),
      ],
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(
              fontFamily: _kFont,
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700)),
    );
  }
}
