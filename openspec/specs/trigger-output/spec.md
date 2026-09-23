# trigger-output Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P3).
> Nguồn sự thật: `lib/trigger/trigger_manager.dart`, `lib/ui/floating_button.dart`,
> `lib/audio/output_mode_selector.dart`, `lib/audio/nudge_delivery.dart`,
> `lib/suggestion/offline_nudge_cache.dart`, `assets/offline_nudge_cache.json`,
> `test/{trigger_manager_test,floating_button_test,output_mode_selector_test,offline_nudge_cache_test,nudge_delivery_test}.dart`.

## Purpose

Ghép 3 mảnh: (1) **Trigger** — một điểm vào duy nhất cho mọi nguồn kích hoạt gợi ý; (2) **Output
Mode** — người dùng chọn cách nhận nudge (tai nghe / rung / chỉ chữ) + tốc độ đọc; (3) **Offline
Nudge Cache** — kho 72 câu (12 × 6 type) dự phòng khi LLM không dùng được. Cùng nhau tạo luồng Push
đầy đủ: nguồn → TriggerManager → SuggestionService → chọn mode → giao nudge.

## Requirements

### Requirement: Một điểm vào duy nhất

`TriggerManager.onSuggestRequested(source)` **PHẢI (MUST)** là điểm vào DUY NHẤT cho mọi nguồn
(`SuggestTriggerSource`: nút nổi / nút chẩn đoán / thông báo / volume key / nút BT). Luồng: ghi mốc
Push (P1E) → SuggestionService → chọn chế độ output → giao nudge. KHÔNG có cooldown ở đây
(quyết định P2: cooldown chỉ của P6); mốc Push lỗi KHÔNG chặn Push.

#### Scenario: Nút chẩn đoán đi cùng đường nút nổi

- **GIVEN** nút "Xin gợi ý (P3)" trên màn hình và nút nổi cùng tồn tại
- **WHEN** bấm bất kỳ nút nào trong hai
- **THEN** cả hai đi qua cùng `onSuggestRequested` — hành vi không khác nhau (chỉ khác `source` để log)

### Requirement: Chế độ output có fallback an toàn

`NudgeOutputMode` (ear/haptic/silent, lưu bảng `meta` `nudge_output_mode`) **PHẢI (MUST)** có hành vi:
- **ear**: đọc qua tai nghe; KHÔNG có tai nghe ⇒ TỰ HẠ xuống text (không phải người dùng chọn — ràng buộc an toàn)
- **haptic**: rung; rung lỗi ⇒ hạ xuống text
- **silent**: chỉ chữ — không âm thanh, không rung (chốt an toàn cuối cùng, không phụ thuộc mạng)

Tốc độ đọc `writeSpeechRate()` kẹp trong khoảng `OutputConfig.minSpeechRate` 0.9x–1.2x, mặc định
1.05x, nối tới `setSpeechRate` native (K41: cảm nhận thực chưa verify trên máy). Lỗi nạp config lạ ⇒
dùng mặc định, không ném.

#### Scenario: Mất tai nghe khi đang chọn chế độ tai nghe

- **GIVEN** chế độ `ear` đang có hiệu lực
- **WHEN** nudge sẵn sàng mà tai nghe không kết nối
- **THEN** mode có hiệu lực thành text (`EffectiveNudgeOutput.text`) — nudge KHÔNG bị mất, KHÔNG phát loa

### Requirement: Offline Cache chỉ là FALLBACK

`OfflineNudgeCache` (asset `offline_nudge_cache.json`, 72 câu = 12 × 6 type × 2-4 từ) **PHẢI (MUST)**
chỉ dùng khi KHÔNG gọi được LLM (Policy chặn / `NO_SUGGESTION` hợp lệ thì KHÔNG fallback); kết quả
cache mang nguồn `NudgeSource.cache` + đếm `cacheFallbackCount` để UI hiện `CACHE OFFLINE`. Xoay
vòng tránh câu vừa hiện; nạp lại lỗi asset ⇒ cho phép thử lần sau (không chết vĩnh viễn).

#### Scenario: Máy bay

- **GIVEN** đã bật máy bay (không gọi được LLM)
- **WHEN** Push được kích hoạt
- **THEN** nudge từ cache với nhãn `CACHE OFFLINE`, KHÔNG phải nudge thật — UI phân biệt được nguồn

#### Scenario: LLM trả NO_SUGGESTION hợp lệ

- **GIVEN** LLM hoạt động bình thường
- **WHEN** LLM trả `NO_SUGGESTION` (không có gì đáng nói)
- **THEN** cache KHÔNG được dùng thay thế — đây là lỗi đã sửa (test khoá: "LLM trả NO_SUGGESTION hợp lệ ⇒ KHÔNG fallback")

### Requirement: Giao nudge không bao giờ ném

`NudgeDelivery` **PHẢI (MUST)** giao nudge theo mode có hiệu lực và KHÔNG BAO GIỜ ném; lỗi rung ⇒ hạ
xuống text; lỗi TTS ⇒ báo qua kênh fallback (P1F) nhưng luồng Push vẫn hoàn tất.

#### Scenario: Rung lỗi

- **GIVEN** chế độ có hiệu lực là haptic
- **WHEN** `HapticFeedback` ném lỗi trên thiết bị
- **THEN** nudge vẫn tới người dùng dưới dạng chữ; không crash, không mất nudge
