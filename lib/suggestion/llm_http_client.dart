import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/constants.dart';

/// Client HTTP **mặc định** cho mọi cuộc gọi LLM (P5.4 — phần B của prompt).
///
/// Vì sao cần lớp này: `.timeout(...)` của `Future` chỉ ngừng **chờ** future — nó không đảm bảo huỷ
/// được kết nối TCP bên dưới. `http.Client()` mặc định (không đặt `connectionTimeout`) gặp mạng xấu
/// (DNS treo, handshake không phản hồi) có thể khiến request "treo" lâu hơn hẳn con số timeout đã
/// khai báo trước khi future thực sự hoàn thành.
///
/// `connectionTimeout` ở đây là thời gian **thiết lập kết nối**, KHÔNG phải thời gian chờ phản hồi:
/// - nối không xong sau [SuggestionConfig.socketConnectTimeout] ⇒ bỏ ngay (chờ thêm vô ích);
/// - thời gian chờ LLM trả lời (sau khi đã nối) vẫn do [SuggestionConfig.llmTimeout] /
///   [SuggestionConfig.postReviewTimeout] quyết định qua `.timeout(...)`.
///
/// Hai lớp cùng tồn tại có chủ ý — lớp này **không thay thế** lớp `.timeout()`.
///
/// [inner] chỉ để **test** xác minh được rằng `connectionTimeout` thực sự được đặt lên `HttpClient`
/// (`IOClient` không lộ `HttpClient` bên trong ra ngoài, nên không có cách nào kiểm từ bên ngoài).
http.Client defaultLlmHttpClient({HttpClient? inner}) {
  final HttpClient httpClient = inner ?? HttpClient();
  httpClient.connectionTimeout = SuggestionConfig.socketConnectTimeout;
  return IOClient(httpClient);
}
