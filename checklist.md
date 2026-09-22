# checklist.md — P0 & P0.5

Cập nhật: 2026-09-21 15:30 (+07). Nguồn chi tiết: `.plan/P0-result.md`, `.plan/P0_5-result.md`,
`spikes/p0_audio/README.md`, `README.md`.

## Đã làm

### P0 — phần không cần thiết bị

- [x] Kiểm tra Precondition của P0 → **không đạt** (không có thiết bị), đã dừng đúng quy trình.
- [x] Convert PhoWhisper → GGML: tiny f16 75MB / q5_0 30MB; base f16 142MB / q5_0 55MB. Kiểm chứng bằng cách decode thật trên 10 clip có ground-truth, không chỉ kiểm tra file tồn tại.
- [x] Tải model Vosk tiếng Việt: `vosk-model-small-vn-0.4` (51MB) + `vosk-model-vn-0.4` (168MB, test thêm).
- [x] Tooling tái sử dụng: `spikes/p0_audio/tools/{convert_phowhisper.sh,fetch_test_audio.py,normalize_audio.py,verify_models.py,verify_vosk.py}` + bằng chứng `reports/*.json`.
- [x] Đo baseline trên host: PhoWhisper-base q5_0 12.4% WER / RTF 0.53; tiny 15.5% / 0.29; Vosk small 52.2% (raw) → 41.1% (sau chuẩn hoá âm lượng); Vosk lớn 53.0% → 40.3%.
- [x] Viết code app spike (1129 dòng): Flutter UI + Kotlin (mic `AudioSource.MIC`, Vosk streaming, PhoWhisper chunk, probe route/pin, TTS test, foreground service) + JNI whisper.cpp (pin commit `307869a`).
- [x] Kiểm thử chạy được: `flutter analyze` sạch, `flutter test` pass, `whisper_jni.cpp` biên dịch sạch bằng g++ host, đối chiếu 3/3 symbol JNI Kotlin↔C++, hợp đồng MethodChannel/EventChannel Dart↔Kotlin khớp.
- [x] Ghi báo cáo phase `.plan/P0-result.md` + `working.md` + `openspec update` (không drift).

### P0.5 — Project Bootstrap

- [x] Tự kiểm Precondition của P0.5 → **không đạt**, đã báo mâu thuẫn và hỏi thay vì tự chọn; chủ dự án chọn **waive**.
- [x] `flutter create` project thật ngay tại gốc repo: package `ai_assistant_phone`, app id `com.aiassistant.phone`, **minSdk 26**, Android only. Không mất `.gitignore` custom hay file tài liệu nào (đã đối chiếu trước/sau).
- [x] Cấu trúc 7 tầng `lib/{core,audio,transcript,suggestion,trigger,ui,services}` — mỗi tầng có `README.md` riêng nêu vai trò + phase sẽ điền vào.
- [x] Manifest: 7 quyền (6 quyền prompt yêu cầu + `WAKE_LOCK`), service `type=microphone`, có ghi chú `INTERNET` chỉ dùng cho LLM ở P2.
- [x] Foreground service skeleton: `flutter_foreground_task` 11.0.3 (`init` + `TaskHandler` + `start`/`stop` + check quyền trước khi start), notification "Đang lắng nghe".
- [x] `audio_session` 0.2.4: `contentType=speech`, `usage=media` (cố ý **không** `voiceCommunication` để tránh kéo sang HFP/SCO), `willPauseWhenDucked`, lắng nghe `becomingNoisy`.
- [x] Lưu trữ: SQLite (`sqflite`) mở DB + bảng `meta` + chỗ migration; `flutter_secure_storage` cho API key LLM (P2).
- [x] Màn hình chính tối thiểu: trạng thái Sẵn sàng / Đang lắng nghe + nút bật/tắt + trạng thái hạ tầng (quyền, DB, API key).
- [x] Lint: `flutter_lints` + 8 rule bổ sung trong `analysis_options.yaml`.
- [x] Kiểm thử: `flutter scan`→ `flutter analyze` **No issues found**; `flutter test` **All tests passed** (smoke test có stub MethodChannel của 4 plugin).
- [x] Tra cứu version/API thật trước khi viết code (đọc source trong `~/.pub-cache`) — nhờ đó analyze sạch ngay lần đầu.
- [x] `README.md` gốc: yêu cầu môi trường, lệnh build/chạy, cấu trúc project, 4 bước kiểm tra nhanh trên máy thật.
- [x] Ghi báo cáo phase `.plan/P0_5-result.md` + cập nhật `working.md` / `checklist.md` / `next.md` / `faq.md` / `features.md`.

