# `lib/trigger/` — trigger abstraction (P3 task 1)

Đã có code từ **P3**. Đây là tầng trả lời câu "**cái gì** kích hoạt gợi ý" (mục 4.6), tách hẳn khỏi
"gợi ý **nội dung** gì" (`lib/suggestion/`).

## Điểm vào duy nhất

```dart
TriggerManager.onSuggestRequested({SuggestTriggerSource source = floatingButton})
```

**Mọi** nguồn kích hoạt phải gọi đúng hàm này — không viết luồng riêng cho từng nguồn. Thêm nguồn mới
(volume key, nút tai nghe BT, notification action, semi-auto P6) = thêm một chỗ gọi, không sửa logic:

```
nguồn (nút nổi / nút chẩn đoán / …)
   → TriggerManager.onSuggestRequested(source)
       ├─ ghi mốc Push (P1E)            — lỗi ở đây KHÔNG chặn Push
       ├─ SuggestionService.pushFromState()   — Policy (chặn cứng userSpeaking + debounce) → LLM → Offline Cache
       └─ OutputModeSelector + NudgeDelivery → SafeTtsOutput (đọc) / rung / chỉ chữ
```

Grep để tự kiểm: `grep -rn "onSuggestRequested" lib/` — chỉ được thấy 1 nơi gọi (hiện là
`lib/ui/home_screen.dart`).

## Nguồn đã có (P3)

| Nguồn | Trạng thái | Ghi chú |
|---|---|---|
| Nút nổi trong app (`SuggestFloatingButton`) | ✅ có | **Tap** = Push, **giữ 2 giây** = Emergency Phrase (P1G). Không xin `SYSTEM_ALERT_WINDOW` — xem `.plan/P3-result.md` mục "Sai khác" |
| Nút chẩn đoán "Xin gợi ý (P3)" trên màn hình chính | ✅ có | Đi **cùng** một hàm với nút nổi (không còn logic riêng như P2) |
| Notification action | ⬜ chưa | Cần Kotlin ở `ListeningService` + gọi ngược vào Dart ⇒ thuộc P4 (nợ **K43**) |
| Volume key | ⬜ chưa | Phải override ở tầng Activity; nếu vội thì mỗi lần chỉnh âm lượng sẽ gọi LLM ⇒ nợ **K43** |
| Nút tai nghe Bluetooth | ⬜ chưa | Cần `MediaSession`/`MediaButtonReceiver` + phát từ tiến trình nền ⇒ P4 (nợ **K43**) |
| Semi-auto (tự động theo state) | ⬜ chưa | P6 — **cooldown 12-15s thuộc phase đó**, KHÔNG áp lên Push thủ công |

## Ràng buộc

1. **Push thủ công KHÔNG cooldown** (quyết định P2). Chỉ debounce 1s chống double-tap trong Policy.
2. **Không bao giờ ném ra UI** — mọi lỗi quy về `NO_SUGGESTION` (hoặc nudge từ Offline Cache).
3. **Đường Emergency không đi qua tầng này**: gesture giữ 2 giây gọi thẳng
   `EmergencyPhraseService.triggerEmergency()` (không LLM, không Policy, không debounce).
4. **Không log nội dung nudge** — dùng `SuggestionResult.logLabel` (loại/nguồn) cho log; nội dung chỉ
   hiện trên màn hình chẩn đoán.

Chi tiết đầy đủ: `.plan/P3-result.md` · `.project/modules/trigger-and-output.md`.
