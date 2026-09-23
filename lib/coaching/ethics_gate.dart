import '../core/app_logger.dart';
import '../core/constants.dart';
import '../services/storage/meta_store.dart';

/// Cổng "đã hiển thị lời nhắc đạo đức" (P7 mục 4 — mục 5.3 của kế hoạch).
///
/// Trách nhiệm duy nhất: trả lời "**app đã hiện lời nhắc ranh giới đạo đức cho người dùng này
/// chưa?**" — đủ để UI quyết định hiện dialog lần đầu hay không, mà **không** cần đọc/ghi bảng
/// `meta` trực tiếp từ tầng UI (UI không chạm storage trực tiếp — tách tầng đã chốt từ P1E).
/// Đây là **lời nhắc cho chính người dùng**, không phải tính năng pháp lý: không chặn, không ghi
/// nhận vi phạm; flag `meta` chỉ nhằm để dialog không hiện lại mỗi lần mở app.
///
/// Lỗi đọc/ghi **không bao giờ ném** (cùng hợp đồng với `TrainingLevelStore`): DB lỗi ⇒ coi là
/// "chưa hiện" (hướng an toàn — dialog có thể hiện lại, không sao) và không cấm dùng app.
abstract final class EthicsGate {
  static const AppLogger _log = AppLogger('EthicsGate');

  static bool _shown = false;

  /// Lời nhắc đã được xác nhận chưa? (`true` ngay sau [markShown]; trước đó đọc `meta`.)
  static bool get hasShown => _shown;

  /// Reset RAM — CHỈ gọi từ unit test (tên hàm là hợp đồng; không dùng annotation
  /// `@visibleForTesting` để khỏi phải khai báo dependency `meta` cho đúng một annotation).
  static void resetForTest() => _shown = false;

  /// Đọc flag từ cấu hình. Không bao giờ ném.
  static Future<bool> load(ConfigStore store) async {
    try {
      final String? raw = await store.read(EthicsConfig.shownFlagKey);
      _shown = raw == '1';
    } catch (error) {
      _log.warn('không đọc được flag ethics — coi như chưa hiện: $error');
      _shown = false;
    }
    return _shown;
  }

  /// Ghi flag "đã xác nhận". Không bao giờ ném; lỗi ⇒ `_shown` vẫn được đặt (hướng người dùng:
  /// không hiện lại liên tục vì một lần ghi SQLite lỗi — dialog là lời nhắc, không phải hợp đồng).
  static Future<void> markShown(ConfigStore store) async {
    _shown = true;
    try {
      await store.write(EthicsConfig.shownFlagKey, '1');
    } catch (error) {
      _log.warn('không ghi được flag ethics (sẽ hiện lại lần sau): $error');
    }
  }
}
