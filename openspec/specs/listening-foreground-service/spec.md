# listening-foreground-service Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P0.5). Không phải đề xuất.
> Nguồn sự thật: `lib/services/foreground_service.dart`, `android/app/src/main/AndroidManifest.xml`,
> `lib/core/constants.dart`.

## Purpose

Giữ tiến trình app sống khi màn hình tắt / app bị minimize bằng Android foreground service với
notification cố định — điều kiện bắt buộc để app nghe hội thoại liên tục hàng chục phút (tính năng
thu âm thật thuộc P1A, **chưa tồn tại trong code**). Ở giai đoạn hiện tại service chỉ sống và cập
nhật notification; `onRepeatEvent` được **cố ý** để rỗng.

## Requirements

### Requirement: Khai báo service và quyền trên Manifest

- Service `com.pravera.flutter_foreground_task.service.ForegroundService` **PHẢI (MUST)** được khai báo với
  `android:foregroundServiceType="microphone"` và `android:exported="false"`
  (`android/app/src/main/AndroidManifest.xml:48-51`). **Tên service không được đổi** — ràng buộc của plugin.
- Manifest **PHẢI (MUST)** khai báo đủ 7 quyền: `RECORD_AUDIO` (:5), `FOREGROUND_SERVICE` (:6),
  `FOREGROUND_SERVICE_MICROPHONE` (:7), `BLUETOOTH_CONNECT` (:9), `POST_NOTIFICATIONS` (:11),
  `INTERNET` (:12), `WAKE_LOCK` (:14).

#### Scenario: Service được khai báo đúng type

- **GIVEN** app đã build (chưa từng được xác minh — xem `Cần làm rõ` mục 1)
- **WHEN** hệ thống đọc Manifest
- **THEN** thấy đúng một service của plugin `flutter_foreground_task` với `foregroundServiceType="microphone"`, không exported

### Requirement: Callback của isolate là hàm top-level có entry-point pragma

Hàm đăng ký TaskHandler **PHẢI (MUST)** là hàm top-level và **PHẢI (MUST)** có
`@pragma('vm:entry-point')` (`lib/services/foreground_service.dart:11-14`), nếu không isolate mới
của service sẽ không gọi được khi app ở nền.

#### Scenario: Service bắt đầu chạy ở nền

- **GIVEN** service được start và engine tạo isolate riêng cho callback
- **WHEN** isolate gọi entry point
- **THEN** `listeningTaskCallback()` chạy và đăng ký `ListeningTaskHandler` qua
  `FlutterForegroundTask.setTaskHandler(...)`

### Requirement: Cấu hình service cố định

`ListeningService.init()` (`foreground_service.dart:50-77`) **PHẢI (MUST)** cấu hình:
- Notification: `channelId='ai_assistant_listening'`, `channelName='Đang lắng nghe'`, `onlyAlertOnce: true`
  (hằng ở `lib/core/constants.dart:19-21,23-24`)
- `eventAction = ForegroundTaskEventAction.repeat(5000)` — hằng `ServiceConfig.repeatEventMs` (`constants.dart:27`)
- `autoRunOnBoot: false` (:67), `autoRunOnMyPackageReplaced: false`, `allowWakeLock: true` (:69),
  `allowWifiLock: false`, `stopWithTask: false` (:73)
- `init()` có cờ `_initialized` chống khởi tạo 2 lần (:49, :74-76)

#### Scenario: Init được gọi nhiều lần

- **GIVEN** `ListeningService.init()` đã được gọi (vd: trong `main()`)
- **WHEN** `start()` được gọi (nó gọi `init()` lại — `foreground_service.dart:84`)
- **THEN** `init()` return ngay không cấu hình lại (cờ `_initialized`), không có side-effect thứ hai

#### Scenario: Người dùng vuốt app khỏi recent apps

- **GIVEN** service đang chạy với `stopWithTask: false` (:73)
- **WHEN** người dùng vuốt app khỏi recent apps
- **THEN** service **không** bị dừng theo task (quyết định sản phẩm: chỉ người dùng bấm nút mới tắt)

### Requirement: Start service phải qua kiểm quyền và chống chạy trùng

`ListeningService.start()` (`foreground_service.dart:83-113`) **PHẢI (MUST)**:
1. Nếu `isRunningService` đã true → return `true` **mà không** start lại (:86-89)
2. Gọi `PermissionGate.ensureServicePermissions()`; nếu không được cấp quyền mic → log warn và
   return `false` (:91-95) — **không** gọi `startService`
3. Gọi `FlutterForegroundTask.startService` với `serviceId: 210` (`constants.dart:17`),
   `serviceTypes: [ForegroundServiceTypes.microphone]` (:97-102)
