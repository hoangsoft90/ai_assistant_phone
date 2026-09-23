// Test P5 task 2 — Session Summary.
//
// Điều cần khoá:
// - Nhịp: KHÔNG gọi LLM trước khi đủ `everyNudges` (mỗi lần bấm Push không được thành một request).
// - Có nhịp theo thời gian cho buổi im lặng lâu nhưng vẫn có nudge.
// - Lỗi (mạng/timeout/không key/lỗi lạ/transcript rỗng) ⇒ giữ bản tóm tắt cũ, ghi `lastNote`, KHÔNG ném.
// - Bản tóm tắt bị cắt về trần ký tự trước khi vào prompt khung.
// - `reset()` xoá sạch (phiên sau không được thừa hưởng ngữ cảnh buổi trước).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/coaching/session_summary.dart';
import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/suggestion/llm_provider.dart';
import 'package:ai_assistant_phone/suggestion/session_memory.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_models.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_policy.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_service.dart';
import 'package:ai_assistant_phone/transcript/transcript_segment.dart';
import 'package:ai_assistant_phone/transcript/transcript_store.dart';

class _FakeTextLlm implements TextLlmProvider {
  String result = 'đã nói về công việc và còn dang dở chuyện chuyển nhà';
  Object? throwError;
  int calls = 0;
  final List<String> prompts = <String>[];
  final List<int> maxTokens = <int>[];

  /// Nếu khác `null`, `complete` sẽ chờ future này — dùng để mô phỏng LLM trả về MUỘN (sau `reset`).
  Future<void>? gate;

  @override
  Future<String> complete({required String prompt, int maxTokens = 200}) async {
    calls++;
    prompts.add(prompt);
    this.maxTokens.add(maxTokens);
    final Future<void>? wait = gate;
    if (wait != null) {
      await wait;
    }
    final Object? error = throwError;
    if (error != null) {
      throw error;
    }
    return result;
  }
}

class _FakeTranscript implements TranscriptStore {
  SessionTranscript? transcript;
  bool throwOnRead = false;
  int reads = 0;

  @override
  Future<SessionTranscript> sessionTranscript({int maxChars = 6000}) async {
    reads++;
    if (throwOnRead) {
      throw StateError('DB chưa mở');
    }
    return transcript ??
        const SessionTranscript(
          text: 'dạ em chào anh\nem mới chuyển nhà tuần trước',
          segmentCount: 2,
          truncated: false,
        );
  }

  /// Cần cho test cuối file (đi cả đường `SuggestionService.push`).
  @override
  Future<TranscriptWindow> recentWindow({Duration? window}) async => TranscriptWindow(
        segments: <TranscriptSegment>[
          TranscriptSegment(text: 'dạ em chào anh', timestamp: DateTime(2026, 9, 23, 8, 59)),
        ],
        lastPushMoment: null,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeTranscript không hỗ trợ ${invocation.memberName}');
}

/// Policy không lọc lặp: 2 test cuối đang thử **nhịp tóm tắt**, mà anti-repetition (2 phút, so cả
/// `type`) sẽ chặn gần hết Push khi 6 type bị xoay vòng trong vài giây — làm test đo sai đối tượng.
/// Ghi đè đúng một luật, giữ nguyên `canSuggest` của P2.
class _NoRepeatPolicy extends SuggestionPolicy {
  const _NoRepeatPolicy();

  @override
  bool isRepetition({
    required SuggestionResult result,
    required List<SuggestionRecord> recent,
    required DateTime now,
  }) =>
      false;
}

/// LLM nudge giả trả câu khác nhau mỗi lần + xoay type.
class _RotatingLlm implements LlmProvider {
  int calls = 0;

