import Flutter
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Pinned Firebase Messaging observes UIApplication's launch notification.
    GeneratedPluginRegistrant.register(with: self)
    registerVisionOcr()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 면허증 OCR: 애플 기본 글자 인식(Vision)으로 한글까지 읽는다 (iOS 16 이상).
  /// 추가 라이브러리 없이 기기 안에서 처리하며, 사진을 밖으로 보내지 않는다.
  private func registerVisionOcr() {
    guard let registrar = self.registrar(forPlugin: "DaeByeonBoxVisionOcr") else { return }
    let channel = FlutterMethodChannel(
      name: "daebyeonbox/vision_ocr",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "recognize",
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      if #available(iOS 16.0, *) {
        VisionOcr.recognize(path: path, result: result)
      } else {
        result(FlutterError(code: "unsupported", message: "iOS 16 이상에서만 한글 인식을 지원합니다.", details: nil))
      }
    }
  }
}

@available(iOS 16.0, *)
private enum VisionOcr {
  static func recognize(path: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      guard let image = UIImage(contentsOfFile: path), let cgImage = image.cgImage else {
        DispatchQueue.main.async {
          result(FlutterError(code: "bad_image", message: "사진을 읽을 수 없습니다.", details: nil))
        }
        return
      }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["ko-KR", "en-US"]
      request.usesLanguageCorrection = false

      let handler = VNImageRequestHandler(
        cgImage: cgImage,
        orientation: CGImagePropertyOrientation(image.imageOrientation),
        options: [:]
      )
      do {
        try handler.perform([request])
        // 위에서 아래, 왼쪽에서 오른쪽 순서로 줄을 정렬한다
        let observations = (request.results ?? []).sorted { a, b in
          if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 {
            return a.boundingBox.midY > b.boundingBox.midY
          }
          return a.boundingBox.minX < b.boundingBox.minX
        }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        DispatchQueue.main.async { result(lines.joined(separator: "\n")) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "ocr_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }
}

private extension CGImagePropertyOrientation {
  init(_ orientation: UIImage.Orientation) {
    switch orientation {
    case .up: self = .up
    case .down: self = .down
    case .left: self = .left
    case .right: self = .right
    case .upMirrored: self = .upMirrored
    case .downMirrored: self = .downMirrored
    case .leftMirrored: self = .leftMirrored
    case .rightMirrored: self = .rightMirrored
    @unknown default: self = .up
    }
  }
}
