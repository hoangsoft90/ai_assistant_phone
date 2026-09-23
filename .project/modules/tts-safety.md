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
      ├── ACTION_AUDIO_BECOMING_NOISY (receiver)         ← lớp DỪNG SỚM NHẤT (hệ thống bắn TRƯỚC khi đổi route)
      ├── AudioDeviceCallback (registerAudioDeviceCallback) ← lớp bảo hiểm: biết tai nghe ra/vào (cả có dây & BT)
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
| Dart → native | `speak {text, rate?}` | `"synthesizing"` (đã bắt đầu tổng hợp) · `"noHeadset"` (từ chối + đã rung) · `"error:<chi tiết>"`. `rate` là khoá **tuỳ chọn** của P3 (tốc độ đọc 0.9–1.2x, kẹp ở cả hai phía); thiếu khoá ⇒ không đụng tốc độ |
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
| A5b | Dừng ở 2 lớp: `becomingNoisy` (sớm nhất, trước khi route đổi) + `AudioDeviceCallback` (bảo hiểm, phủ cả Bluetooth) | Kotlin `noisyReceiver` + `onAudioDevicesRemoved` |
| A6 | Kết nối lại ⇒ **không tự phát lại**, phải `confirmHeadsetReady()` | test `headsetFound (kết nối lại)…` |
| A7 | File tổng hợp xong muộn (sau khi stop/mất tai nghe) **không** được phát | Kotlin `generation` token (`onDone` so thế hệ) |
| A8 | `setPreferredDevice` bị từ chối ⇒ **không phát** | Kotlin `playSynthesized()` |
| A9 | Sự kiện native sai dạng ⇒ coi là `headsetLost` (không bỏ qua) | `eventFromNative()` · test `sự kiện sai dạng…` |
| A10 | Không dùng `USAGE_VOICE_COMMUNICATION` / `setCommunicationDevice` (kéo HFP/SCO) | Kotlin `AudioAttributes` builder · rà bằng grep |
| A11 | Tốc độ đọc sai/hỏng (ngoài 0.9–1.2, `NaN`, sai kiểu) **không** được làm hỏng việc phát — chỉ kẹp hoặc bỏ qua | `OutputConfig.clampSpeechRate` + Kotlin `speak()`/`coerceIn` · test `giá trị NGOÀI khoảng bị kẹp…` |

## 5. Quy tắc bắt buộc khi sửa module này

1. **Mọi** phát âm thanh của app phải qua `SafeTtsOutput`. Kiểm bằng:
   `grep -rn "\.speak(" lib/` ⇒ chỉ được thấy trong `safe_tts_output.dart` (gọi client) và nơi gọi
   `SafeTtsOutput` (`nudge_delivery.dart`, `emergency/emergency_phrase_service.dart`, nút đọc thử trên
   màn hình chẩn đoán).
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

Với tai nghe có dây, log của test case 1 sẽ đi qua **`becomingNoisy`** trước (rồi mới tới
`MẤT thiết bị riêng tư` nếu hệ thống cập nhật danh sách thiết bị).
3. **Tắt Bluetooth** trong Cài đặt giữa lúc đang đọc ⇒ hành vi như (1).

## 7. Hạn chế đã biết / việc chưa làm (đừng tưởng nhầm đã có)

- **Không phân biệt được tai nghe A2DP với loa Bluetooth A2DP** (cùng `TYPE_BLUETOOTH_A2DP`). Nếu
  người dùng kết nối loa BT, app coi đó là "riêng tư". Việc chọn thiết bị nào là ở Cài đặt Bluetooth.
- **Rung dùng `Vibrator` của hệ thống** với 2 nhịp khác nhau (1 nhịp = không có tai nghe, 2 nhịp =
  vừa mất tai nghe). Không phải "pattern" tuỳ biến sâu hơn.
