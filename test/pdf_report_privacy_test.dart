import 'dart:io';

import 'package:blackbox_driver_care/services/local_files.dart';
import 'package:blackbox_driver_care/services/pdf_report_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('blackbox-pdf-export');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('real local PDF export is scoped to owner and backend case', () async {
    final owner = LocalAppFiles.ownerScope('owner@example.com');
    final otherOwner = LocalAppFiles.ownerScope('other@example.com');
    final analyzedAt = DateTime.utc(2026, 10, 15, 1, 2, 3);
    final data = ReportData(
      accidentId: caseA,
      analyzedAt: analyzedAt,
      address: '-',
      weatherText: '',
      rateOurPct: 60,
      rateOtherPct: 40,
      aiSummary: '검증된 분석',
      lawStatusNote: '법령 검색 결과 없음',
    );

    final path = await PdfReportService.saveToLocal(
      data,
      ownerScope: owner,
      directory: directory,
    );

    final file = File(path);
    final expectedName =
        'DriveGuard_${owner}_${caseA}_report_${analyzedAt.millisecondsSinceEpoch}.pdf';
    expect(file.existsSync(), isTrue);
    expect(file.path.split(Platform.pathSeparator).last, expectedName);
    expect(String.fromCharCodes(await file.openRead(0, 4).first), '%PDF');
    expect(
      (await LocalAppFiles.listOwnedPdfs(directory, owner))
          .map((item) => item.path),
      [file.path],
    );
    expect(await LocalAppFiles.listOwnedPdfs(directory, otherOwner), isEmpty);
  });
}

const caseA = 'case_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
