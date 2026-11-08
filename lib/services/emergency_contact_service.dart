// lib/services/emergency_contact_service.dart
//
// 비상 연락처(보호자) 저장
//   - 사고 후 응답이 없을 때 위치 문자를 받을 번호
//   - 휴대폰 안(보안 저장소)에만 저장하고 서버로 보내지 않는다
//   - 계정별로 따로 저장한다 (다른 계정으로 로그인하면 보이지 않음)

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_service.dart';
import 'case_service.dart' show authenticatedPrincipal;

class EmergencyContact {
  const EmergencyContact({required this.name, required this.phone});

  /// 이름 (비어 있을 수 있음)
  final String name;

  /// 숫자만 (예: 01012345678)
  final String phone;

  String get displayPhone => formatPhoneNumber(phone);

  /// "홍길동 (010-1234-5678)" 또는 "010-1234-5678"
  String get label => name.isEmpty ? displayPhone : '$name ($displayPhone)';
}

/// 입력값에서 숫자만 남기고, 휴대폰·일반 전화번호 형태가 아니면 null
String? normalizePhoneNumber(String input) {
  final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
  if (!RegExp(r'^0\d{8,10}$').hasMatch(digits)) return null;
  return digits;
}

/// 01012345678 → 010-1234-5678, 0212345678 → 02-1234-5678
String formatPhoneNumber(String digits) {
  if (digits.startsWith('02')) {
    if (digits.length == 9) {
      return '02-${digits.substring(2, 5)}-${digits.substring(5)}';
    }
    if (digits.length == 10) {
      return '02-${digits.substring(2, 6)}-${digits.substring(6)}';
    }
  }
  if (digits.length == 11) {
    return '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7)}';
  }
  if (digits.length == 10) {
    return '${digits.substring(0, 3)}-${digits.substring(3, 6)}-${digits.substring(6)}';
  }
  return digits;
}

class EmergencyContactNotifier extends StateNotifier<EmergencyContact?> {
  EmergencyContactNotifier(this._owner, {FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(),
        super(null) {
    _ready = _load();
  }

  final String? _owner;
  final FlutterSecureStorage _storage;
  late final Future<void> _ready;

  String? get _key =>
      _owner == null ? null : 'emergency_contact_v1:$_owner';

  /// 저장소에서 다 읽은 뒤의 연락처 (사고 직후 바로 쓸 때)
  Future<EmergencyContact?> current() async {
    await _ready;
    return state;
  }

  Future<void> _load() async {
    final key = _key;
    if (key == null) return;
    try {
      final phone = await _storage.read(key: '$key:phone');
      final name = await _storage.read(key: '$key:name');
      final normalized = phone == null ? null : normalizePhoneNumber(phone);
      if (normalized == null || !mounted) return;
      state = EmergencyContact(name: (name ?? '').trim(), phone: normalized);
    } catch (_) {
      // 저장소를 못 읽으면 미등록으로 둔다
    }
  }

  /// 저장. 번호 형식이 틀리면 false
  Future<bool> save({required String name, required String phone}) async {
    final key = _key;
    final normalized = normalizePhoneNumber(phone);
    if (key == null || normalized == null) return false;
    final trimmedName = name.trim();
    await _storage.write(key: '$key:phone', value: normalized);
    await _storage.write(key: '$key:name', value: trimmedName);
    if (mounted) {
      state = EmergencyContact(name: trimmedName, phone: normalized);
    }
    return true;
  }

  Future<void> clear() async {
    final key = _key;
    if (key == null) return;
    await _storage.delete(key: '$key:phone');
    await _storage.delete(key: '$key:name');
    if (mounted) state = null;
  }
}

final emergencyContactProvider =
    StateNotifierProvider<EmergencyContactNotifier, EmergencyContact?>((ref) {
  final owner = ref.watch(authProvider.select(authenticatedPrincipal));
  return EmergencyContactNotifier(owner);
});
