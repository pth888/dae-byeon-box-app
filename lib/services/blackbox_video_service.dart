// lib/services/blackbox_video_service.dart
//
// 소유한 백엔드 사건의 증거 업로드 및 블랙박스 원본 영상 재생.

import 'dart:async';
import 'dart:typed_data';
import 'dart:io' if (dart.library.html) '../utils/io_web_stub.dart';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'auth_service.dart';
import 'case_service.dart';
import 'consent_service.dart';
import 'local_files.dart';

enum EvidenceKind { photo, audio, additionalVideo }

extension on EvidenceKind {
  String get apiName => switch (this) {
        EvidenceKind.photo => 'evidence_photo',
        EvidenceKind.audio => 'evidence_audio',
        EvidenceKind.additionalVideo => 'additional_video',
      };

  int get maxBytes => switch (this) {
        EvidenceKind.photo => 20 * 1024 * 1024,
        EvidenceKind.audio => 100 * 1024 * 1024,
        EvidenceKind.additionalVideo => 2 * 1024 * 1024 * 1024,
      };

  Set<String> get allowedMimes => switch (this) {
        EvidenceKind.photo => const {'image/jpeg', 'image/png'},
        EvidenceKind.audio => const {'audio/mp4', 'audio/aac', 'audio/mpeg'},
        EvidenceKind.additionalVideo => const {
            'video/mp4',
            'video/quicktime',
            'video/x-matroska',
          },
      };
}

class EvidenceServiceException implements Exception {
  const EvidenceServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class InvalidEvidenceException extends EvidenceServiceException {
  const InvalidEvidenceException(super.message);
}

class EvidenceTooLargeException extends EvidenceServiceException {
  const EvidenceTooLargeException(super.message);
}

abstract interface class EvidenceFile {
  String get path;
  Future<bool> exists();
  Future<int> lengthBytes();
  Stream<List<int>> openRead();
}

class IoEvidenceFile implements EvidenceFile {
  IoEvidenceFile(String path) : _file = File(path);

  final File _file;

  @override
  String get path => _file.path;

  @override
  Future<bool> exists() => _file.exists();

  @override
  Future<int> lengthBytes() => _file.length();

  @override
  Stream<List<int>> openRead() => _file.openRead();
}

class BackendCaseFile {
  const BackendCaseFile({
    required this.id,
    required this.caseId,
    required this.kind,
    required this.sha256,
    required this.size,
    required this.mime,
    required this.createdAt,
  });

  final String id;
  final String caseId;
  final String kind;
  final String sha256;
  final int size;
  final String mime;
  final DateTime createdAt;

  factory BackendCaseFile.fromJson(
    Map<String, dynamic> json, {
    required String expectedCaseId,
  }) {
    final id = json['id'];
    final caseId = json['case_id'];
    final kind = json['kind'];
    final hash = json['sha256'];
    final size = json['size'];
    final mime = json['mime'];
    final createdAtRaw = json['created_at'];
    final createdAt = createdAtRaw is String
        ? DateTime.tryParse(createdAtRaw)?.toUtc()
        : null;
    if (id is! String ||
        id.isEmpty ||
        caseId != expectedCaseId ||
        kind is! String ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        size is! int ||
        size <= 0 ||
        mime is! String ||
        createdAt == null) {
      throw const EvidenceServiceException('서버의 증거 파일 응답이 올바르지 않습니다.');
    }
    return BackendCaseFile(
      id: id,
      caseId: caseId as String,
      kind: kind,
      sha256: hash,
      size: size,
      mime: mime,
      createdAt: createdAt,
    );
  }
}

bool _isAiEligibleAttachment(BackendCaseFile file) => switch (file.kind) {
      'evidence_photo' => file.mime == 'image/jpeg' || file.mime == 'image/png',
      'additional_video' => file.mime == 'video/mp4',
      _ => false,
    };

void validateAiAttachmentSelection(List<BackendCaseFile> files) {
  if (files.length > 3) {
    throw const EvidenceServiceException('첨부 파일은 최대 3개까지 선택할 수 있습니다.');
  }
  if (files.any((file) =>
      file.kind != 'evidence_photo' && file.kind != 'additional_video')) {
    throw const EvidenceServiceException('AI 첨부는 현장 사진과 추가 영상만 지원합니다.');
  }
  if (files.any((file) => !_isAiEligibleAttachment(file))) {
    throw const EvidenceServiceException(
      'AI 분석은 JPEG/PNG 사진과 MP4 영상만 지원합니다.',
    );
  }
  final totalBytes = files.fold<int>(0, (sum, file) => sum + file.size);
  if (totalBytes > 10 * 1024 * 1024) {
    throw const EvidenceServiceException('선택한 자료 합계는 10MB 이하여야 합니다');
  }
}

class DownloadedCaseVideo {
  const DownloadedCaseVideo({required this.file, required this.localPath});

