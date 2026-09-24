// Test P5.4 phần A — timeout tách theo đúng use-case.
//
// Khoá 4 điều, đúng theo DoD của `.plan/prompt_P5_4.md`:
// 1. Push (gợi ý realtime) VẪN timeout ở mốc 4s cũ — không bị phase này làm hỏng.
// 2. Post-Review chờ được LLM trả lời sau 4.5s (mốc 4s cũ sẽ đã cắt ngang) ⇒ dùng `postReviewTimeout`.
// 3. Session Summary cũng theo mốc 5 phút (không chặn cuộc trò chuyện).
// 4. Test LLM: mặc định 30s (trước 12s) + client mặc định có `connectionTimeout` ở tầng socket.
//
// Cách đo thời gian: `fakeAsync` (đồng hồ giả) — cùng cách `conversation_state_test.dart` đã dùng cho
// watchdog. Không dùng `await Future.delayed` thật để "chờ xem có timeout không": chậm, và dễ flaky.
// Mọi HTTP đi qua client giả trả lời SAU một độ trễ cho trước (không gọi mạng thật).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:ai_assistant_phone/coaching/post_review_service.dart';
import 'package:ai_assistant_phone/coaching/pre_brief.dart';
import 'package:ai_assistant_phone/coaching/session_summary.dart';
import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';
import 'package:ai_assistant_phone/services/storage/transcript_dao.dart';
import 'package:ai_assistant_phone/suggestion/groq_llm_provider.dart';
import 'package:ai_assistant_phone/suggestion/llm_http_client.dart';
import 'package:ai_assistant_phone/suggestion/llm_provider.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_models.dart';
import 'package:ai_assistant_phone/suggestion/test_llm_service.dart';
import 'package:ai_assistant_phone/transcript/transcript_store.dart';

class _FakeConfigStore implements ConfigStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// Client giả: trả về chat completions SAU [delay] (đồng hồ giả của `fakeAsync` điều khiển được).
class _SlowChatClient extends http.BaseClient {
  _SlowChatClient({required this.delay, required this.content});

  final Duration delay;
  final String content;

  /// Số request thực tế đã gửi — để khẳng định retry/timeout không nhân đôi request.
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    await Future<void>.delayed(delay);
    final String body = jsonEncode(<String, Object?>{
      'choices': <Object?>[
        <String, Object?>{
          'message': <String, Object?>{'content': content},
        },
      ],
    });
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
      contentLength: body.length,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
}

/// Transcript giả cho Post-Review/Session Summary (đường `run()` / `maybeRefresh()`).
class _FakeTranscript implements TranscriptStore {
  @override
  int? sessionId = 7;

  @override
  Future<SessionTranscript> sessionTranscript({int maxChars = 6000}) async =>
      const SessionTranscript(text: 'dạ em chào anh', segmentCount: 2, truncated: false);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeTranscript không hỗ trợ ${invocation.memberName}');
}

/// Bắt lời lưu báo cáo — để khẳng định Post-Review đã chạy **hết đường** (không bị timeout cắt ngang).
class _RecordingSink implements ReportSink {
  final List<PostReviewReportRow> saved = <PostReviewReportRow>[];

  @override
  Future<void> save(PostReviewReportRow report) async => saved.add(report);
}

