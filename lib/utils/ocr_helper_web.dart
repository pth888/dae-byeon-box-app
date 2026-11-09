// lib/utils/ocr_helper_web.dart
// 웹 전용 OCR 스텁 — Google ML Kit은 웹을 지원하지 않으므로 OCR을 비활성화한다.
// (웹은 결과 조회·표시 전용. 면허증 인식은 네이티브 앱에서만 제공.)

/// 웹에서는 OCR 미지원 — 빈 문자열을 반환한다.
Future<String> recognizeKoreanText(String imagePath) async => '';

/// 이 플랫폼에서 OCR 사용 가능 여부.
const bool kOcrSupported = false;

/// 웹에서는 한글 인식도 지원하지 않는다.
bool get kOcrReadsKorean => false;
