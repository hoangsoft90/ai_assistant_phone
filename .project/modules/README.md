# modules/ — Danh sách module

Cập nhật: 2026-09-21 (+07).

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
| `transcript-store` | P1E | `lib/transcript/` | Lưu transcript vào SQLite, truy vấn N phút gần nhất |
| `tts-safety` | P1F | `lib/audio/` | **SafeTtsOutput** — cổng an toàn duy nhất được phát ra loa |
| `emergency-phrase` | P1G | `lib/trigger/` | Câu thoát hiểm phát hoàn toàn local, không qua LLM |
| `suggestion-engine` | P2 | `lib/suggestion/` | Gọi LLM + Policy lọc gợi ý; fallback offline |
| `trigger-modes` | P3 | `lib/trigger/` | Cách kích hoạt gợi ý + chế độ hiển thị + cache nudge offline |
| `pipeline-halfduplex` | P4 | ghép các tầng | Ghép toàn bộ luồng, đảm bảo half-duplex |
| `prebrief-postreview` | P5 | `lib/ui/`, `lib/suggestion/` | Chuẩn bị trước cuộc nói + xem lại sau |
| `semi-auto-mode` | P6 | `lib/trigger/` | Chế độ bán tự động (tuỳ chọn) |
| `hardening-release` | P7 | toàn dự án | Chống kill service, pin, release build |

Chi tiết từng tính năng + lý do: `features.md` (gốc repo) và `next.md`.
