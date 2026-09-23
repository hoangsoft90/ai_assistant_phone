// Test P5 task 4 — Thống kê tuần.
//
// Điều cần khoá:
// - "Số lần Push/buổi" đúng (mục 4.9) và bảng theo ngày đủ 7 ngày (ngày trống vẫn hiện số 0).
// - Xu hướng: so Push/buổi khi cả hai tuần đều có buổi; nếu tuần trước không có buổi thì so tổng Push.
// - Lỗi DB ⇒ `unavailable` + note (KHÔNG hiện "0 buổi" — số 0 giả bị hiểu là "tuần này không nói gì").
// - KHÔNG có logic tự đề xuất/đổi cấp: lớp này chỉ đếm (khẳng định bằng chính API — không có field nào
//   kiểu "suggestedLevel"/"recommendation").

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/coaching/weekly_stats.dart';
import 'package:ai_assistant_phone/services/storage/transcript_dao.dart';

class _FakeDao implements TranscriptDao {
  final List<TranscriptSession> sessions = <TranscriptSession>[];
  final List<TranscriptPush> pushes = <TranscriptPush>[];
  bool fail = false;

  int _nextId = 1;

  TranscriptSession addSession(DateTime startedAt, {DateTime? lastActivityAt}) {
    final TranscriptSession session = TranscriptSession(
      id: _nextId++,
      startedAt: startedAt,
      lastActivityAt: lastActivityAt ?? startedAt,
    );
    sessions.add(session);
    return session;
  }

  void addPush(int sessionId, DateTime at) =>
      pushes.add(TranscriptPush(sessionId: sessionId, at: at));

  @override
  Future<List<TranscriptSession>> sessionsSince(DateTime since) async {
    if (fail) {
      throw StateError('DB chưa mở');
    }
    return sessions
        .where((TranscriptSession s) => !s.lastActivityAt.isBefore(since))
        .toList();
  }

