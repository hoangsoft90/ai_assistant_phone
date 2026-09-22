import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/audio/emergency/emergency_phrase_service.dart';
import 'package:ai_assistant_phone/audio/emergency/emergency_phrases.dart';
import 'package:ai_assistant_phone/audio/tts/safe_tts_output.dart';
import 'package:ai_assistant_phone/audio/tts/tts_client.dart';

/// Client giả cho test P1G — cùng mẫu `_FakeTtsClient` của `safe_tts_output_test.dart`:
/// không đụng kênh native, điều khiển trực tiếp trạng thái tai nghe + ghi lại mọi lời gọi.
class _FakeTtsClient implements TtsClient {
  _FakeTtsClient({this.hasHeadset = true});

  bool hasHeadset;
  bool throwOnSpeak = false;
  int speakCalls = 0;
  int vibrateCalls = 0;
  final List<String> spokenTexts = <String>[];

  void Function(TtsEvent event)? _handler;

  /// Giả lập native bắn sự kiện mất tai nghe (đang phát ⇒ `wasPlaying: true`).
  void fireHeadsetLost() {
    _handler?.call(const TtsEvent(type: TtsEventType.headsetLost, wasPlaying: true));
  }

  @override
  Future<TtsOutputInfo> outputState() async =>
      TtsOutputInfo(hasPrivateOutput: hasHeadset, preferred: hasHeadset ? const TtsDevice(type: 4) : null);

  @override
  Future<TtsNativeSpeakResult> speak(String text) async {
    speakCalls++;
    spokenTexts.add(text);
    if (throwOnSpeak) {
      throw StateError('kênh TTS chết (giả lập)');
    }
    return hasHeadset
        ? const TtsNativeSpeakResult(TtsNativeSpeakStatus.synthesizing)
        : const TtsNativeSpeakResult(TtsNativeSpeakStatus.noHeadset);
  }

  @override
  Future<bool> stop() async => false;

  @override
  Future<void> vibrateFallback() async {
    vibrateCalls++;
  }

  @override
  void onEvent(void Function(TtsEvent event)? handler) {
    _handler = handler;
  }
}

void main() {
  test('danh sách câu thoát mặc định: 3–5 câu, không câu rỗng (prompt P1G task 1)', () {
    expect(emergencyPhrases.length, inInclusiveRange(3, 5));
    expect(emergencyPhrases.every((String p) => p.trim().isNotEmpty), isTrue);
  });

  test('triggerEmergency phát đúng câu thuộc danh sách và XOAY VÒNG', () async {
    final _FakeTtsClient client = _FakeTtsClient();
    final EmergencyPhraseService service = EmergencyPhraseService(tts: SafeTtsOutput(client: client));

    for (int i = 0; i < emergencyPhrases.length + 1; i++) {
      final EmergencyTriggerResult result = await service.triggerEmergency();
      expect(result, EmergencyTriggerResult.started);
      // Câu phát ra LUÔN là một phần tử của danh sách (không bao giờ phát nội dung lạ).
      expect(emergencyPhrases.contains(client.spokenTexts[i]), isTrue);
      expect(client.spokenTexts[i], emergencyPhrases[i % emergencyPhrases.length]);
      expect(service.lastPhrase, client.spokenTexts[i]);
    }
    expect(client.speakCalls, emergencyPhrases.length + 1);
  });

  test('đo độ trễ trigger → native bắt đầu tổng hợp (DoD mục 2)', () async {
    final _FakeTtsClient client = _FakeTtsClient();
    final EmergencyPhraseService service = EmergencyPhraseService(tts: SafeTtsOutput(client: client));

    expect(service.lastTriggerToSynthLatency, isNull); // chưa trigger lần nào
    await service.triggerEmergency();
    expect(service.lastTriggerToSynthLatency, isNotNull);
    // Môi trường giả là gọi tức thời ⇒ độ trễ đo được phải nhỏ hơn ngưỡng lý tưởng 200ms
    // (prompt P1G: "< 200ms lý tưởng"). Trên máy thật con số này được đọc từ log/dòng Emergency.
    expect(service.lastTriggerToSynthLatency!.inMilliseconds, lessThan(200));
  });

  test('không có tai nghe ⇒ KHÔNG gọi native speak, có rung, không có "độ trễ phát" (DoD mục 3)', () async {
    final _FakeTtsClient client = _FakeTtsClient(hasHeadset: false);
    final EmergencyPhraseService service = EmergencyPhraseService(tts: SafeTtsOutput(client: client));

    final EmergencyTriggerResult result = await service.triggerEmergency();

    expect(result, EmergencyTriggerResult.skippedNoHeadset);
    expect(client.speakCalls, 0); // fail-safe của P1F: không có tai nghe thì KHÔNG gọi phát
    expect(client.vibrateCalls, 1); // đúng hành vi P1F: rung 1 nhịp + nudge chữ
    expect(service.lastTriggerToSynthLatency, isNull);
    expect(service.lastPhrase, isNotNull); // vẫn biết câu đã định phát (cho UI/log)
  });

  test('mất tai nghe rồi (chưa xác nhận lại) ⇒ skippedNeedsConfirmation, KHÔNG phát', () async {
    final _FakeTtsClient client = _FakeTtsClient();
    final EmergencyPhraseService service = EmergencyPhraseService(tts: SafeTtsOutput(client: client));

    await service.triggerEmergency(); // lần đầu phát được
    client.fireHeadsetLost(); // mất tai nghe giữa chừng → SafeTtsOutput vào chế độ im lặng

    final EmergencyTriggerResult result = await service.triggerEmergency();

    expect(result, EmergencyTriggerResult.skippedNeedsConfirmation);
    expect(client.speakCalls, 1); // không tăng — KHÔNG phát lần thứ hai
  });

  test('client lỗi ⇒ failed, không ném ra ngoài, KHÔNG thử lại', () async {
    final _FakeTtsClient client = _FakeTtsClient()..throwOnSpeak = true;
    final EmergencyPhraseService service = EmergencyPhraseService(tts: SafeTtsOutput(client: client));

    final EmergencyTriggerResult result = await service.triggerEmergency();

    expect(result, EmergencyTriggerResult.failed);
    expect(client.speakCalls, 1); // đúng 1 lần — đường khẩn cấp không retry (fail-safe P1F)
  });

  test('phần tử rỗng trong danh sách cấu hình bị lọc bỏ', () async {
    final _FakeTtsClient client = _FakeTtsClient();
    final EmergencyPhraseService service = EmergencyPhraseService(
      tts: SafeTtsOutput(client: client),
      phrases: <String>['Câu A', '  ', 'Câu B'],
    );

    await service.triggerEmergency();
    await service.triggerEmergency();
    await service.triggerEmergency();

    expect(client.spokenTexts, <String>['Câu A', 'Câu B', 'Câu A']);
  });

  test('danh sách cấu hình toàn rỗng ⇒ failed, không phát gì (không fallback câu lạ)', () async {
    final _FakeTtsClient client = _FakeTtsClient();
    final EmergencyPhraseService service = EmergencyPhraseService(
      tts: SafeTtsOutput(client: client),
      phrases: <String>['', '   '],
    );

    expect(await service.triggerEmergency(), EmergencyTriggerResult.failed);
    expect(client.speakCalls, 0);
  });
}
