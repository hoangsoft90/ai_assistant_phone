// Test tầng an toàn TTS (P1F) bằng client giả.
//
// Đây là phase an toàn quan trọng nhất của app, nên test khoá đúng các BẤT BIẾN (không chỉ "chạy
// không lỗi"): không có tai nghe ⇒ KHÔNG được gọi phát; lỗi ⇒ KHÔNG được gọi phát; mất tai nghe
// giữa chừng ⇒ im lặng; kết nối lại ⇒ KHÔNG tự phát lại (chờ xác nhận).
//
// Test này KHÔNG chứng minh được "không lọt ra loa ngoài" trên máy thật — việc đó phải làm bằng 3
// test case bắt buộc với logcat/dumpsys (xem `.plan/P1F-result.md`).

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/audio/tts/safe_tts_output.dart';
import 'package:ai_assistant_phone/audio/tts/tts_channels.dart';
import 'package:ai_assistant_phone/audio/tts/tts_client.dart';

/// Client giả: không cần kênh native, ghi lại mọi lời gọi để khẳng định "đã KHÔNG gọi phát".
class FakeTtsClient implements TtsClient {
  FakeTtsClient({
    this.hasOutput = false,
    this.speakOutcome = 'synthesizing',
    this.outputStateThrows = false,
    this.speakThrows = false,
    this.deviceName = 'Tai nghe test',
    this.deviceType = 8, // AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
  });

  bool hasOutput;
  String speakOutcome;
  bool outputStateThrows;
  bool speakThrows;
  String deviceName;
  int deviceType;

  final List<String> speakCalls = <String>[];
  int stopCalls = 0;
  int vibrateCalls = 0;
  int outputStateCalls = 0;

  void Function(TtsEvent event)? _handler;

  void emit(TtsEvent event) => _handler?.call(event);

  @override
  Future<TtsOutputInfo> outputState() async {
    outputStateCalls++;
    if (outputStateThrows) {
      throw StateError('kênh native chết');
    }
    return TtsOutputInfo(
      hasPrivateOutput: hasOutput,
      preferred: hasOutput ? TtsDevice(type: deviceType, name: deviceName) : null,
    );
  }

  @override
  Future<TtsNativeSpeakResult> speak(String text) async {
    speakCalls.add(text);
    if (speakThrows) {
      throw StateError('kênh native chết khi speak');
    }
    return speakResultFromNative(speakOutcome);
  }

  @override
  Future<bool> stop() async {
    stopCalls++;
    return true;
  }

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
  group('SafeTtsOutput — không có tai nghe thì tuyệt đối không phát', () {
    test('trạng thái ban đầu là unknown (chưa hỏi native lần nào)', () {
      final SafeTtsOutput tts = SafeTtsOutput(client: FakeTtsClient());
      expect(tts.state, TtsOutputState.unknown);
    });

    test('refresh(): native báo có tai nghe ⇒ ready', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: true);
      final SafeTtsOutput tts = SafeTtsOutput(client: client);

      await tts.refresh();

      expect(tts.state, TtsOutputState.ready);
      expect(tts.lastInfo?.preferred?.name, 'Tai nghe test');
    });

    test('speak() khi KHÔNG có tai nghe: không gọi native speak, có rung + nudge chữ', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: false);
      final SafeTtsOutput tts = SafeTtsOutput(client: client);
      final List<TtsFallbackNotice> notices = <TtsFallbackNotice>[];
      tts.fallbacks.listen(notices.add);

      final TtsSpeakResult result = await tts.speak('xin chào');

