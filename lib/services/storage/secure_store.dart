import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/constants.dart';

/// Lưu trữ dữ liệu nhạy cảm (API key của LLM — dùng từ P2).
///
/// Dùng keystore của hệ điều hành (Android Keystore) qua `flutter_secure_storage`;
/// KHÔNG bao giờ ghi API key vào SQLite/SharedPreferences/file thường.
abstract final class SecureStore {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static Future<bool> hasLlmApiKey() async =>
      (await _storage.read(key: StorageConfig.llmApiKeyKey))?.isNotEmpty ?? false;

  static Future<void> saveLlmApiKey(String apiKey) =>
      _storage.write(key: StorageConfig.llmApiKeyKey, value: apiKey);

  static Future<String?> readLlmApiKey() => _storage.read(key: StorageConfig.llmApiKeyKey);

  static Future<void> deleteLlmApiKey() => _storage.delete(key: StorageConfig.llmApiKeyKey);
}
