# next.md — Roadmap & việc sắp tới

Cập nhật: 2026-09-23 (+07). Nguồn: `.plan/production_roadmap.md`, `.plan/P4-result.md`.

## Đang ở đâu

- **Phase hiện tại: P4 — Full Pipeline Integration + half-duplex, code xong PHẦN KHÔNG PHỤ THUỘC MÁY (236/236 test, analyze sạch), đã commit `00e16e0` + push.** Precondition của P4 **không đạt** (9/10 phase trong chuỗi P1A→P3 chưa pass DoD riêng); user chọn **waive có ghi rủi ro** + hoãn vòng test máy thật. Đã có orchestrator duy nhất (`lib/services/conversation_session_controller.dart`) thi hành half-duplex thật + phục hồi lỗi từng module; UI không còn tự nối module. **Phát hiện lỗi native mới (K45)**: phát câu mới khi câu trước đang đọc ⇒ câu mới im lặng (ảnh hưởng Emergency Phrase) — ✅ **đã sửa ở tầng code theo yêu cầu user** (`wavFor(gen)` + `cleanTemp(file)` + `onError` suy thế hệ; xem A54); còn chờ xác nhận **hành vi** trên máy thật. **Review lại bản sửa này** còn tìm thêm **2 lỗi cùng họ** (callback của thế hệ cũ đụng state dùng chung ⇒ câu mới im lặng; và `error` của thế hệ cũ ⇒ Dart mở lại cửa ASR giữa lúc đang đọc) — đã sửa, **chưa commit** (vùng audio, chờ user xác nhận).
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
| 13 | **P5** Pre-Brief + Post-Review + Coaching + Training Level | ⬜ | |
| 14 | **P6** Semi-auto Mode (tuỳ chọn) | ⬜ | Cần dùng thực địa ≥ 2 tuần. |
| 15 | **P7** Production Hardening & Release | ⬜ | |

Tổng ước tính tới lúc dùng được (bỏ P6): **~9–11 tuần**.

## Đã hoàn thành

- Không có phase nào **hoàn thành trọn vẹn** (mọi phase đều thiếu vòng xác minh trên máy thật).
- Code xong: P1A, P1B, P1C, P1D, P1E, P1F, P1G, P2, P3, **P4 (phần không phụ thuộc máy)**; P0/P0.5 xong phần không cần thiết bị.
- Xong **phần chuẩn bị của P0** (không cần thiết bị): model PhoWhisper GGML tiny/base (f16 + q5_0), model Vosk small + lớn, 5 tool tái sử dụng được cho P1C/P1D, 5 file số liệu thô, code app spike 1129 dòng (analyze/test/JNI-syntax đều sạch), báo cáo `.plan/P0-result.md`.

## Việc sắp tới (theo thứ tự)

0. **Tải APK mới nhất từ CI** → cài máy → chạy protocol: P1E (`am kill` + đổi ngày 8 ngày, xem
   `lib/transcript/README.md` mục 5), P1D (so sánh 2 engine, 45 phút), P1B (ngưỡng VAD bằng giọng thật),
   P1A/P0.5 (quyền, FGS, DB, `becomingNoisy`), P0 (A2DP/HFP). Đây là việc **chặn chất lượng** của cả 5 phase.
1. **Chốt đường build — XONG 2026-09-21:** KHÔNG build tại máy dev (`/home` ~265MB free); đã push `main` lên `hoangsoft90/ai_assistant_phone`, workflow `build-debug-apk.yml` (gradlew trực tiếp) — run #1 đã trigger. Việc kế tiếp: xem kết quả run để đóng/mở nợ K11/K14; nếu fail → lấy log job theo skill `.agents/skills/ai-assistant-phone-debug-apk/SKILL.md`.
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

0. Cài APK mới nhất → mở app → **Nhập API key Groq** (nút mới của P3) → bấm **Xác nhận tai nghe**
   (K37 vẫn đang bắt bấm mỗi lần mở app) → chọn chế độ `Tai nghe (đọc)`.
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
- **Rủi ro môi trường:** `/home` chỉ còn ~396MB trống; `/tmp/p0spike` có thể mất khi reboot (model trong repo là bản sao lưu).
