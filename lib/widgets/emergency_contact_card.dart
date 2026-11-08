// lib/widgets/emergency_contact_card.dart
//
// 마이페이지 · 비상 연락처(보호자) 카드
// 사고 후 15초간 응답이 없으면 이 번호로 위치 문자를 보낸다.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/emergency_contact_service.dart';
import '../services/emergency_dispatch_service.dart';
import '../utils/theme.dart';

class EmergencyContactCard extends ConsumerWidget {
  const EmergencyContactCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contact = ref.watch(emergencyContactProvider);
    final registered = contact != null;
    final autoSend = EmergencyDispatcher.canSendAutomatically;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.divider, width: 1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.surfaceDark,
            ),
            child: Icon(
              registered ? Icons.contact_phone_outlined : Icons.person_add_alt,
              color: registered ? Colors.white : AppTheme.textHint,
              size: 22,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  contact != null ? contact.label : '등록된 비상 연락처 없음',
                  style: TextStyle(
                    color: registered ? Colors.white : AppTheme.textSub,
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  autoSend
                      ? '사고 후 15초간 응답이 없으면 위치를 문자로 자동 전송'
                      : '사고 후 15초간 응답이 없으면 위치 전송 (이 기기는 시연 화면)',
                  style: const TextStyle(
                    color: AppTheme.textHint,
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Semantics(
            button: true,
            label: registered ? '비상 연락처 변경' : '비상 연락처 등록',
            child: GestureDetector(
              onTap: () => _edit(context, ref, contact),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: registered ? Colors.transparent : AppTheme.pointWhite,
                  border: Border.all(
                    color: registered
                        ? const Color(0xFF3A3A3E)
                        : AppTheme.pointWhite,
                  ),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  registered ? '변경' : '등록',
                  style: TextStyle(
                    color: registered ? Colors.white : Colors.black,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    EmergencyContact? current,
  ) async {
    final nameController = TextEditingController(text: current?.name ?? '');
    final phoneController =
        TextEditingController(text: current?.displayPhone ?? '');
    String? error;

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.surfaceDark,
          title: const Text('비상 연락처',
              style: TextStyle(color: Colors.white, fontSize: 17)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '사고 후 응답이 없을 때 위치와 사고 시각을 이 번호로 보냅니다. 번호는 이 휴대폰에만 저장됩니다.',
                style: TextStyle(
                    color: AppTheme.textSub, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: '이름 (선택)',
                  hintText: '예: 어머니',
                  labelStyle: TextStyle(color: AppTheme.textSub),
                  hintStyle: TextStyle(color: AppTheme.textHint),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9\- ]')),
                ],
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: '휴대폰 번호',
                  hintText: '010-1234-5678',
                  errorText: error,
                  labelStyle: const TextStyle(color: AppTheme.textSub),
                  hintStyle: const TextStyle(color: AppTheme.textHint),
                ),
              ),
            ],
          ),
          actions: [
            if (current != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'delete'),
                child: const Text('삭제',
                    style: TextStyle(color: AppTheme.errorRed)),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소',
                  style: TextStyle(color: AppTheme.textSub)),
            ),
            TextButton(
              onPressed: () {
                if (normalizePhoneNumber(phoneController.text) == null) {
                  setDialogState(() => error = '전화번호를 확인해 주세요');
                  return;
                }
                Navigator.pop(ctx, 'save');
              },
              child:
                  const Text('저장', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );

    final name = nameController.text;
    final phone = phoneController.text;
    // 다이얼로그 닫힘 애니메이션이 끝난 뒤 정리
    Future.delayed(const Duration(milliseconds: 500), () {
      nameController.dispose();
      phoneController.dispose();
    });
    if (action == null || !context.mounted) return;

    final notifier = ref.read(emergencyContactProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    if (action == 'delete') {
      await notifier.clear();
      messenger.showSnackBar(
          const SnackBar(content: Text('비상 연락처를 삭제했습니다.')));
      return;
    }

    try {
      final saved = await notifier.save(name: name, phone: phone);
      if (!saved) {
        messenger.showSnackBar(
            const SnackBar(content: Text('비상 연락처를 저장하지 못했습니다.')));
        return;
      }
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('비상 연락처를 저장하지 못했습니다.')));
      return;
    }

    // 안드로이드: 사고 순간에 권한 창을 띄울 수 없으니 지금 받아 둔다
    if (EmergencyDispatcher.canSendAutomatically) {
      final granted = await EmergencyDispatcher.requestSmsPermission();
      messenger.showSnackBar(SnackBar(
        content: Text(granted
            ? '비상 연락처를 저장했습니다. 응답이 없으면 자동으로 문자를 보냅니다.'
            : '저장했지만 문자 권한이 없어 자동 발송이 되지 않습니다. 다시 저장해 권한을 허용해 주세요.'),
      ));
    } else {
      messenger.showSnackBar(const SnackBar(
        content: Text('비상 연락처를 저장했습니다.'),
      ));
    }
  }
}
