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
| `lib/services/storage/transcript_dao.dart` | `TranscriptDao` (interface) + `SqliteTranscriptDao` (bản thật) + `TranscriptSession`. |
| `lib/services/storage/app_database.dart` | Schema v2: `_createTranscriptSchema()` dùng chung cho `onCreate` (máy mới) và `_onUpgrade` (v1→v2). |
| `lib/core/constants.dart` | `databaseVersion = 2`, `transcriptRollingWindow` (8′), `transcriptResumeGap` (30′), `transcriptRetention` (7 ngày). |
| `lib/ui/home_screen.dart` | Dòng "Transcript" / "Push gần nhất" + nút "Đánh dấu Push (P1E)" (tạm, để kiểm trên máy). |
| `lib/main.dart` | `TranscriptStore.instance().init()` trong bootstrap (khôi phục + xoá dữ liệu cũ, **không** phụ thuộc việc người dùng bật ASR). |

## 3. API endpoint

Không có — hoàn toàn local, **không gọi cloud** (chiều thu 100% offline; Post-Review ở P5 mới được dùng
cloud ASR và chỉ khi có Wi-Fi).

## 4. Local storage

| Bảng | Cột | Ghi chú |
|---|---|---|
| `transcript_sessions` | `id`, `started_at_ms`, `last_activity_at_ms` | Không có `ended_at`: phiên mới khi im lặng quá 30′. |
| `transcript_segments` | `id`, `session_id`, `timestamp_ms`, `text` | Index `(session_id, timestamp_ms)`. |
| `transcript_pushes` | `id`, `session_id`, `timestamp_ms` | Ghi **mọi** lần bấm Push. |

- DB: `ai_assistant.db` **version 2** (v1 = chỉ bảng `meta`).
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
- Sửa `attach()/detach()` phải giữ mẫu **capture-trước-khi-xoá** (bug race đã bị test bắt ở P1E — xem
  A33 trong `LESSONS_LEARNED.md`). Nếu lint `cancel_subscriptions` phản đối, giữ nguyên lối race-safe và
  dùng `// ignore` có chú thích, **không** "sửa cho vừa lint".
