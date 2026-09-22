# working.md — nhật ký đang làm

- [2026-09-21] **P1E — Transcript Store (code xong, 2/4 mục DoD đạt).** `lib/transcript/` (`transcript_segment.dart` **chỉ có text + timestamp**, `transcript_store.dart`) + `lib/services/storage/transcript_dao.dart` (interface + bản SQLite, cùng mẫu `ConfigStore` của P1D nên test được bằng DAO giả). **Schema SQLite lên v2** (3 bảng `transcript_sessions/segments/pushes` + 2 index) + nhánh migration `v1 → v2` cho máy đã cài P0.5 — DDL trong code được **kiểm thật bằng sqlite3 của Python** trên một DB v1 giả (bảng/index đúng, `meta` cũ còn nguyên). Ghi thẳng xuống đĩa từng dòng (không gom lô) ⇒ khôi phục được sau khi bị kill; cửa sổ RAM 8 phút, xoá dữ liệu cũ hơn 7 ngày ở `init()` (transaction 3 bảng). Nối vào app: `main()` init (recovery + cleanup không phụ thuộc thao tác người dùng) + `home_screen` attach/detach theo vòng đời ASR, thêm dòng "Transcript"/"Push gần nhất" và nút Push tạm để kiểm trên máy. **Bug tự phát hiện qua test:** `attach()` gọi `unawaited(detach())` ⇒ detach treo ở `await` rồi `_asrSub = null` đè lên subscription mới ⇒ **stream cũ vẫn ghi transcript** (họ lỗi race như F2/K23) — đã sửa (capture-trước-khi-xoá + huỷ trên biến cục bộ) + test regression. Cũng sửa: `init()` cache future hỏng ⇒ store chết vĩnh viễn nếu SQLite lỗi thoáng qua. Analyze sạch · **95/95 test** (16 mới). Nợ: K27 (đo crash/7 ngày trên máy thật), K28 (chốt có dùng SQLCipher mã hoá DB không).
- [2026-09-21] **CI `35675870025` (`bb436a3`) XANH** — icon launcher mới (adaptive icon + PNG legacy + `roundIcon`) build APK thành công ⇒ resource Android biên dịch được (đây là mục verify duy nhất cho thay đổi thuần resource; xem A32).
- [2026-09-21] **Launcher icon mới (concept user chốt: bong bóng hội thoại + sóng âm, tông teal).** Sinh bằng script tái tạo được `tools/make_app_icon.py` (Pillow, không sửa tay PNG) → **adaptive icon** `mipmap-anydpi-v26` (minSdk 26 ⇒ mọi máy đi nhánh này) + PNG legacy đủ 5 dpi + `android:roundIcon` trong manifest. **Lỗi tự phát hiện khi rà lại:** bản đầu vẽ luôn gradient vào layer `foreground` (đục) ⇒ launcher không áp được mặt nạ/parallax và `ic_launcher_background.png` thành file chết; đã sửa thành **foreground trong suốt** + background là layer riêng, xoá `values/ic_launcher_background.xml` không còn ai tham chiếu. Hình học kiểm bằng số: chóp đuôi cách tâm **30.2dp < 33dp** vùng an toàn (mặt nạ tròn không cắt đuôi). Ràng buộc + bảng màu ghi vào `.project/design-system.md`. Preview 4 ô: `icon_preview.png` (gitignore). analyze sạch · 79/79 test. Việc verify **thật** là build APK trên CI (local không có Android SDK) — bài học **A32**. Lỗi phụ: Flutter SDK local phải tải lại Dart SDK (233MB) do bị SIGTERM giữa chừng (A32).
- [2026-09-21] **Fix CI run `35618380022` (fail trên commit docs `c6a2979`).** Gốc: Gradle wrapper tải distribution `gradle-9.3.1-all.zip` nhận **HTTP 504** từ services.gradle.org — lỗi hạ tầng thoáng qua, KHÔNG phải code. Fix: retry 3 lần bước tải distribution trong workflow + đổi `-all` (341MB) → `-bin` (129MB). Dọn luôn 2 lỗi analyze của spike trên CI (`spikes/**` vào exclude — log CI sạch). Bài học **A31** (phân loại fail: hạ tầng vs code trước khi sửa). analyze sạch · 79/79 test.
- [2026-09-21] **Review P1D → sửa F1–F5 (`2c0ae82`, `e6f01ac`) → CI `35617319912` XANH.** F1/K22: nạp/giải phóng model chạy trên loader thread riêng (hết treo UI/ANR) — áp cho cả bridge P1C. F2/K23: generation token + worker giữ recognizer riêng. F3/K25: `initTimeout` (test 2 engine). F4/K26: flush `getFinalResult()` khi release + Dart gọi release trước khi đóng stream. F5/K24: xoá 3 getter chết. Lần push đầu fail 8 lỗi Kotlin (`No value passed for parameter 'messenger'` — tham số chết trong helper) → bài học **A30** + bỏ tham số chết. analyze sạch · **79/79 test**. Bài học mới A26–A30 + 4 quy tắc đã áp dụng trong skill. P1E **chưa viết code** (mới kiểm precondition + thu thập dữ kiện).

