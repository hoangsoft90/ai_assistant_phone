# architecture.md — Kiến trúc code

Cập nhật: 2026-09-21 (+07).

> **Đọc mục 0 trước.** Hiện repo mới có khung (P0.5). Các tầng trong mục 2 mới chỉ có **file
> README + vài file khung**; luồng dữ liệu ở mục 3 là **thiết kế đã chốt nhưng chưa implement**.

## 0. Kiểu kiến trúc đã chốt

**Layered theo domain (không phải feature-first).** Lý do: dự án này có **một** luồng nghiệp vụ
duy nhất chạy liên tục (audio → ASR → gợi ý → TTS → lưu trữ), không có nhiều màn hình/tính năng
độc lập kiểu e-commerce. Chia theo **tầng xử lý** giúp ràng buộc an toàn (P1F) nằm đúng một chỗ và
không bị "lách" qua các feature khác.

Hệ quả: **không** tổ chức theo `lib/features/<feature>/`. Nếu P5 (Pre-Brief/Post-Review/Coaching)
phình to thành nhiều màn hình độc lập thì mới cân nhắc lại — hiện chưa cần.

## 1. Cấu trúc thư mục

```
lib/
├── main.dart                  # bootstrap: init service, audio session, DB → runApp
├── core/                      # hằng số, logger — không phụ thuộc tầng nào
├── audio/                     # P1A: AudioRecord (mic điện thoại), P1F: SafeTtsOutput
├── transcript/                # P1C/P1D/P1E: engine ASR (PhoWhisper/Vosk) + transcript store
├── suggestion/                # P2: Suggestion Engine + Policy (LLM + luật an toàn)
├── trigger/                   # P3: cách kích hoạt gợi ý (nút bấm, từ khoá, im lặng...)
├── ui/                        # màn hình, widget
└── services/                  # foreground service, quyền, LLM client, storage/
    └── storage/               # SQLite + secure storage
android/app/src/main/
├── AndroidManifest.xml        # 7 quyền + service type=microphone
├── kotlin/com/aiassistant/phone/MainActivity.kt
└── cpp/                       # (chưa có ở project chính) JNI whisper.cpp — hiện nằm ở spikes/
test/
└── app_smoke_test.dart        # smoke test UI, có stub MethodChannel của 4 plugin
spikes/p0_audio/               # code thăm dò P0 — KHÔNG phải code sản phẩm
```

**Quy ước đặt file (quan trọng — tránh đặt sai tầng):**

| Loại code | Đặt ở đâu |
|---|---|
| Hằng số, tên channel/DB, id thông báo | `lib/core/constants.dart` (mọi "giá trị ma thuật" tập trung một chỗ) |
| Ghi log | `lib/core/app_logger.dart` — **không dùng `print`** (lint `avoid_print`) |
| Chạm vào API hệ thống (mic, audio attributes, service, DB) | `lib/services/` hoặc `lib/audio/` — **UI không được gọi thẳng plugin** |
| Màn hình/widget | `lib/ui/` — chỉ gọi qua lớp bọc trong `services/` |
| Model/dữ liệu | theo tầng sở hữu nó (`transcript/` cho bản ghi, `suggestion/` cho gợi ý) |

Bọc plugin trong lớp `abstract final class` (ví dụ `ListeningService`, `PermissionGate`,
`AppDatabase`) là **pattern chính của repo** → xem [patterns.md](patterns.md).

## 2. Vai trò từng tầng

| Tầng | Trách nhiệm | Trạng thái |
|---|---|---|
| `core/` | Hằng số, logger, (sau này) tiện ích thuần | ✅ có code |
| `audio/` | Chọn nguồn thu (mic điện thoại), cấu hình audio session, **SafeTtsOutput** (P1F) | 🟡 chỉ có `app_audio_session.dart` |
| `transcript/` | Engine ASR (abstract) + PhoWhisper/Vosk + lưu transcript theo thời gian | ⬜ chưa có code |
| `suggestion/` | Gọi LLM + Policy lọc gợi ý trước khi hiển thị/đọc | ⬜ chưa có code |
| `trigger/` | Quyết định *khi nào* đưa gợi ý (thủ công/bán tự động) | ⬜ chưa có code |
| `ui/` | Màn hình; hiện chỉ có `home_screen.dart` (màn hình chẩn đoán trạng thái) | 🟡 màn hình khung |
| `services/` | Foreground service, quyền runtime, storage, (P2) LLM client | 🟡 3 file |

