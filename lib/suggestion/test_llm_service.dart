import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/app_logger.dart';
import '../core/constants.dart';
import '../services/storage/meta_store.dart';
import '../services/storage/secure_store.dart';
import 'llm_http_client.dart';
import 'llm_provider_config.dart';

/// Phân loại kết quả Test LLM (issue1_fix mục 4).
enum LlmTestKind {
  /// Request thành công — LLM hoạt động với config hiện tại.
  success,

  /// 401/403 — key không hợp lệ / không có quyền cho endpoint này.
  auth,

  /// 404 — endpoint hoặc model không tồn tại.
  notFound,

  /// Endpoint không parse được scheme http/https, hoặc host không phản hồi (DNS/socket).
  invalidEndpoint,

  /// Hết thời gian chờ (mặc định 30s).
  timeout,

  /// Lỗi mạng khác (socket/DNS/SSL...) không thuộc [invalidEndpoint].
  network,

  /// HTTP khác (5xx...) hoặc thân phản hồi dị dạng.
  server,
}

/// Kết quả một lần **Test LLM** (issue1_fix mục 4).
///
/// Tách kiểu kết quả khỏi ném exception: Test LLM là tính năng **chẩn đoán** — mọi đường (kể cả
/// lỗi) đều là kết quả hợp lệ cần hiện cho người dùng. Phân loại rõ tại đây để UI chỉ việc map
/// enum → thông điệp, và test khoá được từng nhánh.
class LlmTestResult {
  const LlmTestResult.success({required this.model, required this.latency})
      : kind = LlmTestKind.success,
        message = null;

  const LlmTestResult.failure(this.kind, this.message)
      : model = null,
        latency = null;

  final LlmTestKind kind;

  /// Thông điệp hiển thị được ngay cho người dùng (chỉ `null` khi success).
  final String? message;

  /// Model đã test (khi success).
  final String? model;

  /// Độ trễ request→response (khi success).
  final Duration? latency;

  bool get isSuccess => kind == LlmTestKind.success;
}

/// **Test LLM** (issue1_fix mục 4) — gửi 1 request tối thiểu tới endpoint/model/key hiện tại để
/// chứng minh cấu hình dùng được, KHÔNG đụng phiên hội thoại.
///
/// Ràng buộc của prompt (mục 4) — mọi thứ dưới đây đều được thiết kế để đáp ứng:
/// - Dùng **đúng** config hiện tại: resolve qua cùng `LlmProviderConfigResolver` + `SecureStore`
///   với Post-Review/Suggestion (mục 5 — một abstraction duy nhất). KHÔNG cache.
/// - Request thật (prompt 1 dòng, `max_tokens` nhỏ, timeout 30s) — không chỉ check field rỗng.
/// - Phân loại: auth (401/403) / not-found (404) / endpoint sai / timeout / network — không crash,
///   không stack trace trên UI (UI chỉ nhận [LlmTestResult]).
/// - **Không** tạo session / transcript / report / đổi phiên hiện tại: lớp này chỉ chạm
///   `http.Client` + 2 kho lưu trữ cấu hình (đọc). Không import gì tầng session/transcript.
///
/// Vì sao dùng key qua callback thay vì gọi `SecureStore` cứng: test mock HTTP mà không cần keystore
/// thật (platform channel không có ở unit test) — cùng cách `GroqLlmProvider` đã làm với
/// `apiKeyReader`.
class TestLlmService {
  TestLlmService({
    http.Client? client,
    Future<String?> Function()? apiKeyReader,
    ConfigStore? configStore,
    // P5.4: 30s (trước là 12s). Vẫn đủ nhanh cho chẩn đoán tức thì, nhưng không còn quá ngắn trên
    // mạng chậm / endpoint tự host có độ trễ cao — Test LLM báo "timeout" sai nguyên nhân khi đó.
    this.timeout = const Duration(seconds: 30),
  })  : _client = client ?? defaultLlmHttpClient(),
        _apiKeyReader = apiKeyReader ?? SecureStore.readLlmApiKey,
        _configStore = configStore ?? const MetaConfigStore();

  static const AppLogger _log = AppLogger('TestLlm');

  final http.Client _client;
  final Future<String?> Function() _apiKeyReader;
  final ConfigStore _configStore;
  final Duration timeout;

