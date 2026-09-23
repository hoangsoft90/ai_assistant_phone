# features.md — Trợ lý AI hỗ trợ giao tiếp realtime (Android, cá nhân)

Cập nhật: 2026-09-23 (sau P7 + các phase bổ sung P2.1/P5.1/P5.2/P5.3). Nguồn: `.plan/plan_final_v2.md` (mục 1, 4, 5) + `.plan/production_roadmap.md` + `.plan/*-result.md`.

## Định nghĩa sản phẩm (mục 1.1)

App Android cá nhân, **nghe cuộc trò chuyện realtime và đưa gợi ý ngắn (nudge) khi người dùng chủ động bấm nút xin gợi ý** (push-to-suggest). Ràng buộc cứng: chỉ 1 điện thoại + 4G + 1 tai nghe Bluetooth, không server riêng.

## Bốn nguyên tắc bất biến (mục 1.3)

1. Chiều thu (nghe + ASR) chạy **100% offline**, không phụ thuộc mạng/quota bên thứ ba.
2. TTS **chỉ ra tai nghe**, tuyệt đối không ra loa ngoài.
3. Transcript để **thô**, không gắn nhãn người nói.
4. Người dùng giữ quyền chủ động: nudge chỉ xuất hiện khi bấm Push (trừ semi-auto mode là tuỳ chọn, có cooldown).

## Tính năng hiện có

> Trạng thái: **code + test xong** nghĩa là có test Dart xanh (373/373) nhưng **chưa verify máy thật** nếu ghi chú nói rõ — giáo trình test ở `human.md`.

| # | Tính năng | Phase | Trạng thái | Ghi chú |
|---|---|---|---|---|
| 1 | Foreground service + audio session + SQLite + màn chẩn đoán | P0.5 | ✅ đã chạy thật | Đã verify adb 2026-09-23 |
| 2 | Capture mic (P1A) + VAD hội thoại (P1B) | P1A/P1B | ✅ đã chạy thật | T0/T7 đạt trên máy |
| 3 | ASR PhoWhisper (chính) | P1C | ✅ đã chạy thật | Transcript thật tiếng Việt vào DB |
| 4 | ASR Vosk (dự phòng) + selector + đổi engine an toàn | P1D + sửa bug | ✅ đã chạy thật | T9 đạt cả 2 chiều |
| 5 | Transcript store + khôi phục sau kill | P1E | ✅ đã chạy thật | 4 segments qua force-stop |
| 6 | SafeTtsOutput (chỉ tai nghe, silent fallback + rung) | P1F | ⚠ code xong | TC2 đạt; TC1/TC3 chờ human |
| 7 | Emergency Phrase (giữ 2s, 100% local) | P1G | ⚠ code xong | User xác nhận nghe qua tai nghe; test đầy đủ chờ human |
| 8 | Suggestion Engine (Groq) + policy + Nudge/Emergency/Output Mode | P2/P3 | ⚠ code xong | Cần nhập Groq key trên máy |
| 9 | Half-duplex + chống race TTS/ASR + recovery | P4 | ⚠ code xong | K45 cần nghe thật |
| 10 | Pre-Brief + Session Summary + Post-Review + Training Level + Thống kê tuần | P5 | ⚠ code xong | K48 chưa verify máy |
| 11 | Lịch sử phiên + lưu/xem lại báo cáo + retention chỉnh được (3/7/14/30) | P5.1 | ⚠ code xong | Migration v2→v3 chờ máy; tối ưu N+1 (2 query) |
| 12 | Đặt tên phiên (mặc định theo timestamp, đổi tên được) | P5.2 | ⚠ code xong | Migration v3→v4 chứng minh trên SQLite thật |
| 13 | UI 4 tab (Trang chủ/Lịch sử/Thống kê/Cài đặt) + nút nổi toàn cục | P5.3 | ⚠ code xong | Nav + floating controls có 7 test widget |
| 14 | Custom LLM Provider (endpoint/model tuỳ chỉnh, khôi phục Groq) | P2.1 | ⚠ code xong | Cần endpoint thật trên máy (human.md Việc 8) |
| 15 | Production hardening (R8/minify, quy tắc riêng tư, release notes) | P7 | ✅ build CI xanh | APK debug-signed; signing thật chưa làm (chốt với user) |
| 16 | Semi-auto Mode | P6 | ❌ chưa làm | Tuỳ chọn, không bắt buộc |

