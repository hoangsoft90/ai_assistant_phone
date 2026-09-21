import 'dart:developer' as developer;

/// Mức log của app.
enum LogLevel { debug, info, warn, error }

/// Logger dùng chung cho mọi tầng.
///
/// Lý do tồn tại: (1) không dùng `print` (lint `avoid_print`), (2) khi cần đổi nơi ghi log
/// (ghi file, gửi đi đâu đó) thì chỉ sửa một chỗ, (3) log qua `dart:developer` nên xem được
/// bằng `adb logcat` khi chạy trên máy thật.
class AppLogger {
  const AppLogger(this.tag);

  final String tag;

  void debug(String message) => _log(LogLevel.debug, message);

  void info(String message) => _log(LogLevel.info, message);

  void warn(String message, [Object? error]) => _log(LogLevel.warn, message, error);

  void error(String message, [Object? error, StackTrace? stackTrace]) =>
      _log(LogLevel.error, message, error, stackTrace);

  void _log(LogLevel level, String message, [Object? error, StackTrace? stackTrace]) {
    developer.log(
      message,
      name: '$tag/${level.name}',
      level: _levelValue(level),
      error: error,
      stackTrace: stackTrace,
    );
  }

  int _levelValue(LogLevel level) => switch (level) {
        LogLevel.debug => 500,
        LogLevel.info => 800,
        LogLevel.warn => 900,
        LogLevel.error => 1000,
      };
}
