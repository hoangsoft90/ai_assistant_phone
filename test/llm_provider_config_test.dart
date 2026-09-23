import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';
import 'package:ai_assistant_phone/suggestion/groq_llm_provider.dart';
import 'package:ai_assistant_phone/suggestion/llm_provider_config.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_models.dart';

/// ConfigStore giả trong bộ nhớ (cùng mẫu DAO giả của `transcript_store_test`).
class _FakeConfigStore implements ConfigStore {
  final Map<String, String> values = <String, String>{};
  int readCount = 0;

  @override
  Future<String?> read(String key) async {
    readCount++;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

SuggestionContext _context() => SuggestionContext(
      prompt: 'test prompt',
      recentTranscript: 'xin chào',
      pushTimestamp: '',
      topicsExplored: const <String>[],
      lastSuggestions: const <String>[],
    );

http.Client _clientCapturing(
  void Function(http.Request request) onRequest, {
  String content = '{"action":"NUDGE","type":"ASK","text":"Hỏi về công việc"}',
}) =>
    MockClient((http.Request request) async {
      onRequest(request);
      return http.Response(
        jsonEncode(<String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{'content': content},
            },
          ],
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

void main() {
  group('LlmProviderConfigResolver — đọc config (P2.1)', () {
    test('CHƯA cấu hình gì ⇒ trả mặc định Groq Y HỆT trước P2.1 (DoD-1)', () async {
      final _FakeConfigStore store = _FakeConfigStore(); // rỗng — máy chưa từng cấu hình
      final ResolvedLlmConfig config = await LlmProviderConfigResolver.resolve(store);
      expect(config.endpoint.toString(), SuggestionConfig.groqEndpoint);
      expect(config.model, SuggestionConfig.groqModel);
      expect(config.isDefault, isTrue);
    });

    test('giá trị RỖNG (rỗng/khoảng trắng) ⇒ dùng mặc định, không ném', () async {
      final _FakeConfigStore store = _FakeConfigStore()
        ..values[LlmProviderConfig.baseUrlKey] = '   '
        ..values[LlmProviderConfig.modelKey] = '';
      final ResolvedLlmConfig config = await LlmProviderConfigResolver.resolve(store);
      expect(config.endpoint.toString(), SuggestionConfig.groqEndpoint);
      expect(config.model, SuggestionConfig.groqModel);
    });

    test('URL không parse được / scheme lạ ⇒ mặc định + không ném (hợp đồng không-ném)', () async {
      final _FakeConfigStore store = _FakeConfigStore()
        ..values[LlmProviderConfig.baseUrlKey] = 'không-phải-url ::///'
        ..values[LlmProviderConfig.modelKey] = 'model-của-tôi';
      final ResolvedLlmConfig config = await LlmProviderConfigResolver.resolve(store);
      expect(config.endpoint.toString(), SuggestionConfig.groqEndpoint);
      expect(config.model, 'model-của-tôi');
    });

    test('URL đúng scheme (http lẫn https) ⇒ dùng giá trị tuỳ chỉnh', () async {
      final _FakeConfigStore store = _FakeConfigStore()
        ..values[LlmProviderConfig.baseUrlKey] = 'http://localhost:1234/v1/chat/completions';
      expect((await LlmProviderConfigResolver.resolve(store)).endpoint.toString(),
          'http://localhost:1234/v1/chat/completions');

      store.values[LlmProviderConfig.baseUrlKey] = 'https://openrouter.ai/api/v1/chat/completions';
      final ResolvedLlmConfig config = await LlmProviderConfigResolver.resolve(store);
      expect(config.endpoint.host, 'openrouter.ai');
      expect(config.isDefault, isFalse);
    });

    test('reset() xoá cả 2 khoá ⇒ quay về Groq mặc định (DoD-4)', () async {
      final _FakeConfigStore store = _FakeConfigStore()
        ..values[LlmProviderConfig.baseUrlKey] = 'https://openrouter.ai/api/v1/chat/completions'
        ..values[LlmProviderConfig.modelKey] = 'openai/gpt-4o-mini';
      await LlmProviderConfigResolver.reset(store);
      expect(store.values[LlmProviderConfig.baseUrlKey], isEmpty);
      expect(store.values[LlmProviderConfig.modelKey], isEmpty);
      final ResolvedLlmConfig config = await LlmProviderConfigResolver.resolve(store);
      expect(config.isDefault, isTrue);
    });

    test('validateEndpoint: rỗng = OK (mặc định); thiếu scheme / sai cú pháp = lỗi', () {
      expect(LlmProviderConfigResolver.validateEndpoint(null), isNull);
      expect(LlmProviderConfigResolver.validateEndpoint('  '), isNull);
      expect(LlmProviderConfigResolver.validateEndpoint('abc'), isNotNull);
      expect(LlmProviderConfigResolver.validateEndpoint('ftp://x.com/v1'), isNotNull);
      expect(LlmProviderConfigResolver.validateEndpoint('https://a.b/c'), isNull);
    });
  });

  group('GroqLlmProvider với configStore (P2.1) — request thật qua MockClient', () {
    test('CHƯA cấu hình ⇒ request đi đúng Groq endpoint + model cũ (không regression)', () async {
      late http.Request captured;
      final GroqLlmProvider provider = GroqLlmProvider(
        client: _clientCapturing((http.Request request) => captured = request),
        apiKeyReader: () async => 'test-key',
        configStore: _FakeConfigStore(),
      );
      await provider.generateSuggestion(_context());
      expect(captured.url.toString(), SuggestionConfig.groqEndpoint);
      expect((jsonDecode(captured.body) as Map<String, dynamic>)['model'],
          SuggestionConfig.groqModel);
    });

    test('đã cấu hình endpoint/model khác ⇒ request đi đúng giá trị mới (DoD-2)', () async {
      late http.Request captured;
      final _FakeConfigStore store = _FakeConfigStore()
        ..values[LlmProviderConfig.baseUrlKey] = 'https://openrouter.ai/api/v1/chat/completions'
        ..values[LlmProviderConfig.modelKey] = 'meta-llama/llama-3-8b-instruct';
      final GroqLlmProvider provider = GroqLlmProvider(
        client: _clientCapturing((http.Request request) => captured = request),
        apiKeyReader: () async => 'test-key',
        configStore: store,
      );
      await provider.generateSuggestion(_context());
      expect(captured.url.toString(), 'https://openrouter.ai/api/v1/chat/completions');
      expect((jsonDecode(captured.body) as Map<String, dynamic>)['model'],
          'meta-llama/llama-3-8b-instruct');
    });

    test('ĐỌC MỖI LẦN GỌI: đổi config giữa 2 lần gọi ⇒ lần sau dùng giá trị mới (không cache)', () async {
      final List<String> urls = <String>[];
      final _FakeConfigStore store = _FakeConfigStore();
      final GroqLlmProvider provider = GroqLlmProvider(
        client: _clientCapturing((http.Request request) => urls.add(request.url.toString())),
        apiKeyReader: () async => 'test-key',
        configStore: store,
      );

      await provider.generateSuggestion(_context());
      expect(urls.single, SuggestionConfig.groqEndpoint);

      // Người dùng đổi cấu hình giữa phiên (không khởi động lại app).
      store.values[LlmProviderConfig.baseUrlKey] = 'https://together.ai/v1/chat/completions';
      store.values[LlmProviderConfig.modelKey] = 'mixtral-8x7b';
      await provider.generateSuggestion(_context());

      expect(urls, hasLength(2));
      expect(urls.last, 'https://together.ai/v1/chat/completions');
      // Đọc qua resolver mỗi lần: store phải bị đọc ít nhất 2 lần (1 lần gọi = ≥ 2 read: url+model).
      expect(store.readCount, greaterThanOrEqualTo(4));
    });

    test('complete() (đường văn bản P5) cũng đi đúng endpoint đã cấu hình', () async {
      late http.Request captured;
      final _FakeConfigStore store = _FakeConfigStore()
        ..values[LlmProviderConfig.baseUrlKey] = 'https://api.example.com/v1/chat/completions';
      final GroqLlmProvider provider = GroqLlmProvider(
        client: _clientCapturing((http.Request request) => captured = request),
        apiKeyReader: () async => 'test-key',
        configStore: store,
      );
      await provider.complete(prompt: 'tóm tắt', maxTokens: 50);
      expect(captured.url.toString(), 'https://api.example.com/v1/chat/completions');
      // Đường văn bản KHÔNG bật JSON mode (không đổi hành vi hiện có — constraint P2.1).
      expect((jsonDecode(captured.body) as Map<String, dynamic>).containsKey('response_format'),
          isFalse);
    });

    test('API key VẪN qua apiKeyReader/SecureStore — endpoint tuỳ chỉnh không đổi đường key', () async {
      late http.Request captured;
      var keyReads = 0;
      final GroqLlmProvider provider = GroqLlmProvider(
        client: _clientCapturing((http.Request request) => captured = request),
        apiKeyReader: () async {
          keyReads++;
          return 'gsk_key-in-secure-store';
        },
        configStore: _FakeConfigStore()
          ..values[LlmProviderConfig.baseUrlKey] = 'https://openrouter.ai/api/v1/chat/completions',
      );
      await provider.generateSuggestion(_context());
      expect(keyReads, 1); // key đọc mỗi lần gọi như cũ
      expect(captured.headers['Authorization'], 'Bearer gsk_key-in-secure-store');
    });
  });
}
