# app-storage Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P0.5). Không phải đề xuất.
> Nguồn sự thật: `lib/services/storage/app_database.dart`, `lib/services/storage/secure_store.dart`,
> `lib/core/constants.dart`.

## Purpose

Hai kho dữ liệu của app, tách theo tính chất dữ liệu:
- **SQLite** (`sqflite`): dữ liệu nghiệp vụ có cấu trúc — hiện chỉ có bảng `meta`; schema transcript
  là việc của P1E, **cố ý không định nghĩa trước**.
- **Secure storage** (keystore OS qua `flutter_secure_storage`): dữ liệu nhạy cảm — hiện chỉ có
  khóa API key LLM (dùng từ P2).

Chọn SQLite thay vì Hive là quyết định đã chốt (xem `context.md` mục 4, quyết định D4) vì P1E cần
truy vấn theo khung thời gian và dump theo phiên.

## Requirements

### Requirement: Mở và cache database

`AppDatabase.instance()` (`lib/services/storage/app_database.dart:20-36`) **PHẢI (MUST)**:
1. Trả về cache nếu `_database` khác null **và** `isOpen` (:21-24)
2. Ngược lại mở DB tại `join(await getDatabasesPath(), 'ai_assistant.db')` với
   `version: 1` (`StorageConfig.databaseVersion`, `constants.dart:34-35`), gắn `onCreate`/`onUpgrade` (:27-32)
3. Lưu vào `_database` và trả về (:33-34)

#### Scenario: Gọi instance lần đầu

- **GIVEN** app mới khởi động, chưa mở DB bao giờ
- **WHEN** `AppDatabase.instance()` được gọi
- **THEN** DB `ai_assistant.db` được mở (tạo mới nếu chưa có) ở thư mục databases chuẩn của Android, `onCreate` chạy, log "đã mở SQLite v1 tại <path>" được ghi, và instance được cache

#### Scenario: Gọi instance lần thứ hai

- **GIVEN** DB đã mở và đang `isOpen`
- **WHEN** `AppDatabase.instance()` được gọi lại
- **THEN** trả về cùng instance đã cache **không** mở connection mới (cả `main()` và `HomeScreen._refreshStatus()` đều đi qua đường này — không có 2 connection song song)

#### Scenario: DB đã bị đóng trước đó

- **GIVEN** `close()` đã được gọi trước đó
- **WHEN** `AppDatabase.instance()` được gọi
- **THEN** vì `_database` vẫn khác null nhưng `isOpen == false`, điều kiện cache thất bại ⇒ DB được mở lại và cache được thay bằng instance mới

### Requirement: Schema v1 chỉ có bảng meta

`_onCreate` (`app_database.dart:43-53`) **PHẢI (MUST)**:
1. Tạo bảng `meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`
2. Insert một dòng duy nhất: `key='created_at'`, `value=<ISO8601 thời điểm tạo>`

**KHÔNG** tạo bảng transcript nào ở version này — schema transcript là việc của P1E.

#### Scenario: DB được tạo lần đầu

- **GIVEN** file `ai_assistant.db` chưa tồn tại
- **WHEN** `openDatabase` chạy với `onCreate`
- **THEN** bảng `meta` được tạo với khóa chính `key`; một dòng `created_at` với giá trị `DateTime.now().toIso8601String()` được insert; log "đã tạo schema v1 (bảng meta)" được ghi

### Requirement: Migration phải đi qua onUpgrade, không xóa DB

