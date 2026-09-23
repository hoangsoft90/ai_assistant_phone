# conversation-vad Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P1B + F2/F4 từ review). Không phải đề xuất.
> Nguồn sự thật: `lib/audio/vad/conversation_state.dart`, `conversation_state_notifier.dart`,
> `vad_client.dart`, `android/.../vad/VadDetector.kt`, `test/conversation_state_test.dart`,
> `.project/modules/conversation-state.md`.

## Purpose

Phát hiện "đang có người nói" từ luồng PCM của capture (P1A) và phát biểu trạng thái 2-nhánh
(`userSpeaking` / `notUserSpeaking`) cho tầng trên (Policy P2 chặn Push lúc đang nói, half-duplex P4).
VAD dùng WebRTC VAD VERY_AGGRESSIVE, chia khung 20ms ngay ở native — nhờ vậy KHÔNG phải hạ `chunkMs`
của luồng thu (giải quyết K12).

## Requirements

### Requirement: Hai trạng thái với ngưỡng có lý giải

`ConversationState` **PHẢI (MUST)** chỉ có đúng 2 trạng thái, chuyển theo bộ ngưỡng mặc định
(`ConversationStateConfig.defaults`, `lib/audio/vad/conversation_state.dart:88-107`):
- **attack** 300ms nói liên tục (tỉ lệ khung nói ≥ 0.5) ⇒ `userSpeaking`
- **release** 1500ms im lặng ⇒ `notUserSpeaking`
- watchdog 1500ms: đang khoá mà không còn dữ liệu VAD ⇒ mở khoá khẩn (sửa F2)
- lịch sử chuyển trạng thái trong phiên: tối đa 500 bản ghi (không lưu vĩnh viễn)

#### Scenario: Nhận ra người nói và im lặng

- **GIVEN** state machine đang chạy với config mặc định
- **WHEN** có tiếng nói liên tục ≥ 300ms rồi im lặng ≥ 1500ms
- **THEN** lần lượt chuyển `notUserSpeaking → userSpeaking` rồi `userSpeaking → notUserSpeaking`, mỗi lần chuyển kèm `VadFrameStat` (số khung nói/tổng, tỉ lệ nói, thời lượng)

#### Scenario: Dữ liệu VAD ngắt quãng

- **GIVEN** state đang là `userSpeaking`
- **WHEN** không còn frame VAD nào tới trong 1500ms (watchdog)
- **THEN** state mở khoá khẩn về `notUserSpeaking` thay vì khoá vĩnh viễn

### Requirement: Phát trạng thái cho tầng trên

Trạng thái **PHẢI (MUST)** được phát qua `ValueNotifier` + `Stream` (changes/transitions) và
`isUserSpeaking` đồng bộ — Policy P2 đọc đồng bộ để chặn cứng trước khi gọi LLM.

#### Scenario: UI vẽ lại theo tick VAD

- **GIVEN** màn hình chẩn đoán đang mở và lắng nghe đang bật
- **WHEN** mỗi buffer VAD về
- **THEN** dòng "Hội thoại" vẽ lại (`_vadTick`, sửa F4) — tỉ lệ nói không bị đóng băng
