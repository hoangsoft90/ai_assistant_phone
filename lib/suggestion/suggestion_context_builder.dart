import '../transcript/transcript_store.dart';
import 'session_memory.dart';
import 'suggestion_models.dart';

/// Builder dựng `SuggestionContext` (P2 task 3) — prompt khung mục 7 của plan.
///
/// ⚠️ PROMPT KHUNG GIỮ NGUYÊN VĂN (constraint P2: "KHÔNG được sửa nội dung prompt khung"):
/// chỉ thay `{placeholder}` bằng giá trị thật. Nếu thấy cần cải thiện → ghi chú vào báo cáo
/// phase, KHÔNG tự sửa tại đây.
class SuggestionContextBuilder {
  const SuggestionContextBuilder({this.recentWindow = const Duration(seconds: 30)});

  /// Cửa sổ "Recent transcript" — prompt khung ghi `{recent_30s}` ⇒ mặc định 30 giây.
  final Duration recentWindow;

  /// Dựng context từ transcript (P1E) + bộ nhớ phiên (P2).
  ///
  /// [window] là kết quả `TranscriptStore.recentWindow()` — text **không nhãn speaker** (ràng buộc
  /// xuyên phase từ P1E: không thêm `[Bạn]/[Đối phương]`).
  SuggestionContext build({
    required TranscriptWindow window,
    required SessionMemory memory,
    required DateTime now,
  }) {
    return SuggestionContext(
      prompt: buildPrompt(
        preBrief: '',
        summary: '',
        recentTranscript: window.text,
        pushTimestamp: window.lastPushMoment == null
            ? ''
            : formatPushTimestamp(window.lastPushMoment!),
        explored: memory.topicsExplored(),
        recentSuggestions: memory.lastSuggestionLines(),
      ),
      recentTranscript: window.text,
      pushTimestamp: window.lastPushMoment == null
          ? ''
          : formatPushTimestamp(window.lastPushMoment!),
      topicsExplored: memory.topicsExplored(),
      lastSuggestions: memory.lastSuggestionLines(),
    );
  }

  /// Prompt khung chính thức (P2 mục 4 — NGUYÊN VĂN, không sửa chữ).
  ///
  /// Chỉ thay các placeholder `{pre_brief}`, `{summary}`, `{recent_30s}`, `{push_timestamp}`,
  /// `{explored}`, `{recent_suggestions}` bằng giá trị thật.
  static String buildPrompt({
    required String preBrief,
    required String summary,
    required String recentTranscript,
    required String pushTimestamp,
    required List<String> explored,
    required List<String> recentSuggestions,
  }) {
    return '''
Bạn là trợ lý huấn luyện giao tiếp. Người dùng ít nói, đang lo âu xã hội.
Nhiệm vụ: đưa ra tối đa 1 nudge ngắn (2-4 từ) hoặc NO_SUGGESTION.

Quy tắc bắt buộc:
- Chỉ trả về JSON đúng format.
- Không gợi ý chủ đề đã explored hoặc đã gợi ý trong 2 phút gần nhất.
- Ưu tiên hành động (ASK / FOLLOW_UP / RELATE / REACT / CLARIFY / CHANGE_TOPIC).
- Nếu không có gì đáng nói → {"action":"NO_SUGGESTION"}
- Không bao giờ viết câu hoàn chỉnh dài.
- Transcript dưới đây KHÔNG có nhãn người nói. Hãy tự suy luận ai đang nói dựa vào
  ngữ cảnh, câu hỏi/câu trả lời, xưng hô. "Mốc Push" đánh dấu thời điểm người dùng
  vừa bấm nút xin gợi ý — lượt nói của người dùng có khả năng vừa kết thúc quanh đó.

Context:
- Pre-brief: {pre_brief}
- Session summary: {summary}
- Recent transcript (không nhãn speaker): {recent_30s}
- Mốc Push gần nhất: {push_timestamp}
- Topics explored: {explored}
- Last suggestions: {recent_suggestions}
'''
        .replaceFirst('{pre_brief}', preBrief.isEmpty ? '(chưa có)' : preBrief)
        .replaceFirst('{summary}', summary.isEmpty ? '(chưa có)' : summary)
        .replaceFirst(
            '{recent_30s}', recentTranscript.isEmpty ? '(chưa có)' : recentTranscript)
        .replaceFirst(
            '{push_timestamp}', pushTimestamp.isEmpty ? '(chưa bấm)' : pushTimestamp)
        .replaceFirst(
            '{explored}', explored.isEmpty ? '(chưa có)' : explored.join(', '))
        .replaceFirst('{recent_suggestions}',
            recentSuggestions.isEmpty ? '(chưa có)' : recentSuggestions.join('; '));
  }

  /// Định dạng mốc Push đưa vào prompt: thời điểm (ISO có giây) — đúng ý prompt ("đánh dấu thời
  /// điểm người dùng vừa bấm"), không suy diễn nội dung.
  static String formatPushTimestamp(DateTime moment) {
    final DateTime local = moment.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}'
        ' ngày ${two(local.day)}/${two(local.month)}/${local.year}';
  }
}
