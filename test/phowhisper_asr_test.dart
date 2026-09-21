// Test P1C — PhoWhisperAsrEngine (thuần Dart, stub MethodChannel; phần native đo trên CI/máy
// thật — xem .plan/P1C-result.md).

import 'dart:async';

import 'package:ai_assistant_phone/audio/asr/asr_engine.dart';
import 'package:ai_assistant_phone/audio/asr/phowhisper_asr_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// PCM16 mono 16kHz tĩnh: 1 giây = 32000 byte.
Uint8List _pcmSeconds(int seconds, int value) {
  final Uint8List bytes = Uint8List(seconds * 32000);
  for (int i = 0; i + 1 < bytes.length; i += 2) {
    bytes[i] = value & 0xFF;
    bytes[i + 1] = (value >> 8) & 0xFF;
  }
  return bytes;
}

/// Stub kênh ASR ghi lại mọi lời gọi; có thể mô phỏng native gọi ngược 'transcript'.
class _FakeAsrChannel {
  _FakeAsrChannel(this.onFeed) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(AsrChannels.control),
            (MethodCall call) async {
      calls.add(call);
      switch (call.method) {
        case 'loadModel':
          return null;
        case 'feed':
          onFeed(call);
          return null;
        case 'releaseModel':
          return null;
        default:
          throw MissingPluginException();
      }
    });
  }

  final List<MethodCall> calls = <MethodCall>[];

  /// Được gọi khi Dart gửi 'feed' — mô phỏng phía native (thường là gọi ngược 'transcript').
  final void Function(MethodCall call) onFeed;

  void close() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(AsrChannels.control), null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AsrEngine — hợp đồng interface (khoá chữ ký prompt P1C)', () {
    test('PhoWhisperAsrEngine implements AsrEngine', () {
      final PhoWhisperAsrEngine engine = PhoWhisperAsrEngine();
      expect(engine, isA<AsrEngine>());
    });

    test('feedAudioChunk trước init() ném StateError (hợp đồng)', () async {
      final PhoWhisperAsrEngine engine = PhoWhisperAsrEngine();
      expect(
        () => engine.feedAudioChunk(_pcmSeconds(1, 0)),
        throwsStateError,
      );
    });
  });

  group('PhoWhisperAsrEngine — accumulator', () {
    late _FakeAsrChannel channel;
    late PhoWhisperAsrEngine engine;

    setUp(() {
      channel = _FakeAsrChannel((MethodCall _) {}); // feed: không làm gì.
      engine = PhoWhisperAsrEngine();
    });

    tearDown(() async {
      await engine.dispose();
      channel.close();
    });

    test('gom đúng 4s mới gửi đi 1 chunk; phần dư giữ lại (không mất mẫu)', () async {
      await engine.init();
      await engine.feedAudioChunk(_pcmSeconds(3, 100)); // 3s — chưa đủ.
      expect(channel.calls.where((MethodCall c) => c.method == 'feed'), isEmpty);
      expect(engine.pendingBytes, 3 * 32000);

      await engine.feedAudioChunk(_pcmSeconds(2, 100)); // +2s → đủ 4s, dư 1s.
      final List<MethodCall> feeds =
          channel.calls.where((MethodCall c) => c.method == 'feed').toList();
      expect(feeds, hasLength(1));
      final Uint8List sent = feeds.single.arguments['pcm16'] as Uint8List;
      expect(sent.length, 4 * 32000); // 4s đúng.
      expect(engine.pendingBytes, 1 * 32000); // 1s dư giữ lại.
    });

    test('6s một phát: gửi 1 chunk 4s, giữ 2s', () async {
      await engine.init();
      await engine.feedAudioChunk(_pcmSeconds(6, 200));
      final List<MethodCall> feeds =
          channel.calls.where((MethodCall c) => c.method == 'feed').toList();
      expect(feeds, hasLength(1));
      expect((feeds.single.arguments['pcm16'] as Uint8List).length, 4 * 32000);
      expect(engine.pendingBytes, 2 * 32000);
    });

    test('9s một phát: gửi 2 chunk (4s + 4s), giữ 1s', () async {
      await engine.init();
      await engine.feedAudioChunk(_pcmSeconds(9, 300));
      final List<MethodCall> feeds =
          channel.calls.where((MethodCall c) => c.method == 'feed').toList();
      expect(feeds, hasLength(2));
      expect(engine.pendingBytes, 1 * 32000);
    });

    test('init() hai lần là no-op (idempotent)', () async {
      await engine.init();
      final int callsAfterFirst = channel.calls.length;
      await engine.init();
      expect(channel.calls.length, callsAfterFirst);
    });

    test('dispose xong thì feedAudioChunk là no-op an toàn', () async {
      await engine.init();
      await engine.dispose();
      // Không ném (đã _disposed), không gọi feed nữa.
      final int calls = channel.calls.length;
      await engine.feedAudioChunk(_pcmSeconds(1, 0));
      expect(channel.calls.length, calls);
    });
  });

  group('PhoWhisperAsrEngine — transcriptStream', () {
    test('native gọi ngược "transcript" → text phát ra stream (đã trim)', () async {
      final PhoWhisperAsrEngine engine = PhoWhisperAsrEngine();
      final _FakeAsrChannel channel = _FakeAsrChannel((MethodCall call) {
        // Mô phỏng native: sau khi nhận 'feed', gọi ngược 'transcript' như thật.
        engine.debugHandleNativeCall(const MethodCall('transcript', <String, Object?>{
          'text': '  xin chào  ',
          'latencyMs': 120,
          'audioMs': 4000,
          'dropped': 2,
        }));
      });
      await engine.init();

      final Completer<String> done = Completer<String>();
      final StreamSubscription<String> sub =
          engine.transcriptStream.listen(done.complete);
      await engine.feedAudioChunk(_pcmSeconds(4, 100));
      final String text = await done.future.timeout(const Duration(seconds: 2));
      expect(text, 'xin chào'); // Đã trim.
      expect(engine.droppedTotal, 2); // dropped từ payload được tích.

      await sub.cancel();
      await engine.dispose();
      channel.close();
    });

    test('payload rỗng/trắng KHÔNG phát vào stream', () async {
      final PhoWhisperAsrEngine engine = PhoWhisperAsrEngine();
      final _FakeAsrChannel channel = _FakeAsrChannel((MethodCall _) {
        engine.debugHandleNativeCall(const MethodCall('transcript', <String, Object?>{
          'text': '   ',
          'latencyMs': 50,
          'audioMs': 4000,
          'dropped': 0,
        }));
      });
      await engine.init();

      final List<String> received = <String>[];
      final StreamSubscription<String> sub =
          engine.transcriptStream.listen(received.add);
      await engine.feedAudioChunk(_pcmSeconds(4, 100));
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty, reason: 'text trắng không được phát');

      await sub.cancel();
      await engine.dispose();
      channel.close();
    });
  });
}
