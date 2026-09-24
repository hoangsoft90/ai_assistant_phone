# Module: bootstrap-shell

Trạng thái: 🟡 **khung có thật, một phần đã chạy trên máy thật** (adb 2026-09-23: T0 quyền/FGS/mic ✅,
DB đọc được ✅). Khởi tạo + UI hiện nay do **P5.3** tổ chức lại — module này chỉ giữ phần `main()`
và lịch sử màn hình chẩn đoán.

## 1. Mục đích

- Dựng hạ tầng (foreground service, audio session, database) **trước** `runApp`.
- Màn hình chính tổ chức thông tin trạng thái để test tay trên máy thật **không phải đọc log**.
- Nút **Bật/Tắt lắng nghe** để kiểm foreground service.

## 2. File & hàm

### `lib/main.dart`

| Hàm/việc | Chi tiết |
|---|---|
| `main()` | `WidgetsFlutterBinding.ensureInitialized()` → `initCommunicationPort()` → `ListeningService.init()` → `AppAudioSession.configure()` (try/catch) → `AppDatabase.instance()` (try/catch) → `runApp` |
| `AiAssistantApp` | `MaterialApp` với **`home: RootScaffold()`** (từ P5.3 — trước đây là `HomeScreen()`), theme `ColorScheme.fromSeed(Colors.teal)` |

**Thứ tự gọi là ràng buộc, không phải ngẫu nhiên (ràng buộc #9 AGENTS.md):**
- `initCommunicationPort()` **phải** chạy trước `runApp` — mở port để `TaskHandler` (isolate riêng)
  trao đổi dữ liệu với UI.
- Mỗi mảnh hạ tầng bọc `try/catch` **riêng**: lỗi một mảnh không làm app chết (mục tiêu P0.5 là app
  phải mở được để chẩn đoán).

### UI hiện tại (sau P5.3)

| File | Vai trò |
|---|---|
| `lib/ui/root_scaffold.dart` | Điểm vào UI: **`ScaffoldMessenger(key: _messengerKey)` bao NGOÀI `Scaffold`** (fix SnackBar 2026-09-24) + `BottomNavigationBar` 4 tab (Trang chủ/Lịch sử/Thống kê/Cài đặt) + `IndexedStack` giữ state tab + `Stack` đè `GlobalFloatingControls` |
| `lib/ui/global_floating_controls.dart` | Nút nổi toàn cục: Bật/Dừng lắng nghe (1 nút đổi trạng thái), Kết thúc buổi (chỉ bật khi phiên chạy), Làm mới, `SuggestFloatingButton` (P3) — bấm được ở **mọi** tab |
| `lib/ui/home_tab.dart` | Card trạng thái rút gọn (4 dòng) + **15 dòng chẩn đoán gom `ExpansionTile` "Chi tiết kỹ thuật" mặc định ĐÓNG** + lối vào Pre-Brief |
| `lib/ui/settings_tab.dart` | Gom mọi cấu hình: LLM (key/endpoint/model), output mode, tốc độ đọc, Training Level, retention, engine ASR |
| `lib/ui/home_screen.dart` | **Shim** — re-export `RootScaffold`, giữ tên class cho tương thích tham chiếu cũ |
| `lib/ui/session_coordinator.dart` | State + logic phiên dùng chung (tách từ `HomeScreen` cũ, P5.3): `ChangeNotifier`, SnackBar qua `messengerKey`, hàng đợi snack `_drainSnackQueue` chờ **4.1s/snack**; bơm được `pendingAnalysis` / `testLlm` cho test |

> Lịch sử: `HomeScreen` gốc (P0.5) là 1 màn nhồi mọi nút + card chẩn đoán 15 dòng; P5.3 tách thành
> 4 tab + nút nổi toàn cục mà **không viết lại logic nghiệp vụ** (chi tiết `.plan/P5_3-result.md`).

## 3. API endpoints

**Không có ở tầng bootstrap.** `INTERNET` trong Manifest chỉ phục vụ LLM từ P2 (chi tiết
`suggestion-engine.md`). App cố ý không có backend/auth (ràng buộc #6).

## 4. Local storage

Chỉ **đọc** để hiện trạng thái (không ghi/không đọc dữ liệu nghiệp vụ):
- SQLite: `AppDatabase.instance()` → schema **v6** (P5.4) — chi tiết `transcript-store.md`.
- Secure storage: `SecureStore.hasLlmApiKey()` → hiện "đã lưu" / "chưa có".

## 5. Test hiện có

- `test/app_smoke_test.dart` — đã cập nhật theo cấu trúc P5.3; stub MethodChannel của các plugin.
- `test/p5_3_navigation_test.dart` — 7 test nav: 4 tab, nút nổi ở mọi tab (`findsOneWidget`),
  không trùng nút, IndexedStack giữ state. **Bơm `_FakeCapture` + `flushSnackTimers`** (A60/A61) —
  đọc trước khi viết test UI mới.
- `test/snackbar_visibility_test.dart` — 4 test **SnackBar hiện thật trong cây `RootScaffold` đầy đủ**
  (Test LLM thành công/thất bại, Bật lắng nghe từ tab Trang chủ, từ tab Lịch sử). Bất biến khoá lỗi
  cũ: SnackBar **không** có tổ tiên `IndexedStack`. Bơm `_FakeTestLlm` qua tham số `testLlm`.

## 6. Việc còn thiếu

- [ ] **K51:** verify nhóm bổ sung trên máy thật (nav 4 tab, migration DB có sẵn v2→v4, đổi tên
      phiên, retention, LLM endpoint) — APK mới đã có artifact CI (`app-debug-apk`).

## 7. Cảnh báo khi sửa

- **Không** đổi thứ tự khởi tạo trong `main()` (xem mục 2).
- **Không** bỏ `try/catch` quanh từng mảnh hạ tầng trong `main()`.
- **Không** thêm gọi thẳng plugin mới vào UI — phải bọc qua lớp trong `services/` (xem
  `patterns.md` mục 2).
- **P5.3 khoá:** không sửa `floating_button.dart` (chỉ đổi chỗ mount); không để 2 nơi cùng 1 hành
  động phiên (mỗi hành động đúng 1 điểm bấm — có test khoá).
- **`ScaffoldMessenger` phải ở NGOÀI `Scaffold`** trong `root_scaffold.dart` — `Scaffold` chỉ đăng ký
  được với messenger ở **tổ tiên** của nó. Đặt messenger vào `Scaffold.body` (đúng như bản trước
  2026-09-24) làm SnackBar bị vẽ trong `Scaffold` của tab đang offstage trong `IndexedStack` ⇒ **bấm
  nút ở tab Cài đặt/Trang chủ không thấy thông báo gì**. Sửa lại thứ tự này là **tái tạo bug**; test
  khoá ở `test/snackbar_visibility_test.dart` (bất biến "SnackBar không có tổ tiên `IndexedStack`").
- **Không xoá dòng chẩn đoán** khi sửa `home_tab.dart` — chỉ gom vào ExpansionTile (15 dòng giữ đủ).
- Thêm timer/delay mới vào `SessionCoordinator` ⇒ phải cập nhật `flushSnackTimers` trong test
  (A61); thêm member mới vào DAO ⇒ cập nhật mọi fake `implements` (A24).
