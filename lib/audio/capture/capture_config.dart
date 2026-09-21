/// Cấu hình và kiểu dữ liệu dùng chung cho tầng audio capture (P1A).
///
/// Quy ước: mọi hằng "ma thuật" liên quan capture nằm ở đây, không hardcode trong engine.
/// Chuẩn 16kHz / mono / PCM 16-bit là đầu vào bắt buộc của các ASR engine sẽ dùng ở P1C/P1D.
library;

/// Cấu hình capture — mẫu thô (raw PCM) từ mic điện thoại.
class CaptureConfig {
  /// Sample rate mong muốn (Hz). 16kHz là chuẩn đầu vào của PhoWhisper/Vosk.
  final int sampleRate;

  /// Số kênh: luôn 1 (mono).
  final int numChannels;

  /// Bit depth: luôn 16 (PCM 16-bit).
  final int bitsPerSample;

  /// Độ dài (ms) của một chunk phát ra stream. 20-30ms mượt cho VAD ở P1B
  /// (gợi ý kỹ thuật của prompt P1A); 100ms làm chunk nhỏ quá tốn overhead chạy Dart.
  final int chunkMs;

  const CaptureConfig({
    this.sampleRate = 16000,
    this.numChannels = 1,
    this.bitsPerSample = 16,
    this.chunkMs = 100,
  });

  /// Số byte mỗi mẫu (mono, 16-bit).
  int get bytesPerSample => bitsPerSample ~/ 8;

  /// Số byte mỗi khung chunkMs milliseconds.
  int get chunkBytes =>
      sampleRate * chunkMs ~/ 1000 * numChannels * bytesPerSample;

  @override
  String toString() =>
      'CaptureConfig($sampleRate Hz, mono, PCM$bitsPerSample, chunk=$chunkMs ms, chunkBytes=$chunkBytes)';
}

/// Trạng thái của audio capture.
enum CaptureStatus { idle, starting, capturing, error, stopped }

/// Lỗi của tầng capture, kèm nguồn gốc để UI hiển thị thông báo phù hợp.
sealed class CaptureError implements Exception {
  const CaptureError(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thiếu quyền RECORD_AUDIO (đã bị từ chối hoặc từ chối vĩnh viễn).
class CapturePermissionDenied extends CaptureError {
  const CapturePermissionDenied(super.message);
}

/// Không mở được mic (thiết bị chiếm mic, không hỗ trợ cấu hình, lỗi hệ thống...).
class CaptureUnavailable extends CaptureError {
  const CaptureUnavailable(super.message);
}

/// Lỗi xảy ra GIỮA lúc đang ghi (vd: AudioRecord.read trả mã lỗi).
/// Capture đã tự dừng sạch trước khi lỗi này được ném ra stream.
class CaptureFailed extends CaptureError {
  const CaptureFailed(super.message);
}
