import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:blackbox_driver_care/screens/accident/accident_video_list_screen.dart';
import 'package:blackbox_driver_care/screens/accident/first_response_screen.dart';
import 'package:blackbox_driver_care/screens/analysis/analysis_screen.dart';
import 'package:blackbox_driver_care/services/auth_service.dart';
import 'package:blackbox_driver_care/services/blackbox_video_service.dart';
import 'package:blackbox_driver_care/services/case_service.dart';
import 'package:blackbox_driver_care/services/model_analysis_service.dart';
import 'package:blackbox_driver_care/widgets/road_question_widget.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _caseA = 'case_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _caseB = 'case_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  for (final place in [1, 3, 6, 4]) {
    testWidgets('reference video keeps expert $place across reanalysis',
        (tester) async {
      final cases =
          _Adapter((_) async => _caseResponse(_caseA, lockedPlace: place));
      final analysis = _analysisAdapter();
      await tester.pumpWidget(_analysisApp(cases, analysis));
      await tester.pumpAndSettle();
      final posts = analysis.requests.where((r) => r.method == 'POST');
      expect(posts.single.data['road']['place'], place);
      final selector =
          tester.widget<RoadQuestionWidget>(find.byType(RoadQuestionWidget));
      expect(selector.selectedPlace, place);
      for (var option = 0; option < 8; option++) {
        expect(
            tester
                .widget<ChoiceChip>(find.byKey(Key('road-option-$option')))
                .onSelected,
            isNull);
      }
      selector.onChanged(5, null);
      await tester.pump();
      expect(
          tester
              .widget<RoadQuestionWidget>(find.byType(RoadQuestionWidget))
              .selectedPlace,
          place);
      if (place == 1 || place == 6) {
        final action = place == 1 ? 'left' : 'entering';
        final chip = find.byKey(Key('road-action-$action'));
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
        expect(posts, hasLength(1));
      }
      await tester.ensureVisible(find.text('입력 내용으로 다시 분석'));
      await tester.tap(find.text('입력 내용으로 다시 분석'));
      await tester.pumpAndSettle();
      expect(posts, hasLength(2));
      expect(posts.last.data['road']['place'], place);
      expect(
          posts.last.data['road']['other_action'],
          place == 1
              ? 'left'
              : place == 6
                  ? 'entering'
                  : null);
      expect(
          tester
              .widget<RoadQuestionWidget>(find.byType(RoadQuestionWidget))
              .selectedPlace,
          place);
    });
  }

  for (final demo in [true, false]) {
    for (final firstResponse in [true, false]) {
      testWidgets(
        '$demo demo routes from ${firstResponse ? 'response' : 'video'}',
        (tester) async {
          final cases = _Adapter(
            (request) async =>
                _caseResponse(request.path.split('/').last, demo: demo),
          );
          final router = GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (_, __) => firstResponse
                    ? const FirstResponseScreen(
                        accidentId: _caseA,
                        initialVideoStep: true,
                      )
                    : const AccidentVideoViewScreen(caseId: _caseA),
              ),
              GoRoute(
                path: '/analysis',
                name: 'analysis',
                builder: (_, state) => Text('analysis:${state.extra}'),
              ),
            ],
          );
          addTearDown(router.dispose);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                authProvider.overrideWith((_) => _Auth()),
                caseServiceProvider.overrideWithValue(_caseService(cases)),
                blackboxVideoProvider.overrideWith((_) => _NoVideo()),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          );
          await tester.pumpAndSettle();
          final label = demo
              ? '주차장 모델로 분석'
              : firstResponse
                  ? 'AI 과실 분석 시작'
                  : '분석 페이지로 이동';
          expect(find.text(label), findsOneWidget);
          await tester.ensureVisible(find.text(label));
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(find.text('analysis:$_caseA'), findsOneWidget);
          expect(cases.requests, hasLength(2));
          expect(
            cases.requests.every((r) => r.path == '/api/v1/cases/$_caseA'),
            isTrue,
          );
        },
      );
    }
  }

  testWidgets('demo locks parking and batches feedback through the real API', (
    tester,
  ) async {
    final cases = _Adapter((_) async => _caseResponse(_caseA, demo: true));
    final analysis = _analysisAdapter();
    await tester.pumpWidget(_analysisApp(cases, analysis));
    await tester.pumpAndSettle();
    expect(find.text('40%'), findsOneWidget);

    final posts = analysis.requests.where((r) => r.method == 'POST');
    expect(posts, hasLength(1));
    expect(posts.single.data, {
      'road': {'place': 5, 'other_action': null},
    });
    final selector = tester.widget<RoadQuestionWidget>(
      find.byType(RoadQuestionWidget),
    );
    expect(selector.selectedPlace, 5);
    expect(selector.selectedAction, isNull);
    expect(selector.isBusy, isTrue);
    for (var place = 0; place < 8; place++) {
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(Key('road-option-$place')))
            .onSelected,
        isNull,
      );
    }
    // Even a delayed callback cannot change the demo model input.
    selector.onChanged(1, 'left');
    await tester.pump();
    expect(
      tester
          .widget<RoadQuestionWidget>(find.byType(RoadQuestionWidget))
          .selectedPlace,
      5,
    );
    await tester.ensureVisible(find.text('추가 정황 선택'));
    await tester.tap(find.text('추가 정황 선택'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('상대 과속'));
    await tester.tap(find.text('상대 과속'));
    await tester.pumpAndSettle();
    // 야간은 주행 환경 칸에서 고른다
    await tester.ensureVisible(find.text('날씨·노면·시간대 선택'));
    await tester.tap(find.text('날씨·노면·시간대 선택'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('야간'));
    await tester.tap(find.text('야간'));
    await tester.pumpAndSettle();
    expect(posts, hasLength(1));
    await tester.ensureVisible(find.text('입력 내용으로 다시 분석'));
    await tester.tap(find.text('입력 내용으로 다시 분석'));
    await tester.pumpAndSettle();
    expect(posts, hasLength(2));
    expect(posts.last.data['road'], {'place': 5, 'other_action': null});
    expect(posts.last.data['facts'], {'opponent_speeding_suspected': true});
    expect(posts.last.data['keywords'], ['과속', '야간']);
  });

  testWidgets('normal case keeps editable road and submits only on request', (
    tester,
  ) async {
    final cases = _Adapter((_) async => _caseResponse(_caseA));
    final analysis = _analysisAdapter();
    await tester.pumpWidget(_analysisApp(cases, analysis));
    await tester.pumpAndSettle();
    final posts = analysis.requests.where((r) => r.method == 'POST');
    expect(posts.single.data, isEmpty);
    final chip = find.byKey(const Key('road-option-1'));
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(posts, hasLength(1));
    expect(
      tester
          .widget<RoadQuestionWidget>(find.byType(RoadQuestionWidget))
          .selectedPlace,
      1,
    );
    await tester.ensureVisible(find.text('입력 내용으로 다시 분석'));
    await tester.tap(find.text('입력 내용으로 다시 분석'));
    await tester.pumpAndSettle();
    expect(posts.last.data['road'], {'place': 1, 'other_action': null});
  });

  testWidgets('late demo metadata cannot lock or analyze the next case', (
    tester,
  ) async {
    final pending = Completer<ResponseBody>();
    final cases = _Adapter(
      (r) => r.path.endsWith(_caseA)
          ? pending.future
          : Future.value(_caseResponse(_caseB)),
    );
    final analysis = _analysisAdapter();
    final service = _caseService(cases);
    final model = _modelService(analysis);
    Widget app(String id) =>
        _analysisApp(cases, analysis, id: id, cases: service, model: model);
    await tester.pumpWidget(app(_caseA));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(analysis.requests, isEmpty);
    await tester.pumpWidget(app(_caseB));
    await tester.pumpAndSettle();
    pending.complete(_caseResponse(_caseA, demo: true));
    await tester.pumpAndSettle();
    final selector = tester.widget<RoadQuestionWidget>(
      find.byType(RoadQuestionWidget),
    );
    expect(selector.isBusy, isFalse);
    expect(selector.selectedPlace, 0);
    expect(find.text('40%'), findsOneWidget);
    expect(analysis.requests.every((r) => r.path.contains(_caseB)), isTrue);
    expect(analysis.requests.where((r) => r.method == 'POST'), hasLength(1));
  });

  for (final wrongCase in [true, false]) {
    testWidgets(
      'unsafe metadata ($wrongCase wrong case) cannot start analysis',
      (tester) async {
        final cases = _Adapter(
          (_) async => wrongCase
              ? _caseResponse(_caseB, demo: true)
              : _json(503, {'error': 'unavailable'}),
        );
        final analysis = _analysisAdapter();
        await tester.pumpWidget(_analysisApp(cases, analysis));
        await tester.pumpAndSettle();
        expect(analysis.requests, isEmpty);
        await tester.ensureVisible(find.text('입력 내용으로 다시 분석'));
        await tester.tap(find.text('입력 내용으로 다시 분석'));
        await tester.pumpAndSettle();
        expect(analysis.requests, isEmpty);
      },
    );
  }
}

