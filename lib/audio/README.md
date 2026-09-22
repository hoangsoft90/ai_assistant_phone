# `lib/audio/` — thu âm, VAD, ASR, TTS

Nơi chứa toàn bộ pipeline audio. Sẽ được điền dần theo thứ tự phase:

| Phase | Thành phần dự kiến |
|---|---|
| ✅ P1A | `capture/` — Audio capture từ **mic điện thoại** (`AudioRecord`, nguồn `MIC`), stream PCM 16kHz mono. Xong code, **chưa verify trên máy thật** (xem `.plan/P1A-result.md`) |
| P1B | VAD + state tối giản `userSpeaking` / `notUserSpeaking` |
| P1C | `PhoWhisperAsrEngine` (whisper.cpp, model GGML q5_0) implement interface `AsrEngine` |
| P1D | `VoskAsrEngine` + `AsrEngineSelector` (đổi engine qua config) |
| ✅ P1F | `tts/` — `SafeTtsOutput`: cổng **bắt buộc** cho mọi phát âm thanh từ phase này trở đi (native `TextToSpeech` → `AudioTrack.setPreferredDevice`). Code xong, **3 test case máy thật chưa chạy** (`.plan/P1F-result.md`) |
| P1G | Emergency Phrase (local, tách khỏi luồng LLM) |

Trạng thái hiện tại: `app_audio_session.dart` (P0.5) + `capture/` (P1A) + `vad/` (P1B) + `asr/` (P1C/P1D)
+ `tts/` (P1F, 3 file Dart bọc 1 file Kotlin). Chi tiết an toàn TTS: `.project/modules/tts-safety.md`.

**Ràng buộc kiến trúc bắt buộc (đừng vi phạm khi thêm code vào đây):**
- Mic thu là **mic điện thoại**; tai nghe Bluetooth **chỉ để phát** (A2DP một chiều). Không dùng
  usage `voiceCommunication` — nó kéo hệ thống sang HFP/SCO và hạ chất lượng audio.
- Chiều thu phải chạy **100% offline**; không có phương án cloud ASR nào cho luồng nghe realtime
  (cloud chỉ dùng ở Post-Review P5, và chỉ khi có Wi-Fi).
- Từ P1F trở đi, mọi lệnh phát âm thanh **phải** đi qua `SafeTtsOutput`, không gọi TTS trực tiếp.
  Kiểm nhanh: `grep -rn "\.speak(" lib/` — chỉ được thấy trong `tts/safe_tts_output.dart` và nơi gọi
  `SafeTtsOutput` (hiện là nút đọc thử trên màn hình chẩn đoán).
