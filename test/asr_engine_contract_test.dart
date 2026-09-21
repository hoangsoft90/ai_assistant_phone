// Test P1D — HỢP ĐỒNG `AsrEngine`: chạy CÙNG một bộ test cho cả hai engine để chứng minh chúng
// hoán đổi được cho nhau (DoD P1D: "VoskAsrEngine hoạt động đúng interface").
//
// Không test phần inference thật (cần máy thật) — chỉ test phần Dart: init trước feed, stream kết
// quả, dispose idempotent, và không phát text rỗng vào stream.

import 'dart:async';

import 'package:ai_assistant_phone/audio/asr/asr_engine.dart';
import 'package:ai_assistant_phone/audio/asr/phowhisper_asr_engine.dart';
import 'package:ai_assistant_phone/audio/asr/vosk_asr_engine.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// PCM16 mono 16kHz tĩnh (giá trị mẫu cố định): 1 giây = 32000 byte.
Uint8List _pcmBytes(int seconds, int value) {
  final Uint8List bytes = Uint8List(seconds * 32000);
  for (int i = 0; i + 1 < bytes.length; i += 2) {
    bytes[i] = value & 0xFF;
    bytes[i + 1] = (value >> 8) & 0xFF;
  }
  return bytes;
}

/// Một engine + cách mô phỏng native trả kết quả + cách đọc số chunk đã gửi.
class _EngineUnderTest {
  _EngineUnderTest({
    required this.name,
    required this.channelName,
    required this.create,
    required this.pushNativeTranscript,
    required this.feedCalls,
  });

  final String name;
  final String channelName;
  final AsrEngine Function() create;

  /// Gọi vào đường xử lý native-call của engine (mô phỏng native chủ động gọi về).
  final Future<void> Function(AsrEngine engine, Map<String, Object?> payload)
      pushNativeTranscript;

  /// Số lời gọi 'feed' đã đi qua kênh (để chứng minh hành vi gom chunk khác nhau vẫn đúng hợp đồng).
  final int Function() feedCalls;
}

_FakeChannel? _active;

