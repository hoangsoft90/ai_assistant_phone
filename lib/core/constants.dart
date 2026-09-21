/// Hằng số/hằng cấu hình dùng chung toàn app.
///
/// Quy ước: mọi giá trị "ma thuật" (id, tên channel, tên DB, khóa lưu trữ) đều tập trung ở đây
/// để các phase sau không phải sửa rải rác nhiều file.
library;

/// Thông tin hiển thị của app.
abstract final class AppInfo {
  static const String displayName = 'Trợ lý giao tiếp';
}

/// Cấu hình foreground service.
///
/// P0.5 chỉ cần service chạy được và hiện notification cố định "Đang lắng nghe";
/// logic audio thật sẽ được bơm vào `ListeningTaskHandler.onRepeatEvent` ở P1A-P1B.
abstract final class ServiceConfig {
  static const int serviceId = 210;

  static const String channelId = 'ai_assistant_listening';
  static const String channelName = 'Đang lắng nghe';
  static const String channelDescription = 'Hiện khi trợ lý đang nghe hội thoại.';

  static const String notificationTitle = 'Đang lắng nghe';
  static const String notificationText = 'Chạm để quay lại app';

  /// Chu kỳ gọi `onRepeatEvent` (ms). P0.5 chưa dùng; P1A sẽ dùng mốc này cho vòng đọc audio.
  static const int repeatEventMs = 5000;
}

/// Cấu hình lưu trữ.
abstract final class StorageConfig {
  /// SQLite cho transcript store (P1E). Chọn SQLite thay vì Hive vì cần truy vấn theo
  /// khung thời gian + dump theo phiên (xem lý do chi tiết trong README.md).
  static const String databaseName = 'ai_assistant.db';
  static const int databaseVersion = 1;

  /// Khóa lưu API key của LLM trong secure storage (dùng từ P2).
  static const String llmApiKeyKey = 'llm_api_key';
}
