import 'dart:convert';
import 'dart:io';

import 'package:blackbox_driver_care/router/app_router.dart';
import 'package:blackbox_driver_care/screens/accident/first_response_screen.dart';
import 'package:blackbox_driver_care/services/auth_service.dart';
import 'package:blackbox_driver_care/services/blackbox_video_service.dart';
import 'package:blackbox_driver_care/services/case_service.dart';
import 'package:blackbox_driver_care/services/consent_service.dart';
import 'package:blackbox_driver_care/services/location_service.dart';
import 'package:blackbox_driver_care/services/sensor_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channels = [
    MethodChannel('dexterous.com/flutter/local_notifications'),
    MethodChannel('plugins.flutter.io/path_provider'),
    MethodChannel('com.llfbandit.record/messages'),
  ];

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(const {});
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        return channel.name == 'plugins.flutter.io/path_provider'
            ? Directory.systemTemp.path
            : null;
      });
    }
  });

  tearDown(() {
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  for (final acceptPush in [true, false]) {
    testWidgets(
        acceptPush
            ? 'Home accepts push A through production routes then manual entry creates B'
            : 'Home manual entry without extra ignores pending push and selected history',
        (tester) async {
      final api = _IncidentApi();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
        ..httpClientAdapter = api;
      late SensorNotifier sensor;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _SignedInAuth()),
          consentControllerProvider.overrideWith(
            (ref) => _GrantedConsentController(),
          ),
          locationProvider.overrideWith((ref) => _NoLocation()),
          sensorProvider.overrideWith((ref) {
            sensor = _SeededSensor(
              ref,
              pendingCaseId: acceptPush ? null : _caseA,
            );
            return sensor;
          }),
          caseServiceProvider.overrideWith((ref) => CaseService(
                dio: dio,
                accessToken: () async => 'token',
                savedDevice: () async => (id: 'dev_a', name: 'Dashcam'),
                activeCase: () => ref.read(activeCaseProvider),
                onActiveCaseChanged: (id) =>
                    ref.read(activeCaseProvider.notifier).state = id,
              )),
          backendEvidenceServiceProvider.overrideWithValue(
            BackendEvidenceService(
              apiDio: dio,
              storageDio: dio,
              accessToken: () async => 'token',
            ),
          ),
        ],
        child: Consumer(
          builder: (context, ref, child) => MaterialApp.router(
            routerConfig: ref.watch(appRouterProvider),
          ),
        ),
      ));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      final router = container.read(appRouterProvider);
      try {
        await tester.pumpAndSettle();
        container.read(activeCaseProvider.notifier).state = _caseA;

        if (acceptPush) {
          final push = sensor.triggerFromExternal(
            caseId: _caseA,
            lat: 37.5,
            lon: 127.0,
          );
          await tester.pumpAndSettle();
          await push;
          await tester.tap(find.text('네, 사고 났어요'));
          await tester.pumpAndSettle();
          expect(container.read(sensorProvider).caseId, isNull);
          await tester.tap(find.text('지금 시작'));
          await tester.pumpAndSettle();

          expect(
            tester
                .widget<FirstResponseScreen>(find.byType(FirstResponseScreen))
                .accidentId,
            _caseA,
          );
          expect(api.requests.where((request) => request.method == 'POST'),
              isEmpty);
          expect(container.read(activeCaseProvider), _caseA);
          router.go('/');
          await tester.pumpAndSettle();
        }

        await tester.tap(find.text('사고 접수 시작'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('영상 없이 새 사고 접수'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('지금 시작'));
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<FirstResponseScreen>(find.byType(FirstResponseScreen))
              .accidentId,
          _caseB,
        );
        expect(container.read(activeCaseProvider), _caseB);
        final creates =
            api.requests.where((request) => request.method == 'POST').toList();
        expect(creates, hasLength(1));
        expect(creates.single.path, '/api/v1/cases');
        expect((creates.single.data as Map)['device_id'], 'dev_a');
        expect(api.requests.last.path, '/api/v1/cases/$_caseB/files');
        expect(api.requests.map((request) => request.headers['Authorization']),
            everyElement('Bearer token'));
        expect(tester.takeException(), isNull);
      } finally {
        sensor.dismissAlert();
        router.go('/');
        await tester.pump();
        await tester.pump(const Duration(seconds: 11));
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }
}

const _caseA = 'case_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _caseB = 'case_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

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

class _GrantedConsentController extends ConsentController {
  _GrantedConsentController()
      : super(
          service: ConsentService(accessToken: () async => 'token'),
        ) {
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

class _NoLocation extends LocationNotifier {
  @override
  Future<void> requestLocationAndFetch() async {}
}

class _SeededSensor extends SensorNotifier {
  _SeededSensor(super.ref, {String? pendingCaseId}) {
    if (pendingCaseId != null) {
      state = SensorState(isImpactDetected: true, caseId: pendingCaseId);
    }
  }
}

class _IncidentApi implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (options.path == '/api/v1/cases/latest-hardware') {
      return ResponseBody.fromString(
        jsonEncode({
          'data': {'case': null}
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        },
      );
    }
    final creates = options.method == 'POST' && options.path == '/api/v1/cases';
    final id = creates ? _caseB : options.path.split('/').last;
    final data = options.path.endsWith('/files')
        ? {'files': [], 'next_cursor': null}
        : {
            'case': {
              'id': id,
              'device_id': 'dev_a',
              'title': 'Incident $id',
              'status': 'created',
              'created_at': '2026-10-15T00:00:00Z',
              'lat': 37.5,
              'lon': 127.0,
            },
          };
    return ResponseBody.fromString(
      jsonEncode({'data': data}),
      creates ? 201 : 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
