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

/// Cấu hình Suggestion Engine (P2).
abstract final class SuggestionConfig {
  /// Debounce chống double-tap cho **Push thủ công**. KHÔNG phải cooldown 12-15s — cooldown chỉ
  /// thuộc semi-auto mode (P6, chưa làm); áp cooldown lên Push là vi phạm ràng buộc xuyên phase.
  static const Duration pushDebounce = Duration(seconds: 1);

  /// Anti-repetition: không gợi ý lại chủ đề/type đã dùng trong khoảng này (plan mục 4.7).
  static const Duration antiRepetitionWindow = Duration(minutes: 2);

  /// Timeout gọi API LLM. Quá hạn ⇒ trả `NO_SUGGESTION` (không treo app). Offline Nudge Cache
  /// thật làm ở P3; ở đây chỉ cần fail gracefully.
  static const Duration llmTimeout = Duration(seconds: 4);

  /// Retry đúng 1 lần khi LLM trả JSON lỗi, rồi coi như `NO_SUGGESTION` (prompt P2 mục 5).
  static const int llmMaxParseRetries = 1;

  /// Model Groq mặc định (llama-3.1-8b-instant — gợi ý trong prompt P2, còn hoạt động 2026-09,
  /// free tier). Không hard-code ở tầng provider; đổi qua đây khi giá/model thay đổi.
  static const String groqModel = 'llama-3.1-8b-instant';

  /// Endpoint Groq chat completions (OpenAI-compatible, xác minh từ tài liệu chính thức 2026-09).
  static const String groqEndpoint = 'https://api.groq.com/openai/v1/chat/completions';
}

/// Cấu hình Trigger + Output Mode (P3).
abstract final class TriggerConfig {
  /// Giữ nút nổi bao lâu thì tính là gesture Emergency (prompt P3 task 2: 2 giây).
  /// Ngắn hơn [emergencyHold] ⇒ Push thường; đủ [emergencyHold] ⇒ Emergency Phrase.
  static const Duration emergencyHold = Duration(seconds: 2);
}

/// Cấu hình chế độ hiển thị nudge (P3 mục 4.8).
abstract final class OutputConfig {
  /// Khoá lưu chế độ output trong bảng `meta` (dùng lại `ConfigStore` như P1D).
  static const String modeKey = 'nudge_output_mode';

  /// Asset kho nudge offline (P3 mục 4.12).
  static const String offlineNudgeCacheAsset = 'assets/offline_nudge_cache.json';

  /// Khoảng tốc độ đọc TTS cho phép + mặc định (theo mục 4.8).
  ///
  /// Đã nối tới native từ P3 (`TextToSpeech.setSpeechRate` trong `SafeTtsBridge.kt`), nhưng
  /// **chưa verify trên máy thật** — xem K41 ở `checklist.md`.
  static const double minSpeechRate = 0.9;
  static const double maxSpeechRate = 1.2;
  static const double defaultSpeechRate = 1.05;

  /// Khoá lưu tốc độ đọc TTS (bảng `meta`, cùng chỗ với [modeKey]).
  static const String speechRateKey = 'tts_speech_rate';

  /// Chuẩn hoá tốc độ đọc về khoảng cho phép.
  ///
  /// Một chỗ DUY NHẤT định nghĩa ràng buộc 0.9x-1.2x, dùng chung cho cả tầng cấu hình (đọc từ
  /// `meta`) và tầng phát (`SafeTtsOutput`): giá trị hỏng (NaN/Infinity/nằm ngoài khoảng) không được
  /// làm native nhận một tốc độ lạ, cũng không được làm UI hiển thị số vô nghĩa.
  static double clampSpeechRate(double value) {
    if (!value.isFinite) {
      return defaultSpeechRate;
    }
    return value.clamp(minSpeechRate, maxSpeechRate).toDouble();
  }
}
