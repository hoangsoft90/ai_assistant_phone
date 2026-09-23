import '../services/storage/transcript_dao.dart';

/// Tên hiển thị của một phiên (P5.2) — **một chỗ duy nhất** sinh tên, để danh sách Lịch sử và màn
/// hình chi tiết báo cáo không bao giờ lệch nhau.
///
/// Quy tắc:
/// - `title` khác `null` và **không rỗng sau khi trim** ⇒ dùng tên người dùng đã đặt.
/// - ngược lại (`null`, chuỗi rỗng, hoặc chỉ khoảng trắng — gồm cả phiên cũ trước migration v4)
///   ⇒ sinh tên mặc định từ `started_at` theo giờ **địa phương**, ví dụ `"Buổi 23/09/2026 14:30"`.
///
/// Không có nhánh nào ném: mọi dữ liệu vào đều hiển thị được.
abstract final class SessionDisplayName {
  /// Trần độ dài tên người dùng đặt. Cắt bớt (không báo lỗi) để tên dài không phá layout danh sách
  /// trong Lịch sử.
  static const int maxLength = 60;

  /// Tên hiển thị của [session] — tên đã đặt nếu có, nếu không thì tên mặc định theo timestamp.
  static String of(TranscriptSession session) {
    final String? title = session.title;
    if (title != null && title.trim().isNotEmpty) {
      return title.trim();
    }
    return defaultFrom(session.startedAt);
  }

  /// Tên mặc định sinh từ mốc bắt đầu phiên, định dạng `"Buổi 23/09/2026 14:30"`.
  static String defaultFrom(DateTime startedAt) => 'Buổi ${timestamp(startedAt)}';

  /// Mốc thời gian dạng `"23/09/2026 14:30"` theo giờ **địa phương** máy (ngày/tháng/năm).
  /// Dùng chung cho tên mặc định của phiên và dòng "báo cáo đã lưu lúc ..." ở màn hình chi tiết.
  static String timestamp(DateTime moment) {
    final DateTime local = moment.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// Chuẩn hoá giá trị người dùng nhập trước khi lưu (P5.2):
  /// - rỗng / toàn khoảng trắng ⇒ `null` (xoá tên tự đặt, quay về tên mặc định — **không báo lỗi**);
  /// - dài hơn [maxLength] ⇒ **cắt bớt**, không throw;
  /// - còn lại ⇒ trim.
  static String? normalize(String? raw) {
    if (raw == null) {
      return null;
    }
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return trimmed.length <= maxLength ? trimmed : trimmed.substring(0, maxLength);
  }
}
