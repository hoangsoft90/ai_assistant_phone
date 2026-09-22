// Test P3 task 3 — Output Mode (mục 4.8) + tốc độ đọc TTS.
//
// Phần "chọn chế độ nào" là logic thuần (không cần thiết bị), nên test khoá được cả 3 chế độ + quy
// tắc **tự hạ cấp Ear → chữ khi không có tai nghe** (ràng buộc an toàn: không được để chế độ Ear
// đọc ra loa ngoài).

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/audio/output_mode_selector.dart';
import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';

/// Store giả trong bộ nhớ (SQLite thật cần platform channel) — cùng mẫu với `asr_engine_selector_test`.
class _FakeConfigStore implements ConfigStore {
  _FakeConfigStore([Map<String, String>? initial]) : _values = <String, String>{...?initial};

  final Map<String, String> _values;
  bool throwOnRead = false;
  bool throwOnWrite = false;

  @override
  Future<String?> read(String key) async {
    if (throwOnRead) {
      throw StateError('DB chưa mở');
    }
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (throwOnWrite) {
      throw StateError('DB lỗi');
    }
    _values[key] = value;
  }
}

void main() {
  group('NudgeOutputMode + OutputModeSelector (P3 task 3)', () {
    test('mặc định là Ear — nhưng KHÔNG đọc khi thiếu tai nghe (an toàn nằm ở effectiveMode)', () async {
      final OutputModeSelector selector = OutputModeSelector(store: _FakeConfigStore());
      expect(OutputModeSelector.defaultMode, NudgeOutputMode.ear);
      expect(await selector.read(), NudgeOutputMode.ear);
    });

    test('đọc lại đúng giá trị đã lưu cho cả 3 chế độ', () async {
      for (final NudgeOutputMode mode in NudgeOutputMode.values) {
        final _FakeConfigStore store = _FakeConfigStore();
        final OutputModeSelector selector = OutputModeSelector(store: store);
        await selector.write(mode);
        expect(await selector.read(), mode, reason: 'chế độ ${mode.storageValue}');
      }
    });

    test('giá trị lạ trong DB ⇒ về mặc định, KHÔNG ném', () async {
      final OutputModeSelector selector = OutputModeSelector(
        store: _FakeConfigStore(<String, String>{OutputConfig.modeKey: 'khong-ton-tai'}),
      );
      expect(await selector.read(), OutputModeSelector.defaultMode);
    });

    test('DB lỗi khi đọc/ghi ⇒ không ném (cấu hình hỏng không được làm chết đường gợi ý)', () async {
      final _FakeConfigStore store = _FakeConfigStore()..throwOnRead = true;
      final OutputModeSelector selector = OutputModeSelector(store: store);

      expect(await selector.read(), OutputModeSelector.defaultMode);

      store.throwOnRead = false;
      store.throwOnWrite = true;
      await expectLater(selector.write(NudgeOutputMode.silent), completes);
    });

    test('effectiveMode: Ear + KHÔNG có tai nghe ⇒ hạ xuống chữ (không đọc ra loa ngoài)', () {
      expect(
        OutputModeSelector.effectiveMode(NudgeOutputMode.ear, headsetAvailable: false),
        EffectiveNudgeOutput.text,
      );
      expect(
        OutputModeSelector.effectiveMode(NudgeOutputMode.ear, headsetAvailable: true),
        EffectiveNudgeOutput.ear,
      );
    });

    test('effectiveMode: Haptic không phụ thuộc tai nghe; Silent luôn là chữ', () {
      expect(
        OutputModeSelector.effectiveMode(NudgeOutputMode.haptic, headsetAvailable: false),
        EffectiveNudgeOutput.haptic,
      );
      expect(
        OutputModeSelector.effectiveMode(NudgeOutputMode.haptic, headsetAvailable: true),
        EffectiveNudgeOutput.haptic,
      );
      expect(
        OutputModeSelector.effectiveMode(NudgeOutputMode.silent, headsetAvailable: true),
        EffectiveNudgeOutput.text,
      );
      expect(
        OutputModeSelector.effectiveMode(NudgeOutputMode.silent, headsetAvailable: false),
        EffectiveNudgeOutput.text,
      );
    });
  });

  group('Tốc độ đọc TTS (mục 4.8: 0.9x-1.2x, mặc định 1.05x)', () {
    test('chưa cấu hình ⇒ 1.05x', () async {
      final OutputModeSelector selector = OutputModeSelector(store: _FakeConfigStore());
      expect(await selector.readSpeechRate(), OutputConfig.defaultSpeechRate);
      expect(OutputConfig.defaultSpeechRate, 1.05);
    });

    test('lưu rồi đọc lại đúng giá trị', () async {
      final OutputModeSelector selector = OutputModeSelector(store: _FakeConfigStore());
      await selector.writeSpeechRate(0.95);
      expect(await selector.readSpeechRate(), 0.95);
    });

    test('giá trị NGOÀI khoảng bị kẹp về 0.9-1.2 (cả khi ghi lẫn khi đọc)', () async {
      final _FakeConfigStore store = _FakeConfigStore(
        <String, String>{OutputConfig.speechRateKey: '9.0'},
      );
      final OutputModeSelector selector = OutputModeSelector(store: store);
      expect(await selector.readSpeechRate(), OutputConfig.maxSpeechRate);

      await selector.writeSpeechRate(0.1);
      expect(await store.read(OutputConfig.speechRateKey), '0.90');
    });

    test('giá trị không phải số / NaN ⇒ về mặc định, không ném', () async {
      final _FakeConfigStore store = _FakeConfigStore(
        <String, String>{OutputConfig.speechRateKey: 'nhanh-len'},
      );
      final OutputModeSelector selector = OutputModeSelector(store: store);
      expect(await selector.readSpeechRate(), OutputConfig.defaultSpeechRate);

      expect(OutputConfig.clampSpeechRate(double.nan), OutputConfig.defaultSpeechRate);
      expect(OutputConfig.clampSpeechRate(double.infinity), OutputConfig.defaultSpeechRate);
      expect(OutputConfig.clampSpeechRate(1.0), 1.0);
      expect(OutputConfig.clampSpeechRate(0.5), OutputConfig.minSpeechRate);
      expect(OutputConfig.clampSpeechRate(2.0), OutputConfig.maxSpeechRate);
    });

    test('DB lỗi ⇒ về mặc định, không ném', () async {
      final OutputModeSelector selector =
          OutputModeSelector(store: _FakeConfigStore()..throwOnRead = true);
      expect(await selector.readSpeechRate(), OutputConfig.defaultSpeechRate);
    });
  });
}
