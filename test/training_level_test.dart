// Test P5 task 4 — Training Level (mục 4.9).
//
// Điều cần khoá:
// - Store: mặc định Full Assist, giá trị lạ ⇒ mặc định, ghi lỗi thì RAM KHÔNG đổi (không sai lệch im lặng).
// - Luật theo cấp: Level 4/5 ⇒ `NO_SUGGESTION` có chủ đích và **KHÔNG** fallback Offline Cache; Level 2
//   cần ngữ cảnh rõ; Level 3 chỉ khi đã im lặng đủ lâu ("thật sự kẹt").
// - Push thủ công vẫn KHÔNG có cooldown (ràng buộc xuyên phase) — cấp 1 bấm liên tiếp khi rảnh vẫn đi qua.
// - Emergency Phrase KHÔNG bị cấp độ chặn (đường riêng P1G/P3).

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/audio/emergency/emergency_phrase_service.dart';
import 'package:ai_assistant_phone/audio/nudge_delivery.dart';
import 'package:ai_assistant_phone/audio/output_mode_selector.dart';
import 'package:ai_assistant_phone/audio/tts/safe_tts_output.dart';
import 'package:ai_assistant_phone/audio/tts/tts_client.dart';
import 'package:ai_assistant_phone/coaching/session_summary.dart';
import 'package:ai_assistant_phone/coaching/training_level.dart';
import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';
import 'package:ai_assistant_phone/suggestion/llm_provider.dart';
import 'package:ai_assistant_phone/suggestion/offline_nudge_cache.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_models.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_policy.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_service.dart';
import 'package:ai_assistant_phone/transcript/transcript_segment.dart';
import 'package:ai_assistant_phone/transcript/transcript_store.dart';
import 'package:ai_assistant_phone/trigger/trigger_manager.dart';

class _FakeConfigStore implements ConfigStore {
  _FakeConfigStore({Map<String, String>? initial, this.failWrite = false})
      : values = <String, String>{...?initial};

  final Map<String, String> values;
  bool failWrite;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) {
      throw StateError('DB lỗi khi ghi');
    }
    values[key] = value;
  }
}

class _FakeLlm implements LlmProvider {
  int calls = 0;

  @override
  Future<SuggestionResult> generateSuggestion(SuggestionContext context) async {
    calls++;
    return const SuggestionResult.nudge(type: NudgeType.ask, text: 'hỏi thêm đi');
  }
}

class _FakeTextLlm implements TextLlmProvider {
  @override
  Future<String> complete({required String prompt, int maxTokens = 200}) async => 'tóm tắt giả';
}

/// Transcript giả điều khiển được cửa sổ 30s (để thử luật "kẹt" của Level 3 và "ngữ cảnh rõ" của Level 2).
class _FakeTranscript implements TranscriptStore {
  _FakeTranscript({this.lastSegmentAt});

  DateTime? lastSegmentAt;
  int markPushCalls = 0;

  @override
  Future<void> markPushMoment(DateTime moment) async {
    markPushCalls++;
  }

  @override
  Future<TranscriptWindow> recentWindow({Duration? window}) async => TranscriptWindow(
        segments: lastSegmentAt == null
            ? const <TranscriptSegment>[]
            : <TranscriptSegment>[
                TranscriptSegment(text: 'dạ vâng ạ', timestamp: lastSegmentAt!),
              ],
        lastPushMoment: null,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeTranscript không hỗ trợ ${invocation.memberName}');
}

class _FakeTtsClient implements TtsClient {
  @override
  Future<TtsOutputInfo> outputState() async => const TtsOutputInfo(hasPrivateOutput: true);

  @override
  Future<TtsNativeSpeakResult> speak(String text, {double? rate}) async =>
      const TtsNativeSpeakResult(TtsNativeSpeakStatus.synthesizing);

  @override
  Future<bool> stop() async => false;