## 3. Luồng dữ liệu (thiết kế đã chốt — chưa implement)

```
MIC ĐIỆN THOẠI (AudioRecord, P1A)
   │  PCM 16-bit, đọc theo buffer trong onRepeatEvent của foreground service
   ▼
VAD / phát hiện có tiếng nói (P1B)   ← trạng thái Sẵn sàng / Đang nghe / Đang phát
   │  chỉ phần có tiếng nói mới đưa sang ASR (tiết kiệm pin)
   ▼
ASR offline (P1C/P1D) — engine sau interface chung
   │  text + timestamp
   ▼
Transcript Store (P1E, SQLite)      ←── lưu ngay, không phụ thuộc LLM
   │  lấy N phút gần nhất
   ▼
Suggestion Engine (P2) ──► LLM cloud (chỉ gửi TEXT, không gửi audio)
   │  + Policy (luật an toàn, giới hạn tần suất, fallback offline)
   ▼
Trigger (P3)  → quyết định có đưa gợi ý ra lúc này hay không
   ▼
SafeTtsOutput (P1F) ──► tai nghe Bluetooth (A2DP)
   │  ⚠ CỔNG AN TOÀN: nếu output không phải A2DP → KHÔNG phát gì cả
   ▼
UI hiển thị gợi ý + Post-Review (P5)
```

**Ba điểm phải nhớ về luồng này:**

1. **Audio không bao giờ ra khỏi máy.** Chỉ `text` đi tới LLM.
2. **SafeTtsOutput là cổng duy nhất được phát ra loa.** Từ P1F, mọi thứ phát âm thanh phải đi qua
   nó. Trong code spike P0 có một `TtsTest` phát trực tiếp — **cố ý**, để đo hành vi thô của
   Android, và **tuyệt đối không được tái sử dụng**.
3. **Half-duplex:** đang phát TTS thì dừng thu; xong mới thu lại.

## 4. Luồng dữ liệu ở tầng lưu trữ (đã có khung)

- SQLite mở qua `AppDatabase.instance()` (singleton có cache; `close()` để đóng).
- DB hiện chỉ có bảng `meta`; **schema transcript là việc của P1E** và phải thêm bằng migration
  (`onUpgrade`), không được xoá/tạo lại DB của người dùng.
- API key LLM để trong `flutter_secure_storage` qua `SecureStore` — **không** để trong SQLite/SQLite
  plain text hay file cấu hình.

## 5. Quy ước với code spike `spikes/p0_audio/`

- Spike **không phải** code sản phẩm: có thể xoá bay cả thư mục mà không ảnh hưởng app.
- Những gì **đáng tái sử dụng** từ spike: 5 tool Python/shell trong `spikes/p0_audio/tools/`
  (convert model, tải audio test, chuẩn hoá âm lượng, đo WER), model GGML đã convert, và pattern JNI
  `whisper_jni.cpp`.
- Những gì **không được** mang sang: `TtsTest` (phát trực tiếp — xem cảnh báo ở mục 3).

## 6. Kiểm thử — hiện trạng

- `flutter analyze` + `flutter test` là 2 lệnh bắt buộc chạy trước khi báo xong (đã sạch ở P0.5).
- Test UI hiện có **stub MethodChannel** của 4 plugin (`flutter_foreground_task/methods`,
  `com.tekartik.sqflite`, `plugins.it_nomads.com/flutter_secure_storage`,
  `flutter.baseflow.com/permissions/methods`). Khi thêm plugin mới, phải thêm stub tương ứng —
  nếu không test sẽ đỏ vì thiếu native.
- **Không có** integration test / test trên máy thật trong CI (chưa có CI — xem
  [integrations.md](integrations.md)).
