// Test P1E — `TranscriptStore`: lưu dòng transcript có timestamp, rolling window trong RAM, khôi phục
// sau khi app bị kill (DoD 2), tự xoá sau 7 ngày (DoD 3), API text thô không nhãn cho P2 (DoD 4).
//
// Cách test crash recovery ở đây: mô phỏng "app đã bị OS kill" bằng cách dựng sẵn dữ liệu trong DAO
// giả (coi như lần chạy trước đã ghi xuống đĩa) rồi tạo một `TranscriptStore` MỚI + `init()` — đúng
// đường đi của lần mở app sau. Quy trình test trên máy thật (adb) ghi ở `lib/transcript/README.md`.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_assistant_phone/audio/asr/asr_engine.dart';
import 'package:ai_assistant_phone/services/storage/transcript_dao.dart';
import 'package:ai_assistant_phone/transcript/transcript_segment.dart';
import 'package:ai_assistant_phone/transcript/transcript_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Đồng hồ giả — mọi mốc thời gian trong test đi qua đây (không dùng `DateTime.now()` thật).
class _MutableClock {
  _MutableClock(this.value);

  DateTime value;

  DateTime call() => value;
}

/// DAO giả trong bộ nhớ (sqflite cần platform channel nên không dùng được ở unit test).
class _FakeDao implements TranscriptDao {
  final List<TranscriptSession> sessions = <TranscriptSession>[];
  final Map<int, List<TranscriptSegment>> segments = <int, List<TranscriptSegment>>{};
  final Map<int, List<DateTime>> pushes = <int, List<DateTime>>{};
  final Map<int, PostReviewReportRow> reports = <int, PostReviewReportRow>{};

  /// Mốc cutoff của lần `deleteOlderThan` gần nhất — để test khẳng định đúng hạn 7 ngày.
  DateTime? lastCutoff;

  int _nextId = 1;

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
    );
  }

  @override
  Future<void> appendSegment(int sessionId, TranscriptSegment segment) async {
    segments.putIfAbsent(sessionId, () => <TranscriptSegment>[]).add(segment);
  }

  @override
  Future<List<TranscriptSegment>> segmentsSince(int sessionId, DateTime since) async {
    final List<TranscriptSegment> all = segments[sessionId] ?? <TranscriptSegment>[];
    return all
        .where((TranscriptSegment s) => !s.timestamp.isBefore(since))
        .toList();
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

  // P5: hai truy vấn mới cho thống kê tuần — bản giả gộp từ cùng dữ liệu trong bộ nhớ, giữ đúng ngữ
  // nghĩa "kể từ [since]" của bản thật (xem doc `sessionsSince`/`pushesSince` trong `transcript_dao`).
  @override
  Future<List<TranscriptSession>> sessionsSince(DateTime since) async => sessions
      .where((TranscriptSession s) => !s.lastActivityAt.isBefore(since))
      .toList();

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
  Future<int> deleteOlderThan(DateTime cutoff) async {
    lastCutoff = cutoff;
    final List<TranscriptSession> old = sessions
        .where((TranscriptSession s) => s.lastActivityAt.isBefore(cutoff))
        .toList();
    for (final TranscriptSession session in old) {
      sessions.removeWhere((TranscriptSession s) => s.id == session.id);
      segments.remove(session.id);
      pushes.remove(session.id);
      reports.remove(session.id);
    }
    return old.length;
  }

  // P5.1: 3 methods mới của interface — bản giả gộp từ cùng map trong bộ nhớ.
  @override
  Future<List<TranscriptSession>> allSessions({int limit = 100}) async {
    final List<TranscriptSession> sorted = List<TranscriptSession>.of(sessions)
      ..sort((TranscriptSession a, TranscriptSession b) =>
          b.lastActivityAt.compareTo(a.lastActivityAt));
    return sorted.take(limit).toList();
  }

  @override
  Future<PostReviewReportRow?> reportForSession(int sessionId) =>
      Future<PostReviewReportRow?>.value(reports[sessionId]);

  @override
  Future<Set<int>> sessionIdsWithReport() => Future<Set<int>>.value(reports.keys.toSet());

  @override
  Future<void> markSessionEnded(int sessionId, DateTime endedAt) async {
    final int index = sessions.indexWhere((TranscriptSession s) => s.id == sessionId);
    if (index < 0) {
      return;
    }
    final TranscriptSession old = sessions[index];
    sessions[index] = TranscriptSession(
      id: old.id,
      startedAt: old.startedAt,
      lastActivityAt: old.lastActivityAt,
      title: old.title,
      endedAt: endedAt,
    );
  }

  @override
  Future<void> renameSession(int sessionId, String? title) async {
    final int index = sessions.indexWhere((TranscriptSession s) => s.id == sessionId);
    if (index < 0) {
      return;
    }
    final TranscriptSession old = sessions[index];
    sessions[index] = TranscriptSession(
      id: old.id,
      startedAt: old.startedAt,
      lastActivityAt: old.lastActivityAt,
      title: title,
    );
  }

  @override
  Future<void> saveReport(int sessionId, PostReviewReportRow report) async {
    reports[sessionId] = report;
  }
}

