import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auth_service.dart';
import '../services/case_service.dart' show authenticatedPrincipal;
import '../services/map_service.dart';
import '../utils/theme.dart';
import 'osm_embed.dart';

const Key accidentMapFrameKey = Key('accident-location-map-frame');

class AccidentLocationMap extends ConsumerStatefulWidget {
  const AccidentLocationMap({
    super.key,
    required this.caseId,
    this.service,
    this.fallbackLatitude,
    this.fallbackLongitude,
  });

  final String caseId;
  final MapService? service;
  final double? fallbackLatitude;
  final double? fallbackLongitude;

  @override
  ConsumerState<AccidentLocationMap> createState() =>
      _AccidentLocationMapState();
}

class _AccidentLocationMapState extends ConsumerState<AccidentLocationMap> {
  late MapService _service;
  AccidentMap? _map;
  String? _error;
  bool _loading = true;
  bool _awaitingSessionLogin = false;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? ref.read(mapServiceProvider);
    _load(rebuild: false);
  }

  @override
  void didUpdateWidget(covariant AccidentLocationMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.caseId == widget.caseId &&
        oldWidget.service == widget.service) {
      return;
    }
    _service.cancelPendingRequests();
    _service = widget.service ?? ref.read(mapServiceProvider);
    _load();
  }

  @override
  void dispose() {
    _requestGeneration++;
    _service.cancelPendingRequests();
    super.dispose();
  }

  Future<void> _load({bool rebuild = true}) async {
    final generation = ++_requestGeneration;
    final caseId = widget.caseId;
    final service = _service;
    void clear() {
      _map = null;
      _error = null;
      _loading = true;
    }

    if (rebuild && mounted) {
      setState(clear);
    } else {
      clear();
    }

    try {
      final map = await service.fetchCaseMap(caseId);
      if (!_isCurrent(generation, caseId, service)) return;
      setState(() {
        _map = map;
        _error = null;
        _loading = false;
      });
    } on MapRequestCancelledException {
      return;
    } on MapAuthenticationException {
      if (!_isCurrent(generation, caseId, service)) return;
      setState(() {
        _map = null;
        _error = '로그인 후 사고 위치 지도를 확인할 수 있습니다';
        _loading = false;
      });
    } on MapServiceException {
      if (!_isCurrent(generation, caseId, service)) return;
      setState(() {
        _map = null;
        _error = '지도를 불러올 수 없습니다';
        _loading = false;
      });
    } catch (_) {
      if (!_isCurrent(generation, caseId, service)) return;
      setState(() {
        _map = null;
        _error = '지도를 불러올 수 없습니다';
        _loading = false;
      });
    }
  }

  bool _isCurrent(int generation, String caseId, MapService service) =>
      mounted &&
      generation == _requestGeneration &&
      caseId == widget.caseId &&
      identical(service, _service);

  void _handleSessionChange(AuthState? previous, AuthState next) {
    final previousPrincipal =
        previous == null ? null : authenticatedPrincipal(previous);
    final nextPrincipal = authenticatedPrincipal(next);
    final loginStarted = previous?.status == AuthStatus.authenticated &&
        previous?.isBusy == false &&
        next.isBusy;
    final loginFinished = _awaitingSessionLogin && !next.isBusy;
    if (previousPrincipal == nextPrincipal && !loginStarted && !loginFinished) {
      return;
    }
    if (loginStarted || previousPrincipal != nextPrincipal) {
      _service.invalidateSession();
    }
    _awaitingSessionLogin = loginStarted;
    _requestGeneration++;
    if (!mounted) return;
    final canReload = nextPrincipal != null &&
        !loginStarted &&
        (!loginFinished || next.error == null);
    setState(() {
      _map = null;
      _error = nextPrincipal == null || (loginFinished && next.error != null)
          ? '로그인 후 사고 위치 지도를 확인할 수 있습니다'
          : null;
      _loading = canReload;
    });
    if (canReload) _load();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authProvider, _handleSessionChange);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            key: accidentMapFrameKey,
            height: 200,
            width: double.infinity,
            child: _buildFrame(),
          ),
        ),
        if (_map != null)
          _buildMetadata(_map!)
        else if (_hasFallbackCoordinate)
          _buildFallbackMetadata(),
      ],
    );
  }

  Widget _buildFrame() {
    if (_loading) {
      return const ColoredBox(
        color: AppTheme.surfaceDark,
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppTheme.teslaRed,
            ),
          ),
        ),
      );
    }
    if (_error != null) {
      return _fallbackMap() ?? _message(_error!, retry: true);
    }

    final map = _map;
    if (map == null) return _message('지도를 불러올 수 없습니다', retry: true);
    switch (map.status) {
      case AccidentMapStatus.ready:
        return _mapImage(map);
      case AccidentMapStatus.pending:
        return _fallbackMap() ?? _message('지도 이미지를 생성 중입니다', retry: true);
      case AccidentMapStatus.noGps:
        return _message('위치 정보(GPS)가 없는 사고입니다');
      case AccidentMapStatus.unavailable:
        return _fallbackMap() ?? _message('지도를 불러올 수 없습니다', retry: true);
    }
  }

  bool get _hasFallbackCoordinate {
    final map = _map;
    final latitude = map?.latitude ?? widget.fallbackLatitude;
    final longitude = map?.longitude ?? widget.fallbackLongitude;
    return latitude != null &&
        longitude != null &&
        latitude.isFinite &&
        longitude.isFinite &&
        latitude >= -90 &&
        latitude <= 90 &&
        longitude >= -180 &&
        longitude <= 180;
  }

  Widget? _fallbackMap() {
    if (!kIsWeb || !_hasFallbackCoordinate) return null;
    final latitude = _map?.latitude ?? widget.fallbackLatitude!;
    final longitude = _map?.longitude ?? widget.fallbackLongitude!;
    return Stack(
      fit: StackFit.expand,
      children: [
        buildOsmEmbed(latitude, longitude),
        const Positioned(
          right: 6,
          bottom: 4,
          child: ColoredBox(
            color: Colors.white70,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                '지도 이미지 대체 보기 · © OpenStreetMap',
                style: TextStyle(fontSize: 9, color: Colors.black87),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFallbackMetadata() => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          '${widget.fallbackLatitude!.toStringAsFixed(6)}, '
          '${widget.fallbackLongitude!.toStringAsFixed(6)} · GPS 좌표',
          style: const TextStyle(color: AppTheme.textHint, fontSize: 11),
        ),
      );

  Widget _mapImage(AccidentMap map) {
    final imageBytes = map.imageBytes;
    if (imageBytes == null) {
      return _fallbackMap() ?? _message('지도를 불러올 수 없습니다', retry: true);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(
          imageBytes,
          fit: BoxFit.cover,
          gaplessPlayback: false,
          errorBuilder: (context, error, stackTrace) =>
              _fallbackMap() ?? _message('지도를 불러올 수 없습니다', retry: true),
        ),
        Positioned(
          right: 6,
          bottom: 4,
          child: ColoredBox(
            color: Colors.white70,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: const Text(
                '© OpenStreetMap',
                style: TextStyle(fontSize: 9, color: Colors.black87),
              ),
            ),
          ),
        ),
        if (map.hasRoute)
          Positioned(
            left: 8,
            top: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  '이동 경로 포함',
                  style: TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _message(String message, {bool retry = false}) {
    return ColoredBox(
      color: AppTheme.surfaceDark,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.map_outlined, color: AppTheme.textHint, size: 30),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textSub, fontSize: 12),
              ),
              if (retry) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('다시 시도'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetadata(AccidentMap map) {
    final hasCoordinates = map.latitude != null && map.longitude != null;
    if (!hasCoordinates && map.capturedAt == null && !map.gpsIsAssumed) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (hasCoordinates)
            _fact(
              Icons.my_location_rounded,
              '${map.latitude!.toStringAsFixed(6)}, '
              '${map.longitude!.toStringAsFixed(6)}',
            ),
          if (map.capturedAt != null)
            _fact(Icons.schedule, _formatUtc(map.capturedAt!)),
          if (map.gpsIsAssumed)
            _fact(Icons.info_outline, '추정 GPS 위치'),
        ],
      ),
    );
  }

  Widget _fact(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppTheme.textHint),
        const SizedBox(width: 5),
        Text(
          text,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppTheme.textSub, fontSize: 12),
        ),
      ],
    );
  }
}

String _formatUtc(DateTime value) {
  final utc = value.toUtc();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} UTC';
}