  final BackendCaseFile file;
  final String localPath;
}

class BackendEvidenceService {
  BackendEvidenceService({
    required Dio apiDio,
    required Dio storageDio,
    required AccessTokenProvider accessToken,
    bool Function()? canCollect,
  })  : _apiDio = apiDio,
        _storageDio = storageDio,
        _accessToken = accessToken,
        _canCollect = canCollect ?? (() => true);

  final Dio _apiDio;
  final Dio _storageDio;
  final AccessTokenProvider _accessToken;
  final bool Function() _canCollect;
  static int _downloadSequence = 0;

  Future<BackendCaseFile> uploadEvidence({
    required String caseId,
    required String path,
    required EvidenceKind kind,
    required String mime,
  }) =>
      uploadEvidenceFile(
        caseId: caseId,
        file: IoEvidenceFile(path),
        kind: kind,
        mime: mime,
      );

  Future<BackendCaseFile> uploadEvidenceFile({
    required String caseId,
    required EvidenceFile file,
    required EvidenceKind kind,
    required String mime,
  }) async {
    if (!_canCollect()) {
      throw const EvidenceServiceException(
        '증거 수집 전에 개인정보 및 위치정보 동의가 필요합니다.',
      );
    }
    _requireCaseId(caseId);
    if (!kind.allowedMimes.contains(mime)) {
      throw InvalidEvidenceException('${kind.apiName} 파일 형식이 허용되지 않습니다.');
    }
    if (!await file.exists()) {
      throw const InvalidEvidenceException('업로드할 파일을 찾을 수 없습니다.');
    }
    final size = await file.lengthBytes();
    if (size <= 0) {
      throw const InvalidEvidenceException('빈 파일은 업로드할 수 없습니다.');
    }
    if (size > kind.maxBytes) {
      throw EvidenceTooLargeException('${kind.apiName} 파일이 허용 크기를 초과했습니다.');
    }

    final digest = await sha256.bind(file.openRead()).first;
    final token = await _requiredToken();
    final issue = await _apiDio.post(
      '/api/v1/cases/$caseId/uploads',
      data: {
        'file_kind': kind.apiName,
        'sha256': digest.toString(),
        'size': size,
        'mime': mime,
      },
      options: Options(headers: _bearer(token)),
    );
    if (issue.statusCode != 201) {
      throw EvidenceServiceException(_apiMessage(issue, '증거 업로드를 시작할 수 없습니다.'));
    }
    final issueData = _envelope(issue);
    final uploadId = issueData['upload_id'];
    final putUrl = issueData['put_url'];
    final requiredHeadersRaw = issueData['required_headers'];
    if (uploadId is! String ||
        uploadId.isEmpty ||
        putUrl is! String ||
        Uri.tryParse(putUrl)?.hasScheme != true ||
        requiredHeadersRaw is! Map) {
      throw const EvidenceServiceException('서버의 업로드 주소 응답이 올바르지 않습니다.');
    }
    final requiredHeaders = <String, String>{};
    for (final entry in requiredHeadersRaw.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const EvidenceServiceException('서버의 업로드 헤더 응답이 올바르지 않습니다.');
      }
      requiredHeaders[entry.key as String] = entry.value as String;
    }
    final put = await _storageDio.putUri(
      Uri.parse(putUrl),
      data: file.openRead(),
      options: Options(
        headers: requiredHeaders,
        responseType: ResponseType.plain,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
    if (put.statusCode == null ||
        put.statusCode! < 200 ||
        put.statusCode! >= 300) {
      throw const EvidenceServiceException('증거 파일 저장에 실패했습니다.');
    }
    final completionToken = await _requiredToken();
    final complete = await _apiDio.post(
      '/api/v1/cases/$caseId/uploads/$uploadId/complete',
      options: Options(headers: _bearer(completionToken)),
    );
    if (complete.statusCode != 200) {
      throw EvidenceServiceException(
          _apiMessage(complete, '증거 업로드를 완료하지 못했습니다.'));
    }
    final uploaded = BackendCaseFile.fromJson(
      _map(_envelope(complete)['file']),
      expectedCaseId: caseId,
    );
    if (uploaded.kind != kind.apiName ||
        uploaded.sha256 != digest.toString() ||
        uploaded.size != size ||
        uploaded.mime != mime) {
      throw const EvidenceServiceException('완료된 증거 파일 정보가 요청과 일치하지 않습니다.');
    }
    return uploaded;
  }

  Future<DownloadedCaseVideo> downloadOriginalVideo({
    required String caseId,
    required String savePath,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    bool Function()? isCurrent,
  }) async {
    _requireCaseId(caseId);
    final cleanupGeneration = LocalAppFiles.accountCleanupGeneration;
    void requireCurrent() {
      if (cancelToken?.isCancelled == true ||
          cleanupGeneration != LocalAppFiles.accountCleanupGeneration ||
          isCurrent?.call() == false) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: savePath),
          reason: 'The account or download request changed',
        );
      }
    }