  @override
  Future<SuggestionResult> generateSuggestion(SuggestionContext context) async {
    final NudgeType type = NudgeType.values[calls % NudgeType.values.length];
    calls++;
    return SuggestionResult.nudge(type: type, text: 'gợi ý số $calls');
  }
}

/// Nhường vài nhịp event-loop để các lần tóm tắt "bắn mà không chờ" (`unawaited` trong
/// `SuggestionService`) kịp kết thúc. Test phải tự chờ — `push()` **cố ý** không chờ tóm tắt
/// (chờ sẽ làm nudge tới muộn, phá DoD độ trễ của P4).
Future<void> settle() async {
  for (int i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late DateTime now;
  late _FakeTextLlm llm;
  late _FakeTranscript transcript;

  SessionSummaryService build({int everyNudges = 4, Duration? interval}) =>
      SessionSummaryService(
        provider: llm,
        transcript: transcript,
        now: () => now,
        everyNudges: everyNudges,
        interval: interval ?? CoachingConfig.summaryInterval,
      );

  setUp(() {
    now = DateTime(2026, 9, 23, 9, 0, 0);
    llm = _FakeTextLlm();
    transcript = _FakeTranscript();
  });

  group('SessionSummaryService — nhịp', () {
    test('chưa đủ nudge ⇒ KHÔNG gọi LLM (mỗi lần Push không thành một request)', () async {
      final SessionSummaryService service = build();

      for (int nudges = 1; nudges < 4; nudges++) {
        await service.maybeRefresh(nudgeCount: nudges);
      }

      expect(llm.calls, 0);
      expect(service.summary, isEmpty);
      expect(service.refreshCount, 0);
    });

    test('đủ 4 nudge ⇒ gọi LLM đúng 1 lần và đưa transcript vào prompt', () async {
      final SessionSummaryService service = build();

      await service.maybeRefresh(nudgeCount: 4);

      expect(llm.calls, 1);
      expect(llm.prompts.single, contains('em mới chuyển nhà tuần trước'));
      expect(service.summary, 'đã nói về công việc và còn dang dở chuyện chuyển nhà');
      expect(service.refreshCount, 1);
      expect(service.lastNote, isNull);
      expect(service.updatedAt, now);
      // Transcript đã bóc băng là thứ duy nhất rời máy (ràng buộc cứng #4) — prompt không được
      // nhắc tới audio/đường dẫn file.
      expect(llm.prompts.single.toLowerCase().contains('wav'), isFalse);
    });

    test('nudge mới không đủ ngưỡng tiếp theo ⇒ không gọi thêm', () async {
      final SessionSummaryService service = build();
      await service.maybeRefresh(nudgeCount: 4);
      await service.maybeRefresh(nudgeCount: 6);
      expect(llm.calls, 1);
    });

    test('REVIEW: nhịp đếm theo số nudge THẬT, không bị trần 20 bản ghi của bộ nhớ phiên chặn',
        () async {
      final SessionSummaryService service = build();

      // Giả lập phiên dài: mỗi lần đủ 4 nudge lại tóm tắt một lần, kể cả sau mốc 20.
      for (int nudges = 4; nudges <= 24; nudges += 4) {
        await service.maybeRefresh(nudgeCount: nudges);
      }

      expect(llm.calls, 6, reason: 'nhịp 4 nudge phải chạy tiếp sau mốc 20 của SessionMemory');
      expect(service.refreshCount, 6);
    });

    test('quá interval dù chưa đủ nudge mới ⇒ vẫn tóm tắt lại (buổi im lặng lâu)', () async {
      final SessionSummaryService service = build();
      // Lần đầu: phải đủ 4 nudge mới gọi (chưa có mốc thời gian nào để so).
      await service.maybeRefresh(nudgeCount: 4);
      expect(llm.calls, 1);

      // Chỉ 1 nudge mới (chưa đủ ngưỡng 4) nhưng đã quá 5 phút ⇒ điều kiện HOẶC theo thời gian.
      now = now.add(CoachingConfig.summaryInterval);
      await service.maybeRefresh(nudgeCount: 5);

      expect(llm.calls, 2);
      expect(service.refreshCount, 2);
    });

    test('reset() xoá sạch — phiên mới không thừa hưởng tóm tắt buổi trước', () async {
      final SessionSummaryService service = build();
      await service.maybeRefresh(nudgeCount: 4);
      expect(service.summary, isNotEmpty);

      service.reset();

      expect(service.summary, isEmpty);
      expect(service.refreshCount, 0);
      expect(service.updatedAt, isNull);
      expect(service.lastNote, isNull);
      // Sau reset lại phải đủ 4 nudge mới gọi LLM lần nữa.
      await service.maybeRefresh(nudgeCount: 3);
      expect(llm.calls, 1);
    });
  });

  group('SessionSummaryService — không bao giờ ném', () {
    test('mất mạng/thiếu key ⇒ giữ bản cũ + ghi lý do', () async {
      final SessionSummaryService service = build();
      await service.maybeRefresh(nudgeCount: 4);
      final String previous = service.summary;

      llm.throwError = const SuggestionException('lỗi mạng khi gọi LLM');
      await service.maybeRefresh(nudgeCount: 8);

      expect(service.summary, previous, reason: 'lỗi không được xoá bản tóm tắt đang dùng');
      expect(service.lastNote, contains('lỗi mạng'));
    });

    test('REVIEW: lỗi ⇒ KHÔNG thử lại ở mỗi nudge sau đó (chống đập vào LLM đang chết)', () async {
      final SessionSummaryService service = build();
      llm.throwError = const SuggestionException('lỗi mạng khi gọi LLM');

      await service.maybeRefresh(nudgeCount: 4);
      expect(llm.calls, 1);

      // Nudge 5, 6, 7: nếu chỉ ghi mốc khi THÀNH CÔNG thì mỗi lần là một request hỏng nữa.
      await service.maybeRefresh(nudgeCount: 5);
      await service.maybeRefresh(nudgeCount: 6);
      await service.maybeRefresh(nudgeCount: 7);
      expect(llm.calls, 1, reason: 'chưa đủ nhịp mới thì không được thử lại');

      // Đủ thêm một nhịp nudge ⇒ cho thử lại (lỗi có thể chỉ là thoáng qua).
      await service.maybeRefresh(nudgeCount: 8);
      expect(llm.calls, 2);
    });

    test('REVIEW: sau lỗi, hết interval vẫn thử lại (network hồi phục)', () async {
      final SessionSummaryService service = build();
      llm.throwError = const SuggestionException('lỗi mạng');
      await service.maybeRefresh(nudgeCount: 4);
      expect(llm.calls, 1);

      llm.throwError = null;
      now = now.add(CoachingConfig.summaryInterval);
      await service.maybeRefresh(nudgeCount: 5);

      expect(llm.calls, 2);
      expect(service.summary, isNotEmpty);
    });

    test('REVIEW: kết quả bay về SAU reset ⇒ bị vứt bỏ (phiên mới không thừa hưởng tóm tắt phiên cũ)',
        () async {
      final SessionSummaryService service = build();
      final Completer<void> gate = Completer<void>();
      llm.gate = gate.future;
      llm.result = 'tóm tắt của PHIÊN CŨ';

      // Lần tóm tắt đang chờ LLM...
      final Future<void> inFlight = service.maybeRefresh(nudgeCount: 4);
      await Future<void>.delayed(Duration.zero);
      expect(llm.calls, 1);

      // ... thì phiên đổi (người dùng tắt rồi bật lại).
      service.reset();
      llm.gate = null;
      llm.result = 'tóm tắt của PHIÊN MỚI';
      gate.complete();
      await inFlight;

      expect(service.summary, isEmpty, reason: 'kết quả phiên cũ không được ghi vào phiên mới');
      expect(service.refreshCount, 0);
      expect(service.lastNote, isNull);

      // Phiên mới vẫn tóm tắt được bình thường.
      await service.maybeRefresh(nudgeCount: 4);
      expect(service.summary, 'tóm tắt của PHIÊN MỚI');
      expect(service.refreshCount, 1);
    });

    test('provider ném lỗi NGOÀI dự kiến ⇒ nuốt, không ném ra ngoài (bài học A50)', () async {
      final SessionSummaryService service = build();
      llm.throwError = TypeError();

      await service.maybeRefresh(nudgeCount: 4); // không được ném

      expect(service.summary, isEmpty);
      expect(service.lastNote, 'lỗi không xác định');
    });

    test('transcript rỗng ⇒ không gọi LLM, ghi lý do', () async {
      final SessionSummaryService service = build();
      transcript.transcript = const SessionTranscript(
        text: '',
        segmentCount: 0,
        truncated: false,
      );

      await service.maybeRefresh(nudgeCount: 4);

      expect(llm.calls, 0);
      expect(service.lastNote, contains('chưa có transcript'));
    });

    test('đọc transcript lỗi (SQLite) ⇒ không ném', () async {
      final SessionSummaryService service = build();
      transcript.throwOnRead = true;

      await service.maybeRefresh(nudgeCount: 4);

      expect(llm.calls, 0);
      expect(service.lastNote, 'lỗi không xác định');
    });
  });

  group('SuggestionService ↔ SessionSummaryService (nhịp theo nudge thật)', () {
    test('phiên dài >20 nudge vẫn tóm tắt đều theo nhịp (không bị trần SessionMemory chặn)',
        () async {
      DateTime clock = DateTime(2026, 9, 23, 9, 0, 0);
      final _FakeTextLlm textLlm = _FakeTextLlm();
      final _FakeTranscript store = _FakeTranscript();
      final SessionSummaryService summaries = SessionSummaryService(
        provider: textLlm,
        transcript: store,
        now: () => clock,
        everyNudges: 4,
      );
      // LLM giả trả nudge KHÁC NHAU mỗi lần + đổi type, để anti-repetition không chặn (đang thử NHỊP
      // tóm tắt, không thử anti-repetition).
      final SuggestionService service = SuggestionService(
        provider: _RotatingLlm(),
        policy: const _NoRepeatPolicy(),
        transcript: store,
        summaries: summaries,
        now: () => clock,
      );

      for (int i = 0; i < 25; i++) {
        clock = clock.add(const Duration(seconds: 2)); // vượt debounce 1s
        await service.push(isUserSpeaking: false);
      }
      await settle();

      // 25 nudge ⇒ tóm tắt ở các mốc 4, 8, 12, 16, 20, 24 = 6 lần. Nếu service lấy số nudge từ
      // `SessionMemory` (trần 20) thì sau mốc 20 sẽ KHÔNG còn lần nào nữa.
      expect(summaries.refreshCount, 6);
      expect(textLlm.calls, 6);
      expect(summaries.summary, isNotEmpty);
    });

    test('resetSession (đầu phiên mới) xoá cả nhịp đếm: phiên sau lại bắt đầu từ 0', () async {
      DateTime clock = DateTime(2026, 9, 23, 9, 0, 0);
      final _FakeTextLlm textLlm = _FakeTextLlm();
      final _FakeTranscript store = _FakeTranscript();
      final SessionSummaryService summaries = SessionSummaryService(
        provider: textLlm,
        transcript: store,
        now: () => clock,
        everyNudges: 4,
      );
      final SuggestionService service = SuggestionService(
        provider: _RotatingLlm(),
        policy: const _NoRepeatPolicy(),
        transcript: store,
        summaries: summaries,
        now: () => clock,
      );

      for (int i = 0; i < 4; i++) {
        clock = clock.add(const Duration(seconds: 2));
        await service.push(isUserSpeaking: false);
      }
      await settle();
      expect(summaries.refreshCount, 1);

      service.resetSession();
      //  Nhường một nhịp event-loop: lần tóm tắt của phiên cũ (nếu còn bay) kết thúc ở đây — và phải bị
      //  vứt bỏ nhờ token thế hệ, chứ không ghi đè lên phiên mới.
      await Future<void>.delayed(Duration.zero);
      expect(summaries.refreshCount, 0);
      expect(summaries.summary, isEmpty, reason: 'phiên mới không dùng tóm tắt buổi trước');

      for (int i = 0; i < 4; i++) {
        clock = clock.add(const Duration(seconds: 2));
        await service.push(isUserSpeaking: false);
      }
      await settle();
      expect(summaries.refreshCount, 1, reason: 'đếm lại từ 0 cho phiên mới');
    });
  });

  group('SessionSummaryService — prompt + clamp', () {
    test('prompt yêu cầu tóm tắt ngắn, không suy đoán, chỉ trả về phần tóm tắt', () {
      final String prompt = SessionSummaryService.buildSummaryPrompt('transcript ở đây');
      expect(prompt, contains('tối đa 40 từ'));
      expect(prompt, contains('Không suy đoán thông tin không có trong transcript'));
      expect(prompt, contains('Chỉ trả về phần tóm tắt'));
      expect(prompt, contains('transcript ở đây'));
      // Không nhãn người nói (ràng buộc xuyên phase từ P1E).
      expect(prompt.contains('[Bạn]'), isFalse);
    });

    test('clamp: quá trần ⇒ cắt và thêm dấu …, gộp khoảng trắng', () {
      final String long = 'a' * (CoachingConfig.summaryCharLimit + 50);
      final String clamped = SessionSummaryService.clampSummary(long);
      expect(clamped.length, CoachingConfig.summaryCharLimit + 1);
      expect(clamped.endsWith('…'), isTrue);

      expect(SessionSummaryService.clampSummary('  nhiều   khoảng \n trắng  '),
          'nhiều khoảng trắng');
    });

    test('bản tóm tắt quá dài từ LLM bị cắt trước khi vào prompt khung', () async {
      final SessionSummaryService service = build();
      llm.result = 'x' * (CoachingConfig.summaryCharLimit * 2);

      await service.maybeRefresh(nudgeCount: 4);

      expect(service.summary.length, lessThanOrEqualTo(CoachingConfig.summaryCharLimit + 1));
    });
  });
}
