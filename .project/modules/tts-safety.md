# Module: TTS safety (`SafeTtsOutput`) — P1F

> Nguồn sự thật: `lib/audio/tts/*` + `android/app/src/main/kotlin/com/aiassistant/phone/tts/SafeTtsBridge.kt`.
> Trạng thái: 🟡 **code xong + 21 unit test pass; 3 test case bắt buộc trên máy thật CHƯA chạy**
> (xem `.plan/P1F-result.md`). **Phase an toàn quan trọng nhất của app** — đọc hết file này trước khi sửa.

## 1. Vì sao module này tồn tại

Nếu nudge (gợi ý) lọt ra loa ngoài, người đối diện nghe được toàn bộ nội dung app đang gợi ý cho
người dùng ⇒ phá hỏng mục đích app và có thể gây hại thật (`plan_final_v2.md` mục 4.2c/4.8).
Vì vậy đây là module duy nhất của app được viết theo tinh thần **fail-safe**: lỗi ⇒ **không phát gì**,
khác hẳn các module khác (lỗi ⇒ log rồi chạy tiếp — `operating_rules.md` rule 10).

## 2. Kiến trúc

```
UI / tầng trên (P2/P3)
      │  speak(text) · confirmHeadsetReady() · stop() · fallbacks (stream)
      ▼
SafeTtsOutput            lib/audio/tts/safe_tts_output.dart   ← CỔNG DUY NHẤT được phát âm thanh
      │  TtsClient (interface, test được bằng bản giả)
      ▼
NativeTtsClient          lib/audio/tts/tts_channels.dart      ← MethodChannel com.aiassistant.phone/tts
      │
      ▼
SafeTtsEngine (Kotlin)   android/.../tts/SafeTtsBridge.kt
      ├── AudioManager.getDevices(GET_DEVICES_OUTPUTS)   ← đọc TƯƠI mỗi lần quyết định phát
      ├── AudioDeviceCallback (registerAudioDeviceCallback) ← biết tai nghe ra/vào theo thời gian thực
      ├── TextToSpeech.synthesizeToFile(...)             ← CHỈ tổng hợp ra file, KHÔNG tự phát
      └── AudioTrack + setPreferredDevice(a2dpDevice)    ← route TƯỜNG MINH, USAGE_MEDIA
```

Vì sao **không** dùng `TextToSpeech.speak()`: nó để hệ điều hành tự chọn route; khi tai nghe mất,
Android chuyển route media về **loa ngoài** ⇒ đúng thứ phải chặn. Cách của module: tự phát PCM qua
`AudioTrack` đã trỏ tường minh tới thiết bị tai nghe.

## 3. Hợp đồng kênh native (`com.aiassistant.phone/tts`)

| Chiều | Method | Ý nghĩa |
|---|---|---|
| Dart → native | `outputState` | Trả `{hasPrivateOutput, preferred, devices[]}` — **đọc tươi**, không cache |
| Dart → native | `speak {text}` | `"synthesizing"` (đã bắt đầu tổng hợp) · `"noHeadset"` (từ chối + đã rung) · `"error:<chi tiết>"` |
| Dart → native | `stop` | Trả `true` nếu trước đó thực sự đang phát/tổng hợp |
| Dart → native | `vibrateFallback` | Rung 1 nhịp ngắn khi **Dart** tự phát hiện không có tai nghe (khi đó native không được gọi `speak`) |
| native → Dart | `event {type, …}` | `headsetFound` · `headsetLost` · `spoke` · `error` |

Sự kiện native→Dart đi qua **messenger đăng ký đầu tiên** (engine UI — `MainActivity.configureFlutterEngine`).
Kênh CHỈ được đăng ký cho engine UI ở P1F; nếu P3/P4 cần phát TTS từ isolate của service thì phải đổi
cách chọn messenger (xem mục 7).

## 4. Bất biến an toàn (test nào khoá cái nào)

