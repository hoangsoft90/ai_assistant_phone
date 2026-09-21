import 'dart:async';
import 'dart:typed_data';

import 'capture_config.dart';

/// Hợp đồng của lớp client gọi native — tách khỏi implementation để controller test được
/// mà không cần kênh thật.
///
/// Hợp đồng với phía native (Kotlin) được ghi ở [CaptureChannels] và trong
/// `android/app/src/main/kotlin/com/aiassistant/phone/audio/CaptureChannelBridge.kt`.
abstract class CaptureClient {
  /// Xin native mở mic với cấu hình mong muốn, trả về cấu hình **thực tế** được dùng.
  ///
  /// Phải ném `PlatformException` với `code` là `PERMISSION_DENIED` hoặc `UNAVAILABLE`
  /// khi thất bại (controller map sang [CaptureError] tương ứng).
  Future<CaptureConfig> startNative(CaptureConfig config);

  /// Báo native dừng ghi (giữ engine sống để start lại sau).
  Future<void> stopNative();

  /// Báo native giải phóng toàn bộ tài nguyên (AudioRecord.release).
  Future<void> disposeNative();

  /// Đăng ký handler nhận lỗi runtime từ native. Chỉ giữ MỘT handler duy nhất.
  void onError(void Function(CaptureError error) handler);

  /// Stream chunk PCM16 mono (byte) từ native.
  Stream<Uint8List> pcmChunks();
}
