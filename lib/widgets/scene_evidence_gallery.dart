// lib/widgets/scene_evidence_gallery.dart
//
// 초동 대처 3단계(현장 촬영)에서 찍어 올린 사진·추가 영상 보기
//   - 서버에 저장된 사건 파일 중 현장 사진(evidence_photo)·추가 영상(additional_video)만 보여준다
//   - 사진: 눌러서 크게 보기(확대 가능) / 영상: 눌러서 재생
//   - 삭제: 칸 오른쪽 위 휴지통, 길게 누르기, 크게 보기 화면 오른쪽 위 휴지통

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../services/blackbox_video_service.dart';
import '../utils/theme.dart';

const _photoKind = 'evidence_photo';
const _videoKind = 'additional_video';

class SceneEvidenceGallery extends ConsumerStatefulWidget {
  const SceneEvidenceGallery({
    super.key,
    required this.caseId,
    this.onCounts,
  });

  final String caseId;

  /// 불러온 사진·영상 개수를 화면 위쪽 숫자에 반영할 때
  final void Function(int photos, int videos)? onCounts;

  @override
  ConsumerState<SceneEvidenceGallery> createState() =>
      _SceneEvidenceGalleryState();
}

class _GalleryItem {
  _GalleryItem(this.file);
  final BackendCaseFile file;
  String? url;
  bool get isVideo => file.kind == _videoKind;
}

class _SceneEvidenceGalleryState extends ConsumerState<SceneEvidenceGallery> {
  List<_GalleryItem>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = ref.read(backendEvidenceServiceProvider);
    try {
      final files = await service.listCaseFiles(widget.caseId);
      final items = files
          .where((f) => f.kind == _photoKind || f.kind == _videoKind)
          .map(_GalleryItem.new)
          .toList()
        ..sort((a, b) => b.file.createdAt.compareTo(a.file.createdAt));
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
      widget.onCounts?.call(
        items.where((i) => !i.isVideo).length,
        items.where((i) => i.isVideo).length,
      );
      // 사진 미리보기 주소는 하나씩 받아 온다
      for (final item in items.where((i) => !i.isVideo)) {
        try {
          final url = await service.fileAccessUrl(
              caseId: widget.caseId, fileId: item.file.id);
          if (!mounted) return;
          setState(() => item.url = url);
        } catch (_) {
          // 하나가 실패해도 나머지는 보여준다
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '촬영한 파일을 불러오지 못했습니다.');
    }
  }

