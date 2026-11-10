import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/accident_type_catalog.dart';
import '../../services/auth_service.dart';
import '../../services/blackbox_video_service.dart';
import '../../services/case_service.dart';
import '../../services/consent_service.dart';
import '../../services/device_service.dart';
import '../../services/local_files.dart';
import '../../services/map_service.dart';
import '../../services/model_analysis_service.dart';
import '../../services/pdf_report_service.dart';
import '../../utils/theme.dart';
import '../../widgets/analysis_clip_card.dart';
import '../../widgets/law_result_panel.dart';
import '../../widgets/road_question_widget.dart';

enum AnalysisPhase { resolving, ready }

class AnalysisScreen extends ConsumerStatefulWidget {
  const AnalysisScreen({
    super.key,
    required this.accidentId,
    this.analysisService,
    this.initialJobId,
    this.initialReportId,
    this.initialError,
  });

  final String accidentId;
  final ModelAnalysisService? analysisService;
  final String? initialJobId;
  final String? initialReportId;
  final String? initialError;

  @override
  ConsumerState<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends ConsumerState<AnalysisScreen> {
  late final ModelAnalysisService _analysisService;
  final LatestRequestTracker _requestTracker = LatestRequestTracker();

  AnalysisPhase _phase = AnalysisPhase.resolving;
  ModelAnalysisReport? _report;
  String? _caseId;
  bool _caseIsDemo = false;
  int? _lockedRoadPlace;
  String? _errorMessage;
  int? _selectedPlace;
  String? _selectedAction;
  String? _automaticRoadStatus;
  bool _roadWasUserSelected = false;
  bool _isAnalyzing = false;
  bool _reportIsPrevious = false;
  bool _isExportingPdf = false;
  bool _extrasExpanded = false;
  int _roadRevision = 0;
  // 시간 초과됐지만 서버에서 계속 진행 중일 수 있는 분석 작업 ID
  String? _timedOutJobId;
  final _egoMovementController = TextEditingController();
  final _otherMovementController = TextEditingController();

  final Map<String, bool> _userFeedback = {
    '상대 깜빡이 미점등': false,
    '내 깜빡이 점등': false,
    '상대 신호위반': false,
    '상대 과속': false,
    '어린이보호구역': false,
  };

  // 주행 환경 (줄마다 하나만 선택, 모르면 비워 둠)
  static const _weatherOptions = ['맑음', '흐림', '비', '눈', '안개'];
  static const _surfaceOptions = ['마른 노면', '젖은 노면', '빙판·눈길'];
  static const _timeOptions = ['주간', '야간'];
  String? _weather;
  String? _surface;
  String? _timeOfDay;
  bool _envExpanded = false;

  /// "비 · 젖은 노면 · 야간" (아무것도 안 골랐으면 null)
  String? get _environmentSummary {
    final parts = [_weather, _surface, _timeOfDay].whereType<String>().toList();
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  void initState() {
    super.initState();
    _analysisService = widget.analysisService ??
        ModelAnalysisService(
          dio: Dio(BaseOptions(
            baseUrl: kApiBaseUrl,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
            headers: {'Content-Type': 'application/json'},
          )),
          accessToken: () => ref.read(authProvider.notifier).validAccessToken(),
        );
    _initialize();
  }

  @override
  void didUpdateWidget(covariant AnalysisScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accidentId == widget.accidentId &&
        oldWidget.initialJobId == widget.initialJobId &&
        oldWidget.initialReportId == widget.initialReportId &&
        oldWidget.initialError == widget.initialError) {
      return;
    }

    _requestTracker.begin();
    _phase = AnalysisPhase.resolving;
    _report = null;
    _caseId = null;
    _caseIsDemo = false;
    _lockedRoadPlace = null;
    _errorMessage = null;
    _selectedPlace = null;
    _selectedAction = null;
    _automaticRoadStatus = null;
    _roadWasUserSelected = false;
    _isAnalyzing = false;
    _reportIsPrevious = false;
    _isExportingPdf = false;
    _extrasExpanded = false;
    _roadRevision = 0;
    _timedOutJobId = null;
    _egoMovementController.clear();
    _otherMovementController.clear();
    _userFeedback.updateAll((_, __) => false);
    _weather = null;
    _surface = null;
    _timeOfDay = null;
    _envExpanded = false;
    _initialize();
  }

  @override
  void dispose() {
    _egoMovementController.dispose();
    _otherMovementController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final request = _requestTracker.begin();
    final accidentId = widget.accidentId;
    try {
      final directCase = ModelAnalysisService.isBackendCaseId(accidentId);
      final savedDevice = directCase
          ? (id: null, name: null)
          : await ref.read(deviceServiceProvider).savedDevice();
      if (!mounted || !_requestTracker.isLatest(request)) return;
      final selectedEvent =
          directCase ? null : ref.read(blackboxVideoProvider).event;
      final caseId = await _analysisService.resolveCaseId(
        accidentId: accidentId,
        registeredDeviceId: savedDevice.id,
        selectedHardwareEventId: selectedEvent?.eventId,
      );
      if (!mounted || !_requestTracker.isLatest(request)) return;
      final backendCase =
          await ref.read(caseServiceProvider).selectOwnedCase(caseId);
      if (!mounted || !_requestTracker.isLatest(request)) return;
      if (backendCase.id != caseId) {
        throw const InvalidBackendCaseException();
      }
      setState(() {
        _caseId = caseId;
        _caseIsDemo = backendCase.isDemo;
        _lockedRoadPlace =
            backendCase.fixedRoadPlace ?? (_caseIsDemo ? 5 : null);
        if (_lockedRoadPlace != null) {
          _selectedPlace = _lockedRoadPlace;
          _selectedAction = null;
        }
        _phase = AnalysisPhase.ready;
        _isAnalyzing =
            widget.initialJobId != null || widget.initialError == null;
        _errorMessage = _friendlyErrorMessage(widget.initialError);
      });

      if (widget.initialJobId == null && widget.initialError != null) return;

      final roadRevision = _roadRevision;
      final report = widget.initialJobId != null
          ? await _analysisService.loadJob(
              caseId,
              widget.initialJobId!,
              expectedReportId: widget.initialReportId,
            )
          : widget.initialReportId == null
              ? await _analysisService.requestAnalysis(
                  caseId: caseId,
                  place: _lockedRoadPlace,
                )
              : await _analysisService.loadReport(
                  caseId,
                  widget.initialReportId!,
                );
      if (!mounted || !_requestTracker.isLatest(request)) return;
      setState(() {
        _report = report;
        if (_roadRevision == roadRevision) _applyReportedRoad(report.road);
        _reportIsPrevious = false;
        _errorMessage = widget.initialJobId == null
            ? null
            : _friendlyErrorMessage(widget.initialError);
        _isAnalyzing = false;
      });
    } on Object catch (error) {
      if (!mounted || !_requestTracker.isLatest(request)) return;
      setState(() {
        _phase = AnalysisPhase.ready;
        _errorMessage = _displayError(error);
        _timedOutJobId =
            error is AnalysisJobTimeoutException ? error.jobId : null;
        _isAnalyzing = false;
      });
    }
  }

  /// 시간 초과된 같은 작업을 다시 조회한다. 새 분석을 요청하지 않는다.
  Future<void> _resumeTimedOutJob() async {
    final caseId = _caseId;
    final jobId = _timedOutJobId;
    if (caseId == null || jobId == null || _isAnalyzing) return;
    final request = _requestTracker.begin();
    final roadRevision = _roadRevision;
    setState(() {
      _isAnalyzing = true;
      _errorMessage = null;
    });
    try {
      final report = await _analysisService.loadJob(caseId, jobId);
      if (!mounted || !_requestTracker.isLatest(request)) return;
      setState(() {
        _report = report;
        if (_roadRevision == roadRevision) _applyReportedRoad(report.road);
        _reportIsPrevious = false;
        _timedOutJobId = null;
        _isAnalyzing = false;
      });
      _showMessage(report.hasRates ? '분석이 완료되었습니다.' : '분석 결과를 확인해 주세요.');
    } on Object catch (error) {
      if (!mounted || !_requestTracker.isLatest(request)) return;
      setState(() {
        _errorMessage = _displayError(error);
        // 여전히 대기 중이면 같은 작업 ID를 유지한다.
        _timedOutJobId =
            error is AnalysisJobTimeoutException ? error.jobId : null;
        _isAnalyzing = false;
      });
    }
  }

  String _displayError(Object error) {
    if (error is AnalysisJobTimeoutException) {
      return '분석이 아직 끝나지 않았습니다. 서버에서 분석이 계속 진행될 수 있으니 '
          '잠시 후 아래 버튼으로 결과를 다시 확인해 주세요.\n작업 ID: ${error.jobId}';
    }
    if (error is ModelAnalysisException) {
      return _friendlyErrorMessage(error.message) ?? error.message;
    }
    return '분석 정보를 불러오지 못했습니다. 네트워크 상태를 확인해 주세요.';
  }

  String? _friendlyErrorMessage(String? message) {
    if (message == null) return null;
    if (message == 'place_required' || message.contains('도로유형 선택이 필요')) {
      return '사용자께서 도로유형 선택 시 더욱 더 정확한 결과가 나옵니다.';
    }
    return message;
  }

  void _changeRoad(int place, String? action) {
    if (_isAnalyzing || (_lockedRoadPlace != null && place != _lockedRoadPlace))
      return;
    setState(() {
      _roadRevision++;
      _selectedPlace = place;
      _selectedAction = place == 1 || place == 6 ? action : null;
      _roadWasUserSelected = true;
      _reportIsPrevious = _report != null;
    });
  }

  ({Map<String, bool> facts, List<String> keywords}) _feedbackPayload() {
    final facts = <String, bool>{};
    final keywords = <String>[];
    for (final item in _userFeedback.entries.where((entry) => entry.value)) {
      switch (item.key) {
        case '상대 깜빡이 미점등':
          facts['opponent_lane_change'] = true;
          keywords.addAll(const ['진로변경', '방향지시등 불이행']);
        case '내 깜빡이 점등':
          keywords.add('방향지시등 점등');
        case '상대 신호위반':
          facts['opponent_signal_violation'] = true;
          keywords.add('신호위반');
        case '상대 과속':
          facts['opponent_speeding_suspected'] = true;
          keywords.add('과속');
        case '빗길·악천후':
          facts['bad_weather'] = true;
          keywords.add('빗길');
        case '야간':
          keywords.add('야간');
        case '어린이보호구역':
          facts['school_zone'] = true;
          keywords.add('어린이보호구역');
      }
    }
    // 주행 환경: 궂은 날씨·노면은 기존 bad_weather 정황으로, 나머지는 검색어로 보낸다
    void addKeyword(String word) {
      if (!keywords.contains(word)) keywords.add(word);
    }

    switch (_weather) {
      case '비':
        facts['bad_weather'] = true;
        addKeyword('빗길');
      case '눈':
        facts['bad_weather'] = true;
        addKeyword('눈길');
      case '안개':
        facts['bad_weather'] = true;
        addKeyword('안개');
    }
    switch (_surface) {
      case '젖은 노면':
        facts['bad_weather'] = true;
        addKeyword('빗길');
      case '빙판·눈길':
        facts['bad_weather'] = true;
        addKeyword('빙판');
    }
    if (_timeOfDay == '야간') addKeyword('야간');
    return (facts: facts, keywords: keywords);
  }

  Future<void> _reanalyze() async {
    final caseId = _caseId;
    final place = _selectedPlace;
    if (_isAnalyzing) return;
    if (caseId == null) {
      _showMessage('연결된 분석 케이스가 없어 재분석할 수 없습니다.');
      return;
    }
    if (place == null) {
      _showMessage('도로유형을 선택해 주세요.');
      return;
    }

    final request = _requestTracker.begin();
    final roadRevision = _roadRevision;
    final feedback = _feedbackPayload();
    setState(() {
      _isAnalyzing = true;
      _reportIsPrevious = _report != null;
      _errorMessage = null;
      _timedOutJobId = null;
    });
    try {
      final report = await _analysisService.requestAnalysis(
        caseId: caseId,
        place: place,
        otherAction: _selectedAction,
        facts: feedback.facts,
        keywords: feedback.keywords,
        movements: VehicleMovements(
          ego: _egoMovementController.text,
          other: _otherMovementController.text,
        ),
      );
      if (!mounted || !_requestTracker.isLatest(request)) return;
      setState(() {
        _report = report;
        if (_roadRevision == roadRevision) _applyReportedRoad(report.road);
        _reportIsPrevious = false;
        _isAnalyzing = false;
      });
      _showMessage(
          report.hasRates ? '실제 모델 재분석이 완료되었습니다.' : '재분석 결과를 확인해 주세요.');
    } on Object catch (error) {
      if (!mounted || !_requestTracker.isLatest(request)) return;
      setState(() {
        _errorMessage = _displayError(error);
        _timedOutJobId =
            error is AnalysisJobTimeoutException ? error.jobId : null;
        _isAnalyzing = false;
      });
    }
  }

  void _applyReportedRoad(CaseRoadSelection road) {
    // Historical reports cannot replace the server's fixed expert selection.
    _selectedPlace = _lockedRoadPlace ?? road.place;
    _selectedAction =
        _selectedPlace == 1 || _selectedPlace == 6 ? road.otherAction : null;
    _automaticRoadStatus = road.automaticStatus;
    _roadWasUserSelected = road.isUserSelected;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: AppTheme.surfaceDark,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _showAnalysisSummary(ModelAnalysisReport report) {
    final law = LawReportResult.fromAnalysis(report.analysis);
    return showModalBottomSheet<void>(
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
                        '분석 요약',
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
                _summaryRow(
                  '과실비율',
                  report.hasRates
                      ? '우리 과실 ${report.rateB}% · 상대 과실 ${report.rateA}%'
                      : '확인할 수 없음',
                ),
                _summaryRow(
                  '위치·도로',
                  _registeredLocationText(report) ?? '확인할 수 없음',
                ),
                _summaryRow('법령·판례', _lawSummaryText(law)),
                _summaryRow('분석일', _formatDate(report.createdAt)),
                const SizedBox(height: 8),
                const Text(
                  legalReferenceWarning,
                  style: TextStyle(
                    color: AppTheme.warningOrange,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _summaryRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(
                color: AppTheme.textHint,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _lawSummaryText(LawReportResult law) {
    if (law.status == 'unavailable') return '현재 결과를 사용할 수 없음';
    final count = law.references.length;
    if (law.status == 'incomplete') {
      return count == 0 ? '일부 결과만 확인됨' : '일부 결과 · 근거 $count건';
    }
    return count == 0 ? '검색된 근거 없음' : '확인된 법령·판례 근거 $count건';
  }

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${local.year}.${twoDigits(local.month)}.${twoDigits(local.day)}';
  }


  Future<void> _exportPdf() async {
    final report = _report;
    final caseId = _caseId;
    if (!_canExportPdf || report == null || caseId == null) {
      _showMessage(
        '현재 도로 입력으로 완료된 실제 모델 분석만 PDF로 저장할 수 있습니다.',
      );
      return;
    }
    if (_isExportingPdf) return;
    final auth = ref.read(authProvider.notifier);
    final owner = authenticatedPrincipal(ref.read(authProvider));
    final email = ref.read(authProvider).email;
    final session = auth.sessionGeneration;
    final cleanup = LocalAppFiles.accountCleanupGeneration;
    bool current() =>
        mounted &&
        owner != null &&
        auth.sessionGeneration == session &&
        authenticatedPrincipal(ref.read(authProvider)) == owner &&
        LocalAppFiles.accountCleanupGeneration == cleanup &&
        _caseId == caseId &&
        identical(_report, report) &&
        !_reportIsPrevious;
    if (owner == null || email == null || email.isEmpty) {
      _showMessage('PDF 저장에는 로그인 사용자 정보가 필요합니다.');
      return;
    }
    setState(() => _isExportingPdf = true);
    try {
      final data = await _buildReportData(report, caseId, isCurrent: current);
      if (!current()) return;
      if (!kIsWeb) {
        await PdfReportService.saveToLocal(
          data,
          ownerScope: LocalAppFiles.ownerScope(email),
        );
      }
      if (!current()) return;
      await PdfReportService.generateAndShare(data);
    } on Object catch (error) {
      if (current()) _showMessage('PDF 생성 오류: $error');
    } finally {
      if (mounted) setState(() => _isExportingPdf = false);
    }
  }

  // ── 정밀 분석 리포트 데이터 만들기 ─────────────────────────
  static const _otherActionLabels = <String, String>{
    'left': '좌회전 중',
    'right': '우회전 중',
    'u_turn': '유턴 중',
    'straight_other': '직진·그 밖의 움직임',
    'entering': '회전교차로로 들어오는 중',
    'circulating': '회전교차로 안을 도는 중',
    'lane_change': '회전교차로 안에서 차로를 바꾸는 중',
  };

  static const _fileKindLabels = <String, String>{
    'original_video': '원본 블랙박스 영상',
    'video': '추가 영상',
    'photo': '현장 사진',
    'image': '현장 사진',
  };

  Future<ReportData> _buildReportData(
    ModelAnalysisReport report,
    String caseId, {
    required bool Function() isCurrent,
  }) async {
    final analysis = report.analysis;
    final model = _asMap(analysis['model']);
    final prediction = _asMap(model?['prediction']);

    // 과실비율 확률 분포 (우리 차량 = 모델의 B 당사자)
    final ratioCandidates = <ReportRatioCandidate>[];
    final values = prediction?['ratio_values'];
    final probs = prediction?['ratio_probs'];
    if (values is List && probs is List && values.length == probs.length) {
      for (var i = 0; i < values.length; i++) {
        final v = values[i];
        final p = probs[i];
        if (v is num && p is num) {
          ratioCandidates
              .add(ReportRatioCandidate(ourPct: v.toInt(), prob: p.toDouble()));
        }
      }
    }

    // 사고 유형 후보
    // 유형 번호 → 설명 (assets/data/accident_types.json)
    final typeCatalog = await AccidentTypeCatalog.load();
    final typeCandidates = <ReportTypeCandidate>[];
    final topk = prediction?['type_topk'];
    if (topk is List) {
      for (final item in topk) {
        final m = _asMap(item);
        final code = m?['code'];
        final prob = m?['prob'];
        if (code is num && prob is num) {
          final info = typeCatalog[code.toInt()];
          final description = m?['description'];
          typeCandidates.add(ReportTypeCandidate(
            code: code.toInt(),
            prob: prob.toDouble(),
            description: info?.title ??
                (description is String && description.isNotEmpty
                    ? description
                    : null),
            detail: info?.detail,
            baseOurPct: info?.baseOurPct,
            baseOtherPct: info?.baseOtherPct,
          ));
        }
      }
    }

    // 분석 영상 구간 (원본 영상 기준 ms)
    int? clipStart, clipEnd, impactMs, frames;
    double? fps;
    final clip = _asMap(prediction?['clip']);
    final window = clip?['window_ms'];
    if (window is List &&
        window.length == 2 &&
        window[0] is num &&
        window[1] is num) {
      clipStart = (window[0] as num).toInt();
      clipEnd = (window[1] as num).toInt();
      final fpsValue = clip?['fps'];
      fps = fpsValue is num ? fpsValue.toDouble() : null;
      final framesValue = clip?['frames'];
      frames = framesValue is num ? framesValue.toInt() : null;
      final padStart = _asMap(clip?['padded_ms'])?['start'];
      final impactFrame = clip?['impact_frame_est'];
      if (impactFrame is num && fps != null && fps > 0) {
        final offset = padStart is num ? padStart.toInt() : 0;
        impactMs = clipStart - offset + (impactFrame / fps * 1000).round();
      }
    }
    final warnings = prediction?['warnings'] is List
        ? (prediction!['warnings'] as List).whereType<String>().toList()
        : const <String>[];

    // 위치·시각
    final automatic = _asMap(report.road.raw['automatic']);
    final gps = _asMap(automatic?['gps']);
    double? lat = gps?['lat'] is num ? (gps!['lat'] as num).toDouble() : null;
    double? lon = gps?['lon'] is num ? (gps!['lon'] as num).toDouble() : null;
    final videoState = ref.read(blackboxVideoProvider);
    final event = videoState.caseId == caseId ? videoState.event : null;
    lat ??= event?.lat;
    lon ??= event?.lon;
    final address = _nonEmptyText(automatic?['address']) ??
        _nonEmptyText(automatic?['road_name']);
    DateTime? incidentAt = event?.triggerUtc;

    Uint8List? mapImage;
    try {
      final map = await ref.read(mapServiceProvider).fetchCaseMap(caseId);
      if (map.status == AccidentMapStatus.ready) mapImage = map.imageBytes;
      incidentAt ??= map.capturedAt;
      lat ??= map.latitude;
      lon ??= map.longitude;
    } on Object {
      // 지도는 없어도 리포트를 만든다.
    }

    // 지도를 기다리는 사이 계정이 바뀌었으면 이전 사건 파일을 새 계정으로 요청하지 않는다
    if (!isCurrent()) throw StateError('PDF export superseded');

    // 초동 대처에서 찍은 현장 사진 (없거나 못 받아도 리포트는 만든다)
    var scenePhotos = <Uint8List>[];
    try {
      scenePhotos = await ref
          .read(backendEvidenceServiceProvider)
          .downloadScenePhotos(caseId);
    } on Object {
      scenePhotos = const [];
    }
    if (!isCurrent()) throw StateError('PDF export superseded');

    // 도로·상대 움직임
    final place = report.road.place;
    final placeLabel = place != null && place >= 0 && place < roadLabels.length
        ? roadLabels[place]
        : null;
    final action = report.road.otherAction;
    final actionLabel = action == null || action == 'unknown'
        ? null
        : _otherActionLabels[action];
    final autoNote = switch (report.road.automaticStatus) {
      'estimated' => 'GPS 기반 자동 추정값',
      'needs_confirmation' => '자동 판별: GPS만으로 확정하지 못함',
      'unavailable' => '자동 판별: 사용 불가 (도로 정보 조회 실패)',
      _ => null,
    };

    // 기상
    final weather = report.currentWeather;
    final weatherText = weather == null
        ? null
        : '${weather.condition} · ${_formatNumber(weather.temperatureC)}℃ · '
            '강수 ${_formatNumber(weather.precipitationMm)}mm';

    // 문처리 진술
    final statements = <ReportStatement>[];
    final rawStatements = analysis['user_statements'];
    if (rawStatements is List) {
      for (final item in rawStatements) {
        final m = _asMap(item);
        final text = _nonEmptyText(m?['text']);
        if (text == null) continue;
        final at = m?['created_at'];
        statements.add(ReportStatement(
          text: text,
          at: at is String ? DateTime.tryParse(at) : null,
        ));
      }
    }

    // 증거 파일 (원본 영상 고유값)
    final evidenceFiles = <ReportEvidenceFile>[];
    try {
      final files =
          await ref.read(backendEvidenceServiceProvider).listCaseFiles(caseId);
      for (final file in files) {
        final label = _fileKindLabels[file.kind];
        if (label == null) continue;
        evidenceFiles.add(ReportEvidenceFile(
          label: label,
          sha256: file.sha256,
          sizeBytes: file.size,
          receivedAt: file.createdAt,
        ));
      }
    } on Object {
      // 파일 목록을 못 받아도 리포트는 만든다.
    }
    if (!isCurrent()) throw StateError('PDF export superseded');

    // 법령·판례: 쟁점별로 묶고, 쟁점 안에서는 조문 → 판례 순서
    final law = LawReportResult.fromAnalysis(analysis);
    final grouped = <String, List<LawReference>>{};
    for (final reference in law.references) {
      grouped.putIfAbsent(reference.issueType, () => []).add(reference);
    }
    final issues = <ReportIssue>[];
    grouped.forEach((issueType, refs) {
      refs.sort((a, b) =>
          (a.kind == 'statute' ? 0 : 1).compareTo(b.kind == 'statute' ? 0 : 1));
      final label = law.issues
              .where((issue) => issue.issueType == issueType)
              .map((issue) => issue.label)
              .firstOrNull ??
          issueType;
      issues.add(ReportIssue(
        label: label,
        refs: refs
            .map((r) => ReportLawRef(
                  title: r.title,
                  isPrecedent: r.kind == 'precedent',
                  fromVideo: r.source == 'video',
                  text: r.excerpt,
                  url: r.url,
                ))
            .toList(),
      ));
    });
    final lawStatusNote = switch (law.status) {
      'incomplete' => '법령·판례 검색이 일부만 완료되어, 찾은 근거만 표시합니다.',
      'unavailable' => '이 분석에서는 법령·판례 검색 결과를 사용할 수 없습니다.',
      _ => null,
    };

    // 확인하지 못한 부분
    final unknowns = <String>[
      if (report.road.isUserSelected &&
          {'needs_confirmation', 'unavailable'}
              .contains(report.road.automaticStatus))
        '도로 정보 자동 판별을 확정하지 못해, 도로 형태는 사용자가 고른 값을 사용했습니다.',
      if (report.gpsIsAssumed) '사고 위치 GPS는 실측값이 아닌 추정값입니다.',
      if (lat == null || lon == null) '사고 위치 GPS 정보를 확인하지 못했습니다.',
      if (weather == null) '사고 당시 기상 정보를 확인하지 못했습니다.',
      if (action == 'unknown') '상대 차량 움직임은 "잘 모르겠음"으로 답해 판단에 반영하지 않았습니다.',
      '주행 속도는 측정값이 없어 판단에 쓰지 않았습니다.',
      if (law.status != 'complete') '법령·판례 근거 검색이 완전히 끝나지 않았습니다.',
      if (warnings.isNotEmpty) '모델이 영상 처리 중 경고를 남겼습니다: ${warnings.join(', ')}',
    ];

    // AI 설명: 실제 LLM이 한국어로 만든 경우에만
    final providers = _asMap(analysis['providers']);
    final text = report.text.trim();
    final aiSummary = providers?['llm'] == 'real' &&
            RegExp(r'[가-힣]').hasMatch(text) &&
            text.isNotEmpty
        ? text
        : null;

    final version = report.report['version'];
    return ReportData(
      accidentId: caseId,
      analyzedAt: report.createdAt,
      reportVersion: version is int ? version : null,
      isComplete: analysis['status'] == 'complete',
      rateOurPct: report.rateB!,
      rateOtherPct: report.rateA!,
      ratioCandidates: ratioCandidates,
      typeCandidates: typeCandidates,
      incidentAt: incidentAt,
      address: address,
      latitude: lat,
      longitude: lon,
      gpsEstimated: report.gpsIsAssumed,
      roadPlaceLabel: placeLabel,
      roadUserSelected: report.road.isUserSelected,
      roadAutoNote: autoNote,
      otherActionLabel: actionLabel,
      weatherText: weatherText,
      mapImage: mapImage,
      scenePhotos: scenePhotos,
      clipStartMs: clipStart,
      clipEndMs: clipEnd,
      impactMs: impactMs,
      clipFrames: frames,
      clipFps: fps,
      modelWarnings: warnings,
      checkedFacts: _userFeedback.entries
          .where((entry) => entry.value)
          .map((entry) => entry.key)
          .toList(),
      drivingEnvironment: _environmentSummary,
      egoMovement: _egoMovementController.text.trim(),
      otherMovement: _otherMovementController.text.trim(),
      statements: statements,
      evidenceFiles: evidenceFiles,
      lawKeywords: law.keywords,
      issues: issues,
      lawStatusNote: lawStatusNote,
      unknowns: unknowns,
      aiSummary: aiSummary,
    );
  }

  /// 분석에 사용된 영상 구간 카드 (모델이 구간 정보를 준 경우만)
  Widget? _clipCard(ModelAnalysisReport report) {
    final caseId = _caseId;
    if (caseId == null) return null;
    final prediction =
        _asMap(_asMap(report.analysis['model'])?['prediction']);
    final clip = _asMap(prediction?['clip']);
    final window = clip?['window_ms'];
    if (window is! List ||
        window.length != 2 ||
        window[0] is! num ||
        window[1] is! num) {
      return null;
    }
    final start = (window[0] as num).toInt();
    final end = (window[1] as num).toInt();
    if (end <= start) return null;
    int? impact;
    final fps = clip?['fps'];
    final impactFrame = clip?['impact_frame_est'];
    final padStart = _asMap(clip?['padded_ms'])?['start'];
    if (impactFrame is num && fps is num && fps > 0) {
      final offset = padStart is num ? padStart.toInt() : 0;
      impact = start - offset + (impactFrame / fps * 1000).round();
    }
    return AnalysisClipCard(
      key: ValueKey('clip-$caseId-$start-$end'),
      caseId: caseId,
      startMs: start,
      endMs: end,
      impactMs: impact,
    );
  }

  Map<String, dynamic>? _asMap(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;

  bool get _canExportPdf {
    final report = _report;
    return _phase == AnalysisPhase.ready &&
        !_isAnalyzing &&
        !_reportIsPrevious &&
        report != null &&
        report.hasRates &&
        _caseId == report.caseId;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgBlack,
      appBar: AppBar(
        leading: IconButton(
          tooltip: '뒤로',
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        ),
        title: const Text('과실 분석'),
        actions: [
          IconButton(
            tooltip: 'PDF 리포트 저장',
            onPressed: _isExportingPdf || !_canExportPdf ? null : _exportPdf,
            icon: _isExportingPdf
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share_rounded, size: 20),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _phase == AnalysisPhase.resolving
            ? const Center(child: CircularProgressIndicator())
            : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    final chipFontFamily = Theme.of(context).textTheme.labelLarge?.fontFamily;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildReport(),
          const SizedBox(height: 16),
          const Text(
            legalReferenceWarning,
            style: TextStyle(
              color: AppTheme.warningOrange,
              fontSize: 12,
              height: 1.45,
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            _statusBox(
              icon: _timedOutJobId != null
                  ? Icons.hourglass_top_rounded
                  : Icons.error_outline_rounded,
              text: _errorMessage!,
              color: _timedOutJobId != null
                  ? AppTheme.warningOrange
                  : AppTheme.errorRed,
            ),
          ],
          if (_timedOutJobId != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _isAnalyzing ? null : _resumeTimedOutJob,
                icon: const Icon(Icons.sync_rounded),
                label: const Text('진행 중인 분석 결과 다시 확인'),
              ),
            ),
          ],
          const SizedBox(height: 36),
          const Text('도로유형', style: AppTheme.label),
          const SizedBox(height: 6),
          Text(
            _roadStatusText(),
            style: const TextStyle(color: AppTheme.textHint, fontSize: 12),
          ),
          const SizedBox(height: 14),
          Theme(
            data: Theme.of(context).copyWith(
              chipTheme: Theme.of(context).chipTheme.copyWith(
                    backgroundColor: AppTheme.cardDark,
                    selectedColor: Colors.white,
                    disabledColor: AppTheme.cardDark,
                    labelStyle: TextStyle(
                      color: AppTheme.textSub,
                      fontFamily: chipFontFamily,
                    ),
                    secondaryLabelStyle: TextStyle(
                      color: Colors.black,
                      fontFamily: chipFontFamily,
                    ),
                    side: const BorderSide(color: AppTheme.divider),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
            ),
            child: RoadQuestionWidget(
              selectedPlace: _selectedPlace,
              selectedAction: _selectedAction,
              onChanged: _changeRoad,
              isBusy: _isAnalyzing || (_caseIsDemo && _lockedRoadPlace == 5),
              roadLocked: _lockedRoadPlace != null,
            ),
          ),
          const SizedBox(height: 32),
          const Text('사고 직전 차량 움직임 (선택)', style: AppTheme.label),
          const SizedBox(height: 6),
          const Text(
            '현재 모델은 도로유형과 구조화된 상대 차량 움직임 답변을 사용합니다. 내 차량·상대 차량 자유 설명은 설명 맥락이며 과실비율 변경을 보장하지 않습니다.',
            style: TextStyle(color: AppTheme.textHint, fontSize: 12),
          ),
          const SizedBox(height: 12),
          _movementField('내 차량', _egoMovementController),
          const SizedBox(height: 10),
          _movementField('상대 차량', _otherMovementController),
          const SizedBox(height: 32),
          const Text('주행 환경', style: AppTheme.label),
          const SizedBox(height: 12),
          _buildEnvironment(),
          const SizedBox(height: 32),
          const Text('영상에 안 나온 정황', style: AppTheme.label),
          const SizedBox(height: 12),
          _buildExtras(),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isAnalyzing ? null : _reanalyze,
              icon: _isAnalyzing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: Text(_isAnalyzing ? '모델 분석 중' : '입력 내용으로 다시 분석'),
            ),
          ),
          if (_report != null) ...[
            const SizedBox(height: 12),
            if (_isAnalyzing)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      context.canPop() ? context.pop() : context.go('/'),
                  icon: const Icon(Icons.arrow_back_rounded),
                  label: const Text('현재 결과로 계속하기'),
                ),
              )
            else ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _canExportPdf
                      ? () => context.pushNamed('my-reports', extra: _caseId)
                      : null,
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('리포트 작성'),
                ),
              ),
              if (!_canExportPdf) ...[
                const SizedBox(height: 6),
                const Text(
                  '완료된 분석 결과가 있을 때 리포트를 만들 수 있습니다.',
                  style: TextStyle(color: AppTheme.textHint, fontSize: 12),
                ),
              ],
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => context.go('/'),
                  icon: const Icon(Icons.home_outlined),
                  label: const Text('홈으로 돌아가기'),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  String _roadStatusText() {
    if (_caseIsDemo && _lockedRoadPlace == 5)
      return '시연 사고는 주차장 모델로 분석합니다. 도로유형은 주차장으로 고정됩니다.';
    if (_lockedRoadPlace case final place?)
      return '이 영상은 ${roadLabels[place]} 전용 모델로 고정됩니다.';
    if (_roadWasUserSelected) return '저장된 사용자 선택을 불러왔습니다.';
    return switch (_automaticRoadStatus) {
      'estimated' => 'GPS 기반 자동 추정값입니다. 필요하면 수정해 주세요.',
      'needs_confirmation' => 'GPS만으로 도로유형을 확정하지 못했습니다. 직접 선택해 주세요.',
      'unavailable' => '도로 자동 추정을 사용할 수 없습니다. 직접 선택해 주세요.',
      _ => '사고 당시 도로 형태를 선택해 주세요.',
    };
  }

  Widget _buildReport() {
    final report = _report;
    if (_isAnalyzing && report == null) {
      return _statusBox(
        icon: Icons.auto_awesome_rounded,
        text: '백엔드 실제 모델이 사고 영상을 분석하고 있습니다.',
        color: Colors.white,
      );
    }
    if (report == null) {
      return _statusBox(
        icon: Icons.info_outline_rounded,
        text: '표시할 모델 분석 결과가 없습니다. 도로유형을 선택해 재분석해 주세요.',
        color: AppTheme.textSub,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_reportIsPrevious) ...[
          _statusBox(
            icon: Icons.history_rounded,
            text: '이전 분석 결과',
            color: AppTheme.warningOrange,
          ),
          const SizedBox(height: 16),
        ],
        if (report.hasRates) ...[
          Row(
            children: [
              _rateSide('우리 과실', report.rateB!),
              Container(width: 1, height: 70, color: AppTheme.divider),
              _rateSide('상대 과실', report.rateA!),
            ],
          ),
          const SizedBox(height: 30),
        ] else
          _statusBox(
            icon: Icons.info_outline_rounded,
            text: _modelUnavailableText(report),
            color: AppTheme.warningOrange,
          ),
        const SizedBox(height: 24),
        if (_registeredGpsSummary(report) case final summary?) ...[
          _statusBox(
            icon: Icons.location_on_outlined,
            text: summary,
            color: AppTheme.textSub,
          ),
          const SizedBox(height: 24),
        ],
        if (_clipCard(report) case final clip?) ...[
          clip,
          const SizedBox(height: 24),
        ],
        LawResultPanel(analysis: report.analysis),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _showAnalysisSummary(report),
            icon: const Icon(Icons.summarize_outlined, size: 18),
            label: const Text('분석 요약 보기'),
          ),
        ),
      ],
    );
  }

  String _modelUnavailableText(ModelAnalysisReport report) {
    return switch (report.reason) {
      'place_required' => '사용자께서 도로유형 선택 시 더욱 더 정확한 결과가 나옵니다.',
      'no_original_video' => '원본 사고 영상이 없어 모델 분석을 실행할 수 없습니다.',
      'unsupported_input' => '모델이 지원하지 않는 영상 형식입니다.',
      'decode_failed' => '사고 영상을 해석하지 못했습니다.',
      'clip_too_short' => '분석할 사고 영상 구간이 너무 짧습니다.',
      _ => report.status == ModelReportStatus.incomplete
          ? '모델 분석에 필요한 입력이 아직 완전하지 않습니다.'
          : '모델 분석을 사용할 수 없습니다.',
    };
  }

  String? _registeredGpsSummary(ModelAnalysisReport report) {
    final automatic = report.road.raw['automatic'];
    if (automatic is! Map) return null;
    final gps = automatic['gps'];
    if (gps is! Map ||
        !_validCoordinate(gps['lat'], -90, 90) ||
        !_validCoordinate(gps['lon'], -180, 180)) {
      return null;
    }
    final address = _nonEmptyText(automatic['address']);
    final roadName = _nonEmptyText(automatic['road_name']);
    final location = address ?? roadName;
    final place = report.road.place;
    final topology = place == null ? null : roadLabels[place];
    if (address != null && roadName != null && topology != null) {
      return '등록된 GPS 위치는 $address이며, 도로명은 $roadName입니다. '
          '선택한 도로유형은 $topology입니다.';
    }
    if (address != null && roadName != null) {
      return '등록된 GPS 위치는 $address이며, 도로명은 $roadName입니다.';
    }
    if (location != null && topology != null) {
      return '등록된 GPS 위치는 $location이며, 선택한 도로유형은 $topology입니다.';
    }
    if (location != null) return '등록된 GPS 위치는 $location입니다.';
    if (topology != null) {
      return '등록된 GPS 위치 정보가 확인되었으며, 선택한 도로유형은 $topology입니다.';
    }
    return '등록된 GPS 위치 정보가 확인되었습니다.';
  }

  String? _registeredLocationText(ModelAnalysisReport report) {
    final automatic = report.road.raw['automatic'];
    if (automatic is! Map) return null;
    final gps = automatic['gps'];
    if (gps is! Map ||
        !_validCoordinate(gps['lat'], -90, 90) ||
        !_validCoordinate(gps['lon'], -180, 180)) {
      return null;
    }
    final values = <String>[
      if (_nonEmptyText(automatic['address']) case final address?) address,
      if (_nonEmptyText(automatic['road_name']) case final roadName?) roadName,
      if (report.road.place case final place?) roadLabels[place],
    ];
    return values.isEmpty ? '등록된 위치 정보' : values.join(' · ');
  }

  bool _validCoordinate(Object? value, num min, num max) =>
      value is num && value.isFinite && value >= min && value <= max;

  String? _nonEmptyText(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim();
  }


  String _formatNumber(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();

  Widget _rateSide(String label, int rate) {
    return Expanded(
      child: Column(
        children: [
          Text(label,
              style: const TextStyle(color: AppTheme.textSub, fontSize: 13)),
          const SizedBox(height: 8),
          Text(
            '$rate%',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 46,
              fontWeight: FontWeight.w200,
            ),
          ),
        ],
      ),
    );
  }

  Widget _movementField(
    String label,
    TextEditingController controller,
  ) {
    return TextField(
      controller: controller,
      enabled: !_isAnalyzing,
      onChanged: (_) => _markReportStale(),
      maxLength: 500,
      minLines: 1,
      maxLines: 3,
      decoration: InputDecoration(
        labelText: '$label (선택)',
        hintText: '$label 움직임을 간단히 적어주세요',
        border: const OutlineInputBorder(),
      ),
    );
  }

  void _markReportStale() {
    if (_report != null && !_reportIsPrevious) {
      setState(() => _reportIsPrevious = true);
    }
  }

  Widget _statusBox({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        border: Border.all(color: AppTheme.divider),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: AppTheme.textSub, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  /// 주행 환경: 접히는 칸 하나에 날씨·노면·시간대 선택 버튼
  Widget _buildEnvironment() {
    final summary = _environmentSummary;
    return Column(
      children: [
        InkWell(
          onTap: _isAnalyzing
              ? null
              : () => setState(() => _envExpanded = !_envExpanded),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppTheme.cardDark,
              border: Border.all(color: AppTheme.divider),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Expanded(child: Text(summary ?? '날씨·노면·시간대 선택')),
                Icon(_envExpanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded),
              ],
            ),
          ),
        ),
        if (_envExpanded) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: AppTheme.cardDark,
              border: Border.all(color: AppTheme.divider),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _envRow('날씨', _weatherOptions, _weather,
                    (v) => _weather = v),
                const SizedBox(height: 12),
                _envRow('노면', _surfaceOptions, _surface,
                    (v) => _surface = v),
                const SizedBox(height: 12),
                _envRow('시간대', _timeOptions, _timeOfDay,
                    (v) => _timeOfDay = v),
                const SizedBox(height: 12),
                const Text(
                  '모르면 비워 두세요. 선택한 내용은 법령·판례 검색과 리포트에 반영됩니다.',
                  style: TextStyle(color: AppTheme.textHint, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _envRow(
    String label,
    List<String> options,
    String? selected,
    void Function(String? value) assign,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(label,
                style: const TextStyle(color: AppTheme.textSub, fontSize: 13)),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: options.map((option) {
              final isSelected = option == selected;
              return ChoiceChip(
                label: Text(option),
                selected: isSelected,
                showCheckmark: false,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.black : Colors.white,
                  fontSize: 13,
                ),
                selectedColor: AppTheme.pointWhite,
                backgroundColor: AppTheme.cardDark,
                side: BorderSide(
                  color: isSelected
                      ? AppTheme.pointWhite
                      : const Color(0xFF3A3A3E),
                ),
                shape: const StadiumBorder(),
                onSelected: _isAnalyzing
                    ? null
                    // 같은 걸 다시 누르면 선택이 풀린다
                    : (_) => setState(() {
                          assign(isSelected ? null : option);
                          _reportIsPrevious = _report != null;
                        }),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildExtras() {
    final count = _userFeedback.values.where((value) => value).length;
    return Column(
      children: [
        InkWell(
          onTap: _isAnalyzing
              ? null
              : () => setState(() => _extrasExpanded = !_extrasExpanded),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppTheme.cardDark,
              border: Border.all(color: AppTheme.divider),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(count == 0 ? '추가 정황 선택' : '$count개 선택됨'),
                ),
                Icon(_extrasExpanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded),
              ],
            ),
          ),
        ),
        if (_extrasExpanded) ...[
          const SizedBox(height: 8),
          Material(
            color: AppTheme.cardDark,
            shape: RoundedRectangleBorder(
              side: const BorderSide(color: AppTheme.divider),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              children: _userFeedback.entries.map((entry) {
                return CheckboxListTile(
                  dense: true,
                  value: entry.value,
                  title: Text(entry.key),
                  onChanged: _isAnalyzing
                      ? null
                      : (value) => setState(() {
                            _userFeedback[entry.key] = value ?? false;
                            _reportIsPrevious = _report != null;
                          }),
                );
              }).toList(),
            ),
          ),
        ],
      ],
    );
  }
}
