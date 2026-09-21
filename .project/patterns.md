# patterns.md — Pattern code đang dùng

Cập nhật: 2026-09-21 (+07).

> Quy tắc: file này chỉ ghi pattern **thực sự có trong code**. Pattern nào mới là kế hoạch thì nằm
> ở mục 5 và ghi rõ "chưa có", để agent sau không tưởng là đã dùng.

## 1. Namespace pattern — `abstract final class` + `static` (đang dùng, chủ đạo)

Mọi lớp bọc plugin/hạ tầng đều là `abstract final class` với thành viên `static`:

```dart
abstract final class ListeningService {   // lib/services/foreground_service.dart
  static const AppLogger _log = AppLogger('ListeningService');
  static Future<bool> start() async { ... }
  static Future<void> stop() async { ... }
}
```

Các lớp theo pattern này: `AppInfo`, `ServiceConfig`, `StorageConfig` (core/constants.dart),
`AppLogger`, `ListeningService`, `PermissionGate`, `AppDatabase`, `SecureStore`, `AppAudioSession`.

**Vì sao:** (1) chặn `extends`/`implements` ngoài ý muốn, (2) không cần khởi tạo, (3) không cần DI
container ở phase này, (4) `const` logger là hằng compile-time nên không tốn gì.

**Khi nào phải bỏ pattern này:** khi cần **2 instance cùng lúc** hoặc cần **mock trong test**. Cụ thể
là P1C/P1D — hai ASR engine phải cùng tồn tại sau một interface chung (xem mục 5).

## 2. Adapter/wrapper quanh plugin (đang dùng)

UI **không bao giờ** gọi thẳng package bên thứ ba; chỉ gọi qua lớp bọc trong `services/`:

| Plugin | Lớp bọc | File |
|---|---|---|
| `flutter_foreground_task` | `ListeningService`, `ListeningTaskHandler` | `lib/services/foreground_service.dart` |
| `permission_handler` | `PermissionGate` | `lib/services/permission_gate.dart` |
| `sqflite` + `path` | `AppDatabase` | `lib/services/storage/app_database.dart` |
| `flutter_secure_storage` | `SecureStore` | `lib/services/storage/secure_store.dart` |
| `audio_session` | `AppAudioSession` | `lib/audio/app_audio_session.dart` |

**Ngoại lệ có kiểm soát:** `ui/home_screen.dart` import trực tiếp `flutter_foreground_task` (cho
`WithForegroundTask`) và `sqflite` (để gọi `db.getVersion()` khi hiện trạng thái trên màn hình chẩn
đoán). Đây là chấp nhận tạm cho màn hình chẩn đoán — **không** được nhân rộng ra màn hình khác.

## 3. Pattern `@pragma('vm:entry-point')` cho callback isolate (đang dùng — dễ sai)

```dart
@pragma('vm:entry-point')
void listeningTaskCallback() {
  FlutterForegroundTask.setTaskHandler(ListeningTaskHandler());
}
```

**Bắt buộc**: hàm top-level + annotation. Nếu không, isolate mới của service sẽ không gọi được hàm
khi app ở nền — lỗi chỉ lộ ra khi app thực sự chạy nền, không lộ khi test. Không được chuyển hàm này
vào trong class hay biến nó thành closure.

## 4. Dependency Injection: KHÔNG có

Chưa dùng `get_it`, `riverpod`, hay constructor injection. Thay thế hiện tại là `static` + lớp bọc.
Lý do: phase bootstrap chưa có gì cần inject. **Mốc xem lại:** P1C (2 ASR engine) hoặc P1B (state
machine) — chỗ đầu tiên thực sự cần thay thế implementation trong test.

## 5. Pattern đã ĐỊNH dùng nhưng CHƯA có trong code

| Pattern | Sẽ dùng ở | Ghi chú |
|---|---|---|
| **Engine abstraction** (interface chung cho ASR) | **P1D** | Điều kiện để PhoWhisper và Vosk thay nhau được; prompt P1D nói rõ "abstraction" |
| **Repository / Store** (lớp truy cập dữ liệu cho transcript) | **P1E** | `AppDatabase` hiện chỉ mở DB, chưa phải repository |
| **Policy object** (luật lọc gợi ý trước khi hiển thị) | **P2** | Tách khỏi phần gọi LLM |
| **State machine** | **P1B** | Xem [state-routing.md](state-routing.md) |
| Factory / Builder | chưa có kế hoạch | Chỉ thêm nếu thật cần — theo tinh thần chống over-engineering của `AGENTS.md` |
| BLoC | **không có kế hoạch** | Đừng tự thêm |

## 6. Xử lý lỗi (đang dùng — có quy ước rõ)

- **Bootstrap (`main.dart`)**: mỗi mảnh hạ tầng bọc `try/catch` riêng, lỗi chỉ **ghi log** chứ không
  làm app chết. Mục tiêu P0.5 là app vẫn mở được để chẩn đoán.
- **`ListeningService.start()`**: nuốt lỗi, log rồi trả `false` — UI hiện thông báo "Không bật được
  service (thiếu quyền micro?)".
- **`HomeScreen._refreshStatus()`**: mỗi lời gọi plugin bọc `try/catch` riêng; lỗi một mảnh không
  làm hỏng trạng thái các mảnh còn lại.
- **Luôn `if (!mounted) return;`** trước `setState` trong async callback.
- Trả `bool`/giá trị thay vì ném exception ở ranh giới UI ↔ hạ tầng.

⚠ **Cảnh báo cho các phase sau:** pattern "nuốt lỗi, log rồi trả false" **chấp nhận được cho màn hình
chẩn đoán**, nhưng **KHÔNG được** áp cho P1F (SafeTtsOutput): ở đó lỗi phải dẫn tới **không phát gì**,
chứ không được rơi vào nhánh phát ra loa ngoài. Đừng copy khuôn `try/catch → false` sang code an toàn.

## 7. Logging (đang dùng)

- Dùng `AppLogger` (`lib/core/app_logger.dart`) → `dart:developer` → xem được bằng `adb logcat`.
- Cấm `print` (lint `avoid_print`).
- Tag theo `Tên/tầng`; ví dụ `AppLogger('ListeningTaskHandler')` cho isolate của service.
- Logger là `static const` ở mọi lớp → không tạo logger mới trong mỗi lần gọi hàm.

## 8. Quy ước test (đang dùng)

- Test đặt ở `test/`, tên file `*_test.dart` (bắt buộc — `flutter test` chỉ nhận hậu tố này).
- Plugin native phải được **stub MethodChannel** trong `setUp` (xem `test/app_smoke_test.dart`).
  Khi thêm plugin mới → thêm tên channel vào danh sách stub, nếu không test đỏ vì thiếu native.
- Test hiện tại chỉ kiểm UI/Dart; logic thật (service, DB, quyền) phải kiểm trên máy thật.
