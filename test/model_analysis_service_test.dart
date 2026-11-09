import 'dart:convert';
import 'dart:typed_data';

import 'package:blackbox_driver_care/services/model_analysis_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModelAnalysisService', () {
    test('loads only the exact analysis job and expected report', () async {
      final adapter = QueueAdapter([
        jsonResponse(200, {
          'data': {
            'job': {
              'id': 'job_exact_push',
              'case_id': _caseA,
              'kind': 'analysis',
              'status': 'done',
            },
            'report': {
              ..._reportFixture(
                status: 'incomplete',
                modelProvider: 'real',
                prediction: null,
              ),
              'id': 'rpt_exact_push',
            },
          },
        }),
      ]);

      final report = await serviceWith(adapter).loadJob(
        _caseA,
        'job_exact_push',
        expectedReportId: 'rpt_exact_push',
      );

      expect(report.status, ModelReportStatus.incomplete);
      expect(adapter.requests.single.method, 'GET');
      expect(
        adapter.requests.single.path,
        '/api/v1/cases/$_caseA/jobs/job_exact_push',
      );
    });

    test('rejects non-analysis jobs and mismatched expected reports', () async {
      for (final response in [
        {
          'job': {
            'id': 'job_wrong_kind',
            'case_id': _caseA,
            'kind': 'report_cleanup',
            'status': 'done',
          },
          'report': {
            ..._reportFixture(
              status: 'incomplete',
              modelProvider: 'real',
              prediction: null,
            ),
            'id': 'rpt_expected',
          },
        },
        {
          'job': {
            'id': 'job_wrong_report',
            'case_id': _caseA,
            'kind': 'analysis',
            'status': 'done',
          },
          'report': {
            ..._reportFixture(
              status: 'incomplete',
              modelProvider: 'real',
              prediction: null,
            ),
            'id': 'rpt_other',
          },
        },
      ]) {
        final jobId = (response['job']! as Map)['id']! as String;
        final service = serviceWith(QueueAdapter([
          jsonResponse(200, {'data': response}),
        ]));

        await expectLater(
          service.loadJob(
            _caseA,
            jobId,
            expectedReportId: 'rpt_expected',
          ),
          throwsA(isA<ModelAnalysisException>()),
        );
      }
    });

    test('preserves the exact job id when polling reaches its limit', () async {
      final adapter = QueueAdapter([
        jsonResponse(202, {
          'data': {
            'job': {'id': 'job_still_running', 'case_id': _caseA}
          }
        }),
        jsonResponse(200, {
          'data': {
            'job': {
              'id': 'job_still_running',
              'case_id': _caseA,
              'kind': 'analysis',
              'status': 'running',
            },
            'report': null,
          }
        }),
      ]);
      final dio = Dio(BaseOptions(baseUrl: 'http://example.test'))
        ..httpClientAdapter = adapter;
      final service = ModelAnalysisService(
        dio: dio,
        accessToken: () async => 'token',
        pollInterval: Duration.zero,
        maxPollAttempts: 1,
      );

      await expectLater(
        service.requestAnalysis(caseId: _caseA, place: 4),
        throwsA(
          isA<AnalysisJobTimeoutException>().having(
            (error) => error.jobId,
            'jobId',
            'job_still_running',
          ),
        ),
      );
      expect(
        adapter.requests.last.path,
        '/api/v1/cases/$_caseA/jobs/job_still_running',
      );
    });

    for (var road = 0; road < 8; road++) {
      test('road $road accepts no movements and no secondary answer', () async {
        final adapter = QueueAdapter([
          jsonResponse(202, {
            'data': {
              'job': {'id': 'job_optional', 'case_id': _caseA}
            }
          }),
          jsonResponse(200, {
            'data': {
              'job': {
                'id': 'job_optional',
                'case_id': _caseA,
                'kind': 'analysis',
                'status': 'done'
              },
              'report': _reportFixture(
                  status: 'incomplete',
                  modelProvider: 'real',
                  prediction: null,
                  place: road),
            }
          }),
        ]);
        await serviceWith(adapter).requestAnalysis(
          caseId: _caseA,
          place: road,
          movements: const VehicleMovements(ego: ' ', other: ''),
        );
        expect(adapter.requests.first.data, {
          'road': {'place': road, 'other_action': null},
        });
      });
    }

    test(
        'resolves client id from registered device and selected hardware event',
        () async {
      final adapter = QueueAdapter([
        jsonResponse(200, {
          'data': {
            'case': {'id': _caseA}
          }
        }),
      ]);
      final service = serviceWith(adapter);

      final caseId = await service.resolveCaseId(
        accidentId: 'client-uuid',
        registeredDeviceId: 'dev_registered',
        selectedHardwareEventId: 'event_selected',
      );

      expect(caseId, _caseA);
      expect(adapter.requests.single.path, '/api/v1/cases/by-event');
      expect(adapter.requests.single.queryParameters, {
        'device_id': 'dev_registered',
        'event_id': 'event_selected',
      });
      expect(adapter.requests.single.headers['Authorization'], 'Bearer token');
    });

    test('rejects an unmapped client id instead of inventing an event',
        () async {
      final service = serviceWith(QueueAdapter([]));

      await expectLater(
        service.resolveCaseId(
          accidentId: 'client-uuid',
          registeredDeviceId: 'dev_registered',
          selectedHardwareEventId: null,
        ),
        throwsA(isA<MissingCaseMappingException>()),
      );
    });

    test('loads automatic road selection and saved secondary answer', () async {
      final adapter = QueueAdapter([
        jsonResponse(200, {
          'data': {
            'road': {
              'automatic': {'status': 'estimated'},
              'selected': {'place': 1, 'other_action': 'right', 'revision': 2},
              'model_input': {'place': 1, 'other_action': 'right'}
            }
          }
        }),
      ]);
      final service = serviceWith(adapter);

      final road = await service.loadRoad(_caseB);

      expect(road.place, 1);
      expect(road.otherAction, 'right');
      expect(road.isUserSelected, isTrue);
    });

    test('posts road and answer then polls only the returned exact job id',
        () async {
      final adapter = QueueAdapter([
        jsonResponse(202, {
          'data': {
            'job': {'id': 'job_exact', 'case_id': _caseC, 'status': 'queued'}
          }
        }),
        jsonResponse(200, {
          'data': {
            'job': {
              'id': 'job_exact',
              'case_id': _caseC,
              'kind': 'analysis',
              'status': 'running',
            },
            'report': null,
          }
        }),
        jsonResponse(200, {
          'data': {
            'job': {
              'id': 'job_exact',
              'case_id': _caseC,
              'kind': 'analysis',
              'status': 'done',
            },
            'report': {
              'id': 'rpt_1',
              'case_id': _caseC,
              'version': 1,
              'created_at': '2026-10-15T00:00:00Z',
              'text': 'authoritative report',
              'analysis': {
                'status': 'complete',
                'providers': {
                  'model': 'real',
                  'law': 'unavailable',
                  'context': 'absent',
                  'llm': 'absent',
                },
                'model_input': {'place': 6, 'other_action': 'circulating'},
                'model': {
                  'prediction': {
                    'rateB': 70,
                    'rateA': 30,
                    'ego_party': 'B',
                    'place_used': 6,
                  }
                }
              }
            }
          }
        }),
      ]);
      final service = serviceWith(adapter);

      final report = await service.requestAnalysis(
        caseId: _caseC,
        place: 6,
        otherAction: 'circulating',
        facts: const {'bad_weather': true},
        keywords: const ['빗길'],
      );

      expect(adapter.requests.first.method, 'POST');
      expect(adapter.requests.first.path, '/api/v1/cases/$_caseC/analysis');
      expect(adapter.requests.first.data, {
        'road': {'place': 6, 'other_action': 'circulating'},
        'facts': {'bad_weather': true},
        'keywords': ['빗길'],
      });
      expect(
        adapter.requests.skip(1).map((request) => request.path),
        everyElement('/api/v1/cases/$_caseC/jobs/job_exact'),
      );
      expect(report.rateB, 70);
      expect(report.rateA, 30);
      expect(report.lawAvailable, isFalse);
    });

    test('sends null other_action for roads without a secondary question',
        () async {
      final adapter = QueueAdapter([
        jsonResponse(202, {
          'data': {
            'job': {'id': 'job_4', 'case_id': _caseD, 'status': 'queued'}
          }
        }),
        jsonResponse(200, {
          'data': {
            'job': {
              'id': 'job_4',
              'case_id': _caseD,
              'kind': 'analysis',
              'status': 'done',
            },
            'report': {
              'id': 'rpt_4',
              'case_id': _caseD,
              'version': 1,
              'created_at': '2026-10-15T00:00:00Z',
              'text': 'unavailable',
              'analysis': {
                'status': 'unavailable',
                'providers': {
                  'model': 'real',
                  'law': 'unavailable',
                  'context': 'absent',
                  'llm': 'absent',
                },
                'model_input': {'place': 4, 'other_action': null},
                'model': {'prediction': null, 'reason': 'decode_failed'}
              }
            }
          }
        }),
      ]);
      final service = serviceWith(adapter);

      final report = await service.requestAnalysis(
        caseId: _caseD,
        place: 4,
        otherAction: 'left',
      );

      expect((adapter.requests.first.data as Map)['road'], {
        'place': 4,
        'other_action': null,
      });
      expect(report.hasRates, isFalse);
      expect(report.status, ModelReportStatus.unavailable);
    });

    test('sends explicit empty feedback collections to clear saved feedback',
        () async {
      final adapter = QueueAdapter([
        jsonResponse(202, {
          'data': {
            'job': {'id': 'job_clear', 'case_id': _caseD}
          }
        }),
        jsonResponse(200, {
          'data': {
            'job': {
              'id': 'job_clear',
              'case_id': _caseD,
              'kind': 'analysis',
              'status': 'done',
            },
            'report': {
              'id': 'rpt_clear',
              'case_id': _caseD,
              'version': 1,
              'created_at': '2026-10-15T00:00:00Z',
              'text': 'cleared',
              'analysis': {
                'status': 'incomplete',
                'providers': {
                  'model': 'real',
                  'law': 'unavailable',
                  'context': 'absent',
                  'llm': 'absent',
                },
                'model_input': {'place': 0, 'other_action': null},
                'model': {'prediction': null, 'reason': 'place_required'}
              }
            }
          }
        }),
      ]);
      final service = serviceWith(adapter);

      await service.requestAnalysis(
        caseId: _caseD,
        place: 0,
        facts: const {},
        keywords: const [],
      );

      expect(adapter.requests.first.data, {
        'road': {'place': 0, 'other_action': null},
        'facts': <String, bool>{},
        'keywords': <String>[],
      });
    });

    test('failed job and done job without report never produce fallback rates',
        () async {
      final failed = serviceWith(QueueAdapter([
        jsonResponse(202, {
          'data': {
            'job': {'id': 'job_failed', 'case_id': _caseE}
          }
        }),
        jsonResponse(200, {
          'data': {
            'job': {
              'id': 'job_failed',
              'case_id': _caseE,
              'kind': 'analysis',
              'status': 'failed',
              'error_code': 'job_failed'
            },
            'report': null,
          }
        }),
      ]));
      await expectLater(
        failed.requestAnalysis(caseId: _caseE, place: 0),
        throwsA(isA<ModelAnalysisException>()),
      );

      final missing = serviceWith(QueueAdapter([
        jsonResponse(202, {
          'data': {
            'job': {'id': 'job_null', 'case_id': _caseF}
          }
        }),
        jsonResponse(200, {
          'data': {
            'job': {
              'id': 'job_null',
              'case_id': _caseF,
              'kind': 'analysis',
              'status': 'done',
            },
            'report': null,
          }
        }),
      ]));
      await expectLater(
        missing.requestAnalysis(caseId: _caseF, place: 0),
        throwsA(isA<ModelAnalysisException>()),
      );

      final dead = serviceWith(QueueAdapter([
        jsonResponse(202, {
          'data': {
            'job': {'id': 'job_dead', 'case_id': _caseF}
          }
        }),
        jsonResponse(200, {
          'data': {
            'job': {
              'id': 'job_dead',
              'case_id': _caseF,
              'kind': 'analysis',
              'status': 'dead',
            },
            'report': null,
          }
        }),
      ]));
      await expectLater(
        dead.requestAnalysis(caseId: _caseF, place: 0),
        throwsA(isA<ModelAnalysisException>()),
      );
    });

    test('incomplete report remains visible without invented rates', () async {
      final service = serviceWith(QueueAdapter([
        jsonResponse(202, {
          'data': {
            'job': {'id': 'job_incomplete', 'case_id': _caseF}
          }
        }),
        jsonResponse(200, {
          'data': {
            'job': {
              'id': 'job_incomplete',
              'case_id': _caseF,
              'kind': 'analysis',
              'status': 'done',
            },
            'report': {
              'id': 'rpt_incomplete',
              'case_id': _caseF,
              'version': 1,
              'created_at': '2026-10-15T00:00:00Z',
              'text': 'road is required',
              'analysis': {
                'status': 'incomplete',
                'providers': {
                  'model': 'real',
                  'law': 'unavailable',
                  'context': 'absent',
                  'llm': 'absent',
                },
                'model_input': {'place': 0, 'other_action': null},
                'model': {
                  'prediction': null,
                  'reason': 'place_required',
                  'needs_user_input': ['road'],
                }
              }
            }
          }
        }),
      ]));

      final report = await service.requestAnalysis(
        caseId: _caseF,
      );

      expect(report.status, ModelReportStatus.incomplete);
      expect(report.hasRates, isFalse);
      expect(report.reason, 'place_required');
    });

    test('rejects a job or report linked to a different case', () async {
      final wrongJob = serviceWith(QueueAdapter([
        jsonResponse(202, {
          'data': {
            'job': {'id': 'job_wrong_case', 'case_id': _caseF}
          }
        }),
        jsonResponse(200, {
          'data': {
            'job': {
              'id': 'job_wrong_case',
              'case_id': _caseE,
              'kind': 'analysis',
              'status': 'done',
            },
            'report': _reportFixture(
              status: 'incomplete',
              modelProvider: 'real',
              prediction: null,
              caseId: _caseF,
            ),
          }
        }),
      ]));

      await expectLater(
        wrongJob.requestAnalysis(caseId: _caseF),
        throwsA(isA<ModelAnalysisException>()),
      );

      final wrongReport = serviceWith(QueueAdapter([
        jsonResponse(202, {
          'data': {
            'job': {'id': 'job_wrong_report', 'case_id': _caseF}
          }
        }),
        jsonResponse(200, {
          'data': {
            'job': {
              'id': 'job_wrong_report',
              'case_id': _caseF,
              'kind': 'analysis',
              'status': 'done',
            },
            'report': _reportFixture(
              status: 'incomplete',
              modelProvider: 'real',
              prediction: null,
              caseId: _caseE,
            ),
          }
        }),
      ]));

      await expectLater(
        wrongReport.requestAnalysis(caseId: _caseF),
        throwsA(isA<ModelAnalysisException>()),
      );
    });
  });

  test('latest request tracker rejects stale response', () {
    final tracker = LatestRequestTracker();
    final stale = tracker.begin();
    final latest = tracker.begin();

    expect(tracker.isLatest(stale), isFalse);
    expect(tracker.isLatest(latest), isTrue);
  });

  group('ModelAnalysisReport validation', () {
    test('parses real statute and precedent links while rejecting signed URLs',
        () {
      final law = LawReportResult.fromAnalysis({
        'providers': {'law': 'real'},
        'law': {
          'status': 'complete',
          'keywords': ['신호위반'],
          'evidence': [
            {
              'id': 's1',
              'kind': 'statute',
              'source': 'video',
              'issue_type': 'signal',
              'title': '도로교통법',
              'excerpt': '법령 본문',
              'url': 'https://www.law.go.kr/법령/도로교통법/제5조',
            },
            {
              'id': 'p1',
              'kind': 'precedent',
              'source': 'user_keyword',
              'issue_type': 'signal',
              'title': '판결 1',
              'excerpt': '판례 요지',
              'url': 'https://www.law.go.kr/LSW/precInfoP.do?precSeq=175119',
            },
            {
              'id': 'p2',
              'kind': 'precedent',
              'source': 'video',
              'issue_type': 'signal',
              'title': '차단',
              'excerpt': '서명 URL',
              'url':
                  'https://www.law.go.kr/LSW/precInfoP.do?precSeq=175119&token=',
            },
            {
              'id': 'p3',
              'kind': 'precedent',
              'source': 'video',
              'issue_type': 'signal',
              'title': '외부',
              'excerpt': '외부 호스트',
              'url': 'https://example.com/case',
            },
          ],
        },
      });
      expect(law.status, 'complete');
      expect(law.keywords, ['신호위반']);
      expect(
        law.references.map((item) => item.title),
        containsAll(['도로교통법', '판결 1', '차단', '외부']),
      );
      expect(law.references.first.url, startsWith('https://www.law.go.kr/법령/'));
      expect(
        law.references[1].url,
        'https://www.law.go.kr/LSW/precInfoP.do?precSeq=175119',
      );
      expect(law.references[2].url, isNull);
      expect(law.references[3].url, isNull);
    });

    test('keeps references visible when category matching is incomplete', () {
      final law = LawReportResult.fromAnalysis({
        'providers': {'law': 'real'},
        'law': {
          'status': 'incomplete',
          'unknowns': ['category_model_unavailable'],
          'evidence': List.generate(
            6,
            (index) => {
              'id': 'ref-$index',
              'kind': 'precedent',
              'source': 'user_keyword',
              'issue_type': 'signal',
              'title': '판례 $index',
              'excerpt': '요지',
              'url':
                  'https://www.law.go.kr/LSW/precInfoP.do?precSeq=${175119 + index}',
            },
          ),
        },
      });
      expect(law.references, hasLength(6));
      expect(law.unknowns, contains('category_model_unavailable'));
    });

    test('distinguishes empty complete results and issue roles', () {
      final law = LawReportResult.fromAnalysis({
        'providers': {'law': 'real'},
        'law': {
          'status': 'complete',
          'issues': [
            {
              'issue_type': 'signal',
              'label': '신호위반',
              'source': 'video',
              'legal_role': 'rule_candidate',
            },
            {
              'issue_type': 'custom',
              'label': '사용자 입력',
              'source': 'user_keyword',
              'legal_role': 'search_only',
            },
          ],
        },
      });
      expect(law.references, isEmpty);
      expect(
        law.issues.map((item) => item.legalRole),
        ['rule_candidate', 'search_only'],
      );
    });

    test('requires canonical reference identity and issue source roles', () {
      final reference = <String, dynamic>{
        'id': 'statute:signal:5',
        'kind': 'statute',
        'title': '도로교통법',
        'excerpt': '본문',
        'url': 'https://www.law.go.kr/법령/도로교통법/제5조',
        'issue_type': 'signal',
        'source': 'video',
      };
      for (final field in ['id', 'issue_type', 'source', 'kind']) {
        final invalid = Map<String, dynamic>.from(reference)..remove(field);
        expect(
          LawReportResult.fromAnalysis({
            'providers': {'law': 'real'},
            'law': {
              'status': 'complete',
              'evidence': [invalid],
            },
          }).references,
          isEmpty,
        );
      }
      final valid = LawReportResult.fromAnalysis({
        'providers': {'law': 'real'},
        'law': {
          'status': 'complete',
          'evidence': [reference],
          'issues': [
            {
              'issue_type': 'signal',
              'label': '신호',
              'source': 'video',
              'legal_role': 'hint_only',
            },
            {
              'issue_type': 'signal',
              'label': '잘못된 원천',
              'source': 'rule',
              'legal_role': 'rule_candidate',
            },
            {
              'issue_type': 'signal',
              'label': '잘못된 역할',
              'source': 'user_keyword',
              'legal_role': 'rule_candidate',
            },
          ],
        },
      });
      expect(valid.references.single.id, 'statute:signal:5');
      expect(valid.references.single.issueType, 'signal');
      expect(valid.issues.map((issue) => issue.label), ['신호']);
    });

    test(
        'rejects every credential query name but retains public precedent queries',
        () {
      for (final name in [
        'oc',
        'token',
        'key',
        'signature',
        'access_token',
        'authorization',
        'credential',
        'credentials',
        'secret',
        'password',
        'passwd',
        'api_key',
        'apikey',
        'x-api-key',
        'X-Amz-Signature',
      ]) {
        final law = LawReportResult.fromAnalysis({
          'providers': {'law': 'real'},
          'law': {
            'status': 'complete',
            'evidence': [
              {
                'id': 'precedent:1',
                'kind': 'precedent',
                'title': '판례',
                'excerpt': '요지',
                'issue_type': 'signal',
                'source': 'user_keyword',
                'url':
                    'https://www.law.go.kr/LSW/precInfoP.do?precSeq=175119&$name=',
              },
            ],
          },
        });
        expect(law.references.single.url, isNull, reason: name);
      }
    });

    test(
        'suppresses forged evidence unless the LAW provider and status are real',
        () {
      final evidence = {
        'id': 'statute:signal:5',
        'kind': 'statute',
        'title': '도로교통법',
        'excerpt': '본문',
        'url': 'https://www.law.go.kr/법령/도로교통법/제5조',
        'issue_type': 'signal',
        'source': 'video',
      };
      for (final fixture in [
        {
          'providers': {'law': 'mock'},
          'law': {
            'status': 'complete',
            'keywords': ['신호위반'],
            'unknowns': ['provider_contract'],
            'evidence': [evidence],
          },
        },
        {
          'providers': {'law': 'unavailable'},
          'law': {
            'status': 'incomplete',
            'keywords': ['신호위반'],
            'unknowns': ['law_service_unavailable'],
            'evidence': [evidence],
          },
        },
        {
          'providers': {'law': 'real'},
          'law': {
            'status': 'unavailable',
            'keywords': ['신호위반'],
            'unknowns': ['law_service_unavailable'],
            'evidence': [evidence],
          },
        },
        {
          'providers': {'law': 'real'},
          'law': {
            'status': 'unexpected',
            'keywords': ['신호위반'],
            'unknowns': ['provider_contract'],
            'evidence': [evidence],
          },
        },
      ]) {
        final law = LawReportResult.fromAnalysis(fixture);
        expect(law.status, 'unavailable', reason: fixture.toString());
        expect(law.keywords, ['신호위반']);
        expect(law.unknowns, isNotEmpty);
        expect(law.references, isEmpty);
        expect(law.issues, isEmpty);
      }
    });

    test('accepts only complete real Party B rates that sum to 100', () {
      final report = ModelAnalysisReport.fromReport(_reportFixture(
        status: 'complete',
        modelProvider: 'real',
        lawProvider: 'unavailable',
        prediction: {'rateB': 70, 'rateA': 30, 'ego_party': 'B'},
      ));

      expect(report.hasRates, isTrue);
      expect(report.rateB, 70);
      expect(report.rateA, 30);
      expect(report.lawAvailable, isFalse);
    });

    test('rejects mock, invalid, unavailable, and non-B rate payloads', () {
      final invalid = [
        _reportFixture(
          status: 'complete',
          modelProvider: 'mock',
          prediction: {'rateB': 70, 'rateA': 30, 'ego_party': 'B'},
        ),
        _reportFixture(
          status: 'complete',
          modelProvider: 'real',
          prediction: {'rateB': 70, 'rateA': 40, 'ego_party': 'B'},
        ),
        _reportFixture(
          status: 'complete',
          modelProvider: 'real',
          prediction: {'rateB': 110, 'rateA': -10, 'ego_party': 'B'},
        ),
        _reportFixture(
          status: 'unavailable',
          modelProvider: 'real',
          prediction: {'rateB': 70, 'rateA': 30, 'ego_party': 'B'},
        ),
        _reportFixture(
          status: 'complete',
          modelProvider: 'real',
          prediction: {'rateB': 70, 'rateA': 30, 'ego_party': 'A'},
        ),
      ];

      for (final fixture in invalid) {
        final report = ModelAnalysisReport.fromReport(fixture);
        expect(report.hasRates, isFalse, reason: fixture.toString());
        expect(report.rateB, isNull);
        expect(report.rateA, isNull);
      }
    });

    test('LAW is available only when the provider is real', () {
      for (final provider in ['mock', 'unavailable', 'absent']) {
        final report = ModelAnalysisReport.fromReport(_reportFixture(
          status: 'complete',
          modelProvider: 'real',
          lawProvider: provider,
          prediction: {'rateB': 50, 'rateA': 50, 'ego_party': 'B'},
        ));
        expect(report.lawAvailable, isFalse);
      }

      final realLaw = ModelAnalysisReport.fromReport(_reportFixture(
        status: 'complete',
        modelProvider: 'real',
        lawProvider: 'real',
        prediction: {'rateB': 50, 'rateA': 50, 'ego_party': 'B'},
      ));
      expect(realLaw.lawAvailable, isTrue);
    });

    test('rejects malformed required report contract fields', () {
      final malformed = <Map<String, dynamic>>[
        {
          ..._reportFixture(
            status: 'complete',
            modelProvider: 'real',
            prediction: {'rateB': 50, 'rateA': 50, 'ego_party': 'B'},
          ),
          'analysis': null,
        },
        {
          ..._reportFixture(
            status: 'complete',
            modelProvider: 'real',
            prediction: {'rateB': 50, 'rateA': 50, 'ego_party': 'B'},
          ),
          'analysis': {
            'status': 'complete',
            'providers': null,
            'model': <String, dynamic>{},
          },
        },
        {
          ..._reportFixture(
            status: 'incomplete',
            modelProvider: 'real',
            prediction: null,
          ),
          'analysis': {
            'status': 'incomplete',
            'providers': {
              'model': 'real',
              'law': 'unavailable',
              'context': 'absent',
              'llm': 'absent',
            },
            'model': null,
          },
        },
        _reportFixture(
          status: 'mystery',
          modelProvider: 'real',
          prediction: null,
        ),
        _reportFixture(
          status: 'complete',
          modelProvider: 'real',
          prediction: null,
        ),
        {
          ..._reportFixture(
            status: 'incomplete',
            modelProvider: 'real',
            prediction: null,
          ),
          'created_at': 'not-a-timestamp',
        },
      ];

      for (final report in malformed) {
        expect(
          () => ModelAnalysisReport.fromReport(report),
          throwsA(isA<ModelAnalysisException>()),
          reason: report.toString(),
        );
      }
    });

    test('reads analyzed place from canonical report input', () {
      final report = ModelAnalysisReport.fromReport(_reportFixture(
        status: 'complete',
        modelProvider: 'real',
        prediction: {
          'rateB': 50,
          'rateA': 50,
          'ego_party': 'B',
          'place_used': 1,
        },
        place: 6,
      ));

      expect(report.analyzedPlace, 6);
    });

    test('accepts only fresh validated real current weather', () {
      final now = DateTime.now().toUtc();
      final observedAt = now.subtract(const Duration(minutes: 10));
      final validContext = <String, Object?>{
        'kind': 'current_weather',
        'provider': 'real',
        'source': 'open_meteo',
        'gps': {'lat': 37.4979, 'lon': 127.0276},
        'weather': {
          'condition': '맑음',
          'temperature_c': 18.5,
          'precipitation_mm': 0,
          'observed_at': observedAt.toIso8601String(),
        },
      };
      final report = ModelAnalysisReport.fromReport(_reportFixture(
        status: 'complete',
        modelProvider: 'real',
        prediction: {'rateB': 50, 'rateA': 50, 'ego_party': 'B'},
        context: validContext,
        createdAt: now.toIso8601String(),
      ));

      expect(report.currentWeather?.condition, '맑음');
      expect(report.currentWeather?.temperatureC, 18.5);
      expect(report.currentWeather?.precipitationMm, 0);

      for (final invalid in [
        {...validContext, 'provider': 'mock'},
        {
          ...validContext,
          'weather': {
            ...validContext['weather']! as Map,
            'observed_at':
                now.subtract(const Duration(hours: 3)).toIso8601String(),
          },
        },
        {
          ...validContext,
          'gps': {'lat': 95, 'lon': 127.0276},
        },
        {
          ...validContext,
          'weather': {
            ...validContext['weather']! as Map,
            'condition': 'clear',
          },
        },
      ]) {
        final rejected = ModelAnalysisReport.fromReport(_reportFixture(
          status: 'complete',
          modelProvider: 'real',
          prediction: {'rateB': 50, 'rateA': 50, 'ego_party': 'B'},
          context: invalid,
          createdAt: now.toIso8601String(),
        ));
        expect(rejected.currentWeather, isNull, reason: invalid.toString());
      }

      final yesterday = now.subtract(const Duration(days: 1));
      final oldHistory = ModelAnalysisReport.fromReport(_reportFixture(
        status: 'complete',
        modelProvider: 'real',
        prediction: {'rateB': 50, 'rateA': 50, 'ego_party': 'B'},
        context: {
          ...validContext,
          'weather': {
            ...validContext['weather']! as Map,
            'observed_at': yesterday.toIso8601String(),
          },
        },
        createdAt: yesterday.toIso8601String(),
      ));
      expect(oldHistory.currentWeather, isNull);
    });

    test('accepts current and legacy public speed values with provenance', () {
      for (final value in [40, 43]) {
        final report = ModelAnalysisReport.fromReport({
          ..._reportFixture(
            status: 'complete',
            modelProvider: 'real',
            prediction: {'rateB': 50, 'rateA': 50, 'ego_party': 'B'},
          ),
          'analysis': {
            ..._reportFixture(
              status: 'complete',
              modelProvider: 'real',
              prediction: {'rateB': 50, 'rateA': 50, 'ego_party': 'B'},
            )['analysis'] as Map,
            'speed_demo': {
              'value_kmh': value,
              'source': 'mock',
              'is_mock': true,
            },
          },
        });
        expect(report.speedDemo?.valueKmh, value);
        expect(report.speedDemo?.source, 'mock');
        expect(report.speedDemo?.isMock, isTrue);
      }
    });

    test('rejects numeric speed values that are not integers', () {
      final fixture = _reportFixture(
        status: 'complete',
        modelProvider: 'real',
        prediction: {'rateB': 50, 'rateA': 50, 'ego_party': 'B'},
      );
      final report = ModelAnalysisReport.fromReport({
        ...fixture,
        'analysis': {
          ...fixture['analysis'] as Map,
          'speed_demo': {
            'value_kmh': 40.0,
            'source': 'mock',
            'is_mock': true,
          },
        },
      });

      expect(report.speedDemo, isNull);
    });

    test(
        'accepts only strict synthetic context and labels PDF presentation data',
        () {
      const strictContext = {
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
      };
      final report = ModelAnalysisReport.fromReport(_reportFixture(
        status: 'complete',
        modelProvider: 'real',
        prediction: {
          'rateB': 50,
          'rateA': 50,
          'ego_party': 'B',
          'place_used': 0,
        },
        context: strictContext,
        gpsIsAssumed: false,
      ));

      expect(report.syntheticContext?.pdfAddress,
          '[합성 목업 · 실제 사고 위치 아님] Gangnam Station, Seoul');
      expect(report.syntheticContext?.pdfWeatherText,
          '[합성 목업 · 실제 사고 기상 아님] clear · 20℃ · 강수 0mm');
      expect(report.gpsIsAssumed, isFalse);

      for (final invalid in [
        {...strictContext, 'is_mock': false},
        {...strictContext, 'source': 'other_fixture'},
        {
          ...strictContext,
          'weather': {
            ...strictContext['weather']! as Map,
            'temperature_c': '20'
          }
        },
      ]) {
        final rejected = ModelAnalysisReport.fromReport(_reportFixture(
          status: 'complete',
          modelProvider: 'real',
          prediction: {
            'rateB': 50,
            'rateA': 50,
            'ego_party': 'B',
            'place_used': 0,
          },
          context: invalid,
          gpsIsAssumed: false,
        ));
        expect(rejected.syntheticContext, isNull, reason: invalid.toString());
      }
    });
  });
}

