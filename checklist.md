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

### Thuộc P1F (đã test MỘT PHẦN trên máy thật 2026-09-22 — K34 thu hẹp)

> Phase an toàn quan trọng nhất của app: **không được** tick chỉ vì code chạy không lỗi.
> Lệnh thu bằng chứng: `adb logcat -v time -s SafeTts:V flutter:V | tee /tmp/p1f_run.log`
> và `adb shell dumpsys audio | grep -iE "a2dp|sco|ForceUse"`. Chi tiết buổi test:
> `.plan/P1F-result.md` mục "Cập nhật sau buổi test qua adb".

- [x] **Phát TTS đầu-cuối qua tai nghe (fix A45 hiệu lực thật):** log `đã phát 111946/111946 byte`,
  **user xác nhận nghe rõ**, `SCO_STATE_INACTIVE`, route `USAGE_MEDIA`.
- [x] **Phát hiện mất tai nghe + rung 2 nhịp:** `MẤT thiết bị riêng tư: 4` → `đã rung: HEADSET_LOST` (9ms);
  `Connected devices` rỗng sau rút; chặn phát khi chưa xác nhận (fail-closed) được xác minh thật.
- [x] Dòng `TTS` trên màn hình chẩn đoán hiện đúng thiết bị: `Pixel 3a (type 4) · 1 thiết bị riêng tư`.
- [ ] **Rút tai nghe GIỮA LÚC ĐANG ĐỌC** — 2 lần thử đều rút sau khi clip đã phát xong (2,5s tổng hợp
  im lặng trước khi tiếng ra làm lỡ nhịp); chưa có bằng chứng dừng-mid-playback.
- [ ] **Test case 2:** rút tai nghe rồi mới bấm đọc → `không có tai nghe ⇒ KHÔNG phát TTS` + rung 1 nhịp,
  không có AudioTrack nào được tạo. (user dừng buổi test trước khi tới case này)
- [ ] **Test case 3:** tắt kết nối Bluetooth trong Cài đặt **giữa lúc đang đọc** — chưa có tai nghe BT.
- [ ] **K37 — F-P1F-1:** callback baseline của `registerAudioDeviceCallback` bị coi là "kết nối lại"
  ⇒ mỗi lần mở app có tai nghe sẵn đều đòi bấm Xác nhận. **Chưa sửa** (P3 làm xong mà không đụng tới,
  vì đây là đường an toàn của P1F); vẫn đang làm mỗi buổi test máy thật tốn thêm 1 bước thủ công ⇒
  nên sửa ngay trước buổi test gộp (K34/K39/K41/K42).

### Thuộc P1G (code xong 2026-09-22 — chưa build/máy thật)

- [x] `lib/audio/emergency/` — `emergency_phrases.dart` (file cấu hình riêng, 3 câu prompt) +
  `emergency_phrase_service.dart` (`triggerEmergency()` xoay vòng, gọi thẳng `SafeTtsOutput`,
  đo `lastTriggerToSynthLatency`).
- [x] 8 unit test mới (130/130 pass) — gồm: 0 network/LLM (grep), không tai nghe ⇒ 0 gọi native
  speak + 1 rung, xoay vòng, failed không retry.
- [x] Nút tạm `Emergency Phrase (P1G)` + dòng `Emergency` trên màn hình chẩn đoán.
- [x] **Gesture thật đã có ở P3:** giữ nút nổi đúng 2 giây (`lib/ui/floating_button.dart`, có test đo mốc 2s).
- [ ] **Chạy trên máy thật:** phát được câu qua tai nghe + độ trễ đọc từ dòng Emergency; trigger khi
  KHÔNG tai nghe ⇒ im lặng + rung (chạy gộp với K34); rút tai nghe giữa lúc emergency đang đọc.

### Thuộc P2 (code xong 2026-09-22 — 161/161 test, chưa build/máy thật)

> Nợ **K39**. Cách test: lưu Groq API key vào `SecureStore`, bật app, bấm nút **"Xin gợi ý (P2)"**
> (nút này tự ghi mốc Push rồi xin gợi ý), xem dòng `Gợi ý (P2)` trên màn hình chẩn đoán +
> `adb logcat -v time -s Suggestion:V flutter:V`.

