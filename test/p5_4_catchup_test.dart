// Test P5.4 phần B/C — phân tích bù (catch-up) cho phiên đã kết thúc mà chưa có báo cáo.
//
// Khoá theo DoD của `.plan/prompt_P5_4.md` (mục B):
// - Phiên kết thúc mà Post-Review lỗi ⇒ phiên VẪN trong Lịch sử và được liệt kê để phân tích bù.
// - catchUp() thành công ⇒ có báo cáo, `sessionIdsWithReport()` chứa phiên, icon Lịch sử đổi.
// - Throttle: lần 2 KHÔNG thử lại phiên vừa thử trong 6 giờ (đếm số lần gọi LLM thật).
// - Lỗi hạ tầng (mạng/thiếu key) ⇒ dừng cả lượt; lỗi nội dung phiên ⇒ bỏ qua phiên đó, đi tiếp.
// - `init()` của app tự chạy catch-up khi có API key, không crash nếu service lỗi.
// - Nút "Phân tích lại các buổi còn thiếu" trong Lịch sử hoạt động, SnackBar rõ ràng.
//
// Toàn bộ chạy trên DAO giả trong bộ nhớ (không SQLite) + LLM giả (không gọi mạng).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/audio/capture/capture_config.dart';
import 'package:ai_assistant_phone/audio/capture/capture_engine.dart';
import 'package:ai_assistant_phone/coaching/pending_analysis_service.dart';
import 'package:ai_assistant_phone/coaching/post_review_service.dart';
import 'package:ai_assistant_phone/coaching/pre_brief.dart';
import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';
import 'package:ai_assistant_phone/services/storage/transcript_dao.dart';
import 'package:ai_assistant_phone/suggestion/llm_provider.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_models.dart';
import 'package:ai_assistant_phone/transcript/transcript_segment.dart';
import 'package:ai_assistant_phone/ui/history_screen.dart';
import 'package:ai_assistant_phone/ui/session_coordinator.dart';

/// Đồng hồ **CỐ ĐỊNH** dùng CHUNG cho cả DAO giả lẫn service (`now:`).
///
/// Trước đây `_FakeDao.finishedSessionsWithoutReport` tính cutoff throttle bằng `DateTime.now()` THẬT,
/// còn service được bơm `now: () => DateTime(2026, 9, 23, 21, 0)` — hai đồng hồ lệch nhau nên test
/// "throttle 6 giờ" chỉ pass khi giờ thật còn sớm hơn mốc cố định + 6h (tức trước 03:00), và đỏ sau
/// đó. Dùng chung một mốc ⇒ test tất định, không phụ thuộc giờ chạy.
final DateTime _fixedNow = DateTime(2026, 9, 23, 21, 0);

class _FakeConfigStore implements ConfigStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// DAO giả trong bộ nhớ — cùng mẫu các `_FakeDao` của P5.1/P5.2, thêm 3 member của P5.4.
class _FakeDao implements TranscriptDao {
  final List<TranscriptSession> sessions = <TranscriptSession>[];
  final Map<int, List<TranscriptSegment>> segments = <int, List<TranscriptSegment>>{};
  final Map<int, PostReviewReportRow> reports = <int, PostReviewReportRow>{};

  /// Cột `last_analysis_attempt_ms` — mốc lần THỬ phân tích bù gần nhất của từng phiên.
  final Map<int, DateTime> analysisAttempts = <int, DateTime>{};

  int addSession(DateTime startedAt, {DateTime? endedAt, String? title}) {
    final TranscriptSession session = TranscriptSession(
      id: sessions.length + 1,
      startedAt: startedAt,
      lastActivityAt: startedAt,
      title: title,
      endedAt: endedAt,
    );
    sessions.add(session);
    return session.id;
  }

  void addSegment(int sessionId, String text, {DateTime? at}) {
    segments
        .putIfAbsent(sessionId, () => <TranscriptSegment>[])
        .add(TranscriptSegment(text: text, timestamp: at ?? DateTime(2026, 9, 23, 20, 0)));
  }

