// lib/widgets/accident_alert_dialog.dart
//
// 충격 감지 알림창
//   - 충격 강도와 15초 카운트다운을 보여준다
//   - "네, 사고 났어요" / "아니요, 괜찮아요" 중 하나를 누르면 그대로 진행
//   - 15초 동안 응답이 없으면 같은 창에서 119·보호자 긴급 알림을 보내고 결과를 보여준다
//       119 는 시연만, 보호자 문자는 안드로이드에서 실제 발송
//       (아이폰·아이패드·블랙박스 테스트 충격은 시연)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/emergency_contact_service.dart';
import '../services/emergency_dispatch_service.dart';
import '../services/hardware_event_service.dart';
import '../utils/theme.dart';

/// 응답을 기다리는 시간
const int kEmergencyCountdownSeconds = 15;

/// 알림창 글꼴: 앱에 들어 있는 한글 글꼴(보통·굵게 두 가지)만 쓴다.
/// 기기 기본 글꼴의 중간 굵기를 흉내 내면서 글자가 번져 보이는 것을 막는다.
const String _kFont = 'NotoSansKR';

enum _Phase { countdown, sending, sent }

class AccidentAlertDialog extends ConsumerStatefulWidget {
  const AccidentAlertDialog({
    super.key,
    this.gForce,
    this.hardwareEvent,
    required this.onAccident,
    required this.onDismiss,
  });

  /// 휴대폰 센서로 잰 충격 (블랙박스 알림이면 null 일 수 있음)
  final double? gForce;

  /// 블랙박스 충격 알림이면 그 이벤트
  final HardwareEvent? hardwareEvent;

  /// "네, 사고 났어요" 또는 긴급 알림 뒤 "초동 대처 시작"
  final VoidCallback onAccident;

  /// "아니요, 괜찮아요" 또는 긴급 알림 뒤 "닫기"
  final VoidCallback onDismiss;

  /// 알림창이 이미 떠 있는지 (같은 충격으로 여러 개 뜨지 않게)
  static bool get isOpen => _showing || _openCount > 0;
  static int _openCount = 0;
  static bool _showing = false;

  /// 알림창을 한 번만 띄운다.
  /// 같은 순간에 충격 신호가 두 번 오면(전방·후방 동시, 센서 연속 등) 창이 겹쳐 뜨면서
  /// 같은 글자가 두 겹으로 그려져 번져 보였다. 띄우기 전에 바로 표시해서 막는다.
  static Future<void> showOnce(BuildContext context, WidgetBuilder builder) async {
    if (isOpen) return;
    _showing = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: builder,
      );
    } finally {
      _showing = false;
    }
  }

  @override
  ConsumerState<AccidentAlertDialog> createState() =>
      _AccidentAlertDialogState();
}

const TextStyle _titleStyle = TextStyle(
    fontFamily: _kFont,
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: Colors.white,
    height: 1.35);
const TextStyle _bodyStyle = TextStyle(
    fontFamily: _kFont,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: Colors.white,
    height: 1.5);

class _AccidentAlertDialogState extends ConsumerState<AccidentAlertDialog> {
  int _countdown = kEmergencyCountdownSeconds;
  _Phase _phase = _Phase.countdown;
  Timer? _timer;
  EmergencyDispatchResult? _result;

  @override
  void initState() {
    super.initState();
    AccidentAlertDialog._openCount++;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _phase != _Phase.countdown) {
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
    AccidentAlertDialog._openCount--;
    super.dispose();
  }

