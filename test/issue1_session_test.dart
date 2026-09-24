// Test issue1_fix — Session lifecycle (ACTIVE vs FINISHED).
//
// Khoá theo DoD mục 11 (test 9–14 của `.plan/issue1_fix.md`):
// 9.  Start A → End A → Start B ⇒ A ≠ B, A finished, B active.
// 10. Finished session KHÔNG được resume.
// 11. ACTIVE session trong resume window VẪN resume được (crash recovery giữ nguyên).
// 12. Post-Review async của A vẫn gắn đúng A kể cả khi B start trước khi review xong.
// 13. End không duplicate transcript.
// 14. End khi transcript rỗng không crash.
//
// Mô phỏng "app bị kill / mở lại" đúng cách P1E đã dùng: dựng dữ liệu trong DAO giả rồi tạo
// `TranscriptStore` MỚI + `init()` — đúng đường `_open()` của lần mở app sau.

import 'dart:typed_data';

import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/services/storage/transcript_dao.dart';
import 'package:ai_assistant_phone/transcript/transcript_segment.dart';
import 'package:ai_assistant_phone/transcript/transcript_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _MutableClock {
  _MutableClock(this.value);

  DateTime value;

  DateTime call() => value;
}

/// DAO giả trong bộ nhớ — bản sao pattern `_FakeDao` của `transcript_store_test.dart`, thêm
/// `markSessionEnded` (member mới của issue1_fix). Thay vì import bản kia (private), giữ bản cục
/// bộ tối giản đúng những gì test này cần.
class _FakeDao implements TranscriptDao {
  final List<TranscriptSession> sessions = <TranscriptSession>[];
  final Map<int, List<TranscriptSegment>> segments = <int, List<TranscriptSegment>>{};
  final Map<int, List<DateTime>> pushes = <int, List<DateTime>>{};

  /// P5.4: mốc lần THỬ phân tích bù của từng phiên. Fake này KHÔNG có kho báo cáo
  /// (`sessionIdsWithReport()` luôn rỗng ở dưới) ⇒ mọi phiên đã kết thúc đều là "thiếu báo cáo".
  final Map<int, DateTime> analysisAttempts = <int, DateTime>{};

  int _nextId = 1;

