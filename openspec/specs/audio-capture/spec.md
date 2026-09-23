# audio-capture Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P1A + rà lỗi P4). Không phải đề xuất.
> Nguồn sự thật: `lib/audio/capture/`, `android/app/src/main/kotlin/com/aiassistant/phone/capture/`,
> `test/audio_capture_test.dart`, `.project/modules/audio-capture.md`.

## Purpose

Thu âm từ **mic điện thoại** (`AudioSource.MIC`) thành luồng PCM16 mono 16kHz cho toàn bộ các tầng
xử lý phía sau (VAD P1B, ASR P1C/P1D). Capture là nguồn duy nhất của audio trong app: mọi tầng khác
**tiêu thụ** luồng này, không mở recorder riêng.

Quyết định kiến trúc: engine Kotlin chạy trong tiến trình app, được foreground service (P0.5) giữ
sống khi ra nền; một engine dùng chung, mỗi FlutterEngine có sink riêng (tránh mất listener của
engine kia khi một engine hủy đăng ký).

## Requirements

### Requirement: Cấu hình thu chuẩn

Engine thu **PHẢI (MUST)** dùng `AudioSource.MIC`, 16kHz, mono, PCM16 (đúng chuẩn đầu vào của
PhoWhisper/Vosk — `lib/audio/capture/capture_config.dart`). KHÔNG ĐƯỢC đổi nguồn thu sang mic tai
nghe (ràng buộc cứng #2 của app).

#### Scenario: Thu bằng mic điện thoại

- **GIVEN** capture đã được bật sau khi có quyền `RECORD_AUDIO`
- **WHEN** kiểm `dumpsys audio` trên máy thật
- **THEN** session thu hiện `source client=MIC, 16000Hz` thuộc package `com.aiassistant.phone` (bằng chứng buổi test adb 2026-09-23)

### Requirement: Vòng đời start/stop đối xứng

`AudioCaptureController` **PHẢI (MUST)**: `start()` mở mic qua bridge Kotlin, `stop()` dừng và join
thread đọc **theo trạng thái thread** (không dựa vào cờ nghiệp vụ — sửa A56/K47), `dispose()` giải
phóng tài nguyên và không ném.

#### Scenario: Lỗi mic giữa lúc thu

- **GIVEN** capture đang chạy và thread đọc gặp lỗi (đã tự đặt cờ dừng)
- **WHEN** `stop()` được gọi ngay sau đó
- **THEN** thread được join an toàn, VAD/native KHÔNG bị đóng dưới chân thread còn chạy; lỗi được báo qua stream lỗi cho tầng trên phục hồi (P4), không crash tiến trình

#### Scenario: Recorder không bị nhả nhầm

- **GIVEN** engine đang khởi động lại sau lỗi (recorder MỚI đã tạo)
- **WHEN** nhánh lỗi của lượt CŨ chạy `releaseRecorder`
- **THEN** chỉ recorder thuộc chủ sở hữu của lượt đó bị nhả (sửa A54 — field dùng chung không còn là nguồn sự thật)

### Requirement: Phát luồng chunk cho sink

Luồng PCM **PHẢI (MUST)** phát qua EventChannel tới Dart theo chunk; khi không còn listener, native
giữ trạng thái nhưng KHÔNG phát chunk vô ích. `WavSink` chỉ là tiện ích kiểm thử thủ công — KHÔNG
được nối vào đường sản phẩm (app KHÔNG ghi audio ra đĩa — ràng buộc #4).

#### Scenario: Chunk tới nhiều tầng

- **GIVEN** capture đang chạy và cả VAD client lẫn session controller đã lắng nghe
- **WHEN** một chunk PCM được thu
- **THEN** cả hai nhận cùng luồng dữ liệu để xử lý độc lập (VAD khung 20ms ở native, ASR gom chunk ở Dart)