    final token = await _requiredToken();
    requireCurrent();
    final resolved = await _resolveOriginalVideo(
      caseId: caseId,
      token: token,
      cancelToken: cancelToken,
      requireCurrent: requireCurrent,
    );
    final original = resolved.file;
    final url = resolved.url;
    final partial = File('$savePath.part_'
        '${DateTime.now().microsecondsSinceEpoch}_${++_downloadSequence}');
    try {
      await _storageDio.downloadUri(
        Uri.parse(url),
        partial.path,
        options: Options(
          responseType: ResponseType.bytes,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 300,
        ),
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
      );
      requireCurrent();
      // Publish without an await between the lifecycle check and atomic rename.
      partial.renameSync(savePath);
    } finally {
      if (partial.existsSync()) partial.deleteSync();
    }
    return DownloadedCaseVideo(file: original, localPath: savePath);
  }

  /// 원본 영상 파일 정보와 사전서명 접근 주소를 받는다.
  Future<({BackendCaseFile file, String url})> _resolveOriginalVideo({
    required String caseId,
    required String token,
    required CancelToken? cancelToken,
    required void Function() requireCurrent,
  }) async {
    String? cursor;
    BackendCaseFile? original;
    do {
      final response = await _apiDio.get(
        '/api/v1/cases/$caseId/files',
        queryParameters: {'limit': 100, if (cursor != null) 'cursor': cursor},
        options: Options(headers: _bearer(token)),
        cancelToken: cancelToken,
      );
      requireCurrent();
      if (response.statusCode != 200) {
        throw EvidenceServiceException(
            _apiMessage(response, '블랙박스 파일을 확인할 수 없습니다.'));
      }
      final data = _envelope(response);
      final files = data['files'];
      if (files is! List) {
        throw const EvidenceServiceException('서버의 파일 목록 응답이 올바르지 않습니다.');
      }
      for (final item in files) {
        final parsed = BackendCaseFile.fromJson(
          _map(item),
          expectedCaseId: caseId,
        );
        if (parsed.kind == 'original_video') {
          original = parsed;
          break;
        }
      }
      cursor = _cursor(data['next_cursor']);
    } while (original == null && cursor != null);
    if (original == null) {
      throw const EvidenceServiceException('아직 전송된 블랙박스 원본 영상이 없습니다.');
    }
    final access = await _apiDio.get(
      '/api/v1/cases/$caseId/files/${original.id}/access',
      options: Options(headers: _bearer(token)),
      cancelToken: cancelToken,
    );
    requireCurrent();
    if (access.statusCode != 200) {
      throw EvidenceServiceException(
          _apiMessage(access, '블랙박스 영상 접근 주소를 받을 수 없습니다.'));
    }
    final accessData = _envelope(access);
    final url = accessData['url'];
    if (accessData['file_id'] != original.id ||
        url is! String ||
        Uri.tryParse(url)?.hasScheme != true) {
      throw const EvidenceServiceException('서버의 영상 접근 응답이 올바르지 않습니다.');
    }
    return (file: original, url: url);
  }

  /// 웹용: 영상을 내려받지 않고, 브라우저가 바로 재생할 접근 주소만 받는다.
  Future<({BackendCaseFile file, String url})> originalVideoUrl({
    required String caseId,
    CancelToken? cancelToken,
    bool Function()? isCurrent,
  }) async {
    _requireCaseId(caseId);
    void requireCurrent() {
      if (cancelToken?.isCancelled == true || isCurrent?.call() == false) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: caseId),
          reason: 'The account or video request changed',
        );
      }
    }

    final token = await _requiredToken();
    requireCurrent();
    return _resolveOriginalVideo(
      caseId: caseId,
      token: token,
      cancelToken: cancelToken,
      requireCurrent: requireCurrent,
    );
  }

  /// 증거 파일 하나의 임시 접근 주소 (현장 사진·영상 보기용)
  Future<String> fileAccessUrl({
    required String caseId,
    required String fileId,
  }) async {
    _requireCaseId(caseId);
    final token = await _requiredToken();
    final access = await _apiDio.get(
      '/api/v1/cases/$caseId/files/$fileId/access',
      options: Options(headers: _bearer(token)),
    );
    if (access.statusCode != 200) {
      throw EvidenceServiceException(
          _apiMessage(access, '파일 접근 주소를 받을 수 없습니다.'));
    }
    final data = _envelope(access);
    final url = data['url'];
    if (data['file_id'] != fileId ||
        url is! String ||
        Uri.tryParse(url)?.hasScheme != true) {
      throw const EvidenceServiceException('서버의 파일 접근 응답이 올바르지 않습니다.');
    }
    return url;
  }

  /// 현장 사진 원본을 메모리로 받는다 (리포트에 넣을 때). 최대 [maxCount]장, 최신순.
  Future<List<Uint8List>> downloadScenePhotos(
    String caseId, {
    int maxCount = 6,
    int maxBytesEach = 8 * 1024 * 1024,
  }) async {
    final files = (await listCaseFiles(caseId))
        .where((f) =>
            f.kind == 'evidence_photo' &&
            f.size <= maxBytesEach &&
            (f.mime == 'image/jpeg' || f.mime == 'image/png'))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final photos = <Uint8List>[];
    for (final file in files.take(maxCount)) {
      try {
        final url = await fileAccessUrl(caseId: caseId, fileId: file.id);
        final response = await _storageDio.getUri<List<int>>(
          Uri.parse(url),
          options: Options(responseType: ResponseType.bytes),
        );
        final data = response.data;
        if (response.statusCode == 200 && data != null && data.isNotEmpty) {
          photos.add(Uint8List.fromList(data));
        }
      } catch (_) {
        // 한 장이 실패해도 나머지는 넣는다
      }
    }
    return photos;
  }

  /// 사건에 올라간 모든 증거 파일 목록
  Future<List<BackendCaseFile>> listCaseFiles(String caseId) async {
    _requireCaseId(caseId);
    final token = await _requiredToken();
    final files = <BackendCaseFile>[];
    String? cursor;
    do {
      final response = await _apiDio.get(
        '/api/v1/cases/$caseId/files',
        queryParameters: {'limit': 100, if (cursor != null) 'cursor': cursor},
        options: Options(headers: _bearer(token)),
      );
      if (response.statusCode != 200) {
        throw EvidenceServiceException(
          _apiMessage(response, '증거 파일 목록을 불러오지 못했습니다.'),
        );
      }
      final data = _envelope(response);
      final items = data['files'];
      if (items is! List) {
        throw const EvidenceServiceException('서버의 파일 목록 응답이 올바르지 않습니다.');
      }
      for (final item in items) {
        files.add(BackendCaseFile.fromJson(_map(item), expectedCaseId: caseId));
      }
      cursor = _cursor(data['next_cursor']);
    } while (cursor != null);
    return files;
  }

  Future<List<BackendCaseFile>> listAiEligibleFiles(String caseId) async {
    _requireCaseId(caseId);
    final token = await _requiredToken();
    final eligible = <BackendCaseFile>[];
    String? cursor;
    do {
      final response = await _apiDio.get(
        '/api/v1/cases/$caseId/files',
        queryParameters: {'limit': 100, if (cursor != null) 'cursor': cursor},
        options: Options(headers: _bearer(token)),
      );
      if (response.statusCode != 200) {
        throw EvidenceServiceException(
          _apiMessage(response, '첨부 가능한 증거 파일을 불러오지 못했습니다.'),
        );
      }
      final data = _envelope(response);
      final files = data['files'];
      if (files is! List) {
        throw const EvidenceServiceException('서버의 파일 목록 응답이 올바르지 않습니다.');
      }
      for (final item in files) {
        final file = BackendCaseFile.fromJson(
          _map(item),
          expectedCaseId: caseId,
        );
        if (_isAiEligibleAttachment(file)) {
          eligible.add(file);
        }
      }
      cursor = _cursor(data['next_cursor']);
    } while (cursor != null);
    return eligible;
  }

  Future<String> _requiredToken() async {
    final token = await _accessToken();
    if (token == null || token.isEmpty) {
      throw const EvidenceServiceException('로그인이 필요합니다.');
    }
    return token;
  }
}