Widget _analysisApp(
  _Adapter caseAdapter,
  _Adapter analysisAdapter, {
  String id = _caseA,
  CaseService? cases,
  ModelAnalysisService? model,
}) =>
    ProviderScope(
      overrides: [
        caseServiceProvider
            .overrideWithValue(cases ?? _caseService(caseAdapter)),
      ],
      child: MaterialApp(
        home: AnalysisScreen(
          accidentId: id,
          analysisService: model ?? _modelService(analysisAdapter),
        ),
      ),
    );

CaseService _caseService(_Adapter adapter) => CaseService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter,
      accessToken: () async => 'test-token',
      savedDevice: () async => (id: null, name: null),
      activeCase: () => null,
      onActiveCaseChanged: (_) {},
    );

ModelAnalysisService _modelService(_Adapter adapter) => ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter,
      accessToken: () async => 'test-token',
      pollInterval: Duration.zero,
    );

ResponseBody _caseResponse(String id, {bool demo = false, int? lockedPlace}) =>
    _json(200, {
      'data': {
        'case': {
          'id': id,
          'device_id': 'dev_test',
          'title': 'Test accident',
          'status': 'uploaded',
          'created_at': '2026-11-09T00:00:00Z',
          'demo_mode': demo,
          if (lockedPlace != null)
            'road_policy': {
              'locked': true,
              'place': lockedPlace,
              'reason': 'reference_video'
            },
        },
      },
    });

