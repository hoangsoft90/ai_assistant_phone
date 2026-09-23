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
    await _createPostReviewSchema(db);
    await _addSessionTitleColumn(db);
    await _addSessionEndedColumn(db);
    _log.info('đã tạo schema v$version (meta + transcript + post_review_reports + cột title + cột ended_at)');
  }

  /// Migration từng bước. KHÔNG được xoá/tạo lại DB của người dùng: máy đã cài bản P0.5 sẽ có DB
  /// v1 trên đĩa, thiếu nhánh ở đây là crash lúc mở DB.
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 -> v2 (P1E): thêm 3 bảng transcript. Bảng `meta` giữ nguyên, dữ liệu cũ không bị đụng.
      await _createTranscriptSchema(db);
      _log.info('migration v1 -> v2: đã tạo bảng transcript');
    }
    if (oldVersion < 3) {
      // v2 -> v3 (P5.1): thêm bảng lưu báo cáo Post-Review (xem lại từ màn hình Lịch sử). Chỉ thêm
      // bảng MỚI — dữ liệu v2 (meta + transcript) giữ nguyên. Nhánh `< 2` ở trên KHÔNG được sửa.
      await _createPostReviewSchema(db);
      _log.info('migration v2 -> v3: đã tạo bảng post_review_reports');
    }
    if (oldVersion < 4) {
      // v3 -> v4 (P5.2): thêm cột `title` vào `transcript_sessions` (tên phiên người dùng đặt;
      // `NULL` = chưa đặt tên ⇒ hiển thị sẽ sinh tên mặc định từ `started_at_ms`). Chỉ THÊM CỘT —
      // dữ liệu phiên cũ giữ nguyên, không backfill. Các nhánh `< 2`/`< 3` ở trên KHÔNG được sửa.
      await _addSessionTitleColumn(db);
      _log.info('migration v3 -> v4: đã thêm cột title vào transcript_sessions');
    }
    if (oldVersion < 5) {
      // v4 -> v5 (issue1_fix): thêm cột `ended_at_ms` vào `transcript_sessions` — phân biệt
      // **kết-thúc-chủ-động** (người dùng bấm "Kết thúc buổi") với "chỉ hết hoạt động". Phiên đã có
      // `ended_at_ms` không được resume lại (ngược lại thì Start mới sau 30 phút vẫn nối tiếp phiên
      // cũ ⇒ transcript lẫn + báo cáo Post-Review bị ghi đè nhầm phiên). Chỉ THÊM CỘT — dữ liệu cũ
      // giữ nguyên, `NULL` = chưa kết thúc chủ động (phiên cũ trước bản này coi như "chưa kết thúc" —
      // hành vi resume như trước, không mất khả năng crash-recovery cho phiên đang dở thật).
      // Các nhánh `< 2`/`< 3`/`< 4` ở trên KHÔNG được sửa.
      await _addSessionEndedColumn(db);
      _log.info('migration v4 -> v5: đã thêm cột ended_at_ms vào transcript_sessions');
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

  /// Cột `title` của phiên (P5.2) — dùng chung cho `onCreate` (máy mới) và nhánh `oldVersion < 4`
  /// để hai đường không bao giờ lệch nhau.
  ///
  /// **CỐ Ý KHÔNG** đặt `title` vào `_createTranscriptSchema`: helper đó còn được nhánh `< 2` gọi,
  /// và khi đó nhánh `< 4` sẽ chạy `ALTER TABLE` lên bảng **vừa tạo đã có cột** ⇒ lỗi
  /// "duplicate column name" (đường nâng cấp từ DB v1). Tách ALTER ra một chỗ duy nhất như dưới đây
  /// bảo đảm MỌI đường (máy mới, v1/v2/v3 cũ) đều thêm cột đúng **một lần**.
  static Future<void> _addSessionTitleColumn(Database db) async {
    await db.execute('ALTER TABLE transcript_sessions ADD COLUMN title TEXT');
  }

  /// Cột `ended_at_ms` của phiên (issue1_fix) — dùng chung cho `onCreate` (máy mới) và nhánh
  /// `oldVersion < 5` để hai đường không bao giờ lệch nhau.
  ///
  /// **CỐ Ý KHÔNG** đặt vào `_createTranscriptSchema`: helper đó còn được nhánh `< 2` gọi ⇒ sẽ
  /// `duplicate column name` khi nâng từ DB v1 (cùng lý do `title` ở P5.2 đã tách riêng). `NULL` =
  /// chưa kết thúc chủ động (phiên crash/đang dở — được resume theo `resumeGap` như cũ).
  static Future<void> _addSessionEndedColumn(Database db) async {
    await db.execute('ALTER TABLE transcript_sessions ADD COLUMN ended_at_ms INTEGER');
  }

  /// Schema báo cáo Post-Review (P5.1) — dùng chung cho `onCreate` (máy mới) và nhánh
  /// `oldVersion < 3` (máy đã có v1/v2) để hai đường không bao giờ lệch nhau (cùng cách
  /// `_createTranscriptSchema` đã làm cho P1E).
  ///
  /// Theo đúng convention schema đã chốt của repo: mốc thời gian = epoch milliseconds (INTEGER),
  /// KHÔNG khai báo FOREIGN KEY (sqflite không bật `PRAGMA foreign_keys`), xoá theo phiên làm
  /// tường minh trong transaction ở `TranscriptDao`.
  ///
  /// Chỉ lưu báo cáo **dùng được** (`isUsable == true` — đủ 3 mục, sinh từ LLM thành công). Các báo
  /// cáo `unavailable` (mất mạng/chưa có transcript) không có giá trị xem lại — chỉ gây nhiễu Lịch sử.
  static Future<void> _createPostReviewSchema(Database db) async {
    await db.execute(
      'CREATE TABLE post_review_reports ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'session_id INTEGER NOT NULL, '
      'generated_at_ms INTEGER NOT NULL, '
      'good TEXT NOT NULL, '
      'missed TEXT NOT NULL, '
      'exercise TEXT NOT NULL, '
      'segment_count INTEGER NOT NULL, '
      'truncated INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX idx_post_review_reports_session ON post_review_reports (session_id)',
    );
  }
}
