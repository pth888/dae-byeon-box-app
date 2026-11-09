# DriveGuard App

## English

This repository contains the root-level Flutter mobile client. The backend is
deployed separately; see [current runtime handoff](docs/mobile-runtime-handoff-20261109.md)
for required API contracts and verification limits.
This is a normal directory, not a Git submodule. Original source: `pth888/driveguard-ai`
base `92fbec0a`, with model-input changes from `7b386b8`.

From this repository root:

```bash
flutter pub get
flutter test
flutter run --dart-define=API_BASE_URL=https://<private-api-host>
```

Use a compatible Flutter/Dart toolchain; verified with Flutter 3.47.7 and
Dart 3.13.5. Follow [App Handoff](handoff.md) and [Backend Handoff](../backend/handoff.md)
before connecting a phone. Tests passing does not certify APK/iOS builds.

The default API origin in `lib/services/auth_service.dart` is emulator-only
`http://10.0.2.2:8000`; configure `API_BASE_URL` with a reachable private origin for other computers
or phones. MinIO 9000 is storage, not LAW. Real model and LAW analysis use
separate configured inference services. Chat supports Gemini or Groq; current
weather supports Open-Meteo, and road/address estimation supports Kakao Local.
These providers do not enable themselves. See the root [architecture](../diagram.md).

Implemented: eight road choices, signal/roundabout other-car questions, exact
backend job/report polling, canonical B/A values with friendly display labels, unavailable states and safe
PDF export. Owned case entry, photo/audio evidence, server history, chat,
profiles, consent and deletion are connected. Notifications route to the
accident countdown with the owned case ID. FCM registration and optional server
delivery are implemented; simulator notification injection is not physical-phone
FCM certification. Collector sharing remains explicitly configured and does not
grant arbitrary access to another user's private case.

No `.env`, server credentials, signing keys, build directories, SDK caches or
nested `.git` are included. Existing Firebase client configuration belongs to
the original app project; it is not a Firebase Admin service-account key.
Coordinate app project/platform setup with the app owner. The imported tree
retains the original optional macOS-plugin warning. Empty declared asset folders
are tracked. The standard Android Gradle wrapper is included.

Run `flutter pub get` before iOS dependency resolution. Do not reuse simulator
generated plugin registrants or an OCR-excluding local Pod lock for physical
devices. Resolve Pods on the target machine; ML Kit requires a supported physical
device/toolchain and may prevent a full arm64 Simulator build. The previously
shown Simulator used local generated-file adjustments, not a portable release
build. Signing/entitlements and real-device acceptance must be checked separately.

## 한국어

이 저장소는 루트에 Flutter 앱 소스를 두며, 백엔드는 별도로 배포한다.
서브모듈이 아니다. 위 명령은 이 저장소 루트에서 실행한다.
앱·백엔드 핸드오프를 먼저 읽고 휴대폰용 사설 API/저장소 주소와 인증·장치 매핑을 맞춘다.
실제 환경 파일·서버 인증·서명키·빌드/캐시 파일은 제외했다.

8개 도로·추가 질문·모델 재분석·작업별 리포트·PDF와 사건 진입·사진/음성·서버 이력·
대화·프로필·삭제를 연결했다. 로컬 UUID·전역 최신 영상 선택은 제거했다.
실제 모델·LAW 서비스와 Gemini/Groq 상담, Open-Meteo 현재 기상, Kakao 도로 추정은
설정 후 사용할 수 있다. 알림은 소유한 사건의 사고 카운트다운으로 연결하며 FCM 실제
발송 경로도 구현했다. 시뮬레이터 주입 알림과 실기기 FCM 검증은 구분한다.

Android 표준 Gradle 실행 파일을 포함했다. iOS는 먼저 flutter pub get을 실행하고
대상 컴퓨터에서 Pods를 해결한다. 시뮬레이터에서 사용한 로컬 생성 파일·OCR 제외
Pod 잠금 파일은 배포 설정으로 재사용하지 않는다. ML Kit의 기기·도구 지원 제한으로
전체 arm64 시뮬레이터 빌드가 막힐 수 있으며 실기기 서명·권한·설치는 별도 검증한다.
API_BASE_URL과 접근 가능한 저장소 주소를 설정하고 handoff.md를 따른다.
