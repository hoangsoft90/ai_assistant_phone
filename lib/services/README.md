# `lib/services/` — foreground service, lưu trữ, abstraction của client ngoài

| File | Nội dung |
|---|---|
| `foreground_service.dart` | Bọc `flutter_foreground_task`: init, start/stop, `ListeningTaskHandler` (chạy ở isolate riêng). P0.5 chỉ giữ service sống + hiện notification. |
| `permission_gate.dart` | Xin/kiểm tra quyền runtime (mic + notification) — điều kiện bắt buộc để service `type=microphone` chạy được trên Android 14+. |
| `storage/app_database.dart` | Khung SQLite: mở DB, tạo bảng `meta`, chỗ để thêm migration ở P1E. |
| `storage/secure_store.dart` | Lưu API key LLM bằng keystore hệ điều hành (`flutter_secure_storage`); dùng từ P2. |

Ghi chú:
- Logic audio **không** được viết ở đây: `ListeningTaskHandler.onRepeatEvent` chỉ là chỗ móc
  (hook) cho vòng lặp audio/VAD của P1A-P1B; phần xử lý thật thuộc `lib/audio/`.
- P0.5 cố ý **không** bật `autoRunOnBoot`: tự chạy lại sau khi khởi động máy là việc của P7
  (kèm hướng dẫn loại app khỏi battery optimization), không phải của khung.