### P1A — Audio Capture Foundation (mic-only)

- [x] Tự kiểm Precondition (2 mục — **cả 2 không đạt**) và hỏi thay vì tự quyết; chủ dự án chọn **waive**.
- [x] `MicCaptureEngine.kt` — `AudioRecord` + `AudioSource.MIC`, 16kHz mono PCM16, thread `URGENT_AUDIO`, buffer 2× min, lỗi có code `PERMISSION_DENIED`/`UNAVAILABLE`/`CAPTURE_FAILED`.
- [x] `CaptureChannelBridge.kt` — MethodChannel control (`start`/`stop`/`dispose`/`error`) + EventChannel pcm; **1 engine dùng chung, sink riêng từng FlutterEngine**; không listener → bỏ chunk.
- [x] Đăng ký kênh cho **engine của service** qua `ForegroundService.addTaskLifecycleListener` (đúng yêu cầu "capture trong foreground service").
- [x] Dart: `capture_config.dart` (+`CaptureStatus`, sealed `CaptureError`), `capture_engine.dart` (hợp đồng), `capture_client.dart` (interface), `capture_channels.dart` (client native), `audio_capture_controller.dart` (facade + broadcast + `AudioCapture.instance`).
- [x] `wav_sink.dart` — tiện ích nghe lại `.wav` (opt-in, chỉ để kiểm thử thủ công).
- [x] UI: nút bật/tắt giờ mở/tắt mic (service trước → mic sau; nhả mic trước → tắt service sau) + rollback service khi mic lỗi + dòng `Thu âm` trên màn hình chẩn đoán.
- [x] Test: `test/audio_capture_test.dart` — **20 test** (config math, map lỗi, lifecycle, chunk ngoài cửa sổ, onError 1-handler, dispose, hợp đồng kênh thật); thêm stub 2 kênh mới vào smoke test.
- [x] Tự review Kotlin → **sửa 2 lỗi thật**: `stop()` join chính thread đọc; `onCancel` xoá chung set sink làm mất listener của engine kia.
- [x] Kiểm chứng: `flutter analyze` **No issues found**; `flutter test` **21/21 pass**.
- [ ] ⚠ **5 mục DoD của P1A chưa mục nào đo được** (60 phút nền, `dumpsys audio` HFP/SCO, tắt/bật tai nghe, nghe `.wav`, permission flow trên UI thật) — cần APK + máy thật. Xem `.plan/P1A-result.md`.

### P1B — VAD + State tối giản

