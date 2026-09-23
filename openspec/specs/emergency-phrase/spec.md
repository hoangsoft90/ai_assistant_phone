# emergency-phrase Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P1G + nút nổi giữ 2s của P3).
> Nguồn sự thật: `lib/audio/emergency/emergency_phrase_service.dart`, `emergency_phrases.dart`,
> `lib/ui/floating_button.dart`, `lib/core/constants.dart` (TriggerConfig.emergencyHold),
> `test/emergency_phrase_service_test.dart`, `test/floating_button_test.dart`.

## Purpose

Câu thoát hiểm: người dùng đang bối rối trong hội thoại thật cần một câu "cứu" phát ra tai nghe
NGAY. Đường khẩn cấp đi THẲNG `EmergencyPhraseService → SafeTtsOutput` — KHÔNG qua Policy/LLM/
debounce của đường Push (P2/P3), KHÔNG bị chặn bởi Training Level 4/5 (P5), KHÔNG có dialog xác nhận.

## Requirements

### Requirement: Đường khẩn không qua Policy/LLM

`triggerEmergency()` **PHẢI (MUST)** gọi thẳng `SafeTtsOutput.speak()` — không gọi LLM, không qua
`SuggestionPolicy`, không qua `TriggerManager` debounce. Số đo latency `lastTriggerToSynthLatency`
(trigger → native bắt đầu tổng hợp) phải được ghi để theo dõi DoD.

#### Scenario: Kích hoạt giữa lúc mọi tầng khác bận

- **GIVEN** TTS đang đọc một nudge (hoặc LLM đang chờ phản hồi)
- **WHEN** Emergency được kích hoạt
- **THEN** câu thoát hiểm được tổng hợp/phát theo thế hệ mới của SafeTtsOutput, latency được ghi; KHÔNG chờ nudge hay Policy

### Requirement: Xoay vòng câu

Danh sách câu (3 câu cấu hình trong `emergency_phrases.dart`) **PHẢI (MUST)** phát xoay vòng dự
đoán được: lần kích hoạt kế tiếp dùng câu kế tiếp, không lặp liền, không random; câu rỗng bị lọc bỏ
khi khởi tạo; danh sách rỗng ⇒ kết quả `noPhrases` không ném.

#### Scenario: Ba lần kích hoạt liên tiếp

- **GIVEN** service với 3 câu hợp lệ
- **WHEN** kích hoạt 3 lần liên tiếp
- **THEN** câu phát lần lượt theo thứ tự vòng tròn; `nextPhrase` luôn cho biết câu kế tiếp

### Requirement: Cử chỉ giữ đúng 2 giây

Nút nổi **PHẢI (MUST)** dùng `LongPressGestureRecognizer(duration: TriggerConfig.emergencyHold = 2s)`
(vì sao: `GestureDetector` khoá cứng ~500ms; tự đếm Timer lệch +100ms do `onTapDown` bắn sau
`kPressTimeout` — bình luận `floating_button.dart:10-15`). Nhả trước 2s ⇒ chỉ Push; đủ 2s ⇒
Emergency MỘT lần và nhả tay sau đó KHÔNG chạy thêm Push; kéo tay ra ngoài ⇒ không gọi gì.

#### Scenario: Phân biệt giữ dài với tap

- **GIVEN** nút nổi hiển thị và nhận cử chỉ
- **WHEN** người dùng giữ đủ 2 giây rồi nhả
- **THEN** Emergency kích hoạt đúng 1 lần, không có Push kế theo; giữ 1 giây rồi nhả thì chỉ có Push
