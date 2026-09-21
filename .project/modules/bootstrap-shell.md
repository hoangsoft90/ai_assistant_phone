# Module: bootstrap-shell

Trạng thái: 🟡 **khung có thật, chưa chạy trên máy thật** (P0.5).
Đây **không phải** tính năng sản phẩm — đây là điểm khởi động + màn hình chẩn đoán.

## 1. Mục đích

- Dựng hạ tầng (foreground service, audio session, database) **trước** `runApp`.
- Cho một màn hình duy nhất đọc và hiện trạng thái các mảnh hạ tầng ⇒ test tay trên máy thật **không
  phải đọc log**.
- Cho người dùng nút **Bật/Tắt lắng nghe** để kiểm foreground service.

## 2. File & hàm

### `lib/main.dart`

| Hàm/việc | Chi tiết |
|---|---|
| `main()` | `WidgetsFlutterBinding.ensureInitialized()` → `initCommunicationPort()` → `ListeningService.init()` → `AppAudioSession.configure()` (try/catch) → `AppDatabase.instance()` (try/catch) → `runApp` |
| `AiAssistantApp` | `MaterialApp` với `home: HomeScreen()`, theme `ColorScheme.fromSeed(Colors.teal)` |

**Thứ tự gọi là ràng buộc, không phải ngẫu nhiên:**
- `initCommunicationPort()` **phải** chạy trước `runApp` — mở port để `TaskHandler` (isolate riêng)
  trao đổi dữ liệu với UI.
- Mỗi mảnh hạ tầng bọc `try/catch` **riêng**: lỗi một mảnh không làm app chết (mục tiêu P0.5 là app
  phải mở được để chẩn đoán).

### `lib/ui/home_screen.dart`

| Thành phần | Ghi chú |
|---|---|
| `HomeScreen` / `_HomeScreenState` | `StatefulWidget` + `setState` (chưa có state management) |
| State cục bộ | `_serviceRunning`, `_busy`, `_databaseStatus`, `_hasApiKey`, `_permissions` |
| `initState()` | gọi `_refreshStatus()` |
| `_refreshStatus()` | 4 lời gọi plugin, **mỗi cái bọc try/catch riêng**; có `if (!mounted) return;` |
| `_toggleService()` | `ListeningService.stop()` / `.start()`, có `_busy` chặn bấm đúp, `finally` luôn refresh |
| `_statusCard()` | card trạng thái: icon + "Sẵn sàng"/"Đang lắng nghe" + bảng Quyền / Lưu trữ / API key |
| `_infoRow(label, value)` | dòng nhãn–giá trị (private, chưa trích ra shared widget) |
| Bọc ngoài | `WithForegroundTask` — giữ app sống khi bấm back cứng lúc service đang chạy |

## 3. API endpoints

**Không có.** App chưa gọi mạng ở bất kỳ đâu. `INTERNET` khai báo sẵn nhưng chỉ dùng từ P2 (LLM).

## 4. Local storage

Chỉ **đọc** để hiện trạng thái (không ghi/không đọc dữ liệu nghiệp vụ):
- SQLite: `AppDatabase.instance()` → `db.getVersion()` + `StorageConfig.databaseName`.
- Secure storage: `SecureStore.hasLlmApiKey()` → hiện "đã lưu" / "chưa có".

## 5. Test hiện có

`test/app_smoke_test.dart` — dựng `AiAssistantApp`, kiểm 3 text tồn tại: `'Trợ lý giao tiếp'`,
`'Bật lắng nghe'`, `'Sẵn sàng'`. Có **stub MethodChannel** của 4 plugin (foreground_task, sqflite,
secure_storage, permission_handler).

## 6. Việc còn thiếu

- [ ] **Chạy thật trên máy** (chưa từng) — mục tiêu chính của P0.5.
- [ ] Màn hình chẩn đoán này sẽ bị **thay thế/thu gọn** khi có UI thật (P3/P5).
- [ ] Bỏ style hardcode (`Colors.green`, `Colors.blueGrey`, `TextStyle(fontSize: 12, ...)`) — xem
      `design-system.md`.

## 7. Cảnh báo khi sửa

- **Không** đổi thứ tự khởi tạo trong `main()` (xem mục 2).
- **Không** bỏ `try/catch` quanh từng mảnh hạ tầng trong `main()` và trong `_refreshStatus()`.
- **Không** thêm gọi thẳng plugin mới vào UI — phải bọc qua lớp trong `services/` (xem
  `patterns.md` mục 2). Ngoại lệ hiện có (`WithForegroundTask`, `db.getVersion()`) là chấp nhận tạm,
  **không** được nhân rộng.
- **Không** biến màn hình chẩn đoán này thành màn hình sản phẩm — tính năng thật thuộc P1A trở đi.