- [2026-09-21] **P1D code xong (`82f91d2` → CI run 35612601371): Vosk làm ASR dự phòng + `AsrEngineSelector`.** Dùng AAR chính chủ `com.alphacephei:vosk-android:0.3.75@aar` + `jna@aar` (KHÔNG dùng `vosk_flutter`: Dart <3 / kéo permission_handler ^13 → compileSdk 37 > AGP 9.1.0 max 36 — 3 bài học A20-A22). Model Vosk 32MB do CI tải + kiểm SHA256, đóng thành **Android asset** (không khai pubspec vì asset thiếu làm `flutter test` fail — A21). Config engine dùng lại bảng `meta` (không thêm dependency Dart). Nối ASR vào màn hình chính (chọn engine + số liệu so sánh). analyze sạch · **76/76 test**. Quyết định engine: **PhoWhisper mặc định (tạm thời)**, lý do + bảng so sánh ở `lib/audio/asr/README.md`. Báo cáo: `.plan/P1D-result.md`. Nợ: K19 (đo máy thật), K20 (JNA trên máy thật), K21 (APK +32MB/RAM model).
- [2026-09-21] **Run #7 (`10eeb5a`) XANH — whisper.cpp + JNI compile/link thành công (K17 đóng, K11 đóng hoàn toàn).** C1: sửa symbol JNI về `Java_com_aiassistant_phone_asr_AsrNative_*` (tôi từng viết sai `phone__asr` — sai `_` vẫn compile pass, chỉ lộ runtime; bài học A19 đã sửa lại trong skill). Commit `7ea1022` → **run #8** là APK để cài máy thật.
- [2026-09-21] **Run #5 fail ở CMake** (`DOWNLOAD_EXTRACT_TIMESTAMP` không hỗ trợ cmake 3.22.1 NDK). Fix + xử lý batch user giao: JNI symbol `_asr_` (lỗi runtime tiềm ẩn — package Kotlin là `…phone.asr`, không thêm thì UnsatisfiedLinkError dù compile pass), `pending` FloatArray? (đã xong `ee34224`), `AsrChannelBridge.unregister` đối xứng F1 (gọi ở `onEngineWillDestroy` + `cleanUpFlutterEngine`). Commit `6861515` + `10eeb5a` → **run #7** (`10eeb5a`) build cả 3 fix. Bài học A18/A19 vào skill.
- [2026-09-21] **Run #3 XANH (APK debug đầu tiên build thành công — K11 Kotlin đóng).** Run #4 (P1C) fail ở compile Kotlin: `pending: ShortArray?` sai kiểu — fix thành `FloatArray?` (commit `ee34224` → run #5), bài học A17 vào skill.
- [2026-09-21] **P1C code xong (user waive precondition) → run #4 (`f29bef5`, in_progress).** Interface `AsrEngine` đúng chữ ký prompt; `PhoWhisperAsrEngine` (accumulator 4s, không mất mẫu, drop-policy giữ chunk mới nhất); JNI/CMake port từ spike P0 (pin commit 307869a, symbol đổi package); model tiny q5_0 (29MB) vào assets; Kotlin bridge `AsrChannelBridge` đăng ký cả 2 engine. analyze sạch + **50/50 test** (11 mới). Đo máy thật GHI NỢ (K18); native lần đầu compile ở run #4 (K17). Báo cáo: `.plan/P1C-result.md`.
- [2026-09-21] **Fix CI run #2 fail → run #3 (`b5b0940`, in_progress).** Tin tốt: JitPack/K14 đã thông (resolve dependency không lỗi) và vòng compile Kotlin đầu tiên (K11) chạy tới — chỉ đúng **1 lỗi**: `MicCaptureEngine.kt:144 Unresolved reference '_config'` (chính tả string template, `$_config` → `$config`). Rà phòng ngừa `grep '\$_...'` toàn bộ Kotlin → sạch. Skill đã ghi bài học: run đầu sau khi qua compileSdk sẽ dồn lỗi Kotlin, đọc từng dòng `e:` trong log.
- [2026-09-21] **Fix CI run #1 fail → run #2.** Nguyên nhân: `permission_handler_android` 14.1.0 (do lock 13.0.2 kéo lên) đòi compileSdk 37 > max AGP 9.1.0 = 36 → fail `checkDebugAarMetadata` (không phải lỗi Kotlin của ta). Fix: pin `permission_handler: 12.0.1` → android 13.0.1 (compileSdk 35), analyze sạch + 41/41 test, commit `282b1a8` pushed, run #2 in_progress. Bài học compileSdk-plugin đã ghi vào skill. **Lưu ý Kotlin (K11) chưa được compile ở run #1** — fail sớm ở AAR metadata, vòng compile Kotlin chỉ chạy ở run #2 trở đi.
- [2026-09-21] **GH repo + CI build APK + skill.** Push commit đầu tiên `7c8f349` lên `main` (repo `hoangsoft90/ai_assistant_phone`, 155 file — đã loại `.plan/`, `.agents/`, `.freebuff/`, model spike). Workflow `build-debug-apk.yml` (gradlew trực tiếp, JDK17, Flutter 3.47.2, tự sinh `local.properties`, artifact 30 ngày) — run #1 đã **in_progress** sau push. Skill `.agents/skills/ai-assistant-phone-debug-apk/SKILL.md` (token + repo lưu tại đây, không hỏi lại; đã test load). Un-ignore `android/gradlew` + wrapper jar (trước đó bị gitignore ⇒ CI không có gradlew). Token KHÔNG vào bất kỳ file nào trong git (quét sạch; `.freebuff/` cũng đã untrack). **P1C tạm dừng ở precondition** (chưa code gì) — chờ quyết định go/no-go PhoWhisper từ user.
- [2026-09-21] **Regression F1 (user phát hiện):** `dispatchChunk` dùng `holder.sink` trên `EngineChannels` (không tồn tại → lỗi compile Kotlin, analyze Dart không bắt được vì K11). Đã sửa 2 chỗ → `pcmHolder.sink`, rà grep toàn file sạch, đối chiếu chéo kênh/payload Kotlin↔Dart, verify lại: analyze sạch + **41/41 test pass**. Bài học ghi ở `.plan/P1B-result.md` + `LESSONS_LEARNED.md`.
- [2026-09-21] **Review code P1B + sửa F1–F5 (bổ sung sau P1B).** Phát hiện 6 vấn đề (2 🔴); user duyệt: F2 = watchdog 1.5s (không reset tức thì), sửa F1/F3/F4/F5, F6 để sau. Kết quả: F1 unregister sạch theo engine (map theo messenger, nhớ messenger service trong MainActivity), F2 watchdog `inputStalled` (⚠ Timer phải hẹn ngay trong `_publish` lúc vào khoá — test bắt được bug này), F3 `frameMs` từ `VadDetector` qua `VadResult` (xoá hằng hardcode), F4 HomeScreen sống theo sự kiện (status/errors/stats + dispose), F5 assert theo mốc onset. Verify: analyze sạch, **41/41 test pass**. Kotlin vẫn chưa từng biên dịch (K11/K14). Chi tiết: `.plan/P1B-result.md` mục "Bổ sung sau review".
- [2026-09-21] **P1B (VAD + State tối giản) — CODE XONG, 0/4 mục DoD đạt (chưa đo được).**
  Precondition không đạt (P1A `0/5 mục DoD`, chưa có APK/thiết bị) → hỏi và được **waive**.
  - Đã làm: WebRTC VAD (`com.github.gkonovalov.android-vad:webrtc:2.0.10` qua JitPack) bọc trong
    `VadDetector.kt` (16kHz, khung 320 mẫu = 20ms, VERY_AGGRESSIVE); VAD chạy **trên thread thu**
    của P1A + kênh `com.aiassistant.phone/vad` (chỉ chạy khi có listener);
    `ConversationStateMachine` (Dart) với **đúng 2 state** + bộ tích luỹ rò (300ms/1500ms/ratio 0.5),
    `ValueNotifier` + `Stream changes/transitions` + `isUserSpeaking` cho P2, lịch sử trong phiên (≤500);
    dòng `Hội thoại` trên màn hình chẩn đoán.
  - **Giải quyết nợ K12**: không cần hạ `chunkMs` xuống 20–30ms — VAD tự chia khung 20ms ở native.
  - Kiểm chứng: `flutter analyze` **No issues found**; `flutter test` **38/38 pass** (17 test mới);
    **timeline hội thoại mẫu** in ra thật: `700ms: notUserSpeaking → userSpeaking` /
    `5900ms: userSpeaking → notUserSpeaking`; đối chiếu API thư viện VAD bằng source thật + artifact
    JitPack HTTP 200 trước khi pin version.
  - **Chưa verify**: phản hồi <500ms với giọng thật, ngừng nói 1–2s, không flicker khi có nhạc/TV,
    chạy 30 phút. **Mã Kotlin + dependency JitPack chưa từng được biên dịch** (nợ K14 🔴). Chưa commit.
  - Báo cáo: **`.plan/P1B-result.md`**. Tài liệu module: `.project/modules/conversation-state.md`.