- [x] `lib/suggestion/` — 6 file: `suggestion_models.dart`, `llm_provider.dart`,
  `groq_llm_provider.dart`, `suggestion_policy.dart`, `suggestion_context_builder.dart`,
  `session_memory.dart` (+ `suggestion_service.dart` nối tầng UI — ngoài danh sách bàn giao của prompt).
- [x] **Prompt khung dùng NGUYÊN VĂN** — đối chiếu tự động từng dòng với `.plan/prompt_P2.md` mục 4:
  khớp đủ, không dòng nào thiếu/sửa; test `prompt khung NGUYÊN VĂN` khoá lại trong CI.
- [x] 29 unit test mới (161/161 pass): chặn `userSpeaking` (provider 0 lần gọi), debounce 1s,
  anti-repetition 2 phút, retry JSON lỗi đúng 1 lần, timeout/mất mạng KHÔNG retry, parse 2 dạng hợp lệ
  + code fence, Groq provider (endpoint/header/model/HTTP 500/offline/thiếu key/thiếu content),
  **envelope dị dạng ⇒ SuggestionException chứ không `TypeError`** (2 test regression cho H1/H2/H3 của
  đợt review — xem `.plan/P2-result.md` mục 9, bài học A50).
- [x] Cách ly: grep chứng minh `lib/suggestion/` không đụng audio, không key cứng, không import ngoài dự kiến.
- [ ] **DoD-1 — Push khi `notUserSpeaking` ⇒ gọi LLM, parse, hiện nudge hoặc không hiện gì** (máy thật).
- [ ] **DoD-2 — Push khi `userSpeaking` ⇒ KHÔNG có request nào gửi đi** (máy thật: log `Push bị chặn bởi
  policy: userSpeaking` + không có kết nối ra ngoài).
- [ ] **DoD-3 — anti-repetition:** bấm Push 2 lần trong 2 phút ⇒ lần 2 không trùng chủ đề/type (máy thật).
- [ ] **DoD-4 — timeout:** ngắt mạng, bấm Push ⇒ app không treo, `NO_SUGGESTION` sau ~4s (máy thật).
- [x] **DoD-5 — JSON lỗi** ⇒ app không crash (có unit test mock + 4 test regression cho H1/H2/H3; máy thật không cần lặp lại).
- [x] ~~**K40 — Offline Nudge Cache (mục 4.12)**~~ → **đóng ở P3** (72 câu asset + fallback chỉ-khi-LLM-lỗi, có đánh dấu nguồn).
- [ ] **DoD-1 nêu trên giờ có thêm điều kiện:** phải **nhập Groq API key** qua nút mới của P3 (trước đó không có chỗ ghi key ⇒ không thể có nudge thật).

### Thuộc P3 (code xong 2026-09-22 — 211/211 test, chưa build/máy thật)

> Nợ **K42**. Cách test: cài APK mới → nhập API key Groq → bấm **Xác nhận tai nghe** → chọn `Tai nghe (đọc)`
> → bấm/giữ nút nổi, xem dòng `Gợi ý (P3)` trên màn hình chẩn đoán +
> `adb logcat -v time -s Trigger:V NudgeDelivery:V OutputMode:V OfflineNudgeCache:V flutter:V`.

- [x] `lib/trigger/trigger_manager.dart` — **điểm vào DUY NHẤT** cho mọi nguồn (grep: 1 nơi gọi);
  mốc Push (P1E) ghi trước khi xin gợi ý; mốc lỗi KHÔNG chặn Push; không cooldown; không bao giờ ném.
- [x] `lib/ui/floating_button.dart` — tap = Push, giữ **đúng 2s** = Emergency (đi thẳng, không LLM/Policy).
- [x] `lib/audio/output_mode_selector.dart` + `nudge_delivery.dart` — 3 chế độ lưu bảng `meta`, Ear tự
  hạ xuống chữ khi thiếu tai nghe, rung lỗi ⇒ hạ xuống chữ, không bao giờ ném.
- [x] `assets/offline_nudge_cache.json` (72 câu = 12 × 6 type, mọi câu 2–4 từ) +
  `lib/suggestion/offline_nudge_cache.dart` (xoay vòng, tránh câu vừa hiện, không bao giờ ném).
