// lib/services/accident_type_catalog.dart
//
// 사고 유형 번호(모델 type_topk 의 code) → 사고 유형 설명
// 원본: assets/data/accident_types.json  {"번호": {"A": 상대 과실, "B": 우리 과실, "desc": "..."}}
//
// desc 는 과실비율 인정기준표를 옮기면서 일부 칸이 잘려 있다
// (예: "사거리교차로(신 | ...", "호등 없음) | ..."). 화면에 보여줄 때 다듬는다.
//   - 마지막 두 칸: A(상대) 행동, B(우리) 행동
//   - 앞 칸들: 도로·사고 상황

import 'dart:convert';

import 'package:flutter/services.dart';

class AccidentTypeInfo {
  const AccidentTypeInfo({
    required this.code,
    required this.title,
    required this.ourAction,
    required this.otherAction,
    required this.baseOurPct,
    required this.baseOtherPct,
  });

  final int code;

  /// 도로·사고 상황 (예: "사거리 교차로(신호등 있음) · 상대 차량이 맞은편 방향에서 진입")
  final String title;

  /// 우리 차량(B) 행동
  final String ourAction;

  /// 상대(A) 행동
  final String otherAction;

  /// 인정기준표의 기본 과실 (우리 = B, 상대 = A)
  final int baseOurPct;
  final int baseOtherPct;

  /// 한 줄 설명 (리포트 표의 두 번째 줄)
  String get detail => '우리 차량: $ourAction · 상대: $otherAction';
}

class AccidentTypeCatalog {
  AccidentTypeCatalog._(this._items);

  final Map<int, AccidentTypeInfo> _items;

  static AccidentTypeCatalog? _cache;

  static Future<AccidentTypeCatalog> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    try {
      final raw = await rootBundle.loadString('assets/data/accident_types.json');
      final decoded = jsonDecode(raw);
      final items = <int, AccidentTypeInfo>{};
      if (decoded is Map) {
        decoded.forEach((key, value) {
          final code = int.tryParse('$key');
          if (code == null || value is! Map) return;
          final info = _parse(code, value);
          if (info != null) items[code] = info;
        });
      }
      return _cache = AccidentTypeCatalog._(items);
    } catch (_) {
      // 파일을 못 읽어도 리포트는 번호로 만든다.
      return AccidentTypeCatalog._(const {});
    }
  }

  AccidentTypeInfo? operator [](int code) => _items[code];

  // ── desc 다듬기 ───────────────────────────────────────────
  static const _categoryWords = {'차대차', '차대보행자', '차대이륜차'};

  /// 잘린 머리말 → 읽을 수 있는 표현
  static const _heads = <String, String>{
    '사거리교차로(신': '',
    '교차로(신호등': '교차로',
    '횡단보도(신호등': '횡단보도',
    '고속도로(자동차': '고속도로',
    '주차장(또는': '주차장',
    '차도와 차도가': '차도가 아닌 장소',
    '아닌 장소': '차도가 아닌 장소',
    '사거리': '사거리 교차로',
  };

  static AccidentTypeInfo? _parse(int code, Map value) {
    final a = value['A'];
    final b = value['B'];
    final desc = value['desc'];
    if (a is! num || b is! num || desc is! String) return null;

    final parts = desc
        .split('|')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length < 2) return null;

    // 마지막 두 칸 = 상대(A) 행동, 우리(B) 행동
    final otherAction = _tidyAction(parts[parts.length - 2]);
    final ourAction = _tidyAction(parts[parts.length - 1]);

    final context = <String>[];
    final place = _placeFor(code);
    if (place != null) context.add(place);
    for (final part in parts.sublist(0, parts.length - 2)) {
      if (_categoryWords.contains(part)) continue;
      // "호등 없음)", "있음) 부근", "전용도로)포함" 처럼 앞이 잘린 조각은 버린다
      if (_isCutFragment(part)) continue;
      final mapped = _heads[part] ?? part;
      if (mapped.isEmpty) continue;
      if (place != null &&
          (place.contains(mapped) ||
              (mapped.contains('교차로') && place.contains('교차로')))) {
        continue;
      }
      if (!context.contains(mapped)) context.add(mapped);
    }

    return AccidentTypeInfo(
      code: code,
      title: context.isEmpty ? '사고 유형 $code' : context.join(' · '),
      ourAction: ourAction,
      otherAction: otherAction,
      baseOurPct: b.toInt(),
      baseOtherPct: a.toInt(),
    );
  }

  /// 번호 구간으로 알 수 있는 도로 형태 (원본에서 잘린 부분 보완)
  static String? _placeFor(int code) {
    if (code >= 21 && code <= 59) return '사거리 교차로(신호등 없음)';
    if (code >= 60 && code <= 105) return '사거리 교차로(신호등 있음)';
    if (code >= 133 && code <= 186) return '차대보행자';
    if (code >= 187 && code <= 198) return '고속도로(자동차전용도로 포함)';
    if (code >= 199) return '차대이륜차';
    return null;
  }

  static bool _isCutFragment(String part) {
    final open = '('.allMatches(part).length;
    final close = ')'.allMatches(part).length;
    return close > open && part.indexOf(')') < 6;
  }

  static String _tidyAction(String action) {
    var text = action.trim();
    // 끝에 남은 쉼표 정리
    while (text.endsWith(',')) {
      text = text.substring(0, text.length - 1).trim();
    }
    return text.isEmpty ? '-' : text;
  }
}
