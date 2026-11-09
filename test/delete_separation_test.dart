import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:blackbox_driver_care/screens/report/my_reports_screen.dart';
import 'package:blackbox_driver_care/screens/accident/accident_video_list_screen.dart';
import 'package:blackbox_driver_care/services/auth_service.dart';
import 'package:blackbox_driver_care/services/case_service.dart';
import 'task4_async_races_test.dart' show TestAuth;

const caseId = 'case_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class DeleteAdapter implements HttpClientAdapter {
  final writes = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? body, Future? cancel) async {
    Object data;
    var status = 200;
    if (options.method == 'DELETE') {
      writes.add(options);
      if (options.path.endsWith('/reports')) {
        data = {
          'case_id': caseId,
          'status': 'reports_deleted',
          'deleted_reports': 1,
          'media_preserved': true
        };
      } else {
        status = 202;
        data = {
          'case_id': caseId,
          'status': 'delete_requested',
          'job_id': 'job_delete'
        };
      }
    } else if (options.path.endsWith('/reports')) {
      data = {'reports': [], 'next_cursor': null};
    } else {
      data = {
        'cases': [
          {
            'id': caseId,
            'device_id': 'dev_owned',
            'title': 'Fixture video',
            'status': 'done',
            'created_at': '2026-11-09T00:00:00Z'
          }
        ],
        'next_cursor': null
      };
    }
    return ResponseBody.fromString(jsonEncode({'data': data}), status,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('delete-separation-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => folder.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await folder.delete(recursive: true);
  });
  Future<DeleteAdapter> show(WidgetTester tester, Widget child) async {
    final adapter = DeleteAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
      ..httpClientAdapter = adapter;
    final service = CaseService(
        dio: dio,
        accessToken: () async => 'token',
        savedDevice: () async => (id: 'dev_owned', name: 'Front'),
        activeCase: () => null,
        onActiveCaseChanged: (_) {});
    final auth = TestAuth()..loginAs('fixture@example.test');
    await tester.pumpWidget(ProviderScope(overrides: [
      authProvider.overrideWith((ref) => auth),
      caseServiceProvider.overrideWithValue(service)
    ], child: MaterialApp(home: child)));
    await tester.pumpAndSettle();
    return adapter;
  }

  testWidgets(
      'report deletion preserves cached video and uses reports endpoint',
      (tester) async {
    final video = File('${folder.path}/blackbox_$caseId.mp4');
    video.writeAsStringSync('fixture');
    final adapter = await show(tester, const MyReportsScreen());
    await tester.tap(find.text('Fixture video'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('기록 삭제'));
    await tester.pumpAndSettle();
    expect(find.textContaining('영상·사진·GPS'), findsOneWidget);
    await tester.tap(find.text('삭제 요청'));
    await tester.pumpAndSettle();
    expect(adapter.writes.single.path, '/api/v1/cases/$caseId/reports');
    expect(video.existsSync(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('video deletion is explicit and cancellation sends no request',
      (tester) async {
    final adapter = await show(tester, const AccidentVideoListScreen());
    await tester.tap(find.byTooltip('영상과 사건 삭제'));
    await tester.pumpAndSettle();
    expect(find.textContaining('되돌릴 수 없습니다'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(adapter.writes, isEmpty);
    await tester.tap(find.byTooltip('영상과 사건 삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '영상과 사건 삭제'));
    await tester.pumpAndSettle();
    expect(adapter.writes.single.path, '/api/v1/cases/$caseId');
    expect(find.text('Fixture video'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