- [2026-09-21] **P1A (Audio Capture Foundation, mic-only) — CODE XONG, 0/5 mục DoD đạt (chưa đo được).**
  Precondition không đạt (P0.5 chưa verify, chưa có kết luận A2DP) → hỏi và được **waive**.
  - Đã làm: `MicCaptureEngine` (Kotlin, `AudioRecord` + `AudioSource.MIC`, 16kHz mono PCM16, thread
    `URGENT_AUDIO`), `CaptureChannelBridge` (kênh control + pcm, **1 engine dùng chung, sink riêng
    từng FlutterEngine**), `AudioCaptureController` (Dart facade, broadcast stream), interface
    `AudioCaptureEngine`/`CaptureClient`, `WavSink` (kiểm thử thủ công), UI bật/tắt capture kèm
    rollback service khi mic lỗi. Capture chạy trong process do foreground service giữ; kênh **đã**
    đăng ký cho engine của service qua `ForegroundService.addTaskLifecycleListener` để P1B dùng.
  - Kiểm chứng: `flutter analyze` **No issues found**; `flutter test` **21/21 pass** (20 test mới:
    lifecycle, chunk ngoài cửa sổ bị bỏ, map lỗi, onError 1-handler, dispose, hợp đồng kênh thật).
  - Tự review Kotlin tìm & **sửa 2 lỗi thật**: `stop()` join chính thread đọc (treo 1.5s vô ích),
    và `onCancel` xoá chung set sink làm mất listener của engine kia.
  - **Chưa verify**: 60 phút nền, `dumpsys audio` HFP/SCO, rút tai nghe, nghe lại `.wav`, luồng từ
    chối quyền trên UI — đều cần APK + máy thật. **Mã Kotlin chưa từng được biên dịch.** Chưa commit.
  - Báo cáo: **`.plan/P1A-result.md`**. Tài liệu module: `.project/modules/audio-capture.md`.

