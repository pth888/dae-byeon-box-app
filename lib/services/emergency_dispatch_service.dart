// lib/services/emergency_dispatch_service.dart
//
// 사고 후 응답이 없을 때의 긴급 알림
//   - 119: 시연만 한다 (실제 신고는 하지 않음. 오감지로 인한 허위 신고 방지)
//   - 보호자: 안드로이드는 문자를 자동 발송 (SEND_SMS 권한 필요)
//             아이폰·아이패드는 운영체제가 앱의 자동 문자 발송을 막아서 시연 화면만 보여준다
//   - 블랙박스 테스트 충격이면 어떤 기기에서도 실제로 보내지 않는다


import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'emergency_contact_service.dart';

/// 보호자 문자 결과
enum GuardianSmsStatus {
  sent, // 실제 발송함 (안드로이드)
  simulated, // 시연 (아이폰·아이패드 또는 테스트 충격)
  noContact, // 비상 연락처 미등록
  permissionDenied, // 문자 권한 없음
  failed, // 발송 실패
}

class EmergencyLocation {
  const EmergencyLocation({
    required this.latitude,
    required this.longitude,
    this.address,
    this.isLastKnown = false,
  });

  final double latitude;
  final double longitude;
  final String? address;

  /// 현재 위치를 못 잡아 마지막으로 알려진 위치를 쓴 경우
  final bool isLastKnown;

  String get mapUrl =>
      'https://maps.google.com/?q=${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}';
}

class EmergencyDispatchResult {
  const EmergencyDispatchResult({
    required this.at,
    required this.message,
    required this.location,
    required this.contact,
    required this.guardian,
    required this.demoReason,
  });

  final DateTime at;
  final String message;
  final EmergencyLocation? location;
  final EmergencyContact? contact;
  final GuardianSmsStatus guardian;

  /// 실제 발송이 없었던 이유 (없으면 실제 발송 시도함)
  final String? demoReason;
}

class EmergencyDispatcher {
  static const _channel = MethodChannel('daebyeonbox/emergency_sms');

  /// 이 기기에서 앱이 문자를 직접 보낼 수 있는지 (안드로이드만)
  static bool get canSendAutomatically => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 문자 권한 요청 (비상 연락처 등록할 때 미리 받아 둔다)
  static Future<bool> requestSmsPermission() async {
    if (!canSendAutomatically) return false;
    try {
      return (await Permission.sms.request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> hasSmsPermission() async {
    if (!canSendAutomatically) return false;
    try {
      return (await Permission.sms.status).isGranted;
    } catch (_) {
      return false;
    }
  }

  /// 응답이 없을 때 실행. 위치를 잡고 보호자에게 보낸다.
  Future<EmergencyDispatchResult> dispatch({
    required EmergencyContact? contact,
    required bool testEvent,
  }) async {
    final at = DateTime.now();
    final location = await _locate();
    final message = buildMessage(at: at, location: location);

    String? demoReason;
    if (testEvent) {
      demoReason = '블랙박스 테스트 충격이라 실제로 보내지 않았습니다.';
    } else if (!canSendAutomatically) {
      demoReason = '아이폰·아이패드는 운영체제 정책상 앱이 문자를 자동으로 보낼 수 없어 시연 화면으로 보여줍니다.';
    }

    GuardianSmsStatus guardian;
    if (contact == null) {
      guardian = GuardianSmsStatus.noContact;
    } else if (demoReason != null) {
      guardian = GuardianSmsStatus.simulated;
    } else if (!await hasSmsPermission()) {
      guardian = GuardianSmsStatus.permissionDenied;
    } else {
      guardian = await _send(contact.phone, message);
    }

    return EmergencyDispatchResult(
      at: at,
      message: message,
      location: location,
      contact: contact,
      guardian: guardian,
      demoReason: demoReason,
    );
  }

  static String buildMessage({
    required DateTime at,
    required EmergencyLocation? location,
  }) {
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
    final lines = <String>[
      '[Dae-Byeon-BOX 긴급 알림]',
      '교통사고로 의심되는 충격이 감지됐고 운전자가 응답하지 않습니다.',
      if (location?.address != null && location!.address!.isNotEmpty)
        '주소: ${location.address}',
      location == null ? '위치: 확인 불가' : '위치: ${location.mapUrl}',
      '발생 시각: $time',
    ];
    return lines.join('\n');
  }

  Future<GuardianSmsStatus> _send(String phone, String message) async {
    try {
      final ok = await _channel.invokeMethod<bool>('send', {
        'phone': phone,
        'message': message,
      });
      return ok == true ? GuardianSmsStatus.sent : GuardianSmsStatus.failed;
    } on PlatformException catch (error) {
      if (error.code == 'no_permission') {
        return GuardianSmsStatus.permissionDenied;
      }
      return GuardianSmsStatus.failed;
    } catch (_) {
      return GuardianSmsStatus.failed;
    }
  }

  /// 위치 권한이 이미 있을 때만 잡는다 (쓰러진 사람에게 권한 창을 띄우지 않음)
  Future<EmergencyLocation?> _locate() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      Position? position;
      var lastKnown = false;
      try {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 6),
        );
      } catch (_) {
        position = null;
      }
      if (position == null) {
        try {
          position = await Geolocator.getLastKnownPosition();
          lastKnown = position != null;
        } catch (_) {
          position = null;
        }
      }
      if (position == null) return null;
      final address = await _address(position.latitude, position.longitude);
      return EmergencyLocation(
        latitude: position.latitude,
        longitude: position.longitude,
        address: address,
        isLastKnown: lastKnown,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _address(double lat, double lon) async {
    try {
      final places = await placemarkFromCoordinates(lat, lon)
          .timeout(const Duration(seconds: 3));
      if (places.isEmpty) return null;
      final p = places.first;
      final parts = <String?>[
        p.administrativeArea,
        p.locality,
        p.subLocality,
        p.thoroughfare,
        p.subThoroughfare,
      ]
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      // 같은 말이 겹치는 경우 정리 (예: 서울특별시 서울특별시)
      final unique = <String>[];
      for (final part in parts) {
        if (!unique.contains(part)) unique.add(part);
      }
      return unique.isEmpty ? null : unique.join(' ');
    } catch (_) {
      return null;
    }
  }
}

final emergencyDispatcherProvider =
    Provider<EmergencyDispatcher>((ref) => EmergencyDispatcher());
