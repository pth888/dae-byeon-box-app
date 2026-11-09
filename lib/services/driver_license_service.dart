// lib/services/driver_license_service.dart
//
// 운전면허증 정보 (마이페이지 · 운전면허 카드)
//   - 면허증 사진을 OCR(ML Kit 한국어)로 읽어 이름·면허번호·면허 종류·적성검사(갱신) 기간을 채운다.
//   - 주민등록번호와 주소는 읽더라도 저장하지 않는다.
//   - 휴대폰 보안 저장소에 계정별로 저장한다. 면허번호는 기존처럼 서버 프로필에도 저장된다.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_service.dart';
import 'case_service.dart' show authenticatedPrincipal;

class DriverLicenseInfo {
  const DriverLicenseInfo({
    this.name = '',
    this.number = '',
    this.licenseType = '',
    this.renewalPeriod = '',
  });

  /// 이름
  final String name;

  /// 면허번호 (예: 11-19-123456-78)
  final String number;

  /// 면허 종류 (예: 1종 보통)
  final String licenseType;

  /// 적성검사·갱신 기간 (예: 2025.01.01 ~ 2025.12.31)
  final String renewalPeriod;

  bool get isEmpty =>
      name.isEmpty &&
      number.isEmpty &&
      licenseType.isEmpty &&
      renewalPeriod.isEmpty;

  DriverLicenseInfo copyWith({
    String? name,
    String? number,
    String? licenseType,
    String? renewalPeriod,
  }) =>
      DriverLicenseInfo(
        name: name ?? this.name,
        number: number ?? this.number,
        licenseType: licenseType ?? this.licenseType,
        renewalPeriod: renewalPeriod ?? this.renewalPeriod,
      );

  Map<String, String> toJson() => {
        'name': name,
        'number': number,
        'license_type': licenseType,
        'renewal_period': renewalPeriod,
      };

  static DriverLicenseInfo fromJson(Map<String, dynamic> json) =>
      DriverLicenseInfo(
        name: (json['name'] as String?) ?? '',
        number: (json['number'] as String?) ?? '',
        licenseType: (json['license_type'] as String?) ?? '',
        renewalPeriod: (json['renewal_period'] as String?) ?? '',
      );
}

// ── OCR 글자 → 면허 정보 ───────────────────────────────────
class DriverLicenseParser {
  static const _regions = [
    '서울', '부산', '경기', '강원', '충북', '충남', '전남', '경북', '경남', '제주',
    '대구', '인천', '광주', '대전', '울산', '전북', '세종',
  ];

  /// 이름으로 오인하기 쉬운 면허증 위 글자
  static const _notNames = {
    '자동차', '운전면허', '면허증', '보통', '대형', '소형', '특수', '원동기',
    '적성검사', '갱신기간', '발급일', '경찰청장', '주소', '조건', '기간',
    '면허번호', '운전', '한국', '대한민국', '견인', '구난', '수시',
  };

  static DriverLicenseInfo parse(String raw) {
    final text = raw.replaceAll('\r', '');
    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return DriverLicenseInfo(
      number: _number(text),
      licenseType: _types(text),
      renewalPeriod: _period(text),
      name: _name(lines),
    );
  }

  /// 면허번호: "11-19-123456-78" 또는 예전 형식 "서울 19-123456-78"
  static String _number(String text) {
    // OCR 이 하이픈을 다른 문자로 읽는 경우가 많아 공백·여러 대시를 허용한다
    const sep = r'[\s\-–—_.]*';
    final numeric = RegExp('(?<!\\d)(\\d{2})$sep(\\d{2})$sep(\\d{6})$sep(\\d{2})(?!\\d)');
    final m = numeric.firstMatch(text);
    if (m != null) {
      return '${m[1]}-${m[2]}-${m[3]}-${m[4]}';
    }
    final regional = RegExp(
        '(${_regions.join('|')})$sep(\\d{2})$sep(\\d{6})$sep(\\d{2})(?!\\d)');
    final r = regional.firstMatch(text);
    if (r != null) {
      return '${r[1]} ${r[2]}-${r[3]}-${r[4]}';
    }
    return '';
  }

  /// 면허 종류: 1종 대형/보통/소형, 2종 보통/소형, 원동기, 특수 등 (여러 개면 · 로 묶음)
  static String _types(String text) {
    final found = <String>[];
    final re = RegExp(r'([12])\s*종\s*(대형|보통|소형|특수|원동기)');
    for (final m in re.allMatches(text)) {
      final v = '${m[1]}종 ${m[2]}';
      if (!found.contains(v)) found.add(v);
    }
    if (found.isEmpty && RegExp(r'원동기').hasMatch(text)) found.add('2종 원동기');
    return found.join(' · ');
  }

  /// 적성검사·갱신 기간: "2025.01.01 ~ 2025.12.31"
  static String _period(String text) {
    const d = r'(\d{4})\s*[.\-/년]\s*(\d{1,2})\s*[.\-/월]\s*(\d{1,2})\s*일?';
    final re = RegExp('$d\\s*[~～\\-–]\\s*$d');
    final m = re.firstMatch(text);
    if (m == null) return '';
    String two(String? v) => (v ?? '').padLeft(2, '0');
    return '${m[1]}.${two(m[2])}.${two(m[3])} ~ ${m[4]}.${two(m[5])}.${two(m[6])}';
  }

  /// 이름: 한글 2~4자만 있는 줄 중 면허증 고정 문구가 아닌 첫 줄
  static String _name(List<String> lines) {
    final re = RegExp(r'^[가-힣]{2,4}$');
    for (final line in lines) {
      final compact = line.replaceAll(' ', '');
      if (!re.hasMatch(compact)) continue;
      if (_notNames.any(compact.contains)) continue;
      if (_regions.contains(compact)) continue;
      return compact;
    }
    return '';
  }
}

// ── 저장 ────────────────────────────────────────────────────
class DriverLicenseNotifier extends StateNotifier<DriverLicenseInfo?> {
  DriverLicenseNotifier(this._owner, {FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(),
        super(null) {
    _load();
  }

  final String? _owner;
  final FlutterSecureStorage _storage;

  String? get _key => _owner == null ? null : 'driver_license_v1:$_owner';

  Future<void> _load() async {
    final key = _key;
    if (key == null) return;
    try {
      final raw = await _storage.read(key: key);
      if (raw == null || !mounted) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final info =
            DriverLicenseInfo.fromJson(Map<String, dynamic>.from(decoded));
        if (!info.isEmpty) state = info;
      }
    } catch (_) {
      // 읽지 못하면 미등록으로 둔다
    }
  }

  Future<void> save(DriverLicenseInfo info) async {
    final key = _key;
    if (key == null) return;
    await _storage.write(key: key, value: jsonEncode(info.toJson()));
    if (mounted) state = info.isEmpty ? null : info;
  }

  Future<void> clear() async {
    final key = _key;
    if (key == null) return;
    await _storage.delete(key: key);
    if (mounted) state = null;
  }
}

final driverLicenseProvider =
    StateNotifierProvider<DriverLicenseNotifier, DriverLicenseInfo?>((ref) {
  final owner = ref.watch(authProvider.select(authenticatedPrincipal));
  return DriverLicenseNotifier(owner);
});
