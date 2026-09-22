import 'dart:convert';
import 'dart:io';

import 'package:ai_assistant_phone/suggestion/groq_llm_provider.dart';
import 'package:ai_assistant_phone/suggestion/llm_provider.dart';
import 'package:ai_assistant_phone/suggestion/session_memory.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_context_builder.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_models.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_policy.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_service.dart';
import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/transcript/transcript_segment.dart';
import 'package:ai_assistant_phone/transcript/transcript_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// ---- Fake dùng chung ----

class _FakeLlm implements LlmProvider {
  _FakeLlm(this.responses);

  /// Từng phần tử là `SuggestionResult` (trả về) hoặc `SuggestionException` (ném ra).
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

class _CapturingLlm implements LlmProvider {
  _CapturingLlm(this.captured);

  final List<SuggestionContext> captured;

  @override
  Future<SuggestionResult> generateSuggestion(SuggestionContext context) async {
    captured.add(context);
    return const SuggestionResult.nudge(type: NudgeType.ask, text: 'x');
  }
}

class _FakeStore implements TranscriptStore {
  _FakeStore(this._window);

  final TranscriptWindow _window;

  @override
  Future<TranscriptWindow> recentWindow({Duration? window}) async => _window;

  // Chỉ dùng recentWindow. NÉM thay vì trả `null`: nếu sau này service gọi thêm method khác của
  // store, test phải ĐỎ để lộ ra — trả null im lặng sẽ che mất thay đổi hành vi (bài học A8).
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeStore không hỗ trợ ${invocation.memberName}');
}

/// Provider ném đúng loại lỗi được truyền vào (dùng để thử lỗi NGOÀI `SuggestionException`).
class _ThrowingLlm implements LlmProvider {
  _ThrowingLlm(this.error);

  final Object error;

