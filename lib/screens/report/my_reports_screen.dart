// lib/screens/report/my_reports_screen.dart
// 과실 분석 기록 - 서버에 저장된 사고별 분석 결과 목록
//
// 사고를 누르면 아래로 펼쳐지며 최신 분석 요약을 보여주고,
// 그 아래 '분석 리포트.pdf'를 누르면 분석 리포트 화면으로 들어간다.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../services/auth_service.dart';
import '../../services/case_service.dart';
import '../../services/model_analysis_service.dart';
import '../../utils/theme.dart';

class MyReportsScreen extends ConsumerStatefulWidget {
  const MyReportsScreen({super.key, this.initialCaseId});

  final String? initialCaseId;

  @override
  ConsumerState<MyReportsScreen> createState() => _MyReportsScreenState();
}

class _MyReportsScreenState extends ConsumerState<MyReportsScreen> {
  List<BackendCase> _cases = [];
  final Map<String, List<BackendReport>> _cloudReports = {};
  final Map<String, String?> _reportCursors = {};
  final Set<String> _loadingReportCases = {};
  String? _caseCursor;
  bool _loadingCases = true;
  String? _cloudError;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    ref.listenManual<String?>(authProvider.select(authenticatedPrincipal),
        (previous, next) {
      if (previous == next) return;
      setState(() {
        ++_generation;
        _cases = [];
        _cloudReports.clear();
        _reportCursors.clear();
        _loadingReportCases.clear();
        _caseCursor = null;
        _cloudError = null;
      });
      _loadCases(reset: true);
    });
    _loadCases(reset: true);
  }

  // ── 데이터 ───────────────────────────────────────────────
  Future<void> _loadCases({required bool reset}) async {
    if (_loadingCases && !reset) return;
    final principal = authenticatedPrincipal(ref.read(authProvider));
    if (reset) ++_generation;
    final generation = _generation;
    setState(() {
      _loadingCases = principal != null;
      _cloudError = null;
      if (reset) {
        _cases = [];
        _caseCursor = null;
        _cloudReports.clear();
        _reportCursors.clear();
        _loadingReportCases.clear();
      }
    });
    if (principal == null) return;
    try {
      final page = await ref.read(caseServiceProvider).listCases(
            cursor: reset ? null : _caseCursor,
            hasReports: true,
          );
      if (!_isCurrent(generation, principal)) return;
      setState(() {
        _cases = [..._cases, ...page.items];
        _caseCursor = page.nextCursor;
        _loadingCases = false;
      });
      final initialCase = widget.initialCaseId == null
          ? null
          : page.items
              .where((item) => item.id == widget.initialCaseId)
              .firstOrNull;
      if (initialCase != null) _loadCloudReports(initialCase);
    } catch (error) {
      if (!_isCurrent(generation, principal)) return;
      setState(() {
        _cloudError = error.toString();
        _loadingCases = false;
      });
    }
  }

  Future<void> _loadCloudReports(BackendCase backendCase,
      {bool more = false}) async {
    if (_loadingReportCases.contains(backendCase.id)) return;
    final generation = _generation;
    final principal = authenticatedPrincipal(ref.read(authProvider));
    if (principal == null) return;
    setState(() => _loadingReportCases.add(backendCase.id));
    try {
      final page = await ref.read(caseServiceProvider).listReports(
            backendCase.id,
            cursor: more ? _reportCursors[backendCase.id] : null,
          );
      if (!_isCurrent(generation, principal)) return;
      setState(() {
        final merged = [
          if (more) ...?_cloudReports[backendCase.id],
          ...page.items,
        ]..sort((a, b) => b.version.compareTo(a.version)); // 최신 버전 먼저
        _cloudReports[backendCase.id] = merged;
        _reportCursors[backendCase.id] = page.nextCursor;
      });
    } catch (error) {
      if (_isCurrent(generation, principal)) _showMessage(error.toString());
    } finally {
      if (_isCurrent(generation, principal)) {
        setState(() => _loadingReportCases.remove(backendCase.id));
      }
    }
  }

  Future<void> _deleteCloudCase(BackendCase backendCase) async {
    final principal = authenticatedPrincipal(ref.read(authProvider));
    final generation = _generation;
    if (principal == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: const Text('분석 기록 삭제',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text(
          '이 사고의 분석 결과와 리포트만 삭제합니다. 사고 영상·사진·GPS와 사건 정보는 유지됩니다.',
          style: TextStyle(color: AppTheme.textSub, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소', style: TextStyle(color: AppTheme.textSub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('삭제 요청', style: TextStyle(color: AppTheme.errorRed)),
          ),
        ],
      ),
    );
    if (ok != true || !_isCurrent(generation, principal)) return;
    try {
      await ref.read(caseServiceProvider).deleteReports(backendCase.id);
    } catch (error) {
      if (_isCurrent(generation, principal)) _showMessage(error.toString());
      return;
    }
    if (_isPrincipalCurrent(principal)) {
      setState(() {
        ++_generation;
        _cases.removeWhere((item) => item.id == backendCase.id);
        _cloudReports.remove(backendCase.id);
        _reportCursors.remove(backendCase.id);
        _loadingReportCases.clear();
        _loadingCases = false;
      });
    }
    if (_isPrincipalCurrent(principal)) {
      _showMessage('분석 기록을 삭제했습니다. 사고 영상은 유지됩니다.');
    }
  }

  void _openReport(BackendCase backendCase, BackendReport report) {
    context.push('/analysis', extra: {
      'case_id': backendCase.id,
      'report_id': report.id,
    });
  }

  bool _isPrincipalCurrent(String? principal) =>
      mounted &&
      principal != null &&
      authenticatedPrincipal(ref.read(authProvider)) == principal;

  bool _isCurrent(int generation, String? principal) =>
      generation == _generation && _isPrincipalCurrent(principal);

  ModelAnalysisReport? _parseSummary(BackendReport report) {
    try {
      return ModelAnalysisReport.fromReport({
        'id': report.id,
        'case_id': report.caseId,
        'version': report.version,
        'text': report.text,
        'created_at': report.createdAt.toIso8601String(),
        'analysis': report.analysis,
      }, expectedCaseId: report.caseId);
    } catch (_) {
      return null;
    }
  }

  String _formatDate(DateTime value) =>
      DateFormat('yyyy.MM.dd HH:mm').format(value.toLocal());

  // ── 화면 ─────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgBlack,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            Expanded(child: _buildCaseList()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => context.canPop() ? context.pop() : context.go('/'),
            child: const Icon(Icons.arrow_back_ios_new_rounded,
                size: 20, color: Colors.white),
          ),
          const SizedBox(width: 16),
          const Text(
            '과실 분석 기록',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w400,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => _loadCases(reset: true),
            child: const Icon(Icons.refresh_rounded,
                size: 20, color: AppTheme.textSub),
          ),
        ],
      ),
    );
  }

  Widget _buildCaseList() {
    if (_loadingCases && _cases.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
      );
    }
    if (_cloudError != null && _cases.isEmpty) {
      return _buildMessage(_cloudError!, retry: true);
    }
    if (_cases.isEmpty) {
      return _buildMessage('저장된 과실 분석 기록이 없습니다.');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: _cases.length + (_caseCursor != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _cases.length) {
          return TextButton.icon(
            onPressed: _loadingCases ? null : () => _loadCases(reset: false),
            icon: _loadingCases
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.expand_more),
            label: const Text('더 불러오기'),
          );
        }
        return _buildCaseTile(_cases[index]);
      },
    );
  }

  Widget _buildCaseTile(BackendCase backendCase) {
    final reports = _cloudReports[backendCase.id];
    final loading = _loadingReportCases.contains(backendCase.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        border: Border.all(color: const Color(0xFF2A2A2E)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Material(
        color: Colors.transparent,
        child: Theme(
          // ExpansionTile 기본 구분선 제거
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: ValueKey('$_generation:${backendCase.id}'),
            initiallyExpanded: backendCase.id == widget.initialCaseId,
            tilePadding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            iconColor: Colors.white,
            collapsedIconColor: AppTheme.textHint,
            onExpansionChanged: (expanded) {
              if (expanded && reports == null) _loadCloudReports(backendCase);
            },
            leading:
                const Icon(Icons.description_outlined, color: Colors.white),
            title: Text(
              backendCase.title.isEmpty ? '사고 분석' : backendCase.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: Text(
              _formatDate(backendCase.createdAt),
              style: const TextStyle(color: AppTheme.textHint, fontSize: 11),
            ),
            children: [
              if (loading && reports == null)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (reports == null || reports.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('아직 분석 결과가 없습니다.',
                      style: TextStyle(color: AppTheme.textHint, fontSize: 12)),
                )
              else ...[
                _buildSummary(backendCase, reports.first),
                const SizedBox(height: 12),
                ...reports.map((report) => _buildPdfRow(
                      backendCase,
                      report,
                      showVersion: reports.length > 1,
                    )),
              ],
              if (_reportCursors[backendCase.id] != null)
                TextButton(
                  onPressed: loading
                      ? null
                      : () => _loadCloudReports(backendCase, more: true),
                  child: const Text('이전 리포트 더 불러오기'),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _deleteCloudCase(backendCase),
                  icon: const Icon(Icons.delete_outline,
                      size: 16, color: AppTheme.textHint),
                  label: const Text('기록 삭제',
                      style: TextStyle(color: AppTheme.textHint, fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 분석 요약본 ──────────────────────────────────────────
  Widget _buildSummary(BackendCase backendCase, BackendReport report) {
    final summary = _parseSummary(report);
    final weather = summary?.currentWeather;
    final hasGps = backendCase.lat != null && backendCase.lon != null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('분석 요약',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          if (summary != null && summary.hasRates)
            Row(
              children: [
                Expanded(child: _rate('우리 과실', summary.rateB!)),
                Container(width: 0.5, height: 36, color: AppTheme.divider),
                Expanded(child: _rate('상대 과실', summary.rateA!)),
              ],
            )
          else
            _row('과실비율', '확인할 수 없음'),
          const SizedBox(height: 8),
          if (hasGps)
            _row('위치',
                '${backendCase.lat!.toStringAsFixed(5)}, ${backendCase.lon!.toStringAsFixed(5)}'),
          if (weather != null)
            _row('기상',
                '${weather.condition} · ${weather.temperatureC.toStringAsFixed(1)}°C'),
          if (summary?.speedDemo != null)
            _row('참고 속도', '${summary!.speedDemo!.valueKmh} km/h'),
          _row('법령·판례', summary?.lawAvailable == true ? '근거 포함' : '근거 없음'),
          _row('분석일', _formatDate(report.createdAt)),
          if (report.text.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              report.text.trim(),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppTheme.textSub, fontSize: 12, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _rate(String label, int value) {
    return Column(
      children: [
        Text(label,
            style: const TextStyle(color: AppTheme.textHint, fontSize: 11)),
        const SizedBox(height: 4),
        Text('$value%',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w300)),
      ],
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label,
                style: const TextStyle(color: AppTheme.textHint, fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ── 분석 리포트.pdf ──────────────────────────────────────
  Widget _buildPdfRow(
    BackendCase backendCase,
    BackendReport report, {
    required bool showVersion,
  }) {
    final name = showVersion ? '분석 리포트_v${report.version}.pdf' : '분석 리포트.pdf';
    return GestureDetector(
      onTap: () => _openReport(backendCase, report),
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF3A3A3E)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.picture_as_pdf_outlined,
                color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(_formatDate(report.createdAt),
                      style: const TextStyle(
                          color: AppTheme.textHint, fontSize: 11)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppTheme.textHint),
          ],
        ),
      ),
    );
  }

  Widget _buildMessage(String message, {bool retry = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.description_outlined,
                size: 48, color: AppTheme.textHint),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textHint)),
            if (retry)
              TextButton(
                onPressed: () => _loadCases(reset: true),
                child: const Text('다시 시도'),
              ),
          ],
        ),
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
