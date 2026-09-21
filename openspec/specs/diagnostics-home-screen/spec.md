# diagnostics-home-screen Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P0.5). Không phải đề xuất.
> Nguồn sự thật: `lib/ui/home_screen.dart` (toàn bộ 178 dòng), `test/app_smoke_test.dart`.

## Purpose

Màn hình chính **duy nhất** của app ở giai đoạn bootstrap — vừa là khung UI vừa là **màn hình chẩn
đoán**: hiện trạng thái các mảnh hạ tầng (service, quyền, SQLite, secure storage) để kiểm tay trên
máy thật **không phải đọc log**, và cho phép bật/tắt foreground service.

Ràng buộc thiết kế của module: **một mảnh hạ tầng lỗi không được làm màn hình chết** — mọi lời gọi
plugin trong màn hình đều bọc `try/catch` riêng. Đây là màn hình chẩn đoán; tính năng sản phẩm thật
(mi_pre-brief/floating button/settings) thuộc P5/P3 và **chưa tồn tại**.

## Requirements

### Requirement: Hiển thị trạng thái service

Màn hình **PHẢI (MUST)** hiển thị đúng 2 trạng thái dựa trên `ListeningService.isRunning()`:
- `'Sẵn sàng'` với icon `Icons.check_circle_outline` màu `Colors.blueGrey` khi service **không** chạy
- `'Đang lắng nghe'` với icon `Icons.graphic_eq` màu `Colors.green` khi service **đang** chạy
(`lib/ui/home_screen.dart:159-166`)

#### Scenario: Mở app khi service chưa chạy

- **GIVEN** service chưa được bật
- **WHEN** `HomeScreen` dựng xong và `_refreshStatus()` hoàn tất
- **THEN** trạng thái hiển thị "Sẵn sàng" kèm icon check màu blueGrey

#### Scenario: Service đang chạy

- **GIVEN** `ListeningService.isRunning()` trả `true`
- **WHEN** trạng thái được refresh
- **THEN** màn hình hiển thị "Đang lắng nghe" kèm icon graphic_eq màu xanh

#### Scenario: Không đọc được trạng thái service

- **GIVEN** lời gọi `ListeningService.isRunning()` ném exception (vd: plugin chưa sẵn sàng)
- **WHEN** `_refreshStatus()` chạy (`home_screen.dart:44-47`)
- **THEN** exception chỉ được ghi log warn ("không đọc được trạng thái service"), giá trị running giữ `false`, **các khối trạng thái khác vẫn được đọc tiếp** — màn hình không crash

### Requirement: Nút bật/tắt service có chống bấm đúp

Màn hình **PHẢI (MUST)** có một nút chính (`FilledButton.icon`, `home_screen.dart:129-133`):
- Service chưa chạy → nhãn `'Bật lắng nghe'`, icon play → gọi `ListeningService.start()`
- Service đang chạy → nhãn `'Tắt lắng nghe'`, icon stop → gọi `ListeningService.stop()`
- Khi `_busy == true`, nút **PHẢI (MUST)** bị disable (`onPressed: null`) — chống bấm đúp
- Nút làm mới (`IconButton` refresh, `:117-120`) cũng bị disable khi `_busy`

#### Scenario: Bật lắng nghe thành công

- **GIVEN** service chưa chạy, quyền mic đã cấp
- **WHEN** người dùng bấm "Bật lắng nghe"
- **THEN** `_busy` bật `true` (nút disabled), `ListeningService.start()` chạy; khi trả `true` → snackbar "Đang lắng nghe"; trong `finally` `_busy` tắt và `_refreshStatus()` chạy lại — UI về trạng thái "Đang lắng nghe"

#### Scenario: Bật lắng nghe thất bại vì thiếu quyền

- **GIVEN** quyền mic chưa cấp, service chưa chạy
- **WHEN** người dùng bấm "Bật lắng nghe"
- **THEN** `start()` trả `false` → snackbar "Không bật được service (thiếu quyền micro?)"; UI vẫn ở trạng thái "Sẵn sàng"; không có exception nào lan lên người dùng

#### Scenario: Bấm đúp vào nút

- **GIVEN** người dùng bấm nút trong khi `_toggleService` chưa hoàn tất
- **WHEN** lần bấm thứ hai xảy ra
- **THEN** `onPressed` đang là `null` (do `_busy == true`) nên lần bấm thứ hai không có tác dụng — không có 2 lượt start/stop chồng nhau

#### Scenario: Tắt lắng nghe

- **GIVEN** service đang chạy
- **WHEN** người dùng bấm "Tắt lắng nghe"
- **THEN** `ListeningService.stop()` chạy → snackbar "Đã tắt lắng nghe" → refresh trạng thái về "Sẵn sàng"

#### Scenario: Bật/tắt ném exception

- **GIVEN** lời gọi start/stop ném exception bất thường
- **WHEN** `_toggleService` chạy (`home_screen.dart:81-99`)
- **THEN** exception được bắt, log error, snackbar "Lỗi: <error>"; `finally` vẫn tắt `_busy` và refresh — UI không kẹt ở trạng thái disabled

### Requirement: Bảng trạng thái hạ tầng 3 dòng

Màn hình **PHẢI (MUST)** hiển thị `_statusCard()` với 3 dòng thông tin (`_infoRow`, `home_screen.dart:170-173`):

