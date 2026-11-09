import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/case_service.dart';
import '../../services/sensor_service.dart';
import '../../utils/theme.dart';
import '../../widgets/accident_alert_dialog.dart';

class AccidentDetectionScreen extends ConsumerStatefulWidget {
  const AccidentDetectionScreen({
    super.key,
    this.caseId,
    this.impactG,
    this.deviceName,
    this.eventId,
    this.deviceId,
    this.triggeredAt,
    this.isTestEvent = false,
  });

  final String? caseId;
  final double? impactG;
  final String? deviceName;
  final String? eventId;
  final String? deviceId;
  final DateTime? triggeredAt;
  final bool isTestEvent;

  @override
  ConsumerState<AccidentDetectionScreen> createState() =>
      _AccidentDetectionScreenState();
}

class _AccidentDetectionScreenState
    extends ConsumerState<AccidentDetectionScreen> {
  bool _resolvingCase = false;

  Future<void> _onAccident() async {
    if (!mounted || _resolvingCase) return;
    setState(() => _resolvingCase = true);
    try {
      // A shock may arrive before video upload creates its owned case.
      if (widget.caseId == null &&
          widget.eventId != null &&
          widget.deviceId != null) {
        ref.read(sensorProvider.notifier).dismissAlert();
        context.goNamed('first-response', extra: {
          'hardware_event_id': widget.eventId,
          'hardware_device_id': widget.deviceId,
          'hardware_trigger_utc': widget.triggeredAt,
        });
        return;
      }
      final backendCase =
          await ref.read(caseServiceProvider).resolveForAccident(
                caseId: widget.caseId,
                occurredAt: widget.triggeredAt,
              );
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
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppTheme.bgBlack,
        body: AccidentAlertDialog(
          gForce: widget.impactG,
          deviceName: widget.deviceName,
          isTestEvent: widget.isTestEvent,
          onAccident: _onAccident,
          onDismiss: _onDismiss,
        ),
      );
}
