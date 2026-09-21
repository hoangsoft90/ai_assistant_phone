import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../core/app_logger.dart';
import '../core/constants.dart';
import 'permission_gate.dart';

/// Callback chạy trong isolate riêng của foreground service.
///
/// BẮT BUỘC: hàm top-level + `@pragma('vm:entry-point')`, nếu không engine của isolate mới
/// sẽ không gọi được khi app ở nền.
@pragma('vm:entry-point')
void listeningTaskCallback() {
  FlutterForegroundTask.setTaskHandler(ListeningTaskHandler());
}

/// TaskHandler của P0.5: chỉ giữ service sống và cập nhật notification.
///
/// P1A sẽ là nơi bơm vòng đọc audio/VAD thật vào `onRepeatEvent` (mục 4.2 của kế hoạch).
/// Ở phase này KHÔNG được thêm logic audio — xem Constraints của `prompt_P0_5.md`.
class ListeningTaskHandler extends TaskHandler {
  static const AppLogger _log = AppLogger('ListeningTaskHandler');

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _log.info('service started (starter=${starter.name})');
    await FlutterForegroundTask.updateService(
      notificationTitle: ServiceConfig.notificationTitle,
      notificationText: ServiceConfig.notificationText,
    );
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // P0.5: cố ý không làm gì. Giữ chỗ cho vòng lặp audio/VAD của P1A-P1B.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _log.info('service destroyed (isTimeout=$isTimeout)');
  }
}

/// Bọc start/stop foreground service để tầng UI không phụ thuộc trực tiếp vào plugin.
abstract final class ListeningService {
  static const AppLogger _log = AppLogger('ListeningService');

  static bool _initialized = false;

  /// Khởi tạo cấu hình service. Gọi trước `start()` (đã gọi trong `main()`).
  static void init() {
    if (_initialized) {
      return;
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: ServiceConfig.channelId,
        channelName: ServiceConfig.channelName,
        channelDescription: ServiceConfig.channelDescription,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(ServiceConfig.repeatEventMs),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
        // Giữ service sống khi người dùng vuốt app khỏi recent apps: app này cần nghe liên tục,
        // và việc dừng service sẽ do người dùng chủ động bấm nút.
        stopWithTask: false,
      ),
    );
    _initialized = true;
    _log.info('đã init foreground task (channel=${ServiceConfig.channelId})');
  }

  static Future<bool> isRunning() => FlutterForegroundTask.isRunningService;

  /// Bật service. Trả về true nếu service thực sự đang chạy sau lệnh.
  static Future<bool> start() async {
    init();
    try {
      if (await FlutterForegroundTask.isRunningService) {
        _log.info('service đã chạy sẵn');
        return true;
      }

      final bool granted = await PermissionGate.ensureServicePermissions();
      if (!granted) {
        _log.warn('thiếu quyền RECORD_AUDIO — không thể bật service type=microphone');
        return false;
      }

      await FlutterForegroundTask.startService(
        serviceId: ServiceConfig.serviceId,
        serviceTypes: const <ForegroundServiceTypes>[ForegroundServiceTypes.microphone],
        notificationTitle: ServiceConfig.notificationTitle,
        notificationText: ServiceConfig.notificationText,
        callback: listeningTaskCallback,
      );

      final bool running = await FlutterForegroundTask.isRunningService;
      _log.info('startService -> running=$running');
      return running;
    } catch (error, stackTrace) {
      _log.error('startService lỗi', error, stackTrace);
      return false;
    }
  }

  /// Tắt service.
  static Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (error, stackTrace) {
      _log.error('stopService lỗi', error, stackTrace);
    }
  }
}
