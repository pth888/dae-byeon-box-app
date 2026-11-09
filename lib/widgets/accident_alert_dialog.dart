import 'dart:async';

import 'package:flutter/material.dart';

const int kAccidentCountdownSeconds = 15;

class AccidentAlertDialog extends StatefulWidget {
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
  final VoidCallback onAccident;
  final VoidCallback onDismiss;

  @override
  State<AccidentAlertDialog> createState() => _AccidentAlertDialogState();
}

class _AccidentAlertDialogState extends State<AccidentAlertDialog> {
  int _countdown = kAccidentCountdownSeconds;
  Timer? _timer;
  bool _acknowledged = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _acknowledged) return;
      setState(() => _countdown--);
      if (_countdown <= 0) _complete(widget.onAccident);
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

  String get _impactText {
    final g = widget.gForce;
    final impact = g == null || !g.isFinite || g < 0
        ? '충격 강도 측정값 없음'
        : '충격 강도: ${g.toStringAsFixed(1)}G';
    return widget.deviceName == null ? impact : '${widget.deviceName} · $impact';
  }

  @override
  Widget build(BuildContext context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(boldText: false),
        child: PopScope(
          canPop: false,
          child: AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            title: const Row(
              children: [
                Icon(Icons.warning_amber, color: Colors.red, size: 28),
                SizedBox(width: 8),
                Expanded(
                  child: Text('충격이 감지되었습니다',
                      style: TextStyle(fontFamily: 'NotoSansKR', fontSize: 17)),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_impactText, textAlign: TextAlign.center),
                  if (widget.isTestEvent) const Text('테스트 충격'),
                  const SizedBox(height: 12),
                  Text('$_countdown', style: const TextStyle(fontSize: 40)),
                  const SizedBox(height: 8),
                  Text(
                    '사고가 발생했나요?\n$_countdown초 후 초동 대처를 시작합니다.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => _complete(widget.onDismiss),
                child: const Text('아니요, 괜찮아요'),
              ),
              FilledButton(
                onPressed: () => _complete(widget.onAccident),
                child: const Text('네, 사고 났어요'),
              ),
            ],
          ),
        ),
      );
}