/// Engine ASR giả: chỉ cần một stream để bơm text (hợp đồng đầy đủ đã test ở
/// `asr_engine_contract_test.dart`).
class _FakeAsrEngine implements AsrEngine {
  final StreamController<String> _controller = StreamController<String>.broadcast();

  @override
  int get droppedTotal => 0;

  @override
  Future<void> init() async {}

  @override
  Stream<String> get transcriptStream => _controller.stream;

  @override
  Future<void> feedAudioChunk(Uint8List chunk) async {}

  @override
  Future<void> dispose() async {
    await _controller.close();
  }

  void emit(String text) => _controller.add(text);
}

void main() {
  late _MutableClock clock;
  late _FakeDao dao;

  final DateTime base = DateTime(2026, 9, 22, 10, 0);

  setUp(() {
    clock = _MutableClock(base);
    dao = _FakeDao();
  });

  TranscriptStore buildStore({
    Duration window = const Duration(minutes: 8),
    Duration gap = const Duration(minutes: 30),
    Duration retention = const Duration(days: 7),
  }) {
    return TranscriptStore(
      dao: dao,
      now: clock.call,
      rollingWindow: window,
      resumeGap: gap,
      retention: retention,
    );
  }

  group('lưu dòng transcript (DoD 1)', () {
    test('giữ text đã trim + timestamp của đồng hồ, ghi xuống đĩa ngay', () async {
      final TranscriptStore store = buildStore();
      final TranscriptSegment? saved = await store.add('  xin chào  ');

      expect(saved, isNotNull);
      expect(saved!.text, 'xin chào');
      expect(saved.timestamp, base);
      expect(store.sessionId, isNotNull);
      // Đã xuống đĩa chứ không chỉ nằm trong RAM ⇒ kill app là không mất.
      expect(dao.segments[store.sessionId!], <TranscriptSegment>[saved]);
      expect(store.memorySegmentCount, 1);
    });

    test('bỏ qua text rỗng / chỉ khoảng trắng (ASR có thể phát chuỗi trắng)', () async {
      final TranscriptStore store = buildStore();
      expect(await store.add(''), isNull);
      expect(await store.add('   \n '), isNull);
      expect(store.memorySegmentCount, 0);
      // Không có gì để lưu ⇒ không mở phiên, không ghi đĩa (init là lazy).
      expect(store.sessionId, isNull);
      expect(dao.sessions, isEmpty);
    });

    test('nhiều dòng đến sát nhau vẫn giữ đúng thứ tự (ghi tuần tự)', () async {
      final TranscriptStore store = buildStore();
      // Không await: ba lời gọi chồng lên nhau, đúng tình huống stream ASR dồn dòng.
      final Future<TranscriptSegment?> a = store.add('một');
      final Future<TranscriptSegment?> b = store.add('hai');
      final Future<TranscriptSegment?> c = store.add('ba');
      await Future.wait(<Future<TranscriptSegment?>>[a, b, c]);

      final List<String> texts = dao.segments[store.sessionId!]!
          .map((TranscriptSegment s) => s.text)
          .toList();
      expect(texts, <String>['một', 'hai', 'ba']);
    });

    test('lỗi khi ghi không làm chết phiên (trả null, các dòng sau vẫn ghi được)', () async {
      final _FailingDao failing = _FailingDao();
      final TranscriptStore store = TranscriptStore(dao: failing, now: clock.call);

      expect(await store.add('dòng lỗi'), isNull); // ghi đĩa ném lỗi → bị nuốt + log
      failing.broken = false;
      expect(await store.add('dòng sau'), isNotNull);
    });
  });

  group('rolling window trong bộ nhớ (task 3)', () {
    test('RAM chỉ giữ cửa sổ gần nhất, đĩa giữ TẤT CẢ dòng', () async {
      final TranscriptStore store = buildStore(window: const Duration(minutes: 2));

      await store.add('dòng cũ', at: base.subtract(const Duration(minutes: 5)));
      await store.add('dòng vừa', at: base.subtract(const Duration(minutes: 1)));
      await store.add('dòng mới', at: base);

      // Cửa sổ 2 phút tính từ dòng mới nhất ⇒ 'dòng cũ' (−5 phút) bị đẩy khỏi RAM…
      expect(store.memorySegmentCount, 2);
      expect(
        store.memorySegments.map((TranscriptSegment s) => s.text),
        <String>['dòng vừa', 'dòng mới'],
      );
      // …nhưng đĩa vẫn còn đủ 3 dòng (không mất dữ liệu phiên).
      expect(dao.segments[store.sessionId!]!.length, 3);
    });
  });

  group('khôi phục sau khi app bị kill (DoD 2)', () {
    test('mở lại app trong hạn resume ⇒ phiên cũ được khôi phục nguyên vẹn', () async {
      // Lần chạy trước: phiên #1 hoạt động 1 phút trước, có 2 dòng + 1 mốc Push.
      final TranscriptSession previous = await dao.createSession(base.subtract(const Duration(minutes: 5)));
      await dao.appendSegment(
        previous.id,
        TranscriptSegment(
          text: 'câu nói trước khi bị kill',
          timestamp: base.subtract(const Duration(minutes: 1)),
        ),
      );
      await dao.touchSession(previous.id, base.subtract(const Duration(minutes: 1)));
      await dao.recordPush(previous.id, base.subtract(const Duration(minutes: 2)));

      // Lần chạy này (app mở lại): store HOÀN TOÀN mới, không giữ gì trong RAM.
      final TranscriptStore store = buildStore();
      await store.init();

      expect(store.sessionId, previous.id, reason: 'phải nối tiếp phiên đang dở');
      expect(store.recoveredSegmentCount, 1);
      expect(store.memorySegments.single.text, 'câu nói trước khi bị kill');
      expect(store.lastPushMoment, base.subtract(const Duration(minutes: 2)));
      // Và dòng mới vẫn ghi tiếp vào đúng phiên cũ đó.
      await store.add('nói tiếp sau khi mở lại');
      expect(dao.segments[previous.id]!.length, 2);
      expect(dao.segments[previous.id]!.last.text, 'nói tiếp sau khi mở lại');
    });

    test('phiên cũ hơn hạn resume ⇒ mở phiên MỚI, dữ liệu cũ vẫn nằm trên đĩa', () async {
      final TranscriptSession previous =
          await dao.createSession(base.subtract(const Duration(hours: 3)));
      await dao.appendSegment(
        previous.id,
        TranscriptSegment(text: 'hội thoại hôm trước', timestamp: base.subtract(const Duration(hours: 3))),
      );
      await dao.touchSession(previous.id, base.subtract(const Duration(hours: 3)));

      final TranscriptStore store = buildStore();
      await store.init();

      expect(store.sessionId, isNot(previous.id));
      expect(store.recoveredSegmentCount, 0);
      expect(store.memorySegmentCount, 0);
      // Phiên cũ KHÔNG bị xoá (mới 3 giờ, chưa quá 7 ngày) — P5 cần nó cho Post-Review.
      expect(dao.segments[previous.id]!.single.text, 'hội thoại hôm trước');
    });

    test('init lỗi thoáng qua ⇒ lần sau thử lại được (không cache future đã hỏng)', () async {
      final _FlakyDao flaky = _FlakyDao();
      final TranscriptStore store = TranscriptStore(dao: flaky, now: clock.call);

      await expectLater(store.init(), throwsA(isA<StateError>()));
      expect(store.sessionId, isNull);

      flaky.broken = false; // DB hết bị khoá
      await store.init();
      expect(store.sessionId, isNotNull, reason: 'store phải dùng được sau khi thử lại');
    });

    test('ASR lỗi giữa stream không làm hỏng việc ghi transcript', () async {
      final TranscriptStore store = buildStore();
      final _FakeAsrEngine engine = _FakeAsrEngine();
      store.attach(engine);
      engine.emit('câu một');
      await pumpEventQueue();
      await store.close();

      expect(store.memorySegmentCount, 1);
      expect(store.memorySegments.single.text, 'câu một');
    });
  });

  group('tự xoá sau 7 ngày (DoD 3)', () {
    test('xoá phiên cũ hơn 7 ngày (kèm dòng + mốc Push), giữ phiên còn hạn', () async {
      // Phiên cũ: 8 ngày trước. Phiên gần: 1 phút trước.
      final TranscriptSession old =
          await dao.createSession(base.subtract(const Duration(days: 8)));
      await dao.appendSegment(
        old.id,
        TranscriptSegment(text: 'chuyện cũ', timestamp: base.subtract(const Duration(days: 8))),
      );
      await dao.touchSession(old.id, base.subtract(const Duration(days: 8)));
      await dao.recordPush(old.id, base.subtract(const Duration(days: 8)));

      final TranscriptSession recent =
          await dao.createSession(base.subtract(const Duration(minutes: 2)));
      await dao.appendSegment(
        recent.id,
        TranscriptSegment(text: 'chuyện mới', timestamp: base.subtract(const Duration(minutes: 1))),
      );
      await dao.touchSession(recent.id, base.subtract(const Duration(minutes: 1)));

      final TranscriptStore store = buildStore();
      await store.init();

      // Mốc xoá truyền xuống DAO đúng bằng "now − 7 ngày".
      expect(dao.lastCutoff, base.subtract(const Duration(days: 7)));
      expect(dao.sessions.map((TranscriptSession s) => s.id), <int>[recent.id]);
      expect(dao.segments.containsKey(old.id), isFalse, reason: 'dòng của phiên cũ phải bị xoá');
      expect(dao.pushes.containsKey(old.id), isFalse, reason: 'mốc Push của phiên cũ phải bị xoá');
      expect(dao.segments[recent.id]!.single.text, 'chuyện mới');
    });
  });

  group('mốc Push (task 5)', () {
    test('ghi MỌI lần bấm, `lastPushMoment` là mốc gần nhất', () async {
      final TranscriptStore store = buildStore();
      await store.markPushMoment(base.subtract(const Duration(minutes: 5)));
      await store.markPushMoment(base.subtract(const Duration(minutes: 1)));

      expect(store.lastPushMoment, base.subtract(const Duration(minutes: 1)));
      expect(dao.pushes[store.sessionId!]!.length, 2);
    });
  });

  group('API cho Suggestion Engine P2 (DoD 4)', () {
    test('trả text thô KHÔNG nhãn người nói + mốc Push gần nhất', () async {
      final TranscriptStore store = buildStore();
      await store.add('bạn có muốn uống cà phê không', at: base.subtract(const Duration(minutes: 2)));
      await store.add('vâng tôi uống', at: base.subtract(const Duration(minutes: 1)));
      await store.markPushMoment(base.subtract(const Duration(seconds: 30)));

      final TranscriptWindow window = await store.recentWindow();

      expect(window.text, 'bạn có muốn uống cà phê không\nvâng tôi uống');
      expect(window.lastPushMoment, base.subtract(const Duration(seconds: 30)));
      // Ràng buộc 4.2b: KHÔNG nhãn người nói trong bất kỳ dòng nào.
      expect(window.text.contains('['), isFalse);
      expect(window.text.contains('Bạn:'), isFalse);
      expect(window.text.contains('Đối phương'), isFalse);
    });

    test('cửa sổ dài hơn bộ nhớ hoạt động ⇒ đọc từ đĩa, không cắt cụt', () async {
      final TranscriptStore store = buildStore(window: const Duration(minutes: 2));
      await store.add('dòng 10 phút trước', at: base.subtract(const Duration(minutes: 10)));
      await store.add('dòng 2 phút trước', at: base.subtract(const Duration(minutes: 2)));
      await store.add('dòng mới', at: base);

      expect(store.memorySegmentCount, 2, reason: 'RAM chỉ giữ cửa sổ 2 phút');

      final TranscriptWindow window = await store.recentWindow(window: const Duration(minutes: 15));
      expect(window.segments.length, 3);
      expect(window.text.split('\n').first, 'dòng 10 phút trước');
    });

    test('phiên chưa có dòng nào ⇒ cửa sổ rỗng, không ném lỗi', () async {
      final TranscriptStore store = buildStore();
      final TranscriptWindow window = await store.recentWindow();
      expect(window.isEmpty, isTrue);
      expect(window.text, isEmpty);
      expect(window.lastPushMoment, isNull);
    });
  });

  group('gắn vào engine ASR (task 2)', () {
    test('attach lần hai (đổi engine như P1D) không nhân đôi dòng', () async {
      // Regression: `attach()` từng gọi `unawaited(detach())` ⇒ nhánh treo của detach chạy sau khi
      // subscription mới được gán và xoá mất tham chiếu ⇒ stream cũ vẫn ghi vào transcript.
      final TranscriptStore store = buildStore();
      final _FakeAsrEngine first = _FakeAsrEngine();
      final _FakeAsrEngine second = _FakeAsrEngine();

      store.attach(first);
      store.attach(second);
      first.emit('từ engine cũ');
      second.emit('từ engine mới');
      await pumpEventQueue();

      expect(store.memorySegmentCount, 1);
      expect(store.memorySegments.single.text, 'từ engine mới');

      await store.close();
      await first.dispose();
      await second.dispose();
    });

    test('mỗi text engine phát ra thành một dòng; detach thì thôi nhận', () async {
      final TranscriptStore store = buildStore();
      final _FakeAsrEngine engine = _FakeAsrEngine();

      store.attach(engine);
      engine.emit('câu thứ nhất');
      engine.emit('   ');
      engine.emit('câu thứ hai');
      await pumpEventQueue();

      expect(store.memorySegmentCount, 2, reason: 'chuỗi trắng không thành dòng');

      await store.detach();
      engine.emit('câu sau khi detach');
      await pumpEventQueue();
      expect(store.memorySegmentCount, 2);

      await store.close();
      await engine.dispose();
    });
  });
}

/// DAO giả có thể "hỏng" để test nhánh lỗi ghi đĩa.
class _FailingDao extends _FakeDao {
  bool broken = true;

  @override
  Future<void> appendSegment(int sessionId, TranscriptSegment segment) async {
    if (broken) {
      throw StateError('đĩa giả lập đầy');
    }
    return super.appendSegment(sessionId, segment);
  }
}

/// DAO giả "hỏng lúc mở DB" (ví dụ SQLite đang bị khoá) — dùng để test khả năng thử lại của
/// `TranscriptStore.init()`.
class _FlakyDao extends _FakeDao {
  bool broken = true;

  @override
  Future<int> deleteOlderThan(DateTime cutoff) async {
    if (broken) {
      throw StateError('DB đang bị khoá');
    }
    return super.deleteOlderThan(cutoff);
  }
}