  @override
  Future<List<TranscriptSession>> finishedSessionsWithoutReport({required int limit}) async {
    final DateTime cutoff = _fixedNow.subtract(CoachingConfig.analysisRetryInterval);
    final List<TranscriptSession> pending = sessions
        .where((TranscriptSession s) =>
            s.isFinished &&
            !reports.containsKey(s.id) &&
            (analysisAttempts[s.id] == null || analysisAttempts[s.id]!.isBefore(cutoff)))
        .toList()
      ..sort((TranscriptSession a, TranscriptSession b) => a.startedAt.compareTo(b.startedAt));
    return pending.take(limit).toList();
  }

  @override
  Future<void> markAnalysisAttempted(int sessionId, DateTime at) async {
    analysisAttempts[sessionId] = at;
  }

  @override
  Future<SessionText> fullSessionText(
    int sessionId, {
    int maxChars = CoachingConfig.transcriptCharLimit,
  }) async =>
      joinSessionText(
        (segments[sessionId] ?? <TranscriptSegment>[])
            .map((TranscriptSegment s) => s.text)
            .toList(),
        maxChars: maxChars,
      );

  @override
  Future<List<TranscriptSession>> allSessions({int limit = 100}) async =>
      List<TranscriptSession>.of(sessions);

  @override
  Future<Set<int>> sessionIdsWithReport() async => reports.keys.toSet();

  @override
  Future<PostReviewReportRow?> reportForSession(int sessionId) async => reports[sessionId];

  @override
  Future<void> saveReport(int sessionId, PostReviewReportRow report) async {
    reports[sessionId] = report;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeDao không hỗ trợ ${invocation.memberName}');
}

class _FakeTextLlm implements TextLlmProvider {
  String result = '{"good":"g","missed":"m","exercise":"e"}';

  /// Lỗi ném ra mỗi lần gọi (`SuggestionException` = lỗi hạ tầng; lỗi khác = coi như lỗi khác).
  Object? throwError;
  int calls = 0;
  final List<String> prompts = <String>[];

  @override
  Future<String> complete({required String prompt, int maxTokens = 200}) async {
    calls++;
    prompts.add(prompt);
    final Object? error = throwError;
    if (error != null) {
      throw error;
    }
    return result;
  }
}

/// Sink ghi thẳng vào DAO giả — mô phỏng `SqliteReportSink` (báo cáo phân tích lại phải vào đúng phiên).
class _DaoSink implements ReportSink {
  _DaoSink(this.dao);

  final _FakeDao dao;

  @override
  Future<void> save(PostReviewReportRow report) => dao.saveReport(report.sessionId, report);
}

/// Post-Review chạy trên DAO giả (đường `runForSession`).
PostReviewService _buildPostReview(_FakeDao dao, _FakeTextLlm llm) => PostReviewService(
      provider: llm,
      transcriptDao: dao,
      preBriefs: PreBriefStore(store: _FakeConfigStore()),
      reportSink: _DaoSink(dao),
      now: () => _fixedNow,
    );

PendingAnalysisService _buildCatchUp(
  _FakeDao dao,
  _FakeTextLlm llm, {
  bool hasKey = true,
}) =>
    PendingAnalysisService(
      dao: dao,
      postReview: _buildPostReview(dao, llm),
      now: () => _fixedNow,
      hasApiKey: () async => hasKey,
    );

/// Service giả cho tầng UI/coordinator — đếm số lượt gọi, không chạm LLM/DB.
class _FakePending extends PendingAnalysisService {
  _FakePending(this._outcome, {this.throwError, this.onCall});

  final PendingAnalysisOutcome _outcome;
  final Object? throwError;
  final void Function()? onCall;
  int calls = 0;
  Completer<void>? gate;

