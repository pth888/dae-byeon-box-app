// lib/widgets/driver_license_card.dart
//
// 마이페이지 · 운전면허 카드 (비상 연락처 카드와 같은 모양)
//   - "촬영": 카메라로 면허증을 찍으면 OCR 로 이름·면허번호·면허 종류·적성검사 기간을 채운 확인 창을 연다
//   - "직접 입력"/"변경": 같은 확인 창에서 직접 입력·수정
//   - 저장하면 휴대폰에 저장하고, 면허번호는 [onSaved] 로 넘겨 서버 프로필에도 반영한다

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../services/driver_license_service.dart';
import '../utils/ocr_helper_io.dart'
    if (dart.library.html) '../utils/ocr_helper_web.dart';
import '../utils/theme.dart';

class DriverLicenseCard extends ConsumerStatefulWidget {
  const DriverLicenseCard({
    super.key,
    required this.serverLicenseNumber,
    required this.onSaved,
  });

  /// 서버 프로필에 저장돼 있던 면허번호 (휴대폰에 저장된 정보가 없을 때 표시)
  final String serverLicenseNumber;

  /// 저장 후 면허번호를 서버 프로필에 반영
  final Future<void> Function(DriverLicenseInfo info) onSaved;

  @override
  ConsumerState<DriverLicenseCard> createState() => _DriverLicenseCardState();
}

class _DriverLicenseCardState extends ConsumerState<DriverLicenseCard> {
  final _picker = ImagePicker();
  bool _scanning = false;

  DriverLicenseInfo get _current {
    final saved = ref.read(driverLicenseProvider);
    if (saved != null) return saved;
    return DriverLicenseInfo(number: widget.serverLicenseNumber.trim());
  }

  Future<void> _scan() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!kOcrSupported) {
      messenger.showSnackBar(const SnackBar(
          content: Text('이 기기에서는 면허증 자동 인식을 지원하지 않습니다. 직접 입력해 주세요.')));
      await _edit(_current);
      return;
    }
    XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 95,
        maxWidth: 2400,
      );
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('카메라를 열 수 없습니다. 설정에서 카메라 권한을 확인해 주세요.')));
      return;
    }
    if (picked == null || !mounted) return;
    setState(() => _scanning = true);
    DriverLicenseInfo found;
    try {
      final text = await recognizeKoreanText(picked.path);
      found = DriverLicenseParser.parse(text);
    } catch (_) {
      found = const DriverLicenseInfo();
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    if (!mounted) return;

    // 읽은 값이 있으면 그 값, 없으면 기존 값을 채워서 확인 창을 연다
    final base = _current;
    final merged = DriverLicenseInfo(
      name: found.name.isNotEmpty ? found.name : base.name,
      number: found.number.isNotEmpty ? found.number : base.number,
      licenseType:
          found.licenseType.isNotEmpty ? found.licenseType : base.licenseType,
    );
    final readCount = [
      found.name,
      found.number,
      found.licenseType,
    ].where((v) => v.isNotEmpty).length;
    messenger.showSnackBar(SnackBar(
      content: Text(readCount == 0
          ? '면허증 글자를 읽지 못했습니다. 밝은 곳에서 면허증이 화면에 꽉 차게 다시 찍거나 직접 입력해 주세요.'
          : kOcrReadsKorean
              ? '면허증에서 $readCount개 항목을 읽었습니다. 확인 후 저장해 주세요.'
              : '면허번호를 읽었습니다. 이름과 면허 종류는 직접 입력해 주세요.'),
    ));
    await _edit(merged);
  }

  Future<void> _edit(DriverLicenseInfo initial) async {
    final name = TextEditingController(text: initial.name);
    final number = TextEditingController(text: initial.number);
    final type = TextEditingController(text: initial.licenseType);

    final result = await showDialog<DriverLicenseInfo>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: const Text('운전면허 정보',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '주민등록번호와 주소는 저장하지 않습니다. 읽힌 내용이 다르면 고친 뒤 저장해 주세요.',
                style: TextStyle(
                    color: AppTheme.textSub, fontSize: 12.5, height: 1.5),
              ),
              const SizedBox(height: 12),
              _field(name, '이름', '홍길동'),
              _field(number, '면허번호', '11-19-123456-78'),
              _field(type, '면허 종류', '1종 보통'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text('취소', style: TextStyle(color: AppTheme.textSub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              ctx,
              DriverLicenseInfo(
                name: name.text.trim(),
                number: number.text.trim(),
                licenseType: type.text.trim(),
              ),
            ),
            child: const Text('저장', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    Future.delayed(const Duration(milliseconds: 500), () {
      name.dispose();
      number.dispose();
      type.dispose();
    });
    if (result == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(driverLicenseProvider.notifier).save(result);
      await widget.onSaved(result);
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('운전면허 정보를 저장하지 못했습니다.')));
    }
  }

  Widget _field(TextEditingController c, String label, String hint) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        controller: c,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(color: AppTheme.textSub),
          hintStyle: const TextStyle(color: AppTheme.textHint),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(driverLicenseProvider);
    final info = saved ??
        (widget.serverLicenseNumber.trim().isEmpty
            ? null
            : DriverLicenseInfo(number: widget.serverLicenseNumber.trim()));
    final registered = info != null && !info.isEmpty;
    final shown = info ?? const DriverLicenseInfo();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.divider, width: 1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.surfaceDark,
                ),
                child: _scanning
                    ? const Padding(
                        padding: EdgeInsets.all(13),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Icon(
                        registered
                            ? Icons.badge_outlined
                            : Icons.add_card_outlined,
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
                      _scanning
                          ? '면허증 인식 중...'
                          : registered
                              ? (shown.name.isNotEmpty
                                  ? '${shown.name} · ${shown.number.isEmpty ? '면허번호 없음' : shown.number}'
                                  : (shown.number.isEmpty
                                      ? '면허번호 없음'
                                      : shown.number))
                              : '등록된 운전면허 없음',
                      style: TextStyle(
                        color: registered ? Colors.white : AppTheme.textSub,
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      registered
                          ? shown.licenseType.ifEmpty('면허 종류 미입력')
                          : '면허증을 촬영하면 자동으로 입력됩니다',
                      style: const TextStyle(
                        color: AppTheme.textHint,
                        fontSize: 12,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _pill(
                  icon: Icons.camera_alt_outlined,
                  label: '면허증 촬영',
                  filled: !registered,
                  onTap: _scanning ? null : _scan,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _pill(
                  icon: Icons.edit_outlined,
                  label: registered ? '변경' : '직접 입력',
                  filled: false,
                  onTap: _scanning ? null : () => _edit(_current),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pill({
    required IconData icon,
    required String label,
    required bool filled,
    VoidCallback? onTap,
  }) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: filled ? AppTheme.pointWhite : Colors.transparent,
            border: Border.all(
              color: filled ? AppTheme.pointWhite : const Color(0xFF3A3A3E),
            ),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 17, color: filled ? Colors.black : Colors.white),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: filled ? Colors.black : Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