  @override
  Future<SuggestionResult> generateSuggestion(SuggestionContext context) async =>
      throw error;
}

/// Store luôn lỗi — mô phỏng SQLite hỏng/chưa mở được.
class _BrokenStore implements TranscriptStore {
  @override
  Future<TranscriptWindow> recentWindow({Duration? window}) async =>
      throw StateError('DB chưa mở');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_BrokenStore không hỗ trợ ${invocation.memberName}');
}

SuggestionContext _context() => SuggestionContext(
      prompt: 'test prompt',
      recentTranscript: 'xin chào',
      pushTimestamp: '',
      topicsExplored: const <String>[],
      lastSuggestions: const <String>[],
    );

void main() {
  group('SuggestionPolicy', () {
    const SuggestionPolicy policy = SuggestionPolicy();
    final DateTime now = DateTime(2026, 9, 22, 10, 0, 0);

    test('chặn CỨNG khi userSpeaking — kể cả lần bấm đầu tiên', () {
      final PolicyDecision decision = policy.canSuggest(
        isUserSpeaking: true,
        lastAttemptAt: null,
        now: now,
      );
      expect(decision.allowed, isFalse);
      expect(decision.reason, 'userSpeaking');
    });

    test('cho phép khi notUserSpeaking và chưa bấm lần nào', () {
      expect(
        policy.canSuggest(isUserSpeaking: false, lastAttemptAt: null, now: now).allowed,
        isTrue,
      );
    });

    test('debounce: bấm lại trong 1s ⇒ chặn; sau 1s ⇒ cho phép (KHÔNG cooldown 12-15s)', () {
      final PolicyDecision tooSoon = policy.canSuggest(
        isUserSpeaking: false,
        lastAttemptAt: now.subtract(const Duration(milliseconds: 900)),
        now: now,
      );
      expect(tooSoon.allowed, isFalse);
      expect(tooSoon.reason, 'debounce');

      final PolicyDecision afterSecond = policy.canSuggest(
        isUserSpeaking: false,
        lastAttemptAt: now.subtract(const Duration(seconds: 5)),
        now: now,
      );
      expect(afterSecond.allowed, isTrue);
    });

    test('anti-repetition: nudge trùng text hoặc type trong 2 phút ⇒ true', () {
      const SuggestionResult ask =
          SuggestionResult.nudge(type: NudgeType.ask, text: 'Hỏi về cuối tuần');
      expect(
        policy.isRepetition(
          result: ask,
          recent: <SuggestionRecord>[
            SuggestionRecord(
              type: NudgeType.ask,
              text: 'Hỏi về cuối tuần',
              at: now.subtract(const Duration(minutes: 1)),
            ),
          ],
          now: now,
        ),
        isTrue,
      );
      // Trùng type (khác text) cũng bị coi là lặp theo prompt "trùng chủ đề/type".
      expect(
        policy.isRepetition(
          result: const SuggestionResult.nudge(type: NudgeType.ask, text: 'Hỏi khác hẳn'),
          recent: <SuggestionRecord>[
            SuggestionRecord(
              type: NudgeType.ask,
              text: 'Hỏi về cuối tuần',
              at: now.subtract(const Duration(minutes: 1)),
            ),
          ],
          now: now,
        ),
        isTrue,
      );
      // Ngoài cửa sổ 2 phút ⇒ không còn là lặp.
      expect(
        policy.isRepetition(
          result: ask,
          recent: <SuggestionRecord>[
            SuggestionRecord(
              type: NudgeType.ask,
              text: 'Hỏi về cuối tuần',
              at: now.subtract(const Duration(minutes: 2, seconds: 1)),
            ),
          ],
          now: now,
        ),
        isFalse,
      );
      // NO_SUGGESTION không cần lọc.
      expect(
        policy.isRepetition(
          result: const SuggestionResult.noSuggestion(),
          recent: const <SuggestionRecord>[],
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('parseSuggestionOutput', () {
    test('parse đúng NO_SUGGESTION', () {
      final SuggestionResult result = parseSuggestionOutput('{"action":"NO_SUGGESTION"}');
      expect(result.isNudge, isFalse);
      expect(result.note, isNull);
    });

    test('parse đúng NUDGE đầy đủ (type + text)', () {
      final SuggestionResult result = parseSuggestionOutput(
        '{"action":"NUDGE","type":"ASK","text":"Hỏi về sở thích"}',
      );
      expect(result.isNudge, isTrue);
      expect(result.type, NudgeType.ask);
      expect(result.text, 'Hỏi về sở thích');
    });

    test('nhận type viết thường + bóc code fence ```json```', () {
      final SuggestionResult result = parseSuggestionOutput(
        '```json\n{"action":"NUDGE","type":"relate","text":"kể tiếp đi"}\n```',
      );
      expect(result.type, NudgeType.relate);
      expect(result.text, 'kể tiếp đi');
    });

    test('6 type của mục 4.5 đều parse được', () {
      expect(
        NudgeType.tryParse('CHANGE_TOPIC'),
        NudgeType.changeTopic,
      );
      expect(NudgeType.tryParse('follow_up'), NudgeType.followUp);
      expect(NudgeType.tryParse('REACT'), NudgeType.react);
      expect(NudgeType.tryParse('clarify'), NudgeType.clarify);
      expect(NudgeType.tryParse('không tồn tại'), isNull);
    });

    test('JSON lỗi ⇒ SuggestionException retryable (không ném loại khác)', () {
      expect(
        () => parseSuggestionOutput('không phải json'),
        throwsA(
          isA<SuggestionException>()
              .having((SuggestionException e) => e.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('REVIEW: `type` không phải chuỗi (vd 123) ⇒ SuggestionException, KHÔNG TypeError', () {
      expect(
        () => parseSuggestionOutput('{"action":"NUDGE","type":123,"text":"x"}'),
        throwsA(isA<SuggestionException>()),
      );
    });

    test('REVIEW: action là số / NUDGE là object ⇒ SuggestionException, KHÔNG TypeError', () {
      expect(
        () => parseSuggestionOutput('{"action":42}'),
        throwsA(isA<SuggestionException>()),
      );
      expect(
        () => parseSuggestionOutput('{"action":"NUDGE","type":"ASK","text":[1,2]}'),
        throwsA(isA<SuggestionException>()),
      );
    });

    test('action lạ / NUDGE thiếu type / NUDGE thiếu text ⇒ SuggestionException', () {
      expect(
        () => parseSuggestionOutput('{"action":"GIKHI"}'),
        throwsA(isA<SuggestionException>()),
      );
      expect(
        () => parseSuggestionOutput('{"action":"NUDGE","text":"chỉ text"}'),
        throwsA(isA<SuggestionException>()),
      );
      expect(
        () => parseSuggestionOutput('{"action":"NUDGE","type":"ASK"}'),
        throwsA(isA<SuggestionException>()),
      );
    });
  });

  group('SuggestionService', () {
    late DateTime current;
    late _FakeStore store;
    late SessionMemory memory;

    setUp(() {
      current = DateTime(2026, 9, 22, 10, 0, 0);
      store = _FakeStore(
        const TranscriptWindow(segments: <TranscriptSegment>[], lastPushMoment: null),
      );
      memory = SessionMemory();
    });

    SuggestionService makeService(_FakeLlm provider) {
      return SuggestionService(
        provider: provider,
        transcript: store,
        memory: memory,
        now: () => current,
      );
    }

    test('userSpeaking ⇒ KHÔNG gọi LLM (bằng chứng: provider 0 lần gọi)', () async {
      final _FakeLlm provider = _FakeLlm(<Object>[]);
      final SuggestionService svc = makeService(provider);
      final SuggestionResult result = await svc.push(isUserSpeaking: true);
      expect(provider.calls, 0);
      expect(result.isNudge, isFalse);
      expect(result.note, contains('userSpeaking'));
    });

    test('debounce: bấm lại trong 1s ⇒ không gọi LLM lần 2', () async {
      final _FakeLlm provider = _FakeLlm(<Object>[
        const SuggestionResult.nudge(type: NudgeType.ask, text: 'Hỏi về cuối tuần'),
      ]);
      final SuggestionService svc = makeService(provider);
      final SuggestionResult first = await svc.push(isUserSpeaking: false);
      expect(first.isNudge, isTrue);
      current = current.add(const Duration(milliseconds: 500));
      final SuggestionResult second = await svc.push(isUserSpeaking: false);
      expect(provider.calls, 1);
      expect(second.isNudge, isFalse);
      expect(second.note, contains('debounce'));
    });

    test('anti-repetition: 2 lần trong 2 phút trùng type ⇒ lần 2 quy về NO_SUGGESTION', () async {
      final _FakeLlm provider = _FakeLlm(<Object>[
        const SuggestionResult.nudge(type: NudgeType.ask, text: 'Hỏi về cuối tuần'),
        const SuggestionResult.nudge(type: NudgeType.ask, text: 'Hỏi chuyện khác hẳn'),
        // Lần 3 (hết 2 phút): nudge trùng lần 1 nhưng đã ngoài cửa sổ ⇒ được phép.
        const SuggestionResult.nudge(type: NudgeType.ask, text: 'Hỏi chuyện khác hẳn'),
      ]);
      final SuggestionService svc = makeService(provider);
      final SuggestionResult first = await svc.push(isUserSpeaking: false);
      expect(first.isNudge, isTrue);
      current = current.add(const Duration(seconds: 10));
      final SuggestionResult second = await svc.push(isUserSpeaking: false);
      expect(second.isNudge, isFalse);
      expect(second.note, 'trùng gợi ý gần đây');
      // Hết 2 phút: cùng nudge đó được phép lại.
      current = current.add(const Duration(minutes: 2, seconds: 1));
      final SuggestionResult third = await svc.push(isUserSpeaking: false);
      expect(third.isNudge, isTrue);
      expect(provider.calls, 3);
    });

    test('JSON lỗi (retryable) 2 lần liên tiếp ⇒ NO_SUGGESTION, đúng 2 lần gọi', () async {
      final _FakeLlm provider = _FakeLlm(<Object>[
        const SuggestionException('JSON hỏng', null, true),
        const SuggestionException('JSON hỏng lần 2', null, true),
      ]);
      final SuggestionService svc = makeService(provider);
      final SuggestionResult result = await svc.push(isUserSpeaking: false);
      expect(result.isNudge, isFalse);
      expect(result.note, contains('JSON hỏng'));
      expect(provider.calls, 2);
    });

    test('JSON lỗi lần 1, lần 2 thành công ⇒ trả nudge', () async {
      final _FakeLlm provider = _FakeLlm(<Object>[
        const SuggestionException('JSON hỏng', null, true),
        const SuggestionResult.nudge(type: NudgeType.clarify, text: 'Ý bạn là sao'),
      ]);
      final SuggestionService svc = makeService(provider);
      final SuggestionResult result = await svc.push(isUserSpeaking: false);
      expect(result.isNudge, isTrue);
      expect(result.type, NudgeType.clarify);
      expect(provider.calls, 2);
    });

    test('timeout/mất mạng (không retryable) ⇒ NO_SUGGESTION NGAY, KHÔNG retry (mục 6)',
        () async {
      final _FakeLlm provider = _FakeLlm(<Object>[
        const SuggestionException('hết thời gian chờ LLM (4000ms)', null, false),
      ]);
      final SuggestionService svc = makeService(provider);
      final SuggestionResult result = await svc.push(isUserSpeaking: false);
      expect(result.isNudge, isFalse);
      expect(result.note, contains('hết thời gian chờ'));
      expect(provider.calls, 1); // KHÔNG retry — không nhân đôi thời gian chờ.
    });

    test('context: prompt chứa transcript không nhãn + mốc Push + không còn placeholder',
        () async {
      final _FakeStore richStore = _FakeStore(
        TranscriptWindow(
          segments: <TranscriptSegment>[
            TranscriptSegment(
              text: 'xin chào bạn khoẻ không',
              timestamp: DateTime(2026, 9, 22, 9, 59, 20),
            ),
          ],
          lastPushMoment: DateTime(2026, 9, 22, 9, 59, 30),
        ),
      );
      final List<SuggestionContext> captured = <SuggestionContext>[];
      final SuggestionService svc = SuggestionService(
        provider: _CapturingLlm(captured),
        transcript: richStore,
        memory: memory,
        now: () => current,
      );
      await svc.push(isUserSpeaking: false);
      expect(captured, hasLength(1));
      final SuggestionContext context = captured.single;
      // Prompt khung nguyên văn (dòng đầu + phần quy tắc).
      expect(context.prompt, startsWith('Bạn là trợ lý huấn luyện giao tiếp.'));
      expect(context.prompt, contains('Ưu tiên hành động (ASK / FOLLOW_UP / RELATE / REACT / CLARIFY / CHANGE_TOPIC)'));
      // Placeholder đã được thay: các vị trí Context dùng giá trị thật — không còn dạng
      // `{recent_30s}`/`{push_timestamp}`/... (dấu `{` trong phần quy tắc là JSON mẫu của
      // prompt gốc, phải còn nguyên).
      expect(context.prompt.contains('{recent_30s}'), isFalse);
      expect(context.prompt.contains('{push_timestamp}'), isFalse);
      expect(context.prompt.contains('{pre_brief}'), isFalse);
      expect(context.prompt.contains('{summary}'), isFalse);
      expect(context.prompt.contains('{explored}'), isFalse);
      expect(context.prompt.contains('{recent_suggestions}'), isFalse);
      expect(context.prompt, contains('{"action":"NO_SUGGESTION"}'));
      expect(context.prompt, contains('xin chào bạn khoẻ không'));
      expect(context.prompt, contains('ngày 22/09/2026'));
      // Transcript không có nhãn speaker.
      expect(context.prompt.contains('[Bạn]'), isFalse);
      expect(context.prompt.contains('Bạn:'), isFalse);
    });

    test('REVIEW: provider ném lỗi KHÔNG phải SuggestionException ⇒ NO_SUGGESTION, KHÔNG ném',
        () async {
      // Hợp đồng "push() không bao giờ ném" phải chịu được cả lỗi ngoài dự kiến (provider mới,
      // cast lỗi, bug trong thư viện...) — không chỉ SuggestionException.
      final SuggestionService svc = SuggestionService(
        provider: _ThrowingLlm(TypeError()),
        transcript: store,
        memory: memory,
        now: () => current,
      );
      final SuggestionResult result = await svc.push(isUserSpeaking: false);
      expect(result.isNudge, isFalse);
    });

    test('transcript lỗi (SQLite) ⇒ NO_SUGGESTION, KHÔNG ném ra ngoài', () async {
      final SuggestionService svc = SuggestionService(
        provider: _FakeLlm(<Object>[
          const SuggestionResult.nudge(type: NudgeType.ask, text: 'không được gọi tới'),
        ]),
        transcript: _BrokenStore(),
        memory: memory,
        now: () => current,
      );
      // Hợp đồng của push(): KHÔNG BAO GIỜ ném — mọi lỗi quy về NO_SUGGESTION.
      final SuggestionResult result = await svc.push(isUserSpeaking: false);
      expect(result.isNudge, isFalse);
      expect(result.note, 'lỗi đọc transcript');
    });

    test('resetSession xoá debounce + bộ nhớ (bấm lại ngay không bị chặn)', () async {
      final _FakeLlm provider = _FakeLlm(<Object>[
        const SuggestionResult.nudge(type: NudgeType.ask, text: 'A'),
        const SuggestionResult.nudge(type: NudgeType.ask, text: 'B'),
      ]);
      final SuggestionService svc = makeService(provider);
      await svc.push(isUserSpeaking: false);
      svc.resetSession();
      current = current.add(const Duration(seconds: 5));
      final SuggestionResult again = await svc.push(isUserSpeaking: false);
      expect(again.isNudge, isTrue);
      expect(provider.calls, 2);
    });
  });

  group('SuggestionContextBuilder — prompt khung NGUYÊN VĂN', () {
    const List<String> requiredLines = <String>[
      'Bạn là trợ lý huấn luyện giao tiếp. Người dùng ít nói, đang lo âu xã hội.',
      'Nhiệm vụ: đưa ra tối đa 1 nudge ngắn (2-4 từ) hoặc NO_SUGGESTION.',
      '- Chỉ trả về JSON đúng format.',
      '- Không gợi ý chủ đề đã explored hoặc đã gợi ý trong 2 phút gần nhất.',
      '- Ưu tiên hành động (ASK / FOLLOW_UP / RELATE / REACT / CLARIFY / CHANGE_TOPIC).',
      '- Nếu không có gì đáng nói → {"action":"NO_SUGGESTION"}',
      '- Không bao giờ viết câu hoàn chỉnh dài.',
      '- Transcript dưới đây KHÔNG có nhãn người nói. Hãy tự suy luận ai đang nói dựa vào',
      '  ngữ cảnh, câu hỏi/câu trả lời, xưng hô. "Mốc Push" đánh dấu thời điểm người dùng',
      '  vừa bấm nút xin gợi ý — lượt nói của người dùng có khả năng vừa kết thúc quanh đó.',
      'Context:',
      '- Pre-brief: {pre_brief}',
      '- Session summary: {summary}',
      '- Recent transcript (không nhãn speaker): {recent_30s}',
      '- Mốc Push gần nhất: {push_timestamp}',
      '- Topics explored: {explored}',
      '- Last suggestions: {recent_suggestions}',
    ];

    test('template có đủ MỌI dòng của prompt khung gốc (bảo vệ chống sửa ngầm)', () {
      // buildPrompt thay placeholder sau khi ghép — kiểm từng dòng TRƯỚC khi thay bằng cách
      // so với bản đã thay giá trị sentinel: mỗi dòng gốc phải còn nguyên (chỉ khác phần giá trị).
      final String prompt = SuggestionContextBuilder.buildPrompt(
        preBrief: '',
        summary: '',
        recentTranscript: '',
        pushTimestamp: '',
        explored: const <String>[],
        recentSuggestions: const <String>[],
      );
      for (final String line in requiredLines) {
        final String expected = line
            .replaceAll('{pre_brief}', '(chưa có)')
            .replaceAll('{summary}', '(chưa có)')
            .replaceAll('{recent_30s}', '(chưa có)')
            .replaceAll('{push_timestamp}', '(chưa bấm)')
            .replaceAll('{explored}', '(chưa có)')
            .replaceAll('{recent_suggestions}', '(chưa có)');
        expect(prompt.contains(expected), isTrue, reason: 'thiếu dòng: $expected');
      }
      // Đúng thứ tự các dòng Context (indexOf tìm thấy đầu tiên trong bản đã thay).
      final int preBriefPos = prompt.indexOf('- Pre-brief:');
      final int summaryPos = prompt.indexOf('- Session summary:');
      final int recentPos = prompt.indexOf('- Recent transcript');
      final int pushPos = prompt.indexOf('- Mốc Push gần nhất:');
      final int exploredPos = prompt.indexOf('- Topics explored:');
      final int lastPos = prompt.indexOf('- Last suggestions:');
      expect(preBriefPos, lessThan(summaryPos));
      expect(summaryPos, lessThan(recentPos));
      expect(recentPos, lessThan(pushPos));
      expect(pushPos, lessThan(exploredPos));
      expect(exploredPos, lessThan(lastPos));
    });

    test('giá trị thật được thay vào đúng vị trí', () {
      final String prompt = SuggestionContextBuilder.buildPrompt(
        preBrief: 'buổi networking',
        summary: 'đã chào nhau',
        recentTranscript: 'chào bạn mình là Nam',
        pushTimestamp: SuggestionContextBuilder.formatPushTimestamp(
          DateTime(2026, 9, 22, 10, 0, 5),
        ),
        explored: <String>['cuối tuần'],
        recentSuggestions: <String>['ASK: hỏi cuối tuần'],
      );
      expect(prompt, contains('- Pre-brief: buổi networking'));
      expect(prompt, contains('- Session summary: đã chào nhau'));
      expect(
          prompt, contains('- Recent transcript (không nhãn speaker): chào bạn mình là Nam'));
      expect(prompt, contains('- Mốc Push gần nhất: 10:00:05 ngày 22/09/2026'));
      expect(prompt, contains('- Topics explored: cuối tuần'));
      expect(prompt, contains('- Last suggestions: ASK: hỏi cuối tuần'));
    });
  });

  group('GroqLlmProvider (http.Client giả)', () {
    test('HTTP 200 hợp lệ ⇒ parse đúng nudge + đúng endpoint/model/header', () async {
      late http.Request capturedRequest;
      final MockClient client = MockClient((http.Request request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': '{"action":"NUDGE","type":"ASK","text":"Hỏi về công việc"}',
                },
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final GroqLlmProvider provider = GroqLlmProvider(
        client: client,
        apiKeyReader: () async => 'test-key',
      );
      final SuggestionResult result = await provider.generateSuggestion(_context());
      expect(result.isNudge, isTrue);
      expect(result.type, NudgeType.ask);
      expect(result.text, 'Hỏi về công việc');
      expect(capturedRequest.url.toString(), SuggestionConfig.groqEndpoint);
      expect(capturedRequest.headers['Authorization'], 'Bearer test-key');
      final Map<String, dynamic> body = jsonDecode(capturedRequest.body) as Map<String, dynamic>;
      expect(body['model'], SuggestionConfig.groqModel);
      expect(body['response_format'], <String, String>{'type': 'json_object'});
      // Prompt khung đi nguyên văn trong 1 message user.
      final List<dynamic> messages = body['messages'] as List<dynamic>;
      expect(messages, hasLength(1));
      expect((messages.first as Map<String, dynamic>)['role'], 'user');
      expect((messages.first as Map<String, dynamic>)['content'], 'test prompt');
    });

    test('HTTP 500 ⇒ SuggestionException không-retryable', () async {
      final MockClient client =
          MockClient((http.Request request) async => http.Response('server error', 500));
      final GroqLlmProvider provider = GroqLlmProvider(
        client: client,
        apiKeyReader: () async => 'test-key',
      );
      await expectLater(
        provider.generateSuggestion(_context()),
        throwsA(
          isA<SuggestionException>()
              .having((SuggestionException e) => e.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('SocketException (offline) ⇒ SuggestionException — fail gracefully', () async {
      final MockClient client = MockClient((http.Request request) async {
        throw const SocketException('offline');
      });
      final GroqLlmProvider provider = GroqLlmProvider(
        client: client,
        apiKeyReader: () async => 'test-key',
      );
      await expectLater(
        provider.generateSuggestion(_context()),
        throwsA(isA<SuggestionException>()),
      );
    });

    test('timeout của http client ⇒ TimeoutException được bọc thành SuggestionException',
        () async {
      final MockClient client = MockClient((http.Request request) async {
        // Giả lập chậm hơn timeout 4s: dùng .timeout ở tầng provider — giả lập bằng client
        // trả sau 100ms với timeout 10ms.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return http.Response('{}', 200);
      });
      final GroqLlmProvider provider = GroqLlmProvider(
        client: client,
        apiKeyReader: () async => 'test-key',
        timeout: const Duration(milliseconds: 10),
      );
      await expectLater(
        provider.generateSuggestion(_context()),
        throwsA(isA<SuggestionException>()),
      );
    });

    test('thiếu API key ⇒ SuggestionException, KHÔNG gọi network', () async {
      var networkCalled = false;
      final MockClient client = MockClient((http.Request request) async {
        networkCalled = true;
        return http.Response('{}', 200);
      });
      final GroqLlmProvider provider = GroqLlmProvider(
        client: client,
        apiKeyReader: () async => null,
      );
      await expectLater(
        provider.generateSuggestion(_context()),
        throwsA(isA<SuggestionException>()),
      );
      expect(networkCalled, isFalse);
    });

    test('REVIEW: `choices` không đúng dạng (chuỗi / phần tử không phải object) ⇒ SuggestionException',
        () async {
      // Envelope dị dạng: nếu code cast cứng sẽ ném TypeError (KHÔNG phải SuggestionException)
      // ⇒ service không bắt được ⇒ `push()` ném ra UI.
      for (final String body in <String>[
        '{"choices":"không phải list"}',
        '{"choices":["phần tử không phải object"]}',
        '{"choices":[{"message":"không phải object"}]}',
        '{"choices":[{"message":{"content":123}}]}',
      ]) {
        final MockClient client = MockClient((http.Request request) async =>
            http.Response(body, 200, headers: <String, String>{'content-type': 'application/json'}));
        final GroqLlmProvider provider = GroqLlmProvider(
          client: client,
          apiKeyReader: () async => 'test-key',
        );
        await expectLater(
          provider.generateSuggestion(_context()),
          throwsA(isA<SuggestionException>()),
          reason: 'body: $body',
        );
      }
    });

    test('thân phản hồi thiếu content ⇒ SuggestionException', () async {
      final MockClient client = MockClient((http.Request request) async =>
          http.Response(jsonEncode(<String, dynamic>{'choices': <Object?>[]}), 200));
      final GroqLlmProvider provider = GroqLlmProvider(
        client: client,
        apiKeyReader: () async => 'test-key',
      );
      await expectLater(
        provider.generateSuggestion(_context()),
        throwsA(isA<SuggestionException>()),
      );
    });
  });
}
