import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../core/app_logger.dart';
import '../../core/constants.dart';

/// Khung lưu trữ SQLite của dự án (P0.5 task 6).
///
/// Chọn SQLite (không dùng Hive) vì transcript store ở P1E cần:
/// truy vấn theo khung thời gian (lấy N phút gần nhất cho Suggestion Engine), đánh index theo
/// timestamp, và dump toàn bộ theo phiên cho Post-Review (P5).
///
/// P0.5 CHỈ mở DB và tạo bảng `meta` — đủ để chứng minh đường mở/migrate DB chạy được trên máy
/// thật. Schema transcript cố ý KHÔNG định nghĩa ở đây: đó là việc của P1E.
abstract final class AppDatabase {
  static const AppLogger _log = AppLogger('AppDatabase');

  static Database? _database;

  static Future<Database> instance() async {
    final Database? cached = _database;
    if (cached != null && cached.isOpen) {
      return cached;
    }

    final String path = p.join(await getDatabasesPath(), StorageConfig.databaseName);
    final Database db = await openDatabase(
      path,
      version: StorageConfig.databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    _database = db;
    _log.info('đã mở SQLite v${await db.getVersion()} tại $path');
    return db;
  }

  static Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute(
      'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await db.insert('meta', <String, Object?>{
      'key': 'created_at',
      'value': DateTime.now().toIso8601String(),
    });
    await _createTranscriptSchema(db);
    _log.info('đã tạo schema v$version (bảng meta + transcript)');
  }

  /// Migration từng bước. KHÔNG được xoá/tạo lại DB của người dùng: máy đã cài bản P0.5 sẽ có DB
  /// v1 trên đĩa, thiếu nhánh ở đây là crash lúc mở DB.
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 -> v2 (P1E): thêm 3 bảng transcript. Bảng `meta` giữ nguyên, dữ liệu cũ không bị đụng.
      await _createTranscriptSchema(db);
      _log.info('migration v1 -> v2: đã tạo bảng transcript');
    }
  }

  /// Schema transcript (P1E). Dùng chung cho `onCreate` (máy mới) và `onUpgrade` (máy đã có v1)
  /// để hai đường không bao giờ lệch nhau.
  ///
  /// Ghi chú thiết kế:
  /// - Mốc thời gian lưu bằng **epoch milliseconds (INTEGER)**, không dùng chuỗi ISO: so sánh
  ///   khoảng (`WHERE timestamp_ms >= ?`) và sắp xếp chạy đúng ngay trong SQL, không phụ thuộc
  ///   format chuỗi.
  /// - **Không** khai báo FOREIGN KEY: `sqflite` không bật `PRAGMA foreign_keys` mặc định, nên
  ///   `ON DELETE CASCADE` sẽ im lặng không có tác dụng. Xoá theo phiên được làm tường minh trong
  ///   một transaction ở `TranscriptDao.deleteOlderThan`.
  /// - Index `(session_id, timestamp_ms)` phục vụ đúng 2 truy vấn thật: lấy N phút gần nhất và
  ///   dump theo phiên.
  static Future<void> _createTranscriptSchema(Database db) async {
    await db.execute(
      'CREATE TABLE transcript_sessions ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'started_at_ms INTEGER NOT NULL, '
      'last_activity_at_ms INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE transcript_segments ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'session_id INTEGER NOT NULL, '
      'timestamp_ms INTEGER NOT NULL, '
      'text TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX idx_transcript_segments_session_ts '
      'ON transcript_segments (session_id, timestamp_ms)',
    );
    // Mốc người dùng bấm Push (P1E task 5). Ghi MỌI lần bấm, không chỉ lần cuối: P2 cần "mốc gần
    // nhất", còn Post-Review (P5) cần lịch sử để đối chiếu gợi ý với lúc bấm thật.
    await db.execute(
      'CREATE TABLE transcript_pushes ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'session_id INTEGER NOT NULL, '
      'timestamp_ms INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX idx_transcript_pushes_session_ts '
      'ON transcript_pushes (session_id, timestamp_ms)',
    );
  }
}
