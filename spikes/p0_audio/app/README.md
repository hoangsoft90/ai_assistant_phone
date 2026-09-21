# p0_spike — app Flutter thăm dò của Phase 0

App này là **code throwaway**: chỉ để trả lời go/no-go cho pipeline audio (mic điện thoại thu +
ASR offline + TTS chỉ ra tai nghe). Sẽ KHÔNG mang sang P0.5.

Đọc trước: `../README.md` (trạng thái P0, số liệu baseline trên host, protocol test trên máy thật,
cách đẩy model vào điện thoại).

Điểm cần biết khi đọc code:

- Toàn bộ audio/ASR nằm ở Kotlin/native (`android/app/src/main/kotlin/...`), Flutter (`lib/main.dart`)
  chỉ là màn hình điều khiển + log. Đây là hướng sẽ dùng ở P1A/P1C nên phần kiểm chứng được có thể tái sử dụng.
- Ghi âm dùng `AudioRecord` với `AudioSource.MIC` (mic điện thoại, KHÔNG dùng `VOICE_COMMUNICATION`)
  — cố tình như vậy để tránh kéo route Bluetooth sang HFP/SCO (mục 4.2a của kế hoạch).
- `TtsTest` gọi `TextToSpeech` trực tiếp: ở P0 là chủ ý (cần đo hành vi thật của Android khi rút
  tai nghe). Từ P1F trở đi, mọi phát âm thanh PHẢI đi qua `SafeTtsOutput` — không dùng lại file này.
- Model ASR không nằm trong APK; app đọc từ thư mục riêng của nó (UI hiện đường dẫn tuyệt đối),
  đẩy vào bằng `adb push` theo hướng dẫn ở `../README.md`.

Lệnh hay dùng:

```bash
flutter analyze
flutter test
flutter build apk --release    # build trên CI, máy dev này không cài Android SDK
adb logcat -s P0Spike:I P0SpikeJni:I
```