- [2026-09-21] Viết **baseline spec OpenSpec** cho toàn bộ code hiện có (theo yêu cầu user: chỉ viết
  tài liệu, KHÔNG sửa code): 7 spec trong `openspec/specs/` — `app-bootstrap`,
  `listening-foreground-service`, `runtime-permissions`, `audio-session-config`, `app-storage`,
  `diagnostics-home-screen`, `app-core` (gộp logging+constants+smoke-test theo xác nhận của user).
  Mỗi spec: Purpose + Requirements (PHẢI/MUST) + Scenario Given/When/Then kèm `file:line` + mục
  **Cần làm rõ** (hành vi mơ hồ/dead code — không tự sửa). `openspec validate --specs` → **7 passed,
  0 failed, 0 warning**. Đã chứng minh code nguyên vẹn: `flutter analyze` *No issues* + `flutter test`
  *All tests passed* ngay sau khi viết spec. Tool MCP không có trong phiên ⇒ khảo sát bằng cách đọc
  trực tiếp toàn bộ 10 file Dart/Kotlin (repo còn nhỏ) — thay thế tương đương về độ chính xác.

- [2026-09-21] Tạo **knowledge base `.project/`** (13 file: README, overview, architecture, state-routing,
  patterns, design-system, integrations, openspec, modules/{README + 4 module thực có}) + bộ file memory
  ở gốc: `context.md`, `operating_rules.md`, `CLAUDE.md` (mới), và **điền phần `PROJECT` trong `AGENTS.md`**
  (Role & Context / Navigation / 12 Critical Rules / Workflow / git convention — hết placeholder).
  - Ghi rõ trạng thái thật: **chưa có tính năng sản phẩm nào**, không auth/backend/payment; APK chưa
    từng build; repo **0 commit**. Nợ kỹ thuật K1–K10 nằm ở `.project/openspec.md` mục 3.
  - Đã kiểm: 60 file `.md` → **0 link nội bộ hỏng**; `.project/` **không** bị gitignore.
  - `openspec update` → *All 3 tool(s) up to date (v1.13.1)*, không drift; vẫn **0 change** đang mở.
  - Hạ tầng phiên: AgentMemory (`localhost:3111/health`) **không phản hồi** ⇒ không lưu memory/ADR được
    (không tự khởi động lại dịch vụ).

