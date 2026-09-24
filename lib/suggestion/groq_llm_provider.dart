import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../services/storage/secure_store.dart';
import 'llm_http_client.dart';
import 'llm_provider.dart';
import 'llm_provider_config.dart';
import 'suggestion_models.dart';
import '../services/storage/meta_store.dart';

/// Provider Groq (P2 mặc định) — endpoint OpenAI-compatible
/// `POST https://api.groq.com/openai/v1/chat/completions` (xác minh từ tài liệu chính thức
/// 2026-09). Model đọc từ `SuggestionConfig.groqModel` (llama-3.1-8b-instant).
///
/// - API key đọc từ `SecureStore` (keystore OS) **mỗi lần gọi** — không cache trong RAM quá hạn,
///   tuyệt đối không hard-code (constraint P2).
/// - `response_format: json_object` (JSON mode của Groq) — giảm xác suất LLM trả text thường.
/// - Mọi lỗi vận hành (timeout/mạng/HTTP/JSON) ⇒ [SuggestionException] — tầng service retry 1 lần
///   rồi quy về `NO_SUGGESTION`./// - Thân phản hồi được đọc bằng kiểm tra kiểu (`is`), **không cast cứng** — envelope dị dạng phải
///   ra [SuggestionException], không được ném `TypeError` (xem bài học A50).
/// - **P2.1:** khi [configStore] được truyền, endpoint + model được đọc lại từ bảng `meta` **mỗi lần
///   gọi** (đối xứng với cách key đọc từ SecureStore mỗi lần gọi) — cấu hình mới có hiệu lực ngay
///   cho lần gọi kế tiếp, không cần khởi động lại app. Không truyền (mặc định của mọi nơi chưa nâng
///   cấp, và của toàn bộ test cũ) ⇒ dùng giá trị Groq mặc định Y HỆT trước khi có P2.1. Endpoint/
///   model KHÔNG nhạy cảm nên nằm ở `meta`, KHÔNG SecureStore (ràng buộc #8 — key vẫn ở đó).
/// - **P5.4:** timeout mặc định vẫn là [SuggestionConfig.llmTimeout] (4s — Push gợi ý realtime).
///   Caller nào KHÔNG chặn cuộc trò chuyện (Post-Review, Session Summary) phải truyền
///   `timeout: SuggestionConfig.postReviewTimeout` — xem `post_review_service.dart`.
/// - **P5.4:** client mặc định được bọc `connectionTimeout` tường minh ở tầng socket
///   (`defaultLlmHttpClient()`), để mạng xấu không treo lâu hơn con số timeout đã khai báo.
class GroqLlmProvider implements LlmProvider, TextLlmProvider {
  GroqLlmProvider({
    http.Client? client,
    Future<String?> Function()? apiKeyReader,
    Uri? endpoint,
    this.model = SuggestionConfig.groqModel,
    this.timeout = SuggestionConfig.llmTimeout,
    this.configStore,
  })  : _client = client ?? defaultLlmHttpClient(),
        _apiKeyReader = apiKeyReader ?? SecureStore.readLlmApiKey,
        _endpoint = endpoint ?? Uri.parse(SuggestionConfig.groqEndpoint);

  final http.Client _client;
  final Future<String?> Function() _apiKeyReader;
  final Uri _endpoint;
  final String model;
  final Duration timeout;

  /// P2.1: nguồn cấu hình endpoint/model tuỳ chỉnh; `null` = luôn dùng giá trị constructor (Groq mặc
  /// định). Khi có, đọc mỗi lần gọi qua [LlmProviderConfigResolver] — fallback an toàn về Groq nếu
  /// chưa cấu hình/giá trị hỏng (không ném).
  final ConfigStore? configStore;

  @override
  Future<SuggestionResult> generateSuggestion(SuggestionContext context) async {
    // Prompt khung chính thức gửi nguyên văn trong MỘT message user — không tách system/user vì tách
    // là sửa cấu trúc prompt (constraint P2). Nudge 2-4 từ / NO_SUGGESTION: temperature thấp cho ổn
    // định, token trần nhỏ cho rẻ/nhanh, JSON mode để giảm xác suất trả text thường.
    final String content = await _chatContent(
      prompt: context.prompt,
      maxTokens: 100,
      temperature: 0.2,
      jsonMode: true,
    );
    return parseSuggestionOutput(content);
  }

