import 'package:sqflite/sqflite.dart';

import '../../core/app_logger.dart';
import '../../transcript/transcript_segment.dart';
import 'app_database.dart';

/// Một phiên transcript (P1E).
///
/// Phiên = một lần "mở app và nói chuyện liên tục". Không có `endedAt`: phiên kết thúc khi có phiên
/// mới (xem `TranscriptStore.init`) — tránh phải thêm API `endSession()` mà chưa ai gọi.
class TranscriptSession {
  const TranscriptSession({
    required this.id,
    required this.startedAt,
    required this.lastActivityAt,
  });

  final int id;
  final DateTime startedAt;
  final DateTime lastActivityAt;

  @override
  String toString() =>
      'TranscriptSession(#$id, start=${startedAt.toIso8601String()}, '
      'last=${lastActivityAt.toIso8601String()})';
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
    // Một transaction: xoá 3 bảng phải hoặc cùng xong hoặc cùng không — nếu không, một lần crash
    // giữa chừng sẽ để lại dòng transcript mồ côi (dữ liệu riêng tư không ai xoá nữa).
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
        'transcript_sessions',
        where: 'id IN ($placeholders)',
        whereArgs: ids,
      );
      return ids.length;
    });
  }

  static TranscriptSession _sessionFromRow(Map<String, Object?> row) {
    return TranscriptSession(
      id: row['id']! as int,
      startedAt: DateTime.fromMillisecondsSinceEpoch(row['started_at_ms']! as int),
      lastActivityAt: DateTime.fromMillisecondsSinceEpoch(row['last_activity_at_ms']! as int),
    );
  }
}