void main() {
  group('P5.4 — hằng số timeout tách theo use-case', () {
    test('Push GIỮ NGUYÊN 4s; Post-Review/Summary có mốc riêng 5 phút; socket connect 10s', () {
      expect(SuggestionConfig.llmTimeout, const Duration(seconds: 4),
          reason: 'Push là ràng buộc UX cứng — phase này không được đổi');
      expect(SuggestionConfig.postReviewTimeout, const Duration(minutes: 5));
      expect(SuggestionConfig.postReviewTimeout, greaterThan(SuggestionConfig.llmTimeout));
      expect(SuggestionConfig.socketConnectTimeout, const Duration(seconds: 10));
    });
  });

  group('DoD 1 — Push vẫn timeout đúng ở ~4s (không bị ảnh hưởng)', () {
    test('LLM trả lời sau 4.5s ⇒ Push ném SuggestionException ở mốc 4s', () {
      fakeAsync((FakeAsync async) {
        final _SlowChatClient client = _SlowChatClient(
          delay: const Duration(milliseconds: 4500),
          content: 'OK',
        );
        final GroqLlmProvider provider = GroqLlmProvider(
          client: client,
          apiKeyReader: () async => 'sk-x',
          endpoint: Uri.parse('https://llm.example.com/v1/chat/completions'),
        );
        expect(provider.timeout, const Duration(seconds: 4),
            reason: 'provider mặc định phải vẫn là mốc của Push');

        Object? error;
        bool finished = false;
        unawaited(
          provider
              .generateSuggestion(
                const SuggestionContext(
                  prompt: 'prompt giả',
                  recentTranscript: 'a',
                  pushTimestamp: '20:00',
                  topicsExplored: <String>[],
                  lastSuggestions: <String>[],
                ),
              )
              .then<void>((_) {}, onError: (Object e) => error = e)
              .whenComplete(() => finished = true),
        );

        async.elapse(const Duration(milliseconds: 3900));
        expect(finished, isFalse, reason: 'chưa tới 4s thì chưa được bỏ cuộc');
        expect(error, isNull);

        async.elapse(const Duration(milliseconds: 200));
        expect(finished, isTrue, reason: 'quá 4s phải dừng chờ (NO_SUGGESTION ở tầng service)');
        expect(error, isA<SuggestionException>());
        expect('$error', contains('thời gian chờ'));
        expect(client.calls, 1, reason: 'timeout không được nhân đôi request');
      });
    });
  });

  group('DoD 2 — Post-Review dùng postReviewTimeout (không còn bị cắt ở 4s)', () {
    test('LLM trả lời sau 4.5s ⇒ Post-Review vẫn đi hết và lưu báo cáo', () {
      fakeAsync((FakeAsync async) {
        final _SlowChatClient client = _SlowChatClient(
          delay: const Duration(milliseconds: 4500),
          content: '{"good":"g","missed":"m","exercise":"e"}',
        );
        final _RecordingSink sink = _RecordingSink();
        final PostReviewService service = PostReviewService(
          llmClient: client,
          llmApiKeyReader: () async => 'sk-x',
          llmConfigStore: _FakeConfigStore(),
          transcript: _FakeTranscript(),
          preBriefs: PreBriefStore(store: _FakeConfigStore()),
          reportSink: sink,
        );

        PostReviewReport? report;
        unawaited(service.run().then((PostReviewReport r) => report = r));

        async.elapse(const Duration(milliseconds: 4400));
        expect(report, isNull,
            reason: 'đang chờ ở 4.4s — mốc 4s cũ sẽ đã trả báo cáo "hết thời gian chờ"');

        async.elapse(const Duration(seconds: 1));
        expect(report, isNotNull);
        expect(report!.isUsable, isTrue);
        expect(report!.fromLlm, isTrue);
        expect(sink.saved, hasLength(1));
        expect(client.calls, 1);
      });
    });

    test('LLM quá chậm (vượt cả 5 phút) ⇒ vẫn dừng đúng mốc postReviewTimeout', () {
      fakeAsync((FakeAsync async) {
        final _SlowChatClient client = _SlowChatClient(
          delay: const Duration(minutes: 30),
          content: '{"good":"g","missed":"m","exercise":"e"}',
        );
        final PostReviewService service = PostReviewService(
          llmClient: client,
          llmApiKeyReader: () async => 'sk-x',
          llmConfigStore: _FakeConfigStore(),
          transcript: _FakeTranscript(),
          preBriefs: PreBriefStore(store: _FakeConfigStore()),
          reportSink: _RecordingSink(),
        );

        PostReviewReport? report;
        unawaited(service.run().then((PostReviewReport r) => report = r));

        async.elapse(const Duration(minutes: 6));
        expect(report, isNotNull);
        expect(report!.isUsable, isFalse);
        expect(report!.infrastructureFailure, isTrue,
            reason: 'timeout là lỗi hạ tầng ⇒ lượt phân tích bù phải dừng');
      });
    });
  });

  group('DoD 3 — Session Summary cũng dùng mốc 5 phút', () {
    test('LLM trả lời sau 4.5s ⇒ bản tóm tắt vẫn được cập nhật', () {
      fakeAsync((FakeAsync async) {
        final _SlowChatClient client = _SlowChatClient(
          delay: const Duration(milliseconds: 4500),
          content: 'Đã nói về công việc, còn dang dở chuyện cuối tuần.',
        );
        final SessionSummaryService summaries = SessionSummaryService(
          llmClient: client,
          llmApiKeyReader: () async => 'sk-x',
          llmConfigStore: _FakeConfigStore(),
          transcript: _FakeTranscript(),
        );

        unawaited(summaries.maybeRefresh(nudgeCount: CoachingConfig.summaryEveryNudges));

        async.elapse(const Duration(milliseconds: 4400));
        expect(summaries.summary, isEmpty, reason: 'mốc 4s cũ sẽ đã bỏ lượt tóm tắt này');

        async.elapse(const Duration(seconds: 1));
        expect(summaries.summary, isNotEmpty);
        expect(summaries.refreshCount, 1);
        expect(summaries.lastNote, isNull);
      });
    });
  });

  group('DoD 4 — Test LLM: 30s + client mặc định có socket timeout', () {
    test('mặc định 30s (không còn 12s) và chờ được endpoint chậm 20s', () {
      expect(TestLlmService().timeout, const Duration(seconds: 30));

      fakeAsync((FakeAsync async) {
        final _SlowChatClient client = _SlowChatClient(
          delay: const Duration(seconds: 20),
          content: 'OK',
        );
        final TestLlmService service = TestLlmService(
          client: client,
          apiKeyReader: () async => 'sk-x',
          configStore: _FakeConfigStore(),
        );

        LlmTestResult? result;
        unawaited(service.run().then((LlmTestResult r) => result = r));

        async.elapse(const Duration(seconds: 13));
        expect(result, isNull,
            reason: 'mốc 12s cũ sẽ đã báo timeout sai nguyên nhân (endpoint chỉ chậm 20s)');

        async.elapse(const Duration(seconds: 8));
        expect(result, isNotNull);
        expect(result!.isSuccess, isTrue,
            reason: 'endpoint chậm 20s vẫn phải test THÀNH CÔNG, không báo timeout oan');
      });
    });

    test('client mặc định: IOClient + connectionTimeout đặt thật lên HttpClient', () {
      final HttpClient inner = HttpClient();
      final http.Client client = defaultLlmHttpClient(inner: inner);

      expect(client, isA<IOClient>());
      expect(inner.connectionTimeout, SuggestionConfig.socketConnectTimeout,
          reason: 'lớp phòng thủ ở tầng socket phải được đặt trên client mặc định');
      inner.close(force: true);
    });
  });

  group('P5.4 — không lệch hành vi cũ khi caller tự truyền provider', () {
    test('Post-Review dùng provider bơm vào thì timeout của provider đó vẫn được tôn trọng', () {
      fakeAsync((FakeAsync async) {
        // Provider bơm vào với mốc rất ngắn: service KHÔNG được ghi đè timeout của provider.
        final GroqLlmProvider provider = GroqLlmProvider(
          client: _SlowChatClient(
            delay: const Duration(seconds: 30),
            content: '{"good":"g","missed":"m","exercise":"e"}',
          ),
          apiKeyReader: () async => 'sk-x',
          endpoint: Uri.parse('https://llm.example.com/v1/chat/completions'),
          timeout: const Duration(seconds: 5),
        );
        final PostReviewService service = PostReviewService(
          provider: provider,
          transcript: _FakeTranscript(),
          preBriefs: PreBriefStore(store: _FakeConfigStore()),
          reportSink: _RecordingSink(),
        );

        PostReviewReport? report;
        unawaited(service.run().then((PostReviewReport r) => report = r));

        async.elapse(const Duration(seconds: 6));
        expect(report?.isUsable, isFalse);
        expect(report?.infrastructureFailure, isTrue);
      });
    });

    test('SessionSummaryService: `llmConfigStore` null ⇒ hành vi y hệt trước P2.1 (không crash)', () async {
      final SessionSummaryService summaries = SessionSummaryService(
        provider: _StubTextLlm(),
        transcript: _FakeTranscript(),
      );
      await summaries.maybeRefresh(nudgeCount: CoachingConfig.summaryEveryNudges);
      expect(summaries.summary, 'tóm tắt giả');
    });
  });
}

class _StubTextLlm implements TextLlmProvider {
  @override
  Future<String> complete({required String prompt, int maxTokens = 200}) async => 'tóm tắt giả';
}
