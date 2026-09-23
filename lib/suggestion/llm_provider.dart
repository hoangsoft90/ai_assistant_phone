import 'suggestion_models.dart';

/// Abstraction provider LLM (P2 task 1).
///
/// Cấu trúc để thêm `GeminiLlmProvider` sau mà KHÔNG sửa tầng trên (policy/service/UI) — giá/model
/// API có thể đổi, không hard-code 1 provider (bài học plan_final_v2 mục 2). Implementer nhận
/// [SuggestionContext] (đã chứa prompt hoàn chỉnh) và trả [SuggestionResult]; mọi lỗi vận hành
/// (mạng/timeout/HTTP/JSON) ném [SuggestionException] để tầng trên retry rồi quy về
/// `NO_SUGGESTION` — không để lộ Exception khác.
abstract class LlmProvider {
  Future<SuggestionResult> generateSuggestion(SuggestionContext context);
}

/// Provider LLM cho **văn bản tự do** (P5: tóm tắt phiên + Post-Review).
///
/// Vì sao tách khỏi [LlmProvider] thay vì thêm method vào đó: [LlmProvider] có hợp đồng rất hẹp —
/// *luôn* trả `SuggestionResult` đã parse từ JSON nudge — và mọi fake trong test đều bám hợp đồng đó.
/// Nhét thêm một method trả `String` vào đây sẽ (a) buộc mọi implementation/fake phải khai báo cả hai
/// việc không liên quan nhau, (b) trộn hai loại lỗi khác nhau: lỗi parse JSON nudge là chuyện nhỏ
/// (quy về `NO_SUGGESTION`), còn lỗi của tóm tắt/Post-Review chỉ có nghĩa "không tạo được văn bản".
///
/// Hợp đồng: trả text đã trim, ném [SuggestionException] cho mọi lỗi vận hành (mạng/timeout/HTTP/
/// thiếu key). Caller **không bao giờ** để lỗi này nổi lên UI — xem `SessionSummaryService`/
/// `PostReviewService` (đều nuốt lỗi và ghi `note` chẩn đoán).
abstract class TextLlmProvider {
  Future<String> complete({required String prompt, int maxTokens});
}