- [x] Tự kiểm Precondition (không đạt) và hỏi thay vì tự quyết; chủ dự án chọn **waive**.
- [x] Tra cứu & đối chiếu API thật của thư viện VAD (`android-vad` WebRTC 2.0.10): đọc source `VadWebRTC.kt`/`FrameSize.kt`/`SampleRate.kt` + xác nhận artifact `.aar` HTTP 200 trên JitPack **trước khi** pin version.
- [x] `VadDetector.kt` — bọc WebRTC VAD: 16kHz, `FRAME_SIZE_320` (20ms/khung), `VERY_AGGRESSIVE`, `speechDurationMs/silenceDurationMs = 0` (để chỉ Dart quyết định thời gian).
- [x] Tích hợp VAD vào `MicCaptureEngine` (chạy trên thread thu, `setVadEnabled`, `analyze` chia khung) + kênh `com.aiassistant.phone/vad` trong `CaptureChannelBridge` (chỉ bật khi có listener).
- [x] `lib/audio/vad/` — `conversation_state.dart` (2 state + config ngưỡng có căn cứ + `VadFrameStat`), `vad_client.dart` (interface + client native), `conversation_state_notifier.dart` (`ConversationStateMachine` + singleton).
- [x] Logic chuyển state bằng **bộ tích luỹ rò** (300ms / 1500ms / ratio 0.5), có phép tính chứng minh DoD <500ms.
- [x] Expose cho P2: `ValueNotifier` + `Stream changes` + `Stream transitions` + `isUserSpeaking`.
- [x] Lịch sử chuyển state trong phiên (≤500 bản, read-only) + log qua `AppLogger`.
- [x] UI: dòng `Hội thoại` cập nhật live (`ValueListenableBuilder`); thứ tự bật/tắt service→capture→VAD và ngược lại.
- [x] Test: `test/conversation_state_test.dart` — **17 test** gồm **khoá phạm vi 2 state** và timeline hội thoại mẫu; thêm stub kênh VAD vào smoke test.
- [x] Kiểm chứng: `flutter analyze` **No issues found**; `flutter test` **38/38 pass**.
- [ ] ⚠ **4 mục DoD của P1B chưa đo được** (phản hồi <500ms với giọng thật, ngừng nói 1–2s, không flicker khi có nhạc/TV nền, chạy 30 phút) — cần APK + máy thật.
- [ ] **Tinh chỉnh 3 ngưỡng bằng dữ liệu thật** rồi ghi lại giá trị chốt (nợ K15).

### P1E — Transcript Store

- [x] **Model `TranscriptSegment` đúng ràng buộc** — **chỉ** `text` + `timestamp`, không có trường
  speaker/label (quyết định 4.2b); có comment nêu rõ lý do + ràng buộc xuyên phase.
- [x] **Ghi dòng xuống SQLite ngay khi nhận** (không gom lô) ⇒ bị kill đột ngột không mất dữ liệu đã ghi.
- [x] **Cửa sổ rolling trong RAM 8 phút**, đĩa giữ toàn bộ phiên; cửa sổ dài hơn thì đọc SQLite
  (không cắt cụt âm thầm).
- [x] **Schema SQLite v2 + migration `v1 → v2`** (3 bảng + 2 index) cho máy đã cài P0.5 — không xoá
  DB người dùng.
- [x] **Migration SQL kiểm bằng sqlite3 thật** (Python): trích thẳng 5 câu DDL từ `app_database.dart`,
  chạy trên DB v1 giả → bảng/index đúng, dữ liệu `meta` cũ còn nguyên.
- [x] **`markPushMoment(DateTime)`** ghi MỌI lần bấm (bảng riêng), `lastPushMoment` = mốc gần nhất.
- [x] **API cho P2**: `recentWindow(window:)` → text thô không nhãn (`\n` giữa các dòng) + mốc Push.
- [x] **Tự xoá sau 7 ngày** ở `init()` — xoá theo transaction 3 bảng (không để dòng mồ côi).
- [x] **Nối vào app**: `main()` gọi `init()` (recovery + cleanup chạy cả khi người dùng chưa bật ASR);
  `home_screen` attach/detach theo vòng đời ASR + dòng "Transcript"/"Push gần nhất" + nút Push tạm.
- [x] **16 test mới (`test/transcript_store_test.dart`)** — gồm khôi phục phiên đang dở, phiên quá hạn,
  hạn 7 ngày (kiểm cả mốc cutoff), thứ tự khi 3 dòng đến sát nhau, và **regression bug attach/detach**.

### Knowledge base & memory files (ngoài phạm vi DoD)

- [x] Tạo `.project/` — 13 file: `README.md` (entry), `overview.md`, `architecture.md`, `state-routing.md`,
      `patterns.md`, `design-system.md`, `integrations.md`, `openspec.md`, `modules/{README,bootstrap-shell,
      foreground-service,storage,audio-session}.md`.
- [x] Tạo `context.md` + `operating_rules.md` (22 rule riêng của project) + `CLAUDE.md` (entry ngắn → `AGENTS.md`).
- [x] **Điền phần `PROJECT` trong `AGENTS.md`**: Role & Context, thứ tự đọc navigation, **12 Critical Rules**,
      Workflow theo repo, git convention (chưa chốt). Không còn placeholder `<!-- ĐIỀN -->`.