- [2026-09-21] **P0.5 (Project Bootstrap) — XONG PHẦN LÀM ĐƯỢC, 2/5 mục DoD đạt, 3 mục còn lại chưa kiểm được.**
  - **Precondition của P0.5 KHÔNG đạt** (P0 chưa có kết luận go/no-go; chưa biết A2DP hay HFP) → đã tự kiểm
    bằng bằng chứng và báo mâu thuẫn; **chủ dự án chọn "waive precondition"** ⇒ rủi ro đã ghi rõ trong báo cáo.
  - Đã làm: `flutter create` thật ở gốc repo (`com.aiassistant.phone`, minSdk 26, Android only); cấu trúc
    `lib/{core,audio,transcript,suggestion,trigger,ui,services}` + README từng thư mục; manifest 7 quyền;
    foreground service skeleton (`flutter_foreground_task` **11.0.3** — API khác hẳn bản prompt mô tả);
    `audio_session` 0.2.4 (`usage=media`, cố ý không `voiceCommunication`) + lắng nghe `becomingNoisy`;
    SQLite (sqflite) + secure storage cho API key; màn hình chính tối thiểu Sẵn sàng/Đang lắng nghe; lint 8 rule bổ sung.
  - Kiểm thử thật: `flutter analyze` → *No issues found*; `flutter test` → *All tests passed*;
    đọc trực tiếp source trong `~/.pub-cache` để đối chiếu API trước khi viết code.
  - **Chưa kiểm được** (nên 3 mục DoD chưa tick): app build/cài chạy thật, FGS chạy nền không crash,
    manifest build không lỗi — máy dev thiếu Android SDK, chưa có thiết bị. **Chưa commit** (repo vẫn 0 commit).
  - Báo cáo: **`.plan/P0_5-result.md`**. Chi tiết build/chạy: `README.md` gốc repo.
