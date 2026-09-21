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
- [ ] Có cho phép tôi tạo skill từ `LESSONS_LEARNED.md` trong `~/.agents/skills/` không? (Theo `writing-skills`, cần chạy baseline test trước.)
