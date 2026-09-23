# Module: Coaching (Pre-Brief · Session Summary · Post-Review · Training Level) — P5

Cập nhật: 2026-09-23 (+07). Nguồn: `.plan/prompt_P5.md`, `.plan/P5-result.md`, `.plan/plan_final_v2.md`
(mục 4.1, 4.9, 4.10).

## 1. Mục đích

Khép kín vòng lặp **trước – trong – sau** một buổi nói chuyện:

```
Pre-Brief (trước buổi)  →  {pre_brief}  ┐
                                        ├→ prompt khung (P2) → nudge
Session Summary (trong)  →  {summary}   ┘        ↑
                                          Training Level (mục 4.9) quyết định CÓ gọi LLM hay không
Kết thúc buổi  →  Post-Review: 3 mục (làm tốt / cơ hội bỏ lỡ / bài tập)
Số liệu 7 ngày  →  người dùng TỰ quyết định có đổi cấp (app không đề xuất)
```

## 2. File & vai trò

| File | Vai trò |
|---|---|
| `lib/coaching/pre_brief.dart` | `PreBrief` (6 trường, `toPromptValue()` một dòng cho `{pre_brief}`) + `ConversationStyle` + `PreBriefStore` (RAM = phiên hiện tại, **nháp** trong bảng `meta`) |
| `lib/coaching/training_level.dart` | `TrainingLevel` (5 cấp) + `TrainingLevelStore` (đọc/ghi `meta`, RAM cache) |
| `lib/coaching/session_summary.dart` | `SessionSummaryService` — tóm tắt phiên bằng LLM theo nhịp (4 nudge **hoặc** 5 phút) |
| `lib/coaching/post_review_service.dart` | `PostReviewService.run()` + `PostReviewReport` — 3 mục, không bao giờ ném |
| `lib/coaching/weekly_stats.dart` | `WeeklyStatsService` (đọc 2 truy vấn DAO → số liệu 7 ngày + xu hướng) |
| `lib/ui/pre_brief_screen.dart` | Màn hình nhập Pre-Brief |
| `lib/ui/post_review_screen.dart` | Hiện 3 mục; transcript chi tiết **ẩn** sau "Xem chi tiết" |
| `lib/ui/stats_screen.dart` | Số liệu 7 ngày + dòng "app không tự đề xuất đổi cấp" |
| `lib/suggestion/llm_provider.dart` | `TextLlmProvider` (văn bản tự do) — tách khỏi `LlmProvider` (nudge JSON) |
| `lib/suggestion/suggestion_policy.dart` | 2 cổng theo Training Level (`canSuggest` + `canSuggestWithContext`) |
| `lib/transcript/transcript_store.dart` | `sessionTranscript()` — cả phiên, kèm `segmentCount`/`truncated` |

## 3. Local storage (không có schema mới)

| Dữ liệu | Nơi | Vòng đời |
|---|---|---|
| Pre-Brief của phiên | RAM (`PreBriefStore.current`) | theo phiên; mất khi app bị kill |
| Pre-Brief (nháp) | bảng `meta`, khoá `coaching.pre_brief` | tới khi người dùng sửa/xoá (không tự hết hạn) |
| Training Level | bảng `meta`, khoá `coaching.training_level` | tới khi người dùng đổi |
| Bản tóm tắt phiên | RAM (`SessionSummaryService`) | theo phiên; **không** log, **không** lưu đĩa |
| Báo cáo Post-Review | RAM → màn hình | mất khi đóng màn hình (nợ K50) |
| Số liệu 7 ngày | **không lưu** — tính lại từ `transcript_sessions` + `transcript_pushes` | theo dữ liệu gốc (xoá sau 7 ngày — P1E) |

⇒ **Không có migration, không bảng mới, không dữ liệu nhạy cảm mới trên đĩa.**

## 4. Trạng thái

🟡 **Code xong (phần không phụ thuộc máy)** — `flutter analyze` sạch, **302/302 test** (66 test mới).
**0/5 mục DoD tick**: tất cả đều cần máy thật + API key Groq (nợ **K48**). Precondition P5 không đạt ⇒
user waive có ghi rủi ro (giống P3/P4).

## 5. Cảnh báo khi sửa (đọc trước khi đụng)

1. **KHÔNG thêm logic tự đề xuất chuyển cấp** (mục 4.9 đã patch). Màn hình thống kê chỉ được **hiển thị**.
2. **KHÔNG gọi LLM khi `userSpeaking`** — 2 cổng mới của P5 nằm *trước* LLM, không được thay bằng
   "để LLM tự biết".
3. **KHÔNG fallback Offline Nudge Cache** ở cổng Training Level: `NO_SUGGESTION` ở Level 4/5 là quyết định
   học tập của người dùng, không phải "LLM lỗi".
4. **Tóm tắt phiên là tính năng PHỤ**: không được `await` trên đường `push()` (sẽ phá DoD độ trễ của P4),
   không được ném, không được gọi mỗi lần bấm Push (nhịp 4 nudge / 5 phút).
5. **Mọi ghi trạng thái của tóm tắt sau `await` phải kiểm token thế hệ** (`_generation`): kết quả bay về
   sau `reset()` mà vẫn ghi ⇒ phiên mới thừa hưởng ngữ cảnh buổi trước (đã xảy ra thật, xem `.plan/P5-result.md` §5 H3).
6. **Số nudge dùng cho nhịp tóm tắt KHÔNG được lấy từ `SessionMemory`** (trần 20 bản ghi ⇒ nhịp đứng yên
   sau nudge 20 — lỗi H2 đã sửa một lần, đừng tái phạm).
7. **Pre-Brief là dữ liệu cá nhân**: không log nội dung, không nhét vào thông báo lỗi, không gửi đi đâu
   ngoài việc thay `{pre_brief}` trong prompt gửi LLM (text-only).
8. **Post-Review CHỈ được gửi text** lên LLM. Bước "cloud ASR" của `prompt_P5.md` **cố ý không làm** (mâu
   thuẫn ràng buộc cứng #4 — đã hỏi user, xem `.plan/P5-result.md` §1.2). Đừng "sửa lại cho đúng prompt"
   bằng cách thêm ghi audio/upload.
9. `xem chi tiết` transcript là **ẩn mặc định** (mục 4.10) — đừng đổi thành hiện hết.
