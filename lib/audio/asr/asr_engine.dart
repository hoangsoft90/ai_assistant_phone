import 'dart:async';
import 'dart:typed_data';

/// Interface chung cho mọi ASR engine của app (P1C — theo đúng chữ ký trong
/// `.plan/prompt_P1C.md`).
///
/// Hợp đồng bắt buộc (P1D sẽ viết `VoskAsrEngine` cắm vào cùng interface, không sửa tầng trên):
/// - Gọi `init()` **trước** khi feed audio; sau khi `dispose()` thì KHÔNG dùng lại.
/// - [feedAudioChunk] nhận chunk PCM16 **mono 16kHz** (byte, little-endian) — đúng định dạng
///   chunk phát ra từ `lib/audio/capture/` (P1A).
/// - Kết quả nhận dạng phát qua [transcriptStream]; engine KHÔNG phát lỗi vào stream — lỗi
///   nghiêm trọng (không init được model...) phải ném từ `init()`.
/// - **KHÔNG** gắn nhãn người nói ở bất kỳ tầng nào (ràng buộc xuyên phase — mục 4.2b).
/// - **KHÔNG** gọi API cloud nào (ràng buộc xuyên phase — chiều thu 100% offline).
abstract class AsrEngine {
  /// Nạp model vào bộ nhớ (có thể mất vài giây tuỳ model). Ném lỗi nếu không init được.
  Future<void> init();

  /// Text nhận dạng được, phát mỗi khi một đoạn audio được xử lý xong.
  Stream<String> get transcriptStream;

  /// Đưa một chunk PCM16 mono 16kHz vào engine. Engine tự gom thành đoạn dài hơn (3–5s) trước
  /// khi chạy nhận dạng; gọi trước `init()` là vi phạm hợp đồng.
  Future<void> feedAudioChunk(Uint8List chunk);

  /// Giải phóng model + mọi tài nguyên. Sau khi gọi, KHÔNG dùng engine này nữa.
  Future<void> dispose();

  /// Số chunk đã bị BỎ (không xử lý) vì engine không theo kịp thời gian thực.
  ///
  /// KHÔNG thuộc hợp đồng bắt buộc — đây là số đo phục vụ DoD (P1C/P1D) và UI chẩn đoán; engine
  /// nào không đo được thì để mặc định 0. Cả hai engine hiện có đều đã override getter này.
  int get droppedTotal => 0;
}
