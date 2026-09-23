// Test P5.1 — Lịch sử phiên + lưu báo cáo Post-Review + retention có thể chỉnh.
//
// Đúng pattern đã chốt của repo: sqflite cần platform channel nên mọi DAO/store đều test qua bản giả
// trong bộ nhớ (`_FakeDao`, `_FakeConfigStore` — cùng cách `transcript_store_test.dart` đã làm từ
// P1E). Logic thật của SQL nằm ở `SqliteTranscriptDao` — phần schema/migration được khoá bằng test
// phân tích văn bản (nhìn `app_database.dart` như dữ liệu) vì không chạy được SQLite thật ở unit test.
//
// Điều cần khoá (theo DoD prompt P5.1):
// - resolver: chưa cấu hình ⇒ 7 ngày (KHÔNG đổi mặc định); giá trị hỏng/≤0 ⇒ fallback, KHÔNG ném.
// - cleanup: dùng đúng hạn đã cấu hình, phủ CẢ báo cáo (không cho báo cáo sống lâu hơn transcript).
// - HistoryScreen: phiên có báo cáo mở được chi tiết đúng 3 mục; phiên không có báo cáo thì KHÔNG
//   mở màn hình trống.
// - PostReviewService đã được test ở `post_review_test.dart` (nhóm P5.1) — không lặp lại ở đây.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';
import 'package:ai_assistant_phone/services/storage/retention_config.dart';
import 'package:ai_assistant_phone/services/storage/transcript_dao.dart';
import 'package:ai_assistant_phone/transcript/transcript_segment.dart';
import 'package:ai_assistant_phone/ui/history_screen.dart';

/// Đồng hồ giả — mọi mốc thời gian trong test đi qua đây.
class _MutableClock {
  _MutableClock(this.value);

  DateTime value;

  DateTime call() => value;
}

/// DAO giả trong bộ nhớ — đủ 5 nhóm dữ liệu: phiên/segment/push (P1E) + báo cáo (P5.1).
class _FakeDao implements TranscriptDao {
  final List<TranscriptSession> sessions = <TranscriptSession>[];
  final Map<int, List<TranscriptSegment>> segments = <int, List<TranscriptSegment>>{};
  final Map<int, List<DateTime>> pushes = <int, List<DateTime>>{};
  final Map<int, PostReviewReportRow> reports = <int, PostReviewReportRow>{};

  /// Mốc cutoff của lần `deleteOlderThan` gần nhất — để test khẳng định đúng hạn đã cấu hình.
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
  Future<PostReviewReportRow?> reportForSession(int sessionId) =>
      Future<PostReviewReportRow?>.value(reports[sessionId]);

  @override
  Future<Set<int>> sessionIdsWithReport() => Future<Set<int>>.value(reports.keys.toSet());

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
      // Cùng cutoff phải xoá cả báo cáo — không cho báo cáo sống lâu hơn transcript gốc.
      reports.remove(session.id);
    }
    return old.length;
  }
}

class _FakeConfigStore implements ConfigStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

PostReviewReportRow _row(int sessionId, DateTime at) => PostReviewReportRow(
      sessionId: sessionId,
      generatedAt: at,
      good: 'g-$sessionId',
      missed: 'm-$sessionId',
      exercise: 'e-$sessionId',
      segmentCount: 2,
      truncated: false,
    );

