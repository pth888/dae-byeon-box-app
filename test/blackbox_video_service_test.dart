import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:blackbox_driver_care/services/blackbox_video_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BackendEvidenceService', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('blackbox-media-test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('streams sha256 then presigns, PUTs required headers, and completes',
        () async {
      final file = File('${tempDir.path}/evidence.jpg');
      await file.writeAsBytes([1, 2, 3, 4]);
      final apiAdapter = QueueAdapter([
        jsonResponse(201, {
          'data': {
            'upload_id': 'upl_one',
            'put_url': 'https://storage.test/upload',
            'required_headers': {
              'Content-Type': 'image/jpeg',
              'Content-Length': '4',
              'x-amz-checksum-sha256': 'signed-checksum',
            },
            'expires_in': 60,
          },
        }),
        jsonResponse(200, {
          'data': {
            'file': {
              'id': 'file_one',
              'case_id': caseA,
              'kind': 'evidence_photo',
              'sha256':
                  '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a',
              'size': 4,
              'mime': 'image/jpeg',
              'created_at': '2026-10-15T00:00:00Z',
            },
          },
        }),
      ]);
      final storageAdapter = QueueAdapter([ResponseBody.fromBytes([], 200)]);
      final service = mediaService(apiAdapter, storageAdapter);

      final uploaded = await service.uploadEvidence(
        caseId: caseA,
        path: file.path,
        kind: EvidenceKind.photo,
        mime: 'image/jpeg',
      );

      expect(uploaded.id, 'file_one');
      expect(apiAdapter.requests.first.data, {
        'file_kind': 'evidence_photo',
        'sha256':
            '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a',
        'size': 4,
        'mime': 'image/jpeg',
      });
      expect(
          apiAdapter.requests.first.headers['Authorization'], 'Bearer token');
      expect(apiAdapter.requests.last.path,
          '/api/v1/cases/$caseA/uploads/upl_one/complete');
      final storage = storageAdapter.requests.single;
      expect(storage.uri.toString(), 'https://storage.test/upload');
      expect(storage.headers['Authorization'], isNull);
      expect(storage.headers['Content-Type'], 'image/jpeg');
      expect(storage.headers['Content-Length'], '4');
      expect(storage.headers['x-amz-checksum-sha256'], 'signed-checksum');
    });

    test('reacquires the owner token after a long storage PUT', () async {
      final file = File('${tempDir.path}/long-upload.jpg');
      await file.writeAsBytes([1, 2, 3, 4]);
      final apiAdapter = QueueAdapter([
        jsonResponse(201, {
          'data': {
            'upload_id': 'upl_rotated',
            'put_url': 'https://storage.test/upload',
            'required_headers': {
              'Content-Type': 'image/jpeg',
              'Content-Length': '4',
            },
            'expires_in': 1200,
          },
        }),
        jsonResponse(200, {
          'data': {
            'file': {
              'id': 'file_rotated',
              'case_id': caseA,
              'kind': 'evidence_photo',
              'sha256':
                  '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a',
              'size': 4,
              'mime': 'image/jpeg',
              'created_at': '2026-10-15T00:00:00Z',
            },
          },
        }),
      ]);
      final storageAdapter = QueueAdapter([ResponseBody.fromBytes([], 200)]);
      final tokens = ['token-a', 'token-b'];
      final service = mediaService(
        apiAdapter,
        storageAdapter,
        accessToken: () async => tokens.removeAt(0),
      );

      await service.uploadEvidence(
        caseId: caseA,
        path: file.path,
        kind: EvidenceKind.photo,
        mime: 'image/jpeg',
      );

      expect(
          apiAdapter.requests.first.headers['Authorization'], 'Bearer token-a');
      expect(
          apiAdapter.requests.last.headers['Authorization'], 'Bearer token-b');
      expect(storageAdapter.requests.single.headers['Authorization'], isNull);
      expect(tokens, isEmpty);
    });

    test('rejects evidence mime and size before issuing an upload', () async {
      final badMime = File('${tempDir.path}/bad.jpg');
      await badMime.writeAsBytes([1]);
      final adapter = QueueAdapter([]);
      final service = mediaService(adapter, QueueAdapter([]));

      await expectLater(
        service.uploadEvidence(
          caseId: caseA,
          path: badMime.path,
          kind: EvidenceKind.photo,
          mime: 'image/gif',
        ),
        throwsA(isA<InvalidEvidenceException>()),
      );

      final tooLarge = FakeEvidenceFile(
        path: '${tempDir.path}/large.m4a',
        length: 100 * 1024 * 1024 + 1,
      );
      await expectLater(
        service.uploadEvidenceFile(
          caseId: caseA,
          file: tooLarge,
          kind: EvidenceKind.audio,
          mime: 'audio/mp4',
        ),
        throwsA(isA<EvidenceTooLargeException>()),
      );
      expect(adapter.requests, isEmpty);
    });

    test('downloads only a selected owned case file via access URL', () async {
      final apiAdapter = QueueAdapter([
        jsonResponse(200, {
          'data': {
            'files': [
              {
                'id': 'file_original',
                'case_id': caseA,
                'kind': 'original_video',
                'sha256': 'a' * 64,
                'size': 4,
                'mime': 'video/mp4',
                'created_at': '2026-10-15T00:00:00Z',
              },
            ],
            'next_cursor': null,
          },
        }),
        jsonResponse(200, {
          'data': {
            'url': 'https://storage.test/video',
            'expires_in': 60,
            'file_id': 'file_original',
          },
        }),
      ]);
      final storageAdapter = QueueAdapter([
        ResponseBody.fromBytes([1, 2, 3, 4], 200),
      ]);
      final service = mediaService(apiAdapter, storageAdapter);
      final savePath = '${tempDir.path}/video.mp4';

      final result = await service.downloadOriginalVideo(
        caseId: caseA,
        savePath: savePath,
      );

      expect(result.file.id, 'file_original');
      expect(await File(savePath).readAsBytes(), [1, 2, 3, 4]);
      expect(apiAdapter.requests.map((r) => r.path), [
        '/api/v1/cases/$caseA/files',
        '/api/v1/cases/$caseA/files/file_original/access',
      ]);
      expect(storageAdapter.requests.single.headers['Authorization'], isNull);
    });

    test('resolves a web playback URL without downloading video bytes', () async {
      final apiAdapter = QueueAdapter([
        jsonResponse(200, {
          'data': {
            'files': [
              {
                'id': 'file_original',
                'case_id': caseA,
                'kind': 'original_video',
                'sha256': 'a' * 64,
                'size': 4,
                'mime': 'video/mp4',
                'created_at': '2026-10-15T00:00:00Z',
              },
            ],
            'next_cursor': null,
          },
        }),
        jsonResponse(200, {
          'data': {
            'url': 'https://storage.test/video?signature=temporary',
            'expires_in': 60,
            'file_id': 'file_original',
          },
        }),
      ]);
      final storageAdapter = QueueAdapter([]);
      final service = mediaService(apiAdapter, storageAdapter);

      final url = (await service.originalVideoUrl(caseId: caseA)).url;

      expect(url, 'https://storage.test/video?signature=temporary');
      expect(apiAdapter.requests.map((request) => request.path), [
        '/api/v1/cases/$caseA/files',
        '/api/v1/cases/$caseA/files/file_original/access',
      ]);
      expect(storageAdapter.requests, isEmpty);
      expect(apiAdapter.requests.every(
        (request) => request.headers['Authorization'] == 'Bearer token',
      ), isTrue);
    });
  });

  group('BlackboxVideoNotifier', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('blackbox-poll-test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('polls the exact pending case every 5 seconds until ready', () async {
      final service = _PollingEvidenceService(pendingResponses: 2);
      var now = DateTime.utc(2026, 10, 17);
      final waits = <Duration>[];
      final notifier = BlackboxVideoNotifier(
        evidenceService: service,
        ensureOwnedCase: (_) async {},
        principal: () => 'owner@example.com',
        documentsDirectory: () async => tempDir,
        now: () => now,
        wait: (duration) async {
          waits.add(duration);
          now = now.add(duration);
        },
      );
      addTearDown(notifier.dispose);

      await notifier.fetchAndDownload(caseA);

      expect(service.requestedCaseIds, [caseA, caseA, caseA]);
      expect(waits, [const Duration(seconds: 5), const Duration(seconds: 5)]);
      expect(notifier.state.caseId, caseA);
      expect(notifier.state.status, VideoStatus.ready);
    });

    test('stops pending polling after 120 seconds without claiming upload',
        () async {
      final service = _PollingEvidenceService();
      var now = DateTime.utc(2026, 10, 17);
      final notifier = BlackboxVideoNotifier(
        evidenceService: service,
        ensureOwnedCase: (_) async {},
        principal: () => 'owner@example.com',
        documentsDirectory: () async => tempDir,
        now: () => now,
        wait: (duration) async {
          now = now.add(duration);
        },
      );
      addTearDown(notifier.dispose);

      await notifier.fetchAndDownload(caseA);

      expect(service.requestedCaseIds, everyElement(caseA));
      expect(service.requestedCaseIds, hasLength(25));
      expect(notifier.state.status, VideoStatus.waiting);
      expect(notifier.state.errorMessage, contains('아직 준비되지 않았습니다'));
      expect(notifier.state.errorMessage, isNot(contains('전송하고 있습니다')));
    });

    test('case reset cancels a pending poll before another request', () async {
      final firstWait = Completer<void>();
      final service = _PollingEvidenceService();
      final notifier = BlackboxVideoNotifier(
        evidenceService: service,
        ensureOwnedCase: (_) async {},
        principal: () => 'owner@example.com',
        documentsDirectory: () async => tempDir,
        wait: (_) => firstWait.future,
      );
      addTearDown(notifier.dispose);

      final pending = notifier.fetchAndDownload(caseA);
      await Future<void>.delayed(Duration.zero);
      expect(service.requestedCaseIds, [caseA]);

      notifier.resetForCase(caseA);
      firstWait.complete();
      await pending;

      expect(service.requestedCaseIds, [caseA]);
      expect(notifier.state.caseId, isNull);
    });

    test('screen cancellation stops only its case without publishing state',
        () async {
      final firstWait = Completer<void>();
      final service = _PollingEvidenceService();
      final notifier = BlackboxVideoNotifier(
        evidenceService: service,
        ensureOwnedCase: (_) async {},
        principal: () => 'owner@example.com',
        documentsDirectory: () async => tempDir,
        wait: (_) => firstWait.future,
      );
      addTearDown(notifier.dispose);
      final cancel = notifier.cancellationHandleForCase(caseA);
      final pending = notifier.fetchAndDownload(caseA);
      await Future<void>.delayed(Duration.zero);
      final waitingState = notifier.state;

      cancel();
      await pending;

      expect(service.requestedCaseIds, [caseA]);
      expect(notifier.state, same(waitingState));
    });

    test('stops polling immediately on a non-pending error', () async {
      final service = _PollingEvidenceService(
        terminalError: const EvidenceServiceException('접근 권한이 없습니다.'),
      );
      final notifier = BlackboxVideoNotifier(
        evidenceService: service,
        ensureOwnedCase: (_) async {},
        principal: () => 'owner@example.com',
        documentsDirectory: () async => tempDir,
        wait: (_) async => fail('terminal errors must not schedule a poll'),
      );
      addTearDown(notifier.dispose);

      await notifier.fetchAndDownload(caseA);

      expect(service.requestedCaseIds, [caseA]);
      expect(notifier.state.status, VideoStatus.error);
      expect(notifier.state.errorMessage, '접근 권한이 없습니다.');
    });
  });
}

