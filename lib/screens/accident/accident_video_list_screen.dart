// lib/screens/accident/accident_video_list_screen.dart
//
// 사고 영상 기록
//   - AccidentVideoListScreen : 내 계정의 사고 사건(블랙박스 업로드) 목록
//   - AccidentVideoViewScreen : 선택한 사건의 영상 재생 + 사고 위치 지도
//
// 목록에서 영상을 눌러도 바로 분석으로 넘어가지 않고, 먼저 영상만 확인한다.
// 보기 화면 아래의 '이 영상으로 AI 과실 분석' 버튼을 누르면 바로 분석 화면으로 간다.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/blackbox_video_service.dart';
import '../../services/case_service.dart';
import '../../services/auth_service.dart';
import '../../services/local_files.dart';
import '../../utils/theme.dart';
import '../../widgets/accident_location_map.dart';
import '../../widgets/blackbox_video_player_widget.dart';

String _formatDate(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}.${two(local.month)}.${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

Widget _header(BuildContext context, String title, {VoidCallback? onRefresh}) {
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
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w400,
          ),
        ),
        const Spacer(),
        if (onRefresh != null)
          GestureDetector(
            onTap: onRefresh,
            child: const Icon(Icons.refresh_rounded,
                size: 20, color: AppTheme.textSub),
          ),
      ],
    ),
  );
}

// ══════════════════════════════════════════════════════════
// 사고 영상 목록
// ══════════════════════════════════════════════════════════
class AccidentVideoListScreen extends ConsumerStatefulWidget {
  const AccidentVideoListScreen({super.key});

  @override
  ConsumerState<AccidentVideoListScreen> createState() =>
      _AccidentVideoListScreenState();
}