Map<String, dynamic> _reportFixture({
  required String status,
  required String modelProvider,
  String lawProvider = 'unavailable',
  required Map<String, dynamic>? prediction,
  int place = 0,
  String caseId = _caseA,
  Map<String, Object?>? context,
  bool? gpsIsAssumed,
  String createdAt = '2026-10-15T00:00:00Z',
}) {
  return {
    'id': 'rpt_fixture',
    'case_id': caseId,
    'version': 1,
    'created_at': createdAt,
    'text': 'fixture',
    'analysis': {
      'status': status,
      'providers': {
        'model': modelProvider,
        'law': lawProvider,
        'context': 'absent',
        'llm': 'absent',
      },
      'model_input': {'place': place, 'other_action': null},
      if (gpsIsAssumed != null) 'provenance': {'gps_is_assumed': gpsIsAssumed},
      if (context != null) 'context': context,
      'model': {'prediction': prediction},
    },
  };
}

const _caseA = 'case_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _caseB = 'case_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _caseC = 'case_cccccccccccccccccccccccccccccccc';
const _caseD = 'case_dddddddddddddddddddddddddddddddd';
const _caseE = 'case_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _caseF = 'case_ffffffffffffffffffffffffffffffff';

ModelAnalysisService serviceWith(QueueAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://example.test'));
  dio.httpClientAdapter = adapter;
  return ModelAnalysisService(
    dio: dio,
    accessToken: () async => 'token',
    pollInterval: Duration.zero,
    maxPollAttempts: 4,
  );
}

ResponseBody jsonResponse(int statusCode, Map<String, Object?> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

class QueueAdapter implements HttpClientAdapter {
  QueueAdapter(this.responses);

  final List<ResponseBody> responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (responses.isEmpty) {
      throw StateError(
          'No queued response for ${options.method} ${options.path}');
    }
    return responses.removeAt(0);
  }

  @override
  void close({bool force = false}) {}
}
