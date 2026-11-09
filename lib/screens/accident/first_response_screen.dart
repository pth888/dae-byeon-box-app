// lib/screens/accident/first_response_screen.dart
// 테슬라 미니멀 스타일 - 색 최소화, 통일감

import 'dart:async';
import 'dart:io' if (dart.library.html) '../../utils/io_web_stub.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/auth_service.dart';
import '../../services/blackbox_video_service.dart';
import '../../services/case_service.dart';
import '../../services/local_files.dart';
import '../../services/profile_service.dart';
import '../../widgets/blackbox_video_player_widget.dart';
import '../../widgets/accident_location_map.dart';
import '../../widgets/accident_case_picker_sheet.dart';
import '../../utils/theme.dart';

class FirstResponseScreen extends ConsumerStatefulWidget {
  final String accidentId;
  final bool initialVideoStep;
  final String? hardwareEventId;
  final String? hardwareDeviceId;
  final DateTime? hardwareTriggerUtc;

  const FirstResponseScreen({
    super.key,
    required this.accidentId,
    this.initialVideoStep = false,
    this.hardwareEventId,
    this.hardwareDeviceId,
    this.hardwareTriggerUtc,
  });

  @override
  ConsumerState<FirstResponseScreen> createState() =>
      _FirstResponseScreenState();
}

class _FirstResponseScreenState extends ConsumerState<FirstResponseScreen> {
  final ImagePicker _picker = ImagePicker();
  void Function() _cancelVideoRequest = () {};
  int _photoCount = 0;
  int _videoCount = 0;
  int _currentStep = 0;
  String? _caseId;
  String? _caseError;
  bool _uploadingEvidence = false;
  Timer? _hardwareRetry;
  bool _initializingCase = false;
  bool _waitingForHardware = false;
  bool _caseIsDemo = false;
  DateTime? _hardwareWaitStarted;
  String get _effectiveCaseId => _caseId ?? widget.accidentId;
  final Set<String> _checkedChecklistItems = {};

  final _insuranceCache = const OwnerFencedInsuranceCache(SecureAuthStore());
  String _insuranceCompany = '보험사 미등록';
  String _insurancePhone = '';
  bool _insuranceStale = false;

