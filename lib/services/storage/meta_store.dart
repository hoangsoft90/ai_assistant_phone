import 'package:sqflite/sqflite.dart';

import '../../core/app_logger.dart';
import 'app_database.dart';

/// Đọc/ghi cấu hình dạng khoá–giá trị (P1D: lựa chọn ASR engine).
///
/// Cố ý là interface để tầng trên (selector) test được mà không cần SQLite thật: `sqflite` cần
/// platform channel, còn test chỉ cần một bản giả trong bộ nhớ.
abstract class ConfigStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

/// Bản thật: dùng **lại bảng `meta`** của `AppDatabase` (đã tạo từ P0.5) thay vì thêm
/// `shared_preferences`. Lý do: SQLite đã có sẵn và đã được mở ở bootstrap, thêm một dependency
/// nữa cho đúng một khoá cấu hình là thừa; `meta` vốn được tạo ra để chứa các giá trị nhỏ kiểu này.
class MetaConfigStore implements ConfigStore {
  const MetaConfigStore();

  static const AppLogger _log = AppLogger('MetaConfigStore');

  @override
  Future<String?> read(String key) async {
    final Database db = await AppDatabase.instance();
    final List<Map<String, Object?>> rows = await db.query(
      'meta',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['value'] as String?;
  }

  @override
  Future<void> write(String key, String value) async {
    final Database db = await AppDatabase.instance();
    await db.insert(
      'meta',
      <String, Object?>{'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _log.info('đã lưu cấu hình $key=$value');
  }
}
