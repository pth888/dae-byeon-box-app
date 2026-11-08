// lib/widgets/emergency_mini_map.dart
//
// 긴급 알림 완료 화면의 작은 위치 지도 (OpenStreetMap 타일, 키 필요 없음)
// 좌표가 가운데 오도록 3x3 타일을 붙이고 핀을 올린다.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/theme.dart';

class EmergencyMiniMap extends StatelessWidget {
  const EmergencyMiniMap({
    super.key,
    required this.latitude,
    required this.longitude,
    this.height = 170,
    this.zoom = 16,
  });

  final double latitude;
  final double longitude;
  final double height;
  final int zoom;

  static const _tile = 256.0;
  static const _headers = {
    'User-Agent': 'DaeByeonBox/1.0 (capstone accident demo app)',
  };

  @override
  Widget build(BuildContext context) {
    final n = math.pow(2, zoom).toDouble();
    final x = (longitude + 180) / 360 * n;
    final latRad = latitude * math.pi / 180;
    final y = (1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
        2 *
        n;
    final tileX = x.floor();
    final tileY = y.floor();
    // 좌표의 타일 안 위치 (픽셀)
    final px = (x - tileX) * _tile;
    final py = (y - tileY) * _tile;

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          final h = box.maxHeight;
          // 가운데 타일의 왼쪽 위 모서리 위치
          final originX = w / 2 - px;
          final originY = h / 2 - py;
          final tiles = <Widget>[];
          for (var dx = -2; dx <= 2; dx++) {
            for (var dy = -1; dy <= 1; dy++) {
              final tx = (tileX + dx) % n.toInt();
              final ty = tileY + dy;
              if (ty < 0 || ty >= n) continue;
              tiles.add(Positioned(
                left: originX + dx * _tile,
                top: originY + dy * _tile,
                width: _tile,
                height: _tile,
                child: Image.network(
                  'https://tile.openstreetmap.org/$zoom/$tx/$ty.png',
                  headers: _headers,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      Container(color: AppTheme.surfaceDark),
                ),
              ));
            }
          }
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(child: Container(color: AppTheme.surfaceDark)),
              ...tiles,
              // 핀
              Positioned(
                left: w / 2 - 18,
                top: h / 2 - 36,
                child: const Icon(Icons.location_on,
                    color: AppTheme.errorRed, size: 36),
              ),
              Positioned(
                right: 6,
                bottom: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  color: Colors.white70,
                  child: const Text(
                    '© OpenStreetMap',
                    style: TextStyle(color: Colors.black87, fontSize: 9),
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}