// ── 블랙박스 이벤트 모델 ─────────────────────────────────
class BlackboxEvent {
  final String deviceId;
  final String eventId;
  final DateTime? triggerUtc;
  final String? triggerKst;
  final double? lat;
  final double? lon;
  final String videoFileUrl;
  final String? webVideoFileUrl;
  final String? metadataFileUrl;
  final String? modelAnalysisUrl;

  BlackboxEvent({
    required this.deviceId,
    required this.eventId,
    this.triggerUtc,
    this.triggerKst,
    this.lat,
    this.lon,
    required this.videoFileUrl,
    this.webVideoFileUrl,
    this.metadataFileUrl,
    this.modelAnalysisUrl,
  });

  factory BlackboxEvent.fromFile(BackendCaseFile file) => BlackboxEvent(
        deviceId: '',
        eventId: file.id,
        triggerUtc: file.createdAt,
        videoFileUrl: '',
      );

  factory BlackboxEvent.fromJson(Map<String, dynamic> json) {
    final gps = json['gps'] as Map<String, dynamic>?;
    return BlackboxEvent(
      deviceId: (json['device_id'] ?? '') as String,
      eventId: (json['event_id'] ?? '') as String,
      triggerUtc: json['trigger_utc'] != null
          ? DateTime.tryParse(json['trigger_utc'] as String)
          : null,
      triggerKst: json['trigger_kst'] as String?,
      lat: (gps?['lat'] as num?)?.toDouble(),
      lon: (gps?['lon'] as num?)?.toDouble(),
      videoFileUrl: (json['video_file_url'] ?? '') as String,
      webVideoFileUrl: json['web_video_file_url'] as String?,
      metadataFileUrl: json['metadata_file_url'] as String?,
      modelAnalysisUrl: json['model_analysis_file_url'] as String?,
    );
  }
}