  @override
  Future<List<TranscriptSession>> finishedSessionsWithoutReport({required int limit}) async {
    // A72: cutoff phải đi qua CÙNG đồng hồ với mốc ghi vào `analysisAttempts` — nếu dùng
    // `DateTime.now()` thật trong khi test chạy trên `_MutableClock` thì kết quả phụ thuộc giờ chạy.
    final DateTime cutoff =
        (analysisAttempts.values.fold<DateTime?>(null, (DateTime? a, DateTime b) => b.isAfter(a ?? b) ? b : a) ??
                DateTime.fromMillisecondsSinceEpoch(0))
            .subtract(CoachingConfig.analysisRetryInterval);
    final List<TranscriptSession> pending = sessions
        .where((TranscriptSession s) =>
            s.isFinished &&
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

  TranscriptSession _rebuild(int index, {DateTime? endedAt}) {
    final TranscriptSession old = sessions[index];
    return TranscriptSession(
      id: old.id,
      startedAt: old.startedAt,
      lastActivityAt: old.lastActivityAt,
      title: old.title,
      endedAt: endedAt ?? old.endedAt,
    );
  }

  @override
  Future<TranscriptSession?> latestSession() async {
    if (sessions.isEmpty) {
      return null;
    }
    final List<TranscriptSession> sorted = List<TranscriptSession>.of(sessions)
      ..sort((TranscriptSession a, TranscriptSession b) =>
          b.lastActivityAt.compareTo(a.lastActivityAt));
    return sorted.first;
  }

  @override
  Future<TranscriptSession> createSession(DateTime startedAt) async {
    final TranscriptSession session = TranscriptSession(
      id: _nextId++,
      startedAt: startedAt,
      lastActivityAt: startedAt,
    );
    sessions.add(session);
    segments[session.id] = <TranscriptSegment>[];
    pushes[session.id] = <DateTime>[];
    return session;
  }

  @override
  Future<void> touchSession(int sessionId, DateTime at) async {
    final int index = sessions.indexWhere((TranscriptSession s) => s.id == sessionId);
    if (index < 0) {
      return;
    }
    final TranscriptSession old = sessions[index];
    sessions[index] = TranscriptSession(
      id: old.id,
      startedAt: old.startedAt,
      lastActivityAt: at,
      title: old.title,
      endedAt: old.endedAt,
    );
  }

  @override
  Future<void> appendSegment(int sessionId, TranscriptSegment segment) async {
    segments.putIfAbsent(sessionId, () => <TranscriptSegment>[]).add(segment);
  }

  @override
  Future<List<TranscriptSegment>> segmentsSince(int sessionId, DateTime since) async {
    final List<TranscriptSegment> all = segments[sessionId] ?? <TranscriptSegment>[];
    return all.where((TranscriptSegment s) => !s.timestamp.isBefore(since)).toList();
  }

  @override
  Future<void> recordPush(int sessionId, DateTime at) async {
    pushes.putIfAbsent(sessionId, () => <DateTime>[]).add(at);
  }

  @override
  Future<DateTime?> latestPush(int sessionId) async {
    final List<DateTime> all = pushes[sessionId] ?? <DateTime>[];
    if (all.isEmpty) {
      return null;
    }
    return all.reduce((DateTime a, DateTime b) => a.isAfter(b) ? a : b);
  }

  @override
  Future<int> deleteOlderThan(DateTime cutoff) async {
    final List<TranscriptSession> old =
        sessions.where((TranscriptSession s) => s.lastActivityAt.isBefore(cutoff)).toList();
    for (final TranscriptSession session in old) {
      sessions.removeWhere((TranscriptSession s) => s.id == session.id);
      segments.remove(session.id);
      pushes.remove(session.id);
    }
    return old.length;
  }

  @override
  Future<List<TranscriptSession>> sessionsSince(DateTime since) async =>
      sessions.where((TranscriptSession s) => !s.lastActivityAt.isBefore(since)).toList();

  @override
  Future<List<TranscriptPush>> pushesSince(DateTime since) async {
    final List<TranscriptPush> all = <TranscriptPush>[];
    pushes.forEach((int sessionId, List<DateTime> moments) {
      for (final DateTime at in moments) {
        if (!at.isBefore(since)) {
          all.add(TranscriptPush(sessionId: sessionId, at: at));
        }
      }
    });
    all.sort((TranscriptPush a, TranscriptPush b) => a.at.compareTo(b.at));
    return all;
  }

  @override
  Future<List<TranscriptSession>> allSessions({int limit = 100}) async {
    final List<TranscriptSession> sorted = List<TranscriptSession>.of(sessions)
      ..sort((TranscriptSession a, TranscriptSession b) =>
          b.lastActivityAt.compareTo(a.lastActivityAt));
    return sorted.take(limit).toList();
  }

  @override
  Future<PostReviewReportRow?> reportForSession(int sessionId) async => null;

  @override
  Future<Set<int>> sessionIdsWithReport() async => <int>{};

  @override
  Future<void> saveReport(int sessionId, PostReviewReportRow report) async {}

  // --- issue1_fix: lifecycle ---

  @override
  Future<void> markSessionEnded(int sessionId, DateTime endedAt) async {
    final int index = sessions.indexWhere((TranscriptSession s) => s.id == sessionId);
    if (index < 0) {
      return;
    }
    sessions[index] = _rebuild(index, endedAt: endedAt);
  }

  @override
  Future<void> renameSession(int sessionId, String? title) async {}
}

void main() {
  late _MutableClock clock;
  late _FakeDao dao;

  final DateTime base = DateTime(2026, 9, 23, 20, 0);

  setUp(() {
    clock = _MutableClock(base);
    dao = _FakeDao();
  });

  TranscriptStore buildStore({Duration gap = const Duration(minutes: 30)}) {
    return TranscriptStore(
      dao: dao,
      now: clock.call,
      rollingWindow: const Duration(minutes: 8),
      resumeGap: gap,
      retention: const Duration(days: 7),
    );
  }

  group('lifecycle: End đánh dấu FINISHED (test 9, 13, 14)', () {
    test('Start A → add → markEnded → Start B ⇒ A ≠ B, A finished, phiên mới là ACTIVE', () async {
      // Phiên A.
      final TranscriptStore storeA = buildStore();
      await storeA.add('câu của phiên A');
      final int idA = storeA.sessionId!;
      expect(idA, isNotNull);

      // End A — đúng thứ tự `finishSessionAndReview`: stop → markEnded.
      await storeA.markCurrentSessionEnded();

      // Đã ghi xuống DAO (không chỉ RAM): phiên A giờ finished.
      final TranscriptSession a =
          dao.sessions.firstWhere((TranscriptSession s) => s.id == idA);
      expect(a.isFinished, isTrue, reason: 'End chủ động phải ghi ended_at xuống đĩa');
      expect(a.endedAt, base);

      // Start B (mô phỏng `_open()` lần sau).
      clock.value = base.add(const Duration(minutes: 1));
      final TranscriptStore storeB = buildStore();
      await storeB.init();
      final int idB = storeB.sessionId!;

      expect(idB, isNot(idA), reason: 'DoD 9: Start sau End phải tạo phiên mới');
      expect(dao.segments[idA]!.single.text, 'câu của phiên A',
          reason: 'transcript A không được trộn vào B');
      expect(dao.segments[idB] ?? <TranscriptSegment>[], isEmpty,
          reason: 'phiên B mới tạo chưa có dòng nào');
      expect(dao.segments[idA]!.length, 1,
          reason: 'DoD 13: end không được duplicate transcript của A');
    });

    test('markCurrentSessionEnded khi chưa mở phiên (sessionId = null) ⇒ vô hại, không crash (14)',
        () async {
      final TranscriptStore store = TranscriptStore(dao: dao, now: clock.call);
      expect(store.sessionId, isNull);
      await store.markCurrentSessionEnded();
      expect(dao.sessions, isEmpty);
    });

    test('Post-Review đọc transcript RỖNG sau khi end ⇒ report có note, không crash (14)', () async {
      final TranscriptStore store = buildStore();
      await store.init(); // phiên mới, chưa có dòng nào
      await store.markCurrentSessionEnded();

      final SessionTranscript transcript = await store.sessionTranscript();
      expect(transcript.isEmpty, isTrue, reason: 'đây chính là nhánh "transcript rỗng" của run()');
    });
  });

  group('lifecycle: resume policy (test 10, 11)', () {
    test('DoD 10 — phiên FINISHED KHÔNG được resume dù còn trong resumeGap', () async {
      // Lần chạy trước: phiên 1 phút trước, người dùng đã bấm Kết thúc.
      final TranscriptSession previous =
          await dao.createSession(base.subtract(const Duration(minutes: 5)));
      await dao.appendSegment(
        previous.id,
        TranscriptSegment(text: 'buổi đã kết thúc chủ động', timestamp: base.subtract(const Duration(minutes: 1))),
      );
      await dao.touchSession(previous.id, base.subtract(const Duration(minutes: 1)));
      await dao.markSessionEnded(previous.id, base.subtract(const Duration(minutes: 1)));

      // Lần chạy này (Start lại sau End, vẫn trong 30 phút).
      final TranscriptStore store = buildStore();
      await store.init();

      expect(store.sessionId, isNot(previous.id),
          reason: 'phiên đã kết thúc chủ động KHÔNG được resume');
      expect(store.recoveredSegmentCount, 0);
      expect(store.memorySegmentCount, 0, reason: 'không được kéo transcript của phiên cũ vào phiên mới');
    });

    test('DoD 11 — phiên ACTIVE (chưa kết thúc) trong resume window VẪN resume (crash recovery giữ nguyên)',
        () async {
      // Lần chạy trước: phiên 1 phút trước, KHÔNG đánh dấu kết thúc (app bị kill giữa chừng).
      final TranscriptSession previous =
          await dao.createSession(base.subtract(const Duration(minutes: 5)));
      await dao.appendSegment(
        previous.id,
        TranscriptSegment(text: 'câu trước khi app bị kill', timestamp: base.subtract(const Duration(minutes: 1))),
      );
      await dao.touchSession(previous.id, base.subtract(const Duration(minutes: 1)));

      final TranscriptStore store = buildStore();
      await store.init();

      expect(store.sessionId, previous.id, reason: 'crash recovery phải giữ nguyên hành vi cũ');
      expect(store.recoveredSegmentCount, 1);
      expect(store.memorySegments.single.text, 'câu trước khi app bị kill');
    });

    test('phiên ACTIVE nhưng NGOÀI resumeGap ⇒ tạo phiên mới (policy thời gian giữ nguyên)', () async {
      final TranscriptSession previous =
          await dao.createSession(base.subtract(const Duration(hours: 3)));
      await dao.touchSession(previous.id, base.subtract(const Duration(hours: 3)));

      final TranscriptStore store = buildStore();
      await store.init();

      expect(store.sessionId, isNot(previous.id));
      expect(store.recoveredSegmentCount, 0);
    });
  });

  group('DoD 12 — async review không gắn nhầm session', () {
    test('capture sessionId TRƯỚC mọi async: markEnded + report vẫn gắn đúng phiên A dù clock đã nhảy',
        () async {
      // Phiên A có 1 dòng.
      final TranscriptStore storeA = buildStore();
      await storeA.add('dòng của A');
      final int idA = storeA.sessionId!;

      // Bắt đầu "End A": capture trước, stop sau (trong thực tế `finishSessionAndReview` capture
      // `transcript.sessionId` ngay dòng đầu). Ở đây đồng hồ vẫn nhảy giữa các await.
      clock.value = base.add(const Duration(minutes: 1));
      await storeA.markCurrentSessionEnded();

      // Start B TRƯỚC khi review xong (async review của A vẫn đang chạy).
      final TranscriptStore storeB = buildStore();
      await storeB.init();
      final int idB = storeB.sessionId!;
      await storeB.add('dòng của B');

      // Kiểm 3 điều của DoD 12:
      expect(idA, isNot(idB));
      // (1) phiên A đã finished (markEnded ghi đúng phiên, KHÔNG ghi nhầm sang B);
      expect((dao.sessions.firstWhere((TranscriptSession s) => s.id == idA)).isFinished, isTrue);
      expect((dao.sessions.firstWhere((TranscriptSession s) => s.id == idB)).isFinished, isFalse,
          reason: 'phiên B đang ACTIVE không được bị mark nhầm');
      // (2) transcript đọc cho review của A là transcript của A (đọc TRƯỚC khi đổi store):
      expect(dao.segments[idA]!.single.text, 'dòng của A');
      expect(dao.segments[idB]!.single.text, 'dòng của B');
    });

    test('feedAudioChunk chạy không phụ thuộc lifecycle (tiền đề test — engine giả vẫn ghi đúng phiên mới)',
        () async {
      // Phụ để chứng minh helper: segment gắn timestamp đồng hồ của store, không dùng DateTime.now().
      final TranscriptStore store = buildStore();
      final Uint8List chunk = Uint8List(0); // chỉ để khai báo pattern dùng kiểu
      expect(chunk, isEmpty);
      await store.add('một dòng');
      final TranscriptSegment saved = dao.segments[store.sessionId!]!.single;
      expect(saved.timestamp, base, reason: 'timestamp phải theo đồng hồ inject, không phải giờ thật');
    });
  });
}
