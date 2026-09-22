// Test P1D — `AsrEngineSelector`: đổi engine qua config (DoD: "đổi engine qua config mà không cần
// sửa code các tầng trên") + fallback tự động khi `init()` thất bại.

import 'dart:async';
import 'dart:typed_data';

import 'package:ai_assistant_phone/audio/asr/asr_engine.dart';
import 'package:ai_assistant_phone/audio/asr/asr_engine_selector.dart';
import 'package:ai_assistant_phone/audio/asr/phowhisper_asr_engine.dart';
import 'package:ai_assistant_phone/audio/asr/vosk_asr_engine.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bản giả trong bộ nhớ — thay cho SQLite (sqflite cần platform channel, không dùng được ở unit test).
class _MemoryStore implements ConfigStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

/// Engine giả: `init()` thành công hoặc ném lỗi theo cấu hình; ghi lại việc dispose.
class _FakeEngine implements AsrEngine {
  _FakeEngine({this.failInit = false});

  final bool failInit;
  final StreamController<String> _stream = StreamController<String>.broadcast();
  bool initialized = false;
  int disposeCount = 0;

  @override
  int get droppedTotal => 0;

  @override
  Future<void> init() async {
    if (failInit) {
      throw StateError('init giả lập thất bại (ví dụ hết RAM)');
    }
    initialized = true;
  }

  @override
  Stream<String> get transcriptStream => _stream.stream;

  @override
  Future<void> feedAudioChunk(Uint8List chunk) async {}

  @override
  Future<void> dispose() async {
    disposeCount++;
    await _stream.close();
  }
}