// ── 영상 상태 ────────────────────────────────────────────
enum VideoStatus { waiting, fetching, downloading, ready, error }

class BlackboxVideoState {
  final String? caseId;
  final VideoStatus status;
  final BlackboxEvent? event;
  final String? localPath;
  final double downloadProgress;
  final String? errorMessage;

  const BlackboxVideoState({
    this.caseId,
    this.status = VideoStatus.waiting,
    this.event,
    this.localPath,
    this.downloadProgress = 0.0,
    this.errorMessage,
  });

  BlackboxVideoState copyWith({
    String? caseId,
    VideoStatus? status,
    BlackboxEvent? event,
    String? localPath,
    double? downloadProgress,
    String? errorMessage,
  }) =>
      BlackboxVideoState(
        caseId: caseId ?? this.caseId,
        status: status ?? this.status,
        event: event ?? this.event,
        localPath: localPath ?? this.localPath,
        downloadProgress: downloadProgress ?? this.downloadProgress,
        errorMessage: errorMessage,
      );

  String get progressPercent => '${(downloadProgress * 100).toInt()}%';
}

// ── Notifier ─────────────────────────────────────────────
class BlackboxVideoNotifier extends StateNotifier<BlackboxVideoState> {
  BlackboxVideoNotifier({
    required BackendEvidenceService evidenceService,
    required Future<void> Function(String caseId) ensureOwnedCase,
    required String? Function() principal,
    Future<dynamic> Function()? documentsDirectory,
    DateTime Function()? now,
    Future<void> Function(Duration duration)? wait,
    this.pollInterval = const Duration(seconds: 5),
    this.pollTimeout = const Duration(seconds: 120),
  })  : _evidenceService = evidenceService,
        _ensureOwnedCase = ensureOwnedCase,
        _principal = principal,
        _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory,
        _now = now ?? DateTime.now,
        _wait = wait,
        super(const BlackboxVideoState());

