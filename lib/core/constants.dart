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

/// Cấu hình phiên hội thoại (P4 — tích hợp pipeline + half-duplex).
///
/// Các ngưỡng ở đây đều là **ngưỡng phục hồi**, không phải ngưỡng nghiệp vụ: chúng chỉ quyết định
/// khi nào một module con được coi là hỏng và cần khởi động lại / tắt hẳn, để một module lỗi không
/// kéo sập cả phiên (prompt P4 task 5).
abstract final class SessionConfig {
  /// Số lần `feedAudioChunk` lỗi **liên tiếp** thì coi là engine ASR đã hỏng (chứ không phải một
  /// chunk lỗi lẻ) và tiến hành khởi động lại. 1 lần lỗi lẻ là chuyện bình thường (engine đang tự
  /// dọn buffer), còn lỗi liên tục 3 lần thì gần như chắc chắn engine đã chết.
  static const int maxConsecutiveAsrFeedFailures = 3;

  /// Trần số lần khởi động lại ASR trong một phiên.
  ///
  /// Có trần là **có chủ ý**: nếu model hỏng thật (máy hết RAM, thiếu file model) thì khởi động lại
  /// vô hạn chỉ tạo vòng lặp nạp/xả model vài trăm MB làm nóng máy và tụt pin — tệ hơn hẳn việc tắt
  /// ASR và nói rõ cho người dùng rằng chỉ còn VAD.
  static const int maxAsrRestarts = 2;

  /// Số mẫu độ trễ `Push → native bắt đầu tổng hợp` giữ lại để tính trung bình
  /// (DoD P4: "đo độ trễ từ lúc bấm Push đến lúc bắt đầu nghe nudge").
  ///
  /// Giữ 50 mẫu gần nhất thay vì cả phiên: phiên 30-45 phút có thể có hàng trăm lần bấm, còn số
  /// trung bình thì chỉ cần cửa sổ gần đây để phản ánh trạng thái hiện tại của máy.
  static const int latencySampleLimit = 50;
}

/// Cấu hình Coaching — Pre-Brief + Session Summary + Post-Review + Training Level (P5).
///
/// Mọi ngưỡng ở đây là **ngưỡng chi phí/thời gian gọi LLM**, không phải ngưỡng nghiệp vụ: chúng chỉ
/// quyết định *bao lâu thì gọi thêm một lần*, để các tính năng mới của P5 không biến mỗi lần bấm Push
/// thành nhiều request LLM.
abstract final class CoachingConfig {
  /// Khoá lưu **bản nháp Pre-Brief** trong bảng `meta` (dùng lại `ConfigStore` như P1D/P3).
  ///
  /// Vì sao lưu nháp: form Pre-Brief có 6 trường người dùng phải gõ lại mỗi buổi — Pre-Brief là ngữ
  /// cảnh *của buổi*, không phải dữ liệu hội thoại, nên giữ lại để tự điền lần sau là hợp lý. Dữ liệu
  /// nằm trong sandbox app (không mã hoá — giống transcript, xem `transcript_dao.dart`).
  static const String preBriefDraftKey = 'coaching.pre_brief';

  /// Khoá lưu **Training Level** đã chọn (mục 4.9 — hoàn toàn thủ công).
  static const String trainingLevelKey = 'coaching.training_level';

  /// Nhịp tóm tắt phiên: tối thiểu bao nhiêu nudge mới gọi LLM tóm tắt một lần (mục 4.10/P5 task 2).
  ///
  /// 4 nudge: đủ để "diễn biến" có gì mới, mà không tốn một request cho mỗi lần bấm Push (mỗi buổi có
  /// thể có hàng chục lần bấm).
  static const int summaryEveryNudges = 4;

  /// Trần thời gian giữa hai lần tóm tắt: buổi nói chuyện im lặng lâu mà vẫn có nudge thì tóm tắt
  /// lại theo nhịp này (điều kiện HOẶC với [summaryEveryNudges]).
  static const Duration summaryInterval = Duration(minutes: 5);

  /// Trần số ký tự transcript gửi cho LLM ở **mỗi** lần tóm tắt / Post-Review.
  ///
  /// Lý do phải có trần (không chỉ để tiết kiệm token): buổi nói 45 phút có thể sinh vài chục nghìn ký
  /// tự; gửi hết sẽ vượt context window của model nhỏ và làm request lỗi ⇒ tính năng "tự chết" giữa
  /// buổi dài. Cắt từ **đầu** (giữ phần gần đây nhất) vì phần gần đây mới là thứ cần cho gợi ý. Khi
  /// cắt, báo cáo phải nói rõ là đã cắt (không im lặng).
  static const int transcriptCharLimit = 6000;

  /// Trần số ký tự của bản tóm tắt phiên đưa vào prompt khung (`{summary}`) — tóm tắt dài sẽ ăn hết
  /// chỗ của transcript 30s trong cửa sổ context của model nhỏ.
  static const int summaryCharLimit = 400;

  /// Ngưỡng "thật sự kẹt" cho Training Level 3 (Minimal, mục 4.9: *"chỉ khi thật sự kẹt"*).
  ///
  /// Đo được bằng dữ liệu đã có: khoảng lặng kể từ dòng transcript cuối. Đây là **suy luận** của tôi
  /// (prompt P5 cho phép agent tự thiết kế luật cho từng cấp) — ghi rõ trong báo cáo phase để chỉnh
  /// sau khi có phiên thật.
  static const Duration minimalStuckSilence = Duration(seconds: 8);
}

/// Cấu hình nhắc ranh giới đạo đức (P7 — mục 5.3 của kế hoạch).
///
/// Đây là **lời nhắc cho chính người dùng**, không phải tính năng pháp lý: không thu thập,
/// không chặn, không ghi nhận vi phạm. Hiện **một lần duy nhất khi mở app lần đầu** (flag trong
/// bảng `meta`), nội dung tĩnh để không phải giải thích thêm.
abstract final class EthicsConfig {
  /// Khoá flag "đã hiển thị" trong bảng `meta`. Chỉ ghi `'1'` sau khi dialog ĐÓNG (không ghi khi
  /// mở — nếu app bị kill giữa chừng thì lần sau vẫn hiện lại, hướng an toàn).
  static const String shownFlagKey = 'ethics_reminder_shown';

  static const String dialogTitle = 'Trước khi dùng';

  static const String dialogBody = 'Ứng dụng này hỗ trợ GIAO TIẾP CỦA CHÍNH BẠN.\n\n'
      'Đừng dùng trong các cuộc trao đổi có nội dung riêng tư hoặc nhạy cảm thuộc về người khác '
      '(sức khoẻ, tài chính, bí mật cá nhân...). Câu gợi ý do máy sinh ra chỉ để tham khảo — '
      'bạn vẫn là người chịu trách nhiệm với lời nói của mình.';

  static const String dialogConfirm = 'Tôi hiểu';
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
