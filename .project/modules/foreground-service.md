# Module: foreground-service

Trạng thái: 🟡 **có code, chạy được trên lý thuyết, CHƯA test trên máy thật** (P0.5).
Đây là mảnh sống còn của app: không có nó thì app bị hệ thống giết khi tắt màn hình.

## 1. Mục đích

Giữ tiến trình sống khi màn hình tắt / app bị minimize, với notification cố định — điều kiện bắt buộc
để nghe hội thoại liên tục hàng chục phút. **Chưa có logic audio** (đó là P1A).

## 2. File & API (package `flutter_foreground_task` **11.0.3**)

### `lib/services/foreground_service.dart`

| Thành phần | Chi tiết |
|---|---|
| `listeningTaskCallback()` | Hàm **top-level** + `@pragma('vm:entry-point')`. Gọi `FlutterForegroundTask.setTaskHandler(ListeningTaskHandler())`. Xem cảnh báo mục 6 |
| `ListeningTaskHandler extends TaskHandler` | 3 override: `onStart(DateTime, TaskStarter)` → cập nhật notification; `onRepeatEvent(DateTime)` → **cố ý rỗng** (chỗ cho vòng đọc audio/VAD của P1A-P1B); `onDestroy(DateTime, bool isTimeout)` → log |
| `ListeningService.init()` | `FlutterForegroundTask.init(...)`: notification options + `ForegroundTaskOptions` (xem bảng dưới). Có cờ `_initialized` chống init 2 lần |
| `ListeningService.start()` | Chống chạy trùng (`isRunningService`) → `PermissionGate.ensureServicePermissions()` → `startService(serviceId, serviceTypes:[microphone], callback: listeningTaskCallback)` → kiểm lại `isRunningService`. Trả `bool` |
| `ListeningService.stop()` | `FlutterForegroundTask.stopService()` |

### Cấu hình `ForegroundTaskOptions` (đã chốt — mỗi giá trị có lý do)

| Option | Giá trị | Vì sao |
|---|---|---|
| `eventAction` | `repeat(5000 ms)` | `onRepeatEvent` mỗi 5s — P1A sẽ dùng mốc này cho vòng đọc audio |
| `autoRunOnBoot` | `false` | Không tự chạy khi khởi động máy — người dùng chủ động bật |
| `autoRunOnMyPackageReplaced` | `false` | Không tự bật lại sau khi update app |
| `allowWakeLock` | `true` | Giữ CPU thức (kèm quyền `WAKE_LOCK`) |
| `allowWifiLock` | `false` | Không cần — ASR offline |
| `stopWithTask` | `false` | **Cố ý**: người dùng vuốt app khỏi recent apps thì service vẫn chạy; chỉ dừng khi người dùng bấm nút |

### `lib/services/permission_gate.dart`

| Hàm | Chi tiết |
|---|---|
| `ensureServicePermissions()` | `Permission.microphone.request()` + `Permission.notification.request()`; trả `true` nếu **mic** được cấp |
| `currentStatus()` | Trả map `{microphone, notification}` để UI hiện (không xin gì) |

**Vì sao cần quyền ngay ở P0.5 dù chưa ghi âm:** từ **Android 14**, hệ thống **không cho** start
foreground service `type=microphone` nếu app chưa giữ `RECORD_AUDIO`; từ **Android 13**, notification
chỉ hiện khi đã cấp `POST_NOTIFICATIONS`. Ép cả hai ⇒ `start()` trả `false`, UI báo "Không bật được
service (thiếu quyền micro?)".

### Hằng số liên quan (`lib/core/constants.dart` → `ServiceConfig`)

`serviceId = 210`, `channelId = 'ai_assistant_listening'`, `channelName/notificationTitle = 'Đang lắng nghe'`,
`channelDescription`, `notificationText = 'Chạm để quay lại app'`, `repeatEventMs = 5000`.

### Manifest (`android/app/src/main/AndroidManifest.xml`)

Service `com.pravera.flutter_foreground_task.service.ForegroundService`,
`android:foregroundServiceType="microphone"`, `android:exported="false"`.
**Tên service không được đổi** (ràng buộc của plugin).

## 3. API endpoints

Không có.

## 4. Local storage

Không dùng. (Trạng thái service **không** được lưu — đọc trực tiếp từ `isRunningService`.)

## 5. Việc còn thiếu

- [ ] **Chạy thật trên máy**: service bật, notification hiện, sống qua vài phút khi tắt màn hình.
- [ ] Kiểm tra notification hiện đúng trên Android 13+ **và** 14+ (2 nhánh quyền khác nhau).
- [ ] P1A: bơm vòng đọc audio vào `onRepeatEvent`.
- [ ] (P7) Hướng dẫn loại app khỏi battery optimization nếu thực tế thấy service bị giết.

## 6. Cảnh báo khi sửa — ⚠ đọc trước khi đổi bất cứ gì ở đây

1. **`listeningTaskCallback` phải là hàm top-level + có `@pragma('vm:entry-point')`.** Nếu đổi thành
   method/closure, service sẽ không gọi được handler khi app ở nền. **Lỗi này không lộ ra khi test**
   (test chỉ chạy UI/Dart) — chỉ lộ khi chạy thật ở nền.
2. **Không đổi tên service trong Manifest.**
3. **KHÔNG được vứt bỏ bước kiểm quyền trước `startService`.** Trên Android 14+ thiếu `RECORD_AUDIO`
   là start thất bại (ném exception, đã bắt và trả `false`).
4. **`onRepeatEvent` ở phase này phải rỗng.** Prompt P0.5 cấm thêm logic audio vào đây; không "tiện
   tay" implement luôn P1A.
5. **Không chuyển logic sang isolate rồi giả định nó thấy được state của UI** — phải qua
   `initCommunicationPort` (đã gọi trong `main.dart`).
6. `stopWithTask: false` là **quyết định sản phẩm**, không phải mặc định — đừng "sửa cho đúng chuẩn".
