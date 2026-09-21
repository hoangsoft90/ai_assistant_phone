import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'audio/app_audio_session.dart';
import 'core/app_logger.dart';
import 'core/constants.dart';
import 'services/foreground_service.dart';
import 'services/storage/app_database.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const AppLogger log = AppLogger('main');

  // Phải gọi TRƯỚC runApp: mở port để TaskHandler (chạy ở isolate riêng) trao đổi dữ liệu với UI.
  FlutterForegroundTask.initCommunicationPort();
  ListeningService.init();

  // Dựng hạ tầng ở đây; lỗi từng mảnh chỉ ghi log chứ không làm app chết — mục tiêu của P0.5 là
  // xác nhận app chạy được trên máy thật và trạng thái từng mảnh hiện được trên màn hình chính.
  try {
    await AppAudioSession.configure();
  } catch (error, stackTrace) {
    log.error('cấu hình audio session lỗi', error, stackTrace);
  }
  try {
    await AppDatabase.instance();
  } catch (error, stackTrace) {
    log.error('mở SQLite lỗi', error, stackTrace);
  }

  log.info('bootstrap xong, khởi động UI');
  runApp(const AiAssistantApp());
}

/// Widget gốc của app.
class AiAssistantApp extends StatelessWidget {
  const AiAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppInfo.displayName,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      home: const HomeScreen(),
    );
  }
}