`_onUpgrade` (`app_database.dart:56-58`) hiện **không có** migration nào — chỉ log warn
`"onUpgrade <old> -> <new>: chưa có migration nào được định nghĩa"`. Quy tắc bất di bất dịch của repo:
mọi thay đổi schema **PHẢI (MUST)** thêm nhánh migration ở đây và tăng `databaseVersion`;
**KHÔNG ĐƯỢC** xoá/tạo lại DB của người dùng (ràng buộc #7 trong `AGENTS.md` — transcript là dữ liệu nhạy cảm).

#### Scenario: Tăng version mà chưa viết migration

- **GIVEN** `databaseVersion` được tăng lên 2 nhưng `_onUpgrade` chưa có nhánh tương ứng
- **WHEN** app chạy trên thiết bị đã cài DB v1
- **THEN** `onUpgrade(1, 2)` chỉ ghi warn và **không** thay đổi gì schema — DB vẫn dùng được nhưng thiếu bảng mới (đây là hành vi an toàn hiện có: không crash, không mất dữ liệu, nhưng thiếu tính năng)

### Requirement: Đóng database

`AppDatabase.close()` (`app_database.dart:38-41`) **PHẢI (MUST)** gọi `close()` trên instance (nếu có) và
đặt `_database = null` để lần gọi sau mở lại. Hiện **không ai gọi** `close()` trong app.

#### Scenario: Đóng rồi mở lại

- **GIVEN** DB đang mở
- **WHEN** `close()` được gọi rồi `instance()` được gọi lại
- **THEN** DB được mở lại từ đầu (bao gồm mọi đường dẫn onCreate/onUpgrade nếu cần)

### Requirement: API key chỉ lưu trong secure storage

`SecureStore` (`lib/services/storage/secure_store.dart:9-21`) **PHẢI (MUST)** thao tác khóa
`'llm_api_key'` (`StorageConfig.llmApiKeyKey`, `constants.dart:38`) **chỉ** qua
`FlutterSecureStorage` (keystore/keychain của OS). **KHÔNG ĐƯỢC** ghi API key vào SQLite,
SharedPreferences hay file thường (ràng buộc #8 trong `AGENTS.md`).

API hiện có — đúng 4 hàm:
| Hàm | Hành vi | Dòng |
|---|---|---|
| `hasLlmApiKey()` | `read` rồi kiểm `isNotEmpty ?? false` (null hoặc rỗng ⇒ `false`) | :12-13 |
| `saveLlmApiKey(String)` | `write(key, value)` | :15-16 |
| `readLlmApiKey()` | `read(key)` trả `String?` | :18 |
| `deleteLlmApiKey()` | `delete(key)` | :20 |

#### Scenario: Kiểm tra khi chưa lưu key

- **GIVEN** secure storage chưa có khóa `llm_api_key`
- **WHEN** `hasLlmApiKey()` chạy
- **THEN** `read` trả `null`, toán tử `?? false` cho kết quả `false` — UI hiện "chưa có"

#### Scenario: Lưu rồi đọc lại

- **GIVEN** `saveLlmApiKey('sk-...')` đã chạy
- **WHEN** `hasLlmApiKey()` và `readLlmApiKey()` chạy
- **THEN** lần lượt trả `true` và `'sk-...'` (nội dung nằm trong keystore OS, không nằm trong SQLite hay file thường)

#### Scenario: Lưu chuỗi rỗng

- **GIVEN** `saveLlmApiKey('')` chạy (code **không** chặn giá trị rỗng)
- **WHEN** `hasLlmApiKey()` chạy
- **THEN** trả `false` (vì `isNotEmpty`) — tuy nhiên khóa vẫn tồn tại với giá trị rỗng trong storage; `readLlmApiKey()` trả `''` chứ không phải `null`

#### Scenario: Xóa key

- **GIVEN** khóa `llm_api_key` đang tồn tại
- **WHEN** `deleteLlmApiKey()` chạy rồi `hasLlmApiKey()` chạy
- **THEN** `read` trả `null` ⇒ `hasLlmApiKey()` trả `false`

## Cần làm rõ

1. **`saveLlmApiKey` chấp nhận chuỗi rỗng** (scenario ở trên): sau khi lưu `''`, trạng thái "đã có
   key" và "chưa có key" không còn tương ứng 1-1 với tồn tại của khóa. Chưa rõ có cần validate
   (từ chối rỗng, hoặc delete thay vì write) ở P2 khi LLM client thật sự dùng nó.
2. **`onUpgrade` chỉ log warn, không ném lỗi** — nếu P1E quên viết migration, app sẽ chạy tiếp với
   schema cũ **âm thầm**. Đây có thể là lựa chọn an toàn có chủ ý (không crash), nhưng cũng có thể
   che giấu lỗi migration; chưa rõ ai chịu trách nhiệm phát hiện khi đó.
3. **`created_at` trong bảng `meta` dùng giờ thiết bị** (`DateTime.now()`) — nếu giờ máy sai, giá trị
   này sai. Chưa rõ có cần mốc thời gian đáng tin hơn (server time/milliSecondsSinceEpoch) không,
   khi transcript thật (P1E) cũng sẽ phải chọn một quy ước thời gian.
4. **Không có test nào cho `AppDatabase`/`SecureStore`** — các scenario trên mô tả code, chưa có test
   khoá hành vi (test hiện tại stub toàn bộ sqflite/secure_storage channel).
5. **Chưa có chính sách dữ liệu**: transcript giữ bao lâu, xoá khi nào, ai được truy cập — chưa ai
   quyết (đã ghi trong `.project/modules/storage.md` mục 5).
