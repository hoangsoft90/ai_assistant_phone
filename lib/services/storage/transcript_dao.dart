import 'package:sqflite/sqflite.dart';

import '../../core/app_logger.dart';
import '../../transcript/transcript_segment.dart';
import 'app_database.dart';

/// Một phiên transcript (P1E).
///
/// Phiên = một lần "mở app và nói chuyện liên tục". Không có `endedAt`: phiên kết thúc khi có phiên
/// mới (xem `TranscriptStore.init`) — tránh phải thêm API `endSession()` mà chưa ai gọi.
///
/// [title] (P5.2) là tên người dùng tự đặt, **`null` = chưa đặt** (không backfill cho phiên cũ).
/// Tên hiển thị luôn sinh qua `SessionDisplayName.of` — xem `lib/transcript/session_display_name.dart`.
class TranscriptSession {
  const TranscriptSession({
    required this.id,
    required this.startedAt,
    required this.lastActivityAt,
    this.title,
  });

  final int id;
  final DateTime startedAt;
  final DateTime lastActivityAt;

  /// Tên phiên do người dùng đặt (P5.2). `null` = chưa đặt tên ⇒ hiển thị tên mặc định theo
  /// [startedAt]. Không phải khoá chính/không dùng để tra cứu — chỉ để hiển thị.
  final String? title;

  @override
  String toString() =>
      'TranscriptSession(#$id, start=${startedAt.toIso8601String()}, '
      'last=${lastActivityAt.toIso8601String()}${title == null ? '' : ', title="$title"'})';
}

/// Một mốc Push đã ghi (P5: thống kê tuần — "số lần Push/buổi").
///
/// Trả kèm `sessionId` thay vì chỉ mốc thời gian vì caller cần **cả hai** phép đếm: Push theo buổi
/// (mẫu số là phiên) và Push theo ngày (xu hướng tuần). Trả dữ liệu thô rồi gộp trong Dart rẻ hơn và
/// ít sai hơn hai câu SQL gần giống nhau.
class TranscriptPush {
  const TranscriptPush({required this.sessionId, required this.at});

  final int sessionId;
  final DateTime at;
}

/// Một báo cáo Post-Review đã lưu (P5.1) — bản ghi thẳng từ bảng `post_review_reports`.
///
/// Tách khỏi `PostReviewReport` (model của `PostReviewService`) để tầng DAO không phụ thuộc tầng
/// coaching; UI/Service tự map sang model của mình khi cần.
class PostReviewReportRow {
  const PostReviewReportRow({
    required this.sessionId,
    required this.generatedAt,
    required this.good,
    required this.missed,
    required this.exercise,
    required this.segmentCount,
    required this.truncated,
  });

  final int sessionId;
  final DateTime generatedAt;
  final String good;
  final String missed;
  final String exercise;
  final int segmentCount;
  final bool truncated;

  @override
  String toString() =>
      'PostReviewReportRow(session#$sessionId, ${generatedAt.toIso8601String()}, '
      '$segmentCount dòng${truncated ? ', cắt' : ''})';
}

/// Truy cập dữ liệu transcript — **interface**, để `TranscriptStore` test được mà không cần SQLite
/// thật (`sqflite` cần platform channel; test chỉ cần một bản giả trong bộ nhớ). Cùng cách đã dùng
/// cho `ConfigStore` ở P1D.
abstract class TranscriptDao {
  /// Phiên có hoạt động gần nhất, hoặc `null` nếu DB chưa có phiên nào.
  Future<TranscriptSession?> latestSession();

  /// Tạo phiên mới bắt đầu ở [startedAt].
  Future<TranscriptSession> createSession(DateTime startedAt);

  /// Cập nhật mốc hoạt động cuối của phiên (dùng cho quy tắc khôi phục + hạn 7 ngày).
  Future<void> touchSession(int sessionId, DateTime at);

  Future<void> appendSegment(int sessionId, TranscriptSegment segment);

  /// Các dòng của phiên có `timestamp >= since`, **sắp xếp tăng dần theo thời gian**.
  Future<List<TranscriptSegment>> segmentsSince(int sessionId, DateTime since);

  Future<void> recordPush(int sessionId, DateTime at);

  /// Mốc Push gần nhất của phiên, `null` nếu chưa bấm lần nào.
  Future<DateTime?> latestPush(int sessionId);

  /// Xoá **mọi** phiên (kèm dòng transcript + mốc Push của chúng) có hoạt động cuối trước
  /// [cutoff]. Trả về số phiên đã xoá.
  Future<int> deleteOlderThan(DateTime cutoff);

