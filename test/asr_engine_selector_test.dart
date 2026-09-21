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
