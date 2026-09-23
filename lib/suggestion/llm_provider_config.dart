import '../core/app_logger.dart';
import '../core/constants.dart';
import '../services/storage/meta_store.dart';

/// Kết quả đọc cấu hình LLM provider (P2.1): endpoint + model sẽ dùng cho lần gọi kế tiếp.
///
/// Hai giá trị này KHÔNG nhạy cảm (khác API key — key vẫn nằm trong `SecureStore`, ràng buộc #8),
/// nên được lưu trong bảng `meta` như mọi lựa chọn cấu hình khác (giống `AsrEngineSelector` P1D).
class ResolvedLlmConfig {
  const ResolvedLlmConfig({required this.endpoint, required this.model});

  /// Endpoint chat completions đầy đủ (đã parse được, scheme http/https).
  final Uri endpoint;

  /// Tên model (đã trim, khác rỗng).
  final String model;

  /// `true` khi cả hai giá trị trùng mặc định Groq (dùng để hiển thị trạng thái trên UI).
  bool get isDefault =>
      endpoint.toString() == SuggestionConfig.groqEndpoint &&
      model == SuggestionConfig.groqModel;

  @override
  String toString() => 'ResolvedLlmConfig(${endpoint.host}, model=$model)';
}

/// Đọc cấu hình LLM tuỳ chỉnh (P2.1) từ `ConfigStore`/bảng `meta`.
///
/// **Hợp đồng không-ném** (giống `AsrEngineSelector.readConfigured` P1D): thiếu khoá, giá trị rỗng,
/// URL không parse được hoặc scheme lạ ⇒ quay về **mặc định Groq y hệt trước khi có phase này**
/// (`SuggestionConfig.groqEndpoint`/`groqModel`) + log cảnh báo khi có giá trị hỏng — KHÔNG throw,
/// KHÔNG để một cấu hình hỏng làm cả engine gợi ý chết.
///
/// Vì sao KHÔNG cache static (constraint P2.1): đọc lại mỗi lần resolve — giống cách
/// `SecureStore.readLlmApiKey` đọc key mỗi lần gọi — để cấu hình mới có hiệu lực ngay cho service
/// được tạo sau đó, không cần khởi động lại app.
abstract final class LlmProviderConfigResolver {
  static const AppLogger _log = AppLogger('LlmConfig');

  /// Endpoint hiện hành: giá trị tuỳ chỉnh nếu hợp lệ, ngược lại mặc định Groq.
  static Future<Uri> readEndpoint(ConfigStore store) async {
    final String? raw = await store.read(LlmProviderConfig.baseUrlKey);
    final Uri? parsed = _tryParseEndpoint(raw);
    if (parsed == null) {
      if (raw != null && raw.trim().isNotEmpty) {
        _log.warn('llm endpoint "$raw" không hợp lệ → dùng mặc định Groq');
      }
      return Uri.parse(SuggestionConfig.groqEndpoint);
    }
    return parsed;
  }

  /// Model hiện hành: giá trị tuỳ chỉnh nếu hợp lệ, ngược lại mặc định Groq.
  static Future<String> readModel(ConfigStore store) async {
    final String? raw = await store.read(LlmProviderConfig.modelKey);
    final String? value = raw?.trim();
    if (value == null || value.isEmpty) {
      return SuggestionConfig.groqModel;
    }
    return value;
  }

  /// Đọc cả hai cùng lúc (cho nơi cần tạo provider với đủ 2 giá trị).
  static Future<ResolvedLlmConfig> resolve(ConfigStore store) async {
    return ResolvedLlmConfig(
      endpoint: await readEndpoint(store),
      model: await readModel(store),
    );
  }

  /// Ghi endpoint tuỳ chỉnh. Gọi sau khi UI đã validate (validator dùng chung bên dưới).
  static Future<void> writeEndpoint(ConfigStore store, String url) =>
      store.write(LlmProviderConfig.baseUrlKey, url.trim());

  /// Ghi model tuỳ chỉnh (đã trim).
  static Future<void> writeModel(ConfigStore store, String model) =>
      store.write(LlmProviderConfig.modelKey, model.trim());

  /// Xoá cả 2 khoá ⇒ quay về mặc định Groq ("Khôi phục mặc định").
  static Future<void> reset(ConfigStore store) async {
    await store.write(LlmProviderConfig.baseUrlKey, '');
    await store.write(LlmProviderConfig.modelKey, '');
    _log.info('đã khôi phục cấu hình LLM về mặc định Groq');
  }

  /// Validate dùng chung cho UI và resolver: URL phải parse được (`Uri.tryParse`) VÀ có scheme
  /// http/https. `null`/rỗng = "chưa cấu hình" (không phải lỗi).
  static Uri? _tryParseEndpoint(String? raw) {
    if (raw == null) {
      return null;
    }
    final String value = raw.trim();
    if (value.isEmpty) {
      return null;
    }
    final Uri? uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri;
  }

  /// Kiểm hợp lệ cho UI (trước khi lưu): trả `null` nếu hợp lệ, ngược lại trả thông báo lỗi.
  static String? validateEndpoint(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null; // để trống = dùng mặc định, không phải lỗi.
    }
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return 'URL không hợp lệ — phải bắt đầu bằng http:// hoặc https://';
    }
    return null;
  }

  // Model KHÔNG cần validator riêng: `writeModel` trim trước khi ghi ⇒ khoảng trắng thuần thành
  // rỗng = dùng mặc định (hợp lệ); model bất kỳ ký tự nào khác rỗng đều là tên model hợp lệ.
}