| # | Bất biến | Ở đâu |
|---|---|---|
| A1 | Không có tai nghe ⇒ **không gọi** native `speak` (chỉ rung + nudge chữ) | `safe_tts_output.dart` bước 3 · test `speak() khi KHÔNG có tai nghe…` |
| A2 | Đọc trạng thái thiết bị lỗi ⇒ coi như **không có tai nghe** | `refresh()` catch · test `đọc trạng thái thiết bị LỖI…` |
| A3 | Native trả `noHeadset` (Dart đọc trước đó đã cũ) ⇒ chuyển im lặng | test `native trả "noHeadset"…` |
| A4 | Lỗi/giá trị lạ từ native ⇒ `failed`, **không thử lại** | test `trả giá trị lạ` / `ném exception` |
| A5 | Mất tai nghe giữa chừng ⇒ native dừng ngay + Dart vào im lặng + gọi `stop()` lần 2 | test `headsetLost: im lặng ngay…` |
| A6 | Kết nối lại ⇒ **không tự phát lại**, phải `confirmHeadsetReady()` | test `headsetFound (kết nối lại)…` |
| A7 | File tổng hợp xong muộn (sau khi stop/mất tai nghe) **không** được phát | Kotlin `generation` token (`onDone` so thế hệ) |
| A8 | `setPreferredDevice` bị từ chối ⇒ **không phát** | Kotlin `playSynthesized()` |
| A9 | Sự kiện native sai dạng ⇒ coi là `headsetLost` (không bỏ qua) | `eventFromNative()` · test `sự kiện sai dạng…` |
| A10 | Không dùng `USAGE_VOICE_COMMUNICATION` / `setCommunicationDevice` (kéo HFP/SCO) | Kotlin `AudioAttributes` builder · rà bằng grep |

## 5. Quy tắc bắt buộc khi sửa module này

1. **Mọi** phát âm thanh của app phải qua `SafeTtsOutput`. Kiểm bằng:
   `grep -rn "\.speak(" lib/` ⇒ chỉ được thấy trong `safe_tts_output.dart` (gọi client) và nơi gọi
   `SafeTtsOutput`.
2. Không thêm nhánh nào có thể phát khi trạng thái không chắc chắn (kể cả "thử phát rồi xem sao").
3. Sửa bất kỳ dòng nào trong đường phát ⇒ chạy lại 3 test case bắt buộc trên máy thật (mục 6).
4. Đây là **vùng loại trừ Ponytail** (`operating_rules.md` rule 15): không tự commit, phải trình bày
   và chờ người dùng xác nhận.

## 6. Cách verify trên máy thật (3 test case bắt buộc)

```bash
adb logcat -c && adb logcat -s SafeTts:V flutter:V | tee /tmp/p1f_run.log
adb shell dumpsys audio | grep -iE "a2dp|sco|route|ForceUse"    # bằng chứng route không đổi sang SCO
```
1. Rút tai nghe **giữa lúc đang đọc** ⇒ mong đợi: `MẤT thiết bị riêng tư` + `đã DỪNG phát TTS` +
   rung 2 nhịp, **không** nghe gì từ loa ngoài.
2. Rút tai nghe **đúng lúc chuẩn bị đọc** ⇒ mong đợi: `không có tai nghe ⇒ KHÔNG phát TTS` + rung 1
   nhịp, không có AudioTrack nào được tạo.
3. **Tắt Bluetooth** trong Cài đặt giữa lúc đang đọc ⇒ hành vi như (1).

## 7. Hạn chế đã biết / việc chưa làm (đừng tưởng nhầm đã có)

- **Không phân biệt được tai nghe A2DP với loa Bluetooth A2DP** (cùng `TYPE_BLUETOOTH_A2DP`). Nếu
  người dùng kết nối loa BT, app coi đó là "riêng tư". Việc chọn thiết bị nào là ở Cài đặt Bluetooth.
- **Rung dùng `Vibrator` của hệ thống** với 2 nhịp khác nhau (1 nhịp = không có tai nghe, 2 nhịp =
  vừa mất tai nghe). Không phải "pattern" tuỳ biến sâu hơn.
- **Half-duplex CHƯA làm ở đây** (ràng buộc #5 của `.project/overview.md`): module không giữ tham
  chiếu tới tầng capture, nên chưa chặn "đang thu mà phát TTS". Việc ghép thu/phát là P4.
- **Nudge chữ hiện chỉ hiện trên màn hình chẩn đoán** (SnackBar + dòng `TTS`); notification thật là P3.
- **TTS chỉ chạy ở engine UI**: nếu app ở nền mà cần phát (P3/P4), phải đổi cách chọn messenger.
- Chưa xác minh được trên máy thật lần nào (xem `.plan/P1F-result.md`).
