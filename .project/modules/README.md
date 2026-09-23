# modules/ — Danh sách module

Cập nhật: 2026-09-23 (+07).

> ⚠ **Đọc trước:** repo này **chưa có module sản phẩm nào**. Không có Auth, Profile, Cart, Payment,
> Product, Order — đây là **app công cụ cá nhân một người dùng**, không phải app thương mại.
> Danh sách ở mục 2 là **module hạ tầng đã có thật**; mục 3 là **module sẽ có** (chưa có code).

## 1. Cách đọc một file module

Mỗi file module ghi: **mục đích → file/hàm cụ thể → API endpoint (nếu có) → local storage → trạng
thái → việc còn thiếu → cảnh báo khi sửa.**

## 2. Module hạ tầng — ĐÃ CÓ code

| Module | File | Trạng thái |
|---|---|---|
| [Bootstrap shell](bootstrap-shell.md) | `lib/main.dart`, `lib/ui/home_screen.dart` | 🟡 màn hình chẩn đoán, chưa có nghiệp vụ |
| [Foreground service](foreground-service.md) | `lib/services/foreground_service.dart`, `permission_gate.dart` | 🟡 chạy được trên code, **chưa test trên máy** |
| [Storage (SQLite + secure)](storage.md) | `lib/services/storage/*` | 🟡 chỉ mở DB + bảng `meta` |
| [Audio session](audio-session.md) | `lib/audio/app_audio_session.dart` | 🟡 mức khung, **chưa đo A2DP/HFP** |
| [Audio capture](audio-capture.md) | `lib/audio/capture/*` + `android/.../audio/*.kt` | 🟡 **code xong (P1A), chưa verify trên máy** (0/5 mục DoD) |
| [Conversation state (VAD)](conversation-state.md) | `lib/audio/vad/*` + `android/.../audio/VadDetector.kt` | 🟡 **code xong (P1B), chưa verify trên máy** (0/4 mục DoD) |
| [ASR engine](asr-engine.md) | `lib/audio/asr/*` + `android/.../asr/*.kt` + `cpp/*` | 🟡 **code xong (P1C + P1D)**; native compile xanh; chưa đo trên máy (K18/K19) |
| [Transcript store](transcript-store.md) | `lib/transcript/*` + `lib/services/storage/transcript_dao.dart` | 🟡 **code xong (P1E)**; SQLite v2 + migration (kiểm offline); chưa chạy trên máy (K27/K28) |
| [Suggestion engine](suggestion-engine.md) | `lib/suggestion/*` | 🟡 **code xong (P2)** + Offline Nudge Cache (P3); chưa test máy thật (K39 — cần Groq API key, có nút nhập key từ P3) |
| [Trigger + output mode](trigger-and-output.md) | `lib/trigger/*`, `lib/ui/floating_button.dart`, `lib/audio/{output_mode_selector,nudge_delivery}.dart` | 🟡 **code xong (P3)**; 49 test mới; chưa test máy thật (K41/K42), volume key/nút BT/thông báo còn nợ (K43) |
| [Pipeline integration (P4)](pipeline-integration.md) | `lib/services/conversation_session_controller.dart` | 🟡 **code xong (P4)** — orchestrator + half-duplex, 25 test mới (236/236 pass); **chưa verify máy thật** (K46). Phát hiện lỗi native K45 |
| [Coaching (P5)](coaching.md) | `lib/coaching/*`, `lib/ui/{pre_brief,post_review,stats}_screen.dart` | 🟡 **code xong (P5)** — Pre-Brief + Session Summary + Post-Review + Training Level, 66 test mới (**302/302 pass**; commit `4e25b74`, CI xanh); **0/5 mục DoD tick** vì cần máy thật + API key Groq (K48). Bước cloud ASR của prompt **cố ý bỏ** (mâu thuẫn ràng buộc #4) |
| Core (hằng số + logging) | `lib/core/constants.dart`, `app_logger.dart` | ✅ xong cho phạm vi hiện tại — không cần file riêng |

## 3. Module SẢN PHẨM — CHƯA có code (kế hoạch)

Đây là các feature thật của app sẽ được thêm dần. **Chưa file nào tồn tại**; mỗi file sẽ được tạo khi
phase tương ứng bắt đầu (và ghi vào bảng mục 2 lúc đó).

| Module | Phase | Tầng dự kiến | Mô tả ngắn |
|---|---|---|---|
> `audio-capture` (P1A) đã có code — xem bảng ở mục 2 phía trên.

> `vad-state` (P1B) đã có code — xem bảng ở mục 2 phía trên (tên module: `conversation-state`).

| `asr-phowhisper` | P1C | ~~`lib/transcript/`~~ → thực tế `lib/audio/asr/` | Engine ASR chính (GGML, JNI) — **đã xong** (xem `asr-engine.md`) |
| `asr-vosk` | P1D | ~~`lib/transcript/`~~ → thực tế `lib/audio/asr/` | Engine dự phòng + interface chung — **đã xong** (xem `asr-engine.md`) |
> `transcript-store` (P1E) đã có code — xem bảng ở mục 2 phía trên (file: `transcript-store.md`).
> `tts-safety` (P1F) đã có code — xem bảng ở mục 2 phía trên (file: `tts-safety.md`; **3 test case máy thật chưa chạy**).
> `emergency-phrase` (P1G) đã có code — xem `lib/audio/emergency/`; gesture thật (giữ nút nổi 2s) đã có từ P3, còn verify trên máy (K42).
> `suggestion-engine` (P2) đã có code — xem bảng ở mục 2 (file: `suggestion-engine.md`).
> `trigger-modes` (P3) đã có code — xem bảng ở mục 2 (file: `trigger-and-output.md`).
> `pipeline-halfduplex` (P4) đã có code — xem bảng ở mục 2 (file: `pipeline-integration.md`).
> `prebrief-postreview` (P5) đã có code — xem bảng ở mục 2 (file: `coaching.md`); thực tế nằm ở
> `lib/coaching/` (không phải `lib/suggestion/` như dự kiến ban đầu), vì đây là lớp "trước/sau buổi"
> dùng LLM chứ không phải luật gợi ý realtime.
| `semi-auto-mode` | P6 | `lib/trigger/` | Chế độ bán tự động (tuỳ chọn) |
| `hardening-release` | P7 | toàn dự án | Chống kill service, pin, release build |

Chi tiết từng tính năng + lý do: `features.md` (gốc repo) và `next.md`.
