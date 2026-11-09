// lib/services/pdf_report_service.dart
//
// 담당 기능: 정밀 사고 분석 리포트 PDF 생성 (흰 배경 · 한글 폰트)
//   1장  결론 · 결과 확실도 · 과실비율 확률 분포 · 사고 정보(+지도) · AI 설명
//   2장  사고 유형 후보 · 분석 영상 구간 · 판단에 들어간 입력
//   3장  법령·판례 근거 (쟁점별, 원문 전체)
//   4장  다음에 할 일 · 안내
//
// 긴 원문은 여러 문단으로 나눠 페이지를 넘어가도 잘리지 않게 한다.
//
// 사용 패키지: pdf, printing, path_provider

import 'dart:io' if (dart.library.html) '../utils/io_web_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'local_files.dart';
import 'consent_service.dart';

// ══════════════════════════════════════════════════════════
//  리포트 데이터
// ══════════════════════════════════════════════════════════

/// 과실비율 후보 하나 (우리 차량 기준 %)
class ReportRatioCandidate {
  const ReportRatioCandidate({required this.ourPct, required this.prob});
  final int ourPct;
  final double prob;
}

/// 사고 유형 후보 하나
class ReportTypeCandidate {
  const ReportTypeCandidate({
    required this.code,
    required this.prob,
    this.description,
    this.detail,
    this.baseOurPct,
    this.baseOtherPct,
  });
  final int code;
  final double prob;

  /// 도로·사고 상황 (사고 유형 표의 첫 줄)
  final String? description;

  /// 양쪽 차량의 행동 (두 번째 줄)
  final String? detail;

  /// 과실비율 인정기준표의 기본 과실
  final int? baseOurPct;
  final int? baseOtherPct;
}

/// 법령 또는 판례 원문 하나
class ReportLawRef {
  const ReportLawRef({
    required this.title,
    required this.isPrecedent,
    required this.fromVideo,
    required this.text,
    this.url,
  });
  final String title;
  final bool isPrecedent;
  final bool fromVideo; // true: 영상에서 확인, false: 사용자 입력 기반
  final String text; // 서버가 준 원문 전체
  final String? url;
}

/// 쟁점 하나와 그 근거들 (조문 → 판례 순서)
class ReportIssue {
  const ReportIssue({required this.label, required this.refs});
  final String label;
  final List<ReportLawRef> refs;
}

/// 증거 파일 하나
class ReportEvidenceFile {
  const ReportEvidenceFile({
    required this.label,
    required this.sha256,
    required this.sizeBytes,
    required this.receivedAt,
  });
  final String label;
  final String sha256;
  final int sizeBytes;
  final DateTime receivedAt;
}

/// 문처리에 남긴 진술
class ReportStatement {
  const ReportStatement({required this.text, this.at});
  final String text;
  final DateTime? at;
}

class ReportData {
  const ReportData({
    required this.accidentId,
    required this.analyzedAt,
    required this.rateOurPct,
    required this.rateOtherPct,
    this.reportVersion,
    this.isComplete = true,
    this.ratioCandidates = const [],
    this.typeCandidates = const [],
    this.incidentAt,
    this.address,
    this.latitude,
    this.longitude,
    this.gpsEstimated = false,
    this.roadPlaceLabel,
    this.roadUserSelected = false,
    this.roadAutoNote,
    this.otherActionLabel,
    this.weatherText,
    this.mapImage,
    this.drivingEnvironment,
    this.scenePhotos = const [],
    this.clipStartMs,
    this.clipEndMs,
    this.impactMs,
    this.clipFrames,
    this.clipFps,
    this.modelWarnings = const [],
    this.checkedFacts = const [],
    this.egoMovement,
    this.otherMovement,
    this.statements = const [],
    this.evidenceFiles = const [],
    this.lawKeywords = const [],
    this.issues = const [],
    this.lawStatusNote,
    this.unknowns = const [],
    this.aiSummary,
  });

  // 기본 정보
  final String accidentId;
  final DateTime analyzedAt;
  final int? reportVersion;
  final bool isComplete;

  // 결과
  final int rateOurPct;
  final int rateOtherPct;
  final List<ReportRatioCandidate> ratioCandidates;
  final List<ReportTypeCandidate> typeCandidates;

  // 사고 정보
  final DateTime? incidentAt;
  final String? address;
  final double? latitude;
  final double? longitude;
  final bool gpsEstimated;
  final String? roadPlaceLabel;
  final bool roadUserSelected;
  final String? roadAutoNote;
  final String? otherActionLabel;
  final String? weatherText;
  final Uint8List? mapImage;

  /// 사용자가 고른 주행 환경 (예: 비 · 젖은 노면 · 야간)
  final String? drivingEnvironment;

  /// 초동 대처에서 찍은 현장 사진 (최신순, 최대 6장)
  final List<Uint8List> scenePhotos;

