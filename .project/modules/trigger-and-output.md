# Module: Trigger + Output Mode + Offline Nudge Cache — P3

## 1. Vì sao module này tồn tại

Mục 4.6 + 4.8 + 4.12 của `plan_final_v2.md`. Trước P3, gợi ý chỉ kích hoạt được bằng **một nút debug**
trên màn hình chẩn đoán (P2) và nudge chỉ biết **đọc qua tai nghe**. P3 làm ba việc:

1. **Trigger Abstraction** — "cái gì kích hoạt gợi ý" tách khỏi "gợi ý nội dung gì", để thêm nguồn
   mới (thông báo, volume key, semi-auto P6) mà không sửa Suggestion Engine.
2. **Output Mode** — người dùng chọn nudge đến bằng **tai nghe / rung / chữ**, kèm tốc độ đọc TTS.
3. **Offline Nudge Cache** — mất mạng / LLM lỗi thì vẫn có nudge tối thiểu, thay vì im lặng hoàn toàn.

## 2. File / hàm cụ thể

| File | Vai trò |
|---|---|
| `lib/trigger/trigger_manager.dart` | `TriggerManager.onSuggestRequested({source})` — **điểm vào duy nhất**; `TriggerOutcome` (nguồn, kết quả, chế độ hiệu lực, cách giao); `SuggestTriggerSource` (5 giá trị); `onEmergencyRequested()` — đi thẳng `EmergencyPhraseService` |
| `lib/ui/floating_button.dart` | `SuggestFloatingButton` — tap = Push, **giữ đúng 2s** = Emergency (`RawGestureDetector` + `LongPressGestureRecognizer(duration: TriggerConfig.emergencyHold)`) |
| `lib/audio/output_mode_selector.dart` | `NudgeOutputMode` (ear/haptic/silent) + `EffectiveNudgeOutput` (ear/haptic/text) + đọc/ghi chế độ & **tốc độ đọc** vào bảng `meta`; `effectiveMode()` — quyết định thuần logic (Ear tự hạ xuống chữ) |
| `lib/audio/nudge_delivery.dart` | `NudgeDelivery.deliver()` — nơi **giao** nudge thật: `SafeTtsOutput` (đọc) / `HapticFeedback` (rung) / chỉ chữ. Không bao giờ ném |
| `assets/offline_nudge_cache.json` | 72 câu nudge (12 × 6 type), mỗi câu 2–4 từ — dữ liệu bàn giao, sửa tay được |
| `lib/suggestion/offline_nudge_cache.dart` | `OfflineNudgeCache.pickNext({avoidTexts})` — nạp asset, chọn xoay vòng (bước 1 type), tránh câu vừa hiện, không bao giờ ném |
| `lib/suggestion/suggestion_service.dart` | (sửa ở P3) `_fallbackToCache()` — chỉ chạy khi **không dùng được LLM**; `cacheFallbackCount` |

## 3. Local storage

| Khoá (bảng `meta`) | Giá trị | Mặc định |
|---|---|---|
| `nudge_output_mode` | `ear` / `haptic` / `silent` | `ear` (Ear tự hạ xuống chữ khi thiếu tai nghe) |
| `tts_speech_rate` | số dạng chuỗi, đã kẹp 0.9–1.2 | `1.05` |

Kho nudge offline là **asset** trong APK (không phải DB): sửa câu = sửa JSON rồi cài lại.

## 4. Trạng thái

🟡 **Code + 50 test mới xong (211/211 pass, `flutter analyze` sạch); chưa verify trên máy thật.**
Bằng chứng đã có: ngưỡng giữ 2s được test đo ở **đúng** mốc 2s (đồng hồ giả); chế độ Ear không tai
nghe ⇒ **0 lời gọi TTS**; LLM timeout ⇒ nudge `source=cache`; JSON cache hỏng ⇒ `null`, không ném;
file asset validate đủ 6 type × 12 câu × 2–4 từ.

## 5. Việc còn thiếu (đừng tưởng nhầm đã có)

- **Chưa chạy trên máy** (nợ **K42**): nudge thật từ Groq, cảm nhận rung, tốc độ đọc 0,9x/1,2x, chế
  độ máy bay ⇒ nudge cache có dòng `CACHE OFFLINE`.
- **Volume key / nút tai nghe BT / notification action**: chưa có (nợ **K43**). Đường nối đã sẵn
  (`SuggestTriggerSource` + một hàm) nhưng cần native (Activity override / `MediaSession` /
  notification action + engine nền) và phải test trên máy.
- **Nút nổi ngoài app** (overlay toàn hệ thống, `SYSTEM_ALERT_WINDOW`): **cố ý không làm** — xem
  `.plan/P3-result.md` mục "Sai khác" số 1. Cần user chốt nếu muốn.
- **Cache offline không biết chủ đề** (câu chung): nợ **K44**.
- **Tốc độ đọc chưa verify native** (nợ **K41**) và là **cấu hình dính** của engine: Emergency
  (`rate=null`) giữ tốc độ của lần đọc trước đó.
- **Cooldown/semi-auto**: vẫn thuộc P6. Push thủ công **không** cooldown (chỉ debounce 1s ở Policy).
- **Half-duplex** (đang phát thì không thu): P4 — module này không giữ tham chiếu tầng capture.

## 6. Cảnh báo khi sửa

1. **Chỉ một điểm vào**: mọi nguồn trigger phải gọi `TriggerManager.onSuggestRequested()`. Thêm luồng
   riêng cho từng nguồn = phá mục đích của tầng này (và bỏ qua mốc Push/debounce).
2. **Không cooldown cho Push thủ công** — chỉ debounce 1s (trong `SuggestionPolicy`).
3. **Ear không bao giờ được phát khi thiếu tai nghe**: giữ `effectiveMode()` là nơi duy nhất quyết
   định hạ cấp; không tự ý gọi `SafeTtsOutput` từ chỗ khác.
4. **Offline Cache chỉ là fallback**: không gọi nó khi Policy chặn hoặc LLM trả `NO_SUGGESTION` hợp lệ
   (chặn vì "đang nói" mà vẫn đọc nudge là vi phạm nguyên tắc bất biến số 2).
5. **Không log nội dung nudge** — dùng `SuggestionResult.logLabel`.
6. **Ngưỡng giữ nút nổi** đổi được qua `TriggerConfig.emergencyHold`; đổi thì phải sửa/đọc lại
   `test/floating_button_test.dart` (test khoá đúng mốc 2s).
7. **Tốc độ đọc**: kẹp ở cả Dart và Kotlin; một tham số chất lượng sai KHÔNG được làm hỏng việc phát
   (bài học từ chính P3: `argument<Double>` từng có thể ném `ClassCastException` ⇒ mất cả tiếng đọc).
