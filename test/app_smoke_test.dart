// Smoke test: khung app dựng được và màn hình chính có nút điều khiển service.
//
// Trong môi trường test không có plugin native, nên mọi MethodChannel của plugin được stub để
// trả về null. Nhờ vậy test này chỉ kiểm tra phần UI/Dart, không phụ thuộc máy thật.
// Logic thật (service, DB, quyền) phải được kiểm trên thiết bị — xem README.md ở gốc repo.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const List<String> channels = <String>[
      'flutter_foreground_task/methods',
      'com.tekartik.sqflite',
      'plugins.it_nomads.com/flutter_secure_storage',
      'flutter.baseflow.com/permissions/methods',
      // P1A — audio capture (xem lib/audio/capture/capture_channels.dart).
      // Thêm kênh mới vào đây, nếu không test widget sẽ đỏ vì thiếu native.
      'com.aiassistant.phone/audio_capture',
      'com.aiassistant.phone/audio_capture_pcm',
      // P1B — VAD (xem lib/audio/vad/vad_client.dart).
      'com.aiassistant.phone/vad',
      // P1C — ASR (xem lib/audio/asr/phowhisper_asr_engine.dart).
      'com.aiassistant.phone/asr',
    ];
    for (final String name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (MethodCall call) async => null);
    }
  });

  testWidgets('màn hình chính dựng được và có nút bật lắng nghe', (WidgetTester tester) async {
    await tester.pumpWidget(const AiAssistantApp());
    await tester.pump();

    expect(find.text('Trợ lý giao tiếp'), findsOneWidget);
    expect(find.text('Bật lắng nghe'), findsOneWidget);
    expect(find.text('Sẵn sàng'), findsOneWidget);
    expect(find.text('chưa ghi'), findsOneWidget); // trạng thái capture ban đầu (P1A)
    expect(find.text('chưa nghe'), findsOneWidget); // trạng thái VAD ban đầu (P1B)
  });
}
