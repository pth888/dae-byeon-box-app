import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:blackbox_driver_care/screens/analysis/analysis_screen.dart';
import 'package:blackbox_driver_care/services/auth_service.dart';
import 'package:blackbox_driver_care/services/blackbox_video_service.dart';
import 'package:blackbox_driver_care/services/case_service.dart';
import 'package:blackbox_driver_care/services/consent_service.dart';
import 'package:blackbox_driver_care/services/model_analysis_service.dart';
import 'package:blackbox_driver_care/services/map_service.dart';
import 'package:blackbox_driver_care/utils/theme.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('vehicle descriptions are clearly optional and initially empty',
      (tester) async {
    final service = ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = _QueueAdapter(const []),
      accessToken: () async => 'token',
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
      child: MaterialApp(
        home: AnalysisScreen(
          accidentId: _caseId,
          analysisService: service,
          initialError: '도로유형을 선택해 주세요.',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('사고 직전 차량 움직임 (선택)'), findsOneWidget);
    for (final label in ['내 차량 (선택)', '상대 차량 (선택)']) {
      final field =
          tester.widget<TextField>(find.widgetWithText(TextField, label));
      expect(field.controller!.text, isEmpty);
    }
  });

  setUpAll(() async {
    FontLoader notoLoader(String family) => FontLoader(family)
      ..addFont(rootBundle.load('assets/fonts/NotoSansKR-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/NotoSansKR-Bold.ttf'));

    final loaders = <Future<void>>[
      notoLoader('NotoSansKR').load(),
      notoLoader('Ahem').load(),
      notoLoader('Roboto').load(),
    ];

    final configuredFlutterRoot = Platform.environment['FLUTTER_ROOT'];
    var flutterRoot = configuredFlutterRoot == null
        ? File(Platform.resolvedExecutable).parent
        : Directory(configuredFlutterRoot);
    if (configuredFlutterRoot == null) {
      for (var level = 0; level < 4; level++) {
        flutterRoot = flutterRoot.parent;
      }
    }
    final materialIcons = File(
      '${flutterRoot.path}${Platform.pathSeparator}bin${Platform.pathSeparator}'
      'cache${Platform.pathSeparator}artifacts${Platform.pathSeparator}'
      'material_fonts${Platform.pathSeparator}MaterialIcons-Regular.otf',
    );
    if (materialIcons.existsSync()) {
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          materialIcons.readAsBytes().then(ByteData.sublistView),
        );
      loaders.add(icons.load());
    }
    await Future.wait(loaders);
  });

  testWidgets('PDF export stops old-case requests after an account change',
      (tester) async {
    final auth = _ExportAuth();
    final map = _DeferredExportMap();
    final evidence = _QueueAdapter([
      _jsonResponse(200, {
        'data': {'files': [], 'next_cursor': null},
      }),
    ]);
    final model = ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = _QueueAdapter([
          _doneJob('export', rateB: 60, rateA: 40, text: 'Export report'),
        ]),
      accessToken: () async => 'test-token',
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authProvider.overrideWith((_) => auth),
        caseServiceProvider.overrideWithValue(_NormalCases()),
        mapServiceProvider.overrideWithValue(map),
        backendEvidenceServiceProvider.overrideWithValue(BackendEvidenceService(
          apiDio: Dio(BaseOptions(baseUrl: 'http://example.test'))
            ..httpClientAdapter = evidence,
          storageDio: Dio(),
          accessToken: () async => 'test-token',
        )),
      ],
      child: MaterialApp(
        home: AnalysisScreen(
          accidentId: _caseId,
          analysisService: model,
          initialReportId: 'rpt_export',
          initialJobId: 'export',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(_exportButton(tester).onPressed, isNotNull);
    await tester.tap(find.byIcon(Icons.ios_share_rounded));
    await tester.pump();
    expect(map.requested, isTrue);
    auth.changeOwner('other@example.com');
    map.pending.completeError(const MapServiceException('Map unavailable'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(evidence.requests, isEmpty,
        reason: 'An old report must not request evidence as the next user.');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'first analysis runs before road selection and shows explicit limitations',
      (tester) async {
    final adapter = _QueueAdapter([
      _jsonResponse(202, {
        'data': {
          'job': {'id': 'job_needs_road', 'case_id': _caseId}
        }
      }),
      _jsonResponse(200, {
        'data': {
          'job': {
            'id': 'job_needs_road',
            'case_id': _caseId,
            'kind': 'analysis',
            'status': 'done',
          },
          'report': {
            'id': 'rpt_needs_road',
            'case_id': _caseId,
            'version': 1,
            'created_at': '2026-10-15T00:00:00Z',
            'text': '도로 선택 필요',
            'analysis': {
              'status': 'incomplete',
              'providers': {
                'model': 'real',
                'law': 'unavailable',
                'context': 'absent',
                'llm': 'absent',
              },
              'road': {
                'automatic': {'status': 'unavailable'},
                'selected': null,
              },
              'model_input': {'place': null, 'other_action': null},
              'speed_demo': {
                'value_kmh': 43,
                'source': 'mock',
                'is_mock': true,
              },
              'model': {'prediction': null, 'reason': 'place_required'},
            }
          }
        }
      }),
    ]);
    final service = ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter,
      accessToken: () async => 'token',
      pollInterval: Duration.zero,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
      child: MaterialApp(
        home: AnalysisScreen(accidentId: _caseId, analysisService: service),
      ),
    ));
    await tester.pumpAndSettle();

    expect(adapter.requests.first.method, 'POST');
    expect(adapter.requests.first.path, '/api/v1/cases/$_caseId/analysis');
    expect(adapter.requests.where((request) => request.method == 'GET'),
        hasLength(1));
    expect(
      find.text('사용자께서 도로유형 선택 시 더욱 더 정확한 결과가 나옵니다.'),
      findsOneWidget,
    );
    // 기상·참고 속도 칸은 화면에서 뺐다
    expect(find.textContaining('43 km/h'), findsNothing);
    expect(find.text('현재 기상 정보를 확인할 수 없습니다.'), findsNothing);
    expect(find.text('현재 모델은 도로유형 선택이 필요합니다'), findsNothing);
    expect(find.textContaining('목업'), findsNothing);
    expect(find.textContaining('시연용'), findsNothing);
    expect(find.textContaining('Mock'), findsNothing);
    expect(find.text('AI 분석은 참고용이며 법적 효력이 없습니다. 최종 판단은 전문가에게 확인하세요.'),
        findsOneWidget);
  });

  testWidgets('needs-input completion opens road controls without another POST',
      (tester) async {
    final adapter = _QueueAdapter(const []);
    final service = ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter,
      accessToken: () async => 'token',
      pollInterval: Duration.zero,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
      child: MaterialApp(
        home: AnalysisScreen(
          accidentId: _caseId,
          analysisService: service,
          initialError: '현재 모델은 도로유형 선택이 필요합니다',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(
      find.text('사용자께서 도로유형 선택 시 더욱 더 정확한 결과가 나옵니다.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('road-option-0')), findsOneWidget);
    expect(adapter.requests, isEmpty);
  });

  testWidgets('initial job loads its exact incomplete report without a POST',
      (tester) async {
    final adapter = _QueueAdapter([
      _jsonResponse(200, {
        'data': {
          'job': {
            'id': 'job_needs_input_push',
            'case_id': _caseId,
            'kind': 'analysis',
            'status': 'done',
          },
          'report': {
            'id': 'rpt_needs_input_push',
            'case_id': _caseId,
            'version': 1,
            'created_at': '2026-10-15T00:00:00Z',
            'text': '정확한 푸시 작업 보고서',
            'analysis': {
              'status': 'incomplete',
              'providers': {
                'model': 'real',
                'law': 'unavailable',
                'context': 'absent',
                'llm': 'absent',
              },
              'model_input': {'place': null, 'other_action': null},
              'model': {'prediction': null, 'reason': 'place_required'},
            },
          },
        },
      }),
    ]);
    final service = ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter,
      accessToken: () async => 'token',
      pollInterval: Duration.zero,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
      child: MaterialApp(
        home: AnalysisScreen(
          accidentId: _caseId,
          analysisService: service,
          initialJobId: 'job_needs_input_push',
          initialReportId: 'rpt_needs_input_push',
          initialError: '현재 모델은 도로유형 선택이 필요합니다',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.method, 'GET');
    expect(
      adapter.requests.single.path,
      '/api/v1/cases/$_caseId/jobs/job_needs_input_push',
    );
    expect(find.text('정확한 푸시 작업 보고서'), findsNothing);
    expect(find.text('모델 보고서'), findsNothing);
    expect(find.text('분석 요약 보기'), findsOneWidget);
    expect(
      find.text('사용자께서 도로유형 선택 시 더욱 더 정확한 결과가 나옵니다.'),
      findsWidgets,
    );
  });

  testWidgets('report-only history loads by report id without polling or POST',
      (tester) async {
    final adapter = _QueueAdapter([
      _jsonResponse(200, {
        'data': {
          'reports': [
            {
              'id': 'rpt_history',
              'case_id': _caseId,
              'version': 4,
              'created_at': '2026-10-15T00:00:00Z',
              'text': '저장된 과거 보고서',
              'analysis': {
                'status': 'complete',
                'providers': {
                  'model': 'real',
                  'law': 'unavailable',
                  'context': 'absent',
                  'llm': 'absent',
                },
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
          ],
          'next_cursor': null,
        },
      }),
    ]);
    final service = ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter,
      accessToken: () async => 'token',
      pollInterval: Duration.zero,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
      child: MaterialApp(
        home: AnalysisScreen(
          accidentId: _caseId,
          analysisService: service,
          initialReportId: 'rpt_history',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.method, 'GET');
    expect(adapter.requests.single.path, '/api/v1/cases/$_caseId/reports');
    expect(find.text('저장된 과거 보고서'), findsNothing);
    expect(find.text('분석 요약 보기'), findsOneWidget);
  });

  testWidgets('new exact job for the same case replaces the prior job result',
      (tester) async {
    ResponseBody jobResult(String jobId, String reportId, String text) =>
        _jsonResponse(200, {
          'data': {
            'job': {
              'id': jobId,
              'case_id': _caseId,
              'kind': 'analysis',
              'status': 'done',
            },
            'report': {
              'id': reportId,
              'case_id': _caseId,
              'version': 1,
              'created_at': '2026-10-15T00:00:00Z',
              'text': text,
              'analysis': {
                'status': 'complete',
                'providers': {
                  'model': 'real',
                  'law': 'unavailable',
                  'context': 'absent',
                  'llm': 'absent',
                },
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
    final adapter = _QueueAdapter([
      jobResult('job_same_1', 'rpt_same_1', '첫 번째 작업'),
      jobResult('job_same_2', 'rpt_same_2', '두 번째 작업'),
    ]);
    final service = ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter,
      accessToken: () async => 'token',
      pollInterval: Duration.zero,
    );
    Widget app(String jobId, String reportId) => ProviderScope(
          overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
          child: MaterialApp(
            home: AnalysisScreen(
              accidentId: _caseId,
              analysisService: service,
              initialJobId: jobId,
              initialReportId: reportId,
            ),
          ),
        );

    await tester.pumpWidget(app('job_same_1', 'rpt_same_1'));
    await tester.pumpAndSettle();
    expect(find.text('첫 번째 작업'), findsNothing);

    await tester.pumpWidget(app('job_same_2', 'rpt_same_2'));
    await tester.pumpAndSettle();

    expect(find.text('첫 번째 작업'), findsNothing);
    expect(find.text('두 번째 작업'), findsNothing);
    expect(
      adapter.requests.map((request) => request.path),
      [
        '/api/v1/cases/$_caseId/jobs/job_same_1',
        '/api/v1/cases/$_caseId/jobs/job_same_2',
      ],
    );
  });

  testWidgets('automatic estimated road is visibly checked before user input',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final adapter = _QueueAdapter([
      _jsonResponse(202, {
        'data': {
          'job': {'id': 'job_auto_road', 'case_id': _caseId}
        }
      }),
      _jsonResponse(200, {
        'data': {
          'job': {
            'id': 'job_auto_road',
            'case_id': _caseId,
            'kind': 'analysis',
            'status': 'done',
          },
          'report': {
            'id': 'rpt_auto_road',
            'case_id': _caseId,
            'version': 1,
            'created_at': '2026-10-15T00:00:00Z',
            'text': '자동 도로 추정 분석',
            'analysis': {
              'status': 'complete',
              'providers': {
                'model': 'real',
                'law': 'unavailable',
                'context': 'absent',
                'llm': 'absent',
              },
              'road': {
                'automatic': {'status': 'estimated'},
                'selected': null,
              },
              'model_input': {'place': 4, 'other_action': null},
              'model': {
                'prediction': {
                  'rateB': 40,
                  'rateA': 60,
                  'ego_party': 'B',
                  'place_used': 4,
                }
              },
            }
          }
        }
      }),
    ]);
    final service = ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter,
      accessToken: () async => 'token',
      pollInterval: Duration.zero,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
      child: MaterialApp(
        home: AnalysisScreen(accidentId: _caseId, analysisService: service),
      ),
    ));
    await tester.pumpAndSettle();

    final selected = find.byKey(const Key('road-option-4'));
    expect(
      find.descendant(of: selected, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    expect(find.text('GPS 기반 자동 추정값입니다. 필요하면 수정해 주세요.'), findsOneWidget);
    expect(
      tester.getSemantics(selected),
      matchesSemantics(
        isSelected: true,
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasSelectedState: true,
        hasTapAction: true,
        hasFocusAction: true,
        label: '고속도로',
      ),
    );
    semantics.dispose();
  });

  testWidgets(
      'road and secondary answer enqueue case analysis and render exact job report',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const screenshotKey = Key('analysis-screenshot');
    final adapter = _QueueAdapter([
      _jsonResponse(202, {
        'data': {
          'job': {'id': 'job_initial', 'case_id': _caseId}
        }
      }),
      _doneJob(
        'job_initial',
        place: 0,
        rateB: 40,
        rateA: 60,
        text: 'initial',
      ),
      _jsonResponse(202, {
        'data': {
          'job': {'id': 'job_signal_left', 'case_id': _caseId}
        }
      }),
      _doneJob(
        'job_signal_left',
        place: 1,
        rateB: 70,
        rateA: 30,
        text: 'signal left',
      ),
      _jsonResponse(202, {
        'data': {
          'job': {
            'id': 'job_roundabout_circulating',
            'case_id': _caseId,
          }
        }
      }),
      _doneJob(
        'job_roundabout_circulating',
        rateB: 20,
        rateA: 80,
        text: 'roundabout circulating',
      ),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'http://example.test'))
      ..httpClientAdapter = adapter;
    final service = ModelAnalysisService(
      dio: dio,
      accessToken: () async => 'token',
      pollInterval: Duration.zero,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
      child: MaterialApp(
        theme: AppTheme.lightTheme.copyWith(
          platform: TargetPlatform.android,
          textTheme: AppTheme.lightTheme.textTheme.apply(
            fontFamily: 'NotoSansKR',
          ),
          primaryTextTheme: AppTheme.lightTheme.primaryTextTheme.apply(
            fontFamily: 'NotoSansKR',
          ),
        ),
        home: RepaintBoundary(
          key: screenshotKey,
          child: AnalysisScreen(
            accidentId: _caseId,
            analysisService: service,
          ),
        ),
      ),
    ));
    expect(
      _exportButton(tester).onPressed,
      isNull,
    );
    await tester.pumpAndSettle();
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('우리 과실'), findsOneWidget);
    expect(find.text('상대 과실'), findsOneWidget);
    expect(find.text('B측 과실'), findsNothing);
    expect(find.text('A측 과실'), findsNothing);
    expect(find.textContaining('GPS 기반 도로유형 가정값'), findsNothing);
    expect(find.textContaining('모델 요청에 함께 저장'), findsNothing);
    expect(
      _exportButton(tester).onPressed,
      isNotNull,
    );

    await tester.ensureVisible(find.byKey(const Key('road-option-1')));
    await tester.tap(find.byKey(const Key('road-option-1')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('사고 직전 상대 차는 어떻게 움직이고 있었나요?'), findsOneWidget);
    expect(find.text('이전 분석 결과'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(
      _exportButton(tester).onPressed,
      isNull,
    );
    await tester.ensureVisible(find.byKey(const Key('road-action-left')));
    await tester.tap(find.byKey(const Key('road-action-left')));
    await tester.pump();
    expect(
      adapter.requests.where((request) => request.method == 'POST').length,
      1,
    );
    await tester.ensureVisible(find.text('입력 내용으로 다시 분석'));
    await tester.tap(find.text('입력 내용으로 다시 분석'));
    await tester.pumpAndSettle();

    final analysisPosts =
        adapter.requests.where((request) => request.method == 'POST').toList();
    expect(analysisPosts, hasLength(2));
    expect(analysisPosts.last.path, '/api/v1/cases/$_caseId/analysis');
    expect(analysisPosts.last.data, {
      'road': {'place': 1, 'other_action': 'left'},
      'facts': <String, bool>{},
      'keywords': <String>[],
    });
    expect(
      adapter.requests.last.path,
      '/api/v1/cases/$_caseId/jobs/job_signal_left',
    );
    expect(find.text('70%'), findsOneWidget);
    expect(find.text('30%'), findsOneWidget);
    expect(find.text('signal left'), findsNothing);
    expect(find.text('이전 분석 결과'), findsNothing);
    expect(
      _exportButton(tester).onPressed,
      isNotNull,
    );

    await tester.ensureVisible(find.byKey(const Key('road-option-6')));
    await tester.tap(find.byKey(const Key('road-option-6')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text('사고 직전 상대 차는 회전교차로에서 어떤 상태였나요?'),
      findsOneWidget,
    );
    await tester
        .ensureVisible(find.byKey(const Key('road-action-circulating')));
    await tester.tap(find.byKey(const Key('road-action-circulating')));
    await tester.pump();
    expect(
      adapter.requests.where((request) => request.method == 'POST').length,
      2,
    );
    await tester.ensureVisible(find.text('입력 내용으로 다시 분석'));
    await tester.tap(find.text('입력 내용으로 다시 분석'));
    await tester.pumpAndSettle();

    expect(
        (adapter.requests
            .where((request) => request.method == 'POST')
            .last
            .data),
        {
          'road': {'place': 6, 'other_action': 'circulating'},
          'facts': <String, bool>{},
          'keywords': <String>[],
        });
    expect(
      adapter.requests.last.path,
      '/api/v1/cases/$_caseId/jobs/job_roundabout_circulating',
    );
    expect(find.text('20%'), findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('roundabout circulating'), findsNothing);
    expect(tester.takeException(), isNull);
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
        .clearSnackBars();
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('road-secondary-question'))),
      alignment: 0.08,
    );
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(screenshotKey),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    expect(image.width, 320);
    expect(image.height, 800);
    if (Platform.environment['DRIVEGUARD_WRITE_TEST_PNG'] == '1') {
      await tester.runAsync(() async {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        expect(png, isNotNull);
        final output = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'driveguard-analysis-320.png',
        );
        await output.writeAsBytes(
          png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
        debugPrint('Analysis screenshot: ${output.path}');
      });
    }
    image.dispose();
  });

  testWidgets('keyword toggle renders exact LAW result and clears prior search',
      (tester) async {
    Map<String, Object?> law(bool selected) => {
          'status': selected ? 'incomplete' : 'complete',
          'keywords': selected ? ['신호위반'] : <String>[],
          'unknowns': selected ? ['category_model_unavailable'] : <String>[],
          'issues': <Map<String, Object?>>[],
          'evidence': [
            if (selected)
              {
                'id': 'precedent:signal:175119',
                'kind': 'precedent',
                'title': '선택한 신호 판례',
                'excerpt': '선택 조건 검색 결과',
                'url': 'https://www.law.go.kr/LSW/precInfoP.do?precSeq=175119',
                'issue_type': 'signal',
                'source': 'user_keyword',
              },
          ],
        };
    final adapter = _QueueAdapter([
      for (final selected in [false, true, false]) ...[
        _jsonResponse(202, {
          'data': {
            'job': {
              'id': 'job_${selected ? 'selected' : 'clear'}',
              'case_id': _caseId,
            },
          },
        }),
        _doneJob(
          'job_${selected ? 'selected' : 'clear'}',
          place: 0,
          rateB: 40,
          rateA: 60,
          text: '보고서',
          law: law(selected),
        ),
      ],
    ]);
    final service = ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter,
      accessToken: () async => 'token',
      pollInterval: Duration.zero,
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
      child: MaterialApp(
        home: AnalysisScreen(accidentId: _caseId, analysisService: service),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('검색된 법령·판례가 없습니다.'), findsOneWidget);
    await tester.ensureVisible(find.text('추가 정황 선택'));
    await tester.tap(find.text('추가 정황 선택'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('상대 신호위반'));
    await tester.tap(find.text('상대 신호위반'));
    await tester.ensureVisible(find.text('입력 내용으로 다시 분석'));
    await tester.tap(find.text('입력 내용으로 다시 분석'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('사용자 추가 검색 · 판례 · 선택한 신호 판례'),
      findsOneWidget,
    );
    expect(find.text('영상 분류 모델 결과가 없어 법률 매칭이 제한됩니다.'), findsOneWidget);
    var post =
        adapter.requests.where((request) => request.method == 'POST').last;
    expect((post.data as Map)['keywords'], ['신호위반']);
    expect((post.data as Map)['facts'], {'opponent_signal_violation': true});
    await tester.ensureVisible(find.text('상대 신호위반'));
    await tester.tap(find.text('상대 신호위반'));
    await tester.ensureVisible(find.text('입력 내용으로 다시 분석'));
    await tester.tap(find.text('입력 내용으로 다시 분석'));
    await tester.pumpAndSettle();
    post = adapter.requests.where((request) => request.method == 'POST').last;
    expect((post.data as Map)['keywords'], isEmpty);
    expect((post.data as Map)['facts'], isEmpty);
    expect(find.textContaining('선택한 신호 판례'), findsNothing);
    expect(find.text('검색된 법령·판례가 없습니다.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing accidentId resets state and targets the new case',
      (tester) async {
    final adapter = _QueueAdapter([
      _jsonResponse(202, {
        'data': {
          'job': {'id': 'job_case_a', 'case_id': _caseId}
        }
      }),
      _doneJob(
        'job_case_a',
        place: 0,
        rateB: 30,
        rateA: 70,
        text: 'case A report',
      ),
      _jsonResponse(202, {
        'data': {
          'job': {'id': 'job_case_b', 'case_id': _caseIdB}
        }
      }),
      _doneJob(
        'job_case_b',
        caseId: _caseIdB,
        rateB: 80,
        rateA: 20,
        text: 'case B report',
      ),
      _jsonResponse(202, {
        'data': {
          'job': {'id': 'job_case_b_road', 'case_id': _caseIdB}
        }
      }),
      _doneJob(
        'job_case_b_road',
        caseId: _caseIdB,
        place: 4,
        rateB: 60,
        rateA: 40,
        text: 'case B road update',
      ),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'http://example.test'))
      ..httpClientAdapter = adapter;
    final service = ModelAnalysisService(
      dio: dio,
      accessToken: () async => 'token',
      pollInterval: Duration.zero,
    );

    Widget app(String accidentId) => ProviderScope(
          overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
          child: MaterialApp(
            home: AnalysisScreen(
              accidentId: accidentId,
              analysisService: service,
            ),
          ),
        );

    await tester.pumpWidget(app(_caseId));
    await tester.pumpAndSettle();
    expect(find.text('case A report'), findsNothing);
    expect(find.text('30%'), findsOneWidget);

    await tester.pumpWidget(app(_caseIdB));
    await tester.pumpAndSettle();
    expect(find.text('case A report'), findsNothing);
    expect(find.text('case B report'), findsNothing);
    expect(find.text('80%'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('road-option-6')))
          .selected,
      isTrue,
    );

    await tester.ensureVisible(find.byKey(const Key('road-option-4')));
    await tester.tap(find.byKey(const Key('road-option-4')));
    await tester.pump();
    expect(
      adapter.requests.where((request) => request.method == 'POST').length,
      2,
      reason: 'Changing a road selection must not start analysis.',
    );
    await tester.ensureVisible(find.text('입력 내용으로 다시 분석'));
    await tester.tap(find.text('입력 내용으로 다시 분석'));
    await tester.pumpAndSettle();

    final lastPost = adapter.requests
        .where((request) => request.method == 'POST')
        .toList()
        .last;
    expect(lastPost.path, '/api/v1/cases/$_caseIdB/analysis');
    expect(lastPost.data, {
      'road': {'place': 4, 'other_action': null},
      'facts': <String, bool>{},
      'keywords': <String>[],
    });
    expect(find.text('case B road update'), findsNothing);
    expect(find.text('60%'), findsOneWidget);
  });

  testWidgets('synthetic fixture is not rendered on the normal analysis path',
      (tester) async {
    final adapter = _QueueAdapter([
      _jsonResponse(202, {
        'data': {
          'job': {'id': 'job_mock_context', 'case_id': _caseId}
        }
      }),
      _doneJob(
        'job_mock_context',
        place: 0,
        rateB: 40,
        rateA: 60,
        text: 'strict fixture report',
        context: const {
          'kind': 'synthetic_demo',
          'is_mock': true,
          'provider': 'mock',
          'source': 'gangnam_station_fixture',
          'address': 'Gangnam Station, Seoul',
          'weather': {
            'condition': 'clear',
            'temperature_c': 20,
            'precipitation_mm': 0,
            'observed_at': null,
          },
        },
      ),
    ]);
    final service = ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter,
      accessToken: () async => 'token',
      pollInterval: Duration.zero,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
      child: MaterialApp(
        home: AnalysisScreen(accidentId: _caseId, analysisService: service),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Gangnam Station'), findsNothing);
    expect(find.textContaining('목업'), findsNothing);
  });

  testWidgets('shows registered GPS location separately from selected topology',
      (tester) async {
    final adapter = _QueueAdapter([
      _jsonResponse(202, {
        'data': {
          'job': {'id': 'job_location', 'case_id': _caseId}
        }
      }),
      _doneJob(
        'job_location',
        place: 1,
        rateB: 60,
        rateA: 40,
        text: 'location report',
        automaticRoad: const {
          'status': 'estimated',
          'source': 'kakao_local',
          'address': '서울 강남구 테헤란로 1',
          'road_name': '테헤란로',
          'gps': {'lat': 37.4979, 'lon': 127.0276},
        },
      ),
    ]);
    final service = ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter,
      accessToken: () async => 'token',
      pollInterval: Duration.zero,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
      child: MaterialApp(
        home: AnalysisScreen(accidentId: _caseId, analysisService: service),
      ),
    ));
    await tester.pumpAndSettle();

    expect(
      find.text(
        '등록된 GPS 위치는 서울 강남구 테헤란로 1이며, 도로명은 테헤란로입니다. 선택한 도로유형은 신호교차로입니다.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('37.4979'), findsNothing);
    expect(find.textContaining('GPS 기반 도로유형 가정값'), findsNothing);
  });

  testWidgets('shows only fresh real weather and friendly unavailable copy',
      (tester) async {
    final now = DateTime.now().toUtc();
    final adapter = _QueueAdapter([
      _jsonResponse(202, {
        'data': {
          'job': {'id': 'job_weather', 'case_id': _caseId}
        }
      }),
      _doneJob(
        'job_weather',
        rateB: 60,
        rateA: 40,
        text: 'weather report',
        createdAt: now.toIso8601String(),
        context: {
          'kind': 'current_weather',
          'provider': 'real',
          'source': 'open_meteo',
          'gps': {'lat': 37.4979, 'lon': 127.0276},
          'weather': {
            'condition': '흐림',
            'temperature_c': 17,
            'precipitation_mm': 0.5,
            'observed_at':
                now.subtract(const Duration(minutes: 10)).toIso8601String(),
          },
        },
      ),
    ]);
    final service = ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter,
      accessToken: () async => 'token',
      pollInterval: Duration.zero,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
      child: MaterialApp(
        home: AnalysisScreen(accidentId: _caseId, analysisService: service),
      ),
    ));
    await tester.pumpAndSettle();

    // 기상 칸은 화면에서 뺐다
    expect(find.text('기상은 현재 흐림, 17℃, 강수량 0.5mm입니다.'), findsNothing);
    expect(find.text('출처: Open-Meteo'), findsNothing);
    expect(find.textContaining('기상 정보를 확인할 수 없습니다'), findsNothing);
  });

  testWidgets('opens a validated structured summary without raw report text',
      (tester) async {
    final now = DateTime.now().toUtc();
    final expectedDate = '${now.year}.'
        '${now.month.toString().padLeft(2, '0')}.'
        '${now.day.toString().padLeft(2, '0')}';
    const rawReport =
        'model_output: https://internal.example/raw {"debug":true}';
    final adapter = _QueueAdapter([
      _jsonResponse(202, {
        'data': {
          'job': {'id': 'job_summary', 'case_id': _caseId}
        }
      }),
      _doneJob(
        'job_summary',
        place: 1,
        rateB: 60,
        rateA: 40,
        text: rawReport,
        createdAt: now.toIso8601String(),
        automaticRoad: const {
          'status': 'estimated',
          'source': 'kakao_local',
          'address': '서울 강남구 테헤란로 1',
          'road_name': '테헤란로',
          'gps': {'lat': 37.4979, 'lon': 127.0276},
        },
        context: {
          'kind': 'current_weather',
          'provider': 'real',
          'source': 'open_meteo',
          'gps': {'lat': 37.4979, 'lon': 127.0276},
          'weather': {
            'condition': '흐림',
            'temperature_c': 17,
            'precipitation_mm': 0.5,
            'observed_at':
                now.subtract(const Duration(minutes: 10)).toIso8601String(),
          },
        },
        law: const {
          'status': 'complete',
          'keywords': <String>[],
          'unknowns': <String>[],
          'issues': <Map<String, Object?>>[],
          'evidence': [
            {
              'id': 'statute:1',
              'kind': 'statute',
              'title': '도로교통법',
              'excerpt': '신호 준수 의무',
              'url': 'https://www.law.go.kr/법령/도로교통법',
              'issue_type': 'signal',
              'source': 'video',
            },
          ],
        },
        speedDemo: const {
          'value_kmh': 43,
          'source': 'mock',
          'is_mock': true,
        },
      ),
    ]);
    final service = ModelAnalysisService(
      dio: Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter,
      accessToken: () async => 'token',
      pollInterval: Duration.zero,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [caseServiceProvider.overrideWithValue(_NormalCases())],
      child: MaterialApp(
        home: AnalysisScreen(accidentId: _caseId, analysisService: service),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text(rawReport), findsNothing);
    expect(find.text('모델 보고서'), findsNothing);
    await tester.ensureVisible(find.text('분석 요약 보기'));
    await tester.tap(find.text('분석 요약 보기'));
    await tester.pumpAndSettle();

    expect(find.text('분석 요약'), findsOneWidget);
    expect(find.text('우리 과실 60% · 상대 과실 40%'), findsOneWidget);
    expect(find.text('서울 강남구 테헤란로 1 · 테헤란로 · 신호교차로'), findsOneWidget);
    // 요약에서도 기상·속도는 뺐다
    expect(find.text('흐림 · 17℃ · 강수량 0.5mm'), findsNothing);
    expect(find.text('43 km/h'), findsNothing);
    expect(find.text('확인된 법령·판례 근거 1건'), findsOneWidget);
    expect(find.text(expectedDate), findsOneWidget);
    expect(find.text(legalReferenceWarning), findsNWidgets(2));
    expect(find.text(rawReport), findsNothing);
    expect(find.textContaining('https://'), findsNothing);
    expect(find.textContaining('{"debug"'), findsNothing);
  });
}

const _caseId = 'case_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _caseIdB = 'case_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _NormalCases extends Fake implements CaseService {
  @override
  Future<BackendCase> selectOwnedCase(String caseId) async => BackendCase(
        id: caseId,
        deviceId: 'dev_test',
        title: 'Test accident',
        status: 'uploaded',
        createdAt: DateTime.utc(2026, 11, 9),
      );
}

class _ExportAuth extends AuthNotifier {
  _ExportAuth()
      : super(restoreSession: false, tokenStore: MemoryAuthStore()) {
    changeOwner('owner@example.com');
  }

  void changeOwner(String email) =>
      state = AuthState(status: AuthStatus.authenticated, email: email);
}

class _DeferredExportMap extends Fake implements MapService {
  final pending = Completer<AccidentMap>();
  bool requested = false;

  @override
  Future<AccidentMap> fetchCaseMap(String caseId) {
    requested = true;
    return pending.future;
  }
}

ResponseBody _doneJob(
  String jobId, {
  String caseId = _caseId,
  int place = 6,
  required int rateB,
  required int rateA,
  required String text,
  Map<String, Object?>? context,
  Map<String, Object?>? law,
  Map<String, Object?>? automaticRoad,
  Map<String, Object?>? speedDemo,
  String createdAt = '2026-10-15T00:00:00Z',
}) {
  return _jsonResponse(200, {
    'data': {
      'job': {
        'id': jobId,
        'case_id': caseId,
        'kind': 'analysis',
        'status': 'done',
      },
      'report': {
        'id': 'rpt_$jobId',
        'case_id': caseId,
        'version': 1,
        'created_at': createdAt,
        'text': text,
        'analysis': {
          'status': 'complete',
          'providers': {
            'model': 'real',
            'law': law == null ? 'unavailable' : 'real',
            'context': 'absent',
            'llm': 'absent',
          },
          'road': {
            'automatic': automaticRoad ?? {'status': 'estimated'},
            'selected': {
              'place': place,
              'other_action': place == 6 ? 'circulating' : null,
              'revision': 1,
            },
          },
          'model_input': {'place': place, 'other_action': null},
          'provenance': {'gps_is_assumed': true},
          if (context != null) 'context': context,
          if (law != null) 'law': law,
          if (speedDemo != null) 'speed_demo': speedDemo,
          'model': {
            'prediction': {
              'rateB': rateB,
              'rateA': rateA,
              'ego_party': 'B',
              'place_used': place,
            }
          }
        }
      }
    }
  });
}

IconButton _exportButton(WidgetTester tester) {
  return tester.widget<IconButton>(
    find.ancestor(
      of: find.byIcon(Icons.ios_share_rounded),
      matching: find.byType(IconButton),
    ),
  );
}

ResponseBody _jsonResponse(int statusCode, Map<String, Object?> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

class _QueueAdapter implements HttpClientAdapter {
  _QueueAdapter(this.responses);

  final List<ResponseBody> responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (responses.isEmpty) throw StateError('No response for ${options.path}');
    return responses.removeAt(0);
  }

  @override
  void close({bool force = false}) {}
}