  final BackendEvidenceService _evidenceService;
  final Future<void> Function(String caseId) _ensureOwnedCase;
  final String? Function() _principal;
  final Future<dynamic> Function() _documentsDirectory;
  final DateTime Function() _now;
  final Future<void> Function(Duration duration)? _wait;
  final Duration pollInterval;
  final Duration pollTimeout;
  int _request = 0;
  CancelToken? _cancelToken;
  String? _caseId;

  // ── 최신 이벤트 조회 + 영상 다운로드 ────────────────────
  Future<void> fetchAndDownload(String accidentId) async {
    final request = ++_request;
    _cancelToken?.cancel('A newer download was requested');
    final cancelToken = _cancelToken = CancelToken();
    final principal = _principal();
    final cleanupGeneration = LocalAppFiles.accountCleanupGeneration;
    bool current() =>
        mounted &&
        request == _request &&
        principal != null &&
        principal == _principal() &&
        cleanupGeneration == LocalAppFiles.accountCleanupGeneration;
    if (principal == null) {
      reset();
      return;
    }
    _caseId = accidentId;
    state =
        BlackboxVideoState(caseId: accidentId, status: VideoStatus.fetching);
    try {
      await _ensureOwnedCase(accidentId);
      if (!current()) return;
      if (kIsWeb) {
        await _resolveForWeb(accidentId, cancelToken, current);
        return;
      }
      final dir = await _documentsDirectory();
      if (!current()) return;
      final savePath = '${dir.path}/blackbox_$accidentId.mp4';
      final pollingStartedAt = _now();
      while (current()) {
        try {
          state = state.copyWith(status: VideoStatus.fetching);
          final downloaded = await _evidenceService.downloadOriginalVideo(
            caseId: accidentId,
            savePath: savePath,
            cancelToken: cancelToken,
            isCurrent: current,
            onProgress: (received, total) {
              if (current() && total > 0) {
                state = state.copyWith(
                  status: VideoStatus.downloading,
                  downloadProgress: received / total,
                );
              }
            },
          );
          if (!current()) return;
          state = BlackboxVideoState(
            caseId: accidentId,
            status: VideoStatus.ready,
            event: BlackboxEvent.fromFile(downloaded.file),
            localPath: downloaded.localPath,
            downloadProgress: 1,
          );
          return;
        } on EvidenceServiceException catch (error) {
          if (!error.message.contains('아직 전송된')) rethrow;
          if (!current()) return;
          final timedOut = _now().difference(pollingStartedAt) >= pollTimeout;
          state = BlackboxVideoState(
            caseId: accidentId,
            status: VideoStatus.waiting,
            errorMessage: timedOut
                ? '해당 사고의 원본 영상이 아직 준비되지 않았습니다. 잠시 후 다시 확인해 주세요.'
                : '해당 사고의 원본 영상이 아직 준비되지 않았습니다. 자동으로 다시 확인합니다.',
          );
          if (timedOut) return;
          await _waitForNextPoll(cancelToken);
        }
      }
    } catch (error) {
      if (!current()) return;
      state = BlackboxVideoState(
        caseId: accidentId,
        status: VideoStatus.error,
        errorMessage: error.toString(),
      );
    } finally {
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
    }
  }

