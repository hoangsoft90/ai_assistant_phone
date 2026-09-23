# Module: `transcript-store` (P1E) — rolling transcript + kho SQLite

Cập nhật: 2026-09-21 (+07).

| Hạng mục | Giá trị |
|---|---|
| Phase | **P1E** — code xong, **2/4 mục DoD đạt** |
| Trạng thái | 🟡 chạy được theo unit test + SQL kiểm offline; **chưa verify trên máy thật** (K27) |
| Tầng | `lib/transcript/` (model + store) · `lib/services/storage/transcript_dao.dart` (SQLite) |

## 1. Mục đích

Lưu **transcript thô có timestamp** của phiên hội thoại đang diễn ra để:

- Suggestion Engine (P2) lấy **N phút gần nhất** + **mốc Push gần nhất** → dựng prompt LLM.
- Post-Review (P5) đọc lại **toàn bộ phiên** đã lưu.

**Không** gắn nhãn người nói (quyết định 4.2b) — LLM tự suy luận ai đang nói từ ngữ nghĩa.

## 2. File & hàm cụ thể

| File | Nội dung |
|---|---|
| `lib/transcript/transcript_segment.dart` | `TranscriptSegment{text, timestamp}` — **đúng 2 trường**, không có `speaker`/`label`. |
| `lib/transcript/transcript_store.dart` | `TranscriptStore`: `init()`, `attach(engine)`, `detach()`, `add(text)`, `markPushMoment(at)`, `recentWindow({window})`, `close()`; `TranscriptWindow{segments, lastPushMoment, text}`; `instance()` (bản dùng chung cho app). |
| `lib/services/storage/transcript_dao.dart` | `TranscriptDao` (interface) + `SqliteTranscriptDao` (bản thật) + `TranscriptSession{id, startedAt, lastActivityAt, title?}`; `renameSession(id, title?)` (P5.2). |
| `lib/transcript/session_display_name.dart` | `SessionDisplayName` (P5.2): `of(session)` (tên đã đặt, fallback timestamp), `defaultFrom()`, `timestamp()`, `normalize()` (rỗng⇒NULL, cắt 60). |
| `lib/services/storage/app_database.dart` | `_createTranscriptSchema()` + `_createPostReviewSchema()` + `_addSessionTitleColumn()` — mỗi helper dùng chung cho `onCreate` và nhánh migration tương ứng. |
| `lib/core/constants.dart` | `databaseVersion = 4`, `transcriptRollingWindow` (8′), `transcriptResumeGap` (30′), `transcriptRetention` (7 ngày, chỉnh được — P5.1). |
| `lib/ui/home_screen.dart` | Dòng "Transcript" / "Push gần nhất" + nút "Đánh dấu Push (P1E)" (tạm, để kiểm trên máy). |
| `lib/main.dart` | `TranscriptStore.instance().init()` trong bootstrap (khôi phục + xoá dữ liệu cũ, **không** phụ thuộc việc người dùng bật ASR). |

## 3. API endpoint

Không có — hoàn toàn local, **không gọi cloud** (chiều thu 100% offline; Post-Review ở P5 mới được dùng
cloud ASR và chỉ khi có Wi-Fi).

## 4. Local storage

| Bảng | Cột | Ghi chú |
|---|---|---|
| `transcript_sessions` | `id`, `started_at_ms`, `last_activity_at_ms`, `title` (NULL được) | Không có `ended_at`: phiên mới khi im lặng quá 30′. `title` (P5.2) = tên người dùng đặt; `NULL` ⇒ hiển thị tên mặc định qua `SessionDisplayName`. |
| `transcript_segments` | `id`, `session_id`, `timestamp_ms`, `text` | Index `(session_id, timestamp_ms)`. |
| `transcript_pushes` | `id`, `session_id`, `timestamp_ms` | Ghi **mọi** lần bấm Push. |

- DB: `ai_assistant.db` **version 4** (v1 = chỉ `meta`; v2 = 3 bảng transcript; v3 = `post_review_reports`; v4 = cột `title`).
- Không dùng FOREIGN KEY (sqflite không bật `PRAGMA foreign_keys` mặc định) — xoá theo phiên làm tường
  minh trong 1 transaction.
- **Chưa mã hoá** (K28): `sqflite` không hỗ trợ; chuyển sang `sqflite_sqlcipher` là việc của một quyết
  định riêng. Hiện dựa vào sandbox app + tự xoá sau 7 ngày.

## 5. Việc còn thiếu

- **K27:** chạy protocol trên máy thật — `adb shell am kill` (khôi phục phiên đang dở) + đổi ngày hệ
  thống +8 ngày (hạn 7 ngày) + migration v1→v2 trên máy đã cài bản P0.5. Quy trình ở
  `lib/transcript/README.md` mục 5.
- **K28:** quyết định có mã hoá DB không.
- Nhịp ghi đĩa (1 INSERT + 1 UPDATE mỗi ~4s) chưa đo ảnh hưởng pin/I/O.

## 6. Cảnh báo khi sửa

- **Đừng thêm `speaker`/`label`** vào `TranscriptSegment` — vi phạm ràng buộc xuyên phase (mục 3 của
  `AGENT_INSTRUCTIONS.md`).
- **Đừng đổi giá trị `lastPushMoment` thành "chỉ lưu mốc cuối"** ở tầng lưu trữ: P5 cần lịch sử các lần
  bấm để đối chiếu với gợi ý.
- **Đừng bump `databaseVersion` mà không thêm nhánh trong `_onUpgrade`** — máy đã cài app sẽ crash khi
  mở DB.
- **Đừng nhét `title` vào `CREATE TABLE transcript_sessions`** (trong `_createTranscriptSchema`): helper
  đó còn được nhánh `oldVersion < 2` gọi, nên nhánh `< 4` sẽ `ALTER` lên bảng vừa tạo đã có cột ⇒
  `duplicate column name` (đã chứng minh bằng sqlite3 thật, 2026-09-23). Cột `title` phải chỉ được thêm
  ở `_addSessionTitleColumn()` — đúng một chỗ, mọi đường chỉ thêm một lần.
- Sửa `attach()/detach()` phải giữ mẫu **capture-trước-khi-xoá** (bug race đã bị test bắt ở P1E — xem
  A33 trong `LESSONS_LEARNED.md`). Nếu lint `cancel_subscriptions` phản đối, giữ nguyên lối race-safe và
  dùng `// ignore` có chú thích, **không** "sửa cho vừa lint".
