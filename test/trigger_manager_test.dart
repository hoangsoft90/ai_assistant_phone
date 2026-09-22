// Test P3 task 1 + 2 — Trigger Abstraction + Gesture Emergency.
//
// Điều cần khoá:
// - MỌI nguồn trigger đi qua ĐÚNG một hàm `TriggerManager.onSuggestRequested` (không logic riêng
//   cho từng nguồn) và mốc Push (P1E) luôn được ghi, kể cả khi ghi mốc lỗi.
// - Đường Emergency (giữ nút 2 giây) đi THẲNG tới `EmergencyPhraseService`: không qua Policy,
//   không qua LLM, không bị debounce/`userSpeaking` chặn.
// - Nudge được giao theo đúng chế độ output, và Ear tự hạ xuống chữ khi không có tai nghe.
// - LLM không dùng được ⇒ Offline Cache tiếp quản; Policy chặn hoặc LLM trả NO_SUGGESTION hợp lệ
//   ⇒ KHÔNG được fallback sang cache.

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/audio/emergency/emergency_phrase_service.dart';
import 'package:ai_assistant_phone/audio/nudge_delivery.dart';
import 'package:ai_assistant_phone/audio/output_mode_selector.dart';
import 'package:ai_assistant_phone/audio/tts/safe_tts_output.dart';
import 'package:ai_assistant_phone/audio/tts/tts_client.dart';
import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';
import 'package:ai_assistant_phone/suggestion/llm_provider.dart';
import 'package:ai_assistant_phone/suggestion/offline_nudge_cache.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_models.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_service.dart';
import 'package:ai_assistant_phone/transcript/transcript_segment.dart';
import 'package:ai_assistant_phone/transcript/transcript_store.dart';
import 'package:ai_assistant_phone/trigger/trigger_manager.dart';

/// ---- Fake dùng chung (cùng mẫu với `suggestion_engine_test.dart`) ----

class _FakeLlm implements LlmProvider {
  _FakeLlm(this.responses);

  /// Mỗi phần tử là `SuggestionResult` (trả về) hoặc `SuggestionException` (ném ra).
  final List<Object> responses;
  int calls = 0;

  @override
  Future<SuggestionResult> generateSuggestion(SuggestionContext context) async {
    final int index = calls++;
    if (index >= responses.length) {
      fail('LlmProvider bị gọi quá số lần mong đợi (lần $index)');
    }
    final Object next = responses[index];
    if (next is SuggestionException) {
      throw next;
    }
    return next as SuggestionResult;
  }
}

class _FakeTranscript implements TranscriptStore {
  int markPushCalls = 0;
  bool throwOnMarkPush = false;
  bool throwOnRecentWindow = false;

  @override
  Future<void> markPushMoment(DateTime moment) async {
    markPushCalls++;
    if (throwOnMarkPush) {
      throw StateError('DB lỗi khi ghi mốc Push');
    }
  }

  @override
  Future<TranscriptWindow> recentWindow({Duration? window}) async {
    if (throwOnRecentWindow) {
      throw StateError('DB chưa mở');
    }
    return TranscriptWindow(
      segments: const <TranscriptSegment>[],
      lastPushMoment: DateTime(2026, 9, 22, 10, 0, 0),
    );
  }

  // NÉM thay vì trả null: nếu service gọi thêm method khác của store, test phải ĐỎ (bài học A8).
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeTranscript không hỗ trợ ${invocation.memberName}');
}

class _FakeConfigStore implements ConfigStore {
  _FakeConfigStore([Map<String, String>? initial]) : _values = <String, String>{...?initial};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}

class _FakeTtsClient implements TtsClient {
  _FakeTtsClient({this.hasHeadset = true});

  bool hasHeadset;
  final List<String> speakCalls = <String>[];
  final List<double?> speakRates = <double?>[];

  @override
  Future<TtsOutputInfo> outputState() async => TtsOutputInfo(
        hasPrivateOutput: hasHeadset,
        preferred: hasHeadset ? const TtsDevice(type: 4, name: 'Tai nghe dây') : null,
      );

  @override
  Future<TtsNativeSpeakResult> speak(String text, {double? rate}) async {
    speakCalls.add(text);
    speakRates.add(rate);
    return hasHeadset
        ? const TtsNativeSpeakResult(TtsNativeSpeakStatus.synthesizing)
        : const TtsNativeSpeakResult(TtsNativeSpeakStatus.noHeadset);
  }

  @override
  Future<bool> stop() async => false;

  @override
  Future<void> vibrateFallback() async {}

  // Không dùng sự kiện native → đăng ký handler là no-op (không giữ field thừa — bài học A8).
  @override
  void onEvent(void Function(TtsEvent event)? handler) {}
}

class _FakeEmergency implements EmergencyPhraseService {
  int triggers = 0;