- [x] Kiểm chứng: 60 file `.md` → 0 link nội bộ hỏng; `.project/` + các file memory **không** bị gitignore.
- [x] `openspec update` → 3 tool up to date (v1.13.1), không drift.

## Chưa làm

### Thuộc P0 (đang chặn, cần thiết bị)

- [ ] Task 1.4/1.5: đo độ chính xác trên giọng người dùng, độ trễ, pin, ổn định 45–60 phút.
- [ ] Task 2: xác định giữ A2DP hay bị ép HFP.
- [ ] Task 3: xác nhận TTS không lọt ra loa ngoài (kể cả khi rút tai nghe giữa chừng).
- [ ] Task 4: pipeline chạy ≥45 phút liên tục không crash/mất transcript.
- [ ] Quyết định go/no-go bằng văn bản (PhoWhisper hay Vosk cho P1C/P1D). ← **nợ kỹ thuật, đang treo**

### Thuộc P0.5 (DoD chưa xác minh — cần build + máy thật)

- [ ] **App build thành công, cài được lên máy thật** (`flutter run --release`) — chưa từng build; máy dev thiếu Android SDK.
- [ ] **Foreground service chạy được, hiện notification, không crash khi chạy nền vài phút** — chưa kiểm trên thiết bị.
- [ ] **Manifest build không lỗi liên quan permission** — khai báo xong nhưng build chưa chạy.
- [ ] **Commit theo từng bước** (DoD Bàn giao) — repo hiện **0 commit**, đang chờ chủ dự án xác nhận.

### Thuộc P1A (DoD chưa xác minh — cần APK + máy thật)

- [ ] Capture liên tục ≥60 phút, màn hình tắt, không crash/không bị kill.
- [ ] `dumpsys audio`: route không chuyển HFP/SCO suốt quá trình capture.
- [ ] Tắt/bật tai nghe Bluetooth giữa chừng không làm gián đoạn capture.
- [ ] Phát stream đúng + nghe lại file `.wav` để xác nhận chất lượng.
- [ ] Permission flow trên UI thật: từ chối quyền → không crash + có hướng dẫn.
- [ ] **Mã Kotlin chưa từng được biên dịch** — rủi ro build đầu tiên (nợ K11, nay gồm cả P1B).

### Thuộc P1C (DoD chưa xác minh — cần APK + máy thật)