  /// Các phiên có **hoạt động cuối** kể từ [since] (P5: thống kê tuần).
  ///
  /// Dùng `last_activity_at_ms` chứ không phải `started_at_ms`: một buổi bắt đầu 23:50 và kéo sang
  /// 00:10 vẫn phải được tính cho ngày nó *diễn ra phần lớn*, và đây cũng là cột mà hạn 7 ngày dùng
  /// ⇒ hai chỗ nhìn cùng một định nghĩa "phiên còn sống".
  Future<List<TranscriptSession>> sessionsSince(DateTime since);

  /// Mọi mốc Push kể từ [since], sắp xếp tăng dần theo thời gian.
  Future<List<TranscriptPush>> pushesSince(DateTime since);

  // --- P5.1: Lịch sử phiên + lưu báo cáo Post-Review ---

  /// Mọi phiên còn trong DB, **mới nhất trước** (P5.1 — màn hình Lịch sử).
  ///
  /// Dùng `allSessions` thay vì tái dùng `sessionsSince(mốc rất xa)`: một mốc "rất xa" cứng sẽ hỏng
  /// khi có phiên bắt đầu trước đó (DateTime epoch 0 + UTC offset...), và hàm này truyền tải đúng ý
  /// "lấy hết, mới nhất trước" cho người đọc.
  Future<List<TranscriptSession>> allSessions({int limit = 100});

  /// Báo cáo Post-Review đã lưu của phiên [sessionId], `null` nếu chưa có.
  Future<PostReviewReportRow?> reportForSession(int sessionId);

  /// Tập ID của các phiên **có** báo cáo Post-Review đã lưu (P5.1) — **một query duy nhất**.
  ///
  /// Vì sao có hàm này: màn hình Lịch sử cần biết phiên nào có báo cáo để vẽ chú thích; cách
  /// "lặp `reportForSession` cho từng phiên" là N+1 query (100 phiên ⇒ 101 query). SELECT
  /// `DISTINCT session_id` của cả bảng báo cáo là 1 query — bảng này nhỏ (tối đa 1 dòng/phiên,
  /// tự bị xoá theo retention), nên DISTINCT trên client/từ SQL như nhau; dùng SQL cho gọn.
  Future<Set<int>> sessionIdsWithReport();

  /// Lưu báo cáo Post-Review dùng được cho phiên [sessionId]. Ghi **đè** báo cáo cũ nếu phiên đã có
  /// (người dùng chạy Post-Review lại — chỉ bản mới nhất có ý nghĩa xem lại).
  Future<void> saveReport(int sessionId, PostReviewReportRow report);

  // --- P5.2: tên phiên ---

  /// Đổi tên hiển thị của phiên [sessionId] (P5.2). [title] **`null` = xoá tên tự đặt** ⇒ phiên quay
  /// về tên mặc định sinh từ `started_at_ms`.
  ///
  /// Tầng DAO lưu nguyên giá trị nhận được (không validate/cắt bớt — việc chuẩn hoá rỗng→`null` và
  /// giới hạn độ dài là của tầng gọi, qua `SessionDisplayName.normalize`).
  Future<void> renameSession(int sessionId, String? title);
}

/// Bản thật: SQLite (`sqflite`) — kho đã chọn từ P0.5 và đã được mở ở bootstrap.
///
/// Lưu ý quyền riêng tư (P1E task 7): `sqflite` **không** hỗ trợ mã hoá DB (phải đổi sang
/// `sqflite_sqlcipher` — package thay thế trực tiếp). Phase này cố ý KHÔNG thêm package đó
/// (prompt P1E cho phép: "KHÔNG mã hoá phức tạp ở phase này nếu chưa cần"), nên dữ liệu nằm trong
/// **thư mục riêng của app** (Android sandbox — app khác không đọc được) và bị xoá sau 7 ngày.
/// Xem `lib/transcript/README.md` để biết điều kiện chuyển sang mã hoá.
class SqliteTranscriptDao implements TranscriptDao {
  const SqliteTranscriptDao();

  static const AppLogger _log = AppLogger('TranscriptDao');

