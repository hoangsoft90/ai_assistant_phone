import 'package:flutter/services.dart' show HapticFeedback;

import '../core/app_logger.dart';
import 'output_mode_selector.dart';
import 'tts/safe_tts_output.dart';

/// Cách một nudge đã được giao cho người dùng (để log + hiện trên màn hình chẩn đoán).
enum NudgeDeliveryResult {
  /// Đã đưa cho native TTS đọc qua tai nghe.
  spoken,

  /// Đã rung.
  vibrated,

  /// Chỉ hiện chữ (chế độ Silent, hoặc Ear bị hạ cấp vì không có tai nghe).
  textOnly,
}

/// Giao nudge theo chế độ đã chọn (P3 task 3).
///
/// **Bất biến an toàn:** lớp này **chỉ** được phát âm thanh qua [SafeTtsOutput] — không có đường
/// nào khác (ràng buộc xuyên phase từ P1F). Rung ở đây là rung **của app** (`HapticFeedback`), khác
/// với rung báo "không có tai nghe" do native `SafeTtsBridge` thực hiện trong `SafeTtsOutput`.
///
/// Không bao giờ ném: chế độ chữ luôn là đường lui cuối cùng (constraint P3 "Silent mode phải hoạt
/// động hoàn toàn không phụ thuộc mạng/pin").
class NudgeDelivery {
  NudgeDelivery({SafeTtsOutput? tts, Future<void> Function()? haptic})
      : _tts = tts ?? SafeTtsOutput.instance(),
        _haptic = haptic ?? _defaultHaptic;

  static const AppLogger _log = AppLogger('NudgeDelivery');

  final SafeTtsOutput _tts;
  final Future<void> Function() _haptic;

  /// Rung mặc định: **1 pattern chung cho mọi loại nudge** (prompt P3 task 3 cho phép MVP như vậy).
  static Future<void> _defaultHaptic() => HapticFeedback.mediumImpact();

  /// Giao [text] theo [via]. Trả về cách đã giao thật (đã tính cả trường hợp phải hạ cấp).
  ///
  /// [speechRate] chỉ có ý nghĩa ở chế độ đọc (đã cấu hình ở mục 4.8); các chế độ khác bỏ qua.
  Future<NudgeDeliveryResult> deliver({
    required String text,
    required EffectiveNudgeOutput via,
    double? speechRate,
  }) async {
    switch (via) {
      case EffectiveNudgeOutput.ear:
        return _speak(text, speechRate);
      case EffectiveNudgeOutput.haptic:
        return _vibrate();
      case EffectiveNudgeOutput.text:
        _log.info('nudge chỉ hiện dạng chữ (chế độ Silent)');
        return NudgeDeliveryResult.textOnly;
    }
  }

  Future<NudgeDeliveryResult> _speak(String text, double? speechRate) async {
    // `SafeTtsOutput.speak` đã fail-safe: tự kiểm tra tai nghe tươi, tự rung + phát notice chữ khi
    // không đọc được. Ở đây chỉ map kết quả sang cách giao thật.
    final TtsSpeakResult result = await _tts.speak(text, speechRate: speechRate);
    switch (result) {
      case TtsSpeakResult.started:
        return NudgeDeliveryResult.spoken;
      case TtsSpeakResult.skippedNoHeadset:
      case TtsSpeakResult.skippedNeedsConfirmation:
      case TtsSpeakResult.failed:
        // Đã có nudge chữ + (nếu là no-headset) rung từ SafeTtsOutput — không rung thêm lần nữa.
        return NudgeDeliveryResult.textOnly;
    }
  }

  Future<NudgeDeliveryResult> _vibrate() async {
    try {
      await _haptic();
      return NudgeDeliveryResult.vibrated;
    } catch (error) {
      // Không rung được (máy tắt haptic, không có view...) ⇒ vẫn còn chữ. Không được ném.
      _log.warn('không rung được nudge: $error');
      return NudgeDeliveryResult.textOnly;
    }
  }
}
