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

  /// Version schema SQLite. v2 (P1E): thêm 3 bảng transcript (`transcript_sessions`,
  /// `transcript_segments`, `transcript_pushes`). Mỗi lần lên version PHẢI có nhánh migration
  /// tương ứng trong `AppDatabase._onUpgrade` — người dùng đã có DB v1 trên máy.
  static const int databaseVersion = 2;

  /// Transcript (P1E): cửa sổ giữ trong **bộ nhớ hoạt động**. Dài hơn thì đọc thẳng từ SQLite;
  /// ngắn hơn thì tốn RAM vô ích khi phiên chạy hàng giờ.
  static const Duration transcriptRollingWindow = Duration(minutes: 8);

  /// Phiên transcript cũ hơn mốc này (theo hoạt động cuối) được coi là "đã kết thúc" ⇒ mở app lại
  /// sẽ tạo phiên MỚI thay vì khôi phục. Nhỏ hơn ngưỡng này ⇒ coi là phiên **đang dở** (app bị OS
  /// kill giữa chừng) và khôi phục lại (P1E task 4). 30 phút: đủ dài cho một cuộc nói chuyện có
  /// khoảng nghỉ, đủ ngắn để lần mở app hôm sau không nối vào phiên cũ.
  static const Duration transcriptResumeGap = Duration(minutes: 30);

  /// Tự xoá transcript cũ hơn mốc này (P1E task 7 — quyền riêng tư, mục 5.3): 7 ngày.
  /// Chạy ở `TranscriptStore.init()` (lúc app khởi động).
  static const Duration transcriptRetention = Duration(days: 7);

  /// Khóa lưu API key của LLM trong secure storage (dùng từ P2).
  static const String llmApiKeyKey = 'llm_api_key';
}
