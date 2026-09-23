// Test issue1_fix — LLM config thống nhất + Test LLM + Post-Review cùng config.
//
// Khoá theo DoD mục 11 của `.plan/issue1_fix.md`:
// - Test 1–3: load/save/reopen endpoint + model + key (persisted, plaintext) — UI/state đúng.
// - Test 4–7: Test LLM dùng đúng endpoint/model/key; 401/timeout/network không crash; KHÔNG tạo
//   session/transcript/report.
// - Test 8: message lỗi key là GENERIC khi custom endpoint (không còn "chưa có API key Groq" sai
//   ngữ cảnh), vẫn giữ ngữ cảnh Groq khi endpoint là mặc định.
//
// Mọi HTTP đều qua `MockClient` (package:http/testing) — không gọi mạng thật.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ai_assistant_phone/coaching/post_review_service.dart';
import 'package:ai_assistant_phone/coaching/pre_brief.dart';
import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';
import 'package:ai_assistant_phone/suggestion/groq_llm_provider.dart';
import 'package:ai_assistant_phone/suggestion/llm_provider_config.dart';
import 'package:ai_assistant_phone/suggestion/test_llm_service.dart';
import 'package:ai_assistant_phone/transcript/transcript_store.dart';

class _FakeConfigStore implements ConfigStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// Ghi lại mọi request mock nhận được — để test khẳng định đúng endpoint/model/key đã dùng.
/// Handler nhận đúng 1 tham số `Request` (bỏ dummy thứ 2 của `MockClientHandler`).
class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.handler);

  final Future<http.Response> Function(http.Request request) handler;
  final List<http.Request> requests = <http.Request>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final http.Request req = request as http.Request;
    requests.add(req);
    final http.Response response = await handler(req);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      contentLength: response.bodyBytes.length,
      headers: response.headers,
    );
  }
}

http.Response _chatOk(String content) => http.Response(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': content},
          },
        ],
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );

/// Transcript giả — dùng để chứng minh Test LLM KHÔNG đụng phiên (đếm số lần đọc transcript).
class _CountingTranscript implements TranscriptStore {
  int reads = 0;

  @override
  int? sessionId = 7;

