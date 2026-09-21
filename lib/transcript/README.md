# `lib/transcript/` — transcript store

Chưa có file Dart nào. Được điền ở **P1E**.

Dự kiến:
- Model dòng transcript: `text` + `timestamp`. **KHÔNG có trường `speaker`/`label`** (quyết định
  4.2b: LLM tự suy luận ai đang nói từ ngữ nghĩa, không gắn nhãn ở tầng lưu trữ).
- Truy vấn theo khung thời gian (N phút gần nhất) để cấp cho Suggestion Engine (P2).
- Dump theo phiên để Post-Review (P5) xử lý.

Lưu trữ đã chọn sẵn ở P0.5: **SQLite** qua `sqflite` (khung mở DB + migration nằm ở
`lib/services/storage/app_database.dart`). Schema bảng transcript sẽ do P1E định nghĩa và thêm
một bước migration mới.