_Adapter _analysisAdapter() => _Adapter((request) async {
      final id = request.path.split('/')[4];
      if (request.method == 'POST') {
        return _json(202, {
          'data': {
            'job': {'id': 'job_test', 'case_id': id},
          },
        });
      }
      return _json(200, {
        'data': {
          'job': {
            'id': 'job_test',
            'case_id': id,
            'kind': 'analysis',
            'status': 'done',
          },
          'report': {
            'id': 'rpt_test',
            'case_id': id,
            'version': 1,
            'created_at': '2026-11-09T00:00:00Z',
            'text': 'Test result',
            'analysis': {
              'status': 'complete',
              'providers': {
                'model': 'real',
                'law': 'unavailable',
                'context': 'absent',
                'llm': 'absent',
              },
              // Old reports must not override the fixed demo selection.
              'model_input': {'place': 0, 'other_action': null},
              'model': {
                'prediction': {
                  'rateB': 40,
                  'rateA': 60,
                  'ego_party': 'B',
                  'place_used': 0,
                },
              },
            },
          },
        },
      });
    });

ResponseBody _json(int status, Map<String, Object?> body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

class _Auth extends AuthNotifier {
  _Auth() : super(restoreSession: false, tokenStore: MemoryAuthStore()) {
    state = const AuthState(
      status: AuthStatus.authenticated,
      email: 'test@example.com',
    );
  }
}

class _NoVideo extends BlackboxVideoNotifier {
  _NoVideo()
      : super(
          evidenceService: BackendEvidenceService(
            apiDio: Dio(),
            storageDio: Dio(),
            accessToken: () async => null,
          ),
          ensureOwnedCase: (_) async {},
          principal: () => null,
        ) {
    state = const BlackboxVideoState(
      caseId: _caseA,
      status: VideoStatus.ready,
      localPath: '/tmp/demo-test-video.mp4',
    );
  }
  @override
  Future<void> fetchAndDownload(String accidentId) async {}
}
