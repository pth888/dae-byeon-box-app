import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:blackbox_driver_care/services/case_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CaseService', () {
    for (final linked in [false, true]) {
      test('hardware event resolves exact device without local registration: $linked', () async {
        final adapter = QueueAdapter([
          linked ? jsonResponse(200, {'data': {'case': caseJson(caseA)}})
              : jsonResponse(404, {'error': {'code': 'not_found', 'message': 'case not found'}}),
        ]);
        final service = serviceWith(adapter, savedDevice: () async => (id: null, name: null));
        final result = await service.findHardwareEventCase('shock-1', 'dev_owned');
        expect(result?.id, linked ? caseA : null);
        expect(adapter.requests.every((r) => r.method == 'GET'), isTrue);
        expect(adapter.requests.single.path, '/api/v1/cases/by-event');
        expect(adapter.requests.single.queryParameters['device_id'], 'dev_owned');
      });
    }
    test('peeks owned MQTT shock events without changing active case', () async {
      final adapter = QueueAdapter([
        jsonResponse(200, {
          'data': {
            'source_status': 'ok',
            'events': [
              {
                'event_id': 'shock-123',
                'device_id': 'dev_owned',
                'source_device_id': 'violet-dashcam-1',
                'device_name': 'Front dashcam',
                'trigger_utc': '2026-11-07T08:00:00Z',
                'source': 'adxl345',
                'test_event': false,
                'impact_g': 1.7,
                'case_id': null,
              },
            ],
          },
        }),
      ]);
      String? active = caseB;
      final service = serviceWith(
        adapter,
        activeCase: () => active,
        onActiveCaseChanged: (id) => active = id,
      );

      final events = await service.peekRecentHardwareEvents();

      expect(events, hasLength(1));
      expect(events.single.eventId, 'shock-123');
      expect(events.single.impactG, 1.7);
      expect(events.single.caseId, isNull);
      expect(active, caseB);
      expect(adapter.requests.single.path, '/api/v1/hardware-events');
      expect(adapter.requests.single.headers['Authorization'], 'Bearer token');
    });

    test('latest hardware case returns and activates the exact server case',
        () async {
      final adapter = QueueAdapter([
        jsonResponse(200, {
          'data': {'case': caseJson(caseA)},
        }),
      ]);
      String? active;
      final service = serviceWith(
        adapter,
        onActiveCaseChanged: (id) => active = id,
      );

      final result = await service.selectLatestHardwareCase();

      expect(result?.id, caseA);
      expect(active, caseA);
      expect(adapter.requests.single.path, '/api/v1/cases/latest-hardware');
      expect(adapter.requests.single.headers['Authorization'], 'Bearer token');
    });

    test('latest hardware case returns null without changing active case',
        () async {
      final adapter = QueueAdapter([
        jsonResponse(200, {
          'data': {'case': null},
        }),
      ]);
      String? active = caseB;
      final service = serviceWith(
        adapter,
        activeCase: () => active,
        onActiveCaseChanged: (id) => active = id,
      );

      final result = await service.selectLatestHardwareCase();

      expect(result, isNull);
      expect(active, caseB);
    });

    test('latest hardware case requires authentication before HTTP', () async {
      final adapter = QueueAdapter([]);
      final service = serviceWith(adapter, accessToken: () async => null);

      await expectLater(
        service.selectLatestHardwareCase(),
        throwsA(isA<CaseAuthenticationException>()),
      );

      expect(adapter.requests, isEmpty);
    });

    test('peeking latest hardware case does not change the active case',
        () async {
      final adapter = QueueAdapter([
        jsonResponse(200, {
          'data': {'case': caseJson(caseA)},
        }),
      ]);
      String? active = caseB;
      final service = serviceWith(
        adapter,
        activeCase: () => active,
        onActiveCaseChanged: (id) => active = id,
      );

      final result = await service.peekLatestHardwareCase();

      expect(result?.id, caseA);
      expect(active, caseB);
      expect(adapter.requests.single.path, '/api/v1/cases/latest-hardware');
      expect(adapter.requests.single.headers['Authorization'], 'Bearer token');
    });

    test('peeking latest hardware case requires authentication', () async {
      final adapter = QueueAdapter([]);
      final service = serviceWith(adapter, accessToken: () async => null);

      await expectLater(
        service.peekLatestHardwareCase(),
        throwsA(isA<CaseAuthenticationException>()),
      );

      expect(adapter.requests, isEmpty);
    });

    test('superseded latest hardware lookup cannot replace a newer case',
        () async {
      final adapter = ControlledAdapter();
      String? active;
      final service = serviceWith(
        adapter,
        onActiveCaseChanged: (id) => active = id,
      );

      final latest = service.selectLatestHardwareCase();
      final latestOutcome = expectLater(
        latest,
        throwsA(isA<SupersededCaseOperationException>()),
      );
      await adapter.waitForRequests(1);
      final owned = service.selectOwnedCase(caseB);
      await adapter.waitForRequests(2);
      adapter.complete(
        caseB,
        jsonResponse(200, {
          'data': {'case': caseJson(caseB)},
        }),
      );
      await owned;
      adapter.complete(
        'latest-hardware',
        jsonResponse(200, {
          'data': {'case': caseJson(caseA)},
        }),
      );

      await latestOutcome;
      expect(active, caseB);
    });

    test('activates only an exact owned backend case returned by the API',
        () async {
      final adapter = QueueAdapter([
        jsonResponse(200, {
          'data': {
            'case': {
              'id': caseA,
              'device_id': 'dev_owned',
              'title': 'Owned case',
              'status': 'created',
              'created_at': '2026-10-15T00:00:00Z',
            },
          },
        }),
      ]);
      String? active;
      final service = serviceWith(adapter, onActiveCaseChanged: (id) {
        active = id;
      });

      final result = await service.selectOwnedCase(caseA);

      expect(result.id, caseA);
      expect(active, caseA);
      expect(adapter.requests.single.path, '/api/v1/cases/$caseA');
      expect(adapter.requests.single.headers['Authorization'], 'Bearer token');
    });

    test('rejects malformed or mismatched case ids without activating them',
        () async {
      String? active;
      final malformed = serviceWith(
        QueueAdapter([]),
        onActiveCaseChanged: (id) => active = id,
      );

      await expectLater(
        malformed.selectOwnedCase('not-a-backend-case'),
        throwsA(isA<InvalidBackendCaseException>()),
      );
      expect(active, isNull);

      final mismatch = serviceWith(
        QueueAdapter([
          jsonResponse(200, {
            'data': {
              'case': {
                'id': caseB,
                'device_id': 'dev_owned',
                'title': 'Wrong case',
                'status': 'created',
                'created_at': '2026-10-15T00:00:00Z',
              },
            },
          }),
        ]),
        onActiveCaseChanged: (id) => active = id,
      );
      await expectLater(
        mismatch.selectOwnedCase(caseA),
        throwsA(isA<InvalidBackendCaseException>()),
      );
      expect(active, isNull);
    });

    test('superseded validation cannot navigate with an older case', () async {
      final adapter = ControlledAdapter();
      String? active;
      final service = serviceWith(
        adapter,
        onActiveCaseChanged: (id) => active = id,
      );

      final first = service.selectOwnedCase(caseA);
      final firstOutcome = expectLater(
        first,
        throwsA(isA<SupersededCaseOperationException>()),
      );
      await adapter.waitForRequests(1);
      final second = service.selectOwnedCase(caseB);
      await adapter.waitForRequests(2);
      adapter.complete(
          caseB,
          jsonResponse(200, {
            'data': {'case': caseJson(caseB)}
          }));
      await expectLater(second, completion(isA<BackendCase>()));
      adapter.complete(
          caseA,
          jsonResponse(200, {
            'data': {'case': caseJson(caseA)}
          }));

      await firstOutcome;
      expect(active, caseB);
    });

    test('sensor-only resolution creates a case with the stored backend device',
        () async {
      final adapter = QueueAdapter([
        jsonResponse(201, {
          'data': {
            'case': {
              'id': caseA,
              'device_id': 'dev_saved',
              'title': 'Phone sensor event',
              'status': 'created',
              'lat': 37.5,
              'lon': 127.0,
              'created_at': '2026-10-15T00:00:00Z',
            },
          },
        }),
      ]);
      String? active;
      final service = serviceWith(
        adapter,
        savedDevice: () async => (id: 'dev_saved', name: 'My dashcam'),
        onActiveCaseChanged: (id) => active = id,
      );

      final result = await service.resolveForAccident(
        lat: 37.5,
        lon: 127.0,
        occurredAt: DateTime.utc(2026, 10, 15, 1, 2, 3),
      );

      expect(result.id, caseA);
      expect(active, caseA);
      expect(adapter.requests.single.path, '/api/v1/cases');
      expect(adapter.requests.single.data, {
        'device_id': 'dev_saved',
        'title': 'Phone sensor event 2026-10-15 01:02:03 UTC',
        'lat': 37.5,
        'lon': 127.0,
      });
    });

    test(
        'two manual incidents create distinct evidence cases despite history selection',
        () async {
      final adapter = QueueAdapter([
        jsonResponse(201, {
          'data': {'case': caseJson(caseB)}
        }),
        jsonResponse(201, {
          'data': {'case': caseJson(caseC)}
        }),
      ]);
      String? active = caseA;
      final service = serviceWith(
        adapter,
        activeCase: () => active,
        onActiveCaseChanged: (id) => active = id,
      );

      final first = await service.resolveActiveOrCreate();
      final second = await service.resolveActiveOrCreate();

      expect(first.id, caseB);
      expect(second.id, caseC);
      expect(first.id, isNot(second.id));
      expect(adapter.requests.map((request) => request.path), [
        '/api/v1/cases',
        '/api/v1/cases',
      ]);
    });

    test('retains server cursors for case and report pagination', () async {
      final adapter = QueueAdapter([
        jsonResponse(200, {
          'data': {
            'cases': [caseJson(caseA)],
            'next_cursor': 'case-next',
          },
        }),
        jsonResponse(200, {
          'data': {
            'reports': [
              {
                'id': 'rpt_one',
                'case_id': caseA,
                'version': 2,
                'text': 'Report',
                'created_at': '2026-10-15T00:05:00Z',
                'analysis': {'status': 'incomplete'},
              },
            ],
            'next_cursor': 'report-next',
          },
        }),
      ]);
      final service = serviceWith(adapter);

      final cases = await service.listCases(limit: 10, cursor: 'case-cursor');
      final reports = await service.listReports(
        caseA,
        limit: 5,
        cursor: 'report-cursor',
      );

      expect(cases.nextCursor, 'case-next');
      expect(reports.nextCursor, 'report-next');
      expect(adapter.requests[0].queryParameters,
          {'limit': 10, 'cursor': 'case-cursor'});
      expect(adapter.requests[1].queryParameters,
          {'limit': 5, 'cursor': 'report-cursor'});
    });

    test('accepts only explicit 202 case deletion and clears the active case',
        () async {
      final adapter = QueueAdapter([
        jsonResponse(202, {
          'data': {
            'case_id': caseA,
            'job_id': 'job_delete',
            'status': 'delete_requested',
          },
        }),
      ]);
      String? active = caseA;
      final service = serviceWith(
        adapter,
        activeCase: () => active,
        onActiveCaseChanged: (id) => active = id,
      );

      await service.deleteCase(caseA);

      expect(active, isNull);
      expect(adapter.requests.single.method, 'DELETE');
      expect(adapter.requests.single.path, '/api/v1/cases/$caseA');
    });
  });
}

