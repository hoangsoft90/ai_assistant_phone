# next.md — Roadmap & việc sắp tới

Cập nhật: 2026-09-21 15:17 (+07). Nguồn: `.plan/production_roadmap.md`, `.plan/P0-result.md`.

## Đang ở đâu

- **Phase hiện tại: P1F — code xong, đang chờ chạy 3 test case bắt buộc trên máy thật (K34).** P1C–P1F đã code xong; điều còn thiếu xuyên suốt vẫn là **một vòng đo trên máy thật** (P0/P0.5/P1A/P1B/P1C/P1D/P1E/P1F đều nợ DoD đo trên máy — K2/K18/K19/K27/K34).
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
| 8 | **P1F** TTS Output Safety Layer (A2DP-only) | 🟡 **code xong** (`386c3df`, CI run #22/#23 xanh); **0/3 test case máy thật** | Phase an toàn quan trọng nhất. `SafeTtsOutput` = cổng duy nhất phát âm thanh; native `TextToSpeech` → `AudioTrack.setPreferredDevice`, `USAGE_MEDIA`; 2 lớp dừng khi mất tai nghe. Nợ K34 (3 test case), K35 (half-duplex — P4), K36 (giới hạn thiết bị/engine). Xem `.project/modules/tts-safety.md`. |
| 9 | **P1G** Emergency Phrase (local) | ⬜ | |
| 10 | **P2** Suggestion Engine (LLM + Policy) | ⬜ | |
| 11 | **P3** Trigger Abstraction + Output Modes + Offline Nudge Cache | ⬜ | |
| 12 | **P4** Full Pipeline Integration (half-duplex) | ⬜ | |
| 13 | **P5** Pre-Brief + Post-Review + Coaching + Training Level | ⬜ | |
| 14 | **P6** Semi-auto Mode (tuỳ chọn) | ⬜ | Cần dùng thực địa ≥ 2 tuần. |
| 15 | **P7** Production Hardening & Release | ⬜ | |

Tổng ước tính tới lúc dùng được (bỏ P6): **~9–11 tuần**.

## Đã hoàn thành

- Không có phase nào **hoàn thành trọn vẹn** (mọi phase đều thiếu vòng xác minh trên máy thật).
- Code xong: P1A, P1B, P1C, P1D, P1E; P0/P0.5 xong phần không cần thiết bị.
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

## Điểm chặn & rủi ro

- **Chặn cứng:** thiết bị thật (không thể thay bằng emulator vì cần mic/Bluetooth/pin thật).
- **Rủi ro kỹ thuật chưa kiểm chứng được:** build native lần đầu trên CI (AGP 9.1 + NDK 28.2 + whisper.cpp qua FetchContent), phần Kotlin chưa từng được biên dịch.
- **Rủi ro chất lượng ASR:** Vosk (cả 2 bản) trả về rỗng khi audio nhỏ tiếng — đúng kịch bản dùng thật (mic để xa). Nếu PhoWhisper trên CPU điện thoại quá chậm (RTF host đã là 0.53 cho bản base) thì phải xem xét tiny hoặc thiết kế lại kích thước chunk.
- **Rủi ro môi trường:** `/home` chỉ còn ~396MB trống; `/tmp/p0spike` có thể mất khi reboot (model trong repo là bản sao lưu).