  // 분석 구간 (원본 영상 기준 ms)
  final int? clipStartMs;
  final int? clipEndMs;
  final int? impactMs;
  final int? clipFrames;
  final double? clipFps;
  final List<String> modelWarnings;

  // 판단에 들어간 입력
  final List<String> checkedFacts;
  final String? egoMovement;
  final String? otherMovement;
  final List<ReportStatement> statements;

  // 증거
  final List<ReportEvidenceFile> evidenceFiles;

  // 법령·판례
  final List<String> lawKeywords;
  final List<ReportIssue> issues;
  final String? lawStatusNote;

  // 한계·설명
  final List<String> unknowns;
  final String? aiSummary;

  // ── 확률 분포에서 계산하는 값 ──────────────────────────
  ReportRatioCandidate? get topCandidate {
    if (ratioCandidates.isEmpty) return null;
    return ratioCandidates.reduce((a, b) => b.prob > a.prob ? b : a);
  }

  /// 1순위와 그 양옆 후보 (가능성이 높은 범위)
  List<ReportRatioCandidate> get likelyRange {
    final top = topCandidate;
    if (top == null) return const [];
    final index = ratioCandidates.indexOf(top);
    final result = <ReportRatioCandidate>[top];
    if (index > 0) result.insert(0, ratioCandidates[index - 1]);
    if (index < ratioCandidates.length - 1) {
      result.add(ratioCandidates[index + 1]);
    }
    return result;
  }
}

// ══════════════════════════════════════════════════════════
//  PDF 생성
// ══════════════════════════════════════════════════════════
typedef _Fonts = ({pw.Font regular, pw.Font bold});

class PdfReportService {
  // ── 색상 ────────────────────────────────────────────────
  static const _ink = PdfColor.fromInt(0xFF111111);
  static const _sub = PdfColor.fromInt(0xFF5F6368);
  static const _hint = PdfColor.fromInt(0xFF9A9A9A);
  static const _line = PdfColor.fromInt(0xFFE4E4E4);
  static const _fill = PdfColor.fromInt(0xFFF6F6F6);
  static const _brand = PdfColor.fromInt(0xFF2BB3C6);
  static const _brandDark = PdfColor.fromInt(0xFF137A88);
  static const _brandSoft = PdfColor.fromInt(0xFFE6F6F8);
  static const _brandMid = PdfColor.fromInt(0xFF8FD3DC);
  static const _barGray = PdfColor.fromInt(0xFFCFD4D8);
  static const _warn = PdfColor.fromInt(0xFFB26A00);
  static const _warnSoft = PdfColor.fromInt(0xFFFFF4E0);
  static const _red = PdfColor.fromInt(0xFFD93025);

  static Future<_Fonts> _loadFonts() async {
    final regularData =
        await rootBundle.load('assets/fonts/NotoSansKR-Regular.ttf');
    final boldData = await rootBundle.load('assets/fonts/NotoSansKR-Bold.ttf');
    return (regular: pw.Font.ttf(regularData), bold: pw.Font.ttf(boldData));
  }