  /// **P5**: văn bản tự do (tóm tắt phiên / Post-Review) — cùng endpoint, key và timeout; khác
  /// `generateSuggestion` ở chỗ không bật JSON mode (bật JSON mode mà prompt không yêu cầu JSON là
  /// cách chắc chắn nhất để model trả về một object rỗng) và temperature cao hơn một chút để câu văn
  /// không lặp khuôn.
  @override
  Future<String> complete({required String prompt, int maxTokens = 400}) =>
      _chatContent(prompt: prompt, maxTokens: maxTokens, temperature: 0.3, jsonMode: false);

  /// Gọi chat completions và trả **nội dung của message đầu tiên**.
  ///
  /// Gộp một chỗ để hai tính năng (nudge P2, văn bản P5) không thể lệch nhau về cách đọc envelope hay
  /// cách xử lý lỗi — chính kiểu lệch đó đã sinh lỗi ở P3/P4. Mọi nhánh lỗi vẫn là
  /// [SuggestionException] để tầng trên chỉ phải bắt một loại.
  Future<String> _chatContent({
    required String prompt,
    required int maxTokens,
    required double temperature,
    required bool jsonMode,
  }) async {
    final String? apiKey = await _apiKeyReader();
    if (apiKey == null || apiKey.isEmpty) {
      // issue1_fix mục 2: message GENERIC — key là credential của cấu hình LLM hiện tại, không phải
      // "Groq key". Khi đang dùng custom endpoint mà báo "Groq" là gây hiểu nhầm (bug thật đã gặp:
      // Post-Review báo thiếu key Groq dù user cấu hình endpoint riêng xong). Chỉ giữ chữ "Groq" khi
      // endpoint đang là mặc định Groq.
      final Uri currentEndpoint = await _currentEndpoint();
      final bool usingDefaultGroq =
          currentEndpoint.toString() == SuggestionConfig.groqEndpoint;
      throw SuggestionException(
        usingDefaultGroq
            ? 'chưa có API key Groq (lưu qua SecureStore)'
            : 'Chưa cấu hình API key cho LLM hiện tại (lưu qua SecureStore)',
      );
    }

    // P2.1: endpoint/model hiện hành — đọc cấu hình mỗi lần gọi khi có `configStore` (không cache);
    // không có thì dùng đúng giá trị constructor như trước. Cấu hình hỏng ⇒ resolver trả mặc định
    // Groq, không ném. Body/parse/error-handling bên dưới KHÔNG đổi (constraint P2.1).
    final Uri endpoint = await _currentEndpoint();
    final String model;
    if (configStore == null) {
      model = this.model;
    } else {
      model = await LlmProviderConfigResolver.readModel(configStore!);
    }

    final Map<String, Object?> body = <String, Object?>{
      'model': model,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'user', 'content': prompt},
      ],
      'temperature': temperature,
      'max_completion_tokens': maxTokens,
      if (jsonMode) 'response_format': <String, String>{'type': 'json_object'},
    };

    final http.Response response;
    try {
      response = await _client
          .post(
            endpoint,
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
      // issue1_fix mục 2: kèm endpoint host + status để user tự phân loại (auth sai / model sai /
      // endpoint sai) mà không lộ key (chỉ host, không path query). Không crash — vẫn là
      // [SuggestionException] như hợp đồng.
      throw SuggestionException(
        'LLM trả về HTTP ${response.statusCode} (${endpoint.host})'
        '${response.statusCode == 401 || response.statusCode == 403 ? ' — key không hợp lệ cho endpoint này' : ''}'
        '${response.statusCode == 404 ? ' — endpoint hoặc model không tồn tại' : ''}',
      );
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
    final Object? text =
        rawMessage is Map<String, dynamic> ? rawMessage['content'] : null;
    if (text is! String || text.trim().isEmpty) {
      throw const SuggestionException('phản hồi LLM thiếu nội dung');
    }
    return text;
  }

  /// Endpoint hiện hành — constructor nếu không có `configStore`, đọc từ config nếu có.
  Future<Uri> _currentEndpoint() async {
    final ConfigStore? store = configStore;
    if (store == null) {
      return _endpoint;
    }
    return LlmProviderConfigResolver.readEndpoint(store);
  }
}