void main() {
  group('AsrEngineSelector — đọc/ghi cấu hình', () {
    test('chưa có cấu hình → engine mặc định (PhoWhisper)', () async {
      final AsrEngineSelector selector = AsrEngineSelector(_MemoryStore());
      expect(await selector.readConfigured(), AsrEngineSelector.defaultKind);
      expect(AsrEngineSelector.defaultKind, AsrEngineKind.phoWhisper);
    });

    test('ghi rồi đọc lại đúng engine (khoá cấu hình ổn định)', () async {
      final _MemoryStore store = _MemoryStore();
      final AsrEngineSelector selector = AsrEngineSelector(store);
      await selector.writeConfigured(AsrEngineKind.vosk);
      expect(store.values[AsrEngineSelector.configKey], 'vosk');
      expect(await selector.readConfigured(), AsrEngineKind.vosk);
    });

    test('giá trị lạ/đã đổi tên → quay về mặc định, KHÔNG ném lỗi', () async {
      final _MemoryStore store = _MemoryStore();
      store.values[AsrEngineSelector.configKey] = 'engine-khong-ton-tai';
      final AsrEngineSelector selector = AsrEngineSelector(store);
      expect(await selector.readConfigured(), AsrEngineSelector.defaultKind);
    });

    test('create() trả đúng lớp engine thật (không cần sửa tầng trên khi đổi engine)', () {
      final AsrEngineSelector selector = AsrEngineSelector(_MemoryStore());
      expect(selector.create(AsrEngineKind.phoWhisper), isA<PhoWhisperAsrEngine>());
      expect(selector.create(AsrEngineKind.vosk), isA<VoskAsrEngine>());
    });
  });

  // K33 — cần đo A/B `chunkSeconds`/`threads` trên máy thật: nếu các giá trị này nằm trong code thì
  // mỗi lần thử một mức phải build + cài lại APK. Đưa vào config (bảng `meta`) ⇒ đổi bằng dữ liệu.
  group('AsrEngineSelector — AsrTuning (K33)', () {
    test('chưa có khoá ⇒ mặc định chunk 4s + threads tự động', () async {
      final AsrTuning tuning = await AsrEngineSelector(_MemoryStore()).readTuning();
      expect(tuning.chunkSeconds, AsrTuning.defaultChunkSeconds);
      expect(tuning.threads, AsrTuning.defaultThreads);
      expect(AsrTuning.defaults.chunkSeconds, 4, reason: 'giữ nguyên hành vi cũ khi không cấu hình');
    });

    test('đọc đúng giá trị đã ghi', () async {
      final _MemoryStore store = _MemoryStore();
      store.values[AsrEngineSelector.chunkSecondsKey] = '12';
      store.values[AsrEngineSelector.threadsKey] = '6';
      final AsrTuning tuning = await AsrEngineSelector(store).readTuning();
      expect(tuning.chunkSeconds, 12);
      expect(tuning.threads, 6);
    });

    test('giá trị hỏng/ngoài khoảng ⇒ mặc định, KHÔNG ném lỗi', () async {
      for (final String bad in <String>['abc', '0', '1', '31', '-3', '']) {
        final _MemoryStore store = _MemoryStore();
        store.values[AsrEngineSelector.chunkSecondsKey] = bad;
        store.values[AsrEngineSelector.threadsKey] = '99';
        final AsrTuning tuning = await AsrEngineSelector(store).readTuning();
        expect(tuning.chunkSeconds, AsrTuning.defaultChunkSeconds, reason: 'chunk="$bad"');
        expect(tuning.threads, AsrTuning.defaultThreads, reason: 'threads="99"');
      }
    });

    test('create() áp tuning vào PhoWhisperAsrEngine; Vosk không dùng tuning', () {
      final AsrEngineSelector selector = AsrEngineSelector(_MemoryStore());
      final AsrEngine engine = selector.create(
        AsrEngineKind.phoWhisper,
        tuning: const AsrTuning(chunkSeconds: 12, threads: 6),
      );
      final PhoWhisperConfig config = (engine as PhoWhisperAsrEngine).config;
      expect(config.chunkSeconds, 12);
      expect(config.threads, 6);
      expect(config.resolvedThreads, 6, reason: 'threads=6 phải giữ nguyên, không bị chặn trần');
      expect(selector.create(AsrEngineKind.vosk), isA<VoskAsrEngine>());
    });
  });

  group('AsrEngineSelector — createAndInit + fallback', () {
    test('init theo engine đã cấu hình', () async {
      final _MemoryStore store = _MemoryStore();
      store.values[AsrEngineSelector.configKey] = 'vosk';
      final Map<AsrEngineKind, _FakeEngine> made = <AsrEngineKind, _FakeEngine>{};
      final AsrEngineSelector selector = AsrEngineSelector(
        store,
        (AsrEngineKind kind) => made[kind] = _FakeEngine(),
      );

      final AsrEngine engine = await selector.createAndInit();
      expect(made[AsrEngineKind.vosk]!.initialized, isTrue);
      expect(made.containsKey(AsrEngineKind.phoWhisper), isFalse,
          reason: 'không tạo engine không được chọn');
      expect(engine, same(made[AsrEngineKind.vosk]));
    });

    test('init engine đã chọn thất bại → fallback sang engine còn lại', () async {
      final _MemoryStore store = _MemoryStore();
      store.values[AsrEngineSelector.configKey] = 'phowhisper';
      final Map<AsrEngineKind, _FakeEngine> made = <AsrEngineKind, _FakeEngine>{};
      final AsrEngineSelector selector = AsrEngineSelector(
        store,
        (AsrEngineKind kind) => made[kind] = _FakeEngine(
              failInit: kind == AsrEngineKind.phoWhisper,
            ),
      );

      final AsrEngine engine = await selector.createAndInit();
      expect(engine, same(made[AsrEngineKind.vosk]));
      expect(made[AsrEngineKind.vosk]!.initialized, isTrue);
      expect(made[AsrEngineKind.phoWhisper]!.disposeCount, 1,
          reason: 'engine init thất bại phải được giải phóng');
      // Cấu hình KHÔNG bị đổi: fallback chỉ cho phiên này, không âm thầm đổi engine mặc định.
      expect(await selector.readConfigured(), AsrEngineKind.phoWhisper);
    });

    test('allowFallback = false → ném lỗi gốc, không thử engine khác', () async {
      final _MemoryStore store = _MemoryStore();
      final Map<AsrEngineKind, _FakeEngine> made = <AsrEngineKind, _FakeEngine>{};
      final AsrEngineSelector selector = AsrEngineSelector(
        store,
        (AsrEngineKind kind) => made[kind] = _FakeEngine(failInit: true),
      );

      await expectLater(
        selector.createAndInit(allowFallback: false),
        throwsA(isA<StateError>()),
      );
      expect(made.length, 1, reason: 'chỉ thử đúng engine đã chọn');
    });

    test('cả hai engine đều fail → StateError mô tả rõ cả hai', () async {
      final AsrEngineSelector selector = AsrEngineSelector(
        _MemoryStore(),
        (AsrEngineKind kind) => _FakeEngine(failInit: true),
      );

      await expectLater(
        selector.createAndInit(),
        throwsA(isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          allOf(contains('phowhisper'), contains('vosk')),
        )),
      );
    });

    test('overrideKind dùng cho phiên này mà không đổi cấu hình đã lưu', () async {
      final _MemoryStore store = _MemoryStore();
      final Map<AsrEngineKind, _FakeEngine> made = <AsrEngineKind, _FakeEngine>{};
      final AsrEngineSelector selector = AsrEngineSelector(
        store,
        (AsrEngineKind kind) => made[kind] = _FakeEngine(),
      );

      await selector.createAndInit(overrideKind: AsrEngineKind.vosk);
      expect(made[AsrEngineKind.vosk]!.initialized, isTrue);
      expect(store.values.containsKey(AsrEngineSelector.configKey), isFalse);
    });
  });
}