  @override
  Future<PendingAnalysisOutcome> catchUp({int limit = CoachingConfig.analysisCatchUpLimit}) async {
    calls++;
    onCall?.call();
    final Completer<void>? g = gate;
    if (g != null) {
      await g.future;
    }
    final Object? error = throwError;
    if (error != null) {
      throw error;
    }
    return _outcome;
  }
}

class _FakeCapture implements AudioCaptureEngine {
  @override
  Future<CaptureConfig> start() async => const CaptureConfig();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  int get capturedBytes => 0;

  @override
  void onError(void Function(CaptureError error) handler) {}

  @override
  Stream<Uint8List> get chunks => const Stream<Uint8List>.empty();

  @override
  Stream<CaptureStatus> get status => const Stream<CaptureStatus>.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Mọi MethodChannel plugin trả null — cùng danh sách `p5_3_navigation_test.dart`, để `init()`
    // của coordinator chạy được trong môi trường test (không native, không SQLite, không keystore).
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const List<String> channels = <String>[
      'flutter_foreground_task/methods',
      'com.tekartik.sqflite',
      'plugins.it_nomads.com/flutter_secure_storage',
      'flutter.baseflow.com/permissions/methods',
      'com.aiassistant.phone/audio_capture',
      'com.aiassistant.phone/audio_capture_pcm',
      'com.aiassistant.phone/vad',
      'com.aiassistant.phone/asr',
      'com.aiassistant.phone/vosk',
      'com.aiassistant.phone/tts',
    ];
    for (final String name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (MethodCall call) async => null);
    }
  });

  late _FakeDao dao;
  late _FakeTextLlm llm;

  final DateTime base = DateTime(2026, 9, 23, 20, 0);

  setUp(() {
    dao = _FakeDao();
    llm = _FakeTextLlm();
  });

  group('DoD 3 — phiên kết thúc mà Post-Review lỗi vẫn được liệt kê để phân tích bù', () {
    test('LLM lỗi mạng lúc "Kết thúc buổi" ⇒ phiên còn trong Lịch sử + nằm trong danh sách chờ',
        () async {
      final int sessionId = dao.addSession(base, endedAt: base);
      dao.addSegment(sessionId, 'dạ em chào anh');

      llm.throwError = const SuggestionException('lỗi mạng khi gọi LLM');

      // Đường "Kết thúc buổi": transcript của phiên đang mở → Post-Review.
      final PostReviewService service = PostReviewService(
        provider: llm,
        transcriptDao: dao,
        preBriefs: PreBriefStore(store: _FakeConfigStore()),
        reportSink: _DaoSink(dao),
      );
      final PostReviewReport report = await service.runForSession(sessionId);

      expect(report.isUsable, isFalse);
      expect(report.infrastructureFailure, isTrue);
      expect(dao.reports, isEmpty, reason: 'không lưu báo cáo rỗng vào Lịch sử');

      // Phiên VẪN nằm trong Lịch sử (dữ liệu không phụ thuộc LLM)…
      expect((await dao.allSessions()).map((TranscriptSession s) => s.id), contains(sessionId));
      // …và được đánh dấu là cần phân tích bù.
      final List<TranscriptSession> pending = await dao.finishedSessionsWithoutReport(limit: 5);
      expect(pending.map((TranscriptSession s) => s.id), <int>[sessionId]);
    });

    test('phiên CHƯA kết thúc hoặc ĐÃ có báo cáo hoặc vừa thử <6h ⇒ KHÔNG nằm trong danh sách chờ',
        () async {
      final int finishedNoReport = dao.addSession(base, endedAt: base);
      dao.addSession(base.subtract(const Duration(hours: 1))); // phiên CHƯA kết thúc
      final int withReport = dao.addSession(base.subtract(const Duration(hours: 2)), endedAt: base);
      dao.reports[withReport] = PostReviewReportRow(
        sessionId: withReport,
        generatedAt: base,
        good: 'g',
        missed: 'm',
        exercise: 'e',
        segmentCount: 2,
        truncated: false,
      );
      final int justAttempted =
          dao.addSession(base.subtract(const Duration(hours: 3)), endedAt: base);
      dao.analysisAttempts[justAttempted] = _fixedNow;

      final List<TranscriptSession> pending = await dao.finishedSessionsWithoutReport(limit: 5);

      expect(pending.map((TranscriptSession s) => s.id), <int>[finishedNoReport],
          reason: 'chỉ phiên đã kết thúc + chưa có báo cáo + quá hạn throttle mới được thử');
    });

    test('sắp xếp CŨ NHẤT trước và tôn trọng `limit`', () async {
      final int newest = dao.addSession(base, endedAt: base);
      final int oldest = dao.addSession(base.subtract(const Duration(days: 2)), endedAt: base);
      final int middle = dao.addSession(base.subtract(const Duration(days: 1)), endedAt: base);

      final List<TranscriptSession> firstTwo =
          await dao.finishedSessionsWithoutReport(limit: 2);
      expect(firstTwo.map((TranscriptSession s) => s.id), <int>[oldest, middle]);

      final List<TranscriptSession> all = await dao.finishedSessionsWithoutReport(limit: 5);
      expect(all.map((TranscriptSession s) => s.id), <int>[oldest, middle, newest]);
    });
  });

  group('DoD 4 — catchUp() phân tích lại thành công', () {
    test('LLM thành công lần này ⇒ phiên có báo cáo + `sessionIdsWithReport()` chứa phiên', () async {
      final int sessionId = dao.addSession(base, endedAt: base);
      dao.addSegment(sessionId, 'dạ em chào anh');
      dao.addSegment(sessionId, 'anh ăn cơm chưa');

      final PendingAnalysisOutcome outcome = await _buildCatchUp(dao, llm).catchUp();

      expect(outcome.analyzed, 1);
      expect(outcome.stoppedReason, isNull);
      expect((await dao.sessionIdsWithReport()), contains(sessionId));
      expect(llm.calls, 1);
      // Prompt phải là transcript THẬT của phiên đó (không phải phiên đang mở — ở đây không có phiên nào).
      expect(llm.prompts.single, contains('anh ăn cơm chưa'));
      expect(dao.reports[sessionId]!.segmentCount, 2);
    });

    test('phiên bất kỳ (không phải phiên đang mở) — báo cáo gắn ĐÚNG sessionId của nó', () async {
      final int a = dao.addSession(base.subtract(const Duration(days: 1)), endedAt: base);
      dao.addSegment(a, 'chuyện hôm qua');
      final int b = dao.addSession(base, endedAt: base);
      dao.addSegment(b, 'chuyện hôm nay');

      await _buildCatchUp(dao, llm).catchUp();

      expect((await dao.sessionIdsWithReport()), <int>{a, b});
      expect(dao.reports[a]!.sessionId, a);
      expect(dao.reports[b]!.sessionId, b);
    });

    test('thứ tự xử lý tuần tự, cũ nhất trước (không song song)', () async {
      final int old = dao.addSession(base.subtract(const Duration(days: 2)), endedAt: base);
      final int recent = dao.addSession(base, endedAt: base);
      dao.addSegment(old, 'cũ');
      dao.addSegment(recent, 'mới');

      await _buildCatchUp(dao, llm).catchUp();

      expect(llm.calls, 2, reason: 'tuần tự: 2 phiên ⇒ 2 request, lần lượt');
      expect(llm.prompts.first, contains('cũ'));
      expect(llm.prompts.last, contains('mới'));
      // `markAnalysisAttempted` phải chạy TRƯỚC khi gọi LLM (app bị kill cũng không thử lại ngay).
      expect(dao.analysisAttempts.keys, containsAll(<int>[old, recent]));
    });
  });

  group('DoD 5 — throttle 6 giờ (không đập lại phiên vừa thử)', () {
    test('gọi catchUp() 2 lần liên tiếp cho phiên lỗi nội dung ⇒ lần 2 KHÔNG gọi LLM', () async {
      final int sessionId = dao.addSession(base, endedAt: base);
      dao.addSegment(sessionId, 'dạ em chào anh');
      // Lỗi NỘI DUNG (LLM trả định dạng lạ) — không phải lỗi hạ tầng, nên lượt đó đi tiếp được.
      llm.result = 'không phải JSON';

      final PendingAnalysisService service = _buildCatchUp(dao, llm);

      final PendingAnalysisOutcome first = await service.catchUp();
      expect(first.analyzed, 0);
      expect(first.stoppedReason, isNull, reason: 'lỗi nội dung chỉ hỏng 1 phiên, không dừng lượt');
      expect(llm.calls, 1);

      final PendingAnalysisOutcome second = await service.catchUp();
      expect(second.analyzed, 0);
      expect(llm.calls, 1, reason: 'vừa thử <6h ⇒ KHÔNG được thử lại (throttle)');

      // Sau khi hết hạn throttle thì phiên đó lại được thử.
      dao.analysisAttempts[sessionId] =
          _fixedNow.subtract(const Duration(hours: 7));
      await service.catchUp();
      expect(llm.calls, 2);
    });
  });

  group('lỗi hạ tầng ⇒ dừng cả lượt; thiếu key ⇒ không chạy', () {
    test('LLM lỗi mạng ở phiên đầu ⇒ dừng ngay, KHÔNG thử phiên thứ hai', () async {
      final int first = dao.addSession(base.subtract(const Duration(days: 1)), endedAt: base);
      final int second = dao.addSession(base, endedAt: base);
      dao.addSegment(first, 'phiên 1');
      dao.addSegment(second, 'phiên 2');
      llm.throwError = const SuggestionException('lỗi mạng khi gọi LLM');

      final PendingAnalysisOutcome outcome = await _buildCatchUp(dao, llm).catchUp();

      expect(llm.calls, 1, reason: 'nguyên nhân là hạ tầng ⇒ thử tiếp là vô nghĩa');
      expect(outcome.analyzed, 0);
      expect(outcome.stoppedReason, contains('mạng'));
    });

    test('chưa có API key ⇒ không gọi LLM, không ghi mốc throttle', () async {
      final int sessionId = dao.addSession(base, endedAt: base);
      dao.addSegment(sessionId, 'dạ em chào anh');

      final PendingAnalysisOutcome outcome = await _buildCatchUp(dao, llm, hasKey: false).catchUp();

      expect(outcome.analyzed, 0);
      expect(outcome.stoppedReason, contains('API key'));
      expect(llm.calls, 0);
      expect(dao.analysisAttempts, isEmpty,
          reason: 'thiếu key không phải lỗi của phiên — không được tiêu mất 6h throttle của nó');
    });

    test('không có phiên nào cần phân tích ⇒ kết quả rỗng, không phải lỗi', () async {
      final PendingAnalysisOutcome outcome = await _buildCatchUp(dao, llm).catchUp();
      expect(outcome.analyzed, 0);
      expect(outcome.stoppedReason, isNull);
      expect(llm.calls, 0);
    });
  });

  group('DoD 7 — nút "Phân tích lại các buổi còn thiếu" trong Lịch sử', () {
    testWidgets('bấm nút ⇒ SnackBar kết quả + chú thích "có báo cáo" cập nhật ngay', (WidgetTester tester) async {
      final int sessionId = dao.addSession(base, endedAt: base);
      // Service giả: khi được gọi thì ghi luôn 1 báo cáo vào DAO (mô phỏng phân tích bù thành công).
      final _FakePending fake = _FakePending(
        const PendingAnalysisOutcome.done(1),
        onCall: () => dao.reports[sessionId] = PostReviewReportRow(
          sessionId: sessionId,
          generatedAt: base,
          good: 'g',
          missed: 'm',
          exercise: 'e',
          segmentCount: 2,
          truncated: false,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(home: HistoryScreen(dao: dao, pendingAnalysis: fake)),
      );
      await tester.pumpAndSettle();

      expect(find.text('chưa có báo cáo'), findsOneWidget);

      await tester.tap(find.byTooltip('Phân tích lại các buổi còn thiếu'));
      // KHÔNG `pumpAndSettle` ngay sau khi bấm: lúc đang chạy, icon là `CircularProgressIndicator`
      // (animation vô hạn) nên `pumpAndSettle` sẽ không bao giờ hồi. Ở đây service giả trả về tức thì,
      // nên 2 nhịp `pump` là đủ để lượt chạy xong + SnackBar hiện.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(fake.calls, 1);
      expect(find.text('Đã phân tích lại 1 buổi.'), findsOneWidget);
      expect(find.text('có nhận xét cuối buổi — bấm để xem lại'), findsOneWidget);
    });

    testWidgets('không có gì để làm ⇒ SnackBar nói rõ "Không có buổi nào cần phân tích."',
        (WidgetTester tester) async {
      dao.addSession(base, endedAt: base);
      final _FakePending fake = _FakePending(const PendingAnalysisOutcome.done(0));

      await tester.pumpWidget(
        MaterialApp(home: HistoryScreen(dao: dao, pendingAnalysis: fake)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Phân tích lại các buổi còn thiếu'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Không có buổi nào cần phân tích.'), findsOneWidget);
    });

    testWidgets('dừng vì lý do cụ thể ⇒ SnackBar nêu đúng lý do', (WidgetTester tester) async {
      dao.addSession(base, endedAt: base);
      final _FakePending fake = _FakePending(
        const PendingAnalysisOutcome.stopped(analyzed: 0, stoppedReason: 'lỗi mạng khi gọi LLM'),
      );

      await tester.pumpWidget(
        MaterialApp(home: HistoryScreen(dao: dao, pendingAnalysis: fake)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Phân tích lại các buổi còn thiếu'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('lỗi mạng khi gọi LLM'), findsOneWidget);
    });
  });

  group('DoD 6 — init() của app tự chạy catch-up (không chặn, không crash)', () {
    SessionCoordinator build(_FakePending service) => SessionCoordinator(
          messengerKey: GlobalKey<ScaffoldMessengerState>(),
          startService: () async => true,
          stopService: () async {},
          capture: _FakeCapture(),
          pendingAnalysis: service,
        );

    test('init() ⇒ catch-up tự chạy đúng 1 lượt, không chặn các lệnh load khác', () async {
      final _FakePending service = _FakePending(const PendingAnalysisOutcome.done(0));
      final SessionCoordinator coordinator = build(service);

      coordinator.init();
      // Các lệnh load được gọi TRƯỚC/ĐỘC LẬP với catch-up: chỉ cần 1 vòng microtask là catch-up đã chạy.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(service.calls, 1);
      coordinator.dispose();
    });

    test('service lỗi ⇒ init() không crash, không ném ra ngoài', () async {
      final _FakePending service = _FakePending(
        const PendingAnalysisOutcome.done(0),
        throwError: StateError('bùm'),
      );
      final SessionCoordinator coordinator = build(service);

      coordinator.init();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(service.calls, 1);
      coordinator.dispose();
    });

    test('gọi lại nhiều lần ⇒ KHÔNG chạy chồng (cờ chặn)', () async {
      final _FakePending service = _FakePending(const PendingAnalysisOutcome.done(0));
      service.gate = Completer<void>();
      final SessionCoordinator coordinator = build(service);

      coordinator.init();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // Lượt 1 vẫn đang chạy (chưa mở gate) — gọi thêm 2 lần nữa phải bị bỏ qua.
      unawaited(coordinator.catchUpPendingAnalyses());
      unawaited(coordinator.catchUpPendingAnalyses());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(service.calls, 1, reason: 'cờ _catchUpRunning phải chặn lượt chồng');

      service.gate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      coordinator.dispose();
    });
  });
}