  Future<String?> _urlFor(_GalleryItem item) async {
    if (item.url != null) return item.url;
    try {
      final url = await ref
          .read(backendEvidenceServiceProvider)
          .fileAccessUrl(caseId: widget.caseId, fileId: item.file.id);
      item.url = url;
      return url;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('파일을 열 수 없습니다. 잠시 후 다시 시도해 주세요.')));
      }
      return null;
    }
  }

  Future<void> _open(_GalleryItem item) async {
    final url = await _urlFor(item);
    if (url == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (viewerContext) => item.isVideo
          ? _VideoViewer(
              url: url,
              onDelete: () => _confirmDelete(item, viewerContext: viewerContext),
            )
          : _PhotoViewer(
              url: url,
              onDelete: () => _confirmDelete(item, viewerContext: viewerContext),
            ),
    ));
  }

  /// 삭제 확인 → 서버에서 삭제 → 목록에서 빼기
  Future<void> _confirmDelete(_GalleryItem item,
      {BuildContext? viewerContext}) async {
    final dialogContext = viewerContext ?? context;
    final what = item.isVideo ? '영상' : '사진';
    final ok = await showDialog<bool>(
      context: dialogContext,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text('$what 삭제',
            style: const TextStyle(color: Colors.white, fontSize: 17)),
        content: Text(
          '이 $what을 삭제할까요?\n삭제한 $what은 되돌릴 수 없습니다.',
          style: const TextStyle(
              color: AppTheme.textSub, fontSize: 13.5, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소', style: TextStyle(color: AppTheme.textSub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: AppTheme.errorRed)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(backendEvidenceServiceProvider)
          .deleteCaseFile(caseId: widget.caseId, fileId: item.file.id);
    } on EvidenceServiceException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
      return;
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('파일을 삭제하지 못했습니다. 잠시 후 다시 시도해 주세요.')));
      return;
    }
    if (!mounted) return;
    // 크게 보기 화면에서 지웠으면 그 화면을 닫는다
    if (viewerContext != null && viewerContext.mounted) {
      Navigator.of(viewerContext).pop();
    }
    final items = (_items ?? const <_GalleryItem>[])
        .where((i) => i.file.id != item.file.id)
        .toList();
    setState(() => _items = items);
    widget.onCounts?.call(
      items.where((i) => !i.isVideo).length,
      items.where((i) => i.isVideo).length,
    );
    messenger.showSnackBar(SnackBar(content: Text('$what을 삭제했습니다.')));
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '촬영한 사진·영상',
              style: TextStyle(
                color: AppTheme.textSub,
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: () {
                setState(() {
                  _items = null;
                  _error = null;
                });
                _load();
              },
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.refresh_rounded,
                    color: AppTheme.textHint, size: 18),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_error != null)
          Text(_error!,
              style: const TextStyle(color: AppTheme.textHint, fontSize: 12.5))
        else if (items == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              ),
            ),
          )
        else if (items.isEmpty)
          const Text('아직 촬영한 사진·영상이 없습니다.',
              style: TextStyle(color: AppTheme.textHint, fontSize: 12.5))
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 120,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemBuilder: (_, i) => _tile(items[i]),
          ),
      ],
    );
  }

  Widget _tile(_GalleryItem item) {
    Widget content;
    if (item.isVideo) {
      content = const Center(
        child: Icon(Icons.play_circle_outline,
            color: Colors.white, size: 36),
      );
    } else if (item.url == null) {
      content = const Center(
        child: Icon(Icons.image_outlined, color: AppTheme.textHint, size: 28),
      );
    } else {
      content = Image.network(
        item.url!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Center(
          child: Icon(Icons.broken_image_outlined,
              color: AppTheme.textHint, size: 28),
        ),
      );
    }
    return Semantics(
      button: true,
      label: item.isVideo ? '추가 영상 재생' : '현장 사진 크게 보기',
      child: GestureDetector(
        onTap: () => _open(item),
        onLongPress: () => _confirmDelete(item),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            color: AppTheme.surfaceDark,
            child: Stack(
              fit: StackFit.expand,
              children: [
                content,
                if (item.isVideo)
                  const Positioned(
                    left: 6,
                    bottom: 5,
                    child: Text('영상',
                        style: TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                // 눈에 보이는 삭제 버튼 (길게 누르기를 모르는 사용자도 지울 수 있게)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Semantics(
                    button: true,
                    label: item.isVideo ? '영상 삭제' : '사진 삭제',
                    child: GestureDetector(
                      key: Key('scene-delete-${item.file.id}'),
                      onTap: () => _confirmDelete(item),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: const BoxDecoration(
                          color: Color(0xB3000000),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.delete_outline_rounded,
                            color: Colors.white, size: 16),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 사진 크게 보기 ──────────────────────────────────────────
class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.url, required this.onDelete});
  final String url;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('현장 사진'),
        actions: [
          IconButton(
            tooltip: '사진 삭제',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: onDelete,
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 5,
          child: Image.network(
            url,
            fit: BoxFit.contain,
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : const CircularProgressIndicator(color: Colors.white),
            errorBuilder: (_, __, ___) => const Text('사진을 불러오지 못했습니다.',
                style: TextStyle(color: AppTheme.textSub)),
          ),
        ),
      ),
    );
  }
}

// ── 영상 재생 ───────────────────────────────────────────────
class _VideoViewer extends StatefulWidget {
  const _VideoViewer({required this.url, required this.onDelete});
  final String url;
  final VoidCallback onDelete;

  @override
  State<_VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<_VideoViewer> {
  late final VideoPlayerController _controller;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
      _controller.play();
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('추가 영상'),
        actions: [
          IconButton(
            tooltip: '영상 삭제',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () {
              _controller.pause();
              widget.onDelete();
            },
          ),
        ],
      ),
      body: Center(
        child: _failed
            ? const Text('영상을 재생하지 못했습니다.',
                style: TextStyle(color: AppTheme.textSub))
            : !_ready
                ? const CircularProgressIndicator(color: Colors.white)
                : GestureDetector(
                    onTap: () => _controller.value.isPlaying
                        ? _controller.pause()
                        : _controller.play(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AspectRatio(
                          aspectRatio: _controller.value.aspectRatio,
                          child: VideoPlayer(_controller),
                        ),
                        VideoProgressIndicator(
                          _controller,
                          allowScrubbing: true,
                          colors: const VideoProgressColors(
                            playedColor: Colors.white,
                            bufferedColor: AppTheme.textHint,
                            backgroundColor: AppTheme.surfaceDark,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Icon(
                          _controller.value.isPlaying
                              ? Icons.pause_circle_outline
                              : Icons.play_circle_outline,
                          color: Colors.white,
                          size: 40,
                        ),
                      ],
                    ),
                  ),
      ),
    );
  }
}
