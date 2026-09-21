import 'dart:async';
import 'dart:typed_data';

import 'capture_config.dart';

/// Bìa đế cho các engine capture cụ thể.
///
/// Hợp đồng (bắt buộc cho MỌI implementation — xem `.project/architecture.md`):
/// - `chunks` phát các chunk PCM16 mono (byte) liên tục sau `start()` thành công.
/// - Chunk phát ra là **bản copy riêng** — bên nhận an toàn giữ tham chiếu lâu (vd: xếp hàng
///   cho ASR) mà không bị engine ghi đè.
/// - **Lỗi runtime KHÔNG đi qua stream** (stream chỉ phát dữ liệu). Lỗi có 2 loại:
///   - Lỗi khi `start()`: ném trực tiếp dưới dạng `CaptureError` (async error của Future).
///   - Lỗi giữa lúc ghi: báo qua callback `onError` (đăng ký 1 lần), engine **tự dừng sạch**
///     trước khi gọi callback, và `status` chuyển sang `CaptureStatus.error`.
/// - Gọi `start()` khi đang capturing là no-op an toàn (trả về trạng thái hiện tại).
/// - Gọi `stop()` khi chưa chạy là no-op an toàn.
/// - Sau `stop()`, engine PHẢI có thể `start()` lại được (tái sử dụng cùng instance).
/// - `dispose()` giải phóng tài nguyên vĩnh viễn; sau đó KHÔNG dùng nữa.
abstract class AudioCaptureEngine {
  /// Chunk audio thô (PCM16 mono) theo thời gian thực.
  ///
  /// Stream KHÔNG phát lỗi — lỗi runtime giữa lúc ghi được báo qua [onError] và [status]
  /// chuyển sang `CaptureStatus.error` (engine tự dừng sạch trước khi báo).
  Stream<Uint8List> get chunks;

  /// Trạng thái hiện tại của capture. Phát mỗi khi trạng thái đổi.
  Stream<CaptureStatus> get status;

  /// Đăng ký handler nhận lỗi runtime giữa lúc ghi (vd: AudioRecord.read trả mã lỗi).
  ///
  /// Hợp đồng: **chỉ một handler duy nhất** — đăng ký lần sau ghi đè lần trước (native
  /// method-call handler không hỗ trợ nhiều listener như broadcast stream). Lỗi khi
  /// `start()` thì KHÔNG đi qua đây mà ném trực tiếp từ `start()`.
  void onError(void Function(CaptureError error) handler);

  /// Số byte PCM đã thu kể từ lần `start()` cuối — để test/đo (DoD: stream hoạt động đúng).
  int get capturedBytes;

  /// Bắt đầu capture. Trả về cấu hình thực tế được dùng (device có thể áp sample rate khác).
  ///
  /// Ném `CapturePermissionDenied` nếu thiếu quyền mic, `CaptureUnavailable` nếu không mở
  /// được mic. Nếu đang capturing, trả về cấu hình hiện tại không làm gì cả.
  Future<CaptureConfig> start();

  /// Dừng capture sạch (nếu đang chạy). No-op nếu chưa chạy.
  Future<void> stop();

  /// Giải phóng tài nguyên vĩnh viễn. Sau khi gọi, KHÔNG dùng engine này nữa.
  Future<void> dispose();
}
