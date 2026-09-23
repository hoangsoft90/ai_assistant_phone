# coaching Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P5). Không tự đề xuất đổi cấp ở bất kỳ đâu.
> Nguồn sự thật: `lib/coaching/{pre_brief,session_summary,post_review_service,training_level,weekly_stats}.dart`,
> `lib/ui/{pre_brief_screen,post_review_screen,stats_screen}.dart`,
> `lib/suggestion/suggestion_policy.dart` (2 cổng Training Level), `test/{pre_brief,session_summary,post_review,training_level,weekly_stats}_test.dart`,
> `.project/modules/coaching.md`.

## Purpose

Lớp "huấn luyện" xung quanh pipeline: Pre-Brief cho ngữ cảnh buổi nói, Session Summary cho LLM nhớ
ngữ cảnh dài, Post-Review cho học sau buổi, Training Level cho người dùng tự chọn mức app can thiệp,
Weekly Stats cho số liệu tham khảo. Quyết định đã chốt: **hoàn toàn thủ công** — app KHÔNG tự đề xuất
chuyển cấp, KHÔNG nhắc nhở tự động.

## Requirements

### Requirement: Pre-Brief là dữ liệu thật của prompt

`PreBriefStore` **PHẢI (MUST)** giữ Pre-Brief của phiên (RAM) + bản nháp trong bảng `meta` (không
schema mới); khi mở app, nháp được đưa làm Pre-Brief của phiên đang chuẩn bị. Chủ đề kiêng kỵ đứng
CUỐI và ghi rõ `TRÁNH (chủ đề kiêng kỵ): …` để LLM không đọc ngược thành "chủ đề nên khai thác".

#### Scenario: Nháp tồn tại qua lần mở app

- **GIVEN** người dùng đã nhập Pre-Brief rồi tắt app
- **WHEN** app mở lại
- **THEN** nháp được nạp lại và là Pre-Brief của phiên mới; dòng `Coaching (P5)` hiện `Pre-Brief: có`

### Requirement: Tóm tắt định kỳ không cản Push

`SessionSummaryService` **PHẢI (MUST)** tóm tắt (≤ 40 từ) theo nhịp **4 nudge HOẶC 5 phút** (điều
kiện HOẶC, cả hai cấu hình được cho test), gọi KHÔNG `await` (không làm nudge tới muộn), KHÔNG BAO
GIỜ ném/chặn Push; lỗi ⇒ giữ bản cũ + `lastNote`, KHÔNG log nội dung. Mọi ghi trạng thái phải qua
**token thế hệ** (cùng họ K45/A54) — kết quả tóm tắt bay về sau `reset()` KHÔNG được ghi vào phiên
mới (lỗi H3 đã sửa); mốc refresh ghi theo lần ĐỒNG BỘ gần nhất, không theo lần thử (lỗi H1); số nudge
đọc từ bộ đếm riêng, không từ `SessionMemory` trần 20 (lỗi H2).

#### Scenario: LLM chậm trả sau khi phiên kết thúc

- **GIVEN** một lần tóm tắt đang bay (LLM chưa trả)
- **WHEN** phiên được reset và phiên mới bắt đầu
- **THEN** kết quả muộn bị BỎ (token không khớp) — phiên mới KHÔNG thừa hưởng ngữ cảnh buổi trước

### Requirement: Post-Review đúng 3 mục

`PostReviewService` **PHẢI (MUST)** sinh đúng 3 mục (làm tốt / cơ hội bỏ lỡ / bài tập) từ transcript
cả buổi bằng text local (KHÔNG có bước cloud ASR — mâu thuẫn với ràng buộc #4 đã chốt bỏ ở P5);
parse chịu code fence; mọi lỗi quy về `unavailable(note)` không ném; định dạng lạ ⇒ vẫn cho đọc văn
bản thô. UI: transcript chi tiết ẨN mặc định sau "Xem chi tiết". Báo cáo KHÔNG persist (K50 — cố ý
tránh phát sinh dữ liệu nhạy cảm mới).

#### Scenario: Kết thúc buổi

- **GIVEN** một phiên có transcript và đã nhập API key
- **WHEN** người dùng bấm "Kết thúc buổi + nhận xét (P5)" (phiên stop trước rồi mới phân tích)
- **THEN** màn hình nhận xét hiện đúng 3 mục; dòng `Coaching (P5)` tăng `nhận xét 1 lần`; đóng màn hình không để lại dữ liệu

### Requirement: Training Level thủ công với luật trong Policy

`TrainingLevel` (5 cấp, giá trị lưu `meta` ổn định) **PHẢI (MUST)** do người dùng tự chọn; hành vi
thực thi nằm trong `SuggestionPolicy` **TRƯỚC KHI** gọi LLM: Level 4/5 ⇒ `NO_SUGGESTION` có chủ đích;
Level 2 cần ngữ cảnh rõ; Level 3 chỉ khi im lặng ≥ 8s. **Emergency KHÔNG bị chặn** ở mọi cấp. Store
chỉ đổi RAM khi ghi SQLite thành công (tránh lệch im lặng); đọc lỗi/giá trị lạ ⇒ mặc định Full Assist
+ log cảnh báo. KHÔNG có logic tự đề xuất đổi cấp ở bất kỳ đâu.

#### Scenario: Level Training chặn realtime nhưng không chặn Emergency

- **GIVEN** cấp đang chọn là `training`
- **WHEN** người dùng bấm nút nổi (Push) rồi giữ 2 giây (Emergency)
- **THEN** Push trả `NO_SUGGESTION` có chủ đích; câu thoát hiểm vẫn phát bình thường

#### Scenario: Cấp giữ nguyên qua lần mở app

- **GIVEN** người dùng chọn `minimal` (ghi thành công)
- **WHEN** app mở lại
- **THEN** cấp hiện hành vẫn là `minimal` (bằng chứng buổi test adb 2026-09-23: config được ghi và đọc lại từ bảng `meta`)

### Requirement: Số liệu 7 ngày không kèm đề xuất

`WeeklyStats` **PHẢI (MUST)** tổng hợp số buổi/Push/Push-per-buổi trong 7 ngày + xu hướng từ dữ liệu
thật của DB; màn hình thống kê KHÔNG chứa câu gợi ý đổi cấp.

#### Scenario: Xem số liệu sau một ngày dùng

- **GIVEN** DB có dữ liệu các buổi trong 7 ngày qua
- **WHEN** mở "Số liệu 7 ngày (P5)"
- **THEN** số buổi/Push khớp dữ liệu thật; KHÔNG có câu "nên nâng cấp xuống…" — nếu xuất hiện là vi phạm spec này
