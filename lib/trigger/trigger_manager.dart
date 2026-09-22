import '../audio/emergency/emergency_phrase_service.dart';
import '../audio/nudge_delivery.dart';
import '../audio/output_mode_selector.dart';
import '../audio/tts/safe_tts_output.dart';
import '../core/app_logger.dart';
import '../suggestion/suggestion_models.dart';
import '../suggestion/suggestion_service.dart';
import '../transcript/transcript_store.dart';

/// Nguồn kích hoạt gợi ý (P3 task 1 — mục 4.6).
///
/// Chỉ dùng để **log/chẩn đoán**: mọi nguồn đều đi qua đúng một hàm
/// [TriggerManager.onSuggestRequested], KHÔNG có logic riêng cho từng nguồn. P3 mới có 2 nguồn
/// trong app (nút nổi + nút chẩn đoán); nút thông báo / volume key / nút tai nghe BT là adapter
/// thêm sau mà không phải sửa gì ở đây.
enum SuggestTriggerSource {
  floatingButton('floating_button'),
  diagnosticButton('diagnostic_button'),
  notificationAction('notification_action'),
  volumeKey('volume_key'),
  headsetButton('headset_button');

  const SuggestTriggerSource(this.logName);

  final String logName;
}

/// Kết quả một lần xin gợi ý — đủ để UI hiển thị + ghi log mà không phải hỏi lại tầng nào.
class TriggerOutcome {
  const TriggerOutcome({
    required this.source,
    required this.result,
    required this.effectiveMode,
    required this.delivery,
  });

  final SuggestTriggerSource source;

  /// Kết quả từ Suggestion Engine (có thể là `NO_SUGGESTION`, hoặc nudge từ LLM / từ cache offline).
  final SuggestionResult result;

  /// Chế độ có hiệu lực SAU khi tính tai nghe (Ear có thể đã bị hạ xuống [EffectiveNudgeOutput.text]).
  final EffectiveNudgeOutput effectiveMode;

  /// Cách nudge đã được giao; `null` khi không có nudge nào để giao.
  final NudgeDeliveryResult? delivery;

  bool get hasNudge => result.isNudge;

  /// Dạng ngắn để LOG: dùng `result.logLabel` (không có nội dung nudge) — nội dung nudge suy ra từ
  /// hội thoại nên không được ghi vào logcat (quyết định từ review P2).
  @override
  String toString() =>
      'TriggerOutcome(${source.logName} · ${result.logLabel} · ${effectiveMode.name}'
      '${delivery == null ? '' : ' · giao: ${delivery!.name}'})';
}

/// **Trigger Abstraction** (P3 task 1): một điểm vào duy nhất cho mọi nguồn kích hoạt.
///
/// Luồng Push: ghi mốc Push (P1E) → `SuggestionService.pushFromState()` (Policy chặn cứng
/// `userSpeaking` + debounce) → chọn chế độ output → giao nudge (đọc/rung/chữ).
///
/// Ràng buộc: **KHÔNG cooldown** ở đây (quyết định từ P2: cooldown chỉ thuộc semi-auto mode P6);
/// debounce 1s chống double-tap đã nằm trong `SuggestionPolicy`.
class TriggerManager {
  TriggerManager({
    SuggestionService? suggestions,
    OutputModeSelector? modes,
    NudgeDelivery? delivery,
    TranscriptStore? transcript,
    EmergencyPhraseService? emergency,
    SafeTtsOutput? tts,
  })  : _suggestions = suggestions ?? SuggestionService(),
        _modes = modes ?? OutputModeSelector(),
        _delivery = delivery ?? NudgeDelivery(),
        _transcript = transcript ?? TranscriptStore.instance(),
        _emergency = emergency ?? EmergencyPhraseService(),
        _tts = tts ?? SafeTtsOutput.instance();

  static const AppLogger _log = AppLogger('Trigger');

  final SuggestionService _suggestions;
  final OutputModeSelector _modes;
  final NudgeDelivery _delivery;
  final TranscriptStore _transcript;
  final EmergencyPhraseService _emergency;
  final SafeTtsOutput _tts;

  /// Suggestion Engine (UI/test đọc được: bộ nhớ phiên, số lần fallback cache offline...).
  SuggestionService get suggestions => _suggestions;

  /// Bộ chọn chế độ hiển thị (Settings đọc/ghi qua đây — không tự mở `ConfigStore` ở tầng UI).
  OutputModeSelector get outputModes => _modes;

  /// **Điểm vào DUY NHẤT** cho mọi nguồn Push. Không bao giờ ném.
  Future<TriggerOutcome> onSuggestRequested({
    SuggestTriggerSource source = SuggestTriggerSource.floatingButton,
  }) async {
    // 1) Mốc Push (P1E) — prompt khung cần nó để suy ra lượt nói của người dùng vừa kết thúc quanh
    //    đó. Ghi mốc lỗi KHÔNG được chặn việc xin gợi ý.
    try {
      await _transcript.markPushMoment(DateTime.now());
    } catch (error) {
      _log.warn('không ghi được mốc Push: $error');
    }

    // 2) Suggestion Engine (đã có Policy chặn cứng + debounce + fallback cache offline bên trong).
    //    Log chỉ ghi `logLabel` (loại/nguồn), KHÔNG ghi nội dung nudge — xem `TriggerOutcome.toString`.
    final SuggestionResult result = await _suggestions.pushFromState();
    if (!result.isNudge) {
      _log.info('trigger ${source.logName}: ${result.logLabel}');
      return TriggerOutcome(
        source: source,
        result: result,
        effectiveMode: EffectiveNudgeOutput.text,
        delivery: null,
      );
    }

    // 3) Chọn chế độ có hiệu lực (Ear hạ xuống chữ khi không có tai nghe) + tốc độ đọc đã cấu hình.
    final NudgeOutputMode mode = await _modes.read();
    final double speechRate = await _modes.readSpeechRate();
    await _tts.refresh();
    final EffectiveNudgeOutput effective = OutputModeSelector.effectiveMode(
      mode,
      headsetAvailable: _tts.state == TtsOutputState.ready,
    );

    // 4) Giao nudge.
    final NudgeDeliveryResult delivery = await _delivery.deliver(
      text: result.text!,
      via: effective,
      speechRate: speechRate,
    );
    _log.info(
      'trigger ${source.logName}: ${result.logLabel} · chế độ ${mode.storageValue}'
      '${effective == EffectiveNudgeOutput.ear ? ' (${speechRate.toStringAsFixed(2)}x)' : ' → ${effective.name}'}'
      ' · giao: ${delivery.name}',
    );
    return TriggerOutcome(
      source: source,
      result: result,
      effectiveMode: effective,
      delivery: delivery,
    );
  }

  /// Gesture giữ nút nổi `TriggerConfig.emergencyHold` (2 giây) (P3 task 2).
  ///
  /// Đường khẩn cấp: **không** qua LLM, **không** qua Policy (không được để "đang nói" hay
  /// "debounce" chặn câu thoát hiểm) — đi thẳng `EmergencyPhraseService` → `SafeTtsOutput`.
  Future<EmergencyTriggerResult> onEmergencyRequested() => _emergency.triggerEmergency();

  /// Câu thoát hiểm gần nhất (UI chẩn đoán/phản hồi).
  EmergencyPhraseService get emergency => _emergency;
}
