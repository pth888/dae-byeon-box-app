// lib/widgets/analysis_clip_card.dart
//
// 과실 분석 화면 · "분석에 사용된 영상"
//   - AI 모델이 판단에 쓴 원본 영상 구간만 재생한다 (구간 끝에서 멈춤)
//   - 아래 막대에 구간 안의 재생 위치와 충격 시점(빨간 선)을 보여준다
//   - 영상은 누를 때만 불러온다 (화면을 열 때마다 큰 영상을 받지 않도록)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../services/blackbox_video_service.dart';
import '../utils/theme.dart';

class AnalysisClipCard extends ConsumerStatefulWidget {
  const AnalysisClipCard({
    super.key,
    required this.caseId,
    required this.startMs,
    required this.endMs,
    this.impactMs,
  });

  final String caseId;

  /// 원본 영상 기준 분석 구간 (ms)
  final int startMs;
  final int endMs;

  /// 원본 영상 기준 충격 시점 추정 (ms)
  final int? impactMs;

  @override
  ConsumerState<AnalysisClipCard> createState() => _AnalysisClipCardState();
}

class _AnalysisClipCardState extends ConsumerState<AnalysisClipCard> {
  VideoPlayerController? _controller;
  bool _loading = false;
  String? _error;

  Duration get _start => Duration(milliseconds: widget.startMs);
  Duration get _end => Duration(milliseconds: widget.endMs);

  @override
  void didUpdateWidget(covariant AnalysisClipCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 재분석으로 사건이나 구간이 바뀌면 처음 상태로
    if (oldWidget.caseId != widget.caseId ||
        oldWidget.startMs != widget.startMs ||
        oldWidget.endMs != widget.endMs) {
      _disposeController();
      _error = null;
      _loading = false;
    }
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  void _disposeController() {
    final c = _controller;
    _controller = null;
    c?.removeListener(_onTick);
    c?.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = ref.read(backendEvidenceServiceProvider);
      final files = await service.listCaseFiles(widget.caseId);
      final original = files.where((f) => f.kind == 'original_video').toList();
      if (original.isEmpty) {
        throw StateError('no original video');
      }
      final url = await service.fileAccessUrl(
          caseId: widget.caseId, fileId: original.first.id);
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      await controller.seekTo(_start);
      controller.addListener(_onTick);
      setState(() {
        _controller = controller;
        _loading = false;
      });
      await controller.play();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '원본 영상을 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.';
      });
    }
  }

  void _onTick() {
    final c = _controller;
    if (c == null || !mounted) return;
    // 분석 구간이 끝나면 멈춘다
    if (c.value.isPlaying && c.value.position >= _end) {
      c.pause();
    }
    setState(() {});
  }

  Future<void> _replay() async {
    final c = _controller;
    if (c == null) return;
    await c.seekTo(_start);
    await c.play();
  }

  Future<void> _togglePlay() async {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      if (c.value.position >= _end || c.value.position < _start) {
        await c.seekTo(_start);
      }
      await c.play();
    }
  }

  static String _clock(int ms) {
    final total = ms < 0 ? 0 : ms;
    final m = total ~/ 60000;
    final s = (total % 60000) / 1000;
    return '$m:${s.toStringAsFixed(1).padLeft(4, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final lengthSec = (widget.endMs - widget.startMs) / 1000;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        border: Border.all(color: AppTheme.divider),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '분석에 사용된 영상',
            style: TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          Text(
            'AI가 원본 영상의 ${_clock(widget.startMs)} ~ ${_clock(widget.endMs)} '
            '구간(약 ${lengthSec.toStringAsFixed(1)}초)을 보고 판단했습니다.'
            '${widget.impactMs != null ? ' 빨간 선은 충격 시점입니다.' : ''}',
            style: const TextStyle(
                color: AppTheme.textSub, fontSize: 12.5, height: 1.5),
          ),
          const SizedBox(height: 12),
          _video(),
          const SizedBox(height: 10),
          _segmentBar(),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(_clock(widget.startMs),
                  style:
                      const TextStyle(color: AppTheme.textHint, fontSize: 11)),
              const Spacer(),
              if (widget.impactMs != null)
                Text('충격 ${_clock(widget.impactMs!)}',
                    style: const TextStyle(
                        color: AppTheme.errorRed, fontSize: 11)),
              const Spacer(),
              Text(_clock(widget.endMs),
                  style:
                      const TextStyle(color: AppTheme.textHint, fontSize: 11)),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(
                    color: AppTheme.warningOrange, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  Widget _video() {
    final c = _controller;
    if (c == null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Material(
          color: Colors.black,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            key: const Key('analysis-clip-load'),
            borderRadius: BorderRadius.circular(8),
            onTap: _loading ? null : _load,
            child: Center(
              child: _loading
                  ? const Text('영상을 불러오는 중...',
                      style: TextStyle(color: AppTheme.textSub, fontSize: 13))
                  : const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.play_circle_outline,
                            color: Colors.white, size: 48),
                        SizedBox(height: 6),
                        Text('분석 구간 재생',
                            style: TextStyle(color: Colors.white, fontSize: 13)),
                      ],
                    ),
            ),
          ),
        ),
      );
    }
    final ended = !c.value.isPlaying && c.value.position >= _end;
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio:
                c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9,
            child: GestureDetector(
              onTap: _togglePlay,
              child: VideoPlayer(c),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: c.value.isPlaying ? '일시정지' : '재생',
              onPressed: _togglePlay,
              color: Colors.white,
              icon: Icon(c.value.isPlaying
                  ? Icons.pause_circle_outline
                  : Icons.play_circle_outline),
              iconSize: 34,
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _replay,
              icon: const Icon(Icons.replay_rounded, size: 18),
              label: Text(ended ? '구간 다시 보기' : '처음부터'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
          ],
        ),
      ],
    );
  }

  /// 분석 구간 막대: 흰색 = 재생한 부분, 빨간 선 = 충격 시점
  Widget _segmentBar() {
    final span = (widget.endMs - widget.startMs).toDouble();
    final c = _controller;
    double played = 0;
    if (c != null && span > 0) {
      played = ((c.value.position.inMilliseconds - widget.startMs) / span)
          .clamp(0.0, 1.0);
    }
    final impact = widget.impactMs;
    final impactAt = impact != null && span > 0
        ? ((impact - widget.startMs) / span).clamp(0.0, 1.0)
        : null;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return SizedBox(
        height: 14,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Container(
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A3E),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Container(
              width: w * played,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (impactAt != null)
              Positioned(
                left: (w * impactAt - 1).clamp(0.0, w - 2),
                child: Container(width: 2, height: 14, color: AppTheme.errorRed),
              ),
          ],
        ),
      );
    });
  }
}
