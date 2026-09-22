import '../../core/app_logger.dart';
import '../tts/safe_tts_output.dart';
import 'emergency_phrases.dart';

/// Kết quả một lần kích hoạt Emergency Phrase.
enum EmergencyTriggerResult {
  /// Đã yêu cầu native phát (câu được chọn). Việc có nghe thấy hay không phụ thuộc
  /// [SafeTtsOutput] — nếu tai nghe rút giữa chừng, SafeTtsOutput tự dừng + rung (P1F).
  started,

  /// Không phát vì không có tai nghe — đã rung báo + nudge chữ (đúng hành vi P1F).
  skippedNoHeadset,

  /// Không phát vì tai nghe vừa kết nối lại mà chưa được xác nhận (đúng hành vi P1F).
  skippedNeedsConfirmation,

  /// Lỗi — im lặng, KHÔNG thử lại (fail-safe của P1F).
  failed,
}

/// **Emergency Phrase (P1G)** — câu thoát khẩn cấp phát ngay khi kích hoạt.
///
/// Vì sao tồn tại (plan_final_v2.md mục 4.11): đây là lúc cần phản hồi tức thời nhất, không thể
/// chờ roundtrip mạng 1–2 giây của LLM. Vì vậy đường này:
/// - **KHÔNG** gọi bất kỳ network call, LLM call hay Suggestion Policy nào (Constraint của prompt
///   P1G) — chỉ chọn 1 câu trong danh sách cố định rồi gọi thẳng [SafeTtsOutput];
/// - **tuân thủ toàn bộ logic an toàn của P1F**: không có tai nghe ⇒ không phát gì, chỉ rung +
///   nudge chữ; mất tai nghe giữa chừng ⇒ SafeTtsOutput tự dừng + rung.
///
/// Cách chọn câu: **xoay vòng** (câu 1 → 2 → 3 → 1 → …). Lý do chọn xoay vòng thay vì ngẫu nhiên:
/// dự đoán được (người dùng quen nhịp sau vài lần), không bao giờ lặp liền 2 lần cùng câu khi số
/// câu ≥ 2, và không cần nguồn random — một dependency ít hơn cho đường khẩn cấp.
///
/// P3 sẽ gọi [triggerEmergency] khi gesture thật xảy ra (giữ nút nổi 2 giây); ở P1G chỉ có nút
/// tạm trên màn hình chẩn đoán để kiểm trên máy thật.
class EmergencyPhraseService {
  EmergencyPhraseService({SafeTtsOutput? tts, List<String>? phrases})
      : _tts = tts ?? SafeTtsOutput.instance(),
        _phrases = _validPhrases(phrases ?? emergencyPhrases);

  static const AppLogger _log = AppLogger('EmergencyPhrase');

  final SafeTtsOutput _tts;

  /// Danh sách câu thoát (đã lọc rỗng). Nếu sau khi lọc rỗng vẫn trống ⇒ mọi trigger là lỗi cấu
  /// hình (im lặng + log) — KHÔNG fallback sang câu hardcode khác để không phát nội dung người
  /// dùng không biết nguồn gốc.
  final List<String> _phrases;

  /// Câu kế tiếp sẽ phát (chỉ số xoay vòng).
  int _next = 0;

  /// Đo độ trễ của lần trigger gần nhất: khoảng thời gian từ lúc gọi [triggerEmergency] đến khi
  /// native xác nhận đã bắt đầu tổng hợp (chưa tính thời gian TTS đọc câu — đúng định nghĩa DoD
  /// của prompt P1G). `null` = chưa trigger lần nào hoặc lần gần nhất không phát được.
  Duration? lastTriggerToSynthLatency;

  /// Câu của lần trigger gần nhất (`null` = chưa trigger lần nào) — để UI hiện bằng chứng
  /// "đã phát đúng câu thuộc danh sách" trên máy thật mà không cần đọc logcat.
  String? lastPhrase;

  /// Câu sẽ được phát ở lần trigger kế tiếp (để UI hiện/để test không phụ thuộc trạng thái nội bộ).
  String get nextPhrase => _phrases.isEmpty ? '' : _phrases[_next % _phrases.length];

  /// Kích hoạt câu thoát khẩn cấp. Không bao giờ ném ra ngoài — mọi lỗi thành [EmergencyTriggerResult.failed].
  ///
  /// Không đo/ghi gì ngoài [lastTriggerToSynthLatency]; không đụng capture, transcript hay bất kỳ
  /// mảng nào khác của app (cách ly hoàn toàn — prompt P1G: "đường tắt hoàn toàn riêng biệt").
  Future<EmergencyTriggerResult> triggerEmergency() async {
    final DateTime t0 = DateTime.now();
    if (_phrases.isEmpty) {
      _log.error('danh sách câu thoát rỗng — không phát gì');
      return EmergencyTriggerResult.failed;
    }
    final String phrase = _phrases[_next % _phrases.length];
    _next = (_next + 1) % _phrases.length;
    lastPhrase = phrase;
    try {
      final TtsSpeakResult result = await _tts.speak(phrase);
      final Duration latency = DateTime.now().difference(t0);
      _log.info('emergency: "$phrase" → $result · độ trễ tới khi native bắt đầu tổng hợp: ${latency.inMilliseconds}ms');
      lastTriggerToSynthLatency = switch (result) {
        TtsSpeakResult.started => latency,
        // Không phát được thì không có "độ trễ phát" để báo — ghi null cho lần này.
        _ => null,
      };
      return switch (result) {
        TtsSpeakResult.started => EmergencyTriggerResult.started,
        TtsSpeakResult.skippedNoHeadset => EmergencyTriggerResult.skippedNoHeadset,
        TtsSpeakResult.skippedNeedsConfirmation => EmergencyTriggerResult.skippedNeedsConfirmation,
        TtsSpeakResult.failed => EmergencyTriggerResult.failed,
      };
    } catch (error, stackTrace) {
      // Fail-safe: đường khẩn cấp không được phép crash app, cũng KHÔNG thử lại.
      _log.error('emergency trigger lỗi — KHÔNG phát', error, stackTrace);
      return EmergencyTriggerResult.failed;
    }
  }

  static List<String> _validPhrases(List<String> raw) =>
      raw.where((String p) => p.trim().isNotEmpty).toList(growable: false);
}