      expect(result, TtsSpeakResult.skippedNoHeadset);
      // Bất biến quan trọng nhất của P1F (task 1): không có tai nghe ⇒ KHÔNG gọi speak.
      expect(client.speakCalls, isEmpty);
      expect(client.vibrateCalls, 1);
      expect(tts.state, TtsOutputState.silent);
      await Future<void>.delayed(Duration.zero);
      expect(notices.single.kind, TtsFallbackKind.noHeadset);
    });

    test('speak() khi đọc trạng thái thiết bị LỖI ⇒ coi như không có tai nghe (fail-safe)', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: true, outputStateThrows: true);
      final SafeTtsOutput tts = SafeTtsOutput(client: client);

      final TtsSpeakResult result = await tts.speak('xin chào');

      expect(result, TtsSpeakResult.skippedNoHeadset);
      expect(client.speakCalls, isEmpty);
      expect(tts.state, TtsOutputState.silent);
    });

    test('speak() khi có tai nghe: gọi native đúng 1 lần ⇒ started', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: true);
      final SafeTtsOutput tts = SafeTtsOutput(client: client);

      final TtsSpeakResult result = await tts.speak('xin chào');

      expect(result, TtsSpeakResult.started);
      expect(client.speakCalls, <String>['xin chào']);
      expect(tts.isSpeaking, isTrue);
    });

    test('speak() với text rỗng: không gọi native', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: true);
      final SafeTtsOutput tts = SafeTtsOutput(client: client);

      expect(await tts.speak('   '), TtsSpeakResult.failed);
      expect(client.speakCalls, isEmpty);
    });
  });

  group('SafeTtsOutput — native từ chối/lỗi thì im lặng, không thử lại', () {
    test('native trả "noHeadset" (Dart đọc trước đó đã cũ) ⇒ chuyển im lặng', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: true, speakOutcome: 'noHeadset');
      final SafeTtsOutput tts = SafeTtsOutput(client: client);

      final TtsSpeakResult result = await tts.speak('xin chào');

      expect(result, TtsSpeakResult.skippedNoHeadset);
      expect(tts.state, TtsOutputState.silent);
      expect(tts.isSpeaking, isFalse);
    });

    test('native trả "error:..." ⇒ failed, không ném ra ngoài', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: true, speakOutcome: 'error:code=-1');
      final SafeTtsOutput tts = SafeTtsOutput(client: client);

      expect(await tts.speak('xin chào'), TtsSpeakResult.failed);
      expect(tts.isSpeaking, isFalse);
    });

    test('native trả giá trị lạ ⇒ failed (không đoán là thành công)', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: true, speakOutcome: 'lạ hoắc');
      final SafeTtsOutput tts = SafeTtsOutput(client: client);

      expect(await tts.speak('xin chào'), TtsSpeakResult.failed);
    });

    test('native ném exception ⇒ failed (không bao giờ ném ra ngoài)', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: true, speakThrows: true);
      final SafeTtsOutput tts = SafeTtsOutput(client: client);

      expect(await tts.speak('xin chào'), TtsSpeakResult.failed);
      expect(tts.isSpeaking, isFalse);
    });
  });

  group('SafeTtsOutput — mất tai nghe giữa chừng và kết nối lại', () {
    test('headsetLost: im lặng ngay, gọi stop lớp thứ 2, phát nudge chữ', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: true);
      final SafeTtsOutput tts = SafeTtsOutput(client: client);
      final List<TtsFallbackNotice> notices = <TtsFallbackNotice>[];
      tts.fallbacks.listen(notices.add);
      await tts.speak('xin chào');

      client.emit(const TtsEvent(type: TtsEventType.headsetLost, wasPlaying: true));
      await Future<void>.delayed(Duration.zero);

      expect(tts.state, TtsOutputState.silent);
      expect(tts.isSpeaking, isFalse);
      expect(tts.needsConfirmation, isTrue);
      expect(client.stopCalls, greaterThanOrEqualTo(1));
      expect(notices.last.kind, TtsFallbackKind.headsetLost);
    });

    test('sau headsetLost: speak() KHÔNG gọi native (không tự phát lại)', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: true);
      final SafeTtsOutput tts = SafeTtsOutput(client: client);
      client.emit(const TtsEvent(type: TtsEventType.headsetLost, wasPlaying: false));
      await Future<void>.delayed(Duration.zero);

      final TtsSpeakResult result = await tts.speak('xin chào');

      expect(result, TtsSpeakResult.skippedNeedsConfirmation);
      expect(client.speakCalls, isEmpty);
    });

    test('headsetFound (kết nối lại): vẫn im lặng, phải chờ xác nhận (task 3)', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: false);
      final SafeTtsOutput tts = SafeTtsOutput(client: client);
      client.emit(const TtsEvent(type: TtsEventType.headsetLost, wasPlaying: false));
      client.emit(
        const TtsEvent(
          type: TtsEventType.headsetFound,
          state: TtsOutputInfo(hasPrivateOutput: true),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(tts.state, TtsOutputState.silent);
      expect(tts.needsConfirmation, isTrue);
      expect(await tts.speak('xin chào'), TtsSpeakResult.skippedNeedsConfirmation);
      expect(client.speakCalls, isEmpty);
    });

    test('confirmHeadsetReady() khi tai nghe đã có ⇒ cho phép phát lại', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: true);
      final SafeTtsOutput tts = SafeTtsOutput(client: client);
      client.emit(const TtsEvent(type: TtsEventType.headsetLost, wasPlaying: false));
      await Future<void>.delayed(Duration.zero);
      client.emit(const TtsEvent(type: TtsEventType.headsetFound));
      await Future<void>.delayed(Duration.zero);

      await tts.confirmHeadsetReady();

      expect(tts.needsConfirmation, isFalse);
      expect(tts.state, TtsOutputState.ready);
      expect(await tts.speak('xin chào'), TtsSpeakResult.started);
      expect(client.speakCalls, <String>['xin chào']);
    });

    test('confirmHeadsetReady() khi KHÔNG có tai nghe ⇒ vẫn im lặng', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: false);
      final SafeTtsOutput tts = SafeTtsOutput(client: client);
      client.emit(const TtsEvent(type: TtsEventType.headsetLost, wasPlaying: false));
      await Future<void>.delayed(Duration.zero);

      await tts.confirmHeadsetReady();

      expect(tts.state, TtsOutputState.silent);
      expect(await tts.speak('xin chào'), TtsSpeakResult.skippedNoHeadset);
      expect(client.speakCalls, isEmpty);
    });

    test('event "spoke" kết thúc trạng thái đang đọc', () async {
      final FakeTtsClient client = FakeTtsClient(hasOutput: true);
      final SafeTtsOutput tts = SafeTtsOutput(client: client);
      await tts.speak('xin chào');
      expect(tts.isSpeaking, isTrue);

      client.emit(const TtsEvent(type: TtsEventType.spoke));
      expect(tts.isSpeaking, isFalse);
    });
  });

  group('Hợp đồng kênh native (parse)', () {
    test('infoFromNative: đọc đúng map của native', () {
      final TtsOutputInfo info = infoFromNative(<Object?, Object?>{
        'hasPrivateOutput': true,
        'preferred': <Object?, Object?>{'id': 3, 'type': 8, 'name': 'WH-1000XM3', 'address': 'AC:12'},
        'devices': <Object?>[
          <Object?, Object?>{'id': 3, 'type': 8, 'name': 'WH-1000XM3', 'address': 'AC:12'},
          <Object?, Object?>{'id': 4, 'type': 22, 'name': 'Tai nghe dây', 'address': ''},
        ],
      });

      expect(info.hasPrivateOutput, isTrue);
      expect(info.preferred?.name, 'WH-1000XM3');
      // Native vẫn gửi id/address (dùng cho logcat), nhưng Dart chỉ giữ thứ có người đọc.
      expect(info.devices, hasLength(2));
      expect(info.devices.last.name, 'Tai nghe dây');
    });

    test('infoFromNative: dữ liệu sai dạng ⇒ FormatException (lỗi hợp đồng, phải lộ ra)', () {
      expect(() => infoFromNative('không phải map'), throwsFormatException);
    });

    test('speakResultFromNative: null (thiếu native) ⇒ error, KHÔNG phải thành công', () {
      expect(speakResultFromNative(null).status, TtsNativeSpeakStatus.error);
      expect(speakResultFromNative('synthesizing').status, TtsNativeSpeakStatus.synthesizing);
      expect(speakResultFromNative('noHeadset').status, TtsNativeSpeakStatus.noHeadset);
      expect(speakResultFromNative('error:xyz').status, TtsNativeSpeakStatus.error);
    });

    test('eventFromNative: sự kiện sai dạng được coi là headsetLost (hướng an toàn)', () {
      expect(eventFromNative(42).type, TtsEventType.headsetLost);
      expect(eventFromNative(null).type, TtsEventType.headsetLost);
    });

    test('eventFromNative: đọc đủ 4 loại sự kiện', () {
      expect(eventFromNative(<Object?, Object?>{'type': 'headsetFound'}).type, TtsEventType.headsetFound);
      expect(
        eventFromNative(<Object?, Object?>{'type': 'headsetLost', 'wasPlaying': true}).wasPlaying,
        isTrue,
      );
      expect(eventFromNative(<Object?, Object?>{'type': 'spoke'}).type, TtsEventType.spoke);
      expect(eventFromNative(<Object?, Object?>{'type': 'error'}).type, TtsEventType.error);
      expect(eventFromNative(<Object?, Object?>{'type': 'lạ'}).type, TtsEventType.headsetLost);
    });
  });
}
