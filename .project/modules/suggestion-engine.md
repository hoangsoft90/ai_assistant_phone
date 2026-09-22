# Module: Suggestion Engine (P2) — `lib/suggestion/`

Cập nhật: 2026-09-22 (+07). Trạng thái: **code xong, 161/161 test pass**, chờ test trên máy thật
(cần Groq API key lưu qua SecureStore).

## 1. Vai trò

Sinh gợi ý (nudge 2-4 từ) cho người dùng. Đây là **phần DUY NHẤT của app được phép gọi cloud** —
và chỉ gửi **text** transcript (audio 100% offline, ràng buộc cứng từ P1C/P1D).

## 2. Luồng và nơi chặn

| Bước | File | Ghi chú |
|---|---|---|
| Chặn cứng + debounce | `suggestion_policy.dart` | `userSpeaking` ⇒ không đi tiếp. Debounce 1s, KHÔNG cooldown |
| Dựng prompt | `suggestion_context_builder.dart` | Prompt khung **nguyên văn** (mục 4 prompt P2); transcript 30s từ P1E |
| Gọi LLM | `groq_llm_provider.dart` | Endpoint OpenAI-compatible, timeout 4s, JSON mode |
| Parse | `suggestion_models.dart` | 2 dạng: `NO_SUGGESTION` / `NUDGE{type,text}`; bóc code fence |
| Lọc lặp + ghi nhớ | `suggestion_policy.dart` + `session_memory.dart` | Cửa sổ 2 phút theo text/type |
| Điều phối | `suggestion_service.dart` | `push()` không bao giờ ném |

## 3. Cấu hình (`lib/core/constants.dart` → `SuggestionConfig`)

`pushDebounce` 1s · `antiRepetitionWindow` 2 phút · `llmTimeout` 4s · `groqModel`
`llama-3.1-8b-instant` · `groqEndpoint` (tra tài liệu Groq 2026-09) · `llmMaxParseRetries` 1.

## 4. Cảnh báo khi sửa

1. **Đừng sửa chữ trong prompt khung.** Test `prompt khung NGUYÊN VĂN` khoá từng dòng — cố ý.
   Muốn đổi prompt: đổi ở `.plan/prompt_P2.md` (nguồn chính thức) rồi cập nhật cả test.
2. **Đừng retry timeout/mất mạng.** `SuggestionException` có cờ `retryable`: chỉ lỗi
   parse/JSON mới retry (1 lần). Retry timeout = nhân đôi thời gian chờ ⇒ vi phạm DoD "NO_SUGGESTION
   sau ~3-4s".
3. **Đừng để `push()` ném.** Mọi nhánh lỗi mới thêm vào phải tự bọc và quy về `NO_SUGGESTION`;
   test "transcript lỗi ⇒ KHÔNG ném" là hàng rào cho bất biến này.
4. **Không log API key** (kể cả khi debug request) — key chỉ đọc từ `SecureStore` và đi vào header.
5. Prompt khung yêu cầu JSON ⇒ `response_format: json_object` **phải giữ** (Groq JSON mode), và
   chữ "JSON" phải còn trong prompt (Groq từ chối JSON mode nếu prompt không nhắc JSON).
6. **Không dùng `as` để ép kiểu dữ liệu từ LLM/HTTP** (bài học **A50**) — `as` sai kiểu ném `TypeError`,
   mà `TypeError` **không** phải `SuggestionException` nên sẽ xuyên qua mọi `on SuggestionException`
   ⇒ `push()` ném ra UI. Đọc bằng `is` — xem `parseSuggestionOutput()` trong `suggestion_models.dart`
   và đoạn đọc `choices` trong `groq_llm_provider.dart`. Lưới an toàn thứ hai là `_generateOnce()`
   trong `suggestion_service.dart` — đừng bỏ nó khi refactor, và nếu viết provider mới thì cũng đi qua nó.
7. **Không log nội dung nudge/transcript** — nội dung suy ra từ hội thoại là dữ liệu nhạy cảm; logcat chỉ
   ghi loại nudge + lý do (nội dung đã hiển thị trên màn hình chẩn đoán).

## 5. Việc còn lại (không thuộc P2)

- Offline Nudge Cache (mục 4.12) — P3.
- Trigger thật (floating button/gesture) + hiển thị nudge nghiêm túc — P3.
- Pre-Brief + Session summary thật trong prompt — P5.
- `SessionMemory` persist qua lần mở app — chưa cần (P2 cho phép giữ trong RAM).