void main() {
  // `_MutableClock` dùng cho cleanup; HistoryScreen không cần đồng hồ nên khai báo ở đây.
  late _MutableClock clock;
  late _FakeDao dao;
  late _FakeConfigStore config;

  final DateTime base = DateTime(2026, 9, 23, 10, 0);

  setUp(() {
    clock = _MutableClock(base);
    dao = _FakeDao();
    config = _FakeConfigStore();
  });

  group('RetentionConfigResolver (P5.1 — không đổi mặc định)', () {
    test('chưa từng cấu hình ⇒ đúng mặc định 7 ngày', () async {
      final Duration retention = await RetentionConfigResolver.resolve(config);
      expect(retention, StorageConfig.transcriptRetention);
      expect(retention.inDays, 7);
    });

    test('lưu 3 ngày ⇒ đọc lại đúng 3 ngày', () async {
      await RetentionConfigResolver.save(config, 3);
      expect((await RetentionConfigResolver.resolve(config)).inDays, 3);
    });

    test('giá trị không parse được ⇒ fallback 7 ngày, KHÔNG ném', () async {
      await config.write(StorageConfig.retentionDaysKey, 'abc');
      expect((await RetentionConfigResolver.resolve(config)).inDays, 7);
    });

    test('giá trị 0 hoặc âm ⇒ fallback 7 ngày, KHÔNG ném', () async {
      await config.write(StorageConfig.retentionDaysKey, '0');
      expect((await RetentionConfigResolver.resolve(config)).inDays, 7);
      await config.write(StorageConfig.retentionDaysKey, '-5');
      expect((await RetentionConfigResolver.resolve(config)).inDays, 7);
    });

    test('khoá cấu hình đúng như prompt yêu cầu', () {
      expect(StorageConfig.retentionDaysKey, 'storage.retention_days');
    });

    test('reset ⇒ quay về mặc định', () async {
      await RetentionConfigResolver.save(config, 30);
      await RetentionConfigResolver.reset(config);
      expect((await RetentionConfigResolver.resolve(config)).inDays, 7);
    });
  });

  group('RetentionCleanup — xoá theo hạn tuỳ chỉnh (P5.1)', () {
    Future<void> seedOldAndNew() async {
      // Phiên cũ 8 ngày (vượt cả hạn dài nhất) + phiên gần.
      final TranscriptSession old =
          await dao.createSession(base.subtract(const Duration(days: 8)));
      await dao.touchSession(old.id, base.subtract(const Duration(days: 8)));
      await dao.saveReport(old.id, _row(old.id, base.subtract(const Duration(days: 8))));
      final TranscriptSession recent =
          await dao.createSession(base.subtract(const Duration(minutes: 2)));
      await dao.touchSession(recent.id, base.subtract(const Duration(minutes: 2)));
      await dao.saveReport(recent.id, _row(recent.id, base.subtract(const Duration(minutes: 2))));
    }

    test('cleanup 3 ngày ⇒ phiên 4-7 ngày tuổi phải bị xoá (không đợi mở app lại)', () async {
      await seedOldAndNew();
      // Thêm phiên 5 ngày tuổi: bị xoá ở hạn 3 ngày nhưng GIỮ ở hạn 7 ngày.
      final TranscriptSession mid =
          await dao.createSession(base.subtract(const Duration(days: 5)));
      await dao.touchSession(mid.id, base.subtract(const Duration(days: 5)));
      await dao.saveReport(mid.id, _row(mid.id, base.subtract(const Duration(days: 5))));

      await RetentionConfigResolver.save(config, 3);
      final int? removed = await RetentionCleanup.runNow(
        configStore: config,
        dao: dao,
        now: clock.call,
      );

      expect(removed, 2, reason: 'phiên 8 ngày + 5 ngày tuổi phải bị xoá ngay');
      expect(dao.lastCutoff, base.subtract(const Duration(days: 3)));
      // Chỉ còn phiên gần (id 2 — seed tạo old=1, recent=2; mid=5 ngày được tạo sau = id 3).
      expect(dao.sessions.map((TranscriptSession s) => s.id), <int>[2]);
      // Báo cáo của phiên bị xoá phải đi theo — không sống lâu hơn transcript.
      expect(dao.reports.containsKey(1), isFalse);
      expect(dao.reports.containsKey(3), isFalse);
      expect(dao.reports.containsKey(2), isTrue);
    });

    test('chưa cấu hình gì ⇒ cleanup dùng đúng 7 ngày (hành vi y hệt trước P5.1)', () async {
      await seedOldAndNew();
      final int? removed = await RetentionCleanup.runNow(
        configStore: config,
        dao: dao,
        now: clock.call,
      );
      expect(removed, 1, reason: 'chỉ phiên 8 ngày tuổi vượt hạn 7 ngày');
      expect(dao.lastCutoff, base.subtract(const Duration(days: 7)));
      expect(dao.reports.containsKey(2), isTrue);
    });

    test('lỗi DB ⇒ trả null, KHÔNG ném (cleanup là việc nền)', () async {
      final int? removed = await RetentionCleanup.runNow(
        configStore: config,
        dao: _ThrowingDao(),
      );
      expect(removed, isNull);
    });
  });

  group('TranscriptDao.allSessions / reportForSession / saveReport (bản giả, hợp đồng)', () {
    test('allSessions sắp xếp MỚI NHẤT TRƯỚC', () async {
      final TranscriptSession a = await dao.createSession(base.subtract(const Duration(hours: 3)));
      final TranscriptSession b = await dao.createSession(base);
      final List<TranscriptSession> all = await dao.allSessions();
      expect(all.map((TranscriptSession s) => s.id).toList(), <int>[b.id, a.id]);
    });

    test('saveReport rồi reportForSession đọc lại đủ 7 trường', () async {
      await dao.createSession(base);
      final DateTime generated = base.add(const Duration(minutes: 30));
      await dao.saveReport(1, _row(1, generated));

      final PostReviewReportRow? loaded = await dao.reportForSession(1);
      expect(loaded, isNotNull);
      expect(loaded!.sessionId, 1);
      expect(loaded.generatedAt, generated);
      expect(loaded.good, 'g-1');
      expect(loaded.missed, 'm-1');
      expect(loaded.exercise, 'e-1');
      expect(loaded.segmentCount, 2);
      expect(loaded.truncated, isFalse);
    });

    test('saveReport lần 2 cho cùng phiên ⇒ GHI ĐÈ, đọc lại ra bản MỚI', () async {
      await dao.createSession(base);
      await dao.saveReport(1, _row(1, base));
      final DateTime newer = base.add(const Duration(minutes: 30));
      await dao.saveReport(
        1,
        PostReviewReportRow(
          sessionId: 1,
          generatedAt: newer,
          good: 'good-mới',
          missed: 'missed-mới',
          exercise: 'exercise-mới',
          segmentCount: 5,
          truncated: true,
        ),
      );

      final PostReviewReportRow? loaded = await dao.reportForSession(1);
      expect(loaded, isNotNull);
      expect(loaded!.good, 'good-mới');
      expect(loaded.generatedAt, newer);
      expect(loaded.segmentCount, 5);
      expect(loaded.truncated, isTrue);
    });

    test('sessionIdsWithReport: 1 query trả đúng tập ID của các phiên có báo cáo', () async {
      // 3 phiên: 1 và 3 có báo cáo, 2 không.
      await dao.createSession(base);
      await dao.createSession(base.subtract(const Duration(hours: 1)));
      await dao.createSession(base.subtract(const Duration(hours: 2)));
      await dao.saveReport(1, _row(1, base));
      await dao.saveReport(3, _row(3, base));

      expect(await dao.sessionIdsWithReport(), <int>{1, 3});
    });

    test('sessionIdsWithReport: bảng trống ⇒ tập rỗng (không crash)', () async {
      expect(await dao.sessionIdsWithReport(), isEmpty);
    });

    test('schema/migration v3: đúng nhánh mới, không đụng nhánh cũ', () {
      // Đọc NGUỒN THẬT của `app_database.dart` — test này khoá ràng buộc cứng của prompt P5.1:
      // nhánh `oldVersion < 2` không được sửa, chỉ được thêm nhánh mới.
      final String source =
          File('lib/services/storage/app_database.dart').readAsStringSync();
      // databaseVersion phải ≥ 3 (P5.1 đưa lên 3; P5.2 đưa lên 4 — xem test P5.2 khoá đúng mốc 4).
      // Khẳng định ở đây chỉ nhằm bảo đảm P5.1 không bị hạ version trở lại.
      expect(StorageConfig.databaseVersion, greaterThanOrEqualTo(3));
      // Nhánh v2->v3 TỒN TẠI và gọi đúng hàm tạo schema báo cáo.
      expect(source.contains('oldVersion < 3'), isTrue);
      expect(source.contains('_createPostReviewSchema(db)'), isTrue);
      // Nhánh v1->v2 cũ GIỮ NGUYÊN (ràng buộc cứng của prompt: không sửa nhánh đã có).
      expect(source.contains('oldVersion < 2'), isTrue);
      expect(source.contains('oldVersion <= 2'), isFalse, reason: 'nhánh cũ không được đổi nghĩa');
      // Bảng mới có đủ 8 cột theo prompt.
      expect(source.contains("'CREATE TABLE post_review_reports ('"), isTrue);
      for (final String column in <String>[
        'session_id INTEGER NOT NULL',
        'generated_at_ms INTEGER NOT NULL',
        'good TEXT NOT NULL',
        'missed TEXT NOT NULL',
        'exercise TEXT NOT NULL',
        'segment_count INTEGER NOT NULL',
        'truncated INTEGER NOT NULL',
      ]) {
        expect(source.contains(column), isTrue, reason: 'thiếu cột $column');
      }
      expect(source.contains('idx_post_review_reports_session'), isTrue);
      // deleteOlderThan (trong `transcript_dao.dart`, KHÔNG phải file ở trên) phải xoá cả bảng
      // báo cáo — cùng transaction với 3 bảng transcript.
      final String daoSource =
          File('lib/services/storage/transcript_dao.dart').readAsStringSync();
      final int deleteStart = daoSource.indexOf('Future<int> deleteOlderThan(DateTime cutoff) async');
      expect(deleteStart, greaterThan(0), reason: 'phải tìm được phần THỰC THI của deleteOlderThan');
      final int methodEnd =
          daoSource.indexOf('Future<List<TranscriptSession>> allSessions({int limit = 100}) async', deleteStart);
      expect(methodEnd, greaterThan(deleteStart), reason: 'cần tìm được ranh giới cuối của deleteOlderThan');
      final String deleteMethod = daoSource.substring(deleteStart, methodEnd);
      expect(deleteMethod.contains("'post_review_reports'"), isTrue,
          reason: 'deleteOlderThan phải xoá cả post_review_reports');
    });
  });

  group('HistoryScreen (P5.1)', () {
    Future<void> pumpHistory(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(home: HistoryScreen(dao: dao)));
      await tester.pump();
    }

    testWidgets('có báo cáo ⇒ hiện dòng "có nhận xét", bấm mở đúng 3 mục đã lưu',
        (WidgetTester tester) async {
      final TranscriptSession session = await dao.createSession(base);
      await dao.saveReport(session.id, _row(session.id, base));

      await pumpHistory(tester);

      expect(find.text('Lịch sử phiên'), findsOneWidget);
      expect(find.text('có nhận xét cuối buổi — bấm để xem lại'), findsOneWidget);

      await tester.tap(find.text('có nhận xét cuối buổi — bấm để xem lại'));
      await tester.pumpAndSettle();

      // Màn hình chi tiết: đúng 3 mục với nội dung đã lưu.
      expect(find.text('Điều đã làm tốt'), findsOneWidget);
      expect(find.text('Cơ hội bị bỏ lỡ'), findsOneWidget);
      expect(find.text('Bài tập cho lần sau'), findsOneWidget);
      expect(find.text('g-${session.id}'), findsOneWidget);
      expect(find.text('m-${session.id}'), findsOneWidget);
      expect(find.text('e-${session.id}'), findsOneWidget);
    });

    testWidgets('không có báo cáo ⇒ đánh dấu rõ, bấm KHÔNG mở màn hình trống',
        (WidgetTester tester) async {
      await dao.createSession(base);

      await pumpHistory(tester);

      expect(find.text('chưa có báo cáo'), findsOneWidget);
      await tester.tap(find.text('chưa có báo cáo'));
      await tester.pump();

      // Không mở màn hình chi tiết — chỉ SnackBar báo rõ.
      expect(find.text('Điều đã làm tốt'), findsNothing);
      expect(find.text('Phiên này chưa có báo cáo.'), findsOneWidget);
    });

    testWidgets('DB trống ⇒ thông báo "Chưa có buổi nào", không crash',
        (WidgetTester tester) async {
      await pumpHistory(tester);
      expect(find.text('Chưa có buổi nào được ghi lại.'), findsOneWidget);
    });

    testWidgets('DB lỗi ⇒ hiện lỗi, không crash (màn hình không được làm sập app)',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(home: HistoryScreen(dao: _ThrowingDao())),
      );
      await tester.pump();
      expect(find.textContaining('không đọc được lịch sử'), findsOneWidget);
    });
  });
}

/// DAO ném lỗi mọi truy vấn — dùng để test nhánh lỗi của cleanup + HistoryScreen.
class _ThrowingDao implements TranscriptDao {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('DB giả lập hỏng');
}
