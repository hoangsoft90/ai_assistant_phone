import '../coaching/training_level.dart';
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
    TrainingLevel level = TrainingLevel.fullAssist,
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
    // 3) Training Level (P5, mục 4.9): Level 4/5 "không cứu realtime" ⇒ trả `NO_SUGGESTION` CÓ CHỦ
    //    ĐÍCH (không phải lỗi, không phải fallback cache) trước khi build context/gọi LLM.
    //
    //    Đặt ở đây — chứ không trong prompt — vì đúng nguyên tắc của P2: quyết định "có hỏi LLM hay
    //    không" phải nằm ở tầng policy, không được giao cho LLM tự đoán. Push vẫn được ghi nhận (mốc
    //    Push ghi ở `TriggerManager`) để Post-Review còn dữ liệu; chỉ nudge bị chặn.
    //    Emergency Phrase KHÔNG đi qua đây (đường riêng của P1G/P3) ⇒ câu thoát hiểm vẫn phát.
    if (level.blocksRealtimeNudges) {
      return PolicyDecision.blocked('level ${level.storageValue} (không cứu realtime)');
    }
    return const PolicyDecision.allowed();
  }

  /// Cổng thứ hai theo Training Level — cần **ngữ cảnh** nên phải chạy SAU khi dựng context, nhưng
  /// vẫn TRƯỚC khi gọi LLM (mục 4.9: Level 2 "chỉ khi push + context rõ", Level 3 "chỉ khi thật sự kẹt").
  ///
  /// Vì sao tách khỏi [canSuggest] thay vì gộp: [canSuggest] chạy trước khi đọc transcript (để không
  /// phải đọc DB khi đang nói), còn hai luật này cần dữ liệu của transcript. Gộp lại sẽ buộc phải đọc
  /// transcript ở mọi lần bấm — kể cả lúc `userSpeaking` (đúng ca bị cấm).
  ///
  /// [hasPreBrief]/[hasRecentTranscript] là "có ngữ cảnh rõ" theo nghĩa hẹp, đo được: người dùng đã
  /// nhập Pre-Brief, hoặc trong 30s gần nhất đã có dòng transcript. Rỗng cả hai ⇒ LLM không có gì để
  /// dựa vào, gợi ý lúc đó chỉ là đoán mò.
  ///
  /// [lastTranscriptAt] là mốc dòng transcript CUỐI — dùng làm phép đo "thật sự kẹt" (im lặng kéo
  /// dài). `null` (chưa có dòng nào) ⇒ coi như chưa kẹt: chưa có gì để nói thì không phải "kẹt".
  PolicyDecision canSuggestWithContext({
    required TrainingLevel level,
    required bool hasPreBrief,
    required bool hasRecentTranscript,
    required DateTime? lastTranscriptAt,
    required DateTime now,
  }) {
    if (level.requiresClearContext && !(hasPreBrief || hasRecentTranscript)) {
      return PolicyDecision.blocked(
        'level ${level.storageValue} (chưa có ngữ cảnh rõ: chưa nhập Pre-Brief và chưa có transcript)',
      );
    }
    if (level.requiresStuck) {
      final DateTime? last = lastTranscriptAt;
      if (last == null) {
        return PolicyDecision.blocked('level ${level.storageValue} (chưa có transcript để biết là kẹt)');
      }
      final Duration silence = now.difference(last);
      if (silence < CoachingConfig.minimalStuckSilence) {
        return PolicyDecision.blocked(
          'level ${level.storageValue} (mới im lặng ${silence.inSeconds}s — chưa tới mức kẹt '
          '${CoachingConfig.minimalStuckSilence.inSeconds}s)',
        );
      }
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
