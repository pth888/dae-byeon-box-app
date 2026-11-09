// lib/widgets/floating_chatbot_button.dart
// 테슬라 미니멀 스타일 - 드래그로 위치 이동 + 탭하면 챗봇 바텀시트 오픈

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/theme.dart';
import '../screens/chatbot/thread_chat_screen.dart';
import '../services/auth_service.dart';

/// 드래그 가능한 플로팅 챗봇 버튼.
/// 화면 어디로든 끌어다 놓을 수 있고, 놓으면 좌/우 가장자리에 붙는다.
/// 위치는 앱이 켜져 있는 동안 유지된다(정적 변수).
class DraggableChatbotButton extends ConsumerStatefulWidget {
  final String screenContext;
  const DraggableChatbotButton({super.key, this.screenContext = 'home'});

  // 화면 전환 후에도 위치를 기억하기 위한 정적 저장 (null이면 기본 위치)
  static Offset? savedPosition;

  @override
  ConsumerState<DraggableChatbotButton> createState() =>
      _DraggableChatbotButtonState();
}

class _DraggableChatbotButtonState
    extends ConsumerState<DraggableChatbotButton> {
  static const double _size = 56;
  static const double _margin = 16;

  Offset? _pos; // 좌상단 기준 좌표

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final safeBottom = MediaQuery.of(context).padding.bottom;

    // 초기 기본 위치: 우측, 수치 라인(ON) 위쪽
    _pos ??= DraggableChatbotButton.savedPosition ??
        Offset(
          screen.width - _size - 20,
          screen.height - _size - safeBottom - 210,
        );

    // 화면 경계 안으로 보정
    final maxX = screen.width - _size - _margin;
    final maxY = screen.height - _size - safeBottom - _margin;
    final x = _pos!.dx.clamp(_margin, maxX);
    final y = _pos!.dy.clamp(_margin + 40, maxY);

    return Positioned(
      left: x,
      top: y,
      child: GestureDetector(
        onTap: () => showChatbotSheet(
          context,
          screenContext: widget.screenContext,
          caseId: null,
          userId: ref.read(authProvider).email ?? 'signed-out',
        ),
        onPanUpdate: (details) {
          setState(() {
            _pos = Offset(
                _pos!.dx + details.delta.dx, _pos!.dy + details.delta.dy);
          });
        },
        onPanEnd: (_) {
          // 가까운 좌/우 가장자리에 스냅
          final centerX = _pos!.dx + _size / 2;
          final snapX = centerX < screen.width / 2
              ? _margin
              : screen.width - _size - _margin;
          setState(() {
            _pos = Offset(snapX, _pos!.dy.clamp(_margin + 40, maxY));
            DraggableChatbotButton.savedPosition = _pos;
          });
        },
        child: _buildButton(),
      ),
    );
  }

  Widget _buildButton() {
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFF3A3A3E), width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: const Icon(
        Icons.chat_bubble_outline_rounded,
        color: Colors.white,
        size: 24,
      ),
    );
  }
}

/// (호환용) 기존 정적 버튼 - 현재는 Draggable 버전을 사용
class FloatingChatbotButton extends ConsumerWidget {
  final String screenContext;
  const FloatingChatbotButton({super.key, this.screenContext = 'home'});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => showChatbotSheet(
        context,
        screenContext: screenContext,
        caseId: null,
        userId: ref.read(authProvider).email ?? 'signed-out',
      ),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: AppTheme.surfaceDark,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF3A3A3E), width: 1),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 16,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: const Icon(
          Icons.chat_bubble_outline_rounded,
          color: Colors.white,
          size: 24,
        ),
      ),
    );
  }
}

/// 어디서든 호출 가능한 챗봇 바텀시트
Future<void> showChatbotSheet(
  BuildContext context, {
  String screenContext = 'home',
  required String? caseId,
  required String userId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (sheetContext) {
      final media = MediaQuery.of(sheetContext);
      final keyboard = media.viewInsets.bottom;
      final available = (media.size.height - keyboard).clamp(0.0, media.size.height).toDouble();
      final preferred = media.size.height * 0.82;
      return Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: SizedBox(
          height: available < preferred ? available : preferred,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: MediaQuery(
              data: media.copyWith(viewInsets: EdgeInsets.zero),
              child: ThreadChatScreen(initialCaseId: caseId, keyboardVisible: keyboard > 0),
            ),
          ),
        ),
      );
    },
  );
}
