# Module: audio-capture (P1A)

Trạng thái: 🟡 **code xong, CHƯA xác minh trên máy thật** (0/5 mục DoD — xem `.plan/P1A-result.md`).
Đây **không** phải tính năng sản phẩm cuối: phase này chỉ thu PCM thô. VAD/ASR là P1B/P1C/P1D.

## 1. Mục đích

Ghi âm liên tục từ **mic điện thoại**, ổn định, chạy nền được lâu (45–60 phút+), **không phụ thuộc
trạng thái Bluetooth**, và phơi ra **một** `Stream<Uint8List>` PCM16 mono cho các phase sau dùng lại.

## 2. Kiến trúc (đọc trước khi sửa)

```
UI (HomeScreen) ─┐
                 ├─► AudioCaptureController ──► CaptureClient ──► [MethodChannel/EventChannel]
Service isolate ─┘        (Dart, broadcast)      (NativeCaptureClient)        │
   (P1B sẽ dùng)                                                             ▼
                                                        MicCaptureEngine (Kotlin, AudioRecord MIC)
                                                        + CaptureChannelBridge (kênh, 1 engine dùng chung)
```

- **Một** `AudioRecord` cho cả process; kênh được đăng ký cho **nhiều** FlutterEngine (engine UI trong
  `MainActivity`, engine service qua `ForegroundService.addTaskLifecycleListener`) — mỗi engine một sink.
- Không có listener ⇒ **bỏ** chunk (không buffer, không ghi file).

## 3. File & API

| File | Vai trò |
|---|---|
| `lib/audio/capture/capture_config.dart` | `CaptureConfig` (16kHz/mono/PCM16/chunkMs=100), `CaptureStatus`, `sealed CaptureError` (+3 subclass) |
| `lib/audio/capture/capture_engine.dart` | Hợp đồng `AudioCaptureEngine` (bằng văn bản: chunk là bản copy riêng, lỗi không qua stream, `onError` một-handler, start/stop idempotent, `stop()`→`start()` lại được) |
| `lib/audio/capture/capture_client.dart` | Interface `CaptureClient` (để test bằng fake) |
| `lib/audio/capture/capture_channels.dart` | Tên kênh + `NativeCaptureClient` (gọi native, parse cấu hình, map lỗi) |
| `lib/audio/capture/audio_capture_controller.dart` | `AudioCaptureController` (facade, broadcast stream) + `AudioCapture.instance` (lazy) + `mapPlatformCode()` |
| `lib/audio/capture/wav_sink.dart` | `WavSink` — **chỉ để kiểm tra thủ công** (nghe lại chất lượng), opt-in, phải xoá file sau |
| `android/.../audio/MicCaptureEngine.kt` | `AudioRecord` + `AudioSource.MIC`, thread `URGENT_AUDIO`, buffer 2× min |
| `android/.../audio/CaptureChannelBridge.kt` | Đăng ký kênh, dispatch chunk/lỗi, sink riêng từng engine |

Kênh (phải khớp 2 phía):
- `com.aiassistant.phone/audio_capture` — `start`/`stop`/`dispose` (Dart→native), `error` (native→Dart).
- `com.aiassistant.phone/audio_capture_pcm` — `ByteArray` PCM16 mono (native→Dart).

Lỗi native: code `PERMISSION_DENIED` / `UNAVAILABLE` (khi mở mic) / `CAPTURE_FAILED` (giữa lúc ghi).

## 4. API endpoints

Không có. **Không** gửi audio đi đâu — ràng buộc cứng #4.

## 5. Local storage

**Không ghi gì mặc định.** Audio chỉ nằm trong RAM. `WavSink` là ngoại lệ **thủ công** (DoD P1A).

## 6. Test

`test/audio_capture_test.dart` — 20 test: config/`chunkBytes` math, `mapPlatformCode`, lifecycle
(start no-op khi đang chạy, chunk trước start/sau stop bị bỏ, start lại sau stop), lỗi (map
`PlatformException`, lỗi runtime → `onError`+`errors`+status, onError chỉ 1 handler), dispose, và
hợp đồng kênh thật qua mock MethodChannel. Smoke test đã thêm stub 2 kênh mới.

## 7. Việc còn thiếu

- [ ] ⚠ **Toàn bộ 5 mục DoD đều chưa đo được trên máy thật** (60 phút nền, `dumpsys audio` HFP/SCO,
      rút/tắt tai nghe giữa chừng, nghe lại `.wav`, luồng từ chối quyền trên UI). Cần APK + thiết bị.
- [ ] **Mã Kotlin chưa từng được biên dịch** (máy dev không có Android SDK) — rủi ro nằm ở đây.
- [ ] P1B: đưa VAD vào isolate của service + chốt lại `chunkMs` (20–30ms?).
- [ ] `permanentlyDenied` chưa có đường thoát (không `openAppSettings()`).

## 8. Cảnh báo khi sửa — ⚠ đọc trước

1. **KHÔNG đổi `AudioSource.MIC`** sang `VOICE_COMMUNICATION`/`VOICE_RECOGNITION`: hai nguồn đó kéo
   SCO/HFP, hạ chất lượng và buộc đi qua Bluetooth khi tai nghe đang kết nối (vi phạm ràng buộc #1/#2).
2. **KHÔNG gọi `AudioManager.startBluetoothSco()` / `setMode()`** ở tầng này. Luồng thu phải độc lập
   hoàn toàn với trạng thái tai nghe — đây chính là điều kiện DoD.
3. **KHÔNG ghi audio ra file mặc định.** Chỉ `WavSink` (thủ công) được ghi, và phải xoá sau khi kiểm.
4. **KHÔNG thêm VAD/ASR/xử lý audio vào tầng này** (thuộc P1B/P1C/P1D). Tầng capture chỉ phát chunk thô.
5. **Chunk phát ra phải là bản copy riêng** (`buffer.copyOf()`) — buffer native được tái sử dụng cho
   khung sau; giữ tham chiếu vào buffer gốc sẽ cho dữ liệu rác.
6. **`stop()` của `MicCaptureEngine` không được gọi từ thread đọc** (nó `join` chính thread đó) — dùng
   `releaseRecorder()` như nhánh lỗi đang làm.
7. **Mỗi engine phải có sink riêng** (`PcmSinkHolder`): dùng chung một set sẽ làm engine này ngừng nghe
   → xoá luôn listener của engine kia (lỗi đã từng mắc, đã sửa).
8. Chạm tầng này = chạm **vùng loại trừ Ponytail** (audio routing, an toàn) ⇒ không tự commit.
