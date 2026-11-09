// lib/screens/accident/timeline_dashboard_screen.dart
//
// 담당 기능: 3.3 사고 처리 타임라인 대시보드 및 전문가 매칭 (BM 연계)
//   - 사고 당일: 현장 채증/접수 → D+1: 대인 배상/병원 진료 → D+7: 과실 비율 최종 조율
//   - 퀘스트 형태로 진행 상황 시각화 (timeline_tile)
//   - 소송 이행 시 외부 전문가 인터페이스 연동
//
// 사용 패키지:
//   timeline_tile: ^2.0.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timeline_tile/timeline_tile.dart';

import '../../utils/theme.dart';

// ── 타임라인 아이템 모델 ─────────────────────────────────
class TimelineItem {
  final String dayLabel;    // D+0, D+1, D+7
  final String title;
  final String description;
  final bool isCompleted;
  final bool isCurrent;
  final IconData icon;
  final Color color;

  const TimelineItem({
    required this.dayLabel,
    required this.title,
    required this.description,
    required this.isCompleted,
    required this.isCurrent,
    required this.icon,
    required this.color,
  });
}

class TimelineDashboardScreen extends ConsumerWidget {
  final String accidentId;
  const TimelineDashboardScreen({super.key, required this.accidentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 연구 문서 3.3절 타임라인 (D-Day 뷰)
    final timelineItems = [
      const TimelineItem(
        dayLabel: 'D+0',
        title: '사고 당일: 현장 채증 / 접수',
        description: '현장 사진·영상 촬영, 경찰 신고, 보험사 1차 접수 완료',
        isCompleted: true,
        isCurrent: false,
        icon: Icons.camera_alt,
        color: Colors.green,
      ),
      const TimelineItem(
        dayLabel: 'D+1',
        title: '대인 배상 / 병원 진료',
        description: '부상자 병원 진료 기록 수집, 대인 배상 청구 서류 준비',
        isCompleted: false,
        isCurrent: true,
        icon: Icons.local_hospital,
        color: Colors.blue,
      ),
      const TimelineItem(
        dayLabel: 'D+7',
        title: '과실 비율 최종 조율 / 합의금 산정',
        description: 'AI 분석 리포트 기반 보험사와 과실 비율 협의, 합의금 최종 산정',
        isCompleted: false,
        isCurrent: false,
        icon: Icons.handshake,
        color: Colors.orange,
      ),
      const TimelineItem(
        dayLabel: 'D+30',
        title: '소송 이행 (필요 시)',
        description: '합의 불발 시 소송 전문 변호사 매칭 및 법원 제출 서류 준비',
        isCompleted: false,
        isCurrent: false,
        icon: Icons.gavel,
        color: Colors.purple,
      ),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text('사고 처리 타임라인'),
        backgroundColor: AppTheme.primaryBlue,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 진행 현황 배너 ─────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1565C0), Color(0xFF1976D2)],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('사고 접수 D+1',
                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                  SizedBox(height: 4),
                  Text('현재: 대인 배상 준비 단계',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      )),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ── 타임라인 (timeline_tile) ───────────────
            ...List.generate(timelineItems.length, (i) {
              final item = timelineItems[i];
              final isFirst = i == 0;
              final isLast = i == timelineItems.length - 1;

              return TimelineTile(
                alignment: TimelineAlign.manual,
                lineXY: 0.15,
                isFirst: isFirst,
                isLast: isLast,
                indicatorStyle: IndicatorStyle(
                  width: 48,
                  height: 48,
                  indicator: Container(
                    decoration: BoxDecoration(
                      color: item.isCompleted
                          ? Colors.green
                          : item.isCurrent
                              ? item.color
                              : Colors.grey.shade300,
                      shape: BoxShape.circle,
                    ),
                    child: item.isCompleted
                        ? const Icon(Icons.check, color: Colors.white, size: 20)
                        : Icon(item.icon,
                            color: item.isCurrent
                                ? Colors.white
                                : Colors.grey.shade500,
                            size: 20),
                  ),
                ),
                beforeLineStyle: LineStyle(
                  color: i < timelineItems.indexWhere((t) => t.isCurrent)
                      ? Colors.green
                      : Colors.grey.shade300,
                  thickness: 2,
                ),
                endChild: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 0, 12),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: item.isCurrent
                          ? item.color.withOpacity(0.05)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: item.isCurrent
                          ? Border.all(color: item.color, width: 2)
                          : null,
                      boxShadow: AppTheme.cardShadow,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: item.color.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                item.dayLabel,
                                style: TextStyle(
                                  color: item.color,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (item.isCurrent) ...[
                              const SizedBox(width: 8),
                              const Text('진행 중',
                                  style: TextStyle(
                                    color: Colors.blue,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  )),
                            ],
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(item.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            )),
                        const SizedBox(height: 4),
                        Text(item.description,
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 13,
                              height: 1.4,
                            )),

                        // 소송 단계 전문가 매칭 버튼
                        if (item.dayLabel == 'D+30') ...[
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: () => _showExpertMatchingDialog(context),
                            icon: const Icon(Icons.person_search, size: 16),
                            label: const Text('교통사고 전문 변호사 매칭'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.purple.shade600,
                              foregroundColor: Colors.white,
                              textStyle: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            }),

            const SizedBox(height: 24),

            // ── 손해사정사 직접 연결 ───────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: AppTheme.cardShadow,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('전문가 직접 연결',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 12),
                  _buildExpertButton(
                    icon: Icons.calculate,
                    label: '손해사정사 연결',
                    subtitle: 'AI 과실 결과에 이의 시',
                    color: Colors.orange,
                  ),
                  const SizedBox(height: 8),
                  _buildExpertButton(
                    icon: Icons.gavel,
                    label: '교통사고 전문 변호사 풀',
                    subtitle: '소송 이행 절차 필요 시',
                    color: Colors.purple,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpertButton({
    required IconData icon,
    required String label,
    required String subtitle,
    required Color color,
  }) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color),
      ),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {},
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );
  }

  void _showExpertMatchingDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('전문 변호사 매칭'),
        content: const Text(
            '교통사고 전문 변호사 풀과 다이렉트로 매칭해 드립니다.\n연결하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('연결')),
        ],
      ),
    );
  }
}
