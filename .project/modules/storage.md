# Module: storage (SQLite + secure storage)

Trạng thái: 🟡 **khung** — mới mở DB và tạo bảng `meta`; **schema transcript là việc của P1E** (P0.5).

## 1. Mục đích

- **SQLite** (`sqflite`): nơi lưu transcript + dữ liệu phiên (P1E trở đi).
- **Secure storage** (`flutter_secure_storage`): nơi lưu **API key LLM** (dùng từ P2) — **không** để
  API key trong SQLite hay file cấu hình.

## 2. API

### `lib/services/storage/app_database.dart` → `AppDatabase`

| Thành viên | Chi tiết |
|---|---|
| `_database` (static) | Cache instance; nếu đã mở thì trả luôn |
| `instance()` | `openDatabase(path, version: StorageConfig.databaseVersion, onCreate, onUpgrade)`; đường dẫn `join(await getDatabasesPath(), StorageConfig.databaseName)` |
| `close()` | Đóng DB + xoá cache |
| `_onCreate(db, version)` | Tạo bảng `meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)` + insert `created_at = now` |
| `_onUpgrade(db, old, new)` | **Chưa có migration nào** — chỉ log warn |

Hằng số (`lib/core/constants.dart` → `StorageConfig`): `databaseName = 'ai_assistant.db'`,
`databaseVersion = 1`, `llmApiKeyKey = 'llm_api_key'`.

### `lib/services/storage/secure_store.dart` → `SecureStore`

| Hàm | Chi tiết |
|---|---|
| `hasLlmApiKey()` | Kiểm tra đã lưu key chưa (UI hiện "đã lưu"/"chưa có") |
| (các hàm đọc/ghi key) | Dùng khóa `StorageConfig.llmApiKeyKey` |

## 3. API endpoints

Không có.

## 4. Local storage — chi tiết

| Kho | Nội dung | Ai ghi |
|---|---|---|
| SQLite `ai_assistant.db` | Hiện chỉ bảng `meta`. **P1E** thêm bảng transcript | P1E |
| `flutter_secure_storage` (keystore OS) | `llm_api_key` | P2 |

**Vì sao chọn SQLite thay vì Hive** (quyết định đã chốt, ghi cả trong code):
1. P1E cần **truy vấn theo khung thời gian** ("lấy N phút gần nhất" cho Suggestion Engine) →
   SQL + index theo timestamp làm được ngay, Hive phải tự viết lớp truy vấn.
2. P5 cần **dump toàn bộ theo phiên** cho Post-Review.
3. Công cụ xem/truy vấn DB có sẵn (không phải viết).

## 5. Việc còn thiếu

- [ ] **Chạy thật trên máy**: xác nhận DB mở được (UI hiện `SQLite v1 · ai_assistant.db`).
- [ ] **P1E**: định nghĩa schema transcript + viết migration đầu tiên trong `_onUpgrade`.
- [ ] **P2**: hàm đọc/ghi API key thật (hiện mới có `hasLlmApiKey`).
- [ ] Cân nhắc chính sách lưu (transcript giữ bao lâu, xoá theo phiên) — chưa ai quyết.

## 6. Cảnh báo khi sửa

1. **KHÔNG được xoá/tạo lại DB của người dùng để "cho nhanh".** Mọi thay đổi schema phải đi qua
   `_onUpgrade` + tăng `databaseVersion`. Xoá DB = mất transcript của người dùng (thao tác không hoàn tác).
2. **KHÔNG lưu API key / secret vào SQLite** hay bất kỳ chỗ nào ngoài `SecureStore`.
3. **KHÔNG ghi giá trị secret thật vào log** — `AppLogger` hiện in cả message ra logcat.
4. `instance()` trả **cache**; nếu ai đó gọi `close()` thì các nơi khác sẽ tự mở lại (đã xử lý bằng
   `cached.isOpen`), nhưng **đừng** gọi `close()` rải rác.
5. Transcript là **dữ liệu nhạy cảm** (nội dung hội thoại thật của người dùng). Khi thêm tính năng
   export/chia sẻ ở P5, phải hỏi trước — không tự gửi dữ liệu đi đâu.
