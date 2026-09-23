# asr-engines Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P1C PhoWhisper, P1D Vosk + selector, tối ưu + rà lỗi P4).
> Nguồn sự thật: `lib/audio/asr/`, `android/app/src/main/kotlin/com/aiassistant/phone/asr/`,
> `lib/audio/asr/README.md`, `test/{phowhisper_asr_test,asr_engine_selector_test,asr_engine_contract_test}.dart`,
> `.project/modules/asr-engine.md`.

## Purpose

Bóc băng giọng nói **100% offline** thành text tiếng Việt qua 2 engine cùng một interface `AsrEngine`:
**PhoWhisper** (whisper.cpp, chunk 4s, mặc định) và **Vosk** (streaming, dự phòng). `AsrEngineSelector`
chọn engine theo config trong bảng `meta` — đổi engine KHÔNG phải build lại app và tầng trên
(transcript P1E, suggestion P2) KHÔNG phụ thuộc engine cụ thể.

## Requirements

### Requirement: Interface ASR chung

Mọi engine **PHẢI (MUST)** implement `AsrEngine` (`lib/audio/asr/asr_engine.dart`): `init()`,
`feedAudioChunk(Uint8List PCM16 16kHz)`, `transcriptStream` (chỉ text thành công — lỗi KHÔNG vào
stream, được báo qua kênh riêng), `dispose()`. Engine khởi tạo/giải phóng model **PHẢI (MUST)** chạy
trên loader thread riêng (sửa F1/K22 — không treo UI/ANR).

#### Scenario: Đổi engine không sửa tầng trên

- **GIVEN** transcript store và suggestion engine đã nối ASR qua interface
- **WHEN** `AsrEngineSelector.readConfigured()` trả engine khác
- **THEN** tầng trên vẫn nhận `Stream<String>` text mà không biết (cần không biết) engine cụ thể nào đang chạy

#### Scenario: Transcribe chưa xong khi bị đóng

- **GIVEN** Whisper đang transcribe một chunk
- **WHEN** engine bị đóng (dừng nghe) trong lúc đó
- **THEN** KHÔNG free model khi transcribe chưa xong sau 5s (log `AsrBridge: transcribe chưa xong sau 5s — KHÔNG free model`) — tránh use-after-free/crash tiến trình (K47; **đã hoạt động thật trên máy** 2026-09-23)

### Requirement: PhoWhisper gom chunk có drop policy

Engine PhoWhisper **PHẢI (MUST)** gom audio 4 giây (mặc định `AsrTuning.defaultChunkSeconds = 4`,
threads = 0 ⇒ tự động `min(4, số nhân)`) và khi bị chậm KHÔNG gộp backlog — drop chunk cũ, giữ chunk
mới nhất. Model tiny q5_0 (29MB) nằm trong APK assets (`assets/models/ggml-phowhisper-tiny-q5_0.bin`).

#### Scenario: Engine chậm hơn realtime

- **GIVEN** đang nói liên tục và transcribe mất lâu hơn 4s
- **WHEN** chunk mới sẵn sàng trong khi chunk cũ chưa xong
- **THEN** engine bỏ chunk cũ, xử lý chunk mới — số `bỏ N chunk` hiện trên dòng ASR cho người dùng theo dõi

#### Scenario: Threads tự động

- **GIVEN** config `asr.threads` không có hoặc = 0
- **WHEN** engine khởi tạo
- **THEN** số thread = `min(4, số nhân CPU)` (máy thật Pixel 3a: `threads=4` trong log `AsrJni: load model`)

### Requirement: Vosk streaming dự phòng

Engine Vosk **PHẢI (MUST)** chạy streaming (KHÔNG gom chunk ở Dart — khác PhoWhisper CÓ CHỦ Ý),
model zip do Kotlin tự giải nén từ Android asset (`models/vosk-model-small-vn-0.4.zip`, CI tải + kiểm
SHA256 trước build), `initTimeout` 60s (sửa F3/K25), flush kết quả cuối khi release (sửa F4/K26).

#### Scenario: Engine dự phòng sẵn sàng

- **GIVEN** config `asr.engine='vosk'`
- **WHEN** app bật nhận dạng
- **THEN** model zip được giải nén từ asset, recognizer streaming trả text liên tục; nếu init vượt 60s ⇒ lỗi có kiểm soát (không treo vô hạn)

### Requirement: Chọn engine theo config

`AsrEngineSelector` **PHẢI (MUST)** đọc/ghi config `asr.engine` trong bảng `meta`; giá trị lạ/thiếu ⇒
fallback PhoWhisper (log cảnh báo, không ném). Đổi engine khi đang lắng nghe là việc của tầng phiên
(P4) — selector chỉ quản lý config.

#### Scenario: Máy mới dùng mặc định

- **GIVEN** bảng `meta` chưa có khoá `asr.engine`
- **WHEN** `readConfigured()` chạy
- **THEN** trả PhoWhisper; khi người dùng chọn Vosk qua UI, config ghi `'vosk'` và được giữ lại cho lần mở app sau (bằng chứng buổi test adb 2026-09-23)
