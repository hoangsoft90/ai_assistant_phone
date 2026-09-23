# `lib/audio/` — thu âm, VAD, ASR, TTS

Nơi chứa toàn bộ pipeline audio. Sẽ được điền dần theo thứ tự phase:

| Phase | Thành phần dự kiến |
|---|---|
| ✅ P1A | `capture/` — Audio capture từ **mic điện thoại** (`AudioRecord`, nguồn `MIC`), stream PCM 16kHz mono. Xong code, **chưa verify trên máy thật** (xem `.plan/P1A-result.md`) |
| P1B | VAD + state tối giản `userSpeaking` / `notUserSpeaking` |
| P1C | `PhoWhisperAsrEngine` (whisper.cpp, model GGML q5_0) implement interface `AsrEngine` |
| P1D | `VoskAsrEngine` + `AsrEngineSelector` (đổi engine qua config) |
| ✅ P1F | `tts/` — `SafeTtsOutput`: cổng **bắt buộc** cho mọi phát âm thanh từ phase này trở đi (native `TextToSpeech` → `AudioTrack.setPreferredDevice`). Code xong, **3 test case máy thật chưa chạy** (`.plan/P1F-result.md`). Từ **P4** có thêm `Stream<bool> speakingChanges` — tín hiệu để tầng phiên chặn chunk vào ASR khi đang phát (half-duplex): `.project/modules/pipeline-integration.md` |
| P1G | Emergency Phrase (local, tách khỏi luồng LLM) |
| ✅ P3 | `output_mode_selector.dart` (3 chế độ: tai nghe / rung / chữ + tốc độ đọc 0.9–1.2x) + `nudge_delivery.dart` (nơi **giao** nudge: đọc/rung/chữ). Code xong, **chưa verify trên máy** (K42) |

Trạng thái hiện tại: `app_audio_session.dart` (P0.5) + `capture/` (P1A) + `vad/` (P1B) + `asr/` (P1C/P1D)
+ `tts/` (P1F, 3 file Dart bọc 1 file Kotlin) + `emergency/` (P1G) + 2 file output mode/nudge delivery (P3).
Chi tiết an toàn TTS: `.project/modules/tts-safety.md`. Tầng kích hoạt + chế độ hiển thị:
`.project/modules/trigger-and-output.md`.

**Ràng buộc kiến trúc bắt buộc (đừng vi phạm khi thêm code vào đây):**
- Mic thu là **mic điện thoại**; tai nghe Bluetooth **chỉ để phát** (A2DP một chiều). Không dùng
  usage `voiceCommunication` — nó kéo hệ thống sang HFP/SCO và hạ chất lượng audio.
- Chiều thu phải chạy **100% offline**; không có phương án cloud ASR nào cho luồng nghe realtime
  (cloud chỉ dùng ở Post-Review P5, và chỉ khi có Wi-Fi).
- Từ P1F trở đi, mọi lệnh phát âm thanh **phải** đi qua `SafeTtsOutput`, không gọi TTS trực tiếp.
  Kiểm nhanh: `grep -rn "\.speak(" lib/` — chỉ được thấy trong `tts/safe_tts_output.dart` và nơi gọi
  `SafeTtsOutput` (hiện là `nudge_delivery.dart`, `emergency/emergency_phrase_service.dart` và nút đọc
  thử trên màn hình chẩn đoán).
- Chế độ output **Ear** phải tự hạ xuống **chữ** khi không có tai nghe
  (`OutputModeSelector.effectiveMode`) — tuyệt đối không "thử phát cho chắc".
- Tốc độ đọc TTS chỉ được nằm trong 0.9x–1.2x, kẹp ở **cả** Dart (`OutputConfig.clampSpeechRate`)
  và Kotlin (`SafeTtsBridge`); sai tham số chất lượng KHÔNG được phép làm hỏng việc phát.
