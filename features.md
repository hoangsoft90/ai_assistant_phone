# features.md — Trợ lý AI hỗ trợ giao tiếp realtime (Android, cá nhân)

Cập nhật: 2026-09-21. Nguồn: `.plan/plan_final_v2.md` (mục 1, 4, 5) + `.plan/production_roadmap.md`.

## Định nghĩa sản phẩm (mục 1.1)

App Android cá nhân, **nghe cuộc trò chuyện realtime và đưa gợi ý ngắn (nudge) khi người dùng chủ động bấm nút xin gợi ý** (push-to-suggest). Ràng buộc cứng: chỉ 1 điện thoại + 4G + 1 tai nghe Bluetooth, không server riêng.

## Bốn nguyên tắc bất biến (mục 1.3)

1. Chiều thu (nghe + ASR) chạy **100% offline**, không phụ thuộc mạng/quota bên thứ ba.
2. TTS **chỉ ra tai nghe**, tuyệt đối không ra loa ngoài.
3. Transcript để **thô**, không gắn nhãn người nói.
4. Người dùng giữ quyền chủ động: nudge chỉ xuất hiện khi bấm Push (trừ semi-auto mode là tuỳ chọn, có cooldown).

## Tính năng hiện có

| # | Tính năng | Trạng thái | Ghi chú |
|---|---|---|---|
| 0 | — | — | **Chưa có tính năng sản phẩm nào.** Repo mới ở Phase 0 (spike thăm dò). Thứ duy nhất đang chạy được là code spike P0 (`spikes/p0_audio/`, throwaway, chưa build) + tooling convert/đo model ASR. |

## Tính năng tương lai (theo plan, chưa làm)

### Tầng thu & hiểu (Audio Pipeline — mục 4.2)
- [ ] Ghi âm liên tục bằng **mic điện thoại** (`AudioSource.MIC`) 16kHz mono.
- [ ] VAD + state tối giản `userSpeaking` / `notUserSpeaking` (thay cho state machine đầy đủ).
- [ ] ASR on-device **PhoWhisper** (chính, GGML q5_0 qua whisper.cpp) — P1C.
- [ ] ASR on-device **Vosk** (dự phòng) + `AsrEngine` abstraction đổi engine qua config — P1D.
- [ ] Transcript Store (text + timestamp, **không** nhãn speaker) — P1E.
- [ ] Không dùng cloud ASR cho chiều thu trong mọi trường hợp.

### Tầng phát (TTS an toàn — mục 4.2c, 4.8)
- [ ] `SafeTtsOutput`: chỉ phát khi có output device là tai nghe, chặn mọi khả năng lọt ra loa ngoài — P1F (**phase an toàn quan trọng nhất**).
- [ ] **Emergency Phrase**: câu khẩn cấp phát 100% local, tách hoàn toàn khỏi luồng LLM — P1G.
- [ ] Output Mode (TTS / hiển thị màn hình / kết hợp) — P3.
- [ ] Half-duplex bắt buộc: TTS đang phát → tạm dừng ASR → TTS xong mới bật lại — P4.

### Tầng gợi ý (Suggestion — mục 4.4–4.7)
- [ ] Suggestion Engine gọi LLM (Groq Llama/Gemini Flash) khi người dùng bấm Push — P2.
- [ ] Suggestion Policy: khi nào gợi ý, giới hạn số lượng/độ dài, nội dung ngắn để đọc được ngay.
- [ ] Phân loại Nudge (mục 4.5): các loại gợi ý khác nhau theo tình huống.
- [ ] Trigger Abstraction (mục 4.6): tách "cái gì kích hoạt gợi ý" khỏi "gợi ý nội dung gì" — P3.
- [ ] Anti-repetition & Session Memory (mục 4.7): không lặp lại gợi ý đã đưa trong buổi.
- [ ] **Offline Nudge Cache** (mục 4.12): fallback khi mất mạng — P3.
- [ ] **Pre-Brief** (mục 4.1): bắt buộc nhập ngắn ngữ cảnh buổi trước khi bắt đầu — P5.
- [ ] **Post-Review** (mục 4.10): sau buổi, gửi transcript lên ASR cloud chất lượng cao (**chỉ khi có Wi-Fi**, tần suất thấp) + LLM sinh báo cáo 3 mục: 1 điều làm tốt / 1 điều cần cải thiện / 1 gợi ý luyện tập; cập nhật **Training Level thủ công** (mục 4.9, không tự động đề xuất/chuyển cấp) — P5.
- [ ] **Semi-auto Mode** (tuỳ chọn, P6): tự động gợi ý theo trigger + **cooldown**. Cooldown **chỉ** áp cho semi-auto, KHÔNG áp cho Push thủ công.

### Vận hành & phát hành
- [ ] Foreground Service chạy liên tục, chống bị Android/Doze giết; hướng dẫn loại app khỏi battery optimization — P7.
- [ ] Kiểm soát kích thước APK (model ASR nặng) — P7.
- [ ] Error handling toàn diện + build release ký số (keystore không commit) — P7.
- [ ] Kiểm tra chi phí/bảo mật/đạo đức dù dùng cá nhân (mục 5.3).

## Ràng buộc xuyên phase (dễ vi phạm khi làm phase sau)

- Từ P1F trở đi: **mọi** phát âm thanh phải qua `SafeTtsOutput` (không gọi `flutter_tts`/`TextToSpeech` trực tiếp).
- Từ P1C/P1D: không thêm bất kỳ lời gọi cloud ASR nào cho luồng nghe realtime.
- Từ P1E: không thêm trường `speaker`/`label` vào model transcript.
- Từ P2: không áp cooldown lên Push thủ công.
- Từ P5: không tự động đề xuất/chuyển Training Level.
