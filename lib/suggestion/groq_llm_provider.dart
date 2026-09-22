import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../services/storage/secure_store.dart';
import 'llm_provider.dart';
import 'suggestion_models.dart';

/// Provider Groq (P2 mặc định) — endpoint OpenAI-compatible
/// `POST https://api.groq.com/openai/v1/chat/completions` (xác minh từ tài liệu chính thức
/// 2026-09). Model đọc từ `SuggestionConfig.groqModel` (llama-3.1-8b-instant).
///
/// - API key đọc từ `SecureStore` (keystore OS) **mỗi lần gọi** — không cache trong RAM quá hạn,
///   tuyệt đối không hard-code (constraint P2).
/// - `response_format: json_object` (JSON mode của Groq) — giảm xác suất LLM trả text thường.
/// - Mọi lỗi vận hành (timeout/mạng/HTTP/JSON) ⇒ [SuggestionException] — tầng service retry 1 lần
///   rồi quy về `NO_SUGGESTION`.
/// - Thân phản hồi được đọc bằng kiểm tra kiểu (`is`), **không cast cứng** — envelope dị dạng phải
///   ra [SuggestionException], không được ném `TypeError` (xem bài học A50).
class GroqLlmProvider implements LlmProvider {
  GroqLlmProvider({
    http.Client? client,
    Future<String?> Function()? apiKeyReader,
    Uri? endpoint,
    this.model = SuggestionConfig.groqModel,
    this.timeout = SuggestionConfig.llmTimeout,
  })  : _client = client ?? http.Client(),
        _apiKeyReader = apiKeyReader ?? SecureStore.readLlmApiKey,
        _endpoint = endpoint ?? Uri.parse(SuggestionConfig.groqEndpoint);

  final http.Client _client;
  final Future<String?> Function() _apiKeyReader;
  final Uri _endpoint;
  final String model;
  final Duration timeout;

  @override
  Future<SuggestionResult> generateSuggestion(SuggestionContext context) async {
    final String? apiKey = await _apiKeyReader();
    if (apiKey == null || apiKey.isEmpty) {
      throw const SuggestionException('chưa có API key Groq (lưu qua SecureStore)');
    }

    final Map<String, Object?> body = <String, Object?>{
      'model': model,
      'messages': <Map<String, String>>[
        // Prompt khung chính thức gửi nguyên văn trong MỘT message user — không tách system/user
        // vì tách là sửa cấu trúc prompt (constraint P2).
        <String, String>{'role': 'user', 'content': context.prompt},
      ],
      // Nudge 2-4 từ / NO_SUGGESTION: temperature thấp cho ổn định, token trần nhỏ cho rẻ/nhanh.
      'temperature': 0.2,
      'max_completion_tokens': 100,
      'response_format': <String, String>{'type': 'json_object'},
    };

    final http.Response response;
    try {
      response = await _client
          .post(
            _endpoint,
            headers: <String, String>{
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw SuggestionException(
          'hết thời gian chờ LLM (${timeout.inMilliseconds}ms)');
    } catch (error) {
      // SocketException/ClientException... — mất mạng hoặc DNS hỏng: fail gracefully.
      throw SuggestionException('lỗi mạng khi gọi LLM', error);
    }

    if (response.statusCode != 200) {
      throw SuggestionException('LLM trả về HTTP ${response.statusCode}');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (error) {
      throw SuggestionException('thân phản hồi LLM không phải JSON', error);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const SuggestionException('thân phản hồi LLM không phải JSON object');
    }
    // Đọc envelope bằng `is` (KHÔNG cast cứng `as`): một thân phản hồi dị dạng
    // (`"choices": "x"`, phần tử không phải object, `"content": 123`...) sẽ ném TypeError — loại
    // lỗi mà `on SuggestionException` ở tầng service KHÔNG bắt được ⇒ `push()` ném ra UI.
    final Object? rawChoices = decoded['choices'];
    final Object? firstChoice = rawChoices is List && rawChoices.isNotEmpty
        ? rawChoices.first
        : null;
    final Object? rawMessage =
        firstChoice is Map<String, dynamic> ? firstChoice['message'] : null;
    final Object? content =
        rawMessage is Map<String, dynamic> ? rawMessage['content'] : null;
    if (content is! String || content.trim().isEmpty) {
      throw const SuggestionException('phản hồi LLM thiếu nội dung');
    }

    return parseSuggestionOutput(content);
  }
}