const caseA = 'case_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const caseB = 'case_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const caseC = 'case_cccccccccccccccccccccccccccccccc';

Map<String, Object?> caseJson(String id) => {
      'id': id,
      'device_id': 'dev_owned',
      'title': 'Case',
      'status': 'created',
      'created_at': '2026-10-15T00:00:00Z',
    };

CaseService serviceWith(
  QueueAdapter adapter, {
  AccessTokenProvider? accessToken,
  Future<({String? id, String? name})> Function()? savedDevice,
  String? Function()? activeCase,
  void Function(String?)? onActiveCaseChanged,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://example.test'));
  dio.httpClientAdapter = adapter;
  return CaseService(
    dio: dio,
    accessToken: accessToken ?? () async => 'token',
    savedDevice: savedDevice ?? () async => (id: 'dev_owned', name: 'Dashcam'),
    activeCase: activeCase ?? () => null,
    onActiveCaseChanged: onActiveCaseChanged ?? (_) {},
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

class ControlledAdapter extends QueueAdapter {
  ControlledAdapter() : super([]);

  final Map<String, Completer<ResponseBody>> _pending = {};
  final Completer<void> _firstRequest = Completer<void>();
  final Completer<void> _twoRequests = Completer<void>();

  Future<void> waitForRequests(int count) async {
    if (requests.length >= count) return;
    if (count == 1) return _firstRequest.future;
    await _twoRequests.future;
  }

  void complete(String caseId, ResponseBody response) {
    _pending.remove(caseId)!.complete(response);
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    final caseId = options.path.split('/').last;
    final completer = Completer<ResponseBody>();
    _pending[caseId] = completer;
    if (!_firstRequest.isCompleted) _firstRequest.complete();
    if (requests.length >= 2 && !_twoRequests.isCompleted) {
      _twoRequests.complete();
    }
    return completer.future;
  }
}
