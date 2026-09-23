// Test P5.2 — Đặt tên phiên (mặc định theo timestamp, sửa được sau).
//
// Cùng pattern đã chốt của repo: sqflite cần platform channel nên DAO được test qua bản giả trong bộ
// nhớ; phần schema/migration được khoá bằng test đọc NGUỒN THẬT của `app_database.dart` (nhìn file
// như dữ liệu) vì không chạy được SQLite thật ở unit test.
//
// Điều cần khoá (theo DoD prompt P5.2):
// - Tên hiển thị: `title` đã đặt được ưu tiên; `null`/rỗng/toàn khoảng trắng ⇒ tên mặc định theo
//   `started_at` (đúng định dạng "Buổi dd/MM/yyyy HH:mm").
// - Đổi tên: rỗng ⇒ lưu `null` (quay về mặc định), KHÔNG báo lỗi; quá dài ⇒ cắt còn 60, KHÔNG ném.
// - Migration v4: thêm cột `title`, nhánh cũ giữ nguyên, và cột `title` **không** được nhét vào
//   `CREATE TABLE transcript_sessions` (nếu nhét vào, đường nâng cấp từ DB v1 sẽ chạy ALTER lên bảng
//   vừa tạo đã có cột ⇒ "duplicate column name").
// - Màn hình chi tiết báo cáo hiện TÊN PHIÊN ở tiêu đề.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/services/storage/transcript_dao.dart';
import 'package:ai_assistant_phone/transcript/session_display_name.dart';
import 'package:ai_assistant_phone/ui/history_screen.dart';

/// DAO giả tối thiểu cho HistoryScreen (P5.2): chỉ 3 method mà màn hình dùng; phần còn lại của
/// interface không cần thiết cho test này.
class _FakeDao implements TranscriptDao {
  _FakeDao(this.sessions, this.reports);

  final List<TranscriptSession> sessions;
  final Map<int, PostReviewReportRow> reports;

  /// Mọi lời gọi `renameSession` — để khẳng định ĐÚNG giá trị đã chuẩn hoá được gửi xuống.
  final List<(int, String?)> renameCalls = <(int, String?)>[];

  @override
  Future<List<TranscriptSession>> allSessions({int limit = 100}) async =>
      List<TranscriptSession>.of(sessions);

  @override
  Future<PostReviewReportRow?> reportForSession(int sessionId) async => reports[sessionId];

  @override
  Future<Set<int>> sessionIdsWithReport() async => reports.keys.toSet();

