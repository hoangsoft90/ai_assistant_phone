# pipeline-session Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P4 + rà lỗi native).
> Nguồn sự thật: `lib/services/conversation_session_controller.dart`,
> `android/.../{tts,asr,capture,vad}/*.kt`, `test/conversation_session_controller_test.dart`,
> `.project/modules/pipeline-integration.md`.

## Purpose

Orchestrator duy nhất ghép toàn bộ pipeline thành **một phiên hội thoại half-duplex thật**: service →
capture → VAD → ASR (mở đúng thứ tự, tắt ngược lại); chặn chunk vào ASR khi TTS đang phát (ràng buộc
#5 half-duplex); phục hồi từng module khi lỗi (mic chết, engine ASR fail, trigger lỗi) mà không bao
giờ ném ra UI. Cung cấp SỐ đo trên dòng `Phiên (P4)` làm bằng chứng DoD trên máy thật.

## Requirements

### Requirement: Vòng đời phiên đối xứng

`start()` **PHẢI (MUST)** mở theo thứ tự: service → capture → VAD → (ASR bật riêng bằng
`startAsr()`); `stop()` **PHẢI (MUST)** tắt đúng thứ tự NGƯỢC LAI (ASR → VAD → capture → service) —
thứ tự này là ràng buộc của app (rule 9: không đổi khởi tạo trong `main()`, không thêm audio vào
`onRepeatEvent`). `dispose()` chỉ giải phóng lớp điều phối, KHÔNG dừng service/capture (app nghe tiếp
khi ra nền — `stopWithTask: false`).

#### Scenario: Bật rồi tắt phiên

- **GIVEN** app đang ở trạng thái sẵn sàng
- **WHEN** người dùng bấm "Bật lắng nghe" rồi "Tắt lắng nghe"
- **THEN** các module mở/đóng đủ và đúng thứ tự; FGS xuất hiện rồi biến mất (bằng chứng buổi test adb 2026-09-23: ServiceRecord có khi nghe, 0 sau khi đổi engine/tắt)

#### Scenario: Đổi engine khi đang nghe

- **GIVEN** phiên đang chạy với ASR bật
- **WHEN** người dùng chọn engine khác ở dropdown
- **THEN** phiên tắt hẳn theo đúng chuỗi stop, config engine mới được ghi; app KHÔNG tự bật lại — người dùng bấm "Bật lắng nghe" để chạy lại (bằng chứng buổi test adb 2026-09-23 + SnackBar "Đã đổi engine. Bấm Bật lắng nghe để chạy lại.")

### Requirement: Half-duplex thi hành thật

Controller **PHẢI (MUST)**: nghe `SafeTtsOutput.speakingChanges`; khi `true` ⇒ chặn chunk vào ASR
(đếm `chunksDroppedWhileSpeaking`), khi `false` ⇒ mở lại ASR (đếm `asrResumeCount`). Push khi đang
phát ⇒ BỎ QUA (đếm `overlapPreventedCount`) — không cắt câu đang đọc giữa từ, KHÔNG có cooldown.
Emergency KHÔNG bị chặn bởi cửa này (đường khẩn P1G).

#### Scenario: Đang phát thì không thu

- **GIVEN** phiên đang nghe + ASR bật
- **WHEN** TTS bắt đầu phát một nudge rồi kết thúc
- **THEN** chunk bị chặn trong lúc phát (số tăng), ASR nhận lại đúng 1 lần sau khi phát xong; transcript KHÔNG chứa text từ giọng đọc của máy (bằng chứng số trên dòng `Phiên (P4)` — chờ verify tai/mắt trên máy)

### Requirement: Phục hồi từng module, không ném

Lỗi mic / cả 2 engine ASR fail / feed lỗi 3 lần liên tiếp / trigger lỗi lạ **PHẢI (MUST)** được xử lý
trong controller: restart tối đa 2 lần rồi hạ cấp (tắt ASR, giữ nghe), báo qua `notices` cho UI;
`push()`/`stop()` không bao giờ ném. Số `recoveryCount` ghi lại số lần phục hồi trong phiên.

#### Scenario: Mic chết giữa phiên

- **GIVEN** phiên đang chạy và capture báo lỗi
- **WHEN** controller xử lý lỗi
- **THEN** module liên quan được restart tối đa 2 lần; nếu vẫn lỗi thì hạ cấp an toàn + thông báo cho người dùng — tiến trình KHÔNG chết (cùng họ các fix K47/A55/A56 ở native)

### Requirement: Số đo phiên là bằng chứng

Controller **PHẢI (MUST)** giữ số đo per-session (reset đầu mỗi phiên — `_resetSessionCounters`):
`chunksDroppedWhileSpeaking`, `asrResumeCount`, `overlapPreventedCount`, `averagePushLatency`
(trigger → native bắt đầu tổng hợp, cùng định nghĩa P1G), `sessionStartedAt`, `recoveryCount` — và
phase suy ra từ trạng thái THẬT (idle/listening/processing/speaking), KHÔNG lưu phase song song.

#### Scenario: Đọc bằng chứng sau phiên dài

- **GIVEN** một phiên ≥ 30 phút với nhiều lần Push trong khi TTS phát
- **WHEN** người dùng đọc dòng `Phiên (P4)` (kèm mốc `từ HH:MM`)
- **THEN** các số phản ánh đúng PHIÊN ĐÓ (không tích tụ từ các phiên trước)
