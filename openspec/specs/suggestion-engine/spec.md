# suggestion-engine Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P2 + Pre-Brief/Summary thật của P5 + lỗi review đã sửa).
> Nguồn sự thật: `lib/suggestion/`, `lib/suggestion/suggestion_context_builder.dart` (prompt khung
> NGUYÊN VĂN của prompt P2), `lib/core/constants.dart` (SuggestionConfig),
> `test/{suggestion_engine_test}.dart`, `.project/modules/suggestion-engine.md` (nếu có),
> `.plan/prompt_P2.md` (prompt khung là chuẩn — không được sửa).

## Purpose

Sinh gợi ý câu nói realtime: ghi mốc Push → Policy chặn cứng → dựng ngữ cảnh theo prompt khung →
gọi LLM (Groq) → parse JSON → giao nudge cho tầng output (P3). Mọi lỗi quy về `NO_SUGGESTION`
(kèm lý do) — `push()` KHÔNG BAO GIỜ ném ra UI. Nội dung nudge/transcript KHÔNG lên logcat (log chỉ
dùng `logLabel` không nội dung).

## Requirements

### Requirement: Prompt khung nguyên văn

`SuggestionContextBuilder` **PHẢI (MUST)** giữ nguyên văn prompt khung của prompt P2, chỉ thay
placeholder: `{pre_brief}` (Pre-Brief thật của phiên — P5), `{summary}` (tóm tắt thật — P5),
`{recent_30s}`, `{push_timestamp}`, `{recent_suggestions}`, `{topics_explored}`. Placeholder thiếu
dữ liệu ⇒ chuỗi `(chưa có)`. Chủ đề kiêng kỵ ghi rõ `TRÁNH (chủ đề kiêng kỵ): …` ở cuối Pre-Brief.

#### Scenario: Pre-Brief ảnh hưởng prompt

- **GIVEN** người dùng đã nhập Pre-Brief với chủ đề kiêng kỵ
- **WHEN** ngữ cảnh được dựng cho lần Push kế tiếp
- **THEN** `{pre_brief}` chứa nội dung đã nhập (kèm tiền tố TRÁNH cho kiêng kỵ) — đổi kiêng kỵ ⇒ prompt đổi theo (test khoá DoD-1 P5)

### Requirement: Policy chặn cứng trước LLM

`SuggestionPolicy.evaluate()` **PHẢI (MUST)** chặn THEO THỨ TỰ trước khi dựng context/gọi LLM:
1. `userSpeaking` ⇒ chặn (`blocked('userSpeaking')`) — đọc trạng thái VAD đồng bộ, không dựa vào LLM "tự biết"
2. debounce `SuggestionConfig.pushDebounce` = 1s (chống double-tap; Push thủ công KHÔNG có cooldown — cooldown chỉ của P6)
3. Training Level 4/5 (P5) ⇒ `NO_SUGGESTION` CÓ CHỦ ĐÍCH
4. Level 2 cần ngữ cảnh rõ; Level 3 chỉ khi "thật sự kẹt" (im lặng ≥ 8s kể từ dòng transcript cuối — heuristic K49)

#### Scenario: Push lúc đang nói

- **GIVEN** VAD đang `userSpeaking`
- **WHEN** Push được kích hoạt
- **THEN** KHÔNG có request nào đi tới LLM; kết quả là `NO_SUGGESTION` kèm lý do chặn (bằng chứng trên máy: push thứ 2 được ghi mốc nhưng không phát sinh gọi mạng)

### Requirement: Anti-repetition 2 phút

Nudge trùng text hoặc type với bất kỳ nudge nào trong `SuggestionConfig.antiRepetitionWindow` = 2
phút gần nhất **PHẢI (MUST)** bị loại và sinh nudge khác; chỉ áp cho nudge (`NO_SUGGESTION` không cần
lọc). Bộ đếm nudge của service KHÔNG ĐƯỢC đọc từ `SessionMemory` (trần 20 — lỗi H2 đã sửa: service
giữ bộ đếm riêng).

#### Scenario: Bấm lặp nhiều lần

- **GIVEN** người dùng bấm 3 lần trong 2 phút
- **WHEN** lần 2, 3 trả về cùng text/type với lần trước
- **THEN** nudge bị thay bằng câu khác; sau 2 phút câu cũ được phép dùng lại

### Requirement: LLM Groq + lỗi có kiểm soát

`GroqLlmProvider` **PHẢI (MUST)**: endpoint OpenAI-compatible `SuggestionConfig.groqEndpoint`,
`response_format: json_object`, timeout `SuggestionConfig.llmTimeout` = 4s, model
`SuggestionConfig.groqModel`; API key đọc từ `SecureStore` (Keystore OS) **MỖI LẦN GỌI** — không cache
RAM, không log key, không lưu key vào SQLite (ràng buộc #8). Parser **PHẢI (MUST)** đọc kiểu bằng
`is` (KHÔNG dùng `as` với dữ liệu bên ngoài — lỗi H1/H2/H3 từ review P2, A50), bóc code fence, chấp
nhận 2 dạng JSON hợp lệ. Mọi lỗi vận hành (timeout/mạng/HTTP/JSON) ⇒ `SuggestionException`; retry
CHỈ cho lỗi JSON (cờ `retryable`), timeout/mất mạng fail ngay để giữ "NO_SUGGESTION sau ~4s".

#### Scenario: Mất mạng

- **GIVEN** không có mạng và đã có API key
- **WHEN** Push được kích hoạt
- **THEN** trong ~4-5s kết quả là `NO_SUGGESTION · LLM không dùng được` (không treo UI); Offline Nudge Cache (P3) tiếp quản nếu cấu hình cho phép

#### Scenario: JSON lỗi

- **GIVEN** LLM trả body không parse được
- **WHEN** parser chạy
- **THEN** KHÔNG ném xuyên tới UI; hệ thống thử lại đúng 1 lần cho lỗi JSON rồi trả `NO_SUGGESTION`

### Requirement: Custom LLM endpoint/model (P2.1) — resolve mỗi lần gọi

`GroqLlmProvider` **PHẢI (MUST)** nhận `ConfigStore? configStore`; khi có, endpoint + model được
resolve **MỖI LẦN GỌI** qua `LlmProviderConfigResolver` (fallback an toàn về mặc định Groq khi
chưa cấu hình/giá trị hỏng — không ném). Mọi service gọi LLM **PHẢI (MUST)** nhận/ truyền
`ConfigStore` theo cùng một pattern — `PostReviewService`, `SuggestionService`, `TestLlmService`,
`SessionSummaryService` (bổ sung follow-up P2.1) — để cấu hình tuỳ chỉnh có hiệu lực trên toàn
bộ tính năng dùng LLM; KHÔNG có service nào âm thầm giữ endpoint mặc định Groq.

#### Scenario: Tóm tắt phiên đi đúng endpoint tuỳ chỉnh

- **GIVEN** user đã cấu hình endpoint + model tuỳ chỉnh trong Settings (bảng `meta`)
- **WHEN** `SessionSummaryService.maybeRefresh` tóm tắt (không inject provider)
- **THEN** request HTTP đi tới endpoint tuỳ chỉnh với model tuỳ chỉnh (bằng chứng: test mock
  HTTP server cục bộ khoá path/model/auth-header), KHÔNG rơi silent về Groq

#### Scenario: Chưa cấu hình gì

- **GIVEN** bảng `meta` chưa có endpoint/model (hoặc giá trị hỏng)
- **WHEN** bất kỳ service nào gọi LLM
- **THEN** dùng mặc định Groq y hệt trước P2.1 (không đổi hành vi, không lỗi)