  @override
  Future<void> renameSession(int sessionId, String? title) async {
    renameCalls.add((sessionId, title));
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
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeDao không hỗ trợ ${invocation.memberName}');
}

TranscriptSession _session(int id, DateTime startedAt, {String? title}) => TranscriptSession(
      id: id,
      startedAt: startedAt,
      lastActivityAt: startedAt,
      title: title,
    );

PostReviewReportRow _row(int sessionId) => PostReviewReportRow(
      sessionId: sessionId,
      generatedAt: DateTime(2026, 9, 23, 15, 0),
      good: 'g',
      missed: 'm',
      exercise: 'e',
      segmentCount: 2,
      truncated: false,
    );

void main() {
  final DateTime base = DateTime(2026, 9, 23, 14, 30);
  late _FakeDao dao;

  setUp(() {
    dao = _FakeDao(<TranscriptSession>[], <int, PostReviewReportRow>{});
  });

  group('SessionDisplayName.of — ưu tiên tên đã đặt, fallback timestamp', () {
    test('chưa đặt tên (title = null) ⇒ tên mặc định theo started_at', () {
      expect(
        SessionDisplayName.of(_session(1, base)),
        'Buổi 23/09/2026 14:30',
      );
    });

    test('đã đặt tên ⇒ dùng tên đó (đã trim hai đầu)', () {
      expect(
        SessionDisplayName.of(_session(1, base, title: '  Gặp anh Nam  ')),
        'Gặp anh Nam',
      );
    });

    test('title rỗng hoặc toàn khoảng trắng ⇒ quay về tên mặc định (không hiện dòng trống)', () {
      expect(SessionDisplayName.of(_session(1, base, title: '')), 'Buổi 23/09/2026 14:30');
      expect(SessionDisplayName.of(_session(1, base, title: '   ')), 'Buổi 23/09/2026 14:30');
    });

    test('định dạng tên mặc định: ngày/tháng/năm giờ:phút, đệm 0 cho số < 10', () {
      final DateTime morning = DateTime(2026, 9, 3, 9, 5);
      expect(SessionDisplayName.timestamp(morning), '03/09/2026 09:05');
      expect(SessionDisplayName.defaultFrom(morning), 'Buổi 03/09/2026 09:05');
    });
  });

  group('SessionDisplayName.normalize — rỗng ⇒ null, dài ⇒ cắt (không ném)', () {
    test('null ⇒ null', () {
      expect(SessionDisplayName.normalize(null), isNull);
    });

    test('rỗng / toàn khoảng trắng ⇒ null (xoá tên tự đặt, KHÔNG phải lỗi)', () {
      expect(SessionDisplayName.normalize(''), isNull);
      expect(SessionDisplayName.normalize('    '), isNull);
    });

    test('có nội dung ⇒ trim hai đầu', () {
      expect(SessionDisplayName.normalize('  Tên buổi  '), 'Tên buổi');
    });

    test('dài hơn 60 ký tự ⇒ cắt còn đúng 60, KHÔNG ném', () {
      final String long = 'a' * 200;
      final String? normalized = SessionDisplayName.normalize(long);
      expect(normalized, isNotNull);
      expect(normalized!.length, SessionDisplayName.maxLength);
      expect(normalized, 'a' * 60);
    });

    test('đúng 60 ký tự ⇒ giữ nguyên', () {
      final String exactly = 'b' * 60;
      expect(SessionDisplayName.normalize(exactly), exactly);
    });
  });

  group('Migration v4 — thêm cột title (đọc NGUỒN THẬT app_database.dart)', () {
    late String source;

    setUp(() {
      source = File('lib/services/storage/app_database.dart').readAsStringSync();
    });

    test('databaseVersion tăng đúng 1 bậc so với version thật lúc bắt đầu P5.2 (3 ⇒ 4)', () {
      // KHÔNG hard-code mù: P5.2 bắt đầu khi version thật = 3 (đọc từ code lúc bắt đầu phase).
      expect(StorageConfig.databaseVersion, 4);
    });

    test('có nhánh mới oldVersion < 4, thêm cột title bằng ALTER TABLE', () {
      expect(source.contains('oldVersion < 4'), isTrue);
      expect(source.contains('ALTER TABLE transcript_sessions ADD COLUMN title TEXT'), isTrue);
    });

    test('các nhánh migration cũ GIỮ NGUYÊN (không sửa, không đổi nghĩa)', () {
      expect(source.contains('oldVersion < 2'), isTrue);
      expect(source.contains('oldVersion < 3'), isTrue);
      expect(source.contains('oldVersion <= 2'), isFalse, reason: 'nhánh cũ không được đổi nghĩa');
      expect(source.contains('oldVersion <= 3'), isFalse, reason: 'nhánh cũ không được đổi nghĩa');
    });

    test('cột title KHÔNG nằm trong CREATE TABLE transcript_sessions (tránh duplicate column)', () {
      // Nếu `title` được nhét vào `_createTranscriptSchema`, đường nâng cấp từ DB v1 (nhánh `< 2`
      // tạo bảng → nhánh `< 4` ALTER) sẽ lỗi "duplicate column name" lúc mở DB.
      final int createStart = source.indexOf("'CREATE TABLE transcript_sessions ('");
      expect(createStart, greaterThan(0), reason: 'phải tìm được CREATE TABLE transcript_sessions');
      final int createEnd = source.indexOf(');', createStart);
      expect(createEnd, greaterThan(createStart));
      final String createBlock = source.substring(createStart, createEnd);
      expect(createBlock.contains('title'), isFalse,
          reason: 'cột title phải được thêm bằng ALTER, không nhét vào CREATE TABLE');

      // ALTER chỉ xuất hiện đúng MỘT lần ⇒ mọi đường (máy mới / v1 / v2 / v3) thêm cột đúng 1 lần.
      final int alterCount =
          'ALTER TABLE transcript_sessions ADD COLUMN title TEXT'.allMatches(source).length;
      expect(alterCount, 1, reason: 'ALTER phải nằm ở đúng một chỗ (helper dùng chung)');
    });

    test('renameSession có ở cả interface lẫn bản SQLite (nhận String? — null = xoá tên)', () {
      final String daoSource =
          File('lib/services/storage/transcript_dao.dart').readAsStringSync();
      final int declarations =
          'Future<void> renameSession(int sessionId, String? title)'.allMatches(daoSource).length;
      expect(declarations, 2,
          reason: 'một khai báo trong interface, một bản thực thi (đã bỏ @override nên đếm 2 chữ ký)');
      expect(daoSource.contains("'title': title"), isTrue,
          reason: 'bản SQLite phải ghi cột title (nhận null ⇒ lưu NULL)');
    });
  });

  group('HistoryScreen (P5.2) — hiện tên + đổi tên', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(home: HistoryScreen(dao: dao)));
      await tester.pumpAndSettle();
    }