  // 웹: 브라우저는 파일 저장이 안 되므로 사전서명 주소로 바로 스트리밍한다.
  // (localPath 자리에 재생 주소를 넣고, 플레이어가 kIsWeb 이면 네트워크 재생)
  Future<void> _resolveForWeb(
    String accidentId,
    CancelToken cancelToken,
    bool Function() current,
  ) async {
    final pollingStartedAt = _now();
    while (current()) {
      try {
        state = state.copyWith(status: VideoStatus.fetching);
        final resolved = await _evidenceService.originalVideoUrl(
          caseId: accidentId,
          cancelToken: cancelToken,
          isCurrent: current,
        );
        if (!current()) return;
        state = BlackboxVideoState(
          caseId: accidentId,
          status: VideoStatus.ready,
          event: BlackboxEvent.fromFile(resolved.file),
          localPath: resolved.url,
          downloadProgress: 1,
        );
        return;
      } on EvidenceServiceException catch (error) {
        if (!error.message.contains('아직 전송된')) rethrow;
        if (!current()) return;
        final timedOut = _now().difference(pollingStartedAt) >= pollTimeout;
        state = BlackboxVideoState(
          caseId: accidentId,
          status: VideoStatus.waiting,
          errorMessage: timedOut
              ? '해당 사고의 원본 영상이 아직 준비되지 않았습니다. 잠시 후 다시 확인해 주세요.'
              : '해당 사고의 원본 영상이 아직 준비되지 않았습니다. 자동으로 다시 확인합니다.',
        );
        if (timedOut) return;
        await _waitForNextPoll(cancelToken);
      }
    }
  }

  Future<Map<String, dynamic>?> fetchAnalysis() async {
    return null;
  }

  // ── AI 분석 결과에서 과실 정보 추출 ─────────────────────
  // model_analysis.json → 앱이 쓸 수 있는 과실 데이터로 변환
  Future<VideoAnalysisResult?> fetchAnalysisResult() async {
    return null;
  }

  Future<void> retry(String accidentId) async {
    await fetchAndDownload(accidentId);
  }

  Future<void> _waitForNextPoll(CancelToken cancelToken) {
    final wait = _wait;
    if (wait != null) {
      return Future.any<void>([
        wait(pollInterval),
        cancelToken.whenCancel.then<void>((_) {}),
      ]);
    }

    final completed = Completer<void>();
    late final Timer timer;
    void finish() {
      if (!completed.isCompleted) completed.complete();
    }

    timer = Timer(pollInterval, finish);
    cancelToken.whenCancel.then<void>((_) {
      timer.cancel();
      finish();
    });
    return completed.future;
  }

  void reset() {
    ++_request;
    _cancelToken?.cancel('The account or case changed');
    _cancelToken = null;
    _caseId = null;
    state = const BlackboxVideoState();
  }

  void resetForCase(String caseId) {
    if (_caseId == caseId) reset();
  }

  void Function() cancellationHandleForCase(String caseId) {
    final principal = _principal();
    return () {
      if (!mounted ||
          principal == null ||
          _principal() != principal ||
          _caseId != caseId) {
        return;
      }
      ++_request;
      _cancelToken?.cancel('The response screen was disposed');
      _cancelToken = null;
      _caseId = null;
    };
  }

  @override
  void dispose() {
    ++_request;
    _cancelToken?.cancel('The video provider was disposed');
    super.dispose();
  }
}

