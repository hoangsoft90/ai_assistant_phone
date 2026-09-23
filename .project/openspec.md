# openspec.md — Tiến độ, bug, todo (góc nhìn OpenSpec)

Cập nhật: 2026-09-23 (+07, sau P4).

> **Nguồn sự thật về nợ/DoD là `checklist.md`** — bảng ở mục 3 đây chỉ giữ các mục cũ + mục đang mở
> mức cao; K17–K26 đã đóng và một số dòng cũ đã được dọn.

## 1. Trạng thái OpenSpec

| Hạng mục | Giá trị |
|---|---|
| CLI | `openspec` **1.13.1** |
| Tool đã cài (adapter) | `antigravity`, `claude`, `opencode` — tất cả up to date, **không drift** |
| Profile | 6 workflow đang bật |
| **Changes đang mở** | **KHÔNG CÓ** (`openspec list` → *No active changes*) |
| **Specs đã chốt** | **KHÔNG CÓ** (`openspec/specs/` chỉ có `.gitkeep`) |
| `openspec/config.yaml` | ✅ đã điền `context` (tech stack + 5 ràng buộc cứng + quy ước tên) và `rules` cho `proposal`/`tasks`; đã parse lại bằng `yaml.safe_load` → hợp lệ |

**Vì sao chưa có change nào:** P0 là spike thăm dò (không thay đổi schema/API), P0.5 là bootstrap khung.
Theo quy ước, change đầu tiên nên được tạo **trước khi code** ở phase thay đổi kiến trúc thật —
dự kiến là P1A/P1B.

**Việc cần làm khi tạo change đầu tiên:**
1. Chạy `openspec` theo workflow đang có (không tự chế quy trình).
2. **Tên change không được bắt đầu bằng chữ số** (xem `AGENTS.md` + `openspec/config.yaml`).
3. Đọc `rules` trong `openspec/config.yaml` trước khi viết `proposal.md`/`tasks.md`.

## 2. Phase: đã xong / đang làm / pending

> Nguồn đầy đủ: `next.md`. Ở đây chỉ ghi trạng thái OpenSpec-hoá.

