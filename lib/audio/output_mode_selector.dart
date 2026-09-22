import '../core/app_logger.dart';
import '../core/constants.dart';
import '../services/storage/meta_store.dart';

/// Ba chế độ hiển thị nudge (P3 mục 4.8).
enum NudgeOutputMode {
  /// Đọc qua tai nghe bằng `SafeTtsOutput`. **Tự động hạ xuống [silent]** khi không có tai nghe —
  /// không phải người dùng chọn, mà là ràng buộc an toàn.
  ear('ear', 'Tai nghe (đọc)'),

  /// Rung theo pattern (MVP: 1 pattern chung cho mọi loại nudge).
  haptic('haptic', 'Rung'),

  /// Chỉ hiện chữ trên UI — chốt an toàn cuối cùng: không mạng, không âm thanh, không rung.
  silent('silent', 'Chỉ hiện chữ');

  const NudgeOutputMode(this.storageValue, this.label);

  /// Giá trị lưu trong bảng `meta` (ổn định — đừng đổi, người dùng đã có cấu hình trên máy).
  final String storageValue;

  /// Nhãn hiển thị.
  final String label;

  static NudgeOutputMode? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    final String normalized = raw.trim().toLowerCase();
    for (final NudgeOutputMode mode in NudgeOutputMode.values) {
      if (mode.storageValue == normalized) {
        return mode;
      }
    }
    return null;
  }
}

/// Chế độ output đang có hiệu lực sau khi đã tính điều kiện thực tế.
enum EffectiveNudgeOutput {
  /// Đọc qua tai nghe (chỉ khi tai nghe đang dùng được).
  ear,

  /// Rung.
  haptic,

  /// Chỉ chữ.
  text,
}

/// Đọc/ghi + quyết định chế độ hiển thị nudge (P3 task 3).
///
/// Vì sao tách khỏi `NudgeDelivery`: lớp này chỉ quyết định **chế độ nào** (thuần logic + cấu hình,
/// test được không cần thiết bị), còn lớp giao thật (gọi `SafeTtsOutput`/rung) nằm ở
/// `nudge_delivery.dart`.
class OutputModeSelector {
  OutputModeSelector({ConfigStore? store})
      : _store = store ?? const MetaConfigStore();

  static const AppLogger _log = AppLogger('OutputMode');

  final ConfigStore _store;

  /// Chế độ người dùng đã chọn (mặc định [NudgeOutputMode.ear] — đúng mục đích app: nghe trong tai).
  ///
  /// *Vì sao mặc định KHÔNG phải `silent`*: mục 4.8 gọi silent là chế độ an toàn nhất **khi mọi thứ
  /// khác lỗi**, và Ear đã tự hạ xuống silent khi thiếu tai nghe ⇒ để mặc định `silent` sẽ làm app
  /// cài xong không bao giờ đọc gì cho tới khi người dùng tự đổi. Chế độ an toàn vẫn được đảm bảo
  /// bằng [effectiveMode], không bằng giá trị mặc định.
  static const NudgeOutputMode defaultMode = NudgeOutputMode.ear;

  /// Đọc cấu hình đã lưu; lỗi/giá trị lạ ⇒ về mặc định (không ném — cấu hình hỏng không được làm
  /// chết đường gợi ý).
  Future<NudgeOutputMode> read() async {
    try {
      final String? raw = await _store.read(OutputConfig.modeKey);
      return NudgeOutputMode.tryParse(raw) ?? defaultMode;
    } catch (error) {
      _log.warn('không đọc được chế độ output — dùng mặc định ${defaultMode.storageValue}: $error');
      return defaultMode;
    }
  }

  Future<void> write(NudgeOutputMode mode) async {
    try {
      await _store.write(OutputConfig.modeKey, mode.storageValue);
    } catch (error) {
      _log.warn('không lưu được chế độ output: $error');
    }
  }

  /// Tốc độ đọc TTS đã lưu (mục 4.8: 0.9x-1.2x, mặc định 1.05x).
  ///
  /// Giá trị hỏng/ngoài khoảng đều được chuẩn hoá về khoảng hợp lệ
  /// ([OutputConfig.clampSpeechRate]) — không ném, không để lọt số lạ xuống native.
  Future<double> readSpeechRate() async {
    try {
      final String? raw = await _store.read(OutputConfig.speechRateKey);
      final double? parsed = raw == null ? null : double.tryParse(raw.trim());
      if (parsed == null) {
        return OutputConfig.defaultSpeechRate;
      }
      final double clamped = OutputConfig.clampSpeechRate(parsed);
      if (clamped != parsed) {
        _log.warn('tốc độ đọc đã lưu ngoài khoảng ($parsed) ⇒ dùng $clamped');
      }
      return clamped;
    } catch (error) {
      _log.warn('không đọc được tốc độ đọc TTS — dùng mặc định: $error');
      return OutputConfig.defaultSpeechRate;
    }
  }

  Future<void> writeSpeechRate(double rate) async {
    try {
      await _store.write(
        OutputConfig.speechRateKey,
        OutputConfig.clampSpeechRate(rate).toStringAsFixed(2),
      );
    } catch (error) {
      _log.warn('không lưu được tốc độ đọc TTS: $error');
    }
  }

  /// Chế độ có hiệu lực ngay lúc này.
  ///
  /// [headsetAvailable] phải là trạng thái **tươi** của `SafeTtsOutput` (`state == ready`) —
  /// nếu chưa xác định được thì truyền `false` (hướng an toàn: hạ xuống chế độ chữ).
  static EffectiveNudgeOutput effectiveMode(
    NudgeOutputMode mode, {
    required bool headsetAvailable,
  }) {
    switch (mode) {
      case NudgeOutputMode.ear:
        // Mục 4.8: "Ear chỉ khả dụng khi tai nghe connected, tự động hạ xuống Silent nếu không".
        return headsetAvailable ? EffectiveNudgeOutput.ear : EffectiveNudgeOutput.text;
      case NudgeOutputMode.haptic:
        return EffectiveNudgeOutput.haptic;
      case NudgeOutputMode.silent:
        return EffectiveNudgeOutput.text;
    }
  }
}