- [x] 50 unit test mới: `floating_button_test` (9 — đo **đúng mốc 2 giây**), `trigger_manager_test` (16),
  `offline_nudge_cache_test` (13 — có test đọc thẳng file asset), `output_mode_selector_test` (11),
  +1 test chuẩn hoá tốc độ đọc trong `safe_tts_output_test.dart`.
- [x] Cách ly: grep vùng P3 không có network (client HTTP duy nhất vẫn là `groq_llm_provider.dart`).
- [x] Nút nhập **API key Groq** (điều kiện để DoD-1 chạy được trên máy; P2 chỉ có chỗ *đọc* key).
- [ ] **K42 (🔴) — DoD-1:** bấm nút nổi khi có mạng ⇒ nudge **thật** từ Groq, đọc qua tai nghe.
- [ ] **K42 (🔴) — DoD-2:** giữ nút **đúng 2 giây** trên máy ⇒ câu thoát hiểm (không phải Push);
  thả sớm ⇒ Push. (Test tự động đã đo mốc 2s; cần xác nhận cảm giác tay thật.)
- [ ] **K42 (🟠) — DoD-3:** đổi `Rung` ⇒ rung thật; `Chỉ hiện chữ` ⇒ im lặng tuyệt đối; `Tai nghe (đọc)`
  ⇒ nghe qua tai nghe; **rút tai nghe rồi bấm** ⇒ hạ xuống chữ, không gọi TTS.
- [ ] **K42 (🔴) — DoD-4:** **chế độ máy bay** + bấm nút nổi ⇒ nhận 1 nudge từ Offline Cache, có dòng
  `CACHE OFFLINE`, không im lặng hoàn toàn, không crash.
- [ ] **K43 (🟠) — trigger ngoài app** chưa có: volume key, nút tai nghe Bluetooth, notification action
  (lý do kỹ thuật + đường nối sẵn: `.plan/P3-result.md` mục "Sai khác" số 2).
- [ ] **K41 (🟠) — tốc độ đọc TTS** đã nối native (`setSpeechRate`) nhưng chưa verify trên máy.
- [ ] **K44 (🟡) — Offline Cache không theo chủ đề hội thoại** (câu chung); cần dùng thật rồi chốt ở P5.
- [ ] **K38 đóng:** gesture Emergency thật đã có (nút nổi giữ 2s); chỉ còn verify trên máy (K42).

### Thuộc P1B (DoD chưa xác minh — cần APK + máy thật)

- [ ] Nói to gần mic → `userSpeaking` trong <500ms (đo bằng giọng thật).
- [ ] Ngừng nói ~1–2s → về `notUserSpeaking`.
- [ ] Môi trường ồn nền (nhạc/TV) → không flicker liên tục.
- [ ] `Stream<ConversationState>` ổn định ≥30 phút chạy liên tục.
- [ ] In **timeline state thật** từ logcat và đối chiếu timeline tổng hợp trong `test/conversation_state_test.dart`.
- [ ] **Dependency JitPack (`android-vad:webrtc:2.0.10`) chưa resolve bằng build thật** (nợ K14).

### P4 — Full Pipeline Integration (half-duplex)

