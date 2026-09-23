// Smoke test: khung app dựng được và màn hình chính có nút điều khiển service.
//
// Trong môi trường test không có plugin native, nên mọi MethodChannel của plugin được stub để
// trả về null. Nhờ vậy test này chỉ kiểm tra phần UI/Dart, không phụ thuộc máy thật.
// Logic thật (service, DB, quyền) phải được kiểm trên thiết bị — xem README.md ở gốc repo.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Scrollable;
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
      // P1D — ASR dự phòng Vosk (xem lib/audio/asr/vosk_asr_engine.dart).
      'com.aiassistant.phone/vosk',
      // P1F — TTS an toàn (xem lib/audio/tts/tts_channels.dart).
      'com.aiassistant.phone/tts',
    ];
    for (final String name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (MethodCall call) async => null);
    }
  });

  testWidgets('màn hình chính dựng được và có nút bật lắng nghe', (WidgetTester tester) async {
    await tester.pumpWidget(const AiAssistantApp());
    await tester.pump();

    // P7 mục 4: lần mở app ĐẦU TIÊN (mock trả null ⇒ chưa từng xác nhận) phải hiện lời nhắc
    // đạo đức. barrierDismissible:false ⇒ phải bấm "Tôi hiểu" trước khi tương tác gì khác
    // (modal barrier chặn drag — scrollUntilVisible sẽ chết nếu chưa đóng dialog).
    for (int i = 0; i < 6 && find.text('Tôi hiểu').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.text('Trước khi dùng'), findsOneWidget);
    await tester.tap(find.text('Tôi hiểu'));
    await tester.pumpAndSettle();
    expect(find.text('Trước khi dùng'), findsNothing);

    expect(find.text('Trợ lý giao tiếp'), findsOneWidget);
    expect(find.text('Bật lắng nghe'), findsOneWidget);
    expect(find.text('Sẵn sàng'), findsOneWidget);
    // Từ P1G màn hình có thêm nút Emergency + 1 dòng trạng thái ⇒ card trạng thái dài hơn viewport
    // và ListView dựng lazily — phải CUỘN tới các dòng trạng thái thay vì giả định chúng hiển thị sẵn.
    await tester.scrollUntilVisible(find.text('chưa ghi'), 120, scrollable: find.byType(Scrollable).first);
    await tester.pump();
    expect(find.text('chưa ghi'), findsOneWidget); // trạng thái capture ban đầu (P1A)
    await tester.scrollUntilVisible(find.text('chưa nghe'), 120, scrollable: find.byType(Scrollable).first);
    await tester.pump();
    expect(find.text('chưa nghe'), findsOneWidget); // trạng thái VAD ban đầu (P1B)
  });
}
