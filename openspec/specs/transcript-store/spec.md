# transcript-store Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P1E + schema v4, đã verify một phần trên máy thật).
> Nguồn sự thật: `lib/transcript/`, `lib/services/storage/transcript_dao.dart`,
> `lib/services/storage/app_database.dart`, `lib/core/constants.dart`, `test/transcript_store_test.dart`,
> `.project/modules/transcript-store.md`, `lib/transcript/README.md`.

## Purpose

Lưu hội thoại đã bóc băng thành dữ liệu có cấu trúc cho: tóm tắt phiên (P5), phân tích Post-Review
(P5), số liệu 7 ngày (P5), và khôi phục phiên khi app bị OS kill. Transcript là **dữ liệu nhạy cảm**
(nội dung hội thoại thật) — chỉ lưu text + timestamp, KHÔNG lưu audio (ràng buộc #4), KHÔNG BAO GIỜ
xoá/tạo lại DB để sửa schema — mọi thay đổi phải qua migration (ràng buộc #7).

## Requirements

### Requirement: Schema v4 với migration từng bước từ v1

SQLite **PHẢI (MUST)** có 4 bảng (`transcript_sessions`, `transcript_segments`,
`transcript_pushes`, `post_review_reports`) + 3 index `(session_id, timestamp_ms)` /
`post_review_reports(session_id)`; `transcript_sessions` **PHẢI (MUST)** có cột `title TEXT` (NULL hợp
lệ). `StorageConfig.databaseVersion = 4`. Mỗi mốc version có đúng một nhánh trong `_onUpgrade`:
`< 2` (tạo bảng transcript), `< 3` (bảng báo cáo), `< 4` (`ALTER … ADD COLUMN title`). Máy cài bản cũ
**PHẢI (MUST)** được giữ nguyên dữ liệu — không backfill `title`, phiên cũ có `title = NULL` và hiển
thị tên mặc định theo `started_at`. DDL mới KHÔNG ĐƯỢC chạy nếu bảng đã tồn tại.

Cột `title` **KHÔNG ĐƯỢC** khai báo trong `_createTranscriptSchema()` (đường nâng cấp từ DB v1 sẽ chạy
`ALTER` lên bảng vừa tạo đã có cột ⇒ `duplicate column name`); nó chỉ được thêm ở
`_addSessionTitleColumn()` và helper này được gọi từ đúng hai nơi (`onCreate`, nhánh `< 4`).

#### Scenario: Máy cũ nâng cấp

- **GIVEN** máy có DB v1 từ P0.5
- **WHEN** app mở lần đầu sau nâng cấp
- **THEN** migration tạo 3 bảng + 2 index, dữ liệu `meta` cũ nguyên vẹn (đã verify thật trên máy 2026-09-22, K27)

#### Scenario: Phiên cũ có tên sau migration v4 (P5.2)

- **GIVEN** DB v3 đã có phiên với segments/pushes/báo cáo
- **WHEN** migration lên v4 chạy (`ALTER TABLE transcript_sessions ADD COLUMN title TEXT`)
- **THEN** mọi dòng cũ giữ nguyên số lượng và nội dung, `title` của chúng là `NULL` ⇒ hiển thị tên mặc
  định `"Buổi dd/MM/yyyy HH:mm"` theo `started_at_ms` (`SessionDisplayName.of`)
  *(đã chứng minh bằng `sqlite3` thật trên SQL trích từ `app_database.dart`, 2026-09-23 — 1/1/1/1 → 1/1/1/1;
  còn nợ chạy trên máy thật: K51)*

### Requirement: Ghi thẳng đĩa và khôi phục sau kill

Mỗi segment **PHẢI (MUST)** được ghi SQLite ngay (không gom lô) để khôi phục được sau khi app bị
kill; khi mở lại app, store **PHẢI (MUST)** tìm phiên còn hoạt động (hoạt động trong
`transcriptResumeGap` = 30 phút) và đếm số dòng **khôi phục** để UI báo
`khôi phục N dòng sau khi app bị kill`.

#### Scenario: Force-stop rồi mở lại

- **GIVEN** app đang nghe với ≥ 1 dòng transcript đã ghi
- **WHEN** app bị force-stop rồi mở lại
- **THEN** phiên cũ được nối tiếp (không tạo phiên mới vô cớ), số dòng khôi phục đúng số đã ghi (bằng chứng buổi test adb 2026-09-23: 4 segments giữ nguyên qua force-stop)

### Requirement: Cửa sổ RAM 8 phút và xoá 7 ngày

Store **PHẢI (MUST)** giữ cửa sổ RAM cuộn `transcriptRollingWindow` = 8 phút cho các tầng realtime;
lúc `init()` **PHẢI (MUST)** chạy purge dữ liệu cũ hơn `transcriptRetention` = 7 ngày (transaction 3
bảng). Purge chỉ ghi log — KHÔNG có UI quan sát (đã ghi rõ trong hướng dẫn test để người test không
kết luận nhầm).

#### Scenario: Dữ liệu quá hạn

- **GIVEN** DB có segment cũ hơn 7 ngày
- **WHEN** app khởi động và store `init()` chạy
- **THEN** segment/mốc Push của phiên quá hạn bị xoá, phiên hôm nay còn nguyên (đã verify thật trên máy 2026-09-22 — đặt ngày +8)

### Requirement: API text thô không nhãn + mốc Push

`TranscriptStore` **PHẢI (MUST)** cung cấp: `attach`/`detach` engine ASR (detach phải hủy đúng
subscription hiện tại — sửa bug race từ P1E), `add(text)` ghi tuần tự qua hàng đợi `_pending`,
`recentWindow()` cho prompt realtime, `sessionTranscript()` cho tóm tắt (kèm `segmentCount`,
`truncated`), `markPushMoment()` ghi MỌI lần bấm Push (P2 cần mốc gần nhất, P5 cần lịch sử),
`lastPushMoment` đọc nhanh.

#### Scenario: Detach không rò stream cũ

- **GIVEN** transcript đang attach engine A
- **WHEN** `attach(engine B)` hoặc `detach()` được gọi
- **THEN** subscription cũ bị hủy TRƯỚC khi ghi đè — stream cũ KHÔNG được ghi tiếp transcript (regression test khoá; lỗi gốc: `unawaited(detach())` treo ở await rồi bị đè)

### Requirement: Truy vấn Lịch sử phiên theo hợp đồng DAO (tối ưu N+1)

`TranscriptDao` **PHẢI (MUST)** cung cấp `allSessions({limit})` (mới nhất trước),
`reportForSession(sessionId)`, `saveReport(sessionId, row)` (ghi đè trong 1 transaction) và
`sessionIdsWithReport()` — tập ID phiên có báo cáo bằng **một** query `SELECT DISTINCT session_id`.
Màn hình Lịch sử **KHÔNG ĐƯỢC (MUST NOT)** lặp `reportForSession` cho từng phiên để dựng danh sách
(N+1 query: 100 phiên = 101 query); phải dùng `sessionIdsWithReport()`.

#### Scenario: Danh sách Lịch sử dựng bằng đúng 2 query

- **GIVEN** DB có nhiều phiên, trong đó một số phiên có báo cáo Post-Review đã lưu
- **WHEN** màn hình Lịch sử load
- **THEN** dữ liệu được lấy bằng `allSessions()` + `sessionIdsWithReport()` (2 query, không phụ
  thuộc số phiên); phiên có báo cáo hiển thị đúng trạng thái "có nhận xét"
