# `lib/services/` — foreground service, orchestrator phiên, lưu trữ

| File | Nội dung |
|---|---|
| `conversation_session_controller.dart` | **Orchestrator của phiên (P4)** — nơi DUY NHẤT ráp capture → VAD → ASR → (trigger → LLM → TTS) và giữ ràng buộc **half-duplex** (chặn chunk ASR khi TTS đang phát), chốt chống 2 lần phát chồng nhau, phục hồi khi một module con lỗi, và đo số liệu cho DoD (độ trễ Push, số chunk bị chặn). Chi tiết: `.project/modules/pipeline-integration.md`. |
| `foreground_service.dart` | Bọc `flutter_foreground_task`: init, start/stop, `ListeningTaskHandler` (chạy ở isolate riêng). P0.5 chỉ giữ service sống + hiện notification. |
| `permission_gate.dart` | Xin/kiểm tra quyền runtime (mic + notification) — điều kiện bắt buộc để service `type=microphone` chạy được trên Android 14+. |
| `storage/app_database.dart` | Khung SQLite: mở DB, tạo bảng `meta`, và schema transcript (v2, P1E) — nhánh migration `v1 → v2` nằm ở đây. |
| `storage/meta_store.dart` | `ConfigStore` (interface) + bản SQLite — cấu hình khoá–giá trị (P1D: engine ASR). |
| `storage/transcript_dao.dart` | `TranscriptDao` (interface) + bản SQLite (P1E): phiên, dòng transcript, mốc Push, xoá theo hạn 7 ngày. |
| `storage/secure_store.dart` | Lưu API key LLM bằng keystore hệ điều hành (`flutter_secure_storage`); dùng từ P2. |

Ghi chú:
- Logic audio **không** được viết ở đây: `ListeningTaskHandler.onRepeatEvent` chỉ là chỗ móc
  (hook) cho vòng lặp audio/VAD của P1A-P1B; phần xử lý thật thuộc `lib/audio/`.
- `conversation_session_controller.dart` cũng **không** xử lý audio: nó chỉ gọi các facade có sẵn
  (`AudioCaptureEngine`, `ConversationStateMachine`, `AsrEngineSelector`, `TranscriptStore`,
  `TriggerManager`, `SafeTtsOutput`). Quyết định **nội dung** gợi ý vẫn ở `lib/suggestion/` (Policy),
  quyết định **chế độ** hiển thị vẫn ở `lib/audio/output_mode_selector.dart` — đừng thêm nhánh nghiệp
  vụ vào orchestrator.
- P0.5 cố ý **không** bật `autoRunOnBoot`: tự chạy lại sau khi khởi động máy là việc của P7
  (kèm hướng dẫn loại app khỏi battery optimization), không phải của khung.