## Tính năng tương lai (chưa làm)

### Tầng thu & hiểu (Audio Pipeline — mục 4.2)
- [ ] Ghi âm liên tục bằng **mic điện thoại** (`AudioSource.MIC`) 16kHz mono.
- [ ] VAD + state tối giản `userSpeaking` / `notUserSpeaking` (thay cho state machine đầy đủ).
- [ ] ASR on-device **PhoWhisper** (chính, GGML q5_0 qua whisper.cpp) — P1C.
- [ ] ASR on-device **Vosk** (dự phòng) + `AsrEngine` abstraction đổi engine qua config — P1D.
- [ ] Transcript Store (text + timestamp, **không** nhãn speaker) — P1E.
- [ ] Không dùng cloud ASR cho chiều thu trong mọi trường hợp.

### Tầng phát (TTS an toàn — mục 4.2c, 4.8)
- [x] `SafeTtsOutput`: chỉ phát khi có output device là tai nghe, chặn mọi khả năng lọt ra loa ngoài — P1F (**phase an toàn quan trọng nhất**).
- [x] **Emergency Phrase**: câu khẩn cấp phát 100% local, tách hoàn toàn khỏi luồng LLM — P1G.
- [x] Output Mode (TTS / hiển thị màn hình / kết hợp) — P3.
- [x] Half-duplex bắt buộc: TTS đang phát → tạm dừng ASR → TTS xong mới bật lại — P4.

### Tầng gợi ý (Suggestion — mục 4.4–4.7)
- [x] Suggestion Engine gọi LLM (Groq Llama/Gemini Flash) khi người dùng bấm Push — P2 (+P2.1 endpoint/model tuỳ chỉnh).
- [x] Suggestion Policy: khi nào gợi ý, giới hạn số lượng/độ dài, nội dung ngắn để đọc được ngay.
- [x] Phân loại Nudge (mục 4.5): các loại gợi ý khác nhau theo tình huống.
- [x] Trigger Abstraction (mục 4.6): tách "cái gì kích hoạt gợi ý" khỏi "gợi ý nội dung gì" — P3.
- [x] Anti-repetition & Session Memory (mục 4.7): không lặp lại gợi ý đã đưa trong buổi.
- [x] **Offline Nudge Cache** (mục 4.12): fallback khi mất mạng — P3.
- [x] **Pre-Brief** (mục 4.1): bắt buộc nhập ngắn ngữ cảnh buổi trước khi bắt đầu — P5.
- [x] **Post-Review** (mục 4.10): gửi transcript local (text) → LLM sinh báo cáo 3 mục (mâu thuẫn cloud-ASR trong prompt gốc đã được user chốt bỏ — đúng ràng buộc offline); lưu + xem lại từ Lịch sử — P5/P5.1; cập nhật **Training Level thủ công** (mục 4.9) — P5.
- [ ] **Semi-auto Mode** (tuỳ chọn, P6): tự động gợi ý theo trigger + **cooldown**. Cooldown **chỉ** áp cho semi-auto, KHÔNG áp cho Push thủ công.

### Vận hành & phát hành
- [x] Foreground Service chạy liên tục, chống bị Android/Doze giết; hướng dẫn loại app khỏi battery optimization — P7.
- [x] Kiểm soát kích thước APK (model ASR nặng) — P7 (R8/minify + abiFilters, CI build xanh).
- [x] Error handling toàn diện + build release — P7 (**signing thật chưa làm** — keystore không commit, chốt với user).
- [x] Kiểm tra chi phí/bảo mật/đạo đức dù dùng cá nhân (mục 5.3) — P7 (EthicsGate + quy tắc riêng tư).
- [x] UI điều hướng 4 tab + nút nổi toàn cục + tên phiên + retention — P5.1/P5.2/P5.3 (bổ sung ngoài plan gốc).

## Ràng buộc xuyên phase (dễ vi phạm khi làm phase sau)

- Từ P1F trở đi: **mọi** phát âm thanh phải qua `SafeTtsOutput` (không gọi `flutter_tts`/`TextToSpeech` trực tiếp).
- Từ P1C/P1D: không thêm bất kỳ lời gọi cloud ASR nào cho luồng nghe realtime.
- Từ P1E: không thêm trường `speaker`/`label` vào model transcript.
- Từ P2: không áp cooldown lên Push thủ công.
- Từ P5: không tự động đề xuất/chuyển Training Level.