- [2026-09-21] **P0 (Audio Feasibility Spike) — CHƯA HOÀN THÀNH, dừng ở Precondition.**
  - Lý do: P0 yêu cầu 1 điện thoại Android thật + 1 tai nghe Bluetooth + USB debug; máy dev hiện
    `adb devices` rỗng, không có thiết bị nào. Toàn bộ 5 mục Definition of Done của P0 là đo đạc
    trên máy thật nên chưa mục nào được tính là đạt.
  - Đã làm phần không cần thiết bị: convert + quantize PhoWhisper base/tiny sang GGML q5_0,
    tải model Vosk tiếng Việt (small + bản lớn), viết tooling (`spikes/p0_audio/tools/`), đo baseline
    trên host bằng FLEURS có ground-truth, viết code app spike (Flutter + Kotlin + JNI whisper.cpp).
  - Phát hiện đáng chú ý: Vosk model nhỏ trả về RỖNG khi audio nhỏ tiếng (đúng tình huống mic để xa);
    quantize q5_0 gần như không mất chất lượng; PhoWhisper thắng Vosk rõ rệt (12-16% vs 40-53% WER).
  - Báo cáo theo định dạng mục 5 của AGENT_INSTRUCTIONS.md: **`.plan/P0-result.md`** (quy ước: mỗi phase 1 file `<PHASE>-result.md`).
  - Chi tiết + protocol test on-device: `spikes/p0_audio/README.md`.
  - Chờ người dùng cắm điện thoại; sau đó chạy Task 1-4 của `prompt_P0.md` rồi mới có kết luận go/no-go.
- [2026-09-21] Bổ sung bộ tài liệu điều phối ở gốc repo: `checklist.md` (đã/chưa/cần làm/cần hỏi),
  `features.md` (tính năng hiện tại & tương lai), `next.md` (roadmap + việc sắp tới), `faq.md`
  (thắc mắc/hiểu sai), `result_20260921-1517.txt` (kết quả phiên), `handoff_20260921-1517.md`
  (bàn giao phiên sau — viết thủ công vì skill `handoff` chỉ user gọi được), `LESSONS_LEARNED.md`
  (14 lỗi thật đã mắc + quy tắc chống tái phạm). Điền context dự án cho `openspec/config.yaml`
  và chạy `openspec update` (v1.13.1, không drift).
- [2026-09-21] Ghi chú hạ tầng: AgentMemory (`localhost:3111`) không phản hồi trong phiên này nên
  không lưu được memory; `context.md` / `operating_rules.md` chưa tồn tại (nên tạo ở P0.5 khi có
  khung app thật). OCR (`ocr` CLI) chưa được cài trên máy → bước review dùng cách đọc thủ công.
- [2026-09-22] **Verify P1E trên máy thật** qua adb (Pixel 3a / Android 12 / arm64, APK `9f4508e`):
  K27a–d **đạt** — transcript thật vào SQLite, crash recovery giữ đúng phiên cũ, phiên 8 ngày bị xoá cả
  dòng + mốc Push, và **migration v1→v2 chạy thật** (3 bảng + 2 index, dữ liệu `meta` cũ nguyên vẹn).
  DoD-4 (bấm nút Push) chưa kiểm — máy đang dùng, không tap bừa.
- [2026-09-22] **Phát hiện K29 (🔴) — ASR không đạt realtime** (1 chunk 4s ≈ 160s, RTF ≈ 39, 59 chunk bị
  bỏ): 4 nguyên nhân cộng dồn — `threads=2`/8 nhân; native build **variant Debug** (không set
  `CMAKE_BUILD_TYPE`, host P0 build Release); `GGML_NATIVE=OFF` không kèm `-march` (mất dotprod/fp16);
  chunk 4s bị pad ~30s bởi whisper. Thêm **K30** `abiFilters` vô hiệu (APK **155MB / 3 ABI**), **K31**
  `libjnidispatch.so` có trong APK ✅ (runtime chưa test), **K32** RAM chưa đo.
  Đã ghi bài học **A36–A40** + thứ tự sửa đề xuất vào `.plan/P1E-result.md`.
- [2026-09-22] **Sửa K29a+b+c + K30** (user duyệt) — commit `2ecdd3b`: `threads` mặc định = tự động
  `min(4, số nhân)` (+2 test khoá); `add_compile_options(-O3)` đặt trước `FetchContent_MakeAvailable`
  (cờ thư mục/target chèn sau cờ build type ⇒ mới thắng `-O0` của variant Debug);
  `-march=armv8.2-a+dotprod+fp16` cho arm64-v8a; `disable-abi-filtering=true` để plugin Flutter không
  ghi đè `abiFilters`. Thêm bước CI in `CMakeCache` + `compile_commands` + ABI thật trong APK.
  Verify local: `flutter analyze` sạch · **97/97 test**. Chờ CI xanh → cài APK mới → đo lại RTF (K29).