| Phase | Nội dung | Trạng thái |
|---|---|---|
| **P0** | Audio Feasibility Spike (đo trên máy thật) | 🟡 **dở dang, chặn ở thiết bị** — xong phần không cần thiết bị; **0/5 mục DoD đạt** |
| **P0.5** | Project Bootstrap | 🟡 **xong phần làm được; 2/5 mục DoD đạt**, 3 mục còn lại chưa xác minh (cần build + máy thật) |
| **P1A** | Audio Capture Foundation (mic-only) | 🟡 code xong (5 file Dart + 2 file Kotlin, 21 test pass) — **0/5 mục DoD** vì chưa build/đo trên máy |
| **P1B** | VAD + State tối giản | 🟡 code xong (3 file Dart + 1 file Kotlin, 38 test pass) — **0/4 mục DoD** vì chưa build/đo trên máy |
| P1C | ASR PhoWhisper (chính) | 🟡 code xong + native compile XANH (CI run #7); 0/4 DoD máy thật — nợ K18 |
| P1D | ASR Vosk (dự phòng) + abstraction | 🟡 code xong (`82f91d2`), CI XANH (run 35612601371); 2/4 DoD đạt — nợ K19/K20/K21 |
| P1E | Transcript Store | 🟡 **code xong** (2/4 DoD đạt) — SQLite **v2 + migration** (3 bảng transcript), rolling 8 phút trong RAM, xoá sau 7 ngày, khôi phục phiên sau khi bị kill, API text thô không nhãn cho P2. Nợ K27 (đo máy thật), K28 (mã hoá DB?) |
| P1F | TTS Output Safety Layer (A2DP-only) | 🟡 **code xong + test MỘT PHẦN trên máy thật** (2026-09-22: phát đầu-cuối ✅, mất-tai-nghe+rung ✅ — `.plan/P1F-result.md`); còn rút-mid/TC2/TC3 — nợ K34 (thu hẹp), **K37 mới** |
| P1G | Emergency Phrase (local) | 🟡 **code xong** (`lib/audio/emergency/`, 8 test mới — 130/130 pass, analyze sạch); chưa build/máy thật — xem `.plan/P1G-result.md` |
| P2 | Suggestion Engine (LLM + Policy) | 🟡 **code xong** (`lib/suggestion/`, 29 test mới — 161/161 pass, analyze sạch); **prompt khung nguyên văn** đã đối chiếu từng dòng với `.plan/prompt_P2.md`; review lần 2 tìm + sửa **3 lỗi High** (bài học A50); chưa test máy thật — nợ **K39**, **K40** |
| P3 | Trigger Abstraction + Output Modes + Offline Nudge Cache | 🟡 **code xong** (`lib/trigger/`, `lib/ui/floating_button.dart`, `output_mode_selector.dart`, `nudge_delivery.dart`, asset cache — 50 test mới: **211/211 pass**, analyze sạch); 6 lỗi + 2 thứ thừa (Ponytail) tự tìm khi review đã xử lý; chưa test máy thật — nợ **K41/K42/K43/K44**, đóng **K38/K40** |
| P4 | Full Pipeline Integration (half-duplex) | 🟡 **code xong phần không phụ thuộc máy** (`lib/services/conversation_session_controller.dart` + `SafeTtsOutput.speakingChanges` — 25 test mới: **236/236 pass**, analyze sạch); Precondition **không đạt**, user waive có ghi rủi ro; phát hiện + **sửa** lỗi native **K45** (chờ xác nhận hành vi trên máy); chưa test máy thật — nợ **K46**, đóng **K35** |
| P4 | Full Pipeline Integration (half-duplex) | ⬜ |
| P5 | Pre-Brief + Post-Review + Coaching + Training Level | ⬜ |
| P6 | Semi-auto Mode (tuỳ chọn) | ⬜ — cần dùng thực địa ≥2 tuần |
| P7 | Production Hardening & Release | ⬜ |

Ước tính còn lại tới lúc dùng được (bỏ P6): **~9–11 tuần** (theo `production_roadmap.md`).

## 3. Bug đã biết

**Chưa có bug nào được filed** — app **chưa từng chạy trên thiết bị**, nên chưa có bug runtime nào
được phát hiện. Danh sách dưới đây là **vấn đề/nợ kỹ thuật đã biết** (khác với bug đã quan sát):

| # | Vấn đề | Mức | Nguồn |
|---|---|---|---|
| K1 | **Ràng buộc "không lọt tiếng ra loa ngoài" CHƯA được kiểm chứng** trên Android thật (Task 3 của P0 chưa chạy) | 🔴 cao (an toàn) | `.plan/P0-result.md` |
| K2 | **Chưa biết TTS qua tai nghe giữ A2DP hay bị ép HFP** (Task 2 của P0 chưa chạy) ⇒ cấu hình `audio_session` hiện chỉ là mức khung, có thể phải sửa | 🔴 cao | `lib/audio/app_audio_session.dart`, `.plan/P0-result.md` |
| K3 | **Chưa chốt ASR mặc định** (PhoWhisper hay Vosk) — nợ kỹ thuật treo từ P0 | 🟠 vừa | `next.md`, `.plan/P0-result.md` |
| K4 | **APK chưa từng được build** ⇒ Gradle/AGP 9.1/Kotlin 2.4.0/plugin chưa biên dịch lần nào | 🟠 vừa | `.plan/P0_5-result.md` |
| K5 | **Vosk trả về RỖNG với audio nhỏ tiếng** — cần AGC/kiểm soát gain ở P1A nếu chọn Vosk | 🟠 vừa | `spikes/p0_audio/reports/*.json` |
| K6 | **Code spike còn sót `TtsTest` phát trực tiếp** — không được tái sử dụng; prompt P0.5 nói phải "thay thế hoàn toàn" code thăm dò | 🟠 vừa (an toàn) | `spikes/p0_audio/`, `checklist.md` |
| K7 | **Chưa có state management** ⇒ mốc bắt buộc chốt trước P1B | 🟡 thấp | [state-routing.md](state-routing.md) |
| K8 | **Chưa có CI/CD, chưa có keystore release** | 🟡 thấp | [integrations.md](integrations.md) |
| K9 | **Design system chưa có** + vài giá trị màu/chữ hardcode trong `home_screen.dart` | 🟡 thấp | [design-system.md](design-system.md) |
| K10 | **`/home` chỉ còn ~396MB** — chưa đủ chỗ build Gradle tại máy dev | 🟡 thấp | `.plan/P0_5-result.md` |
| K11 | **Mã Kotlin của P1A chưa từng được biên dịch** — chỉ review thủ công + kiểm ngoặc + đối chiếu API plugin | 🔴 cao | `.plan/P1A-result.md` mục Sai khác 8 |
| ~~K12~~ | ~~`chunkMs=100` chưa đối chiếu ngưỡng VAD~~ → **đã giải quyết ở P1B**: VAD chia khung 20ms ngay ở native, không cần hạ `chunkMs` của luồng PCM | ✅ xong | `.plan/P1B-result.md` mục Sai khác 1 |
| K14 | **Dependency JitPack (`android-vad:webrtc:2.0.10`) + toàn bộ mã Kotlin P1B chưa từng được biên dịch** — chỉ kiểm bằng đọc source + HTTP 200 của artifact | 🔴 cao | `.plan/P1B-result.md` mục Sai khác 6 |
| K15 | **3 ngưỡng VAD (300ms/1500ms/ratio 0.5) chưa tinh chỉnh bằng giọng nói thật** — mới là giá trị khởi đầu có lý giải | 🟠 vừa | `.project/modules/conversation-state.md` mục 4 |
| K16 | **VAD chạy cùng thread thu** với việc copy chunk cho Dart — chưa xác nhận không gây drop mẫu khi CPU bận | 🟡 thấp | `.plan/P1B-result.md` mục Đề xuất |
| K13 | **`permanentlyDenied` chưa có đường thoát** trong app (không `openAppSettings()`); P1A mới hiện hướng dẫn bằng chữ | 🟠 vừa | `.project/modules/audio-capture.md` mục 7 |
| ~~K17, K22–K26~~ | ~~compile native lần đầu (K17) + 5 finding review P1D (K22 main-thread, K23 generation token, K24 getter chết, K25 thiếu timeout, K26 mất câu cuối)~~ → **đã đóng**: CI run #7 (native xanh) + commit `2c0ae82`/`e6f01ac` (CI `35617319912` xanh) | ✅ xong | `checklist.md` |
| K18–K21 | **P1C/P1D chưa đo trên máy thật** (trễ chunk, pin 45′, JNA `libjnidispatch.so`, RAM/kích thước model, bảng so sánh 2 engine) | 🔴 cao | `lib/audio/asr/README.md`, `checklist.md` |
| **K27** | **P1E: crash recovery + hạn 7 ngày + migration v1→v2 CHƯA chạy trên máy thật** — unit test chỉ chứng minh logic; SQL mới kiểm bằng sqlite3 offline | 🔴 cao | `.plan/P1E-result.md`, `lib/transcript/README.md` mục 5 |
| **K28** | **Transcript chưa được mã hoá**: `sqflite` không hỗ trợ, muốn mã hoá phải đổi sang `sqflite_sqlcipher` (+ chuyển dữ liệu cũ). Hiện dựa vào sandbox app + xoá sau 7 ngày | 🟠 vừa | `lib/transcript/README.md` mục 4 |
| **K34** | **P1F: 3 test case bắt buộc (rút tai nghe giữa lúc đọc / rút trước khi đọc / tắt kết nối khi đang đọc) CHƯA chạy trên máy thật** — unit test chỉ khoá logic Dart, không chứng minh được "không lọt ra loa ngoài". Đây là phase an toàn quan trọng nhất của app nên **không được** coi là xong | 🔴 cao | `.plan/P1F-result.md`, `.project/modules/tts-safety.md` mục 6 |
| **K35** | **Half-duplex chưa nối** (đang thu thì không phát TTS và ngược lại) — ràng buộc #5 của `overview.md`; `SafeTtsOutput` không giữ tham chiếu tới tầng capture. Việc ghép là P4 | 🟠 vừa | `.project/modules/tts-safety.md` mục 7 |
| **K36** | **Giới hạn nhận dạng thiết bị + engine TTS**: (a) không phân biệt được tai nghe A2DP với loa Bluetooth A2DP (cùng `TYPE_BLUETOOTH_A2DP`) ⇒ loa BT cũng bị coi là "riêng tư"; (b) kênh TTS chỉ đăng ký cho engine UI nên chưa phát được khi app ở nền (P3/P4 cần) | 🟡 thấp | `.project/modules/tts-safety.md` mục 7 |
| **K37** | **F-P1F-1 — đòi xác nhận sai:** callback đầu của `registerAudioDeviceCallback` (baseline khi đăng ký) bị Dart phân loại thành "kết nối lại" ⇒ **mỗi lần mở app có tai nghe cắm sẵn đều phải bấm "Xác nhận tai nghe" trước khi đọc được**. Fail-closed (an toàn) nhưng phiền; sửa = phân biệt baseline với reconnect thật | 🟠 vừa | `.plan/P1F-result.md` mục "Cập nhật sau buổi test qua adb" |
| ~~K38~~ | ~~Emergency Phrase chưa có gesture thật~~ → **đóng ở P3**: nút nổi giữ **đúng 2 giây** (`lib/ui/floating_button.dart`, test đo mốc 2s); chỉ còn verify trên máy (K42) | ✅ xong | `.plan/P3-result.md` |
| **K39** | **P2: 5 mục DoD chưa verify trên máy thật** — cần APK mới + **Groq API key lưu qua `SecureStore`**. ⚠️ P3 đã thêm **nút nhập key ngay trong app** (trước đó không có chỗ ghi key ⇒ DoD-1 bất khả thi trên máy). Cụ thể: (a) Push khi `notUserSpeaking` ⇒ nudge hiện trên UI; (b) Push khi `userSpeaking` ⇒ **không request nào đi** (kiểm bằng logcat + `dumpsys`); (c) anti-repetition 2 lần trong 2 phút; (d) ngắt mạng ⇒ `NO_SUGGESTION` sau ~4s, không treo; (e) JSON lỗi ⇒ không crash. | 🔴 cao (chặn chất lượng P2) | `.plan/P2-result.md` |
| ~~K40~~ | ~~P2: chưa có Offline Nudge Cache (mục 4.12)~~ → **đóng ở P3**: 72 câu asset (`assets/offline_nudge_cache.json`), fallback **chỉ** khi không dùng được LLM, có đánh dấu nguồn `NudgeSource.cache` | ✅ xong | `.plan/P3-result.md` |
| **K41** | **Tốc độ đọc TTS chưa verify trên máy** — `setSpeechRate` đã nối tới native (0.9–1.2x, mặc định 1.05x, kẹp ở 2 tầng) nhưng chưa xác nhận giọng đọc thật sự đổi. Lưu ý `setSpeechRate` là **cấu hình dính**: đường Emergency (`rate=null`) giữ tốc độ của lần đọc trước đó | 🟠 vừa | `.plan/P3-result.md` |
| **K42** | **P3: 4 mục DoD chưa verify trên máy thật** — (a) nudge **thật** từ Groq qua nút nổi; (b) giữ đúng 2s trên máy ⇒ Emergency, thả sớm ⇒ Push; (c) cả 3 chế độ (rung thật / im lặng tuyệt đối / đọc qua tai nghe) + tốc độ 0,9x–1,2x nghe khác nhau; (d) **chế độ máy bay** ⇒ nudge từ Offline Cache (dòng `CACHE OFFLINE`). Unit test đã khoá logic (kể cả mốc 2 giây) nhưng không thay được cảm nhận/rung/âm thanh thật | 🔴 cao | `.plan/P3-result.md`, `.plan/prompt_P3.md` |
| **K43** | **Trigger ngoài app chưa có**: volume key (cần override Activity; nếu vội ⇒ mỗi lần chỉnh âm lượng sẽ gọi LLM), nút tai nghe Bluetooth (`MediaSession`/`MediaButtonReceiver` + phát từ tiến trình nền ⇒ vướng K36), notification action (Kotlin `ListeningService` + gọi ngược vào Dart khi app ở nền). Đường nối đã sẵn: `SuggestTriggerSource` + **một** hàm `TriggerManager.onSuggestRequested` | 🟠 vừa | `.plan/P3-result.md` mục "Sai khác" 2 |
| **K45** | **LỖI NATIVE (P4 phát hiện — ĐÃ SỬA ở tầng code, chờ xác nhận trên máy): phát câu mới khi câu trước còn đang đọc ⇒ câu mới IM LẶNG.** `SafeTtsBridge` giữ **một field** `tempWav` cho file WAV của lần phát hiện tại, trong khi file đặt tên theo *thế hệ* và mọi lần phát chạy trên cùng thread ⇒ `generation++` làm vòng lặp lần CŨ thoát ngay, `finally { cleanTemp() }` của nó xoá `tempWav` = **file của câu MỚI** ⇒ lần phát mới thấy `tempWav == null` và không phát gì (`không có file WAV để phát`). TTS tổng hợp lâu hơn thời gian thread cũ thoát ⇒ gần như **tất định**. **Ảnh hưởng: Emergency Phrase (câu thoát hiểm) khi đang đọc nudge có thể không kêu.** `ConversationSessionController.push()` bỏ qua Push khi đang phát nên đường Push không vào ca này, nhưng Emergency **cố ý không bị chặn**. **Đã sửa trong commit P4** (user chốt "sửa luôn"): `wavFor(gen)` là nguồn duy nhất cho đường dẫn/tên file, `playSynthesized` giữ file của CHÍNH lần chạy rồi `cleanTemp(wav)`, `cleanTemp(file)` chỉ null field nếu `tempWav === file`, `onError` suy thế hệ từ `utteranceId` (`cleanTempOfGeneration` — **call-site thứ hai cùng họ lỗi**, xem A54). Còn lại: **nghe được câu thoát hiểm khi đang đọc nudge** trên máy thật (bước 7 `.plan/P4-result.md`) | 🟠 vừa | `.project/modules/tts-safety.md` mục 7, `.plan/P4-result.md` |
| **K46** | **P4: 5/6 mục DoD chưa verify trên máy thật** — (a) phiên hội thoại thật ≥ 30 phút không crash; (b) half-duplex đúng (ASR không bắt nhầm giọng TTS — cần tai + `dumpsys audio` + số trên dòng `Phiên (P4)`); (c) đo pin/giờ + độ trễ Push trung bình; (d) rút tai nghe giữa phiên thật; (e) tắt mạng giữa phiên ⇒ phần còn lại vẫn chạy. Unit test đã khoá logic nhưng không thay được phiên thật | 🔴 cao | `.plan/P4-result.md` mục DoD |
| **K44** | **Offline Nudge Cache không theo chủ đề hội thoại** — câu trong cache là câu chung (khi LLM không trả về thì ta không biết nội dung để chọn theo chủ đề). Nếu dùng thật thấy vô dụng thì chốt lại ở P5 | 🟡 thấp | `.plan/P3-result.md` |

## 4. Todo ngay tiếp theo (thứ tự)

1. **Tải APK debug mới nhất từ CI → cài máy thật → chạy 1 vòng protocol đo** cho **tất cả** phase
   đang nợ: **P4 (K46 — cần phiên thật ≥30′, nên đây là lượt test quan trọng nhất)**, **P3 (K42/K41)**, **P2 (K39)**, **P1F (3 test case TTS, K34)**, P0 Task 2/3 (K2), P1E (`am kill` + đổi ngày 8 ngày), P1D (2 engine, 45′), P1B (ngưỡng VAD bằng giọng thật),
   P1A/P0.5 (quyền, FGS, DB, `becomingNoisy`), P0 (A2DP/HFP). Đây là điểm chặn chất lượng của 6 phase.
   Giáo trình gộp một lượt ~45′ nằm ở `next.md` mục "Buổi test máy thật sắp tới".
   Làm **K37** (đòi xác nhận mỗi lần mở app) trước buổi test cho đỡ tốn thao tác tay.
2. Vá ngưỡng/logic theo số liệu máy thật (VAD K15, engine mặc định K3/K18, Vosk K20/K21).
2b. **K43** — trigger ngoài app (thông báo → volume key → nút tai nghe BT); bắt đầu từ notification
   action, sau khi P4 có engine nền (K36).
3. Chốt **K28** (có mã hoá DB transcript không) trước khi phát hành cho người khác dùng.
4. Quyết định số phận `spikes/p0_audio/` (**K6**).
5. Cân nhắc tạo OpenSpec change chính thức cho các capability đã code (baseline specs hiện chỉ có từ
   P0.5 — `openspec/specs/` thiếu P1A–P1E; xem mục 1 và `checklist.md`).

## 5. Việc cần hỏi người dùng (đang treo)

- [ ] Repo GitHub nào + có dựng workflow build APK ngay không?
- [ ] Có commit phần P0 + P0.5 hiện tại không? (repo **0 commit** — xem mục 6)
- [ ] Xoá hay giữ `spikes/p0_audio/`?
- [ ] Cho phép xoá model f16/vosk-bản-lớn trong `/tmp/p0spike` để lấy chỗ build?
- [ ] `.plan/` bị gitignore → có copy báo cáo phase sang thư mục được commit không?
- [ ] **K28:** transcript có cần DB mã hoá (SQLCipher) không?
- [ ] Cho phép tạo skill từ `LESSONS_LEARNED.md` không?

## 6. Trạng thái git

- Repo **đã có lịch sử commit** trên `main` (`hoangsoft90/ai_assistant_phone`), mỗi phase một vài commit;
  `git diff`/impact review dùng được bình thường.
- **Đường build duy nhất = GitHub Actions** (`.github/workflows/build-debug-apk.yml`, gradlew trực tiếp).
  Tuyệt đối **không build APK trên máy dev** (đĩa `/home` chật, không có Android SDK) — quy tắc này
  nằm trong `.agents/skills/ai-assistant-phone-debug-apk/SKILL.md`.
- `.plan/` **bị gitignore** (prompt nội bộ) ⇒ báo cáo phase không vào git; bản sao kiến thức đã vào
  `working.md`/`checklist.md`/`LESSONS_LEARNED.md` (được commit).
