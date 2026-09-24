# Module: Suggestion Engine (P2) — `lib/suggestion/`

Cập nhật: 2026-09-24 (sau P5.4). Trạng thái: **code xong, 424/424 test
pass** (toàn project), phần máy thật gộp **K51**.

### File bổ sung từ P2.1/issue1_fix

| File | Vai trò |
|---|---|
| `lib/suggestion/llm_provider_config.dart` | `LlmProviderConfigResolver` + `ResolvedLlmConfig` — endpoint/model tuỳ chỉnh (bảng `meta`), fallback an toàn về Groq, **resolve mỗi lần gọi** (không cache) |
| `lib/suggestion/test_llm_service.dart` | `TestLlmService` — nút Test LLM: request thật tối thiểu (`"Reply with exactly: OK"`, 8 token, timeout 12s), phân loại auth/notFound/invalidEndpoint/timeout/network/server; dùng CÙNG resolver + SecureStore; **không đụng session/transcript** |

> **Custom LLM phủ toàn bộ 4 service** (follow-up P2.1): `SuggestionService`, `PostReviewService`,
> `TestLlmService`, `SessionSummaryService` — đều nhận `ConfigStore?` và truyền vào
> `GroqLlmProvider(configStore: …)`. Thêm service gọi LLM mới = phải theo đúng pattern này
> (khoá bằng spec `suggestion-engine` + test `session_summary_llm_config_test.dart`).

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
5. **Key plaintext trong dialog Settings là DEBUG-ONLY** (chốt user mục 13 issue1_fix) — mask lại
   trước khi phát hành cho người khác; comment mốc trong `session_coordinator.dart`.
6. Prompt khung yêu cầu JSON ⇒ `response_format: json_object` **phải giữ** (Groq JSON mode), và
   chữ "JSON" phải còn trong prompt (Groq từ chối JSON mode nếu prompt không nhắc JSON).
7. **Không dùng `as` để ép kiểu dữ liệu từ LLM/HTTP** (bài học **A50**) — `as` sai kiểu ném `TypeError`,
   mà `TypeError` **không** phải `SuggestionException` nên sẽ xuyên qua mọi `on SuggestionException`
   ⇒ `push()` ném ra UI. Đọc bằng `is` — xem `parseSuggestionOutput()` trong `suggestion_models.dart`
   và đoạn đọc `choices` trong `groq_llm_provider.dart`. Lưới an toàn thứ hai là `_generateOnce()`
   trong `suggestion_service.dart` — đừng bỏ nó khi refactor, và nếu viết provider mới thì cũng đi qua nó.
8. **Không log nội dung nudge/transcript** — nội dung suy ra từ hội thoại là dữ liệu nhạy cảm; logcat chỉ
   ghi loại nudge + lý do (nội dung đã hiển thị trên màn hình chẩn đoán). Dùng
   `SuggestionResult.logLabel` cho log (P3 thêm getter này sau khi phát hiện `toString()` có nội dung bị
   lọt vào log của `TriggerManager`).

## 5. Việc còn lại (không thuộc P2)

- ~~Offline Nudge Cache (mục 4.12)~~ — ✅ đã có ở P3 (`offline_nudge_cache.dart` +
  `assets/offline_nudge_cache.json`), chỉ chạy khi **không dùng được LLM**. Xem
  `.project/modules/trigger-and-output.md`; nợ K44 (câu chung, không theo chủ đề).
- ~~Trigger thật (floating button/gesture)~~ — ✅ đã có ở P3 (`lib/trigger/`, `lib/ui/floating_button.dart`).
- Pre-Brief + Session summary thật trong prompt — P5.
- `SessionMemory` persist qua lần mở app — chưa cần (P2 cho phép giữ trong RAM).
