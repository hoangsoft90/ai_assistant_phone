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
