import '../../core/app_logger.dart';
import '../../core/constants.dart';
import 'meta_store.dart';
import 'transcript_dao.dart';

/// Các lựa chọn số ngày tự xoá cho phép (P5.1 — mục Settings). Danh sách cố ý **cố định**: cho nhập
/// tự do sẽ sinh giá trị vô lý (0 ngày xoá liên tục, số âm không nghĩa, 9999 ngày đánh mất mục tiêu
/// quyền riêng tư của mục 5.3).
const List<int> allowedRetentionDays = <int>[3, 7, 14, 30];

/// Resolve số ngày tự xoá dữ liệu (P5.1) — cùng pattern với `LlmProviderConfigResolver` (P2.1):
/// đọc `ConfigStore`, giá trị hỏng/thiếu **fallback về mặc định** mà không bao giờ ném.
abstract final class RetentionConfigResolver {
  static const AppLogger _log = AppLogger('RetentionConfig');

  /// Số ngày retention đang có hiệu lực:
  /// - chưa cấu hình (rỗng/null) ⇒ [StorageConfig.transcriptRetention] (7 ngày) — hành vi y hệt
  ///   trước P5.1 (DoD: không đổi mặc định);
  /// - giá trị không parse được hoặc ≤ 0 ⇒ cũng về mặc định (không ném, không crash);
  /// - giá trị ngoài danh sách cho phép ⇒ vẫn nhận (người dùng có thể đã cấu hình từ lần chạy trước
  ///   bằng giá trị khác) — resolver trung lập, UI mới là nơi giới hạn lựa chọn.
  static Future<Duration> resolve(ConfigStore store) async {
    final String? raw;
    try {
      raw = await store.read(StorageConfig.retentionDaysKey);
    } catch (error) {
      _log.warn('không đọc được cấu hình retention — dùng mặc định: $error');
      return StorageConfig.transcriptRetention;
    }
    if (raw == null || raw.trim().isEmpty) {
      return StorageConfig.transcriptRetention;
    }
    final int? days = int.tryParse(raw.trim());
    if (days == null || days <= 0) {
      _log.warn('giá trị retention không hợp lệ: "$raw" — dùng mặc định '
          '${StorageConfig.transcriptRetention.inDays} ngày');
      return StorageConfig.transcriptRetention;
    }
    return Duration(days: days);
  }

  /// Lưu lựa chọn. Chỉ dùng cho giá trị UI chọn từ danh sách cố định (không validate lại ở đây).
  static Future<void> save(ConfigStore store, int days) =>
      store.write(StorageConfig.retentionDaysKey, days.toString());

  /// Xoá cấu hình ⇒ quay về mặc định 7 ngày (dùng cho nút "mặc định" nếu cần + test).
  static Future<void> reset(ConfigStore store) =>
      store.write(StorageConfig.retentionDaysKey, '');
}

/// Xoá dữ liệu cũ theo hạn retention đang có hiệu lực (P5.1).
///
/// Tách khỏi `TranscriptStore` vì cleanup phải chạy **ngay khi người dùng đổi Settings** (không đợi
/// lần mở app sau), và phải phủ **cả** `post_review_reports` — bảng mới của P5.1 — chứ không chỉ 3
/// bảng transcript như trước. Lỗi DB không ném (cleanup là việc nền, không được làm sập Settings).
abstract final class RetentionCleanup {
  static const AppLogger _log = AppLogger('RetentionCleanup');

  /// Chạy cleanup ngay bây giờ với hạn đang có hiệu lực. Trả về số phiên đã xoá, `null` nếu DB lỗi.
  ///
  /// [now] cho phép bơm đồng hồ (test không dùng `DateTime.now()` thật — cùng convention mọi
  /// service của repo).
  static Future<int?> runNow({
    ConfigStore? configStore,
    TranscriptDao? dao,
    DateTime Function()? now,
  }) async {
    final TranscriptDao effectiveDao = dao ?? const SqliteTranscriptDao();
    try {
      final Duration retention = await RetentionConfigResolver.resolve(
        configStore ?? const MetaConfigStore(),
      );
      final int removed = await effectiveDao.deleteOlderThan(
        (now ?? DateTime.now)().subtract(retention),
      );
      if (removed > 0) {
        _log.info('cleanup theo retention ${retention.inDays} ngày: đã xoá $removed phiên');
      }
      return removed;
    } catch (error, stackTrace) {
      _log.error('cleanup theo retention lỗi', error, stackTrace);
      return null;
    }
  }
}