    testWidgets('phiên chưa đặt tên ⇒ hiện tên mặc định theo thời gian',
        (WidgetTester tester) async {
      dao.sessions.add(_session(1, base));
      await pump(tester);
      expect(find.text('Buổi 23/09/2026 14:30'), findsOneWidget);
    });

    testWidgets('phiên đã đặt tên ⇒ hiện đúng tên đã đặt', (WidgetTester tester) async {
      dao.sessions.add(_session(1, base, title: 'Gặp chị Lan'));
      await pump(tester);
      expect(find.text('Gặp chị Lan'), findsOneWidget);
      expect(find.text('Buổi 23/09/2026 14:30'), findsNothing);
    });

    testWidgets('đổi tên ⇒ hiện NGAY tên mới, DAO nhận đúng giá trị đã trim',
        (WidgetTester tester) async {
      final TranscriptSession session = _session(7, base);
      dao.sessions.add(session);
      await pump(tester);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Đổi tên buổi'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), '  Họp nhóm dự án  ');
      await tester.tap(find.text('Lưu'));
      await tester.pumpAndSettle();

      expect(find.text('Họp nhóm dự án'), findsOneWidget);
      expect(dao.renameCalls, hasLength(1));
      expect(dao.renameCalls.single.$1, 7);
      expect(dao.renameCalls.single.$2, 'Họp nhóm dự án');
    });

    testWidgets('nhập rỗng ⇒ lưu null + quay về tên mặc định, KHÔNG lỗi',
        (WidgetTester tester) async {
      dao.sessions.add(_session(3, base, title: 'Tên cũ'));
      await pump(tester);
      expect(find.text('Tên cũ'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '   ');
      await tester.tap(find.text('Lưu'));
      await tester.pumpAndSettle();

      expect(dao.renameCalls.single.$2, isNull, reason: 'rỗng/toàn khoảng trắng ⇒ lưu NULL');
      expect(find.text('Buổi 23/09/2026 14:30'), findsOneWidget);
      expect(find.textContaining('Không đổi được tên'), findsNothing);
    });

    testWidgets('tên quá dài bị cắt còn 60 ký tự (không phá layout)', (WidgetTester tester) async {
      dao.sessions.add(_session(4, base));
      await pump(tester);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'x' * 80);
      await tester.tap(find.text('Lưu'));
      await tester.pumpAndSettle();

      final String? saved = dao.renameCalls.single.$2;
      expect(saved, isNotNull);
      expect(saved!.length, SessionDisplayName.maxLength);
    });

    testWidgets('hủy dialog ⇒ KHÔNG gọi đổi tên (không đổi gì)', (WidgetTester tester) async {
      dao.sessions.add(_session(5, base, title: 'Giữ nguyên'));
      await pump(tester);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Huỷ'));
      await tester.pumpAndSettle();

      expect(dao.renameCalls, isEmpty);
      expect(find.text('Giữ nguyên'), findsOneWidget);
    });

    testWidgets('màn hình chi tiết báo cáo hiện TÊN PHIÊN ở tiêu đề',
        (WidgetTester tester) async {
      final TranscriptSession session = _session(9, base, title: 'Phỏng vấn thử');
      await tester.pumpWidget(
        MaterialApp(
          home: ReportDetailScreen(session: session, row: _row(9)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('Phỏng vấn thử')),
        findsOneWidget,
      );
      // Vẫn hiện đủ 3 mục báo cáo đã lưu.
      expect(find.text('Điều đã làm tốt'), findsOneWidget);
      expect(find.text('Cơ hội bị bỏ lỡ'), findsOneWidget);
      expect(find.text('Bài tập cho lần sau'), findsOneWidget);
    });

    testWidgets('phiên cũ (title = null sau migration) vẫn hiện đúng tên mặc định',
        (WidgetTester tester) async {
      // Mô phỏng dữ liệu đọc từ DB v3 đã nâng lên v4: cột title = NULL.
      dao.sessions.addAll(<TranscriptSession>[
        _session(1, DateTime(2026, 9, 1, 8, 0)),
        _session(2, DateTime(2026, 9, 2, 18, 45)),
      ]);
      await pump(tester);
      expect(find.text('Buổi 01/09/2026 08:00'), findsOneWidget);
      expect(find.text('Buổi 02/09/2026 18:45'), findsOneWidget);
    });
  });
}
