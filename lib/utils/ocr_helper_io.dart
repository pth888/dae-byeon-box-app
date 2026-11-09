// lib/utils/ocr_helper_io.dart
// 네이티브(Android/iOS) 전용 OCR 구현.
//
// iOS(아이폰·아이패드): 애플 기본 글자 인식(Vision)으로 한글·숫자를 읽는다 (iOS 16 이상).
//   ios/Runner/AppDelegate.swift 의 'daebyeonbox/vision_ocr' 채널.
//   ML Kit 한국어 모델은 iOS 에서 앱 종료 문제가 있어 쓰지 않는다.
//   Vision 을 쓸 수 없으면 ML Kit 기본 모델(영문·숫자)로 읽는다.
// Android: ML Kit 한국어 모델 (build.gradle.kts 에 text-recognition-korean 포함).
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

const _visionChannel = MethodChannel('daebyeonbox/vision_ocr');

bool _iosKoreanAvailable = true;

/// 이미지 파일에서 글자를 인식해 반환한다.
Future<String> recognizeKoreanText(String imagePath) async {
  if (Platform.isIOS) {
    try {
      final text = await _visionChannel
          .invokeMethod<String>('recognize', {'path': imagePath});
      _iosKoreanAvailable = true;
      return text ?? '';
    } catch (_) {
      // iOS 16 미만 등: 숫자만이라도 읽는다
      _iosKoreanAvailable = false;
      return _mlKit(imagePath, TextRecognitionScript.latin);
    }
  }
  return _mlKit(imagePath, TextRecognitionScript.korean);
}

Future<String> _mlKit(String imagePath, TextRecognitionScript script) async {
  final recognizer = TextRecognizer(script: script);
  try {
    final recognized = await recognizer.processImage(InputImage.fromFilePath(imagePath));
    return recognized.text;
  } finally {
    await recognizer.close();
  }
}

/// 마지막 인식에서 한글(이름·면허 종류)까지 읽을 수 있었는지
bool get kOcrReadsKorean => !Platform.isIOS || _iosKoreanAvailable;

/// 이 플랫폼에서 OCR 사용 가능 여부.
const bool kOcrSupported = true;