| Nhãn | Nguồn dữ liệu | Giá trị hiển thị |
|---|---|---|
| `Quyền` | `PermissionGate.currentStatus()` | `'chưa kiểm tra'` nếu map rỗng; ngược lại `'mic <đã cấp/chưa cấp>, thông báo <đã cấp/chưa cấp>'` (`:151-155`) |
| `Lưu trữ` | `AppDatabase.instance()` → `db.getVersion()` | `'SQLite v<version> · ai_assistant.db'`; nếu exception → `'lỗi: <error>'` |
| `API key LLM` | `SecureStore.hasLlmApiKey()` | `'lỗi đọc'` nếu `null`; `'đã lưu'` / `'chưa có'` |

#### Scenario: Tất cả hạ tầng hoạt động

- **GIVEN** quyền đã cấp, DB mở được, secure storage đọc được với key chưa lưu
- **WHEN** trạng thái được refresh
- **THEN** card hiển thị: "Quyền: mic đã cấp, thông báo đã cấp" · "Lưu trữ: SQLite v1 · ai_assistant.db" · "API key LLM: chưa có"

#### Scenario: SQLite lỗi nhưng các khối khác ổn

- **GIVEN** `AppDatabase.instance()` ném exception
- **WHEN** `_refreshStatus()` chạy (`:56-61`)
- **THEN** dòng Lưu trữ hiển thị `'lỗi: <error>'`; dòng Quyền và API key LLM vẫn hiển thị đúng trạng thái thật của chúng — lỗi một khối không che trạng thái các khối còn lại

#### Scenario: Secure storage trả null

- **GIVEN** `hasLlmApiKey()` ném exception
- **WHEN** `_refreshStatus()` chạy (`:62-65`)
- **THEN** log warn được ghi; `_hasApiKey` giữ `null` → dòng hiển thị `'lỗi đọc'`

### Requirement: Refresh trạng thái và an toàn mounted

- `_refreshStatus()` **PHẢI (MUST)** được gọi khi `initState` (:36-38) và sau mỗi thao tác bật/tắt (:98)
- Nút refresh trên AppBar **PHẢI (MUST)** gọi lại `_refreshStatus()` (`:117-120`)
- Trước mỗi `setState` trong async flow **PHẢI (MUST)** kiểm `if (!mounted) return;` (`:69-72`, `:103-105`)

#### Scenario: Người dùng bấm refresh

- **GIVEN** app đang mở, trạng thái có thể đã thay đổi (vd: người dùng vừa cấp quyền trong settings)
- **WHEN** người dùng bấm icon refresh trên AppBar
- **THEN** cả 4 nguồn trạng thái (service, quyền, DB, API key) được đọc lại và UI cập nhật

#### Scenario: Kết quả trả về sau khi widget đã bị hủy

- **GIVEN** người dùng rời khỏi màn hình trong khi `_refreshStatus()` đang chờ plugin
- **WHEN** lời gọi plugin hoàn tất
- **THEN** kiểm `!mounted` chặn `setState` — không crash, không lỗi "setState after dispose"

### Requirement: Bọc vòng đời của foreground task

Widget `HomeScreen` **PHẢI (MUST)** được bọc bởi `WithForegroundTask` (`home_screen.dart:112`) — giữ app
sống khi người dùng bấm nút back cứng lúc service đang chạy (cơ chế của plugin, không phải routing).

#### Scenario: Bấm back cứng khi service đang chạy

- **GIVEN** service đang chạy, người dùng bấm nút back hệ thống
- **WHEN** activity bị đưa ra sau
- **THEN** app/process vẫn sống nhờ `WithForegroundTask` + foreground service (hành vi được cấu hình trong module `listening-foreground-service`, spec riêng)

## Cần làm rõ

1. **Trạng thái hiển thị sai lệch khi plugin lỗi:** khi `isRunning()` ném exception, UI hiện
   "Sẵn sàng" (`running = false`) dù service thực tế có thể đang chạy — màn hình chẩn đoán có thể
   gây hiểu nhầm đúng vào lúc cần chẩn đoán. Chưa rõ có cần trạng thái "không đọc được" riêng không.
2. **Style hardcode:** `Colors.green`/`Colors.blueGrey`/`TextStyle(fontSize: 12, color: Colors.black54)`
   (`:160-161`, chú thích ở `:135-138`) — đã được ghi nhận trong `design-system.md` là việc phải bỏ
   khi có design token (P3), nhưng chưa có quyết định "khi nào bỏ".
3. **`_databaseStatus` đọc `db.getVersion()` qua import trực tiếp `package:sqflite`** trong UI
   (`:1-8`) — vi phạm nhẹ quy ước "UI không gọi thẳng plugin" (`patterns.md` mục 2, ngoại lệ được
   chấp nhận cho màn hình chẩn đoán). Chưa rõ khi nào nên thu hồi ngoại lệ này.
4. **Nhãn quyền chỉ gồm mic + thông báo** — `BLUETOOTH_CONNECT` (đã khai báo trong Manifest) không
   được hiện trạng thái. Chưa rõ có cần thêm vào màn hình chẩn đoán khi P1F cần quyền này không.
5. **Không có test nào ngoài 1 smoke test** (3 assert text) — mọi scenario trên mô tả code, chưa
   được khoá bằng widget test (vd: không test nào cho luồng `_busy`/exception).
