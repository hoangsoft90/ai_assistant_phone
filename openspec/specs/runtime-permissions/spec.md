# runtime-permissions Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P0.5, mở rộng P1F). Cập nhật 2026-09-23: thêm quyền
> `BLUETOOTH_CONNECT` (P1F) và `POST_NOTIFICATIONS`.
> Nguồn sự thật: `lib/services/permission_gate.dart`, `android/app/src/main/AndroidManifest.xml`,
> `test/app_smoke_test.dart`.

## Purpose

Xin và kiểm soát 8 quyền của app. Mỗi quyền tồn tại cho đúng một nhu cầu thật — KHÔNG xin quyền
"phòng khi". App không được chết khi thiếu quyền: màn hình chính hiện trạng thái để người dùng tự
bổ sung.

## Requirements

### Requirement: Bộ quyền tối thiểu đủ 8 nhu cầu thật

Manifest **PHẢI (MUST)** khai báo và `PermissionGate` **PHẢI (MUST)** kiểm các quyền sau (mỗi quyền
kèm nhu cầu — không bỏ được cái nào theo audit P7):

1. `RECORD_AUDIO` — thu mic (P1A). Bị từ vĩnh viễn ⇒ hiển thị hướng dẫn (K13: chưa có `openAppSettings()`).
2. `POST_NOTIFICATIONS` — thông báo (Android 13+; Android 12 trở xuống quyền không tồn tại — `pm grant` báo lỗi `Unknown permission` là bình thường).
3. `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MICROPHONE` — service nghe nền.
4. `BLUETOOTH_CONNECT` — **đọc thiết bị audio Bluetooth để TTS phát ra tai nghe (P1F)**. Thiếu quyền này ⇒ SafeTts không nhìn thấy tai nghe ⇒ không bao giờ phát (fail-closed).
5. `VIBRATE` — rung báo khi không phát được (P1F/P3).
6. `INTERNET` — **CHỈ** cho LLM (P2). Audio hội thoại KHÔNG được đi qua quyền này (ràng buộc #4).
7. `<queries> TTS_SERVICE` — tìm engine TTS (P1F).

#### Scenario: Máy Android 12 thiếu BLUETOOTH_CONNECT

- **GIVEN** app cài trên Android 12 mà quyền `BLUETOOTH_CONNECT` chưa cấp
- **WHEN** SafeTtsOutput đọc danh sách thiết bị output
- **THEN** không thấy tai nghe ⇒ mọi phát bị chặn fail-closed (không crash) — đúng lý do hướng dẫn test yêu cầu cấp đủ 3 quyền runtime trước khi test TTS

#### Scenario: Quyền notification không tồn tại

- **GIVEN** app chạy trên Android 12 (API 31 — `POST_NOTIFICATIONS` ra đời ở API 33)
- **WHEN** cố grant/quyền được kiểm
- **THEN** hệ thống báo quyền không tồn tại; app KHÔNG chết và vẫn hoạt động (bằng chứng buổi test adb 2026-09-23)

### Requirement: Trạng thái quyền hiện trên UI

Màn hình chính **PHẢI (MUST)** hiển thị dòng `Quyền` dạng `name=có/không · …` từ kết quả kiểm của
`PermissionGate` — người dùng (và người test) nhìn thấy ngay thiếu quyền nào.

#### Scenario: Thiếu microphone

- **GIVEN** `RECORD_AUDIO` bị từ chối
- **WHEN** màn hình chính vẽ bảng trạng thái
- **THEN** dòng `Quyền` hiện `microphone=không`; bấm "Bật lắng nghe" không mở được mic và báo lỗi có kiểm soát
