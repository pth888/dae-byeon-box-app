// lib/screens/home/main_page.dart
// 테슬라 미니멀 스타일

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/auth_service.dart';
import '../../services/case_service.dart';
import '../../services/hardware_event_service.dart';
import '../../services/sensor_service.dart';
import '../../services/location_service.dart';
import '../../utils/theme.dart';
import '../../widgets/accident_alert_dialog.dart';
import '../../widgets/brand_logo.dart';

class MainPage extends ConsumerStatefulWidget {
  const MainPage({super.key});

  @override
  ConsumerState<MainPage> createState() => _MainPageState();
}

class _MainPageState extends ConsumerState<MainPage> {
  bool _openingManualIncident = false;
  StreamSubscription<HardwareEvent>? _hardwareSub;
  late final HardwareEventWatcher _hardwareWatcher;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(locationProvider.notifier).requestLocationAndFetch();
    });
    // 블랙박스 충격 알림: 홈 화면이 보이고 앱이 앞에 있을 때만 1초마다 조회
    _hardwareWatcher = ref.read(hardwareEventWatcherProvider);
    _hardwareSub = _hardwareWatcher.incidents.listen(_onHardwareIncident);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _hardwareWatcher.start(isActive: _homeIsVisible);
    });
  }

  bool _homeIsVisible() {
    if (!mounted) return false;
    // 충격 알림창이 떠 있는 동안은 블랙박스 알림 조회를 쉰다 (창이 겹쳐 뜨지 않게)
    if (AccidentAlertDialog.isOpen) return false;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return false;
    }
    return ModalRoute.of(context)?.isCurrent ?? true;
  }

  void _onHardwareIncident(HardwareEvent event) {
    if (!mounted || !_homeIsVisible() || AccidentAlertDialog.isOpen) return;
    // 블랙박스 충격도 휴대폰 센서와 같은 알림창 (15초 무응답 시 119·보호자 연락)
    AccidentAlertDialog.showOnce(
      context,
      (dialogContext) => AccidentAlertDialog(
        hardwareEvent: event,
        onAccident: () {
          Navigator.pop(dialogContext);
          context.pushNamed('accident-detected', extra: event);
        },
        onDismiss: () => Navigator.pop(dialogContext),
      ),
    );
  }

  @override
  void dispose() {
    _hardwareSub?.cancel();
    _hardwareWatcher.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sensorState = ref.watch(sensorProvider);

    ref.listen<SensorState>(sensorProvider, (prev, next) {
      if (next.isImpactDetected &&
          !(prev?.isImpactDetected ?? false) &&
          !AccidentAlertDialog.isOpen) {
        AccidentAlertDialog.showOnce(
          context,
          (dialogContext) => AccidentAlertDialog(
            gForce: next.currentGForce,
            onAccident: () {
              final caseId = next.caseId;
              Navigator.pop(dialogContext);
              ref.read(sensorProvider.notifier).dismissAlert();
              context.pushNamed('accident-detected', extra: caseId);
            },
            onDismiss: () {
              Navigator.pop(dialogContext);
              ref.read(sensorProvider.notifier).dismissAlert();
            },
          ),
        );
      }
    });

    return Scaffold(
      backgroundColor: AppTheme.bgBlack,
      body: SafeArea(
        child: Column(
          children: [
            // ── 상단 바 ────────────────────────────────
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 18, 24, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  BrandLogo(fontSize: 18),
                ],
              ),
            ),

            // ── 중앙: 보호 상태 ────────────────────────
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 원형 상태 아이콘
                    Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: sensorState.isMonitoring
                              ? AppTheme.teslaRed
                              : AppTheme.textHint,
                          width: 1.5,
                        ),
                      ),
                      child: Icon(
                        sensorState.isMonitoring
                            ? Icons.shield_outlined
                            : Icons.gpp_bad_outlined,
                        color: sensorState.isMonitoring
                            ? AppTheme.teslaRed
                            : AppTheme.textHint,
                        size: 40,
                      ),
                    ),
                    const SizedBox(height: 36),
                    Text(
                      sensorState.isMonitoring ? '보호 중' : '대기 중',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      sensorState.isMonitoring ? '사고 감지 대기' : '모니터링이 꺼져 있습니다',
                      style: const TextStyle(
                        color: AppTheme.textHint,
                        fontSize: 12,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── 하단 정보 (2개 수치) ──────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              child: Column(
                children: [
                  Container(
                    height: 0.5,
                    color: AppTheme.divider,
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _buildStat(
                        value: sensorState.currentGForce.toStringAsFixed(1),
                        unit: 'G',
                        label: '현재 충격',
                      ),
                      _buildStat(
                        value: kImpactThresholdG.toStringAsFixed(1),
                        unit: 'G',
                        label: '감지 임계값',
                        alignRight: false,
                      ),
                      _buildStat(
                        value: sensorState.isMonitoring ? 'ON' : 'OFF',
                        label: '모니터링',
                        alignRight: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ── 사고 접수 버튼 (알약형) ────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: GestureDetector(
                onTap: _openingManualIncident ? null : _startManualIncident,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    color: AppTheme.pointWhite,
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Center(
                    child: _openingManualIncident
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Text(
                            '사고 접수 시작',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.5,
                            ),
                          ),
                  ),
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: GestureDetector(
                onTap: () => context.pushNamed('accident-videos'),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.divider),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                          Icons.video_library_outlined,
                          color: Colors.white,
                          size: 20,
                        ),
                      const SizedBox(width: 10),
                      const Text(
                        '사고 영상 기록',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // ── 하단 미니 메뉴 ────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildMiniMenu(
                    icon: Icons.gavel_rounded,
                    label: '판례 검색',
                    onTap: () => context.pushNamed('verdict-library'),
                  ),
                  _buildMiniMenu(
                    icon: Icons.description_outlined,
                    label: '과실 분석 기록',
                    onTap: () => context.pushNamed('my-reports'),
                  ),
                  _buildMiniMenu(
                    icon: Icons.person_outline_rounded,
                    label: '내 정보',
                    onTap: () => context.pushNamed('mypage'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startManualIncident() async {
    final auth = ref.read(authProvider.notifier);
    final generation = auth.sessionGeneration;
    final owner = authenticatedPrincipal(ref.read(authProvider));
    if (owner == null) {
      _showMessage('로그인이 필요합니다.');
      return;
    }
    bool isCurrentOwner() =>
        mounted &&
        auth.sessionGeneration == generation &&
        authenticatedPrincipal(ref.read(authProvider)) == owner;

    setState(() => _openingManualIncident = true);
    try {
      final latest =
          await ref.read(caseServiceProvider).selectLatestHardwareCase();
      if (!isCurrentOwner()) return;

      setState(() => _openingManualIncident = false);
      final useLatest = await _confirmManualIncident(latest);
      if (!mounted || !isCurrentOwner() || useLatest == null) return;
      context.pushNamed(
        'accident-detected',
        extra: useLatest ? latest!.id : null,
      );
    } catch (error) {
      if (isCurrentOwner()) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _openingManualIncident = false);
    }
  }

  Future<bool?> _confirmManualIncident(BackendCase? latest) {
    final hasLatest = latest != null;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          hasLatest ? '수신된 블랙박스 영상이 있습니다' : '수신된 영상이 없습니다',
        ),
        content: Text(
          hasLatest
              ? '${_formatCaseDate(latest.createdAt)} 수신한 블랙박스 영상입니다.\n이 영상으로 시작할까요?'
              : '새 사고에는 원본 영상이 아직 없습니다. 영상 없이 접수한 뒤 수신 상태를 확인합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('취소'),
          ),
          if (hasLatest)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('수신 영상 사용'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('영상 없이 새 사고 접수'),
          ),
        ],
      ),
    );
  }

  String _formatCaseDate(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}.${two(local.month)}.${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.surfaceDark,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── 수치 표시 ────────────────────────────────────────────
  Widget _buildStat({
    required String value,
    String? unit,
    required String label,
    bool alignRight = false,
  }) {
    return Column(
      crossAxisAlignment:
          alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w300,
                ),
              ),
              if (unit != null)
                TextSpan(
                  text: unit,
                  style: const TextStyle(
                    color: AppTheme.textSub,
                    fontSize: 14,
                    fontWeight: FontWeight.w300,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textHint,
            fontSize: 11,
            fontWeight: FontWeight.w300,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  // ── 미니 메뉴 ────────────────────────────────────────────
  Widget _buildMiniMenu({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.divider, width: 1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.textSub,
              fontSize: 11,
              fontWeight: FontWeight.w300,
            ),
          ),
        ],
      ),
    );
  }
}