const caseA = 'case_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

BackendEvidenceService mediaService(
  QueueAdapter apiAdapter,
  QueueAdapter storageAdapter, {
  Future<String?> Function()? accessToken,
}) {
  final apiDio = Dio(BaseOptions(baseUrl: 'http://example.test'));
  apiDio.httpClientAdapter = apiAdapter;
  final storageDio = Dio();
  storageDio.httpClientAdapter = storageAdapter;
  return BackendEvidenceService(
    apiDio: apiDio,
    storageDio: storageDio,
    accessToken: accessToken ?? () async => 'token',
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
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    return responses.removeAt(0);
  }

  @override
  void close({bool force = false}) {}
}

class FakeEvidenceFile implements EvidenceFile {
  FakeEvidenceFile({required this.path, required this.length});

  @override
  final String path;

  final int length;

  @override
  Future<bool> exists() async => true;

  @override
  Future<int> lengthBytes() async => length;

  @override
  Stream<List<int>> openRead() => const Stream<List<int>>.empty();
}

class _PollingEvidenceService extends BackendEvidenceService {
  _PollingEvidenceService({this.pendingResponses, this.terminalError})
      : super(
          apiDio: Dio(),
          storageDio: Dio(),
          accessToken: () async => 'token',
        );

  final int? pendingResponses;
  final EvidenceServiceException? terminalError;
  final List<String> requestedCaseIds = [];

  @override
  Future<DownloadedCaseVideo> downloadOriginalVideo({
    required String caseId,
    required String savePath,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    bool Function()? isCurrent,
  }) async {
    requestedCaseIds.add(caseId);
    if (terminalError != null) throw terminalError!;
    if (pendingResponses == null ||
        requestedCaseIds.length <= pendingResponses!) {
      throw const EvidenceServiceException('아직 전송된 블랙박스 원본 영상이 없습니다.');
    }
    return DownloadedCaseVideo(
      file: BackendCaseFile(
        id: 'file_original',
        caseId: caseId,
        kind: 'original_video',
        sha256: 'a' * 64,
        size: 4,
        mime: 'video/mp4',
        createdAt: DateTime.utc(2026, 10, 17),
      ),
      localPath: savePath,
    );
  }
}