4. Kiểm lại `isRunningService` sau khi start và trả kết quả đó (:105-107)
5. Mọi exception → log error và return `false` (:108-111) — **không** ném tiếp lên UI

#### Scenario: Bật service khi đã đủ quyền

- **GIVEN** app đã được cấp `RECORD_AUDIO` và service chưa chạy
- **WHEN** `ListeningService.start()` được gọi
- **THEN** `startService` được gọi với serviceId 210 + type microphone + callback `listeningTaskCallback`; kết quả trả về là trạng thái `isRunningService` sau lệnh

#### Scenario: Bật service khi thiếu quyền mic

- **GIVEN** người dùng từ chối `RECORD_AUDIO`
- **WHEN** `ListeningService.start()` được gọi
- **THEN** `startService` **không** được gọi; hàm ghi log warn "thiếu quyền RECORD_AUDIO — không thể bật service type=microphone" và return `false` (UI sẽ hiện "Không bật được service (thiếu quyền micro?)")

#### Scenario: Bật service khi nó đã chạy sẵn

- **GIVEN** `isRunningService` trả `true`
- **WHEN** `ListeningService.start()` được gọi
- **THEN** ghi log "service đã chạy sẵn" và return `true` ngay, không gọi `startService` lần hai

#### Scenario: startService ném exception

- **GIVEN** plugin lỗi khi start (vd: hệ thống chặn)
- **WHEN** `ListeningService.start()` chạy
- **THEN** exception bị bắt trong `catch`, ghi log error kèm stackTrace, và hàm return `false` — không crash app

### Requirement: TaskHandler chỉ giữ service sống

`ListeningTaskHandler` (`foreground_service.dart:20-41`) **PHẢI (MUST)**:
- `onStart(DateTime, TaskStarter)`: cập nhật notification với title/text từ `ServiceConfig` (:24-31)
- `onRepeatEvent(DateTime)`: **thân hàm rỗng** — chỉ là chỗ cho vòng audio/VAD của P1A-P1B (:33-36)
- `onDestroy(DateTime, bool isTimeout)`: chỉ ghi log (:38-40)

#### Scenario: Chu kỳ lặp của service

- **GIVEN** service đang chạy (repeat mỗi 5000ms)
- **WHEN** `onRepeatEvent` được gọi theo chu kỳ
- **THEN** không có hành vi gì xảy ra (thân rỗng) — ở P0.5 service không thu/thả gì cả

#### Scenario: Service bị hủy

- **GIVEN** service đang chạy
- **WHEN** hệ thống/service dừng
- **THEN** `onDestroy` ghi log "service destroyed (isTimeout=...)" kèm giá trị timeout

### Requirement: Stop service

`ListeningService.stop()` (`foreground_service.dart:115-121`) **PHẢI (MUST)** gọi
`FlutterForegroundTask.stopService()`; exception → log error, **không** ném tiếp.

#### Scenario: Tắt service

- **GIVEN** service đang chạy
- **WHEN** `ListeningService.stop()` được gọi
- **THEN** `stopService()` được gọi; nếu plugin ném exception thì lỗi được ghi log và không lan lên UI

## Cần làm rõ

1. **Toàn bộ hành vi runtime của service CHƯA được xác minh trên thiết bị thật** — APK chưa từng
   được build (máy dev không có Android SDK). Các scenario trên mô tả code, không phải hành vi đã
   quan sát. Cần chạy app thật trước khi coi spec này là "đã verify".
2. **`stopWithTask: false` + `allowWakeLock: true`**: không rõ đã cân nhắc chính sách pin/battery
   optimization của từng hãng (Xiaomi/Samsung có thể kill service) — chưa có chiến lược nào trong
   code xử lý việc service bị hệ thống giết ngoài `onDestroy` log.
3. **Không có API nào cho UI biết service bị hệ thống dừng đột ngột** (không có listener/observer
   ngoài `isRunning()` phải chủ động poll). Chưa rõ ý định: P1B sẽ cần biết trạng thái thật.
4. **`serviceId = 210`** (`constants.dart:17`): không có comment/căn cứ vì sao chọn số này; nếu trùng
   id của app khác thì hệ thống vẫn cho chạy nhưng nên ghi rõ nguồn gốc.
5. **`onStart` cập nhật notification bằng lại hằng số** dù `startService` đã truyền cùng title/text
   (`foreground_service.dart:97-102` so với `:26-29`) — trùng lặp vô hại nhưng chưa rõ ai là nguồn
   sự thật duy nhất cho nội dung notification.