  @override
  Future<List<TranscriptPush>> pushesSince(DateTime since) async {
    if (fail) {
      throw StateError('DB chưa mở');
    }
    return pushes.where((TranscriptPush p) => !p.at.isBefore(since)).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeDao không hỗ trợ ${invocation.memberName}');
}

void main() {
  // Thứ Ba 23/09/2026, 20:00 — tuần 7 ngày gần nhất: 17/09 → 23/09.
  final DateTime now = DateTime(2026, 9, 23, 20, 0);
  final DateTime today = DateTime(2026, 9, 23);
  final DateTime weekStart = DateTime(2026, 9, 17);
  final DateTime previousWeekStart = DateTime(2026, 9, 10);

  late _FakeDao dao;

  WeeklyStatsService build() =>
      WeeklyStatsService(dao: dao, now: () => now);

  setUp(() => dao = _FakeDao());

  test('đếm đúng số buổi + tổng Push + Push/buổi trong 7 ngày', () async {
    final TranscriptSession a = dao.addSession(today.add(const Duration(hours: 9)));
    final TranscriptSession b =
        dao.addSession(today.add(const Duration(hours: 19)));
    for (int i = 0; i < 3; i++) {
      dao.addPush(a.id, today.add(Duration(hours: 9, minutes: i)));
    }
    dao.addPush(b.id, today.add(const Duration(hours: 19)));
    // Buổi của tuần TRƯỚC (ngoài 7 ngày) chỉ dùng để so xu hướng.
    final TranscriptSession old = dao.addSession(previousWeekStart.add(const Duration(hours: 10)));
    dao.addPush(old.id, previousWeekStart.add(const Duration(hours: 10)));

    final WeeklyStats stats = await build().load();

    expect(stats.available, isTrue);
    expect(stats.sessionCount, 2);
    expect(stats.pushCount, 4);
    expect(stats.pushesPerSession, 2.0);
    expect(stats.previousSessionCount, 1);
    expect(stats.previousPushCount, 1);
    // 4 Push / 2 buổi (tuần này) vs 1 Push / 1 buổi (tuần trước) ⇒ tăng.
    expect(stats.trend, StatsTrend.up);
  });

  test('bảng theo ngày: đủ 7 ngày, cũ → mới, buổi tính theo ngày BẮT ĐẦU', () async {
    dao.addSession(DateTime(2026, 9, 20, 22, 30)); // 20/09
    dao.addSession(today.add(const Duration(hours: 8))); // 23/09
    dao.addPush(1, DateTime(2026, 9, 20, 22, 45));
    dao.addPush(2, today.add(const Duration(hours: 8, minutes: 5)));

    final WeeklyStats stats = await build().load();

    expect(stats.days, hasLength(7));
    expect(stats.days.first.day, weekStart);
    expect(stats.days.last.day, today);
    expect(stats.days[0].isEmpty, isTrue); // 17/09
    expect(stats.days[3].sessions, 1); // 20/09
    expect(stats.days[3].pushes, 1);
    expect(stats.days.last.sessions, 1);
    expect(stats.days.last.pushes, 1);
  });

  test('buổi bắt đầu trước tuần này nhưng còn hoạt động trong tuần ⇒ không tính là buổi mới',
      () async {
    // 16/09 bắt đầu, 22/09 vẫn có hoạt động: nằm trong kết quả truy vấn (theo lastActivityAt) nhưng
    // KHÔNG thuộc 7 ngày gần nhất (theo startedAt).
    dao.addSession(DateTime(2026, 9, 16, 21, 0), lastActivityAt: DateTime(2026, 9, 22, 9, 0));

    final WeeklyStats stats = await build().load();

    expect(stats.sessionCount, 0);
    expect(stats.days.every((DayStat d) => d.sessions == 0), isTrue);
  });

  test('tuần trước không có buổi nào ⇒ so theo tổng Push', () async {
    dao.addSession(today.add(const Duration(hours: 9)));
    dao.addPush(1, today.add(const Duration(hours: 9)));

    final WeeklyStats stats = await build().load();

    expect(stats.previousSessionCount, 0);
    expect(stats.trend, StatsTrend.up);
  });

  test('không có gì trong 7 ngày ⇒ available + isEmpty (không phải lỗi)', () async {
    final WeeklyStats stats = await build().load();

    expect(stats.available, isTrue);
    expect(stats.isEmpty, isTrue);
    expect(stats.pushesPerSession, 0);
    expect(stats.trend, StatsTrend.flat);
    expect(stats.days, hasLength(7));
  });

  test('xu hướng: giảm + không đổi', () async {
    // Tuần trước 4 Push/1 buổi, tuần này 1 Push/1 buổi ⇒ giảm.
    final TranscriptSession old = dao.addSession(previousWeekStart.add(const Duration(hours: 9)));
    for (int i = 0; i < 4; i++) {
      dao.addPush(old.id, previousWeekStart.add(Duration(hours: 9, minutes: i)));
    }
    final TranscriptSession current = dao.addSession(today.add(const Duration(hours: 9)));
    dao.addPush(current.id, today.add(const Duration(hours: 9)));

    expect((await build().load()).trend, StatsTrend.down);

    // Thêm 3 Push cho tuần này nữa ⇒ 1.0 vs 1.0... (4 Push/1 buổi vs 4 Push/1 buổi) ⇒ không đổi.
    for (int i = 1; i < 4; i++) {
      dao.addPush(current.id, today.add(Duration(hours: 9, minutes: i)));
    }
    expect((await build().load()).trend, StatsTrend.flat);
  });

  test('REVIEW: DB lỗi ⇒ unavailable + note, KHÔNG hiện "0 buổi" như số thật', () async {
    dao.fail = true;

    final WeeklyStats stats = await build().load();

    expect(stats.available, isFalse);
    expect(stats.note, contains('lỗi đọc dữ liệu'));
    expect(stats.isEmpty, isFalse, reason: 'không được coi là "tuần này không có gì"');
    expect(stats.days, isEmpty);
  });

  test('xu hướng chỉ có 3 nhãn (tăng/giảm/không đổi) — không có nhãn "nên đổi cấp"', () {
    expect(
      StatsTrend.values.map((StatsTrend t) => t.label).toList(),
      <String>['tăng', 'giảm', 'không đổi'],
    );
  });
}