- [ ] **PhoWhisper chạy trong app thật** (code xong, chờ run #4 CI compile native lần đầu + cài máy thật).
- [ ] **Độ trễ mỗi chunk đo được** — kênh đo đã có sẵn trong code (log `latencyMs/audioMs` mỗi chunk).
- [ ] **Pin 30–45 phút đo được**.
- [ ] **Quyết PhoWhisper/Vosk làm mặc định** — thuộc P1D, phải dựa số on-device (số host: PhoWhisper 12–16% WER thắng Vosk 41–52%, nhưng RTF 0.29–0.53 có thể chậm trên CPU điện thoại).
- [x] **K17 — ĐÓNG:** C/C++ + Kotlin ASR đã compile & link thành công (CI run #7, commit `10eeb5a`).

### Thuộc P1D (đã làm / chưa xác minh)

- [x] **VoskAsrEngine đúng interface** — test hợp đồng dùng chung cho cả 2 engine (`test/asr_engine_contract_test.dart`).
- [x] **Đổi engine qua config, không sửa tầng trên** — `AsrEngineSelector` + test (9 test) + dropdown trên màn hình chính.
- [x] **Quyết định engine mặc định bằng văn bản** — `lib/audio/asr/README.md` (PhoWhisper mặc định, **tạm thời**).
- [x] **Fallback tự động** khi `init()` lỗi (prompt ghi "tuỳ chọn") + test khoá hành vi.
- [ ] **Bảng so sánh 2 engine trong app thật** (DoD P1D) — cần APK + máy thật (K19).
- [ ] **Vosk chạy ≥45 phút liên tục** (DoD P1D) — cần máy thật (K19).
- [ ] **K20 (🟠):** JNA có nạp được `libjnidispatch.so` trên máy thật không — đã bật `useLegacyPackaging` + proguard keep rules; xác nhận bằng logcat `VoskBridge`.
- [ ] **K21 (🟠):** APK +32MB (model Vosk) + ~51MB giải nén lần đầu trong `filesDir`; RAM khi nạp model chưa đo — ảnh hưởng trực tiếp quyết định engine mặc định.
- [ ] **Quyết PhoWhisper/Vosk là mặc định** — hiện chọn PhoWhisper theo số host P0 (WER 16.6% vs 52.2%), cần xác nhận bằng RTF/pin trên máy (K18/K19).

### Phát hiện từ review P1D — ĐÃ SỬA (commit `2c0ae82` + `e6f01ac`, CI `35617319912` xanh)

- [x] **K22 — việc nặng chạy trên main thread:** `loadModel` (Vosk) giải nén 51MB + `Model()` + `Recognizer()` **ngay trong method handler** của MethodChannel ⇒ handler chạy trên platform/main thread ⇒ treo UI lần nạp đầu, có nguy cơ vào vùng ANR (5s) trên máy chậm. `AsrChannelBridge` (P1C) cùng vấn đề ở mức nhẹ hơn (`whisper_init_from_file` trên main).
- [x] **K23 — worker Vosk có thể sống lại sau release bị treo:** `release()` bỏ qua việc đóng native khi thread chưa dừng, nhưng `load()` sau đó đặt `closed=false` ⇒ **thread cũ sống lại và dùng chung `recognizer` với thread mới** (Vosk native không thread-safe). Cần "thế hệ" (generation token).
- [x] **K24 — getter chết:** `audioMsTotal`, `pendingChunks`, `droppedTotal` trong `VoskStreamingBridge` không có nơi gọi (bước dead-code check của review).
- [x] **K25 — `init()` không có timeout:** nếu phía native không bao giờ trả lời `loadModel`, `AsrEngineSelector` không bao giờ chạy fallback và UI kẹt ở trạng thái bận.
- [x] **K26 — mất câu đang nói dở khi tắt ASR:** Vosk không gọi `getFinalResult()` trong `dispose()` ⇒ audio từ endpoint cuối tới lúc tắt không được nhận dạng.

### Thuộc P1E — ĐÃ KIỂM TRÊN MÁY THẬT (Pixel 3a / Android 12 / arm64-v8a, APK `9f4508e`, 2026-09-22)

- [x] **K27a — transcript thật vào đĩa:** ASR trên máy sinh **dòng thật** trong `transcript_segments`
  (đọc DB bằng `run-as` + sqlite3), mỗi dòng có timestamp.
- [x] **K27b — crash recovery:** force-stop app → mở lại ⇒ **vẫn phiên cũ**, ghi tiếp đúng phiên đó
  (không tạo phiên mới).
- [x] **K27c — hạn 7 ngày:** phiên 8 ngày trước bị xoá cả dòng + mốc Push; phiên hôm nay còn nguyên.
- [x] **K27d — migration v1→v2 thật trên máy:** tạo DB v1 (chỉ bảng `meta`) → cài vào app → mở app ⇒
  `user_version` **1 → 2**, có `transcript_sessions`/`transcript_segments`/`transcript_pushes` + 2 index,
  **dữ liệu `meta` cũ nguyên vẹn** (không mất `asr.engine`, `created_at`).
- [ ] **DoD-4 (mốc Push) trên máy:** nút "Đánh dấu Push (P1E)" **chưa bấm** — máy đang được dùng nên
  tôi không tap bừa (xem bài học A39). Unit test đã phủ `markPushMoment`.
- [ ] **Nhịp ghi đĩa chưa đo:** 1 INSERT + 1 UPDATE mỗi ~4s/chunk — chưa biết ảnh hưởng pin/I/O trên
  máy thật thế nào (đo cùng lúc với K18/K19).
- [ ] **K28 (🟠) — cần người dùng chốt:** có chuyển sang **DB mã hoá (SQLCipher)** không? Đã kiểm tài
  liệu: `sqflite` **không** hỗ trợ mã hoá, phải đổi sang `sqflite_sqlcipher`. Prompt P1E cho phép bỏ
  qua ở phase này ⇒ hiện dữ liệu nằm trong sandbox app + tự xoá sau 7 ngày.

### Phát hiện mới trên máy thật 2026-09-22 (CHƯA sửa — cần quyết định)

> Đây là kết quả đo trên máy, không phải suy đoán. Nguồn: logcat, DB trên máy, giải mã
> central directory của APK đang cài, CPU `top -H`.

- [~] **K29 (🔴) — ASR tốc độ: ĐÃ SỬA 35 LẦN, gần đạt (RTF 1.13) nhưng CHƯA realtime.**

  | | Bản cũ (trước fix) | Bản sau fix (`bac1414`, đo 2026-09-22 10:47–10:50) |
  |---|---|---|
  | latency / chunk 4s | **~160 000 ms** | **trung vị 4 511 ms** (min 4 105 · max 6 462) |
  | RTF | **~39** | **1.13** (min 1.03 · max 1.62) |
  | chunk bị bỏ | 59 liên tục (mất gần hết audio) | **8 trong ~5 phút** (≈1 chunk/40s) |
  | output | gần như không có | **54 dòng transcript thật** trong 4.7 phút, khoảng cách trung vị 4 535 ms |
  | crash | — | **0** (không còn SIGILL sau khi revert `-march`) |

  Máy test: Pixel 3a, `threads=4` (đã xác nhận trong log `AsrJni`), có người nói thật trong lúc đo
  (VAD chuyển `userSpeaking`/`notUserSpeaking` liên tục). Chi tiết + log ở `.plan/P1E-result.md`.
  **Còn lại để đạt realtime:** xem **K33** bên dưới.

  Bốn nguyên nhân đã khoanh vùng (K29a/b/c đã sửa, K29d còn mở), **cộng dồn** đủ giải thích 39x:
  - [x] **K29a — `threads = 2`** trên máy **8 nhân** ⇒ **đã sửa `2ecdd3b`:** `threads = 0` = tự động
    `min(4, số nhân)` (`resolvedThreads`) + 2 test khoá hành vi + log in `threads=x/8 nhân`.
  - [x] **K29b — native build theo variant Debug:** ⇒ **đã sửa `2ecdd3b`:** thêm `add_compile_options(-O3)`
    TRƯỚC `FetchContent_MakeAvailable` (cờ thư mục/target được chèn sau cờ build type mới thắng `-O0`),
    kèm bước CI in `CMakeCache.txt` + `compile_commands.json` để có bằng chứng cờ. Ghi gốc:
    CI log có `:app:configureCMakeDebug[abi]` và
    **không có** `-DCMAKE_BUILD_TYPE` nào trong `CMakeLists.txt`/`build.gradle.kts` ⇒ whisper.cpp +
    ggml biên dịch theo Debug của NDK (`-O0`). Host P0 build `-DCMAKE_BUILD_TYPE=Release`
    (`spikes/p0_audio/tools/convert_phowhisper.sh` dòng 52). **Xác nhận dứt điểm** bằng cách thêm 1
    bước CI in `build/.cxx/Debug/*/arm64-v8a/CMakeCache.txt` + `compile_commands.json` (2 lib đã bị
    strip DWARF nên không đọc được cờ từ `.so`).
  - [x] **K29c — cờ `-march` đã thử và phải REVERT (crash thật):** commit `2ecdd3b` thêm
    `-march=armv8.2-a+dotprod+fp16`; **cài lên máy ⇒ crash SIGILL ngay chunk đầu**
    (`signal 4 ILL_ILLOPC` tại `libggml-cpu.so ggml_vec_dot_q5_0_q8_0+256` → `whisper_full`).
    Máy test (`/proc/cpuinfo`) **không có `asimddp`** (dot product) dù có `asimdhp` (fp16) —
    CPU part `0x803` (A75) ×6 + `0x802` (A55) ×2. Đã revert trong `bac1414`, chỉ giữ `-O3`, kèm
    cảnh báo ⛔ trong `CMakeLists.txt` + bài học **A42**. Muốn có dotprod ⇒ phải build 2 biến thể
    và chọn theo HWCAP lúc chạy (chưa làm, chờ quyết định).
  - [x] **K29d — chunk 4s + whisper pad ~30s — ĐÃ XÁC NHẬN bằng đo A/B trên máy (2026-09-22):**
    chunk 4s RTF trung vị **1.47** trong khi chunk 12s chỉ **0.31** (cùng bản APK, cùng máy) —
    chi phí cố định ~30s mel pad mỗi lần gọi `whisper_full` là thật. Số liệu đầy đủ: bảng trong
    `lib/audio/asr/README.md` mục 6b.
  - [x] **K33 (🟠) — đường để RTF < 1 — ĐÃ ĐO XONG trên máy (2026-09-22), ĐẠT realtime:**
    | Config | RTF trung vị | Chunk bị bỏ |
    |---|---|---|
    | 4s/4 | 1.47 | (31 trước đo) |
    | 8s/6 | 0.63 | 1 |
    | **12s/6** | **0.31** | **0** |
    Đổi bằng `AsrTuning` qua bảng `meta` (không build lại) — đúng như thiết kế. Cấu hình tốt nhất:
    **12s/6**. Máy test đang giữ config này; mặc định trong code vẫn 4s/auto — quyết định đổi mặc
    định cho mọi máy là của user (đánh đổi: độ trễ hiển thị câu ~12–16s). Chi tiết: `lib/audio/asr/README.md` mục 6b.
- [x] **K30 (🟠) — `abiFilters` bị plugin Flutter ghi đè** ⇒ **đã sửa `2ecdd3b`:** gốc là
  `FlutterPlugin.configureAbiWithoutSplits()` gọi `abiFilters.clear()` + `addAll(PLATFORM_ABI_LIST)`
  = [armeabi-v7a, arm64-v8a, x86_64] **sau** khi app khai báo ⇒ phải bật property
  `disable-abi-filtering=true` trong `android/gradle.properties`. Bằng chứng cũ: APK **155MB, 3 ABI**,
  CI configure CMake cho cả `[armeabi-v7a]`/`[x86_64]`. Bước CI mới sẽ in ABI thật trong APK để chốt.
- [ ] **K31 (🟠) — JNA/Vosk:** `libjnidispatch.so` **có trong APK cho arm64-v8a** ✅ (phần packaging
  đạt, `useLegacyPackaging` hoạt động). Còn thiếu xác nhận **runtime**: chọn engine Vosk + bật ASR
  trên máy (cần 2 lần bấm — chờ user hoặc lúc máy rảnh).
- [ ] **K32 (🟡) — RAM khi ASR chạy (K21):** chưa đo `dumpsys meminfo` trong lúc ASR bật.

### Thuộc P1F (DoD chưa xác minh — cần APK + máy thật + tai nghe) — K34 🔴

> Phase an toàn quan trọng nhất của app: **không được** tick chỉ vì code chạy không lỗi.
> Lệnh thu bằng chứng: `adb logcat -v time -s SafeTts:V flutter:V | tee /tmp/p1f_run.log`
> và `adb shell dumpsys audio | grep -iE "a2dp|sco|ForceUse"`.

- [ ] **Test case 1:** rút tai nghe **giữa lúc đang đọc** → log `becomingNoisy`/`MẤT thiết bị riêng tư`
  + `đã DỪNG phát TTS` + rung 2 nhịp, **không** nghe gì từ loa ngoài (xác nhận bằng tai + video).
- [ ] **Test case 2:** rút tai nghe rồi mới bấm đọc → `không có tai nghe ⇒ KHÔNG phát TTS` + rung 1 nhịp,
  không có AudioTrack nào được tạo.
- [ ] **Test case 3:** tắt kết nối Bluetooth trong Cài đặt **giữa lúc đang đọc** → hành vi như test case 1.
- [ ] Sau khi mất kết nối: bấm "Đọc thử" tiếp → phải bị chặn (`chưa xác nhận route`) cho tới khi bấm
  nút **"Xác nhận tai nghe đã sẵn sàng (P1F)"**.
- [ ] Dòng `TTS` trên màn hình chẩn đoán hiện đúng tên/loại thiết bị đang được coi là tai nghe.

### Thuộc P1B (DoD chưa xác minh — cần APK + máy thật)

- [ ] Nói to gần mic → `userSpeaking` trong <500ms (đo bằng giọng thật).
- [ ] Ngừng nói ~1–2s → về `notUserSpeaking`.
- [ ] Môi trường ồn nền (nhạc/TV) → không flicker liên tục.
- [ ] `Stream<ConversationState>` ổn định ≥30 phút chạy liên tục.
- [ ] In **timeline state thật** từ logcat và đối chiếu timeline tổng hợp trong `test/conversation_state_test.dart`.
- [ ] **Dependency JitPack (`android-vad:webrtc:2.0.10`) chưa resolve bằng build thật** (nợ K14).

## Cần làm (thứ tự đề xuất)

1. **Chốt đường build** — GitHub Actions (chờ repo) hoặc cài Android SDK/NDK tạm vào `/tmp` ở máy này.
2. **Build APK** (debug trước) + cài lên thiết bị → xác minh 3 mục DoD còn lại của P0.5. **(Người dùng đã chốt: KHÔNG build APK trên máy dev này — `df` cho thấy `/home` còn ~265MB, không đủ SDK/NDK + build cache; đường build duy nhất là GitHub Actions, chờ repo.)**
3. Chạy 4 bước ở mục "Kiểm tra nhanh trên máy thật" trong `README.md` (quyền mic/thông báo, FGS sống khi tắt màn hình, DB tạo được, `becomingNoisy` ghi log khi rút tai nghe).
4. **Xác minh phần P0 trên máy thật** (Task 1→4, protocol ở `spikes/p0_audio/README.md` mục 3) — dùng app spike trong `spikes/p0_audio/app/`.
5. Điền số liệu on-device vào bảng DoD, viết kết luận go/no-go, cập nhật `.plan/P0-result.md`.
6. Quyết định số phận code spike `spikes/p0_audio/` khi sang P1A (mặc định: bỏ, chỉ giữ tooling + model + JNI pattern).
7. Tạo `context.md` + `operating_rules.md` + OpenSpec change đầu tiên (`add-project-bootstrap` hoặc tên tương đương cho P1A).

## Cần hỏi lại người dùng

- [x] ~~Repo GitHub dự định tạo là repo nào, có muốn dựng workflow build APK~~ → **Đã xong 2026-09-21:** repo `hoangsoft90/ai_assistant_phone` (branch `main`), workflow `build-debug-apk.yml` chạy bằng gradlew trực tiếp, run #1 đã trigger. Token GH do user cấp, lưu trong skill `.agents/skills/ai-assistant-phone-debug-apk/SKILL.md` (local-only), không hỏi lại.
- [ ] Có commit phần P0 + P0.5 hiện tại không? (repo **0 commit**; tôi chưa commit gì.) Nếu có, muốn chia mấy commit?
- [ ] Xoá hay giữ `spikes/p0_audio/` (code thăm dò P0)? Prompt P0.5 nói "thay thế hoàn toàn" nhưng xoá là việc khó hoàn tác nên tôi chưa làm.
- [ ] Khi có điện thoại: bạn tự thao tác phần tay (rút tai nghe giữa lúc TTS, chấm % từ đúng) hay muốn tôi hướng dẫn từng bước realtime?
- [ ] Ổ đĩa `/home` chỉ còn ~396MB: có được phép xoá model f16/vosk-bản-lớn trong `/tmp/p0spike` (ngoài repo) để lấy chỗ build không?
- [ ] `.plan/` đang bị gitignore → `.plan/P0_5-result.md` sẽ không vào git. Có muốn copy sang `docs/` không?
- [ ] **K28 — transcript có cần mã hoá DB không?** (`sqflite` không hỗ trợ; phải đổi package sang `sqflite_sqlcipher` + chuyển dữ liệu cũ). Hiện dựa vào sandbox app + xoá sau 7 ngày.
- [ ] Có cho phép tôi tạo skill từ `LESSONS_LEARNED.md` trong `~/.agents/skills/` không? (Theo `writing-skills`, cần chạy baseline test trước.)
