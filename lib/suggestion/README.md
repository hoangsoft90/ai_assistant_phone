# `lib/suggestion/` — suggestion engine (LLM + policy)

P2 đã dựng xong. P3 (trigger + Offline Nudge Cache) và P5 (Pre-Brief/Post-Review/Training Level)
bổ sung tiếp.

## Luồng một lần Push (thủ công)

```
Bấm Push (P2: nút debug trên màn hình chẩn đoán; P3: nút thật)
   │
   ├─ 1. SuggestionPolicy.canSuggest()   ← chặn CỨNG ở đây, TRƯỚC khi dựng context
   │        · userSpeaking  ⇒ KHÔNG gọi LLM (nguyên tắc bất biến số 2)
   │        · debounce 1s (chống double-tap — KHÔNG phải cooldown 12-15s của P6)
   │
   ├─ 2. SuggestionContextBuilder        ← transcript 30s gần nhất từ P1E (KHÔNG nhãn speaker)
   │        + mốc Push + topics explored + last suggestions
   │        ⇒ prompt khung (NGUYÊN VĂN mục 4 prompt P2) đã thay {placeholder}
   │
   ├─ 3. LlmProvider.generateSuggestion()   ← GroqLlmProvider (mặc định)
   │        · timeout 4s; mất mạng/HTTP lỗi ⇒ SuggestionException KHÔNG retryable
   │        · JSON hỏng ⇒ retryable ⇒ service thử lại ĐÚNG 1 lần
   │
   └─ 4. parse + anti-repetition + ghi bộ nhớ phiên
            · JSON hỏng sau retry ⇒ NO_SUGGESTION
            · nudge trùng text/type trong 2 phút ⇒ NO_SUGGESTION
```

**Bất biến quan trọng:** `SuggestionService.push()` **KHÔNG BAO GIỜ ném** — policy, đọc transcript,
mạng, timeout, JSON: tất cả quy về `NO_SUGGESTION` (có `note` chẩn đoán). `NO_SUGGESTION` là kết quả
**HỢP LỆ**, không phải lỗi.

## File

| File | Vai trò |
|---|---|
| `suggestion_models.dart` | `NudgeType` (6 loại mục 4.5), `SuggestionResult`, `SuggestionContext`, `SuggestionException`, `parseSuggestionOutput()` |
| `llm_provider.dart` | `abstract class LlmProvider` — thêm `GeminiLlmProvider` sau mà không sửa tầng trên |
| `groq_llm_provider.dart` | Groq chat completions (`llama-3.1-8b-instant`, JSON mode); API key đọc từ `SecureStore` MỖI lần gọi |
| `suggestion_policy.dart` | `canSuggest()` (chặn cứng + debounce) và `isRepetition()` (cửa sổ 2 phút) |
| `suggestion_context_builder.dart` | Dựng prompt khung **nguyên văn** + `formatPushTimestamp()` |
| `session_memory.dart` | `recentSuggestions`/`topicsExplored`/`lastNudgeType` trong RAM (P2 chưa persist) |
| `suggestion_service.dart` | Orchestrator `push()` / `pushFromState()` — nơi duy nhất UI nên gọi |

## Ràng buộc không được vi phạm (ràng buộc xuyên phase)

1. **Prompt khung KHÔNG được sửa** — chỉ thay `{placeholder}`. Có test khoá từng dòng
   (`test/suggestion_engine_test.dart`, group "prompt khung NGUYÊN VĂN").
2. **Không gọi LLM khi `userSpeaking`** — chặn ở `SuggestionPolicy`, KHÔNG dựa vào prompt.
3. **Push thủ công không cooldown** — chỉ debounce 1s. Cooldown 12-15s thuộc semi-auto (P6).
4. **Chỉ TEXT đi lên cloud** — audio 100% offline (P1C/P1D); không thêm cloud ASR ở bất kỳ phase nào.
5. **Không nhãn speaker** trong transcript đưa vào prompt (`[Bạn]/[Đối phương]` bị cấm — P1E).
6. **API key không bao giờ vào source/SQLite/log** — chỉ `SecureStore` (keystore OS).
7. **Không dùng `as` để ép kiểu phản hồi LLM/HTTP** (bài học **A50**): sai kiểu ⇒ `TypeError`, mà
   `TypeError` không phải `SuggestionException` ⇒ nó xuyên qua `on SuggestionException` và `push()`
   ném ra UI. Đọc bằng `is`; giữ `_generateOnce()` trong `suggestion_service.dart` làm lưới an toàn.
8. **Không log nội dung nudge** (nội dung suy từ hội thoại = dữ liệu nhạy cảm) — chỉ log loại + lý do.

## Còn nợ / việc của phase sau

- **Offline Nudge Cache (mục 4.12)** — P3 mới làm; P2 chỉ fail gracefully (timeout ⇒ NO_SUGGESTION).
- **Pre-Brief + Session summary** trong prompt đang để rỗng — P5 (summary cần LLM tóm tắt định kỳ).
- **Nút Push thật** (floating button/gesture) — P3; P2 dùng nút debug trên màn hình chẩn đoán.
- `SessionMemory` chưa persist qua lần mở app (P2 yêu cầu "chưa cần persist phức tạp").
- Anti-repetition so khớp text chuẩn hoá **hoặc** cùng `type` — đúng nghĩa "trùng chủ đề/type" trong
  prompt; nếu thực tế thấy chặn quá tay (2 lần ASK liên tiếp khác chủ đề) thì cần chốt lại ở P5.