/// Stub kênh của MỘT engine, ghi lại lời gọi và trả lời như native.
class _FakeChannel {
  _FakeChannel(this.channelName) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(channelName),
            (MethodCall call) async {
      calls.add(call);
      switch (call.method) {
        case 'loadModel':
        case 'feed':
        case 'releaseModel':
          return null;
        default:
          throw MissingPluginException();
      }
    });
  }

  final String channelName;
  final List<MethodCall> calls = <MethodCall>[];

  int get feedCalls =>
      calls.where((MethodCall call) => call.method == 'feed').length;

  void close() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(channelName), null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<_EngineUnderTest> engines = <_EngineUnderTest>[
    _EngineUnderTest(
      name: 'PhoWhisperAsrEngine',
      // Kênh của PhoWhisper do P1C đặt tên là `AsrChannels` (xem phowhisper_asr_engine.dart).
      channelName: AsrChannels.control,
      create: () => PhoWhisperAsrEngine(),
      pushNativeTranscript: (AsrEngine engine, Map<String, Object?> payload) async {
        await (engine as PhoWhisperAsrEngine)
            .debugHandleNativeCall(MethodCall('transcript', payload));
      },
      feedCalls: () => _active!.feedCalls,
    ),
    _EngineUnderTest(
      name: 'VoskAsrEngine',
      channelName: VoskChannels.control,
      create: () => VoskAsrEngine(),
      pushNativeTranscript: (AsrEngine engine, Map<String, Object?> payload) async {
        await (engine as VoskAsrEngine)
            .debugHandleNativeCall(MethodCall('transcript', payload));
      },
      feedCalls: () => _active!.feedCalls,
    ),
  ];

  for (final _EngineUnderTest spec in engines) {
    group('hợp đồng AsrEngine — ${spec.name}', () {
      tearDown(() {
        _active?.close();
        _active = null;
      });

      test('implements AsrEngine', () {
        expect(spec.create(), isA<AsrEngine>());
      });

      test('feedAudioChunk trước init() ném StateError', () {
        final AsrEngine engine = spec.create();
        expect(() => engine.feedAudioChunk(_pcmBytes(1, 0)), throwsStateError);
      });

      test('init() gọi loadModel đúng 1 lần (gọi lại là no-op)', () async {
        _active = _FakeChannel(spec.channelName);
        final AsrEngine engine = spec.create();
        await engine.init();
        final int after = _active!.calls.length;
        await engine.init();
        expect(_active!.calls.length, after, reason: 'init lần 2 không gọi lại native');
        await engine.dispose();
      });

      test('dispose() idempotent và feed sau dispose là no-op an toàn', () async {
        _active = _FakeChannel(spec.channelName);
        final AsrEngine engine = spec.create();
        await engine.init();
        await engine.dispose();
        await engine.dispose(); // Không ném.
        final int after = _active!.calls.length;
        await engine.feedAudioChunk(_pcmBytes(2, 1));
        expect(_active!.calls.length, after, reason: 'sau dispose không gửi audio nữa');
      });

      test('text rỗng/toàn khoảng trắng KHÔNG phát vào transcriptStream', () async {
        _active = _FakeChannel(spec.channelName);
        final AsrEngine engine = spec.create();
        await engine.init();
        final List<String> received = <String>[];
        final StreamSubscription<String> sub = engine.transcriptStream.listen(received.add);

        await spec.pushNativeTranscript(engine, <String, Object?>{
          'text': '   ',
          'latencyMs': 10,
          'audioMs': 4000,
          'dropped': 0,
        });
        await Future<void>.delayed(Duration.zero);
        expect(received, isEmpty);

        await sub.cancel();
        await engine.dispose();
      });

      test('kết quả native → transcriptStream (trim) + droppedTotal cập nhật', () async {
        _active = _FakeChannel(spec.channelName);
        final AsrEngine engine = spec.create();
        await engine.init();
        final Completer<String> done = Completer<String>();
        final StreamSubscription<String> sub = engine.transcriptStream.listen(done.complete);

        await spec.pushNativeTranscript(engine, <String, Object?>{
          'text': '  xin chào  ',
          'latencyMs': 120,
          'audioMs': 4000,
          'dropped': 3,
        });
        expect(await done.future.timeout(const Duration(seconds: 2)), 'xin chào');
        expect(engine.droppedTotal, 3);

        await sub.cancel();
        await engine.dispose();
      });

      test('KHÔNG có tham số nhãn người nói trong payload gửi đi (ràng buộc xuyên phase)', () async {
        _active = _FakeChannel(spec.channelName);
        final AsrEngine engine = spec.create();
        await engine.init();
        await engine.feedAudioChunk(_pcmBytes(4, 5));
        final MethodCall feed =
            _active!.calls.firstWhere((MethodCall call) => call.method == 'feed');
        final Map<Object?, Object?> args = feed.arguments as Map<Object?, Object?>;
        expect(args.keys, contains('pcm16'));
        expect(args.keys.map((Object? k) => k.toString()).join(','), isNot(contains('speaker')));
      });
    });
  }

  // Ghi chú khác biệt CÓ CHỦ Ý giữa 2 engine, khoá bằng test để không bị "sửa nhầm cho giống nhau":
  group('khác biệt có chủ ý giữa hai engine', () {
    tearDown(() {
      _active?.close();
      _active = null;
    });

    test('PhoWhisper gom 4s mới gửi 1 chunk; Vosk gửi từng chunk ngay (streaming)', () async {
      // PhoWhisper: 3 chunk 100ms = 0.3s < 4s → chưa gửi gì.
      _active = _FakeChannel(AsrChannels.control);
      final PhoWhisperAsrEngine whisper = PhoWhisperAsrEngine();
      await whisper.init();
      for (int i = 0; i < 3; i++) {
        await whisper.feedAudioChunk(Uint8List(3200)); // 100ms mỗi chunk.
      }
      expect(_active!.feedCalls, 0, reason: 'chưa đủ 4s nên chưa gửi');
      await whisper.dispose();
      _active!.close();

      // Vosk: mỗi chunk gửi ngay.
      _active = _FakeChannel(VoskChannels.control);
      final VoskAsrEngine vosk = VoskAsrEngine();
      await vosk.init();
      for (int i = 0; i < 3; i++) {
        await vosk.feedAudioChunk(Uint8List(3200));
      }
      expect(_active!.feedCalls, 3, reason: 'Vosk là streaming: gửi ngay từng chunk');
      expect(vosk.chunksSent, 3);
      await vosk.dispose();
    });

    test('Vosk bỏ qua chunk rỗng (không gọi native)', () async {
      _active = _FakeChannel(VoskChannels.control);
      final VoskAsrEngine vosk = VoskAsrEngine();
      await vosk.init();
      await vosk.feedAudioChunk(Uint8List(0));
      expect(_active!.feedCalls, 0);
      await vosk.dispose();
    });
  });

  group('MetaConfigStore — hợp đồng ConfigStore', () {
    test('MetaConfigStore implements ConfigStore (chưa chạm SQLite ở test này)', () {
      expect(const MetaConfigStore(), isA<ConfigStore>());
    });
  });
}
