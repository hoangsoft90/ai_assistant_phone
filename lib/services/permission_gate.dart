import 'package:permission_handler/permission_handler.dart';

import '../core/app_logger.dart';

/// Xin và kiểm tra các quyền runtime cần để foreground service `type=microphone` chạy được,
/// cộng quyền Bluetooth mà P1F cần (`BLUETOOTH_CONNECT` — đọc trạng thái tai nghe/route).
///
/// Vì sao cần ngay ở P0.5 (dù chưa ghi âm thật):
/// - Từ Android 14, muốn start foreground service type `microphone` thì app phải đang giữ
///   quyền `RECORD_AUDIO` — thiếu là service không bật được (runtime requirement của hệ thống).
/// - Từ Android 13, notification của foreground service chỉ hiện khi đã được cấp
///   `POST_NOTIFICATIONS`.
/// Cả hai đều là điều kiện của DoD P0.5 ("service chạy được, hiện notification"), nên việc xin
/// quyền là plumbing bắt buộc, không phải logic audio.
abstract final class PermissionGate {
  static const AppLogger _log = AppLogger('PermissionGate');

  /// Xin quyền. Trả về true nếu đã có `RECORD_AUDIO` (điều kiện bắt buộc để start service).
  ///
  /// `BLUETOOTH_CONNECT` (Android 12+) được xin ở đây vì P1F cần nó để đọc/điều khiển thiết bị
  /// Bluetooth; **không** phải điều kiện bật service (thiếu quyền này app vẫn nghe được, chỉ là
  /// đường phát TTS an toàn không đọc được trạng thái tai nghe ⇒ sẽ từ chối phát, hướng an toàn).
  static Future<bool> ensureServicePermissions() async {
    final PermissionStatus microphone = await Permission.microphone.request();
    final PermissionStatus notification = await Permission.notification.request();
    final PermissionStatus bluetooth = await Permission.bluetoothConnect.request();
    _log.info('quyền: microphone=${microphone.name}, notification=${notification.name}, '
        'bluetoothConnect=${bluetooth.name}');
    return microphone.isGranted;
  }

  /// Trạng thái hiện tại để hiển thị trên UI (không xin gì thêm).
  static Future<Map<String, bool>> currentStatus() async => <String, bool>{
        'microphone': await Permission.microphone.isGranted,
        'notification': await Permission.notification.isGranted,
        'bluetoothConnect': await Permission.bluetoothConnect.isGranted,
      };
}
