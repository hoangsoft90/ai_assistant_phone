# `lib/coaching/` — vòng trước/sau buổi nói (P5)

Lớp "huấn luyện": chuẩn bị ngữ cảnh **trước** buổi, tóm tắt **trong** buổi, nhận xét **sau** buổi, và
cấp độ huấn luyện do người dùng tự chọn.

| File | Vai trò | Lưu ở đâu |
|---|---|---|
| `pre_brief.dart` | `PreBrief` + `ConversationStyle` + `PreBriefStore` | RAM (phiên) + nháp trong bảng `meta` |
| `training_level.dart` | `TrainingLevel` (5 cấp) + `TrainingLevelStore` | bảng `meta` |
| `session_summary.dart` | `SessionSummaryService` — tóm tắt phiên theo nhịp (4 nudge / 5 phút) | RAM (không log, không đĩa) |
| `post_review_service.dart` | `PostReviewService.run()` → **3 mục** | RAM (màn hình) |
| `weekly_stats.dart` | `WeeklyStatsService` → số liệu 7 ngày + xu hướng | không lưu (tính lại từ DB) |

## Nguyên tắc (ràng buộc xuyên phase từ P5)

1. **Chỉ TEXT đi lên LLM** — không audio, không file, không upload (ràng buộc cứng #4). Bước *cloud ASR*
   trong `prompt_P5.md` **cố ý không làm**; lý do + xác nhận của người dùng ở `.plan/P5-result.md` §1.2.
2. **Không tự đề xuất chuyển Training Level** (mục 4.9 đã patch — hoàn toàn thủ công). `weekly_stats` chỉ
   đếm; `ui/stats_screen.dart` chỉ hiển thị.
3. **Cấp độ ảnh hưởng gợi ý qua `SuggestionPolicy`, không qua prompt** — 2 cổng, cả hai trước khi gọi LLM:
   Level 4/5 ⇒ `NO_SUGGESTION` có chủ đích; Level 2 cần ngữ cảnh rõ; Level 3 chỉ khi "thật sự kẹt"
   (`CoachingConfig.minimalStuckSilence`). **Emergency Phrase không bị chặn** (đường riêng P1G/P3).
4. **Cố ý KHÔNG fallback Offline Nudge Cache** khi cấp độ chặn — fallback là phá đúng cấp người dùng chọn.
5. **Tóm tắt phiên là tính năng phụ**: không `await` trên đường `push()`, không bao giờ ném, không gọi mỗi
   lần Push (nhịp 4 nudge / 5 phút), và **mọi ghi trạng thái sau `await` phải kiểm token thế hệ**
   (`_generation`) để kết quả của phiên cũ không rơi vào phiên mới.
6. **Không log nội dung** tóm tắt/nudge/Pre-Brief (suy ra từ hội thoại thật — quyết định từ review P2);
   chỉ log số liệu + lý do lỗi (`lastNote` hiện trên màn hình chẩn đoán dòng `Coaching (P5)`).

## Việc còn thiếu

- **K48**: 0/5 mục DoD của P5 chưa verify trên máy thật (cần máy + API key Groq). Giáo trình 7 bước ở
  `.plan/P5-result.md` §8.
- **K49**: luật Level 2/3 là heuristic tự thiết kế (ngữ cảnh rõ = có Pre-Brief/transcript; kẹt = im lặng ≥ 8s).
- **K50**: báo cáo Post-Review không persist (chưa cần ở v1 để tránh dữ liệu nhạy cảm mới).
- Settings thật (gom Pre-Brief + cấp độ + chế độ output + tốc độ đọc + API key vào một chỗ) là việc của P7.