  @override
  void initState() {
    super.initState();
    _cancelVideoRequest = ref
        .read(blackboxVideoProvider.notifier)
        .cancellationHandleForCase(widget.accidentId);
    if (widget.initialVideoStep) _currentStep = _steps.length - 1;
    _loadInsuranceInfo();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeCase());
  }

  @override
  void dispose() {
    _hardwareRetry?.cancel();
    _cancelVideoRequest();
    super.dispose();
  }

  Future<void> _initializeCase({bool automatic = false}) async {
    if (_initializingCase || !mounted) return;
    _initializingCase = true;
    _hardwareRetry?.cancel();
    _hardwareRetry = null;
    if (!automatic) _hardwareWaitStarted = DateTime.now();
    String? downloadCaseId;
    final auth = ref.read(authProvider.notifier);
    final generation = auth.sessionGeneration;
    final owner = authenticatedPrincipal(ref.read(authProvider));
    bool isCurrentOwner() =>
        mounted &&
        owner != null &&
        auth.sessionGeneration == generation &&
        authenticatedPrincipal(ref.read(authProvider)) == owner;
    try {
      if (widget.hardwareEventId != null &&
          widget.hardwareDeviceId != null &&
          _caseId == null) {
        final hardwareCase =
            await ref.read(caseServiceProvider).findHardwareEventCase(
                  widget.hardwareEventId!,
                  widget.hardwareDeviceId!,
                  triggeredAt: widget.hardwareTriggerUtc,
                );
        if (!isCurrentOwner()) return;
        if (hardwareCase == null) {
          final timedOut = DateTime.now()
                  .difference(_hardwareWaitStarted ?? DateTime.now()) >=
              const Duration(minutes: 3);
          setState(() {
            _waitingForHardware = !timedOut;
            _caseError = timedOut ? '영상 등록이 지연되고 있습니다. 잠시 후 다시 확인해 주세요.' : null;
          });
          if (!timedOut) {
            _hardwareRetry = Timer(const Duration(seconds: 2),
                () => _initializeCase(automatic: true));
          }
          return;
        }
        _hardwareRetry?.cancel();
        _caseId = hardwareCase.id;
      }
      final backendCase =
          await ref.read(caseServiceProvider).selectOwnedCase(_effectiveCaseId);
      if (!isCurrentOwner() || backendCase.id != _effectiveCaseId) return;
      setState(() {
        _caseId = backendCase.id;
        _caseIsDemo = backendCase.isDemo;
        _caseError = null;
        _waitingForHardware = false;
      });
      _cancelVideoRequest = ref
          .read(blackboxVideoProvider.notifier)
          .cancellationHandleForCase(backendCase.id);
      downloadCaseId = backendCase.id;
    } catch (error) {
      if (!isCurrentOwner()) return;
      setState(() {
        _caseError = error.toString();
        _waitingForHardware = false;
      });
    } finally {
      _initializingCase = false;
    }
    // Video polling can take minutes; it must not hold the case-lookup guard.
    if (downloadCaseId != null && isCurrentOwner()) {
      await ref
          .read(blackboxVideoProvider.notifier)
          .fetchAndDownload(downloadCaseId);
    }
  }

  Future<String> _requireOwnedCase() async {
    final backendCase =
        await ref.read(caseServiceProvider).selectOwnedCase(_effectiveCaseId);
    if (!mounted || backendCase.id != _effectiveCaseId) {
      throw const InvalidBackendCaseException('사고 사건이 변경되었습니다. 다시 시도해 주세요.');
    }
    _caseId = backendCase.id;
    _caseIsDemo = backendCase.isDemo;
    _caseError = null;
    return backendCase.id;
  }

  Future<void> _loadInsuranceInfo() async {
    final authNotifier = ref.read(authProvider.notifier);
    final generation = authNotifier.sessionGeneration;
    final owner = ref.read(authProvider).email?.trim().toLowerCase();
    if (owner == null || owner.isEmpty) return;
    bool isCurrentOwner() =>
        authNotifier.sessionGeneration == generation &&
        ref.read(authProvider).email?.trim().toLowerCase() == owner;
    final profile = await ref.read(profileServiceProvider).fetchProfile();
    if (!mounted || !isCurrentOwner()) return;
    if (profile != null) {
      var ownerStillCurrent = true;
      try {
        ownerStillCurrent = await _insuranceCache.write(
          owner: owner,
          company: profile.insuranceCompany,
          phone: profile.insurancePhone,
          isCurrentOwner: isCurrentOwner,
        );
      } catch (_) {
        ownerStillCurrent = isCurrentOwner();
      }
      if (!mounted || !ownerStillCurrent || !isCurrentOwner()) return;
      setState(() {
        _insuranceCompany = _insuranceLabel(profile.insuranceCompany);
        _insurancePhone = profile.insurancePhone ?? '';
        _insuranceStale = false;
      });
      return;
    }
    InsuranceDisplayData? cached;
    try {
      cached = await _insuranceCache.read(owner);
    } catch (_) {}
    if (!mounted || !isCurrentOwner()) return;
    setState(() {
      _insuranceCompany = _insuranceLabel(cached?.company);
      _insurancePhone = cached?.phone ?? '';
      _insuranceStale = cached != null;
    });
  }

  String _insuranceLabel(String? company) =>
      company == null || company.isEmpty ? '보험사 미등록' : company;

  // 단계 정보 (색 없이 통일)
  final List<_Step> _steps = const [
    _Step(
      icon: Icons.shield_outlined,
      title: '안전 확보',
      subtitle: '2차 사고 방지가 최우선입니다',
      desc: '비상등을 켜고 차량을 안전한 곳으로 이동하세요. 부상자가 있다면 함부로 이동시키지 마세요.',
    ),
    _Step(
      icon: Icons.phone_outlined,
      title: '신고하기',
      subtitle: '경찰·구급대에 즉시 신고하세요',
      desc: '인명 피해가 있다면 119를 먼저 호출하세요. 신고 전 절대 합의하거나 서명하지 마세요.',
    ),
    _Step(
      icon: Icons.camera_alt_outlined,
      title: '현장 촬영',
      subtitle: '모든 각도에서 촬영하세요',
      desc: '차량 위치, 바퀴 방향, 파손 부위, 번호판을 촬영하세요. 신호등, 차선, 도로 상황도 포함하세요.',
    ),
    _Step(
      icon: Icons.videocam_outlined,
      title: '블랙박스 영상 확인',
      subtitle: '사고 원본 영상을 확인합니다',
      desc: '이 사고에 연결된 블랙박스 원본 영상이 준비되면 아래에서 확인할 수 있습니다.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final step = _steps[_currentStep];

    return Scaffold(
      backgroundColor: AppTheme.bgBlack,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            _buildStepIndicator(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStepHeader(step),
                    const SizedBox(height: 28),
                    _buildActionArea(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            _buildBottomButton(),
          ],
        ),
      ),
    );
  }

  // ── 헤더 ─────────────────────────────────────────────────
  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              if (_currentStep > 0) {
                setState(() => _currentStep--);
                return;
              }
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/');
              }
            },
            child: const Icon(Icons.arrow_back_ios_new_rounded,
                size: 20, color: Colors.white),
          ),
          const Spacer(),
          const Text(
            '초동 대처',
            style: TextStyle(
              color: AppTheme.textSub,
              fontSize: 13,
              fontWeight: FontWeight.w400,
              letterSpacing: 1.5,
            ),
          ),
          const Spacer(),
          const SizedBox(width: 20),
        ],
      ),
    );
  }

  // ── 스텝 인디케이터 (얇은 점) ────────────────────────────
  Widget _buildStepIndicator() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Row(
        children: List.generate(_steps.length, (i) {
          final isDone = i < _currentStep;
          final isCurrent = i == _currentStep;
          return Expanded(
            child: Container(
              margin: EdgeInsets.only(right: i < _steps.length - 1 ? 6 : 0),
              height: 3,
              decoration: BoxDecoration(
                color:
                    isDone || isCurrent ? AppTheme.teslaRed : AppTheme.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }

  // ── 단계 헤더 (큰 제목) ──────────────────────────────────
  Widget _buildStepHeader(_Step step) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '0${_currentStep + 1}',
              style: const TextStyle(
                color: AppTheme.teslaRed,
                fontSize: 13,
                fontWeight: FontWeight.w400,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '/ 0${_steps.length}',
              style: const TextStyle(
                color: AppTheme.textHint,
                fontSize: 13,
                fontWeight: FontWeight.w300,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(step.title, style: AppTheme.h1),
        const SizedBox(height: 8),
        Text(
          step.subtitle,
          style: const TextStyle(
            color: AppTheme.textSub,
            fontSize: 14,
            fontWeight: FontWeight.w300,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          step.desc,
          style: const TextStyle(
            color: AppTheme.textSub,
            fontSize: 14,
            fontWeight: FontWeight.w300,
            height: 1.7,
          ),
        ),
      ],
    );
  }

  // ── 단계별 액션 ──────────────────────────────────────────
  Widget _buildActionArea() {
    switch (_currentStep) {
      case 0:
        return _buildChecklist([
          '비상등 점등',
          '차량을 갓길로 이동',
          '안전삼각대 설치',
          '부상자 이동 금지',
        ]);
      case 1:
        return _buildCallSection();
      case 2:
        return _buildPhotoSection();
      case 3:
        return _buildVideoSection();
      default:
        return const SizedBox.shrink();
    }
  }

  // ── 체크리스트 (미니멀) ──────────────────────────────────
  Widget _buildChecklist(List<String> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('체크리스트', style: AppTheme.label),
        const SizedBox(height: 16),
        ...items.map((item) {
          final checked = _checkedChecklistItems.contains(item);
          void toggle() {
            setState(() {
              if (checked) {
                _checkedChecklistItems.remove(item);
              } else {
                _checkedChecklistItems.add(item);
              }
            });
          }

          return Semantics(
            checked: checked,
            onTap: toggle,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: toggle,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    Icon(
                      checked
                          ? Icons.check_circle_rounded
                          : Icons.check_circle_outline_rounded,
                      color: checked ? AppTheme.teslaRed : AppTheme.textHint,
                      size: 20,
                    ),
                    const SizedBox(width: 14),
                    Text(
                      item,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  // ── 신고 섹션 (통일된 리스트) ────────────────────────────
  Widget _buildCallSection() {
    return Column(
      children: [
        _buildCallRow(
          icon: Icons.local_hospital_outlined,
          label: '구급대',
          number: '119',
          phone: '119',
        ),
        if (_insuranceStale) ...[
          const SizedBox(height: 8),
          const Align(
            alignment: Alignment.centerRight,
            child: Text(
              '오프라인 캐시 · 최신 정보 아님',
              style: TextStyle(color: AppTheme.warningOrange, fontSize: 11),
            ),
          ),
        ],
        _buildDivider(),
        _buildCallRow(
          icon: Icons.local_police_outlined,
          label: '경찰',
          number: '112',
          phone: '112',
        ),
        _buildDivider(),
        _buildCallRow(
          icon: Icons.shield_outlined,
          label: '보험사',
          number: _insuranceCompany,
          phone: _insurancePhone,
        ),
        const SizedBox(height: 24),
        const Row(
          children: [
            Icon(Icons.info_outline_rounded,
                color: AppTheme.textHint, size: 14),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '신고 전 절대 합의하거나 서명하지 마세요',
                style: TextStyle(
                  color: AppTheme.textHint,
                  fontSize: 12,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCallRow({
    required IconData icon,
    required String label,
    required String number,
    required String phone,
  }) {
    return GestureDetector(
      onTap: () => _confirmPhoneCall(label: label, number: phone),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    number,
                    style: const TextStyle(
                      color: AppTheme.textHint,
                      fontSize: 13,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.call_outlined, color: AppTheme.teslaRed, size: 20),
          ],
        ),
      ),
    );
  }

  // ── 사진 촬영 섹션 ───────────────────────────────────────
  Widget _buildPhotoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: _takePhoto,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Row(
              children: [
                const Icon(Icons.camera_alt_outlined,
                    color: Colors.white, size: 24),
                const SizedBox(width: 16),
                const Expanded(
                  child: Text(
                    '사진 촬영',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
                Text(
                  '$_photoCount장',
                  style: const TextStyle(
                    color: AppTheme.textHint,
                    fontSize: 13,
                    fontWeight: FontWeight.w300,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.add, color: AppTheme.teslaRed, size: 20),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildDivider(),
        GestureDetector(
          onTap: _uploadingEvidence ? null : _takeAdditionalVideo,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Row(
              children: [
                const Icon(Icons.videocam_outlined,
                    color: Colors.white, size: 24),
                const SizedBox(width: 16),
                const Expanded(
                  child: Text(
                    '추가 영상 촬영',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
                Text(
                  '$_videoCount개',
                  style: const TextStyle(
                    color: AppTheme.textHint,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_uploadingEvidence)
          const LinearProgressIndicator(
            minHeight: 2,
            color: AppTheme.teslaRed,
            backgroundColor: AppTheme.divider,
          ),
      ],
    );
  }

  // ── 블랙박스 영상 섹션 ───────────────────────────────────
  Widget _buildVideoSection() {
    final received = ref.watch(blackboxVideoProvider);
    if (_caseId == null || _caseId != _effectiveCaseId) {
      return _buildVideoStatus(
        icon: Icons.search_rounded,
        title: _waitingForHardware
            ? '사고 영상 등록 대기 중'
            : (_caseError == null ? '영상 확인 중' : '사고 사건을 확인할 수 없습니다'),
        subtitle: _caseError ??
            (_waitingForHardware
                ? '블랙박스가 영상을 저장·전송 중입니다. 자동으로 다시 확인합니다.'
                : '사고 사건을 확인하고 있습니다'),
        showLoading: _caseError == null && !_waitingForHardware,
        showRetry: true,
      );
    }
    final videoState =
        received.caseId == _caseId ? received : const BlackboxVideoState();

    switch (videoState.status) {
      case VideoStatus.waiting:
        return _buildVideoStatus(
          icon: Icons.cloud_queue_rounded,
          title: '원본 영상 준비 대기 중',
          subtitle: videoState.errorMessage ??
              '해당 사고의 원본 영상이 아직 준비되지 않았습니다. 자동으로 다시 확인합니다.',
          showRetry: true,
          showLatest: true,
        );
      case VideoStatus.fetching:
        return _buildVideoStatus(
          icon: Icons.search_rounded,
          title: '영상 확인 중',
          subtitle: '블랙박스 영상을 찾고 있습니다',
          showLoading: true,
        );
      case VideoStatus.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('다운로드 중', style: AppTheme.label),
            const SizedBox(height: 20),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: videoState.downloadProgress,
                minHeight: 3,
                backgroundColor: AppTheme.divider,
                color: AppTheme.teslaRed,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              videoState.progressPercent,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w200,
              ),
            ),
          ],
        );
      case VideoStatus.ready:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.check_circle_outline_rounded,
                    color: AppTheme.successGreen, size: 18),
                SizedBox(width: 8),
                Text(
                  '영상 수신 완료',
                  style: TextStyle(
                    color: AppTheme.successGreen,
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            BlackboxVideoPlayerWidget(
              localPath: videoState.localPath ?? '',
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _showMapSheet,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFF3A3A3E)),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.location_on_outlined,
                        color: Colors.white, size: 18),
                    SizedBox(width: 8),
                    Text(
                      '사고 위치 보기',
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
          ],
        );
      case VideoStatus.error:
        return _buildVideoStatus(
          icon: Icons.error_outline_rounded,
          title: '영상을 불러올 수 없습니다',
          subtitle: videoState.errorMessage ?? '다시 시도해 주세요',
          showRetry: true,
          showLatest: true,
        );
    }
  }

  void _showMapSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.84,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '사고 위치',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '닫기',
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                AccidentLocationMap(
                  key: ValueKey('map-$_effectiveCaseId'),
                  caseId: _effectiveCaseId,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoStatus({
    required IconData icon,
    required String title,
    required String subtitle,
    bool showLoading = false,
    bool showRetry = false,
    bool showLatest = false,
  }) {
    return Column(
      children: [
        const SizedBox(height: 20),
        SizedBox(
          width: 56,
          height: 56,
          child: showLoading
              ? const CircularProgressIndicator(
                  strokeWidth: 2, color: AppTheme.teslaRed)
              : Icon(icon, color: AppTheme.textSub, size: 48),
        ),
        const SizedBox(height: 20),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w300,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppTheme.textHint,
            fontSize: 12,
            fontWeight: FontWeight.w300,
          ),
        ),
        if (showRetry) ...[
          const SizedBox(height: 20),
          GestureDetector(
            onTap: () async {
              await _initializeCase();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF3A3A3E)),
                borderRadius: BorderRadius.circular(100),
              ),
              child: const Text(
                '다시 확인',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
        ],
        if (showLatest) ...[
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _openVideoPicker,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF3A3A3E)),
                borderRadius: BorderRadius.circular(100),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.video_library_outlined,
                      color: Colors.white, size: 16),
                  SizedBox(width: 6),
                  Text(
                    '사고 영상 선택',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDivider() {
    return Container(height: 0.5, color: AppTheme.divider);
  }

  // ── 하단 버튼 (알약형) ───────────────────────────────────
  Widget _buildBottomButton() {
    final videoState = ref.watch(blackboxVideoProvider);
    final isVideoStep = _currentStep == _steps.length - 1;
    final analysisReady = _caseId != null &&
        _caseId == _effectiveCaseId &&
        videoState.caseId == _caseId &&
        videoState.status == VideoStatus.ready &&
        videoState.localPath != null;
    final enabled = !isVideoStep || analysisReady;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
      child: GestureDetector(
        onTap: enabled
            ? () async {
                if (_currentStep < _steps.length - 1) {
                  setState(() => _currentStep++);
                } else {
                  await _startAnalysis();
                }
              }
            : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 18),
          decoration: BoxDecoration(
            color: enabled ? AppTheme.pointWhite : AppTheme.divider,
            borderRadius: BorderRadius.circular(100),
          ),
          child: Center(
            child: Text(
              _currentStep < _steps.length - 1
                  ? '다음 단계'
                  : _caseIsDemo
                      ? '주차장 모델로 분석'
                      : 'AI 과실 분석 시작',
              style: TextStyle(
                color: enabled ? Colors.black : AppTheme.textHint,
                fontSize: 16,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 기능 메서드 ──────────────────────────────────────────
  Future<void> _openVideoPicker() async {
    final selected = await showAccidentCasePicker(
      context,
      currentCaseId: _effectiveCaseId,
    );
    if (!mounted || selected == null) return;
    if (selected == _effectiveCaseId) {
      // 지금 보고 있는 사고를 다시 고르면 영상만 다시 불러온다.
      await _initializeCase();
      return;
    }
    context.pushReplacementNamed(
      'first-response',
      extra: {
        'case_id': selected,
        'initial_video_step': true,
      },
    );
  }

  Future<void> _takePhoto() async {
    final principal = authenticatedPrincipal(ref.read(authProvider));
    final generation = LocalAppFiles.accountCleanupGeneration;
    bool current() =>
        mounted &&
        principal != null &&
        principal == authenticatedPrincipal(ref.read(authProvider)) &&
        generation == LocalAppFiles.accountCleanupGeneration;
    final caseId = await _guardedCase();
    if (caseId == null || !current()) return;
    final photo = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (photo == null) return;
    if (!current()) {
      await _deleteUploadedPickerFile(photo.path);
      return;
    }
    final mime =
        photo.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    try {
      final cached = await cacheLocalCasePhoto(
        caseId: caseId,
        sourcePath: photo.path,
        mime: mime,
      );
      await _deleteUploadedPickerFile(photo.path);
      if (!current()) {
        if (await cached.exists()) await cached.delete();
        return;
      }
      final uploaded = await _uploadEvidence(
        caseId: caseId,
        path: cached.path,
        kind: EvidenceKind.photo,
        mime: mime,
        onComplete: () => _photoCount++,
      );
      if (uploaded && await cached.exists()) await cached.delete();
    } catch (error) {
      if (current()) _showMessage(error.toString());
    }
  }

  Future<void> _takeAdditionalVideo() async {
    final caseId = await _guardedCase();
    if (caseId == null) return;
    final video = await _picker.pickVideo(source: ImageSource.camera);
    if (video == null || !mounted) return;
    final lower = video.path.toLowerCase();
    final mime = lower.endsWith('.mov') ? 'video/quicktime' : 'video/mp4';
    await _uploadEvidence(
      caseId: caseId,
      path: video.path,
      kind: EvidenceKind.additionalVideo,
      mime: mime,
      onComplete: () {
        _videoCount++;
        _deleteUploadedPickerFile(video.path);
      },
    );
  }

  Future<void> _confirmPhoneCall({
    required String label,
    required String number,
  }) async {
    if (number.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('마이페이지에서 보험사 전화번호를 먼저 등록해 주세요.'),
            backgroundColor: AppTheme.surfaceDark,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('$number에 전화할까요?'),
        content: Text('$label 연결은 확인 후 전화 앱에서 진행됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('전화 걸기'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _callPhone(number);
  }

  Future<void> _callPhone(String number) async {
    final cleanNumber = number.replaceAll('-', '').replaceAll(' ', '');
    final uri = Uri(scheme: 'tel', path: cleanNumber);
    try {
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) _showPhoneFailure(number);
    } catch (_) {
      if (mounted) _showPhoneFailure(number);
    }
  }

  void _showPhoneFailure(String number) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '전화 앱을 열 수 없습니다. ($number)\n시뮬레이터에서는 전화를 걸 수 없습니다.',
        ),
        backgroundColor: AppTheme.surfaceDark,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  Future<void> _startAnalysis() async {
    final caseId = await _guardedCase();
    if (!mounted || caseId == null || caseId != _caseId) return;
    context.goNamed('analysis', extra: caseId);
  }

  Future<String?> _guardedCase() async {
    try {
      return await _requireOwnedCase();
    } catch (error) {
      if (mounted) _showMessage(error.toString());
      return null;
    }
  }

  Future<bool> _uploadEvidence({
    required String caseId,
    required String path,
    required EvidenceKind kind,
    required String mime,
    VoidCallback? onComplete,
  }) async {
    if (!mounted || _uploadingEvidence) return false;
    final principal = authenticatedPrincipal(ref.read(authProvider));
    final generation = LocalAppFiles.accountCleanupGeneration;
    bool current() =>
        mounted &&
        principal != null &&
        principal == authenticatedPrincipal(ref.read(authProvider)) &&
        generation == LocalAppFiles.accountCleanupGeneration;
    setState(() => _uploadingEvidence = true);
    try {
      final confirmed = await _requireOwnedCase();
      if (!current()) return false;
      if (confirmed != caseId) {
        throw const InvalidBackendCaseException('사고 사건이 변경되었습니다.');
      }
      await ref.read(backendEvidenceServiceProvider).uploadEvidence(
            caseId: confirmed,
            path: path,
            kind: kind,
            mime: mime,
          );
      if (!current() || _caseId != confirmed) return false;
      setState(() => onComplete?.call());
      _showMessage('증거 파일이 사건에 안전하게 저장되었습니다.');
      return true;
    } catch (error) {
      if (current()) _showMessage(error.toString());
      return false;
    } finally {
      if (mounted) setState(() => _uploadingEvidence = false);
    }
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

  Future<void> _deleteUploadedPickerFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final temporary = await getTemporaryDirectory();
      final root = await temporary.resolveSymbolicLinks();
      final resolved = await file.resolveSymbolicLinks();
      if (resolved.startsWith('$root${Platform.pathSeparator}')) {
        await file.delete();
      }
    } on FileSystemException {
      // The upload is already confirmed; cache cleanup can be retried by the OS.
    }
  }
}

class _Step {
  final IconData icon;
  final String title;
  final String subtitle;
  final String desc;
  const _Step({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.desc,
  });
}
