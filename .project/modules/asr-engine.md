# Module: ASR Engine (nhận dạng tiếng nói, offline)

> Trạng thái: **code xong P1C (PhoWhisper) + P1D (Vosk) — chưa đo trên máy thật.**
> Quyết định engine mặc định: **`lib/audio/asr/README.md`** (nguồn sự thật, không lặp lại ở đây).

## Nhiệm vụ

Biến chunk PCM16 mono 16kHz (từ module `audio-capture`) thành **transcript text**, 100% offline,
KHÔNG gắn nhãn người nói. Là đầu vào của P1E (transcript store) và P2 (suggestion engine).

## Thành phần

| File | Vai trò |
|---|---|
| `lib/audio/asr/asr_engine.dart` | Interface `AsrEngine` (P1C): `init()`, `transcriptStream`, `feedAudioChunk()`, `dispose()`, `droppedTotal` (mặc định 0) |
| `lib/audio/asr/phowhisper_asr_engine.dart` | Engine chính: whisper.cpp; Dart gom **4s** rồi gửi; kênh `com.aiassistant.phone/asr` |
| `lib/audio/asr/vosk_asr_engine.dart` | Engine dự phòng: Vosk; **streaming** (không gom); kênh `com.aiassistant.phone/vosk` |
| `lib/audio/asr/asr_engine_selector.dart` | `AsrEngineKind` + đọc/ghi config + `createAndInit()` có **fallback tự động** |
| `lib/services/storage/meta_store.dart` | `ConfigStore` + bản SQLite (bảng `meta`, khoá `asr.engine`) |
| `android/.../asr/AsrChannelBridge.kt` | JNI wrapper whisper + engine chunk (executor 1 thread, drop policy giữ chunk mới nhất) |
| `android/.../asr/VoskChannelBridge.kt` | Vosk streaming (thread riêng + hàng đợi giới hạn) + tự giải nén model từ Android asset |
| `android/app/src/main/cpp/` | `whisper_jni.cpp` + `CMakeLists.txt` (FetchContent pin commit whisper.cpp) |

## Luồng dữ liệu

```text
mic (audio-capture) ─► Stream<Uint8List> chunk PCM16 16kHz
                          ├─ PhoWhisper: gom 4s ─► kênh /asr ─► JNI whisper.cpp ─► 'transcript'
                          └─ Vosk: từng chunk  ─► kênh /vosk ─► Vosk acceptWaveForm ─► 'transcript'
                                                                          │
                                        transcriptStream (String) ◄───────┘
```

## Cách đổi engine (không build lại)

1. UI màn hình chính: dropdown `Engine nhận dạng (ASR)` → ghi `asr.engine` vào bảng `meta`.
2. Tầng trên gọi `AsrEngineSelector(...).createAndInit()` — **không** tự `new` engine.
3. Fallback: `init()` lỗi ⇒ tự chuyển engine còn lại + log; cấu hình đã lưu KHÔNG đổi.

## Model & dung lượng

| Engine | Model | Vị trí | Trong git |
|---|---|---|---|
| PhoWhisper | `ggml-phowhisper-tiny-q5_0.bin` (29MB) | `assets/models/` (Flutter asset) | có |
| Vosk | `vosk-model-small-vn-0.4.zip` (32MB → 51MB giải nén) | `android/app/src/main/assets/models/` (Android asset) | không — CI tải + kiểm SHA256 |

Vì sao khác nhau: xem `pubspec.yaml` mục `assets:` và `lib/audio/asr/README.md` §5.

## Ràng buộc không được vi phạm

- Chiều thu **100% offline** — không có đường cloud ASR (chỉ Post-Review P5 được phép, và chỉ khi có Wi-Fi).
- Transcript **không có nhãn người nói** (bắt buộc từ P1E trở đi).
- Âm thanh chỉ được phát qua `SafeTtsOutput` (P1F) — không liên quan chiều thu nhưng nhắc để không quên.

## Nợ đang treo

- **K18/K19:** mọi số đo trên máy thật (RTF, pin, nhiệt, 45 phút liên tục, so sánh 2 engine).
- **K20:** JNA nạp `libjnidispatch.so` trên máy thật (đã phòng bằng `useLegacyPackaging` + proguard).
- **K21:** APK +32MB, `filesDir` +51MB lần đầu, RAM khi nạp model Vosk chưa đo.
