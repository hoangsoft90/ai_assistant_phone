// Test follow-up P2.1 — SessionSummaryService dùng CÙNG cấu hình LLM tuỳ chỉnh.
//
// Issue (remaining issues của issue1_fix): `SessionSummaryService` tự dựng
// `GroqLlmProvider()` KHÔNG `configStore` ⇒ tóm tắt phiên luôn đi endpoint/model mặc định Groq,
// bỏ qua custom LLM người dùng đã cấu hình. Sau fix: service nhận `llmConfigStore?` (cùng pattern
// PostReviewService/SuggestionService/TestLlmService) và truyền vào provider khi caller không
// inject provider.
//
// Vì service tự dựng provider bên trong (không inject client được), mock HTTP đúng nghĩa là
// **server HTTP cục bộ** (127.0.0.1, cổng ngẫu nhiên) — endpoint tuỳ chỉnh trỏ vào đó. Key bơm
// bằng stub kênh `flutter_secure_storage` (cùng cách `issue1_llm_test.dart`, không chạm native).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/coaching/session_summary.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';
import 'package:ai_assistant_phone/suggestion/llm_provider_config.dart';
import 'package:ai_assistant_phone/transcript/transcript_store.dart';

class _FakeConfigStore implements ConfigStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _FakeTranscript implements TranscriptStore {
  bool empty = false;

  @override
  Future<SessionTranscript> sessionTranscript({int maxChars = 6000}) async =>
      empty
          ? const SessionTranscript(text: '', segmentCount: 0, truncated: false)
          : const SessionTranscript(
              text: 'dạ em chào anh\nem mới chuyển nhà tuần trước',
              segmentCount: 2,
              truncated: false,
            );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeTranscript không hỗ trợ ${invocation.memberName}');
}

/// Cho phép HTTP thật — `TestWidgetsFlutterBinding` cài override chặn mọi request (trả 400);
/// override này trả client thật để request tới server cục bộ của test đi được.
class _LoopbackHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final HttpClient client = super.createHttpClient(context);
    // Ép đi thẳng: nếu môi trường set HTTP_PROXY, request tới loopback không được bám qua proxy.
    client.findProxy = (_) => 'DIRECT';
    return client;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _LoopbackHttpOverrides();

  late HttpServer server;
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  late Uri endpoint;

  setUp(() async {
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = Uri.parse('http://127.0.0.1:${server.port}/v1/chat/completions');
    server.listen((HttpRequest request) async {
      final String raw = await utf8.decoder.bind(request).join();
      final Map<String, Object?> body = jsonDecode(raw) as Map<String, Object?>;
      requests.add(<String, Object?>{
        'path': request.uri.toString(),
        'model': body['model'],
        'auth': request.headers.value(HttpHeaders.authorizationHeader),
      });
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': 'tóm tắt qua endpoint riêng'},
          },
        ],
      }));
      await request.response.close();
    });

    const MethodChannel secureChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (MethodCall call) async {
      if (call.method == 'read') {
        return 'sk-test-123';
      }
      return null;
    });
  });

  tearDown(() async {
    await server.close(force: true);
    const MethodChannel secureChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  test('config custom ⇒ request tóm tắt đi ĐÚNG endpoint + model (không fallback silent về Groq)',
      () async {
    final _FakeConfigStore store = _FakeConfigStore();
    await LlmProviderConfigResolver.writeEndpoint(store, endpoint.toString());
    await LlmProviderConfigResolver.writeModel(store, 'model-rieng');

    final SessionSummaryService service = SessionSummaryService(
      llmConfigStore: store,
      transcript: _FakeTranscript(),
      now: () => DateTime(2026, 9, 23, 9, 0, 0),
      everyNudges: 4,
    );

    await service.maybeRefresh(nudgeCount: 4);

    expect(requests, hasLength(1));
    expect(requests.single['path'], '/v1/chat/completions');
    expect(requests.single['model'], 'model-rieng');
    expect(requests.single['auth'], 'Bearer sk-test-123');
    expect(service.summary, 'tóm tắt qua endpoint riêng');
    expect(service.lastNote, isNull);
  });

  test('không truyền store ⇒ không đổi hành vi cũ (default Groq — smoke không gọi mạng thật)',
      () async {
    // Transcript rỗng ⇒ service KHÔNG gọi LLM ⇒ không request nào rời máy. Test này khoá
    // đường `llmConfigStore == null` còn tồn tại và không crash — endpoint Groq thật được
    // kiểm trên máy (K51), không cho test chạm mạng thật.
    final SessionSummaryService service = SessionSummaryService(
      transcript: _FakeTranscript()..empty = true,
      now: () => DateTime(2026, 9, 23, 9, 0, 0),
      everyNudges: 4,
    );

    await service.maybeRefresh(nudgeCount: 4);

    expect(requests, isEmpty, reason: 'test không được gọi ra mạng thật');
    expect(service.summary, isEmpty);
    expect(service.lastNote, contains('chưa có transcript'));
  });

  test('prompt tóm tắt giữ nguyên (ràng buộc: không đổi prompt)', () {
    final String prompt = SessionSummaryService.buildSummaryPrompt('transcript ở đây');
    expect(prompt, contains('tối đa 40 từ'));
    expect(prompt, contains('Chỉ trả về phần tóm tắt'));
    expect(prompt, contains('transcript ở đây'));
  });
}
