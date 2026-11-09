import 'dart:async';

import 'package:blackbox_driver_care/router/app_router.dart';
import 'package:blackbox_driver_care/screens/accident/first_response_screen.dart';
import 'package:blackbox_driver_care/screens/home/main_page.dart';
import 'package:blackbox_driver_care/services/auth_service.dart';
import 'package:blackbox_driver_care/services/blackbox_video_service.dart';
import 'package:blackbox_driver_care/services/case_service.dart';
import 'package:blackbox_driver_care/services/consent_service.dart';
import 'package:blackbox_driver_care/services/location_service.dart';
import 'package:blackbox_driver_care/services/sensor_service.dart';
import 'package:blackbox_driver_care/widgets/blackbox_video_player_widget.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('latest video hides a prior ready video during owner validation',
      (tester) async {
    final pending = Completer<BackendCase>();
    final video = _RecordingVideoNotifier(seedReady: true);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _SignedInAuth()),
        caseServiceProvider.overrideWithValue(
          _FakeCaseService(ownedFuture: pending.future),
        ),
        blackboxVideoProvider.overrideWith((ref) => video),
      ],
      child: const MaterialApp(
        home: FirstResponseScreen(accidentId: caseB, initialVideoStep: true),
      ),
    ));
    await tester.pump();
    expect(find.byType(BlackboxVideoPlayerWidget), findsNothing);
    expect(find.text('영상 수신 완료'), findsNothing);
    pending.complete(_backendCase(caseB));
    await tester.pumpAndSettle();
    expect(find.byType(BlackboxVideoPlayerWidget), findsNothing);
    expect(video.requestedCaseIds, [caseB]);
  });

  testWidgets('failed owner validation never exposes a prior ready video',
      (tester) async {
    final video = _RecordingVideoNotifier(seedReady: true);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _SignedInAuth()),
        caseServiceProvider.overrideWithValue(
          _FakeCaseService(ownedError: const CaseAuthenticationException()),
        ),
        blackboxVideoProvider.overrideWith((ref) => video),
      ],
      child: const MaterialApp(
        home: FirstResponseScreen(accidentId: caseB, initialVideoStep: true),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(BlackboxVideoPlayerWidget), findsNothing);
    expect(find.text('영상 수신 완료'), findsNothing);
    expect(find.text('사고 사건을 확인할 수 없습니다'), findsOneWidget);
    expect(video.requestedCaseIds, isEmpty);
  });

  testWidgets('main latest-video entry opens the exact returned hardware case',
      (tester) async {
    final service = _FakeCaseService(latest: _backendCase(caseB));
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const MainPage()),
        GoRoute(
          path: '/response',
          name: 'first-response',
          builder: (_, state) {
            final extra = state.extra as Map<String, dynamic>;
            return Text(
              'response:${extra['case_id']}:${extra['initial_video_step']}',
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(_testApp(service: service, router: router));
    await tester.pump();
    await tester.tap(find.text('최신 블랙박스 영상 보기'));
    await tester.pumpAndSettle();

    expect(find.text('response:$caseB:true'), findsOneWidget);
  });

  testWidgets('fresh MQTT shock opens the accident countdown immediately',
      (tester) async {
    final service = _FakeCaseService();
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const MainPage()),
        GoRoute(
          path: '/accident-detected',
          name: 'accident-detected',
          builder: (_, state) {
            final event = state.extra as Map<String, dynamic>;
            return Text(
              'countdown:${event['case_id']}:${event['impact_g']}:${event['device_name']}',
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(_testApp(service: service, router: router));
    await tester.pumpAndSettle();
    service.hardwareEvents.add(BackendHardwareEvent(
      eventId: 'shock-live-1',
      deviceId: 'dev_owned',
      sourceDeviceId: 'violet-dashcam-1',
      deviceName: '전방 블랙박스',
      triggeredAt: DateTime.now().toUtc(),
      source: 'adxl345',
      isTestEvent: false,
      impactG: 1.8,
    ));

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('countdown:null:1.8:전방 블랙박스'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
      'manual entry offers the owned latest video and opens its countdown',
      (tester) async {
    final service = _FakeCaseService(latest: _backendCase(caseB));
    final router = _manualEntryRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(_testApp(service: service, router: router));
    await tester.pump();
    await tester.tap(find.text('사고 접수 시작'));
    await tester.pumpAndSettle();

    expect(find.text('수신된 블랙박스 영상이 있습니다'), findsOneWidget);
    expect(find.textContaining('2026.10.16'), findsOneWidget);
    expect(find.textContaining('블랙박스 영상입니다.'), findsOneWidget);
    expect(find.textContaining('dev_owned'), findsNothing);

    await tester.tap(find.text('수신 영상 사용'));
    await tester.pumpAndSettle();

    expect(find.text('countdown:$caseB'), findsOneWidget);
    expect(service.latestCalls, 1);
  });

  testWidgets('manual entry can decline the latest video and start a new case',
      (tester) async {
    final service = _FakeCaseService(latest: _backendCase(caseB));
    final router = _manualEntryRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(_testApp(service: service, router: router));
    await tester.pump();
    await tester.tap(find.text('사고 접수 시작'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('영상 없이 새 사고 접수'));
    await tester.pumpAndSettle();

    expect(find.text('countdown:null'), findsOneWidget);
    expect(service.latestCalls, 1);
  });

  testWidgets(
      'manual entry explains no received video before the new-case path',
      (tester) async {
    final service = _FakeCaseService();
    final router = _manualEntryRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(_testApp(service: service, router: router));
    await tester.pump();
    await tester.tap(find.text('사고 접수 시작'));
    await tester.pumpAndSettle();

    expect(find.text('수신된 영상이 없습니다'), findsOneWidget);
    expect(find.textContaining('새 사고에는 원본 영상이 아직 없습니다'), findsOneWidget);

    await tester.tap(find.text('영상 없이 새 사고 접수'));
    await tester.pumpAndSettle();
    expect(find.text('countdown:null'), findsOneWidget);
  });

  testWidgets('manual latest-video API error never starts a fake new case',
      (tester) async {
    final service = _FakeCaseService(
      error: const CaseServiceException('최신 영상을 확인할 수 없습니다.'),
    );
    final router = _manualEntryRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(_testApp(service: service, router: router));
    await tester.pump();
    await tester.tap(find.text('사고 접수 시작'));
    await tester.pumpAndSettle();

    expect(find.text('최신 영상을 확인할 수 없습니다.'), findsOneWidget);
    expect(find.textContaining('countdown:'), findsNothing);
  });

  testWidgets('manual latest-video result is discarded after owner changes',
      (tester) async {
    final pending = Completer<BackendCase?>();
    final service = _FakeCaseService(latestFuture: pending.future);
    final auth = _SwitchableAuth();
    final router = _manualEntryRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _testApp(service: service, router: router, auth: auth),
    );
    await tester.pump();
    await tester.tap(find.text('사고 접수 시작'));
    await tester.pump();

    auth.switchTo('other@example.com');
    pending.complete(_backendCase(caseB));
    await tester.pumpAndSettle();

    expect(find.text('수신된 블랙박스 영상이 있습니다'), findsNothing);
    expect(find.textContaining('countdown:'), findsNothing);
  });

  testWidgets('manual latest-video result is discarded after logout',
      (tester) async {
    final pending = Completer<BackendCase?>();
    final service = _FakeCaseService(latestFuture: pending.future);
    final auth = _SwitchableAuth();
    final router = _manualEntryRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _testApp(service: service, router: router, auth: auth),
    );
    await tester.pump();
    await tester.tap(find.text('사고 접수 시작'));
    await tester.pump();

    auth.signOutForTest();
    pending.complete(_backendCase(caseB));
    await tester.pumpAndSettle();

    expect(find.text('수신된 블랙박스 영상이 있습니다'), findsNothing);
    expect(find.textContaining('countdown:'), findsNothing);
  });

  testWidgets('main latest-video entry keeps the page on no file',
      (tester) async {
    final service = _FakeCaseService();
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const MainPage()),
        GoRoute(
          path: '/response',
          name: 'first-response',
          builder: (_, __) => const Text('unexpected navigation'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(_testApp(service: service, router: router));
    await tester.pump();
    await tester.tap(find.text('최신 블랙박스 영상 보기'));
    await tester.pumpAndSettle();

    expect(find.textContaining('수신 완료된 블랙박스 영상이 없습니다'), findsOneWidget);
    expect(find.text('unexpected navigation'), findsNothing);
  });

  testWidgets('main latest-video entry disables overlapping loads',
      (tester) async {
    final pending = Completer<BackendCase?>();
    final service = _FakeCaseService(latestFuture: pending.future);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const MainPage()),
        GoRoute(
          path: '/response',
          name: 'first-response',
          builder: (_, __) => const Text('unexpected navigation'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(_testApp(service: service, router: router));
    await tester.pump();
    await tester.tap(find.text('최신 블랙박스 영상 보기'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('최신 블랙박스 영상 보기'));
    await tester.pump();
    expect(service.latestCalls, 1);

    pending.complete(null);
    await tester.pumpAndSettle();
    expect(find.textContaining('수신 완료된 블랙박스 영상이 없습니다'), findsOneWidget);
  });

  testWidgets('main latest-video entry exposes auth errors without navigating',
      (tester) async {
    final service =
        _FakeCaseService(error: const CaseAuthenticationException());
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const MainPage()),
        GoRoute(
          path: '/response',
          name: 'first-response',
          builder: (_, __) => const Text('unexpected navigation'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(_testApp(service: service, router: router));
    await tester.pump();
    await tester.tap(find.text('최신 블랙박스 영상 보기'));
    await tester.pumpAndSettle();

    expect(find.text('로그인이 필요합니다.'), findsOneWidget);
    expect(find.text('unexpected navigation'), findsNothing);
  });

  testWidgets(
      'waiting video offers explicit latest-case recovery without fallback',
      (tester) async {
    final service = _FakeCaseService(latest: _backendCase(caseB));
    final video = _RecordingVideoNotifier();
    late GoRouter router;
    router = GoRouter(
      initialLocation: '/response',
      routes: [
        GoRoute(
          path: '/response',
          name: 'first-response',
          builder: (_, state) {
            final extra = state.extra;
            final caseId = extra is Map<String, dynamic>
                ? extra['case_id'] as String
                : caseA;
            final initialVideoStep = extra is Map<String, dynamic> &&
                extra['initial_video_step'] == true;
            return FirstResponseScreen(
              key: ValueKey(caseId),
              accidentId: caseId,
              initialVideoStep: initialVideoStep || caseId == caseA,
            );
          },
        ),
        GoRoute(
          path: '/analysis',
          name: 'analysis',
          builder: (_, state) => Text('analysis:${state.extra}'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(_testApp(
      service: service,
      router: router,
      video: video,
    ));
    await tester.pumpAndSettle();
    expect(find.text('원본 영상 준비 대기 중'), findsOneWidget);

    final screen = tester.widget<FirstResponseScreen>(
      find.byType(FirstResponseScreen),
    );
    expect(screen.accidentId, caseA);
    expect(find.text('최신 수신 영상 보기'), findsOneWidget);
    expect(video.requestedCaseIds, [caseA]);

    await tester.tap(find.text('AI 과실 분석 시작'));
    await tester.pumpAndSettle();

    expect(find.text('analysis:$caseA'), findsNothing);
    expect(find.byType(FirstResponseScreen), findsOneWidget);

    await tester.ensureVisible(find.text('최신 수신 영상 보기'));
    await tester.tap(find.text('최신 수신 영상 보기'));
    await tester.pumpAndSettle();

    final recovered = tester.widget<FirstResponseScreen>(
      find.byType(FirstResponseScreen),
    );
    expect(recovered.accidentId, caseB);
    expect(recovered.initialVideoStep, isTrue);
    expect(video.requestedCaseIds, containsAllInOrder([caseA, caseB]));
  });

  testWidgets('production route recreates FirstResponse when case ID changes',
      (tester) async {
    final service = _FakeCaseService();
    final video = _RecordingVideoNotifier();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _SignedInAuth()),
          consentControllerProvider.overrideWith(
            (ref) => _GrantedConsentController(),
          ),
          locationProvider.overrideWith((ref) => _NoLocation()),
          sensorProvider.overrideWith((ref) => _QuietSensor(ref)),
          caseServiceProvider.overrideWithValue(service),
          blackboxVideoProvider.overrideWith((ref) => video),
        ],
        child: Consumer(
          builder: (context, ref, child) => MaterialApp.router(
            routerConfig: ref.watch(appRouterProvider),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    final router = container.read(appRouterProvider);

    router.goNamed('first-response', extra: caseA);
    await tester.pumpAndSettle();
    await tester.tap(find.text('다음 단계'));
    await tester.pump();
    expect(find.text('신고하기'), findsOneWidget);

    router.goNamed('first-response', extra: caseB);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FirstResponseScreen>(find.byType(FirstResponseScreen))
          .accidentId,
      caseB,
    );
    expect(find.text('안전 확보'), findsOneWidget);
    expect(video.requestedCaseIds, containsAllInOrder([caseA, caseB]));
  });
}

const caseA = 'case_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const caseB = 'case_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

BackendCase _backendCase(String id) => BackendCase(
      id: id,
      deviceId: 'dev_owned',
      title: 'Hardware case',
      status: 'created',
      createdAt: DateTime.utc(2026, 10, 16),
    );

GoRouter _manualEntryRouter() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const MainPage()),
        GoRoute(
          path: '/countdown',
          name: 'accident-detected',
          builder: (_, state) {
            final extra = state.extra;
            return Text(
                'countdown:${extra is Map ? extra['case_id'] : extra}');
          },
        ),
      ],
    );

Widget _testApp({
  required _FakeCaseService service,
  required GoRouter router,
  BlackboxVideoNotifier? video,
  AuthNotifier? auth,
}) {
  return ProviderScope(
    overrides: [
      authProvider.overrideWith((ref) => auth ?? _SignedInAuth()),
      locationProvider.overrideWith((ref) => _NoLocation()),
      sensorProvider.overrideWith((ref) => _QuietSensor(ref)),
      caseServiceProvider.overrideWithValue(service),
      if (video != null) blackboxVideoProvider.overrideWith((ref) => video),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

class _FakeCaseService extends CaseService {
  _FakeCaseService(
      {this.latest,
      this.latestFuture,
      this.error,
      this.ownedFuture,
      this.ownedError})
      : super(
          dio: Dio(),
          accessToken: () async => 'token',
          savedDevice: () async => (id: 'dev_owned', name: 'Dashcam'),
          activeCase: () => null,
          onActiveCaseChanged: (_) {},
        );

  final BackendCase? latest;
  final Future<BackendCase?>? latestFuture;
  final Object? error;
  final Future<BackendCase>? ownedFuture;
  final Object? ownedError;
  int latestCalls = 0;
  final List<BackendHardwareEvent> hardwareEvents = [];

  @override
  Future<BackendCase?> selectLatestHardwareCase() async {
    latestCalls++;
    if (error != null) throw error!;
    if (latestFuture != null) return latestFuture!;
    return latest;
  }

  @override
  Future<List<BackendHardwareEvent>> peekRecentHardwareEvents() async =>
      List<BackendHardwareEvent>.unmodifiable(hardwareEvents);

  @override
  Future<BackendCase> selectOwnedCase(String caseId) async {
    if (ownedError != null) throw ownedError!;
    return ownedFuture ?? Future.value(_backendCase(caseId));
  }
}

class _RecordingVideoNotifier extends BlackboxVideoNotifier {
  _RecordingVideoNotifier({bool seedReady = false})
      : super(
          evidenceService: BackendEvidenceService(
            apiDio: Dio(),
            storageDio: Dio(),
            accessToken: () async => 'token',
          ),
          ensureOwnedCase: (_) async {},
          principal: () => 'driver@example.com',
        ) {
    if (seedReady) {
      state = const BlackboxVideoState(
        caseId: caseA,
        status: VideoStatus.ready,
        localPath: '/tmp/previous_case_video.mp4',
      );
    }
  }

  final List<String> requestedCaseIds = [];

  @override
  Future<void> fetchAndDownload(String accidentId) async {
    requestedCaseIds.add(accidentId);
  }
}

class _NoLocation extends LocationNotifier {
  @override
  Future<void> requestLocationAndFetch() async {}
}

class _QuietSensor extends SensorNotifier {
  _QuietSensor(super.ref);
}

class _SignedInAuth extends AuthNotifier {
  _SignedInAuth()
      : super(
          restoreSession: false,
          tokenStore: MemoryAuthStore(),
          initialAccessToken: 'token',
        ) {
    state = const AuthState(
      status: AuthStatus.authenticated,
      email: 'driver@example.com',
    );
  }
}

class _SwitchableAuth extends _SignedInAuth {
  void switchTo(String email) {
    state = AuthState(status: AuthStatus.authenticated, email: email);
  }

  void signOutForTest() {
    state = const AuthState(status: AuthStatus.unauthenticated);
  }
}

class _GrantedConsentController extends ConsentController {
  _GrantedConsentController()
      : super(service: ConsentService(accessToken: () async => 'token')) {
    state = const ConsentState(
      status: ConsentLoadStatus.ready,
      snapshot: ConsentSnapshot(
        version: '2026-10-15',
        grants: {
          ConsentDocument.privacy: true,
          ConsentDocument.location: true,
          ConsentDocument.externalAi: false,
        },
      ),
    );
  }
}