  static Future<pw.Document> _buildDoc(ReportData d) async {
    final f = await _loadFonts();
    final pdf = pw.Document();
    var section = 0;
    String no() => '${++section}';

    pdf.addPage(
      pw.MultiPage(
        theme: pw.ThemeData.withFont(base: f.regular, bold: f.bold),
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 30),
        footer: (ctx) => _footer(f, ctx, d),
        build: (ctx) => [
          // ── 1장 ────────────────────────────────────────
          _header(f, d),
          pw.SizedBox(height: 14),
          _resultCard(f, d),
          pw.SizedBox(height: 8),
          _kpis(f, d),
          if (d.ratioCandidates.isNotEmpty) ...[
            _h2(f, no(), '과실비율 확률 분포', '모델이 각 비율 후보에 준 확률 · 우리 차량 기준'),
            _distribution(f, d),
            pw.SizedBox(height: 4),
            _hintText(f,
                '1순위 확률이 낮을수록 결과가 갈릴 여지가 큽니다. 보험사 판단이 가능성이 높은 범위 안에서 달라질 수 있습니다.'),
          ],
          _h2(f, no(), '사고 정보'),
          _incidentInfo(f, d),
          if (d.scenePhotos.isNotEmpty) ...[
            _h2(f, no(), '현장 사진', '초동 대처에서 촬영해 사건에 저장한 사진 · ${d.scenePhotos.length}장'),
            _scenePhotos(d),
          ],
          if (d.aiSummary != null) ...[
            _h2(f, '!', 'AI 설명', '분석 결과를 문장으로 정리한 내용'),
            _quote(f, d.aiSummary!, dark: true),
          ],

          // ── 이어서 (페이지를 강제로 나누지 않고 섹션 사이 여백만 둔다) ──
          if (d.typeCandidates.isNotEmpty) ...[
            _h2(f, no(), '모델이 판단한 사고 유형'),
            _typeTable(f, d),
          ],
          if (d.clipStartMs != null && d.clipEndMs != null) ...[
            _h2(f, no(), '분석한 영상 구간'),
            _timeline(f, d),
          ],
          _h2(f, no(), '판단에 들어간 입력'),
          ..._inputs(f, d),

          // ── 법령·판례 ──────────────────────────────────
          ..._lawSection(f, d, no()),

          // ── 다음에 할 일 ────────────────────────────────
          _h2(f, no(), '다음에 할 일'),
          _bullet(f, '보험사에 사고를 접수하고, 이 리포트와 원본 블랙박스 영상을 함께 전달하세요.'),
          _bullet(f, '원본 영상은 편집하지 말고 그대로 보관하세요.'),
          _bullet(f,
              '보험사가 정한 비율에 동의하기 어려우면 과실비율분쟁심의위원회에 심의를 청구할 수 있습니다.'),
          pw.SizedBox(height: 16),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: _warnSoft,
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Text(
              '이 리포트는 AI 모델의 예측과 검색된 법령·판례를 정리한 참고 자료이며 법적 효력이 없습니다. '
              '최종 과실비율은 보험사 또는 분쟁 기관의 판단에 따릅니다.\n$legalReferenceWarning',
              style: pw.TextStyle(
                  font: f.regular,
                  fontSize: 8.5,
                  color: const PdfColor.fromInt(0xFF6B4A00),
                  lineSpacing: 2),
            ),
          ),
        ],
      ),
    );
    return pdf;
  }

  // ── 공유 (시스템 공유 시트) ──────────────────────────────
  static Future<void> generateAndShare(ReportData d) async {
    final pdf = await _buildDoc(d);
    final dt = d.analyzedAt.toLocal();
    await Printing.sharePdf(
      bytes: await pdf.save(),
      filename:
          'Dae-Byeon-BOX_정밀분석리포트_${dt.year}${_two(dt.month)}${_two(dt.day)}.pdf',
    );
  }

  // ── 로컬 저장 (과실 분석 기록용) ──────────────────────────
  static Future<String> saveToLocal(
    ReportData d, {
    required String ownerScope,
    Directory? directory,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('로컬 PDF 저장은 웹에서 지원되지 않습니다.');
    }
    final pdf = await _buildDoc(d);
    final dynamic dir = directory ?? await getApplicationDocumentsDirectory();
    final name = LocalAppFiles.scopedPdfName(
      ownerScope: ownerScope,
      caseId: d.accidentId,
      suffix: 'report_${d.analyzedAt.millisecondsSinceEpoch}',
    );
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(await pdf.save());
    return file.path;
  }

  // ════════════════════════════════════════════════════════
  //  공통 조각
  // ════════════════════════════════════════════════════════
  static pw.TextStyle _t(_Fonts f,
          {double size = 10,
          PdfColor color = _ink,
          bool bold = false,
          double spacing = 0}) =>
      pw.TextStyle(
          font: bold ? f.bold : f.regular,
          fontSize: size,
          color: color,
          lineSpacing: spacing);

  static pw.Widget _h2(_Fonts f, String number, String title,
      [String? desc, bool first = false]) {
    return pw.Padding(
      padding: pw.EdgeInsets.only(top: first ? 0 : 20, bottom: 8),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Container(
            width: 15,
            height: 15,
            alignment: pw.Alignment.center,
            decoration: pw.BoxDecoration(
                color: _ink, borderRadius: pw.BorderRadius.circular(3)),
            child: pw.Text(number,
                style: _t(f, size: 8, color: PdfColors.white, bold: true)),
          ),
          pw.SizedBox(width: 7),
          pw.Text(title, style: _t(f, size: 12, bold: true)),
          if (desc != null) ...[
            pw.SizedBox(width: 7),
            pw.Flexible(child: pw.Text(desc, style: _t(f, size: 8, color: _hint))),
          ],
        ],
      ),
    );
  }

  static pw.Widget _hintText(_Fonts f, String text) =>
      pw.Text(text, style: _t(f, size: 8, color: _hint, spacing: 1.5));

  static pw.Widget _badge(_Fonts f, String text,
      {PdfColor bg = _brandSoft, PdfColor fg = _brandDark}) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration:
          pw.BoxDecoration(color: bg, borderRadius: pw.BorderRadius.circular(8)),
      child: pw.Text(text, style: _t(f, size: 7.5, color: fg, bold: true)),
    );
  }

  static pw.Widget _chip(_Fonts f, String text) => pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: _line),
          borderRadius: pw.BorderRadius.circular(8),
        ),
        child: pw.Text(text, style: _t(f, size: 8)),
      );

  static pw.Widget _quote(_Fonts f, String text, {bool dark = false}) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.fromLTRB(10, 7, 10, 7),
      decoration: pw.BoxDecoration(
        color: _fill,
        border: pw.Border(
            left: pw.BorderSide(color: dark ? _ink : _brand, width: 2.5)),
      ),
      child: pw.Text(text, style: _t(f, size: 9, spacing: 2.5)),
    );
  }

  static pw.Widget _bullet(_Fonts f, String text, {bool warn = false}) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 5),
      decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _line, width: 0.6))),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(
            margin: const pw.EdgeInsets.only(top: 4, right: 7, left: 2),
            width: 4,
            height: 4,
            decoration: pw.BoxDecoration(
                color: warn ? _warn : _hint, shape: pw.BoxShape.circle),
          ),
          pw.Expanded(child: pw.Text(text, style: _t(f, size: 9, spacing: 1.5))),
        ],
      ),
    );
  }

  static pw.Widget _row(_Fonts f, String key, pw.Widget value) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _line, width: 0.6))),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
              width: 82, child: pw.Text(key, style: _t(f, size: 8.5, color: _sub))),
          pw.Expanded(child: value),
        ],
      ),
    );
  }

  static pw.Widget _value(_Fonts f, String main, [String? note]) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(main, style: _t(f, size: 9)),
        if (note != null && note.isNotEmpty)
          pw.Text(note, style: _t(f, size: 7.5, color: _hint)),
      ],
    );
  }

  // ════════════════════════════════════════════════════════
  //  1장
  // ════════════════════════════════════════════════════════
  static pw.Widget _header(_Fonts f, ReportData d) {
    final version = d.reportVersion == null ? '' : ' (리포트 v${d.reportVersion})';
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 10),
      decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _ink, width: 1.5))),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.RichText(
                text: pw.TextSpan(
                  style: pw.TextStyle(font: f.bold, fontSize: 14),
                  children: const [
                    pw.TextSpan(text: 'D', style: pw.TextStyle(color: _brand)),
                    pw.TextSpan(text: 'ae-', style: pw.TextStyle(color: _ink)),
                    pw.TextSpan(text: 'B', style: pw.TextStyle(color: _brand)),
                    pw.TextSpan(text: 'yeon-', style: pw.TextStyle(color: _ink)),
                    pw.TextSpan(text: 'BOX', style: pw.TextStyle(color: _brand)),
                  ],
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text('정밀 사고 분석 리포트', style: _t(f, size: 18, bold: true)),
            ],
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text('사고 번호 ${_shortId(d.accidentId)}',
                  style: _t(f, size: 8, color: _sub)),
              pw.Text('분석 일시 ${_dateTime(d.analyzedAt)}$version',
                  style: _t(f, size: 8, color: _sub)),
              pw.SizedBox(height: 3),
              d.isComplete
                  ? _badge(f, '분석 완료')
                  : _badge(f, '일부 결과', bg: _warnSoft, fg: _warn),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _resultCard(_Fonts f, ReportData d) {
    pw.Widget side(String label, int pct, bool strong) => pw.Expanded(
          child: pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(label, style: _t(f, size: 9, color: _sub)),
                pw.RichText(
                  text: pw.TextSpan(children: [
                    pw.TextSpan(
                        text: '$pct',
                        style: pw.TextStyle(
                            font: f.bold,
                            fontSize: 36,
                            color: strong ? _ink : _hint)),
                    pw.TextSpan(
                        text: '%',
                        style: pw.TextStyle(
                            font: f.regular, fontSize: 15, color: _hint)),
                  ]),
                ),
              ],
            ),
          ),
        );
    final our = d.rateOurPct;
    final other = d.rateOtherPct;
    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _line),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Column(
        children: [
          pw.Row(children: [
            side('우리 차량 과실', our, our >= other),
            pw.Container(width: 0.6, height: 58, color: _line),
            side('상대 차량 과실', other, other > our),
          ]),
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: pw.Row(children: [
              pw.Expanded(
                  flex: our == 0 ? 1 : our,
                  child: pw.Container(
                      height: 6,
                      decoration: pw.BoxDecoration(
                          color: _ink,
                          borderRadius: pw.BorderRadius.circular(2)))),
              pw.SizedBox(width: 2),
              pw.Expanded(
                  flex: other == 0 ? 1 : other,
                  child: pw.Container(
                      height: 6,
                      decoration: pw.BoxDecoration(
                          color: const PdfColor.fromInt(0xFFD0D0D0),
                          borderRadius: pw.BorderRadius.circular(2)))),
            ]),
          ),
        ],
      ),
    );
  }

  static pw.Widget _kpis(_Fonts f, ReportData d) {
    pw.Widget kpi(String k, String v, String s) => pw.Expanded(
          child: pw.Container(
            margin: const pw.EdgeInsets.symmetric(horizontal: 3),
            padding: const pw.EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: pw.BoxDecoration(
                color: _fill, borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(k, style: _t(f, size: 7.5, color: _sub)),
                pw.SizedBox(height: 2),
                pw.Text(v, style: _t(f, size: 13, bold: true)),
                pw.SizedBox(height: 1),
                pw.Text(s, style: _t(f, size: 7, color: _hint)),
              ],
            ),
          ),
        );
    final top = d.topCandidate;
    final range = d.likelyRange;
    final rangeProb = range.fold<double>(0, (sum, c) => sum + c.prob);
    final road = d.roadPlaceLabel ?? '확인 불가';
    final roadNote = [
      d.roadUserSelected ? '사용자 선택' : '자동 추정',
      if (d.otherActionLabel != null) '상대 ${d.otherActionLabel}',
    ].join(' · ');
    return pw.Row(children: [
      kpi(
        '결과 확실도 (1순위 확률)',
        top == null ? '-' : _pct(top.prob),
        top == null ? '확률 정보 없음' : '${d.ratioCandidates.length}개 비율 후보 중 ${top.ourPct}%가 가장 높음',
      ),
      kpi(
        '가능성이 높은 범위',
        range.isEmpty ? '-' : '${range.first.ourPct} ~ ${range.last.ourPct}%',
        range.isEmpty ? '확률 정보 없음' : '${range.length}개 후보 합계 확률 ${_pct(rangeProb)}',
      ),
      kpi('판단에 쓴 도로유형', road, roadNote),
    ]);
  }

  static pw.Widget _distribution(_Fonts f, ReportData d) {
    final top = d.topCandidate;
    final range = d.likelyRange.toSet();
    final maxProb = d.ratioCandidates
        .fold<double>(0, (m, c) => c.prob > m ? c.prob : m);
    const chartHeight = 92.0;
    return pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _line),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Column(
        children: [
          pw.Container(
            height: chartHeight + 14,
            decoration: const pw.BoxDecoration(
                border: pw.Border(bottom: pw.BorderSide(color: _line))),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: d.ratioCandidates.map((c) {
                final isTop = identical(c, top);
                final color = isTop
                    ? _brand
                    : range.contains(c)
                        ? _brandMid
                        : _barGray;
                final h = maxProb <= 0
                    ? 1.0
                    : (c.prob / maxProb * chartHeight).clamp(1.0, chartHeight);
                return pw.Expanded(
                  child: pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 2.5),
                    child: pw.Column(
                      mainAxisAlignment: pw.MainAxisAlignment.end,
                      children: [
                        pw.Text(_pct(c.prob),
                            style: _t(f,
                                size: 7,
                                color: isTop ? _ink : _sub,
                                bold: isTop)),
                        pw.SizedBox(height: 2),
                        pw.Container(
                          height: h.toDouble(),
                          decoration: pw.BoxDecoration(
                            color: color,
                            borderRadius: const pw.BorderRadius.only(
                                topLeft: pw.Radius.circular(3),
                                topRight: pw.Radius.circular(3)),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          pw.SizedBox(height: 3),
          pw.Row(
            children: d.ratioCandidates
                .map((c) => pw.Expanded(
                    child: pw.Text('${c.ourPct}',
                        textAlign: pw.TextAlign.center,
                        style: _t(f, size: 7, color: _hint))))
                .toList(),
          ),
          pw.SizedBox(height: 6),
          pw.Row(children: [
            _legend(f, _brand, '최종 결과'),
            _legend(f, _brandMid, '가능성 높은 범위'),
            _legend(f, _barGray, '기타 후보'),
            pw.Spacer(),
            pw.Text('x축: 우리 차량 과실(%)', style: _t(f, size: 7, color: _sub)),
          ]),
        ],
      ),
    );
  }

  static pw.Widget _legend(_Fonts f, PdfColor color, String label) => pw.Padding(
        padding: const pw.EdgeInsets.only(right: 10),
        child: pw.Row(children: [
          pw.Container(
              width: 7,
              height: 7,
              decoration: pw.BoxDecoration(
                  color: color, borderRadius: pw.BorderRadius.circular(1.5))),
          pw.SizedBox(width: 3),
          pw.Text(label, style: _t(f, size: 7, color: _sub)),
        ]),
      );

  static pw.Widget _incidentInfo(_Fonts f, ReportData d) {
    final gps = (d.latitude != null && d.longitude != null)
        ? 'GPS ${d.latitude!.toStringAsFixed(5)}, ${d.longitude!.toStringAsFixed(5)} · ${d.gpsEstimated ? '추정값' : '실측'}'
        : null;
    final table = pw.Column(children: [
      _row(f, '사고 발생 시각',
          _value(f, d.incidentAt == null ? '확인 불가' : _dateTime(d.incidentAt!, seconds: true))),
      _row(f, '사고 위치', _value(f, d.address ?? '확인 불가', gps)),
      _row(
          f,
          '도로 형태',
          _value(
              f,
              '${d.roadPlaceLabel ?? '확인 불가'}  (${d.roadUserSelected ? '사용자 선택' : '자동 추정'})',
              d.roadAutoNote)),
      if (d.otherActionLabel != null)
        _row(f, '상대 차량 움직임', _value(f, d.otherActionLabel!, '사용자 답변')),
    ]);
    final map = d.mapImage;
    if (map == null) return table;
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(child: table),
        pw.SizedBox(width: 12),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // 서버 지도 위쪽 제목·아래쪽 설명이 잘리지 않게 원본 비율 그대로 넣는다
              pw.ClipRRect(
                horizontalRadius: 6,
                verticalRadius: 6,
                child: _mapImage(map),
              ),
              pw.SizedBox(height: 4),
              _hintText(f, '서버가 만든 사고 위치 지도입니다. 표시된 지점이 블랙박스 GPS 기준 사고 위치입니다.'),
            ],
          ),
        ),
      ],
    );
  }

  // ════════════════════════════════════════════════════════
  //  2장
  // ════════════════════════════════════════════════════════
  /// 1순위 사고 유형의 설명만 보여준다 (순위·번호·확률 없이)
  static pw.Widget _typeTable(_Fonts f, ReportData d) {
    final c = d.typeCandidates.first;
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _line),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(c.description ?? '사고 유형 정보를 찾지 못했습니다',
              style: _t(f, size: 10.5, bold: true)),
          if (c.detail != null) ...[
            pw.SizedBox(height: 3),
            pw.Text(c.detail!, style: _t(f, size: 8.5, color: _sub)),
          ],
          if (c.baseOurPct != null && c.baseOtherPct != null) ...[
            pw.SizedBox(height: 2),
            pw.Text(
                '인정기준 기본 과실  우리 ${c.baseOurPct}% : 상대 ${c.baseOtherPct}%',
                style: _t(f, size: 8, color: _hint)),
          ],
        ],
      ),
    );
  }

  static pw.Widget _timeline(_Fonts f, ReportData d) {
    final start = d.clipStartMs!;
    final end = d.clipEndMs!;
    final impact = d.impactMs;
    // 축: 분석 구간 앞뒤로 여유를 두고 0초부터 표시
    final axisEnd = ((end / 1000).ceil() + 2) * 1000;
    final pre = start;
    final win = end - start;
    final post = axisEnd - end;
    final frames = d.clipFrames == null ? '' : ' · ${d.clipFrames}프레임';
    final fps = d.clipFps == null ? '' : ' · ${_num(d.clipFps!)}fps';
    return pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _line),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
              '원본 영상 중 ${_sec(start)} ~ ${_sec(end)} (${_sec(win)}$frames$fps)를 분석했습니다.',
              style: _t(f, size: 9, color: _sub)),
          pw.SizedBox(height: 14),
          if (impact != null)
            pw.Row(children: [
              pw.Expanded(flex: impact.clamp(1, axisEnd).toInt(), child: pw.SizedBox()),
              pw.Text('충돌 추정 ${_sec(impact)}',
                  style: _t(f, size: 7.5, color: _red, bold: true)),
              pw.Expanded(
                  flex: (axisEnd - impact).clamp(1, axisEnd).toInt(),
                  child: pw.SizedBox()),
            ]),
          pw.SizedBox(height: 2),
          pw.Stack(children: [
            pw.Container(
              height: 18,
              decoration: pw.BoxDecoration(
                  color: _fill, borderRadius: pw.BorderRadius.circular(4)),
              child: pw.Row(children: [
                pw.Expanded(flex: pre.clamp(1, axisEnd).toInt(), child: pw.SizedBox()),
                pw.Expanded(
                  flex: win.clamp(1, axisEnd).toInt(),
                  child: pw.Container(
                    decoration: pw.BoxDecoration(
                      color: _brandSoft,
                      border: pw.Border.all(color: _brand, width: 1),
                      borderRadius: pw.BorderRadius.circular(4),
                    ),
                  ),
                ),
                pw.Expanded(flex: post.clamp(1, axisEnd).toInt(), child: pw.SizedBox()),
              ]),
            ),
            if (impact != null)
              pw.Row(children: [
                pw.Expanded(flex: impact.clamp(1, axisEnd).toInt(), child: pw.SizedBox()),
                pw.Container(width: 1.5, height: 18, color: _red),
                pw.Expanded(
                    flex: (axisEnd - impact).clamp(1, axisEnd).toInt(),
                    child: pw.SizedBox()),
              ]),
          ]),
          pw.SizedBox(height: 3),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              for (var s = 0; s <= axisEnd ~/ 1000; s += (axisEnd ~/ 1000 > 12 ? 5 : 2))
                pw.Text('$s초', style: _t(f, size: 7, color: _hint)),
            ],
          ),
          pw.SizedBox(height: 6),
          pw.Text(
              d.modelWarnings.isEmpty
                  ? '모델 경고: 없음'
                  : '모델 경고: ${d.modelWarnings.join(', ')}',
              style: _t(f, size: 7.5, color: _hint)),
        ],
      ),
    );
  }

  /// 현장 사진: 한 줄에 3장, 잘리지 않게 칸 안에 맞춘다
  static pw.Widget _scenePhotos(ReportData d) {
    final tiles = <pw.Widget>[];
    for (final bytes in d.scenePhotos) {
      pw.ImageProvider image;
      try {
        image = pw.MemoryImage(bytes);
      } catch (_) {
        continue; // 읽을 수 없는 형식은 건너뛴다
      }
      tiles.add(pw.Container(
        width: 165,
        height: 124,
        decoration: pw.BoxDecoration(
          color: _fill,
          borderRadius: pw.BorderRadius.circular(6),
        ),
        child: pw.ClipRRect(
          horizontalRadius: 6,
          verticalRadius: 6,
          child: pw.Image(image, fit: pw.BoxFit.contain),
        ),
      ));
    }
    return pw.Wrap(spacing: 8, runSpacing: 8, children: tiles);
  }

  static pw.Widget _mapImage(Uint8List bytes) {
    final image = pw.MemoryImage(bytes);
    final w = image.width;
    final h = image.height;
    if (w != null && h != null && w > 0 && h > 0) {
      return pw.AspectRatio(
        aspectRatio: w / h,
        child: pw.Image(image, fit: pw.BoxFit.contain),
      );
    }
    return pw.SizedBox(
      width: double.infinity,
      height: 170,
      child: pw.Image(image, fit: pw.BoxFit.contain),
    );
  }

  static List<pw.Widget> _inputs(_Fonts f, ReportData d) {
    return [
      _row(
          f,
          '도로 형태',
          _value(f,
              '${d.roadPlaceLabel ?? '확인 불가'} (${d.roadUserSelected ? '사용자가 직접 선택' : 'GPS 기반 자동 추정'})')),
      if (d.otherActionLabel != null)
        _row(f, '상대 차량 움직임', _value(f, d.otherActionLabel!)),
      if ((d.drivingEnvironment ?? '').isNotEmpty)
        _row(f, '주행 환경', _value(f, d.drivingEnvironment!)),
      _row(
        f,
        '추가로 체크한 정황',
        d.checkedFacts.isEmpty
            ? _value(f, '없음')
            : pw.Wrap(
                spacing: 4,
                runSpacing: 4,
                children: d.checkedFacts.map((x) => _chip(f, x)).toList()),
      ),
      if ((d.egoMovement ?? '').isNotEmpty || (d.otherMovement ?? '').isNotEmpty)
        _row(
            f,
            '차량 움직임 설명',
            _value(f, [
              if ((d.egoMovement ?? '').isNotEmpty) '내 차량: ${d.egoMovement}',
              if ((d.otherMovement ?? '').isNotEmpty) '상대 차량: ${d.otherMovement}',
            ].join('\n'))),
      pw.SizedBox(height: 4),
      _hintText(f,
          '현재 모델은 도로 형태와 상대 차량 움직임 답변을 비율 계산에 사용합니다. 자유 설명은 설명·법령 검색에만 쓰이며 비율을 바꾸지 않습니다.'),
    ];
  }

  // ════════════════════════════════════════════════════════
  //  3장 · 법령·판례 (쟁점별, 원문 전체)
  // ════════════════════════════════════════════════════════
  static List<pw.Widget> _lawSection(_Fonts f, ReportData d, String number) {
    final total = d.issues.fold<int>(0, (n, i) => n + i.refs.length);
    final out = <pw.Widget>[
      _h2(f, number, '법령 · 판례 근거',
          total == 0 ? null : '검색된 근거 원문 전체 · $total건'),
    ];
    if (d.lawKeywords.isNotEmpty) {
      out.add(pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: pw.WrapCrossAlignment.center,
          children: [
            pw.Text('검색어  ', style: _t(f, size: 8, color: _sub)),
            ...d.lawKeywords.map((k) => _chip(f, k)),
          ],
        ),
      ));
    }
    if (total == 0) {
      out.add(pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(
            color: _fill, borderRadius: pw.BorderRadius.circular(6)),
        child: pw.Text(d.lawStatusNote ?? '이 분석에서 검색된 법령·판례 근거가 없습니다.',
            style: _t(f, size: 9, color: _sub)),
      ));
      return out;
    }
    for (var i = 0; i < d.issues.length; i++) {
      final issue = d.issues[i];
      out.add(pw.Padding(
        padding: pw.EdgeInsets.only(top: i == 0 ? 0 : 6, bottom: 4),
        child: pw.Text('쟁점 ${i + 1}. ${issue.label}',
            style: _t(f, size: 9, color: _sub, bold: true)),
      ));
      for (final ref in issue.refs) {
        out.addAll(_lawCard(f, ref));
      }
    }
    if (d.lawStatusNote != null) {
      out.add(pw.Padding(
          padding: const pw.EdgeInsets.only(top: 2),
          child: _hintText(f, d.lawStatusNote!)));
    }
    return out;
  }

  /// 근거 카드. 원문은 문단 단위 위젯으로 나눠 페이지를 넘어가도 잘리지 않는다.
  static List<pw.Widget> _lawCard(_Fonts f, ReportLawRef ref) {
    const side = pw.BorderSide(color: _line, width: 0.8);
    final source = ref.fromVideo
        ? _badge(f, '영상에서 확인')
        : _badge(f, '사용자 입력 기반', bg: _warnSoft, fg: _warn);
    final why = ref.fromVideo
        ? '이 사고와의 관련성: 사고 영상에서 확인된 상황으로 검색된 근거입니다.'
        : '이 사고와의 관련성: 영상에서 직접 확인된 내용이 아니라, 사용자가 입력한 정황으로 검색된 근거입니다.';
    final paragraphs = _paragraphs(ref.text);
    final widgets = <pw.Widget>[
      pw.Container(
        padding: const pw.EdgeInsets.fromLTRB(12, 9, 12, 4),
        decoration: const pw.BoxDecoration(
          border: pw.Border(top: side, left: side, right: side),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                    child: pw.Text(ref.title, style: _t(f, size: 10, bold: true))),
                pw.SizedBox(width: 6),
                _badge(f, ref.isPrecedent ? '판례' : '조문',
                    bg: _fill, fg: _sub),
                pw.SizedBox(width: 4),
                source,
              ],
            ),
            pw.SizedBox(height: 5),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: pw.BoxDecoration(
                color: ref.fromVideo ? _brandSoft : _warnSoft,
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Text(why,
                  style: _t(f,
                      size: 7.5, color: ref.fromVideo ? _brandDark : _warn)),
            ),
          ],
        ),
      ),
    ];
    for (final p in paragraphs) {
      widgets.add(pw.Container(
        padding: const pw.EdgeInsets.fromLTRB(12, 2, 12, 2),
        decoration: const pw.BoxDecoration(
            border: pw.Border(left: side, right: side)),
        child: pw.Text(p, style: _t(f, size: 8.8, spacing: 2.2)),
      ));
    }
    widgets.add(pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 8),
      padding: const pw.EdgeInsets.fromLTRB(12, 3, 12, 8),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: side, left: side, right: side),
      ),
      child: pw.Text(
          ref.url == null
              ? '원문 · 국가법령정보센터'
              : '원문 · ${ref.url}',
          style: _t(f, size: 7, color: _brandDark)),
    ));
    return widgets;
  }

  /// 원문을 줄 단위로 나누고, 너무 긴 줄은 문장 경계에서 다시 나눈다.
  static List<String> _paragraphs(String text) {
    const maxChars = 450;
    final result = <String>[];
    for (final raw in text.split(RegExp(r'\n+'))) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      while (line.length > maxChars) {
        var cut = line.lastIndexOf(RegExp(r'[.다]\s'), maxChars);
        if (cut < maxChars ~/ 2) cut = maxChars;
        result.add(line.substring(0, cut + 1).trim());
        line = line.substring(cut + 1).trim();
      }
      if (line.isNotEmpty) result.add(line);
    }
    return result.isEmpty ? ['-'] : result;
  }

  // ════════════════════════════════════════════════════════
  //  꼬리말
  // ════════════════════════════════════════════════════════
  static pw.Widget _footer(_Fonts f, pw.Context ctx, ReportData d) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 10),
      padding: const pw.EdgeInsets.only(top: 6),
      decoration: const pw.BoxDecoration(
          border: pw.Border(top: pw.BorderSide(color: _line, width: 0.6))),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
              'Dae-Byeon-BOX · 정밀 사고 분석 리포트 · 생성 ${_dateTime(DateTime.now())}',
              style: _t(f, size: 7, color: _hint)),
          pw.Text('${ctx.pageNumber} / ${ctx.pagesCount}',
              style: _t(f, size: 7, color: _hint)),
        ],
      ),
    );
  }

  // ── 포맷 유틸 ────────────────────────────────────────────
  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _dateTime(DateTime t, {bool seconds = false}) {
    final l = t.toLocal();
    final base =
        '${l.year}.${_two(l.month)}.${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}';
    return seconds ? '$base:${_two(l.second)}' : base;
  }

  static String _pct(double p) => '${(p * 100).round()}%';
  static String _num(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
  static String _sec(int ms) => '${(ms / 1000).toStringAsFixed(1)}초';

  static String _shortId(String id) =>
      id.length <= 20 ? id : '${id.substring(0, 13)}…${id.substring(id.length - 6)}';
}