  Future<void> _dispatch() async {
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

  void _accident() {
    _timer?.cancel();
    widget.onAccident();
  }

  void _dismiss() {
    _timer?.cancel();
    widget.onDismiss();
  }

  String get _impactText {
    final hw = widget.hardwareEvent;
    if (hw != null) {
      final g = hw.impactG ?? widget.gForce;
      return '${hw.positionLabel} · 충격 강도 ${g == null ? '측정값 없음' : '${g.toStringAsFixed(1)}G'}';
    }
    final g = widget.gForce;
    return g == null ? '충격 강도 측정값 없음' : '충격 강도: ${g.toStringAsFixed(1)}G';
  }

  @override
  Widget build(BuildContext context) {
    // 아이패드 '볼드체 텍스트'(손쉬운 사용)가 켜져 있으면 글자를 한 단계 더 굵게 그리는데,
    // 글꼴에 없는 굵기를 억지로 만들면서 한글 획이 겹쳐 깨져 보인다.
    // 알림창 안에서는 이 설정을 끄고, 글꼴에 있는 굵기(보통·굵게)만 쓴다.
    return MediaQuery(
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
  }

  // ── 1. 카운트다운 ───────────────────────────────────────
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
          Text('충격이 감지되었습니다', style: TextStyle(fontFamily: _kFont, fontSize: 18)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(_impactText, textAlign: TextAlign.center)),
              if (widget.hardwareEvent?.testEvent == true) ...[
                const SizedBox(width: 6),
                _chip('테스트', AppTheme.warningOrange),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '$_countdown',
            style: TextStyle(fontFamily: _kFont, 
              fontSize: 44,
              fontWeight: FontWeight.w400,
              height: 1,
              color: _countdown <= 5 ? Colors.red : null,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '사고가 발생했나요?\n응답이 없으면 119와 보호자에게 연락합니다.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            contact == null
                ? '보호자 미등록 · 마이페이지에서 등록할 수 있어요'
                : '보호자 ${contact.label}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: _kFont, fontSize: 12, color: AppTheme.textSub),
          ),
          const SizedBox(height: 22),
          _buttons(
            primary: '네, 사고 났어요',
            onPrimary: _accident,
            secondary: '아니요, 괜찮아요',
            onSecondary: _dismiss,
          ),
        ],
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
          Text('응답이 없어 119와 보호자에게\n연락하는 중입니다',
              textAlign: TextAlign.center),
        ],
      ),
    );
  }

  // ── 3. 연락 완료 ────────────────────────────────────────
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
          Flexible(
            child: Text('119와 보호자에게\n연락했습니다',
                style: TextStyle(fontFamily: _kFont, fontSize: 18)),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$kEmergencyCountdownSeconds초 동안 응답이 없어 사고 위치를 알렸습니다.',
              style: const TextStyle(fontFamily: _kFont, fontSize: 13, color: AppTheme.textSub),
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
                style: const TextStyle(fontFamily: _kFont, 
                    fontSize: 11.5,
                    color: AppTheme.warningOrange,
                    height: 1.4),
              ),
            ],
            const SizedBox(height: 4),
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 4),
                title: const Text('보낸 문자 내용 보기',
                    style: TextStyle(fontFamily: _kFont, fontSize: 13)),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(r.message,
                        style: const TextStyle(fontFamily: _kFont, 
                            fontSize: 12.5,
                            height: 1.5,
                            color: AppTheme.textSub)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _buttons(
              primary: '초동 대처 시작',
              onPrimary: _accident,
              secondary: '닫기',
              onSecondary: _dismiss,
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
          height: 50,
          child: ElevatedButton(
            onPressed: onPrimary,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: shape,
            ),
            child: Text(primary,
                style: const TextStyle(fontFamily: _kFont, 
                    fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 50,
          child: OutlinedButton(
            onPressed: onSecondary,
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onSurface,
              side: const BorderSide(color: Color(0xFF5A5A5E)),
              shape: shape,
            ),
            child: Text(secondary,
                style: const TextStyle(fontFamily: _kFont, 
                    fontSize: 15, fontWeight: FontWeight.w400)),
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
      GuardianSmsStatus.failed => _row(
          Icons.sms_failed_outlined, '$name · 문자 전송 실패', '실패', AppTheme.errorRed),
    };
  }

  Widget _row(IconData icon, String title, String chip, Color color) {
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(title, style: const TextStyle(fontFamily: _kFont, fontSize: 14))),
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
          style: TextStyle(fontFamily: _kFont, 
              color: color, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}
