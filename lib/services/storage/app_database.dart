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
    _log.info('đã tạo schema v$version (bảng meta)');
  }

  /// Chưa có bản migration nào (mới ở version 1). Khi P1E thêm bảng transcript, mỗi bước lên
  /// version phải có nhánh migration tương ứng ở đây — không được xoá/tạo lại DB của người dùng.
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    _log.warn('onUpgrade $oldVersion -> $newVersion: chưa có migration nào được định nghĩa');
  }
}