  /// Chạy 1 lần test. Không bao giờ ném — mọi lỗi quy về [LlmTestResult.failure].
  ///
  /// [endpointOverride]/[modelOverride]: giá trị đang hiện trên UI (issue1_fix mục 4 — "ưu tiên giá
  /// trị đang hiện"). `null`/rỗng = dùng giá trị persisted qua resolver (giữ hành vi "để trống =
  /// mặc định Groq"). Key luôn đọc từ SecureStore (UI không nhập key tại dialog Test).
  Future<LlmTestResult> run({String? endpointOverride, String? modelOverride}) async {
    // 1. Resolve config — cùng đường với Post-Review/Suggestion (mục 5).
    Uri endpoint;
    String model;
    try {
      endpoint = await LlmProviderConfigResolver.readEndpoint(_configStore);
      model = await LlmProviderConfigResolver.readModel(_configStore);
    } catch (error) {
      // Resolver có hợp đồng không-ném; lưới an toàn cho MetaConfigStore lỗi DB thoáng qua.
      _log.warn('không đọc được cấu hình LLM: $error');
      return const LlmTestResult.failure(
        LlmTestKind.invalidEndpoint,
        'Không đọc được cấu hình LLM đã lưu — thử lưu lại cấu hình.',
      );
    }
    if (endpointOverride != null && endpointOverride.trim().isNotEmpty) {
      final Uri? parsed = _tryParse(endpointOverride.trim());
      if (parsed == null) {
        return const LlmTestResult.failure(
          LlmTestKind.invalidEndpoint,
          'Endpoint không hợp lệ — phải bắt đầu bằng http:// hoặc https://',
        );
      }
      endpoint = parsed;
    }
    if (modelOverride != null && modelOverride.trim().isNotEmpty) {
      model = modelOverride.trim();
    }

    // 2. Key — đọc từ SecureStore MỖI LẦN (không cache, đối xứng provider).
    final String? apiKey = await _apiKeyReader();
    if (apiKey == null || apiKey.isEmpty) {
      final bool isDefaultGroq = endpoint.toString() == SuggestionConfig.groqEndpoint;
      return LlmTestResult.failure(
        LlmTestKind.auth,
        isDefaultGroq
            ? 'Chưa có API key Groq — nhập key ở tab Cài đặt trước.'
            : 'Chưa cấu hình API key cho LLM hiện tại — nhập key ở tab Cài đặt trước.',
      );
    }

    // 3. Request thật, tối thiểu (prompt 1 dòng, token trần nhỏ).
    final Map<String, Object?> body = <String, Object?>{
      'model': model,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'user', 'content': 'Reply with exactly: OK'},
      ],
      'max_completion_tokens': 8,
      'temperature': 0,
    };
    final DateTime startedAt = DateTime.now();
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
      _log.warn('test LLM hết thời gian chờ (${timeout.inMilliseconds}ms)');
      return LlmTestResult.failure(
        LlmTestKind.timeout,
        'Hết thời gian chờ sau ${timeout.inSeconds}s — endpoint quá chậm hoặc không phản hồi.',
      );
    } catch (error) {
      // SocketException/ClientException/DNS... — không crash, phân loại network.
      _log.warn('test LLM lỗi mạng: $error');
      return const LlmTestResult.failure(
        LlmTestKind.network,
        'Lỗi mạng — không kết nối được endpoint (kiểm tra 4G/Wi-Fi và tên miền).',
      );
    }

    final Duration latency = DateTime.now().difference(startedAt);
    switch (response.statusCode) {
      case 200:
      case 201:
        break; // success — xử lý dưới.
      case 401:
      case 403:
        _log.warn('test LLM: HTTP ${response.statusCode} — auth');
        return LlmTestResult.failure(
          LlmTestKind.auth,
          'Key không hợp lệ hoặc không có quyền với endpoint/model này (HTTP '
          '${response.statusCode}).',
        );
      case 404:
        _log.warn('test LLM: HTTP 404');
        return LlmTestResult.failure(
          LlmTestKind.notFound,
          'Không tìm thấy endpoint hoặc model "$model" (HTTP 404).',
        );
      default:
        _log.warn('test LLM: HTTP ${response.statusCode}');
        return LlmTestResult.failure(
          LlmTestKind.server,
          'Endpoint trả về HTTP ${response.statusCode} — thử lại sau.',
        );
    }

    // 4. Thân phản hồi — đọc bằng `is` (bài học A50: không cast cứng).
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      return const LlmTestResult.failure(
        LlmTestKind.server,
        'Endpoint phản hồi không phải JSON — có thể đây không phải API chat completions.',
      );
    }
    final Object? rawChoices =
        decoded is Map<String, dynamic> ? decoded['choices'] : null;
    final Object? firstChoice = rawChoices is List && rawChoices.isNotEmpty ? rawChoices.first : null;
    final Object? rawMessage =
        firstChoice is Map<String, dynamic> ? firstChoice['message'] : null;
    final Object? text = rawMessage is Map<String, dynamic> ? rawMessage['content'] : null;
    if (text is! String || text.trim().isEmpty) {
      return const LlmTestResult.failure(
        LlmTestKind.server,
        'Endpoint phản hồi nhưng thiếu nội dung — kiểm tra model có hỗ trợ chat completions không.',
      );
    }

    _log.info('test LLM OK: ${endpoint.host} · $model · ${latency.inMilliseconds}ms');
    return LlmTestResult.success(model: model, latency: latency);
  }

  /// Cùng quy tắc validate với `LlmProviderConfigResolver.validateEndpoint` — dùng cho override UI.
  static Uri? _tryParse(String raw) {
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri;
  }
}
