# next.md — Roadmap & việc sắp tới

Cập nhật: 2026-09-24 (+07). Nguồn: `.plan/production_roadmap.md`, `.plan/P4-result.md`, `.plan/P5-result.md`, `.plan/P7-result.md`, `.plan/P2_1-result.md`, `.plan/P5_1-result.md`, `.plan/P5_2-result.md`, `.plan/P5_3-result.md`, `.plan/P5_4-result.md`, `.plan/issue1_fix-result.md`.

## Đang ở đâu

- **Phase hiện tại: sau P7 — các phase bổ sung P2.1 (custom LLM provider) + P5.1 (Lịch sử + retention) + P5.2 (tên phiên) + P5.3 (nav 4 tab) + issue1_fix/follow-up (LLM config + vòng đời phiên) + **P5.4 (timeout theo use-case + phân tích bù)** code xong + review xong (**424/424 test**, analyze sạch). **Đã push tới `a36ce8b`** (+docs) — P5.4 lên CI build APK; mốc nền trước đó `d4f4943` (issue1_fix + follow-up + docs). **Tài liệu kết quả đầy đủ: `.plan/P2_1-result.md`, `.plan/P5_1-result.md`, `.plan/P5_2-result.md`, `.plan/P5_3-result.md`, `.plan/P5_4-result.md`, `.plan/issue1_fix-result.md`.** Việc còn lại của dự án là vòng test máy thật gộp (**K51**) với APK mới.**
- *(Lịch sử gần)* **Review P5.1→P5.3 (2026-09-23): 5 test P5.3 đỏ đã được chữa — không phải bug sản phẩm mà là hụt harness test** (thiếu fake capture ⇒ `startNative` nhận null ⇒ FormatException; assertion viết theo trí nhớ bản cũ; timer SnackBar 4.1s còn pending khi test kết thúc; ListView build lười cần scroll). Thêm tham số `capture` tuỳ chọn cho `SessionCoordinator`/`RootScaffold` (đối xứng `startService`). Kèm tối ưu N+1 HistoryScreen (101 query → 2 query qua `sessionIdsWithReport()`). Chi tiết `working.md`.
- *(Lịch sử gần)* **P5 — Pre-Brief + Session Summary + Post-Review + Training Level, code xong PHẦN KHÔNG PHỤ THUỘC MÁY (commit `4e25b74`, đã push, CI xanh run 35816046451 — artifact `app-debug-apk` 114.9 MB; 302/302 test, analyze sạch).** Precondition P5 **không đạt** (chưa có phiên test thật nào + `adb devices` rỗng) ⇒ user **waive có ghi rủi ro**. **1 mâu thuẫn tài liệu đã hỏi & chốt:** bước *cloud ASR* của Post-Review **không được làm** (trái ràng buộc cứng #4 — audio hội thoại không rời máy; app cố ý không ghi audio) ⇒ Post-Review chỉ gửi **text local** lên LLM, DoD-3 "không áp dụng có lý do". Đã có: Pre-Brief (màn hình + nháp trong `meta` + đi vào `{pre_brief}` thật), tóm tắt phiên định kỳ (`{summary}` thật), Post-Review 3 mục, Training Level thủ công (5 cấp, 2 cổng trong `SuggestionPolicy`, **Emergency không bị chặn**), số liệu 7 ngày. **3 lỗi High tự tìm khi review đã sửa** (thử lại dồn dập sau lỗi; nhịp tóm tắt bị trần 20 của `SessionMemory` chặn; kết quả tóm tắt bay về sau `reset()` ⇒ cần **token thế hệ**). **0/5 mục DoD tick** (cần máy + API key Groq) — nợ **K48/K49/K50**. Xem `.plan/P5-result.md`. **Bước kế tiếp (user chốt): chờ buổi test máy để tick DoD K48 — giờ gộp cùng K51 (P7).**
- *(Lịch sử gần)* **P4 — Full Pipeline Integration + half-duplex, code xong PHẦN KHÔNG PHỤ THUỘC MÁY (236/236 test, analyze sạch), đã commit `00e16e0` + push.** Precondition của P4 **không đạt** (9/10 phase trong chuỗi P1A→P3 chưa pass DoD riêng); user chọn **waive có ghi rủi ro** + hoãn vòng test máy thật. Đã có orchestrator duy nhất (`lib/services/conversation_session_controller.dart`) thi hành half-duplex thật + phục hồi lỗi từng module; UI không còn tự nối module. **Phát hiện lỗi native mới (K45)**: phát câu mới khi câu trước đang đọc ⇒ câu mới im lặng (ảnh hưởng Emergency Phrase) — ✅ **đã sửa ở tầng code theo yêu cầu user** (`wavFor(gen)` + `cleanTemp(file)` + `onError` suy thế hệ; xem A54); còn chờ xác nhận **hành vi** trên máy thật. **Review lại bản sửa này** còn tìm thêm **2 lỗi cùng họ** (callback của thế hệ cũ đụng state dùng chung ⇒ câu mới im lặng; và `error` của thế hệ cũ ⇒ Dart mở lại cửa ASR giữa lúc đang đọc) — đã sửa (`995c675`, CI xanh). **Rà tiếp ASR/capture** còn tìm thêm **1 lỗi CRASH TIẾN TRÌNH** (dừng nghe đúng lúc Whisper đang transcribe ⇒ free model native khi đang dùng + `RejectedExecutionException` từ `finally`) + 2 lỗi cùng họ — đã sửa, **chưa commit** (vùng audio, chờ user xác nhận) — nợ verify **K47**.
- *(Lịch sử gần)* **P3 — Trigger + Output Mode + Offline Nudge Cache, code xong (211/211 test), CHƯA commit.** P1C–P1G + P2 + P3 đã code xong; cả chuỗi còn nợ vòng xác minh trên máy thật (K34 P1F, K39 P2, K41/K42 P3; K27 P1E đã xong). Buổi test P1F 2026-09-22 đã xác nhận đường phát TTS đầu-cuối trên máy thật (user nghe rõ) + phát hiện mất tai nghe; nên gộp các lần test máy thật còn lại vào một lượt (P1F rút-mid/TC2/TC3 + P1G emergency + P2 nudge + P3 gesture/3 chế độ/cache offline/tốc độ đọc).
- Nguyên tắc: đi tuần tự, không nhảy cóc; mỗi phase phải tự kiểm Precondition và tự đối chiếu Definition of Done **có bằng chứng** trước khi báo xong.

## Bảng phase & trạng thái

| # | Phase | Trạng thái | Ghi chú |
|---|---|---|---|
| 1 | **P0** Audio Feasibility Spike | 🟡 **dở dang (chờ thiết bị)** | Đã xong phần không cần thiết bị: model ASR, tooling, số liệu host, code app spike. 0/5 mục DoD đạt. |
| 2 | **P0.5** Project Bootstrap (Flutter scaffold) | ⬜ chưa bắt đầu | Precondition: "P0 xác nhận ASR + audio routing khả thi" → **chưa đạt**. |
| 3 | **P1A** Audio Capture Foundation (mic-only) | 🟡 **code xong, 0/5 mục DoD** (chưa build/đo trên máy) | Đã có `lib/audio/capture/` + 2 file Kotlin; kênh capture đã đăng ký cho cả engine UI lẫn engine service (P1B dùng được ngay). |
| 4 | **P1B** VAD + State tối giản | 🟡 **code xong, 0/4 mục DoD** (chưa build/đo trên máy) | WebRTC VAD chạy trên thread thu; state machine 2 trạng thái; **ngưỡng chưa tinh chỉnh bằng giọng thật** (nợ K15) |
| 5 | **P1C** ASR PhoWhisper (chính) | 🟡 **code xong, native compile XANH** (run #7); 0/4 DoD máy thật | Engine + JNI + model 29MB trong APK. Nợ K18 (đo máy thật). |
| 6 | **P1D** ASR Vosk (dự phòng) + abstraction | 🟡 **code xong** (`82f91d2`, CI run mới); 2/4 DoD đạt | Vosk streaming + `AsrEngineSelector` (đổi engine qua config, fallback tự động). **PhoWhisper là mặc định tạm thời** — xem `lib/audio/asr/README.md`. Nợ K19 (đo máy thật), K20 (JNA), K21 (kích thước/RAM). |
| 7 | **P1E** Transcript Store | 🟡 **code xong** (2/4 DoD đạt) | SQLite v2 + migration; rolling 8 phút trong RAM, xoá sau 7 ngày, khôi phục phiên sau khi bị kill; API text thô không nhãn cho P2. Nợ K27 (đo máy thật), K28 (có mã hoá DB không?). |
| 8 | **P1F** TTS Output Safety Layer (A2DP-only) | 🟡 **code xong + ĐÃ TEST MỘT PHẦN trên máy thật** (2026-09-22: phát đầu-cuối ✅ user nghe rõ, mất-tai-nghe+rung ✅; còn rút-mid-playback, TC2, TC3) | Phase an toàn quan trọng nhất. `SafeTtsOutput` = cổng duy nhất phát âm thanh; native `TextToSpeech` → `AudioTrack.setPreferredDevice`, `USAGE_MEDIA`; 2 lớp dừng khi mất tai nghe. Nợ K34 (thu hẹp), K37 (đòi xác nhận mỗi lần mở app), K35 (half-duplex — P4), K36. Xem `.project/modules/tts-safety.md` + `.plan/P1F-result.md`. |
| 9 | **P1G** Emergency Phrase (local) | 🟡 **code xong** (`lib/audio/emergency/`, 8 test mới — 130/130 pass); chưa build/máy thật | `triggerEmergency()` xoay vòng 3 câu cố định, gọi thẳng `SafeTtsOutput` (0 network/LLM — grep chứng minh), đo độ trễ trigger→tổng hợp. Nút tạm trên màn hình chẩn đoán; gesture thật là P3. Xem `.plan/P1G-result.md`. |
| 10 | **P2** Suggestion Engine (LLM + Policy) | 🟡 **code xong** (`lib/suggestion/`, 29 test mới — 161/161 pass; có thêm 3 lỗi High tự tìm khi review, đã sửa); chưa test máy thật | Groq `llama-3.1-8b-instant` (chỉ gửi TEXT), policy chặn cứng `userSpeaking` + debounce 1s, prompt khung nguyên văn, anti-repetition 2 phút, `push()` không bao giờ ném. Nợ **K39** (5 mục DoD cần máy thật + Groq API key trong SecureStore) + **K40** (Offline Nudge Cache — P3). Xem `.plan/P2-result.md`. |
| 11 | **P3** Trigger Abstraction + Output Modes + Offline Nudge Cache | 🟡 **code xong** (`lib/trigger/`, `lib/ui/floating_button.dart`, 2 file audio, cache asset — 50 test mới: 211/211 pass, analyze sạch); chưa test máy thật | Trigger = **một hàm duy nhất** `TriggerManager.onSuggestRequested`; nút nổi tap=Push / giữ **đúng 2s**=Emergency; 3 chế độ output (Ear tự hạ xuống chữ khi thiếu tai nghe) + tốc độ đọc 0.9-1.2x; Offline Cache 72 câu (chỉ fallback khi LLM không dùng được). Nợ **K41** (tốc độ đọc native), **K42** (máy thật), **K43** (volume key/nút BT/thông báo), **K44** (cache không theo chủ đề). K38/K40 **đóng**. Xem `.plan/P3-result.md`. |
| 12 | **P4** Full Pipeline Integration (half-duplex) | 🟡 **code xong (phần không phụ thuộc máy)** — 236/236 test, analyze sạch | Orchestrator `ConversationSessionController` (half-duplex thật, chốt chống chồng tiếng, phục hồi từng module, số liệu DoD hiện trên màn hình chẩn đoán). Precondition không đạt → user waive. Nợ **K45** (lỗi native TTS im lặng) + **K46** (5 mục DoD máy thật). K35 (half-duplex) **đóng**. Xem `.plan/P4-result.md` |
| 13 | **P5** Pre-Brief + Post-Review + Coaching + Training Level | 🟡 **code xong (phần không phụ thuộc máy)** — 302/302 test, analyze sạch | `lib/coaching/` + `lib/ui/{pre_brief,post_review,stats}_screen.dart` + 2 cổng Training Level trong `SuggestionPolicy`; Precondition không đạt → user waive; **bước cloud ASR của prompt cố ý bỏ** (mâu thuẫn ràng buộc #4 — đã hỏi user). Nợ **K48** (0/5 mục DoD máy thật), **K49** (luật Level 2/3 là heuristic), **K50** (báo cáo không persist). Xem `.plan/P5-result.md` |
| 13b | **P2.1** Custom LLM Provider (endpoint/model tuỳ chỉnh) | 🟡 code xong — 320/320 test | `llm_provider_config.dart` + UI cấu hình + khôi phục Groq; cần endpoint thật trên máy (human.md Việc 8). Xem `.plan/P2_1-result.md` |
| 13c | **P5.1** Lịch sử phiên + lưu báo cáo + retention chỉnh được | 🟡 code xong — 343/343 test | Schema v3 (`post_review_reports`) + HistoryScreen + dropdown 3/7/14/30 (cleanup chạy ngay); tối ưu N+1 (2 query). Xem `.plan/P5_1-result.md` |
| 13d | **P5.2** Tên phiên (mặc định timestamp, đổi được) | 🟡 code xong — 365/365 test | Schema v4 (cột `title`) — migration chứng minh trên SQLite thật; `SessionDisplayName` dùng chung. Xem `.plan/P5_2-result.md` |
| 13e | **P5.3** Nav 4 tab + nút nổi toàn cục | 🟡 code xong — 373/373 test | `RootScaffold` (IndexedStack) + `GlobalFloatingControls` + `SessionCoordinator`; `home_screen.dart` thành shim; `floating_button.dart` 0 dòng bị đụng; **báo cáo `.plan/P5_3-result.md`** (15 dòng chẩn đoán giữ đủ) |
| 13f | **issue1_fix** LLM config + session lifecycle + follow-up summary dùng custom LLM | 🟡 code xong — 399/399 test | Migration v5 (`ended_at_ms`), resume chỉ session chưa kết thúc trong 30′, Test-LLM trong Settings, key plaintext debug-only; **follow-up**: `SessionSummaryService` nhận `llmConfigStore?` — tóm tắt đi đúng endpoint/model tuỳ chỉnh (test mock HTTP server cục bộ). Xem `.plan/issue1_fix-result.md` |
| 13g | **P5.4** Timeout theo use-case + phân tích bù phiên thiếu báo cáo | 🟡 code xong — 424/424 test | Push **giữ 4s**; Post-Review/Summary **5 phút**; Test LLM 30s; `connectionTimeout` 10s ở tầng socket; schema **v6** (`last_analysis_attempt_ms`); `PendingAnalysisService` (tuần tự, throttle 6h) + 2 trigger (init app, nút trên AppBar Lịch sử). Xem `.plan/P5_4-result.md` |
| 14 | **P6** Semi-auto Mode (tuỳ chọn) | ⬜ | Cần dùng thực địa ≥ 2 tuần. |
| 15 | **P7** Production Hardening & Release | 🟡 phần tĩnh xong (audit, EthicsGate, R8 + CI release; signing chưa theo chốt user); nợ máy thật K51 | Xem `.plan/P7-result.md` + `RELEASE_NOTES.md` |

Tổng ước tính tới lúc dùng được (bỏ P6): **~9–11 tuần**.

## Đã hoàn thành

- Không có phase nào **hoàn thành trọn vẹn** (mọi phase đều thiếu vòng xác minh trên máy thật).
- Code xong: P1A, P1B, P1C, P1D, P1E, P1F, P1G, P2, P2.1, P3, **P4 (phần không phụ thuộc máy)**, **P5 (phần không phụ thuộc máy)**, **P5.1, P5.2, P5.3, P7 (phần tĩnh)**; P0/P0.5 xong phần không cần thiết bị.
- Xong **phần chuẩn bị của P0** (không cần thiết bị): model PhoWhisper GGML tiny/base (f16 + q5_0), model Vosk small + lớn, 5 tool tái sử dụng được cho P1C/P1D, 5 file số liệu thô, code app spike 1129 dòng (analyze/test/JNI-syntax đều sạch), báo cáo `.plan/P0-result.md`.
- **Buổi test adb 2026-09-23** (Pixel 3a): T0 (đạo đức/quyền/FGS/mic), T3 (ASR thật — 4 dòng transcript tiếng Việt), T5 (TC2 silent fallback + rung), T9 (đổi engine khi đang nghe), T7 (crash recovery) — chi tiết `.plan/ADB-TEST-result.md`.

## Việc sắp tới (theo thứ tự)

0. ✅ *(Đã xong 2026-09-23)* **Tách commit P2.1/P5.1/P5.2/P5.3 + docs và push** — 5 commit tới `9259082`; APK mới chứa
   custom LLM provider, Lịch sử phiên, tên phiên, nav 4 tab. **Việc còn lại: tải APK từ run CI mới nhất → cài máy.**
1. **Buổi test máy thật gộp (K51) — danh mục đầy đủ trong `TESTING.md` + `human.md`** (8 việc):
   migration DB có sẵn (v2→v4), đổi tên phiên, retention + cleanup ngay, cấu hình LLM endpoint thật,
   nav 4 tab + nút nổi, Pre-Brief/summary/Post-Review/Level, P4 half-duplex + K45, P1F TC1/TC3.
2. **Sau buổi test:** tick DoD từng phase trong `.plan/*-result.md`, đóng nợ K (K34/K36/K37/K39/K41/K42/K45/K46/K48/K49/K51), cập nhật `checklist.md`/`next.md`/`RELEASE_NOTES.md`.
3. **Signing release thật** (keystore ngoài git, CI secret) — khi user sẵn sàng phân phối; hiện APK debug-signed chỉ để test.
4. **P6 Semi-auto Mode** — chỉ khi đã dùng thực địa ổn định ≥ 2 tuần (điều kiện prompt).
5. *(Cũ — đã xử lý)* Tải APK CI, chốt đường build, các protocol P0/P1A/P1B/P1E — phần lớn đã chạy trong buổi adb 2026-09-23 (`.plan/ADB-TEST-result.md`); phần còn lại gộp vào K51 ở trên.
   · **Nợ kiểm chứng hiện đã chồng 4 lớp**: P0 (5 mục), P0.5 (3 mục), P1A (5 mục), P1B (4 mục) — tất cả đều chỉ vướng một việc duy nhất là *build APK + cầm máy thật*. Ưu tiên tuyệt đối: dựng được APK trước khi mở thêm phase. Riêng P1B còn có ngưỡng VAD **phải** tinh chỉnh bằng giọng thật ⇒ viết thêm code trước khi đo chỉ tạo ra ngưỡng "đúng trên giấy".
2. **Build + cài APK** lên điện thoại, xác nhận app mở, xin quyền mic, đọc được model.
3. **`adb push` model** vào `/sdcard/Android/data/vn.p0spike.p0_spike/files/models/` và xác nhận app nhận cả 2 model.
4. **Task 1** — chạy từng engine riêng: độ chính xác trên giọng bạn (≈2 phút hội thoại), độ trễ mỗi chunk, pin giảm trong 30 phút, ổn định 45–60 phút (màn hình tắt), và xác nhận không cần mạng (chế độ máy bay).
5. **Task 2** — `adb shell dumpsys audio` song song khi TTS đang phát qua tai nghe: **giữ A2DP hay bị ép HFP** (kết luận go/no-go của mục 4.2a).
6. **Task 3** — rút tai nghe đột ngột giữa lúc TTS phát; xác nhận không lọt tiếng ra loa ngoài.
7. **Task 4** — full pipeline 45–60 phút, đếm số lần tự dừng/mất transcript.
8. **Kết luận go/no-go bằng văn bản** → cập nhật `.plan/P0-result.md`, `checklist.md`, `next.md`.
9. Chỉ sau khi có kết luận mới sang **P0.5** (bootstrap app Flutter thật).

### Buổi test máy thật sắp tới (gộp nhiều nợ vào MỘT lượt — cần APK mới + tai nghe, ~45′ + 30′ phiên P4)

> **P5 (K48) thêm vào lượt test này — dùng CHÍNH buổi ≥ 30 phút ở dưới, không cần buổi riêng:**
>   - **Pre-Brief (DoD-1):** nhập Pre-Brief (kiêng kỵ "chuyện lương") trước khi bật → nudge không rơi vào
>     chuyện lương; đổi kiêng kỵ sang "chuyện gia đình" ⇒ nudge đổi theo. Dòng `Coaching (P5)` phải ghi
>     `Pre-Brief: có`.
>   - **Session summary:** sau ≥ 4 lần Push, dòng `Coaching (P5)` phải hiện `tóm tắt 1 lần (mới nhất HH:MM)`;
>     nếu không, phần trong ngoặc nói lý do (mất mạng/chưa có key).
>   - **Training Level:** chọn `Training` ⇒ Push bị chặn với lý do `level training`, nhưng giữ nút nổi 2s
>     **vẫn nghe có câu thoát hiểm**; chọn `Minimal` ⇒ Push bị chặn khi vừa có người nói, cho qua sau ~8s.
>   - **Post-Review:** bấm "Kết thúc buổi + nhận xét" ⇒ phải có **đúng 3 mục**; mở "Xem chi tiết" thấy
>     transcript; dòng `Coaching (P5)` ghi `nhận xét 1 lần`.
>   - **Số liệu 7 ngày:** khớp số buổi/Push thật của ngày hôm đó; **không** có câu gợi ý đổi cấp nào.
>
> **P4 (K46) thêm vào giáo trình này — quan trọng nhất vì cần phiên THẬT ≥ 30 phút:**
> 0. Bật lắng nghe → nói chuyện thật (2 người hoặc roleplay) **liên tục ≥ 30 phút**, nhiều lần bấm
>    Push ở các thời điểm khác nhau (đang nói / im lặng / **đúng lúc TTS đang đọc**).
>    - Đọc dòng `Phiên (P4)` trên màn hình chẩn đoán: `chunk bị chặn khi đang phát` **tăng** khi có
>      nudge được đọc và `ASR nhận lại` tăng tương ứng ⇒ half-duplex có tác dụng thật.
>    - Xác nhận ASR **không** bắt nhầm giọng TTS: đọc dòng `Nhận dạng`, xem transcript không chứa
>      câu nudge vừa được đọc; đối chiếu `adb shell dumpsys audio` xem route vẫn A2DP (không SCO).
>    - Bấm Push lúc đang đọc ⇒ mong đợi SnackBar "đang đọc gợi ý trước — bỏ qua lần bấm này" và
>      **không** có tiếng nào bị cắt giữa từ (số `bỏ qua N Push (đang phát)` tăng).
>    - Đo pin/giờ + ghi lại số `Push→tổng hợp ... ms (tb)`.
>    - **Rút tai nghe GIỮA phiên** ⇒ như P1F (im lặng + rung, không lọt loa).
>    - **Tắt mạng giữa phiên** (chế độ máy bay) ⇒ nudge từ Offline Cache, phiên KHÔNG sập.
> 0b. ⚠️ K45: thử giữ nút nổi 2 giây **đúng lúc đang đọc một nudge** ⇒ nếu **không nghe thấy câu
>    thoát hiểm** thì lỗi K45 đã xảy ra thật (log `SafeTts: không có file WAV để phát`).

> **Giáo trình từng bước (viết lại 2026-09-23, khớp code `4c699f6`+): `TESTING.md`** — dùng nó thay cho
> danh sách rút gọn dưới đây khi ngồi test thật.

0. Cài APK mới nhất → mở app → bấm **"Tôi hiểu"** ở lời nhắc đạo đức (P7, chỉ hiện lần đầu — bấm back
   thì lần sau nhắc lại) → **Nhập API key Groq** (nút mới của P3) → bấm **Xác nhận tai nghe**
   (K37 đang bắt bấm mỗi lần mở app: **cố ý**, xem `.project/openspec.md` §3 K37 — sửa sớm sẽ mất phễu
   kiểm route khi **K36** chưa xong) → chọn chế độ `Tai nghe (đọc)`.
1. **K39 (P2):** bấm **Gợi ý** khi không nói ⇒ nudge thật từ Groq; bấm khi đang nói ⇒ không request nào
   đi; bấm 2 lần trong 2 phút ⇒ anti-repetition; **chế độ máy bay** ⇒ nudge từ Offline Cache
   (dòng `CACHE OFFLINE`) — đây cũng là **K42 (P3)** mục DoD-4.
2. **K42 (P3):** giữ nút nổi **đúng 2 giây** ⇒ câu thoát hiểm (không phải Push); thả sớm ⇒ Push.
   Đổi sang chế độ `Rung` ⇒ cảm nhận rung; `Chỉ hiện chữ` ⇒ không âm thanh; kéo thanh tốc độ về 0,9x
   rồi 1,2x ⇒ **K41** nghe khác nhau rõ.
3. **K34 (P1F):** rút tai nghe giữa lúc đang đọc, rút trước khi đọc, tắt Bluetooth khi đang đọc
   (3 test case bắt buộc của phase an toàn quan trọng nhất) — xem `.project/modules/tts-safety.md` mục 6.
4. **P1G:** bấm nút Emergency khi **không** có tai nghe ⇒ im lặng + rung, không lọt loa.
5. Ghi kết quả vào `.plan/P1F-result.md`, `.plan/P2-result.md`, `.plan/P3-result.md` + `checklist.md`.

## Điểm chặn & rủi ro

- **Chặn cứng:** thiết bị thật (không thể thay bằng emulator vì cần mic/Bluetooth/pin thật).
- **Rủi ro kỹ thuật chưa kiểm chứng được:** build native lần đầu trên CI (AGP 9.1 + NDK 28.2 + whisper.cpp qua FetchContent), phần Kotlin chưa từng được biên dịch.
- **Rủi ro chất lượng ASR:** Vosk (cả 2 bản) trả về rỗng khi audio nhỏ tiếng — đúng kịch bản dùng thật (mic để xa). Nếu PhoWhisper trên CPU điện thoại quá chậm (RTF host đã là 0.53 cho bản base) thì phải xem xét tiny hoặc thiết kế lại kích thước chunk.
- **Rủi ro môi trường:** `/home` còn **~364MB** trống (2026-09-23: đã dọn 48MB rác tái tạo được trong `spikes/` + chuyển 133MB model ra `/tmp/p0spike-models` ⇒ trước đó chỉ 185MB). `/tmp` **có thể mất khi reboot** — model ở đó tái tạo được bằng `spikes/p0_audio/tools/convert_phowhisper.sh` (~10 phút), nên **đừng** coi `/tmp` là nơi lưu trữ lâu dài.