// ── AI 영상 분석 결과 (과실 정보) ────────────────────────
class VideoAnalysisResult {
  final double myFaultRatio;
  final double opponentFaultRatio;
  final String accidentType; // sudden_stop 등
  final String accidentObject; // pedestrian 등
  final String sceneSummary; // 장면 설명
  final List<String> legalQueries; // 판례 검색 키워드

  VideoAnalysisResult({
    required this.myFaultRatio,
    required this.opponentFaultRatio,
    required this.accidentType,
    required this.accidentObject,
    required this.sceneSummary,
    required this.legalQueries,
  });

  // 사고 유형 한글 변환
  String get accidentTypeKo {
    switch (accidentType) {
      case 'sudden_stop':
        return '급정거 추돌';
      case 'rear_end_collision':
      case 'rear_end':
        return '후방 추돌';
      case 'intersection':
        return '교차로 사고';
      case 'side_collision':
        return '측면 충돌';
      case 'lane_change':
        return '차로 변경 사고';
      case 'head_on':
        return '정면 충돌';
      case 'pedestrian':
        return '보행자 사고';
      default:
        return accidentType;
    }
  }

  // 사고 대상 한글 변환
  String get accidentObjectKo {
    switch (accidentObject) {
      case 'pedestrian':
        return '보행자';
      case 'vehicle':
        return '차량';
      case 'motorcycle':
        return '이륜차';
      case 'bicycle':
        return '자전거';
      case 'object':
        return '고정물';
      default:
        return accidentObject;
    }
  }
}

// ── Provider ─────────────────────────────────────────────
final backendEvidenceServiceProvider = Provider<BackendEvidenceService>((ref) {
  final apiDio = Dio(
    BaseOptions(
      baseUrl: kApiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      headers: {'Content-Type': 'application/json'},
      validateStatus: (status) => status != null && status < 500,
    ),
  );
  return BackendEvidenceService(
    apiDio: apiDio,
    storageDio: Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(minutes: 5),
      ),
    ),
    accessToken: () => ref.read(authProvider.notifier).validAccessToken(),
    canCollect: () => ref.read(consentControllerProvider).canCollect,
  );
});

final blackboxVideoProvider =
    StateNotifierProvider<BlackboxVideoNotifier, BlackboxVideoState>(
  (ref) {
    final notifier = BlackboxVideoNotifier(
      evidenceService: ref.read(backendEvidenceServiceProvider),
      ensureOwnedCase: (caseId) async {
        await ref.read(caseServiceProvider).selectOwnedCase(caseId);
      },
      principal: () => authenticatedPrincipal(ref.read(authProvider)),
    );
    ref.listen<String?>(authProvider.select(authenticatedPrincipal),
        (previous, next) {
      if (previous != next) notifier.reset();
    });
    return notifier;
  },
);

void _requireCaseId(String caseId) {
  if (!CaseService.isBackendCaseId(caseId)) {
    throw const EvidenceServiceException('유효한 사고 사건이 필요합니다.');
  }
}

Map<String, String> _bearer(String token) => {'Authorization': 'Bearer $token'};

Map<String, dynamic> _envelope(Response<dynamic> response) {
  final body = response.data;
  if (body is! Map || body['data'] is! Map) {
    throw const EvidenceServiceException('서버 응답이 올바르지 않습니다.');
  }
  return Map<String, dynamic>.from(body['data'] as Map);
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map) {
    throw const EvidenceServiceException('서버 응답 항목이 올바르지 않습니다.');
  }
  return Map<String, dynamic>.from(value);
}

String? _cursor(Object? value) {
  if (value == null) return null;
  if (value is String && value.isNotEmpty) return value;
  throw const EvidenceServiceException('서버 페이지 정보가 올바르지 않습니다.');
}

String _apiMessage(Response<dynamic> response, String fallback) {
  final body = response.data;
  if (body is Map && body['error'] is Map) {
    final message = (body['error'] as Map)['message'];
    if (message is String && message.isNotEmpty) return message;
  }
  return fallback;
}
