# runtime-permissions Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P0.5). Không phải đề xuất.
> Nguồn sự thật: `lib/services/permission_gate.dart`, `android/app/src/main/AndroidManifest.xml`.

## Purpose

Xin và kiểm tra các quyền runtime cần để foreground service `type=microphone` chạy được:
từ Android 14, hệ thống **không cho** start foreground service `microphone` khi app chưa giữ
`RECORD_AUDIO`; từ Android 13, notification của foreground service chỉ hiện khi đã cấp
`POST_NOTIFICATIONS`. Ở giai đoạn hiện tại app chưa thu âm — quyền xin ở đây là plumbing bắt buộc
của DoD P0.5 ("service chạy được, hiện notification"), không phải logic audio.

## Requirements

### Requirement: Xin quyền trước khi bật service

`PermissionGate.ensureServicePermissions()` (`lib/services/permission_gate.dart:18-24`) **PHẢI (MUST)**:
1. `Permission.microphone.request()`
2. `Permission.notification.request()`
3. Ghi log cả 2 trạng thái với tên status (`microphone=<name>, notification=<name>`)
4. Return `true` **chỉ khi** quyền microphone `isGranted`; trạng thái notification **không** ảnh
   hưởng giá trị trả về

#### Scenario: Người dùng cấp cả hai quyền

- **GIVEN** app chưa có quyền mic và notification
- **WHEN** `ensureServicePermissions()` được gọi
- **THEN** hệ thống hiện 2 dialog xin quyền (mic trước, notification sau); nếu người dùng cấp cả hai, hàm ghi log "quyền: microphone=granted, notification=granted" và return `true`

#### Scenario: Người dùng từ chối quyền mic nhưng cấp notification

- **GIVEN** người dùng từ chối `RECORD_AUDIO` nhưng cấp `POST_NOTIFICATIONS`
- **WHEN** `ensureServicePermissions()` chạy
- **THEN** hàm return `false` (chỉ quyền mic quyết định) — hệ quả: `ListeningService.start()` sẽ **không** gọi `startService`

#### Scenario: Người dùng từ chối vĩnh viễn (don't ask again)

- **GIVEN** quyền mic đang ở trạng thái `permanentlyDenied`
- **WHEN** `ensureServicePermissions()` chạy
- **THEN** `request()` không hiện dialog nữa; hàm return `false`. **Code hiện không mở settings cho
  người dùng** (không có lời gọi `openAppSettings()`) — người dùng không có đường thoát trong app

### Requirement: Đọc trạng thái quyền không xin thêm

`PermissionGate.currentStatus()` (`permission_gate.dart:26-29`) **PHẢI (MUST)** trả về
`Map<String, bool>` với đúng 2 khóa `'microphone'` và `'notification'`, giá trị là
`isGranted` tương ứng, **mà không** hiện dialog xin quyền nào.

#### Scenario: UI đọc trạng thái để hiển thị

- **GIVEN** app đang chạy, người dùng chưa thao tác gì thêm
- **WHEN** `currentStatus()` được gọi (từ `HomeScreen._refreshStatus()`)
- **THEN** trả về map `{microphone: <bool>, notification: <bool>}` phản ánh trạng thái cấp hiện tại; không có dialog nào xuất hiện

### Requirement: Quyền khai báo trong Manifest

7 quyền khai báo tĩnh (`AndroidManifest.xml:5-14`): `RECORD_AUDIO`, `FOREGROUND_SERVICE`,
`FOREGROUND_SERVICE_MICROPHONE`, `BLUETOOTH_CONNECT`, `POST_NOTIFICATIONS`, `INTERNET`, `WAKE_LOCK`.
Quyền runtime **PHẢI (MUST)** nằm trong danh sách mà `PermissionGate` xin (mic, notification) hoặc
được ghi chú rõ là "khai báo cho tương lai" (BLUETOOTH_CONNECT, INTERNET — xem Cần làm rõ).

#### Scenario: Quyền mic được xin có trong Manifest

- **GIVEN** Manifest đã khai báo `RECORD_AUDIO` (:5)
- **WHEN** `Permission.microphone.request()` chạy
- **THEN** hệ thống hiện dialog xin quyền (nếu Manifest thiếu quyền này, plugin sẽ fail — đây là điều kiện để scenario "Xin quyền" ở trên chạy được)

## Cần làm rõ

1. **`permanentlyDenied` không có đường thoát trong app** (không gọi `openAppSettings()`). Người dùng
   từ chối vĩnh viễn sẽ không thể bật service bao giờ, và UI chỉ báo "Không bật được service (thiếu
   quyền micro?)". Chưa rõ ý định: bỏ sót hay cố ý để sau (P1A mới thật sự cần mic)?
2. **Kết quả xin quyền notification bị bỏ qua** — `ensureServicePermissions()` chỉ return theo mic
   (:22-24). Nếu notification bị từ chối, service vẫn start nhưng notification có thể không hiện
   (Android 13+). Không có cảnh báo nào cho người dùng trong trường hợp này; chưa rõ có phải chủ ý.
3. **`BLUETOOTH_CONNECT` và `INTERNET` được khai báo nhưng không xin runtime ở đâu trong code** —
   `PermissionGate` chỉ đụng mic + notification. `BLUETOOTH_CONNECT` là quyền runtime (Android 12+)
   nên về lý thuyết cũng phải xin; hiện không ai xin và không ai dùng (thuộc P1F). `INTERNET` là
   quyền thường. Cả hai đều là khai báo "cho tương lai" — phù hợp ghi chú P0.5 nhưng cần quyết định
   khi nào xin thật.
4. **Không có test nào cho `PermissionGate`** — hành vi "return chỉ theo mic" chỉ được đảm bảo bằng
   code, chưa có test khoá hành vi này.