  @override
  Future<TranscriptSession?> latestSession() async {
    final Database db = await AppDatabase.instance();
    final List<Map<String, Object?>> rows = await db.query(
      'transcript_sessions',
      orderBy: 'last_activity_at_ms DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return _sessionFromRow(rows.first);
  }

  @override
  Future<TranscriptSession> createSession(DateTime startedAt) async {
    final Database db = await AppDatabase.instance();
    final int ms = startedAt.millisecondsSinceEpoch;
    final int id = await db.insert('transcript_sessions', <String, Object?>{
      'started_at_ms': ms,
      'last_activity_at_ms': ms,
    });
    _log.info('tạo phiên transcript #$id');
    return TranscriptSession(id: id, startedAt: startedAt, lastActivityAt: startedAt);
  }

  @override
  Future<void> touchSession(int sessionId, DateTime at) async {
    final Database db = await AppDatabase.instance();
    await db.update(
      'transcript_sessions',
      <String, Object?>{'last_activity_at_ms': at.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: <Object?>[sessionId],
    );
  }

  @override
  Future<void> appendSegment(int sessionId, TranscriptSegment segment) async {
    final Database db = await AppDatabase.instance();
    await db.insert('transcript_segments', <String, Object?>{
      'session_id': sessionId,
      'timestamp_ms': segment.timestamp.millisecondsSinceEpoch,
      'text': segment.text,
    });
  }

  @override
  Future<List<TranscriptSegment>> segmentsSince(int sessionId, DateTime since) async {
    final Database db = await AppDatabase.instance();
    final List<Map<String, Object?>> rows = await db.query(
      'transcript_segments',
      columns: <String>['timestamp_ms', 'text'],
      where: 'session_id = ? AND timestamp_ms >= ?',
      whereArgs: <Object?>[sessionId, since.millisecondsSinceEpoch],
      // Sắp xếp thêm theo `id` để hai dòng cùng mốc ms vẫn giữ đúng thứ tự đã ghi.
      orderBy: 'timestamp_ms ASC, id ASC',
    );
    return rows
        .map(
          (Map<String, Object?> row) => TranscriptSegment(
            text: row['text']! as String,
            timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp_ms']! as int),
          ),
        )
        .toList();
  }

  @override
  Future<void> recordPush(int sessionId, DateTime at) async {
    final Database db = await AppDatabase.instance();
    await db.insert('transcript_pushes', <String, Object?>{
      'session_id': sessionId,
      'timestamp_ms': at.millisecondsSinceEpoch,
    });
  }

  @override
  Future<DateTime?> latestPush(int sessionId) async {
    final Database db = await AppDatabase.instance();
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT MAX(timestamp_ms) AS latest FROM transcript_pushes WHERE session_id = ?',
      <Object?>[sessionId],
    );
    final Object? latest = rows.isEmpty ? null : rows.first['latest'];
    if (latest is! int) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(latest);
  }

  @override
  Future<int> deleteOlderThan(DateTime cutoff) async {
    final Database db = await AppDatabase.instance();
    // Một transaction: xoá 4 bảng (P5.1: thêm `post_review_reports`) phải hoặc cùng xong hoặc cùng
    // không — nếu không, một lần crash giữa chừng sẽ để lại dòng transcript mồ côi (dữ liệu riêng
    // tư không ai xoá nữa). Báo cáo phải bị xoá CÙNG transcript gốc mà nó dựa vào — không cho tình
    // huống báo cáo sống lâu hơn transcript (prompt P5.1 mục 4).
    return db.transaction<int>((Transaction txn) async {
      final List<Map<String, Object?>> rows = await txn.query(
        'transcript_sessions',
        columns: <String>['id'],
        where: 'last_activity_at_ms < ?',
        whereArgs: <Object?>[cutoff.millisecondsSinceEpoch],
      );
      if (rows.isEmpty) {
        return 0;
      }
      final List<Object?> ids = rows.map((Map<String, Object?> r) => r['id']).toList();
      final String placeholders = List<String>.filled(ids.length, '?').join(', ');
      await txn.delete(
        'transcript_segments',
        where: 'session_id IN ($placeholders)',
        whereArgs: ids,
      );
      await txn.delete(
        'transcript_pushes',
        where: 'session_id IN ($placeholders)',
        whereArgs: ids,
      );
      await txn.delete(
        'post_review_reports',
        where: 'session_id IN ($placeholders)',
        whereArgs: ids,
      );
      await txn.delete(
        'transcript_sessions',
        where: 'id IN ($placeholders)',
        whereArgs: ids,
      );
      return ids.length;
    });
  }

  @override
  Future<List<TranscriptSession>> sessionsSince(DateTime since) async {
    final Database db = await AppDatabase.instance();
    final List<Map<String, Object?>> rows = await db.query(
      'transcript_sessions',
      where: 'last_activity_at_ms >= ?',
      whereArgs: <Object?>[since.millisecondsSinceEpoch],
      orderBy: 'last_activity_at_ms ASC',
    );
    return rows.map(_sessionFromRow).toList();
  }

  @override
  Future<List<TranscriptPush>> pushesSince(DateTime since) async {
    final Database db = await AppDatabase.instance();
    final List<Map<String, Object?>> rows = await db.query(
      'transcript_pushes',
      columns: <String>['session_id', 'timestamp_ms'],
      where: 'timestamp_ms >= ?',
      whereArgs: <Object?>[since.millisecondsSinceEpoch],
      orderBy: 'timestamp_ms ASC',
    );
    return rows
        .map(
          (Map<String, Object?> row) => TranscriptPush(
            sessionId: row['session_id']! as int,
            at: DateTime.fromMillisecondsSinceEpoch(row['timestamp_ms']! as int),
          ),
        )
        .toList();
  }

  @override
  Future<List<TranscriptSession>> allSessions({int limit = 100}) async {
    final Database db = await AppDatabase.instance();
    final List<Map<String, Object?>> rows = await db.query(
      'transcript_sessions',
      orderBy: 'last_activity_at_ms DESC',
      limit: limit,
    );
    return rows.map(_sessionFromRow).toList();
  }

  @override
  Future<PostReviewReportRow?> reportForSession(int sessionId) async {
    final Database db = await AppDatabase.instance();
    final List<Map<String, Object?>> rows = await db.query(
      'post_review_reports',
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
      // Nếu có nhiều hơn 1 (không xảy ra vì saveReport ghi đè) — lấy bản mới nhất.
      orderBy: 'generated_at_ms DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return _reportFromRow(rows.first);
  }

  @override
  Future<Set<int>> sessionIdsWithReport() async {
    final Database db = await AppDatabase.instance();
    final List<Map<String, Object?>> rows = await db.query(
      'post_review_reports',
      columns: <String>['DISTINCT session_id'],
    );
    return rows.map((Map<String, Object?> row) => row['session_id']! as int).toSet();
  }

  @override
  Future<void> saveReport(int sessionId, PostReviewReportRow report) async {
    final Database db = await AppDatabase.instance();
    // Không khai báo UNIQUE ở bảng nên "đè" làm tường minh: xoá bản cũ của phiên rồi ghi bản mới,
    // trong MỘT transaction — không bao giờ có 2 báo cáo cho cùng 1 phiên.
    await db.transaction<void>((Transaction txn) async {
      await txn.delete(
        'post_review_reports',
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
      );
      await txn.insert('post_review_reports', <String, Object?>{
        'session_id': sessionId,
        'generated_at_ms': report.generatedAt.millisecondsSinceEpoch,
        'good': report.good,
        'missed': report.missed,
        'exercise': report.exercise,
        'segment_count': report.segmentCount,
        'truncated': report.truncated ? 1 : 0,
      });
    });
    _log.info('đã lưu báo cáo Post-Review cho phiên #$sessionId');
  }

  static PostReviewReportRow _reportFromRow(Map<String, Object?> row) {
    return PostReviewReportRow(
      sessionId: row['session_id']! as int,
      generatedAt: DateTime.fromMillisecondsSinceEpoch(row['generated_at_ms']! as int),
      good: row['good']! as String,
      missed: row['missed']! as String,
      exercise: row['exercise']! as String,
      segmentCount: row['segment_count']! as int,
      truncated: (row['truncated']! as int) != 0,
    );
  }

  @override
  Future<void> renameSession(int sessionId, String? title) async {
    final Database db = await AppDatabase.instance();
    final int changed = await db.update(
      'transcript_sessions',
      <String, Object?>{'title': title},
      where: 'id = ?',
      whereArgs: <Object?>[sessionId],
    );
    // Không có dòng nào ⇒ phiên đã bị dọn theo hạn retention trong lúc màn hình Lịch sử còn mở.
    // Không phải lỗi (người dùng đang xem danh sách cũ) — chỉ log để không im lặng.
    if (changed == 0) {
      _log.warn('không đổi được tên: phiên #$sessionId không còn trong DB');
      return;
    }
    _log.info('đổi tên phiên #$sessionId${title == null ? ' (xoá tên, về mặc định)' : ''}');
  }

  static TranscriptSession _sessionFromRow(Map<String, Object?> row) {
    return TranscriptSession(
      id: row['id']! as int,
      startedAt: DateTime.fromMillisecondsSinceEpoch(row['started_at_ms']! as int),
      lastActivityAt: DateTime.fromMillisecondsSinceEpoch(row['last_activity_at_ms']! as int),
      // Cột `title` chỉ có từ v4; các truy vấn cũ vẫn trả map thiếu khoá này.
      title: row['title'] as String?,
    );
  }
}