  @override
  Future<EmergencyTriggerResult> triggerEmergency() async {
    triggers++;
    return EmergencyTriggerResult.started;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeEmergency không hỗ trợ ${invocation.memberName}');
}

/// Bộ đồ nghề dựng TriggerManager cho test: mọi thứ đều là fake, không đụng DB/kênh native.
class _Harness {
  _Harness({
    NudgeOutputMode mode = NudgeOutputMode.silent,
    double? storedSpeechRate,
    bool hasHeadset = true,
    List<Object> llmResponses = const <Object>[
      SuggestionResult.nudge(type: NudgeType.ask, text: 'hỏi thêm đi'),
    ],
    DateTime Function()? now,
  })  : llm = _FakeLlm(llmResponses),
        transcript = _FakeTranscript(),
        ttsClient = _FakeTtsClient(hasHeadset: hasHeadset) {
    configStore = _FakeConfigStore(<String, String>{
      OutputConfig.modeKey: mode.storageValue,
      if (storedSpeechRate != null) OutputConfig.speechRateKey: storedSpeechRate.toString(),
    });
    final OutputModeSelector modes = OutputModeSelector(store: configStore);
    final SuggestionService suggestions = SuggestionService(
      provider: llm,
      transcript: transcript,
      cache: OfflineNudgeCache(
        loader: () async => '{"nudges":{"REACT":["hay đấy nhỉ","thú vị đấy"]}}',
      ),
      now: now,
    );
    delivery = NudgeDelivery(tts: SafeTtsOutput(client: ttsClient), haptic: () async {
      hapticCalls++;
    });
    manager = TriggerManager(
      suggestions: suggestions,
      modes: modes,
      delivery: delivery,
      transcript: transcript,
      emergency: emergency,
      tts: SafeTtsOutput(client: ttsClient),
    );
  }

