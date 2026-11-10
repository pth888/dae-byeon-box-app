// lib/utils/report_photo.dart
//
// 리포트(PDF)에 넣을 현장 사진을 작게 줄인다.
//   - 휴대폰 원본 사진(수 MB, 4000px 안팎)을 그대로 넣으면 PDF가 수십 MB가 되어
//     처음 열 때 보기 앱이 그림을 다 그리기 전에 화면을 보여주면서 글자가 깨져 보인다.
//   - 리포트에서 사진은 작은 칸(약 165x124pt)이라 긴 변 1000px 이면 인쇄에도 충분하다.
//   - 줄이는 데 실패하면 원본을 그대로 쓴다.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

Future<Uint8List> shrinkPhotoForReport(
  Uint8List bytes, {
  int maxSide = 1000,
  int quality = 80,
}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width;
    final h = descriptor.height;
    if (w <= maxSide && h <= maxSide && bytes.length <= 500 * 1024) {
      return bytes; // 이미 충분히 작다
    }
    // 한쪽만 정하면 가로세로 비율은 그대로 유지된다
    final codec = await descriptor.instantiateCodec(
      targetWidth: w >= h ? maxSide : null,
      targetHeight: h > w ? maxSide : null,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width;
    final height = image.height;
    image.dispose();
    codec.dispose();
    if (data == null) return bytes;
    // JPEG 압축은 화면이 멈추지 않게 별도 작업으로
    return await compute(
      _encodeJpeg,
      (data.buffer.asUint8List(), width, height, quality),
    );
  } catch (_) {
    return bytes;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Uint8List _encodeJpeg((Uint8List, int, int, int) args) {
  final (rgba, width, height, quality) = args;
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodeJpg(image, quality: quality);
}