- **Half-duplex: P4 đã làm — nhưng ở TẦNG KHÁC, không phải ở đây.** Module này chỉ *báo tin*:
  `Stream<bool> speakingChanges` (phát `true` ngay khi native nhận yêu cầu tổng hợp, `false` khi native
  báo `spoke`). Việc chặn chunk ASR nằm ở `lib/services/conversation_session_controller.dart`. Lý do tách:
  module này không được giữ tham chiếu tới tầng capture (ràng buộc #5) — và cũng không nên, vì đó là
  quan hệ **một chiều** (TTS báo, phiên quyết định).
- **K45 (P4 phát hiện): tài nguyên WAV "có nhiều thế hệ" từng bị giữ bằng MỘT field dùng chung ⇒ câu mới
  IM LẶNG — ĐÃ SỬA ở tầng code (chờ verify máy).** Cơ chế cũ: `SafeTtsBridge` giữ **một field** `tempWav`
  cho file của lần phát hiện tại, trong khi file đặt tên theo *thế hệ* (`tts_<gen>.wav`) và mọi lần phát
  chạy trên cùng một thread (`player`) ⇒ `speak()` mới (`generation++`) làm thread của lần CŨ thoát ngay,
  `finally { cleanTemp() }` của nó xoá `tempWav` — tức **file của câu MỚI** ⇒ vài trăm ms sau câu mới thấy
  `tempWav == null` và **không phát gì** (`không có file WAV để phát`). TTS tổng hợp luôn lâu hơn thời gian
  thread cũ thoát ⇒ gần như **tất định**, không phải race hiếm. Ảnh hưởng trực tiếp: **Emergency Phrase
  (câu thoát hiểm) khi đang đọc nudge có thể không kêu**.
  - Cách sửa (đang dùng, 4 điểm trong `SafeTtsBridge.kt`): **tên file là hàm của số thế hệ**
    (`wavFor(gen)`) và **không chỗ nào đọc field dùng chung để biết mình sở hữu gì**: `playSynthesized`
    lấy `val wav = wavFor(gen)`, `finally` gọi `cleanTemp(wav)`; `cleanTemp(file)` **chỉ null field nếu
    field vẫn `===` file đó**; `onError` dùng `cleanTempOfGeneration(utteranceId)` (suy thế hệ từ
    `utteranceId` — lỗi của thế hệ cũ có thể tới sau khi đã có file mới).
  - ⚠️ **Khi sửa module này:** bất kỳ tài nguyên nào gắn với một "lần chạy" (file WAV, track, request id)
    **không được** tra cứu gián tiếp qua state dùng chung; cleanup phải xoá **đúng đối tượng mình sở hữu**.
    Dấu hiệu để nghi ngờ ngay khi review: thấy `finally { cleanTemp() }` (cleanup chung) ở chỗ có thể đã có
    lần chạy mới ghi vào cùng field — và phải rà **hết** call-site, không chỉ chỗ đang sửa (bài học A54).
  - ⚠️ Chưa xác nhận trên máy thật: phép thử là **giữ nút nổi 2 giây đúng lúc đang đọc nudge** ⇒ phải nghe
    thấy câu thoát hiểm, và log **không** được có `không có file WAV để phát` (xem `.plan/P4-result.md` bước 7).
- **Nudge chữ hiện chỉ hiện trên màn hình chẩn đoán** (SnackBar + dòng `TTS`/`Gợi ý`); kênh hiển
  thị thật (overlay/notification) chưa có — nợ **K43**.
- **TTS chỉ chạy ở engine UI**: nếu app ở nền mà cần phát (P4/K43), phải đổi cách chọn messenger.
- **Tốc độ đọc (P3) chưa verify trên máy**: `setSpeechRate` đã nối tới native nhưng chưa xác nhận
  giọng đọc thật sự đổi ở 0,9x/1,2x (nợ **K41**). Lưu ý `setSpeechRate` là **cấu hình dính** của
  engine: đường Emergency gọi `speak(text, rate=null)` nên nó giữ tốc độ của lần đọc trước đó.
- **Đã xác minh MỘT PHẦN trên máy thật (2026-09-22)**: phát đầu-cuối ✅ (user nghe rõ), phát hiện
  mất tai nghe + rung 2 nhịp ✅; **còn** rút-giữa-lúc-đang-phát, TC2, TC3 (nợ **K34**), và phát hiện
  **K37** (đòi xác nhận mỗi lần mở app khi tai nghe đã cắm sẵn). Chi tiết: `.plan/P1F-result.md`.