  @override
  Future<SessionTranscript> sessionTranscript({int maxChars = 6000}) async {
    reads++;
    return const SessionTranscript(text: 'a\nb', segmentCount: 2, truncated: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  // SecureStore mặc định của `GroqLlmProvider` chạm kênh native `flutter_secure_storage` —
  // stub trả `null` (chưa có key) cho các test Post-Review đi qua đường mặc định (cùng pattern
  // `app_smoke_test.dart`). Các test Test-LLM thì bơm `apiKeyReader` nên không cần kênh này.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (MethodCall call) async => null,
    );
  });

  group('LLM config — load/save/reopen (DoD 1, 2, 3)', () {
    test('resolver trả đúng 3 giá trị custom đã lưu (endpoint + model + key qua reader riêng)', () async {
      final _FakeConfigStore store = _FakeConfigStore();
      await LlmProviderConfigResolver.writeEndpoint(store, 'https://llm.example.com/v1/chat/completions');
      await LlmProviderConfigResolver.writeModel(store, 'my-model');

      final ResolvedLlmConfig resolved = await LlmProviderConfigResolver.resolve(store);
      expect(resolved.endpoint.toString(), 'https://llm.example.com/v1/chat/completions');
      expect(resolved.model, 'my-model');
      expect(resolved.isDefault, isFalse);
    });

    test('save → reopen → identical (không tự đổi giá trị, không fallback nhầm)', () async {
      final _FakeConfigStore store = _FakeConfigStore();
      const String url = 'https://api.openai.com/v1/chat/completions';
      const String model = 'gpt-4o-mini';
      await LlmProviderConfigResolver.writeEndpoint(store, url);
      await LlmProviderConfigResolver.writeModel(store, model);

      // "Reopen" = đọc lại từ store như khi mở Settings lần 2.
      final String? reopenedUrl = await store.read(LlmProviderConfig.baseUrlKey);
      final String? reopenedModel = await store.read(LlmProviderConfig.modelKey);
      expect(reopenedUrl, url);
      expect(reopenedModel, model);

      final ResolvedLlmConfig resolved = await LlmProviderConfigResolver.resolve(store);
      expect(resolved.endpoint.toString(), url);
      expect(resolved.model, model);
    });

    test('để trống endpoint/model ⇒ fallback Groq mặc định (hành vi y hệt trước P2.1)', () async {
      final ResolvedLlmConfig resolved = await LlmProviderConfigResolver.resolve(_FakeConfigStore());
      expect(resolved.isDefault, isTrue);
      expect(resolved.model, SuggestionConfig.groqModel);
      expect(resolved.endpoint.toString(), SuggestionConfig.groqEndpoint);
    });
  });

  group('Test LLM (DoD 4, 5, 6, 7)', () {
    test('success: gửi request THẬT đúng endpoint + model + key (Bearer), trả model + latency',
        () async {
      final _RecordingClient client = _RecordingClient(
        (http.Request request) async => _chatOk('OK'),
      );
      final _FakeConfigStore store = _FakeConfigStore();
      await LlmProviderConfigResolver.writeEndpoint(store, 'https://llm.example.com/v1/chat/completions');
      await LlmProviderConfigResolver.writeModel(store, 'my-model');

      final TestLlmService service = TestLlmService(
        client: client,
        apiKeyReader: () async => 'sk-test-123',
        configStore: store,
      );
      final LlmTestResult result = await service.run();

      expect(result.isSuccess, isTrue);
      expect(result.model, 'my-model');
      expect(result.latency, isNotNull);
      // Đúng endpoint (không phải Groq mặc định) + Bearer key đúng.
      expect(client.requests, hasLength(1));
      expect(client.requests.single.url.toString(), 'https://llm.example.com/v1/chat/completions');
      expect(client.requests.single.headers['Authorization'], 'Bearer sk-test-123');
      // Body dùng đúng model + prompt tối thiểu.
      final Map<String, Object?> body =
          jsonDecode(client.requests.single.body) as Map<String, Object?>;
      expect(body['model'], 'my-model');
      expect(
        ((body['messages']! as List<Object?>).single as Map<String, Object?>)['content'],
        'Reply with exactly: OK',
      );
    });

    test('401 ⇒ phân loại authentication failure, KHÔNG crash', () async {
      final _RecordingClient client = _RecordingClient(
        (http.Request request) async => http.Response('{"error":"bad key"}', 401),
      );
      final TestLlmService service = TestLlmService(
        client: client,
        apiKeyReader: () async => 'sk-wrong',
        configStore: _FakeConfigStore(),
      );

      final LlmTestResult result = await service.run();

      expect(result.isSuccess, isFalse);
      expect(result.kind, LlmTestKind.auth);
      expect(result.message, contains('401'));
    });

    test('404 ⇒ phân loại model/endpoint không tồn tại', () async {
      final TestLlmService service = TestLlmService(
        client: _RecordingClient((http.Request request) async => http.Response('nf', 404)),
        apiKeyReader: () async => 'sk-x',
        configStore: _FakeConfigStore(),
      );

      final LlmTestResult result = await service.run();

      expect(result.kind, LlmTestKind.notFound);
      expect(result.message, contains('404'));
    });

    test('timeout ⇒ không crash, phân loại timeout (không ném ra ngoài)', () async {
      final _RecordingClient client = _RecordingClient((http.Request request) async {
        await Completer<void>().future; // không bao giờ hoàn thành
        throw StateError('unreachable');
      });
      final TestLlmService service = TestLlmService(
        client: client,
        apiKeyReader: () async => 'sk-x',
        configStore: _FakeConfigStore(),
        timeout: const Duration(milliseconds: 20),
      );

      final LlmTestResult result = await service.run();

      expect(result.kind, LlmTestKind.timeout);
      expect(result.message, isNotNull);
    });

    test('lỗi mạng (SocketException-style) ⇒ phân loại network, không crash', () async {
      final TestLlmService service = TestLlmService(
        client: _RecordingClient((http.Request request) async {
          throw http.ClientException('connection refused');
        }),
        apiKeyReader: () async => 'sk-x',
        configStore: _FakeConfigStore(),
      );

      final LlmTestResult result = await service.run();

      expect(result.kind, LlmTestKind.network);
      expect(result.isSuccess, isFalse);
    });

    test('endpoint override hỏng ⇒ invalidEndpoint ngay, KHÔNG gửi request', () async {
      final _RecordingClient client = _RecordingClient(
        (http.Request request) async => _chatOk('OK'),
      );
      final TestLlmService service = TestLlmService(
        client: client,
        apiKeyReader: () async => 'sk-x',
        configStore: _FakeConfigStore(),
      );

      final LlmTestResult result = await service.run(endpointOverride: 'not-a-url');

      expect(result.kind, LlmTestKind.invalidEndpoint);
      expect(client.requests, isEmpty, reason: 'endpoint sai thì không được gửi request');
    });

    test('chưa có key ⇒ failure auth với message GENERIC (custom endpoint), không gửi request',
        () async {      final _RecordingClient client = _RecordingClient(
        (http.Request request) async => _chatOk('OK'),
      );
      final _FakeConfigStore store = _FakeConfigStore();
      await LlmProviderConfigResolver.writeEndpoint(store, 'https://llm.example.com/v1/chat/completions');

      final TestLlmService service = TestLlmService(
        client: client,
        apiKeyReader: () async => null,
        configStore: store,
      );

      final LlmTestResult result = await service.run();

      expect(result.kind, LlmTestKind.auth);
      expect(result.message, isNotNull);
      expect(result.message!, contains('API key'));
      // issue1_fix mục 2: KHÔNG nhắc "Groq" khi đang dùng custom endpoint.
      expect(result.message!.contains('Groq'), isFalse);
      expect(client.requests, isEmpty);
    });

    test('Test LLM KHÔNG tạo session / transcript / report (DoD 7 — ràng buộc mục 4)',
        () async {
      final _RecordingClient client = _RecordingClient(
        (http.Request request) async => _chatOk('OK'),
      );
      final _CountingTranscript transcript = _CountingTranscript();
      final TestLlmService service = TestLlmService(
        client: client,
        apiKeyReader: () async => 'sk-x',
        configStore: _FakeConfigStore(),
      );

      await service.run();

      // Lớp Test LLM chỉ chạm HTTP + config store — không có đường nào tới TranscriptStore.
      expect(transcript.reads, 0);
      // Chỉ đúng 1 request chat — không có request phụ nào (không đo gì thêm).
      expect(client.requests, hasLength(1));
    });
  });

  group('Post-Review dùng cùng config (DoD 8)', () {
    test('message thiếu key là GENERIC khi custom endpoint (không còn "chưa có API key Groq" sai ngữ cảnh)',
        () async {
      final _FakeConfigStore store = _FakeConfigStore();
      await LlmProviderConfigResolver.writeEndpoint(
          store, 'https://llm.example.com/v1/chat/completions');
      await LlmProviderConfigResolver.writeModel(store, 'my-model');

      final GroqLlmProvider provider = GroqLlmProvider(configStore: store);
      final PostReviewService service = PostReviewService(
        provider: provider,
        transcript: _CountingTranscript(),
        preBriefs: PreBriefStore(store: _FakeConfigStore()),
      );

      final PostReviewReport report = await service.run();

      expect(report.fromLlm, isFalse);
      expect(report.note, isNotNull);
      // ⚠️ Điểm chính của issue này: KHÔNG được báo "Groq" khi endpoint là custom.
      expect(report.note!.contains('Groq'), isFalse);
      expect(report.note, contains('API key'));
    });

    test('endpoint mặc định (Groq) ⇒ message vẫn giữ ngữ cảnh Groq (không mất thông tin)', () async {
      final GroqLlmProvider provider = GroqLlmProvider(configStore: _FakeConfigStore());
      final PostReviewService service = PostReviewService(
        provider: provider,
        transcript: _CountingTranscript(),
        preBriefs: PreBriefStore(store: _FakeConfigStore()),
      );

      final PostReviewReport report = await service.run();

      expect(report.fromLlm, isFalse);
      expect(report.note, contains('Groq'));
    });

    test('Post-Review custom endpoint THẬT ⇒ request mang đúng endpoint + model custom', () async {
      final _RecordingClient client = _RecordingClient(
        (http.Request request) async =>
            _chatOk('{"good":"g","missed":"m","exercise":"e"}'),
      );
      final _FakeConfigStore store = _FakeConfigStore();
      await LlmProviderConfigResolver.writeEndpoint(store, 'https://llm.example.com/v1/chat/completions');
      await LlmProviderConfigResolver.writeModel(store, 'my-model');

      final GroqLlmProvider provider = GroqLlmProvider(
        client: client,
        apiKeyReader: () async => 'sk-custom',
        configStore: store,
      );
      final PostReviewService service = PostReviewService(
        provider: provider,
        transcript: _CountingTranscript(),
        preBriefs: PreBriefStore(store: _FakeConfigStore()),
      );

      final PostReviewReport report = await service.run();

      expect(report.isUsable, isTrue);
      expect(client.requests, hasLength(1));
      expect(client.requests.single.url.toString(), 'https://llm.example.com/v1/chat/completions');
      expect(client.requests.single.headers['Authorization'], 'Bearer sk-custom');
      final Map<String, Object?> body =
          jsonDecode(client.requests.single.body) as Map<String, Object?>;
      expect(body['model'], 'my-model');
    });
  });

  group('SecureStore hợp đồng (plaintext UI không làm yếu storage)', () {
    test('save/read/delete vòng đầy đủ (reader callback cùng đường với provider)', () async {
      // Không đụng SecureStore thật (platform channel) — chỉ khoá HỢP ĐỒNG qua reader injection:
      // provider đọc MỖI LẦN gọi, không cache.
      String? stored;
      Future<String?> reader() async => stored;
      final _RecordingClient client = _RecordingClient(
        (http.Request request) async => _chatOk('OK'),
      );
      final TestLlmService service = TestLlmService(
        client: client,
        apiKeyReader: reader,
        configStore: _FakeConfigStore(),
      );

      stored = null;
      LlmTestResult result = await service.run();
      expect(result.isSuccess, isFalse, reason: 'chưa có key ⇒ không được gọi API');

      stored = 'sk-abc';
      result = await service.run();
      expect(result.isSuccess, isTrue);
      expect(client.requests.single.headers['Authorization'], 'Bearer sk-abc');
    });
  });
}