- [x] Tự kiểm Precondition → **KHÔNG ĐẠT** (9/10 phase trong chuỗi P1A→P3 chưa pass DoD riêng — `next.md` ghi rõ "Không có phase nào hoàn thành trọn vẹn"), đã dừng và hỏi thay vì tự quyết; user chọn **waive có ghi rủi ro** + chỉ làm **phần không phụ thuộc máy**.
- [x] `lib/services/conversation_session_controller.dart` — orchestrator **duy nhất**: mở (service → capture → VAD → ASR) và đóng đúng thứ tự ngược lại; UI không còn tự nối module.
- [x] **Half-duplex**: thêm `Stream<bool> SafeTtsOutput.speakingChanges` (không đổi logic an toàn P1F) + chặn chunk ASR trong lúc TTS phát, tự mở lại khi native báo `spoke`; đếm `chunksDroppedWhileSpeaking` / `asrResumeCount`.
- [x] Race **Push khi đang phát** ⇒ bỏ qua + thông báo (không cắt câu đang đọc giữa từ); **KHÔNG cooldown** (ràng buộc xuyên phase); **Emergency không bị chặn**.
- [x] Phục hồi từng module (prompt task 5): mic chết ⇒ dừng VAD/ASR/capture/service + thông báo; **cả 2 engine ASR fail** ⇒ phiên vẫn nghe, chỉ mất transcript; `feedAudioChunk` lỗi 3 lần liên tiếp ⇒ restart (tối đa 2/phiên) rồi hạ cấp; Trigger ném lỗi lạ ⇒ nuốt + thông báo.
- [x] Số liệu DoD hiện trên màn hình chẩn đoán (dòng `Phiên (P4)`): pha, chunk bị chặn, số lần ASR nhận lại, số Push bị bỏ qua, số lần phục hồi, độ trễ Push trung bình, mốc bắt đầu phiên.
- [x] Test: `test/conversation_session_controller_test.dart` — **25 test** (fake cả 7 module con); `flutter analyze` **sạch**; **236/236 test pass**.
- [x] Tự review: sửa **rò subscription** stream transcript của ASR (mỗi lần restart để lại một subscription sống) + **reset số đếm khi bắt đầu phiên mới** (nếu tích tụ thì số liệu mất giá trị làm bằng chứng); bỏ 1 getter không có caller (bài học A8).
- [ ] ⚠ **5/6 mục DoD chưa verify trên máy thật** (nợ **K46**): phiên hội thoại thật ≥ 30 phút không crash, xác nhận half-duplex bằng tai + `dumpsys audio`, đo pin/độ trễ thật, rút tai nghe giữa phiên thật, ngắt mạng giữa phiên.
- [x] Tìm ra lỗi native **K45** khi tự review: phát câu mới khi câu trước còn đang đọc ⇒ câu mới **im lặng** (field `tempWav` dùng chung giữa hai "thế hệ"). Ảnh hưởng trực tiếp **Emergency Phrase**. ✅ **Đã sửa ở tầng code** (theo yêu cầu user trong commit P4): tên file = hàm của số thế hệ (`wavFor`), `playSynthesized` giữ file của chính nó, `cleanTemp(file)` chỉ null field nếu còn trỏ đúng file, `onError` dùng `cleanTempOfGeneration` (call-site thứ hai cùng họ lỗi — A54).
- [x] Tự review lại bản sửa K45 (bước Code Review): **kiểm kê toàn bộ state dùng chung** của `SafeTtsEngine` (`generation`/`synthesizing`/`tempWav`/`track`/nhóm init) ⇒ tìm thêm **2 lỗi cùng họ** và đã sửa: (a) `onError`/`onStop` đặt `synthesizing = false` **không kiểm thế hệ** ⇒ `onStop` của thế hệ cũ (hệ quả mong đợi của chính `speak()` gọi `engine.stop()`) làm `onDone` của câu MỚI bị bỏ qua ⇒ câu mới im lặng; (b) `onEvent("error")` của thế hệ cũ báo về Dart ⇒ `_setSpeaking(false)` ⇒ **mở lại cửa ASR giữa lúc TTS đang đọc** (vi phạm half-duplex) + thông báo lỗi sai. Đã thêm `isCurrentGeneration()`/`handleSynthesisFailure()`, và `cleanTemp` nay so **đường dẫn** (`==`) thay vì đối tượng (`===`). `flutter analyze` sạch · 236/236 test pass.
- [ ] ⚠ 3 lỗi trên đều ở **native** — phần này **không có test harness** ở máy dev (không Android SDK) ⇒ phép thử nằm trong buổi test máy: bước 7 (nghe câu thoát hiểm khi đang đọc nudge) + xem số `chặn N chunk khi đang phát` **không tụt về 0** giữa lúc đang đọc.
- [ ] ⚠ **K45 chưa xác nhận hành vi trên máy thật**: CI đã biên dịch **XANH** (run `35808819851`, artifact `app-debug-apk`), nhưng vẫn phải nghe được câu thoát hiểm khi **giữ nút nổi 2 giây đúng lúc đang đọc nudge** và log không có `không có file WAV để phát` (bước 7 giáo trình test trong `.plan/P4-result.md`).

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
