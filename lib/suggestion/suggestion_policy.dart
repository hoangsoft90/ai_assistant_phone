import '../core/constants.dart';
import 'session_memory.dart';
import 'suggestion_models.dart';

/// Suggestion Policy (P2 task 2) — luật chặn **CỨNG** trước khi đụng tới context/LLM.
///
/// Nguyên tắc bất biến số 2 của plan: tuyệt đối không gợi ý khi người dùng đang nói. Vì vậy check
/// `userSpeaking` nằm Ở ĐÂY (tầng trước khi build context), không dựa vào prompt để LLM "tự biết".
///
/// Push thủ công: **KHÔNG có cooldown** (chỉ debounce chống double-tap) — cooldown 12-15s chỉ dành
/// cho semi-auto mode ở P6, áp vào Push là vi phạm ràng buộc xuyên phase.
class SuggestionPolicy {
  const SuggestionPolicy();

  /// Quyết định có được gọi LLM khi người dùng bấm Push hay không.
  ///
  /// [isUserSpeaking] — trạng thái từ `ConversationStateMachine` (P1B); `true` ⇒ chặn CỨNG.
  /// [lastAttemptAt] — lần bấm Push **gần nhất trước lần này** (nỗ lực, không phải lần thành công)
  /// để bắt double-tap; `null` ⇒ chưa bấm lần nào trong phiên.
  PolicyDecision canSuggest({
    required bool isUserSpeaking,
    required DateTime? lastAttemptAt,
    required DateTime now,
  }) {
    // 1) Chặn CỨNG theo state hội thoại — điều kiện DUY NHẤT bắt buộc cho Push thủ công.
    if (isUserSpeaking) {
      return const PolicyDecision.blocked('userSpeaking');
    }
    // 2) Debounce chống double-tap (không phải cooldown).
    final DateTime? last = lastAttemptAt;
    if (last != null && now.difference(last) < SuggestionConfig.pushDebounce) {
      return const PolicyDecision.blocked('debounce');
    }
    return const PolicyDecision.allowed();
  }

  /// Anti-repetition (mục 4.7): không gợi ý lại **chủ đề** (text) hoặc **type** đã xuất hiện trong
  /// 2 phút gần nhất. Chỉ áp cho nudge (`NO_SUGGESTION` không cần lọc). Đọc đúng nghĩa "trùng
  /// chủ đề/type" trong prompt P2: so khớp text chuẩn hoá (thường/không khoảng trắng thừa) hoặc
  /// cùng loại nudge — sát hơn so với so khớp mờ, nhưng đo được và không đoán mò.
  bool isRepetition({
    required SuggestionResult result,
    required List<SuggestionRecord> recent,
    required DateTime now,
  }) {
    if (!result.isNudge) {
      return false;
    }
    final String text = _normalize(result.text);
    final NudgeType type = result.type!;
    for (final SuggestionRecord record in recent) {
      if (now.difference(record.at) > SuggestionConfig.antiRepetitionWindow) {
        continue;
      }
      if (_normalize(record.text) == text || record.type == type) {
        return true;
      }
    }
    return false;
  }

  static String _normalize(String? raw) =>
      (raw ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}

/// Kết quả của [SuggestionPolicy.canSuggest].
class PolicyDecision {
  const PolicyDecision.allowed()
      : allowed = true,
        reason = null;

  const PolicyDecision.blocked(this.reason)
      : allowed = false;

  final bool allowed;

  /// Lý do bị chặn (`userSpeaking` / `debounce`) — `null` khi được phép.
  final String? reason;
}
