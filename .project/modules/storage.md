# Module: storage (SQLite + secure storage)

Trạng thái: 🟢 **đang dùng thật** — schema **v6** (P1E transcript + P5.1 báo cáo + P5.2 title +
issue1_fix ended_at + P5.4 last_analysis_attempt); migration đã chứng minh không mất dữ liệu trên
`sqlite3` thật (v1→v4) và có test khoá từng nhánh. Phần verify DB có sẵn trên máy thật gộp **K51**.

## 1. Mục đích

- **SQLite** (`sqflite`): transcript, dữ liệu phiên, báo cáo Post-Review, cấu hình (`meta`).
- **Secure storage** (`flutter_secure_storage`): **API key LLM** — không để key trong SQLite hay
  file cấu hình (ràng buộc #8).

## 2. API

### `lib/services/storage/app_database.dart` → `AppDatabase`

| Thành viên | Chi tiết |
|---|---|
| `_database` (static) | Cache instance; nếu đã mở thì trả luôn |
| `instance()` | `openDatabase(path, version: StorageConfig.databaseVersion, onCreate, onUpgrade)`; đường dẫn `join(await getDatabasesPath(), StorageConfig.databaseName)` |
| `close()` | Đóng DB + xoá cache |
| `_onCreate(db, version)` | Tạo bảng `meta` + **helper tạo bảng theo version hiện hành** (gọi chung cho DB mới — không lặp schema) |
| `_onUpgrade(db, old, new)` | Chuỗi nhánh `if (old < 2)` → v2 (transcript) → `if (old < 3)` → v3 (`post_review_reports` + index) → `if (old < 4)` → v4 (`title` phiên) → `if (old < 5)` → v5 (`ended_at_ms`) → `if (old < 6)` → v6 (`last_analysis_attempt_ms`) — **mỗi nhánh chỉ thêm, không sửa nhánh cũ** |

Hằng số (`lib/core/constants.dart` → `StorageConfig`): `databaseName = 'ai_assistant.db'`,
`databaseVersion = 6` (tăng +1 mỗi lần đổi schema, đọc giá trị thật trước khi sửa — A63),
`llmApiKeyKey = 'llm_api_key'`.

### Bảng (theo version xuất hiện)

| Bảng/cột | Từ v | Ghi chú |
|---|---|---|
| `meta (key, value)` | v1 | Cấu hình: engine ASR, endpoint/model LLM (P2.1), training level, retention… |
| transcript (P1E) | v2 | Segment theo phiên + index timestamp |
| `post_review_reports` | v3 | Báo cáo Post-Review persist — K50 đã đóng; xoá cùng transcript theo retention trong **cùng transaction** |
| `sessions.title TEXT` | v4 | NULL hợp lệ; tên mặc định sinh lúc hiển thị từ `started_at` |
| `sessions.ended_at_ms INTEGER` | v5 | `TranscriptSession.endedAt/isFinished`; cơ sở cho resume guard (chỉ resume session chưa kết thúc) |
| `sessions.last_analysis_attempt_ms INTEGER` | v6 | Mốc lần **THỬ** phân tích bù gần nhất (P5.4). `markAnalysisAttempted` ghi **trước** khi gọi LLM ⇒ app bị kill giữa chừng cũng không thử lại ngay. NULL = chưa từng thử |

### `TranscriptDao` — 3 method của P5.4 (phân tích bù)

| Hàm | Hợp đồng |
|---|---|
| `finishedSessionsWithoutReport({required int limit})` | Phiên `endedAt != null` + **chưa có** báo cáo (`NOT EXISTS` trên `post_review_reports`) + quá hạn throttle `CoachingConfig.analysisRetryInterval` (6h) ⇒ **cũ nhất trước**, tối đa `limit`. Phiên đang dở KHÔNG tính (chưa phải "buổi đã xong") |
| `markAnalysisAttempted(int sessionId, DateTime at)` | Ghi mốc THỬ. Caller phải gọi **trước** khi gọi LLM |
| `fullSessionText(int sessionId, {int maxChars})` | Transcript của **phiên bất kỳ** (không cần là phiên đang mở) → `SessionText{text, segmentCount, truncated}` |

**Một chỗ duy nhất ghép/cắt transcript:** `joinSessionText(lines, maxChars:)` (top-level, cùng file)
dùng chung cho `TranscriptStore.sessionTranscript()` (phiên đang mở) **và** `fullSessionText` (phiên
bất kỳ) — trước P5.4 quy tắc cắt nằm trong `TranscriptStore`; nếu bản "phân tích lại sau" tự viết lại
thì cùng một buổi sẽ cho kết quả khác nhau tuỳ đường vào. Quy tắc cắt: cắt từ **đầu**, giữ phần cuối
(`CoachingConfig.transcriptCharLimit`).

### `lib/services/storage/secure_store.dart` → `SecureStore`

| Hàm | Chi tiết |
|---|---|
| `hasLlmApiKey()` | Kiểm tra đã lưu key chưa (UI hiện "đã lưu"/"chưa có") |
| `readLlmApiKey()` / `writeLlmApiKey()` / `deleteLlmApiKey()` | Đọc/ghi/xoá key — provider đọc **mỗi lần gọi**, không cache RAM |
| `deleteLlmApiKey()` | Dùng khi user xoá key từ Settings |

## 3. API endpoints

Không có (app không backend).

## 4. Local storage — chi tiết

| Kho | Nội dung | Ai ghi |
|---|---|---|
| SQLite `ai_assistant.db` | `meta`, transcript, `post_review_reports`, `sessions.title`/`ended_at_ms`/`last_analysis_attempt_ms` | DAO (`TranscriptDao`, `MetaStore`, `PreBriefStore`, `TrainingLevelStore`…); mốc `last_analysis_attempt_ms` do `PendingAnalysisService` ghi |
| `flutter_secure_storage` (keystore OS) | `llm_api_key` | Settings UI qua `SecureStore` |

**Vì sao chọn SQLite thay vì Hive** (quyết định đã chốt, ghi cả trong code):
1. P1E cần **truy vấn theo khung thời gian** ("lấy N phút gần nhất" cho Suggestion Engine) →
   SQL + index theo timestamp làm được ngay, Hive phải tự viết lớp truy vấn.
2. P5 cần **dump toàn bộ theo phiên** cho Post-Review.
3. Công cụ xem/truy vấn DB có sẵn (không phải viết).

## 5. Việc còn thiếu

- [ ] **K51 — verify trên máy thật**: mở app lần đầu trên DB **v5** có sẵn ⇒ migration **v6** chạy,
      transcript + báo cáo cũ còn nguyên; `ended_at` điền đúng cho phiên mới; mốc
      `last_analysis_attempt_ms` chỉ được ghi khi thực sự có lượt phân tích bù chạy.
- [ ] Cân nhắc VACUUM/optimize khi DB lớn (chưa ai yêu cầu).

## 6. Cảnh báo khi sửa

1. **KHÔNG được xoá/tạo lại DB của người dùng để "cho nhanh"** (ràng buộc cứng #7). Mọi thay đổi
   schema phải qua **nhánh `oldVersion < N` MỚI** + tăng `databaseVersion` +1 (đọc giá trị thật
   trước khi sửa). Xoá DB = mất transcript của người dùng (không hoàn tác).
2. **KHÔNG sửa nội dung các nhánh migration đã có** (`< 2`, `< 3`, `< 4`) — chúng đã chạy trên DB
   thật của người dùng; sửa = sai trạng thái. Chỉ thêm nhánh mới.
3. **KHÔNG lưu API key / secret vào SQLite** hay bất kỳ chỗ nào ngoài `SecureStore`; không log key.
4. `instance()` trả **cache**; nếu ai đó gọi `close()` thì các nơi khác sẽ tự mở lại (đã xử lý bằng
   `cached.isOpen`), nhưng **đừng** gọi `close()` rải rác.
5. Transcript là **dữ liệu nhạy cảm** (nội dung hội thoại thật). Export/chia sẻ phải hỏi trước.
6. Thêm cột/bảng: thêm helper tạo riêng + gọi từ **cả** `_onCreate` (DB mới) **và** nhánh migration
   (DB cũ) — trừ khi cố ý ngoài `CREATE TABLE` như `title` v4 (tránh `duplicate column` khi nâng
   từ DB v1 — quyết định P5.2, có test khoá).
7. **Không tạo bản sao thứ hai của logic ghép/cắt transcript.** Mọi đường cần "toàn bộ transcript
   của một phiên" phải đi qua `joinSessionText`/`fullSessionText`; tự viết lại quy tắc cắt ở chỗ
   khác = "phân tích ngay" và "phân tích lại sau" cho kết quả lệch nhau trên cùng một buổi.
8. **Ghi mốc throttle TRƯỚC khi gọi LLM** (`markAnalysisAttempted`) — đảo thứ tự (ghi sau) làm mất
   tác dụng throttle khi app bị OS kill giữa lượt phân tích bù.