  @override
  Future<void> vibrateFallback() async {}

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

SessionSummaryService _silentSummaries(TranscriptStore transcript) => SessionSummaryService(
      provider: _FakeTextLlm(),
      transcript: transcript,
      everyNudges: 99,
    );

void main() {
  group('TrainingLevel — enum + store', () {
    test('5 cấp đúng mã lưu + nhãn/hành vi không rỗng', () {
      expect(TrainingLevel.values, hasLength(5));
      expect(TrainingLevel.tryParse('full_assist'), TrainingLevel.fullAssist);
      expect(TrainingLevel.tryParse('INDEPENDENT'), TrainingLevel.independent);
      expect(TrainingLevel.tryParse('không tồn tại'), isNull);
      expect(TrainingLevel.tryParse(null), isNull);
      for (final TrainingLevel level in TrainingLevel.values) {
        expect(level.label, isNotEmpty);
        expect(level.behavior, isNotEmpty);
      }
    });

    test('chỉ Level 4/5 chặn nudge realtime', () {
      expect(TrainingLevel.training.blocksRealtimeNudges, isTrue);
      expect(TrainingLevel.independent.blocksRealtimeNudges, isTrue);
      expect(TrainingLevel.fullAssist.blocksRealtimeNudges, isFalse);
      expect(TrainingLevel.lightAssist.blocksRealtimeNudges, isFalse);
      expect(TrainingLevel.minimal.blocksRealtimeNudges, isFalse);
    });

    test('máy mới (chưa có khoá) ⇒ Full Assist', () async {
      final TrainingLevelStore store = TrainingLevelStore(store: _FakeConfigStore());
      expect(await store.load(), TrainingLevel.fullAssist);
      expect(store.current, TrainingLevel.fullAssist);
    });

    test('giá trị lạ trong DB ⇒ về mặc định (không ném)', () async {
      final TrainingLevelStore store = TrainingLevelStore(
        store: _FakeConfigStore(initial: <String, String>{
          CoachingConfig.trainingLevelKey: 'cấp 9',
        }),
      );
      expect(await store.load(), TrainingLevel.fullAssist);
    });

    test('save ⇒ ghi đĩa + đổi RAM ngay (hiệu lực cho Push kế tiếp)', () async {
      final _FakeConfigStore config = _FakeConfigStore();
      final TrainingLevelStore store = TrainingLevelStore(store: config);

      expect(await store.save(TrainingLevel.minimal), isTrue);
      expect(store.current, TrainingLevel.minimal);
      expect(config.values[CoachingConfig.trainingLevelKey], 'minimal');
      expect(await TrainingLevelStore(store: config).load(), TrainingLevel.minimal);
    });

    test('REVIEW: ghi lỗi ⇒ KHÔNG đổi RAM (tránh "đổi mà lần sau tự quay về")', () async {
      final TrainingLevelStore store = TrainingLevelStore(
        store: _FakeConfigStore(failWrite: true),
      );
      expect(await store.save(TrainingLevel.independent), isFalse);
      expect(store.current, TrainingLevel.fullAssist);
    });
  });

  group('SuggestionPolicy — luật theo cấp (mục 4.9)', () {
    const SuggestionPolicy policy = SuggestionPolicy();
    final DateTime now = DateTime(2026, 9, 23, 10, 0, 0);

    test('Level 4/5 ⇒ bị chặn với lý do nêu rõ cấp', () {
      for (final TrainingLevel level in <TrainingLevel>[
        TrainingLevel.training,
        TrainingLevel.independent,
      ]) {
        final PolicyDecision decision = policy.canSuggest(
          isUserSpeaking: false,
          lastAttemptAt: null,
          now: now,
          level: level,
        );
        expect(decision.allowed, isFalse);
        expect(decision.reason, contains(level.storageValue));
      }
    });

    test('Level 1/2/3 qua được cổng thứ nhất, nhường cho cổng ngữ cảnh', () {
      for (final TrainingLevel level in <TrainingLevel>[
        TrainingLevel.fullAssist,
        TrainingLevel.lightAssist,
        TrainingLevel.minimal,
      ]) {
        expect(
          policy
              .canSuggest(
                isUserSpeaking: false,
                lastAttemptAt: null,
                now: now,
                level: level,
              )
              .allowed,
          isTrue,
          reason: 'level ${level.storageValue}',
        );
      }
    });

    test('userSpeaking vẫn là chặn CỨNG ở mọi cấp (nguyên tắc bất biến số 2)', () {
      for (final TrainingLevel level in TrainingLevel.values) {
        final PolicyDecision decision = policy.canSuggest(
          isUserSpeaking: true,
          lastAttemptAt: null,
          now: now,
          level: level,
        );
        expect(decision.allowed, isFalse);
        expect(decision.reason, 'userSpeaking');
      }
    });

    test('Level 2 (Light) cần ngữ cảnh rõ: không Pre-Brief + không transcript ⇒ chặn', () {
      final PolicyDecision blocked = policy.canSuggestWithContext(
        level: TrainingLevel.lightAssist,
        hasPreBrief: false,
        hasRecentTranscript: false,
        lastTranscriptAt: null,
        now: now,
      );
      expect(blocked.allowed, isFalse);
      expect(blocked.reason, contains('ngữ cảnh rõ'));

      // Có Pre-Brief là đủ.
      expect(
        policy
            .canSuggestWithContext(
              level: TrainingLevel.lightAssist,
              hasPreBrief: true,
              hasRecentTranscript: false,
              lastTranscriptAt: null,
              now: now,
            )
            .allowed,
        isTrue,
      );
      // Hoặc có transcript gần đây.
      expect(
        policy
            .canSuggestWithContext(
              level: TrainingLevel.lightAssist,
              hasPreBrief: false,
              hasRecentTranscript: true,
              lastTranscriptAt: now.subtract(const Duration(seconds: 2)),
              now: now,
            )
            .allowed,
        isTrue,
      );
    });

    test('Level 3 (Minimal) chỉ khi "thật sự kẹt": im lặng đủ lâu mới cho', () {
      // Chưa có transcript: chưa có gì để nói thì chưa phải kẹt.
      expect(
        policy
            .canSuggestWithContext(
              level: TrainingLevel.minimal,
              hasPreBrief: true,
              hasRecentTranscript: false,
              lastTranscriptAt: null,
              now: now,
            )
            .allowed,
        isFalse,
      );

      // Mới im lặng 2s: chưa tới ngưỡng.
      final PolicyDecision tooSoon = policy.canSuggestWithContext(
        level: TrainingLevel.minimal,
        hasPreBrief: true,
        hasRecentTranscript: true,
        lastTranscriptAt: now.subtract(const Duration(seconds: 2)),
        now: now,
      );
      expect(tooSoon.allowed, isFalse);
      expect(tooSoon.reason, contains('kẹt'));

      // Im lặng quá ngưỡng ⇒ cho phép (đây là "cứu" đúng lúc người dùng đang kẹt).
      expect(
        policy
            .canSuggestWithContext(
              level: TrainingLevel.minimal,
              hasPreBrief: true,
              hasRecentTranscript: true,
              lastTranscriptAt: now.subtract(CoachingConfig.minimalStuckSilence),
              now: now,
            )
            .allowed,
        isTrue,
      );
    });

    test('Level 1 không bị cổng ngữ cảnh chặn', () {
      expect(
        policy
            .canSuggestWithContext(
              level: TrainingLevel.fullAssist,
              hasPreBrief: false,
              hasRecentTranscript: false,
              lastTranscriptAt: null,
              now: now,
            )
            .allowed,
        isTrue,
      );
    });
  });

  group('SuggestionService theo Training Level', () {
    late _FakeLlm llm;
    late _FakeTranscript transcript;
    late TrainingLevelStore levels;

    SuggestionService buildService() => SuggestionService(
          provider: llm,
          transcript: transcript,
          levels: levels,
          summaries: _silentSummaries(transcript),
          cache: OfflineNudgeCache(
            loader: () async => '{"nudges":{"REACT":["hay đấy nhỉ"]}}',
          ),
        );

    setUp(() {
      llm = _FakeLlm();
      transcript = _FakeTranscript(
        lastSegmentAt: DateTime(2026, 9, 23, 10, 0, 0),
      );
      levels = TrainingLevelStore(store: _FakeConfigStore());
    });

    test('Level 4 ⇒ NO_SUGGESTION có chủ đích, KHÔNG gọi LLM, KHÔNG dùng Offline Cache', () async {
      await levels.save(TrainingLevel.training);
      final SuggestionService service = buildService();

      final SuggestionResult result = await service.push(isUserSpeaking: false);

      expect(result.isNudge, isFalse);
      expect(result.note, contains('training'));
      expect(llm.calls, 0, reason: 'cấp 4 nghĩa là KHÔNG hỏi LLM');
      expect(result.unavailable, isFalse,
          reason: 'đây là quyết định học tập, không phải "không dùng được LLM"');
      expect(service.cacheFallbackCount, 0,
          reason: 'fallback cache ở đây là phá đúng cấp độ người dùng chọn');
    });

    test('Level 3 ⇒ chặn khi vừa mới có người nói, cho qua khi đã kẹt', () async {
      await levels.save(TrainingLevel.minimal);
      final SuggestionService service = buildService();

      transcript.lastSegmentAt = DateTime.now().subtract(const Duration(seconds: 1));
      final SuggestionResult blocked = await service.push(isUserSpeaking: false);
      expect(blocked.isNudge, isFalse);
      expect(blocked.note, contains('minimal'));
      expect(llm.calls, 0);

      // Im lặng đủ lâu ⇒ Push kế tiếp đi qua (debounce trong test là 1s theo đồng hồ thật ⇒ chờ 1.1s).
      transcript.lastSegmentAt = DateTime.now().subtract(CoachingConfig.minimalStuckSilence);
      service.resetSession();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final SuggestionResult allowed = await service.push(isUserSpeaking: false);
      expect(allowed.isNudge, isTrue);
      expect(llm.calls, 1);
    });

    test('Level 1: bấm liên tiếp khi rảnh vẫn đi qua (KHÔNG cooldown — ràng buộc xuyên phase)',
        () async {
      final SuggestionService service = buildService();
      final SuggestionResult first = await service.push(isUserSpeaking: false);
      // Đổi text để anti-repetition không chặn (đang thử "không cooldown", không thử anti-repetition).
      service.resetSession();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final SuggestionResult second = await service.push(isUserSpeaking: false);

      expect(first.isNudge, isTrue);
      expect(second.isNudge, isTrue);
      expect(llm.calls, 2);
    });
  });

  group('Emergency không bị Training Level chặn', () {
    test('Level 5: Push bị chặn nhưng giữ nút nổi 2s vẫn kích hoạt Emergency', () async {
      final _FakeLlm llm = _FakeLlm();
      final _FakeTranscript transcript = _FakeTranscript();
      final TrainingLevelStore levels = TrainingLevelStore(store: _FakeConfigStore());
      await levels.save(TrainingLevel.independent);

      final _FakeTtsClient ttsClient = _FakeTtsClient();
      final _FakeEmergency emergency = _FakeEmergency();
      final TriggerManager manager = TriggerManager(
        suggestions: SuggestionService(
          provider: llm,
          transcript: transcript,
          levels: levels,
          summaries: _silentSummaries(transcript),
        ),
        modes: OutputModeSelector(store: _FakeConfigStore()),
        delivery: NudgeDelivery(tts: SafeTtsOutput(client: ttsClient)),
        transcript: transcript,
        emergency: emergency,
        tts: SafeTtsOutput(client: ttsClient),
      );

      final TriggerOutcome outcome = await manager.onSuggestRequested();
      expect(outcome.hasNudge, isFalse, reason: 'cấp 5: không cứu realtime');
      expect(llm.calls, 0);
      // Mốc Push vẫn được ghi để Post-Review còn dữ liệu (không im lặng vứt lần bấm đi).
      expect(transcript.markPushCalls, 1);

      // Đường thoát hiểm đi thẳng, không qua Policy/LLM ⇒ vẫn phát.
      expect(await manager.onEmergencyRequested(), EmergencyTriggerResult.started);
      expect(emergency.triggers, 1);
    });
  });
}
