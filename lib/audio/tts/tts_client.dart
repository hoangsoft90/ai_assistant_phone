/// Định nghĩa dữ liệu + hợp đồng client của tầng TTS (P1F).
///
/// Tách khỏi implementation (xem [TtsClient]) để [SafeTtsOutput] test được với client giả — không
/// cần máy thật. Hợp đồng phía Kotlin nằm ở
/// `android/app/src/main/kotlin/com/aiassistant/phone/tts/SafeTtsBridge.kt`.
library;

/// Một thiết bị output mà nếu phát vào đó thì **không** lọt ra loa ngoài (tai nghe có dây,
/// tai nghe Bluetooth A2DP, tai nghe BLE, USB headset, hearing aid).
///
/// Cố ý KHÔNG coi `TYPE_BLE_SPEAKER`/loa ngoài là hợp lệ; SCO (HFP) cũng không — xem ghi chú
/// trong `SafeTtsBridge.kt`.
class TtsDevice {
  const TtsDevice({required this.type, this.name});

  /// Hằng `AudioDeviceInfo.TYPE_*` của Android (giữ nguyên số để Dart không phải sao chép enum).
  final int type;

  final String? name;

  @override
  String toString() => 'TtsDevice(type=$type, name=$name)';
}

/// Trạng thái thiết bị output tại **thời điểm hỏi** (native đọc tươi, không cache).
class TtsOutputInfo {
  const TtsOutputInfo({required this.hasPrivateOutput, this.preferred, this.devices = const <TtsDevice>[]});

  /// `true` = có ít nhất một tai nghe đang kết nối ⇒ được phép phát TTS.
  final bool hasPrivateOutput;

  /// Thiết bị sẽ được route tường minh (ưu tiên A2DP).
  final TtsDevice? preferred;

  final List<TtsDevice> devices;

  @override
  String toString() =>
      'TtsOutputInfo(hasPrivateOutput=$hasPrivateOutput, preferred=$preferred, devices=${devices.length})';
}

/// Loại sự kiện native bắn lên.
enum TtsEventType {
  /// Có thêm tai nghe (rút dây/cắm lại, bật Bluetooth...).
  headsetFound,

  /// MẤT tai nghe (đây là sự kiện nguy hiểm nhất — native đã dừng phát trước khi bắn).
  headsetLost,

  /// Đã phát xong một câu.
  spoke,

  /// Lỗi từ native (tổng hợp hoặc phát).
  error,
}

/// Sự kiện native → Dart.
class TtsEvent {
  const TtsEvent({required this.type, this.wasPlaying = false, this.message, this.state});

  final TtsEventType type;

  /// Với [TtsEventType.headsetLost]: lúc mất tai nghe có đang phát/tổng hợp không.
  final bool wasPlaying;

  final String? message;
  final TtsOutputInfo? state;

  @override
  String toString() => 'TtsEvent($type, wasPlaying=$wasPlaying, message=$message)';
}

/// Trạng thái mà native trả về cho một lần yêu cầu phát.
enum TtsNativeSpeakStatus {
  /// Native đã bắt đầu tổng hợp; phát xong sẽ báo qua sự kiện `spoke`.
  synthesizing,

  /// Native từ chối vì không còn tai nghe (native đã rung báo). Không có gì được phát.
  noHeadset,

  /// Native báo lỗi (hoặc trả về giá trị không nhận ra) ⇒ không có gì được phát.
  error,
}

class TtsNativeSpeakResult {
  const TtsNativeSpeakResult(this.status, [this.detail]);

  final TtsNativeSpeakStatus status;
  final String? detail;

  @override
  String toString() => 'TtsNativeSpeakResult($status, detail=$detail)';
}

/// Hợp đồng của lớp client gọi native — tách khỏi implementation để [SafeTtsOutput] test được
/// mà không cần kênh thật (cùng mẫu với `CaptureClient` của P1A).
abstract class TtsClient {
  /// Đọc **tươi** trạng thái thiết bị output. Ném `FormatException` nếu native trả sai dạng
  /// (lỗi hợp đồng — phải lộ ra trong test); [SafeTtsOutput] sẽ bắt và coi như "không có tai nghe".
  Future<TtsOutputInfo> outputState();

  /// Yêu cầu native phát [text]. Native **kiểm tra lại thiết bị** một lần nữa trước khi tổng hợp.
  ///
  /// [rate] — tốc độ đọc (đã chuẩn hoá về 0.9-1.2 ở tầng trên). `null` ⇒ **không gửi** tham số tốc độ:
  /// native giữ tốc độ đang đặt của engine (mặc định của engine nếu chưa từng đặt) — đường cũ của
  /// P1F vẫn nguyên vẹn nếu caller không quan tâm tốc độ.
  Future<TtsNativeSpeakResult> speak(String text, {double? rate});

  /// Dừng ngay mọi thứ đang tổng hợp/đang phát. Trả `true` nếu trước đó thực sự có phát.
  Future<bool> stop();

  /// Rung 1 nhịp ngắn để báo "không đọc được vì không có tai nghe" (nhánh nudge chữ).
  Future<void> vibrateFallback();

  /// Đăng ký handler nhận sự kiện từ native. Chỉ giữ **MỘT** handler (hợp đồng kênh native chỉ có
  /// một `setMethodCallHandler`); truyền `null` để gỡ.
  void onEvent(void Function(TtsEvent event)? handler);
}