  final _FakeLlm llm;
  final _FakeTranscript transcript;
  final _FakeTtsClient ttsClient;
  final _FakeEmergency emergency = _FakeEmergency();
  late final _FakeConfigStore configStore;
  late final NudgeDelivery delivery;
  late final TriggerManager manager;
  int hapticCalls = 0;
}

void main() {
  group('TriggerManager — một điểm vào cho mọi nguồn', () {
    test('mọi nguồn trigger đều đi qua cùng một hàm và trả về đúng nguồn đã gọi', () async {
      for (final SuggestTriggerSource source in SuggestTriggerSource.values) {
        final _Harness h = _Harness();
        final TriggerOutcome outcome = await h.manager.onSuggestRequested(source: source);

        expect(outcome.source, source);
        expect(outcome.hasNudge, isTrue);
        expect(h.llm.calls, 1);
      }
    });

    test('ghi mốc Push (P1E) trước khi xin gợi ý', () async {
      final _Harness h = _Harness();
      await h.manager.onSuggestRequested();
      expect(h.transcript.markPushCalls, 1);
    });

    test('ghi mốc Push LỖI vẫn phải xin gợi ý bình thường (mốc không chặn Push)', () async {
      final _Harness h = _Harness();
      h.transcript.throwOnMarkPush = true;

      final TriggerOutcome outcome = await h.manager.onSuggestRequested();

      expect(outcome.hasNudge, isTrue);
      expect(h.transcript.markPushCalls, 1);
    });

    test('transcript lỗi ⇒ NO_SUGGESTION, KHÔNG ném ra UI', () async {
      final _Harness h = _Harness();
      h.transcript.throwOnRecentWindow = true;

      final TriggerOutcome outcome = await h.manager.onSuggestRequested();

      expect(outcome.hasNudge, isFalse);
      expect(outcome.delivery, isNull);
      expect(h.llm.calls, 0, reason: 'không được gọi LLM khi không dựng được context');
    });

    test('debounce 1s chặn lần bấm thứ hai ⇒ chỉ gọi LLM 1 lần (và KHÔNG phải cooldown)', () async {
      final DateTime fixed = DateTime(2026, 9, 22, 10, 0, 0);
      final _Harness h = _Harness(now: () => fixed);

      final TriggerOutcome first = await h.manager.onSuggestRequested();
      final TriggerOutcome second = await h.manager.onSuggestRequested();

      expect(first.hasNudge, isTrue);
      expect(second.hasNudge, isFalse);
      expect(second.result.note, contains('debounce'));
      expect(h.llm.calls, 1);
    });
  });

  group('TriggerManager — giao nudge theo chế độ output (P3 task 3)', () {
    test('Silent: chỉ hiện chữ, KHÔNG gọi TTS, không rung', () async {
      final _Harness h = _Harness(mode: NudgeOutputMode.silent);

      final TriggerOutcome outcome = await h.manager.onSuggestRequested();

      expect(outcome.effectiveMode, EffectiveNudgeOutput.text);
      expect(outcome.delivery, NudgeDeliveryResult.textOnly);
      expect(h.ttsClient.speakCalls, isEmpty);
      expect(h.hapticCalls, 0);
    });

    test('Haptic: rung 1 pattern chung, KHÔNG gọi TTS', () async {
      final _Harness h = _Harness(mode: NudgeOutputMode.haptic);

      final TriggerOutcome outcome = await h.manager.onSuggestRequested();

      expect(outcome.effectiveMode, EffectiveNudgeOutput.haptic);
      expect(outcome.delivery, NudgeDeliveryResult.vibrated);
      expect(h.hapticCalls, 1);
      expect(h.ttsClient.speakCalls, isEmpty);
    });

    test('Ear + có tai nghe: đọc qua SafeTtsOutput với đúng tốc độ đã cấu hình', () async {
      final _Harness h = _Harness(
        mode: NudgeOutputMode.ear,
        hasHeadset: true,
        storedSpeechRate: 0.95,
      );

      final TriggerOutcome outcome = await h.manager.onSuggestRequested();

      expect(outcome.effectiveMode, EffectiveNudgeOutput.ear);
      expect(outcome.delivery, NudgeDeliveryResult.spoken);
      expect(h.ttsClient.speakCalls, <String>['hỏi thêm đi']);
      expect(h.ttsClient.speakRates, <double?>[0.95]);
    });

    test('Ear + KHÔNG có tai nghe: hạ xuống chữ, TUYỆT ĐỐI không gọi TTS', () async {
      final _Harness h = _Harness(mode: NudgeOutputMode.ear, hasHeadset: false);

      final TriggerOutcome outcome = await h.manager.onSuggestRequested();

      expect(outcome.effectiveMode, EffectiveNudgeOutput.text);
      expect(outcome.delivery, NudgeDeliveryResult.textOnly);
      expect(h.ttsClient.speakCalls, isEmpty);
    });

    test('chưa cấu hình tốc độ ⇒ dùng mặc định 1.05x', () async {
      final _Harness h = _Harness(mode: NudgeOutputMode.ear, hasHeadset: true);

      await h.manager.onSuggestRequested();

      expect(h.ttsClient.speakRates, <double?>[OutputConfig.defaultSpeechRate]);
    });

    test('rung lỗi (máy không hỗ trợ haptic) ⇒ vẫn chạy tiếp, hạ xuống chữ (không ném)', () async {
      final _Harness h = _Harness(mode: NudgeOutputMode.haptic);
      final NudgeDelivery delivery = NudgeDelivery(
        tts: SafeTtsOutput(client: h.ttsClient),
        haptic: () async => throw StateError('máy không có vibrator'),
      );

      final NudgeDeliveryResult result = await delivery.deliver(
        text: 'x',
        via: EffectiveNudgeOutput.haptic,
      );

      expect(result, NudgeDeliveryResult.textOnly);
    });
  });

  group('TriggerManager — Offline Cache chỉ là FALLBACK (P3 task 4 + mục 4.12)', () {
    test('LLM timeout ⇒ nudge từ cache offline, có đánh dấu nguồn + đếm fallback', () async {
      final _Harness h = _Harness(
        llmResponses: const <Object>[
          SuggestionException('timeout gọi Groq'),
        ],
      );

      final TriggerOutcome outcome = await h.manager.onSuggestRequested();

      expect(outcome.hasNudge, isTrue);
      expect(outcome.result.source, NudgeSource.cache);
      expect(outcome.result.note, contains('offline cache'));
      expect(h.manager.suggestions.cacheFallbackCount, 1);
    });

    test('LLM trả NO_SUGGESTION hợp lệ ⇒ KHÔNG fallback sang cache (không phải lỗi)', () async {
      final _Harness h = _Harness(
        llmResponses: const <Object>[SuggestionResult.noSuggestion()],
      );

      final TriggerOutcome outcome = await h.manager.onSuggestRequested();

      expect(outcome.hasNudge, isFalse);
      expect(h.manager.suggestions.cacheFallbackCount, 0);
    });

    test('Policy chặn (debounce) ⇒ không gọi LLM, không fallback cache', () async {
      final DateTime fixed = DateTime(2026, 9, 22, 10, 0, 0);
      final _Harness h = _Harness(now: () => fixed);

      await h.manager.onSuggestRequested();
      final TriggerOutcome blocked = await h.manager.onSuggestRequested();

      expect(blocked.hasNudge, isFalse);
      expect(h.manager.suggestions.cacheFallbackCount, 0);
      expect(h.llm.calls, 1);
    });
  });

  group('TriggerManager — Emergency Phrase (P3 task 2)', () {
    test('gesture giữ 2s đi THẲNG tới Emergency: không qua LLM, không qua Policy/debounce', () async {
      final DateTime fixed = DateTime(2026, 9, 22, 10, 0, 0);
      final _Harness h = _Harness(now: () => fixed);

      // Xin gợi ý trước để "nhiễm" debounce, rồi trigger Emergency ngay sau đó: Emergency KHÔNG
      // được phép bị debounce chặn (đường thoát hiểm phải phản hồi tức thì).
      await h.manager.onSuggestRequested();
      final EmergencyTriggerResult result = await h.manager.onEmergencyRequested();

      expect(result, EmergencyTriggerResult.started);
      expect(h.emergency.triggers, 1);
      expect(h.llm.calls, 1, reason: 'Emergency không được gọi LLM');
    });

    test('thời gian giữ mặc định của nút nổi là 2 giây (prompt P3 task 2)', () {
      expect(TriggerConfig.emergencyHold, const Duration(seconds: 2));
    });
  });
}