class _AccidentVideoListScreenState
    extends ConsumerState<AccidentVideoListScreen> with WidgetsBindingObserver {
  final List<BackendCase> _cases = [];
  String? _nextCursor;
  bool _loading = true;
  bool _loadingMore = false;
  bool _silentlyRefreshing = false;
  String? _error;
  Timer? _refreshTimer;
  final Set<String> _deletedIds = {};
  final Set<String> _deletingIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load(reset: true);
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshLatest(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshLatest();
  }

  Future<void> _load({required bool reset}) async {
    if (_silentlyRefreshing) return;
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      if (_nextCursor == null || _loadingMore) return;
      setState(() => _loadingMore = true);
    }
    try {
      final page = await ref
          .read(caseServiceProvider)
          .listCases(limit: 20, cursor: reset ? null : _nextCursor);
      if (!mounted) return;
      setState(() {
        if (reset) _cases.clear();
        _cases
            .addAll(page.items.where((item) => !_deletedIds.contains(item.id)));
        _nextCursor = page.nextCursor;
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _refreshLatest() async {
    if (!mounted ||
        ModalRoute.of(context)?.isCurrent != true ||
        _loading ||
        _loadingMore ||
        _silentlyRefreshing) {
      return;
    }
    if (_cases.isEmpty) {
      await _load(reset: true);
      return;
    }

    _silentlyRefreshing = true;
    try {
      final page = await ref.read(caseServiceProvider).listCases(limit: 20);
      if (!mounted) return;

      final knownIds = _cases.map((item) => item.id).toSet();
      final newCases = page.items
          .where((item) => !knownIds.contains(item.id))
          .toList(growable: false);
      final refreshedIds = page.items.map((item) => item.id).toSet();
      final olderCases = _cases
          .where((item) => !refreshedIds.contains(item.id))
          .toList(growable: false);

      setState(() {
        _cases
          ..clear()
          ..addAll(page.items.where((item) => !_deletedIds.contains(item.id)))
          ..addAll(olderCases.where((item) => !_deletedIds.contains(item.id)));
        _nextCursor = page.nextCursor;
        _error = null;
      });
      if (newCases.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text('새 사고 영상 ${newCases.length}건이 도착했습니다.'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ));
      }
    } catch (_) {
      // Keep the last successful list visible; the next poll retries.
    } finally {
      _silentlyRefreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgBlack,
      body: SafeArea(
        child: Column(
          children: [
            _header(context, '사고 영상 기록', onRefresh: () => _load(reset: true)),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
      );
    }
    if (_error != null) {
      return _message(
        icon: Icons.error_outline_rounded,
        title: '사고 기록을 불러올 수 없습니다',
        subtitle: _error!,
        showRetry: true,
      );
    }
    if (_cases.isEmpty) {
      return _message(
        icon: Icons.video_library_outlined,
        title: '기록된 사고 영상이 없습니다',
        subtitle: '블랙박스에서 사고 영상이 업로드되면 여기에 표시됩니다',
      );
    }
    return RefreshIndicator(
      color: Colors.white,
      backgroundColor: AppTheme.surfaceDark,
      onRefresh: () => _load(reset: true),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        itemCount: _cases.length + (_nextCursor != null ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == _cases.length) return _buildMoreButton();
          return _buildCaseTile(_cases[index], isLatest: index == 0);
        },
      ),
    );
  }

  Widget _buildCaseTile(BackendCase item, {required bool isLatest}) {
    final hasGps = item.lat != null && item.lon != null;
    return GestureDetector(
      onTap: () => context.pushNamed('accident-video', extra: item.id),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.cardDark,
          border: Border.all(color: const Color(0xFF2A2A2E)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppTheme.surfaceDark,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.title.isEmpty ? '사고 영상' : item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                      if (isLatest) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: AppTheme.successGreen),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '최신',
                            style: TextStyle(
                              color: AppTheme.successGreen,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _formatDate(item.createdAt),
                    style: const TextStyle(
                      color: AppTheme.textSub,
                      fontSize: 12,
                    ),
                  ),
                  if (hasGps) ...[
                    const SizedBox(height: 2),
                    Text(
                      '${item.lat!.toStringAsFixed(5)}, '
                      '${item.lon!.toStringAsFixed(5)}',
                      style: const TextStyle(
                        color: AppTheme.textHint,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: '영상과 사건 삭제',
              onPressed: _deletingIds.contains(item.id)
                  ? null
                  : () => _deleteVideo(item),
              icon: const Icon(Icons.delete_outline, color: AppTheme.textSub),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppTheme.textHint),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteVideo(BackendCase item) async {
    final principal = authenticatedPrincipal(ref.read(authProvider));
    if (principal == null || _deletingIds.contains(item.id)) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('영상과 사건 삭제'),
              content: const Text(
                  '이 사고의 영상·사진·GPS·분석 리포트를 함께 삭제합니다. 되돌릴 수 없습니다. 리포트만 지우려면 분석 기록에서 삭제해 주세요.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('취소')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('영상과 사건 삭제')),
              ],
            ));
    bool current() =>
        mounted && principal == authenticatedPrincipal(ref.read(authProvider));
    if (confirmed != true || !current()) return;
    setState(() => _deletingIds.add(item.id));
    try {
      await ref.read(caseServiceProvider).deleteCase(item.id);
      if (!current()) return;
      ref.read(blackboxVideoProvider.notifier).resetForCase(item.id);
      setState(() {
        _deletedIds.add(item.id);
        _cases.removeWhere((row) => row.id == item.id);
      });
      try {
        await cleanupLocalCaseFiles(item.id);
      } catch (_) {/* Server deletion already accepted. */}
      if (current())
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('영상과 사건 삭제를 요청했습니다.')));
    } catch (error) {
      if (current())
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (current()) setState(() => _deletingIds.remove(item.id));
    }
  }

  Widget _buildMoreButton() {
    return GestureDetector(
      onTap: _loadingMore ? null : () => _load(reset: false),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        alignment: Alignment.center,
        child: _loadingMore
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Text(
                '더 보기',
                style: TextStyle(color: AppTheme.textSub, fontSize: 13),
              ),
      ),
    );
  }

  Widget _message({
    required IconData icon,
    required String title,
    required String subtitle,
    bool showRetry = false,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppTheme.textSub, size: 44),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
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
              style: const TextStyle(color: AppTheme.textHint, fontSize: 12),
            ),
            if (showRetry) ...[
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: () => _load(reset: true),
                child: const Text('다시 시도'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// 사고 영상 보기 (재생 + 지도, 분석은 버튼으로만)
// ══════════════════════════════════════════════════════════
class AccidentVideoViewScreen extends ConsumerStatefulWidget {
  const AccidentVideoViewScreen({super.key, required this.caseId});

  final String caseId;

  @override
  ConsumerState<AccidentVideoViewScreen> createState() =>
      _AccidentVideoViewScreenState();
}

class _AccidentVideoViewScreenState
    extends ConsumerState<AccidentVideoViewScreen> {
  late final void Function() _cancelVideoRequest;
  BackendCase? _case;
  String? _caseError;

  @override
  void initState() {
    super.initState();
    _cancelVideoRequest = ref
        .read(blackboxVideoProvider.notifier)
        .cancellationHandleForCase(widget.caseId);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void dispose() {
    _cancelVideoRequest();
    super.dispose();
  }

  Future<void> _initialize() async {
    setState(() => _caseError = null);
    try {
      final backendCase =
          await ref.read(caseServiceProvider).selectOwnedCase(widget.caseId);
      if (!mounted || backendCase.id != widget.caseId) return;
      setState(() => _case = backendCase);
      await ref
          .read(blackboxVideoProvider.notifier)
          .fetchAndDownload(backendCase.id);
    } catch (error) {
      if (!mounted) return;
      setState(() => _caseError = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _case;
    return Scaffold(
      backgroundColor: AppTheme.bgBlack,
      body: SafeArea(
        child: Column(
          children: [
            _header(context, '사고 영상'),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (current != null) ...[
                      Text(
                        current.title.isEmpty ? '사고 영상' : current.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatDate(current.createdAt),
                        style: const TextStyle(
                            color: AppTheme.textSub, fontSize: 12),
                      ),
                      const SizedBox(height: 20),
                    ],
                    _buildVideoSection(),
                    const SizedBox(height: 20),
                    _buildAnalysisButton(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoSection() {
    if (_caseError != null) {
      return _status(
        icon: Icons.error_outline_rounded,
        title: '사고 사건을 확인할 수 없습니다',
        subtitle: _caseError!,
        onRetry: _initialize,
      );
    }
    if (_case == null) {
      return _status(
        icon: Icons.search_rounded,
        title: '영상 확인 중',
        subtitle: '사고 사건을 확인하고 있습니다',
        loading: true,
      );
    }

    final received = ref.watch(blackboxVideoProvider);
    final videoState = received.caseId == widget.caseId
        ? received
        : const BlackboxVideoState();

    switch (videoState.status) {
      case VideoStatus.waiting:
        return _status(
          icon: Icons.cloud_queue_rounded,
          title: '원본 영상 준비 대기 중',
          subtitle: videoState.errorMessage ?? '이 사고의 원본 영상이 아직 준비되지 않았습니다.',
          onRetry: _retry,
        );
      case VideoStatus.fetching:
        return _status(
          icon: Icons.search_rounded,
          title: '영상 확인 중',
          subtitle: '블랙박스 영상을 찾고 있습니다',
          loading: true,
        );
      case VideoStatus.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('다운로드 중', style: AppTheme.label),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: videoState.downloadProgress,
                minHeight: 3,
                backgroundColor: AppTheme.divider,
                color: AppTheme.teslaRed,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              videoState.progressPercent,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w200,
              ),
            ),
          ],
        );
      case VideoStatus.ready:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BlackboxVideoPlayerWidget(
              localPath: videoState.localPath ?? '',
            ),
            const SizedBox(height: 16),
            _outlineButton(
              icon: Icons.location_on_outlined,
              label: '사고 위치 보기',
              onTap: _showMapSheet,
            ),
          ],
        );
      case VideoStatus.error:
        return _status(
          icon: Icons.error_outline_rounded,
          title: '영상을 불러올 수 없습니다',
          subtitle: videoState.errorMessage ?? '다시 시도해 주세요',
          onRetry: _retry,
        );
    }
  }

  Future<void> _retry() async {
    try {
      await ref.read(blackboxVideoProvider.notifier).retry(widget.caseId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error.toString()),
        backgroundColor: AppTheme.surfaceDark,
        behavior: SnackBarBehavior.floating,
      ));
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
                  key: ValueKey('map-${widget.caseId}'),
                  caseId: widget.caseId,
                  fallbackLatitude: _case?.lat,
                  fallbackLongitude: _case?.lon,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 영상은 이미 이 화면에서 확인했으므로 초동 대처의 영상 확인 단계를 건너뛰고
  // 바로 AI 과실 분석 화면으로 간다. 분석은 서버에 있는 원본 영상으로 진행되므로
  // 휴대폰에 영상 다운로드가 끝나지 않았어도 시작할 수 있다.
  Future<void> _startAnalysis() async {
    try {
      final backendCase =
          await ref.read(caseServiceProvider).selectOwnedCase(widget.caseId);
      if (!mounted || backendCase.id != widget.caseId) return;
      context.pushNamed('analysis', extra: backendCase.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error.toString()),
        backgroundColor: AppTheme.surfaceDark,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Widget _buildAnalysisButton() {
    final enabled = _case != null;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: enabled ? _startAnalysis : null,
        icon: const Icon(Icons.analytics_outlined),
        label: Text(_case?.isDemo == true ? '주차장 모델로 분석' : '분석 페이지로 이동'),
        style: FilledButton.styleFrom(
          backgroundColor: AppTheme.pointWhite,
          foregroundColor: Colors.black,
          disabledBackgroundColor: AppTheme.surfaceDark,
          disabledForegroundColor: AppTheme.textHint,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: const StadiumBorder(),
        ),
      ),
    );
  }

  Widget _outlineButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF3A3A3E)),
          borderRadius: BorderRadius.circular(100),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _status({
    required IconData icon,
    required String title,
    required String subtitle,
    bool loading = false,
    Future<void> Function()? onRetry,
  }) {
    return Center(
      child: Column(
        children: [
          const SizedBox(height: 24),
          SizedBox(
            width: 52,
            height: 52,
            child: loading
                ? const CircularProgressIndicator(
                    strokeWidth: 2, color: AppTheme.teslaRed)
                : Icon(icon, color: AppTheme.textSub, size: 44),
          ),
          const SizedBox(height: 18),
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
            style: const TextStyle(color: AppTheme.textHint, fontSize: 12),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 18),
            _outlineButton(
              icon: Icons.refresh_rounded,
              label: '다시 확인',
              onTap: () => onRetry(),
            ),
          ],
        ],
      ),
    );
  }
}
