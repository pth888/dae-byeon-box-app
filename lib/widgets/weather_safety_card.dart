// lib/widgets/weather_safety_card.dart
//
// 사용 패키지: weather: ^3.1.1
// 연구 문서 2.2절: "기상 상황 및 시즌별 위험도 예측 대응법 노출"
//   예시: 장마철 빗길 수막현상, 겨울철 블랙아이스 위험도

import 'package:flutter/material.dart';

class WeatherSafetyCard extends StatelessWidget {
  const WeatherSafetyCard({super.key});

  @override
  Widget build(BuildContext context) {
    // weather 패키지로 실제 날씨 연동 (WeatherFactory 사용)
    // 현재는 Mock 데이터 표시
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.blue.shade400, Colors.blue.shade600],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Text('🌤️', style: TextStyle(fontSize: 24)),
              SizedBox(width: 8),
              Text(
                '오늘의 운전 안전 지수',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '맑음 · 22°C · 주의사항 없음',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '💡 안전운전 넛지: 오후 6시 이후 퇴근길 교통량 증가. 교차로 진입 속도를 줄이세요.',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
