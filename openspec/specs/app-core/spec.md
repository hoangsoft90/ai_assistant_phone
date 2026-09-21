# app-core Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P0.5). Không phải đề xuất.
> Gộp 3 capability nhỏ đã được người dùng duyệt: **core-logging** + **app-constants** +
> **ui-smoke-test** (test khoá hành vi duy nhất hiện có).
> Nguồn sự thật: `lib/core/app_logger.dart`, `lib/core/constants.dart`, `test/app_smoke_test.dart`.

## Purpose

Tầng thấp nhất của app, mọi tầng đều được phép import, **không được import ngược** (`lib/core/README.md`):
- **`AppLogger`** — logger duy nhất của app qua `dart:developer` (xem được bằng `adb logcat`), thay
  thế `print` (bị cấm bởi lint `avoid_print`).
- **Hằng số** (`AppInfo` / `ServiceConfig` / `StorageConfig`) — mọi "giá trị ma thuật" tập trung một
  chỗ để phase sau không phải sửa rải rác.
- **Smoke test** — kiểm khung UI dựng được, có stub MethodChannel cho 4 plugin.

## Requirements

### Requirement: Logger với 4 mức

`AppLogger` (`lib/core/app_logger.dart:11-41`) **PHẢI (MUST)**:
- Được khởi tạo bằng `const AppLogger(tag)` (:12)
- Cung cấp 4 hàm log: `debug`, `info`, `warn`, `error` (:16-23) — `warn` nhận thêm `error` tuỳ chọn,
  `error` nhận `error` + `stackTrace` tuỳ chọn
- Ghi qua `dart:developer` `log()` với `name = '<tag>/<level>'` (:26-31)
- Map mức sang giá trị số: `debug=500`, `info=800`, `warn=900`, `error=1000` (:35-40)

#### Scenario: Ghi log info

- **GIVEN** `static const AppLogger _log = AppLogger('ListeningService')` đã khai báo
- **WHEN** `_log.info('service đã chạy sẵn')` được gọi
- **THEN** một bản ghi `developer.log` được tạo với `name: 'ListeningService/info'`, `level: 800`; khi chạy trên thiết bị, bản ghi này xem được qua `adb logcat`

#### Scenario: Ghi log error kèm stackTrace

- **GIVEN** một exception đã được bắt trong `catch`
- **WHEN** `_log.error('startService lỗi', error, stackTrace)` được gọi
- **THEN** bản ghi log mang `name: '<tag>/error'`, `level: 1000`, kèm cả `error` object và `stackTrace` để truy vết

### Requirement: Cấm print

Codebase **PHẢI (MUST)** dùng `AppLogger`, **KHÔNG ĐƯỢC** dùng `print`/`debugPrint` — lint
`avoid_print` đã bật trong `analysis_options.yaml`.

#### Scenario: Thêm `print` vào code

- **GIVEN** `analysis_options.yaml` đã bật `avoid_print: true`
- **WHEN** ai đó thêm `print('...')` vào một file Dart rồi chạy `flutter analyze`
- **THEN** analyzer báo lỗi `avoid_print` — vi phạm bị chặn trước khi vào repo

### Requirement: Hằng số tập trung ở core

Các hằng sau **PHẢI (MUST)** được tham chiếu từ `lib/core/constants.dart`, **KHÔNG ĐƯỢC** hardcode chỗ khác:

| Nhóm | Hằng | Giá trị | Dòng |
|---|---|---|---|
| `AppInfo` | `displayName` | `'Trợ lý giao tiếp'` | :9 |
| `ServiceConfig` | `serviceId` | `210` | :17 |
| `ServiceConfig` | `channelId` | `'ai_assistant_listening'` | :19 |
| `ServiceConfig` | `channelName` / `notificationTitle` | `'Đang lắng nghe'` | :20, :23 |
| `ServiceConfig` | `channelDescription` | `'Hiện khi trợ lý đang nghe hội thoại.'` | :21 |
| `ServiceConfig` | `notificationText` | `'Chạm để quay lại app'` | :24 |
| `ServiceConfig` | `repeatEventMs` | `5000` | :27 |
| `StorageConfig` | `databaseName` | `'ai_assistant.db'` | :34 |
| `StorageConfig` | `databaseVersion` | `1` | :35 |
| `StorageConfig` | `llmApiKeyKey` | `'llm_api_key'` | :38 |

#### Scenario: Đổi tên kênh thông báo

- **GIVEN** mã nguồn hiện tại
- **WHEN** cần đổi `channelId` (vd: vì lý do hợp nhất kênh trên thiết bị)
- **THEN** chỉ cần sửa **một** dòng trong `constants.dart` — mọi nơi dùng (`foreground_service.dart`, test stub, ...) đều tự cập nhật qua tham chiếu `ServiceConfig.channelId`

### Requirement: Smoke test với stub plugin

`test/app_smoke_test.dart` **PHẢI (MUST)**:
1. Stub MethodChannel trả `null` cho đúng 4 kênh plugin (`:18-27`): `flutter_foreground_task/methods`,
   `com.tekartik.sqflite`, `plugins.it_nomads.com/flutter_secure_storage`,
   `flutter.baseflow.com/permissions/methods`
2. Chạy **một** test widget: dựng `AiAssistantApp` rồi assert 3 text tồn tại (`:29-37`):
   `'Trợ lý giao tiếp'`, `'Bật lắng nghe'`, `'Sẵn sàng'`

#### Scenario: Chạy flutter test trên máy không có native

- **GIVEN** môi trường `flutter test` không có plugin native
- **WHEN** smoke test chạy
- **THEN** 4 kênh plugin trả `null` thay vì `MissingPluginException`; widget dựng được; cả 3 assert pass — test này chỉ khoá phần Dart/UI, không khoá hành vi native

#### Scenario: Thêm plugin mới quên stub

- **GIVEN** một plugin mới được thêm vào `pubspec.yaml` nhưng tên MethodChannel của nó **không** được thêm vào danh sách stub (`:18-23`)
- **WHEN** `flutter test` chạy
- **THEN** lời gọi plugin từ widget trong test ném `MissingPluginException` → test đỏ (cơ chế này là lý do danh sách stub phải cập nhật cùng dependency — quy ước đã ghi trong `operating_rules.md` rule 12)

#### Scenario: Màn hình chính mất nút bật lắng nghe

- **GIVEN** ai đó xoá/nhầm nhãn nút trong `HomeScreen`
- **WHEN** smoke test chạy
- **THEN** `expect(find.text('Bật lắng nghe'), findsOneWidget)` thất bại → test đỏ, phát hiện UI khung bị hỏng trước khi commit

## Cần làm rõ

1. **Tên channel stub là chuỗi hardcode trong test** — không tham chiếu hằng từ plugin. Nếu plugin
   đổi tên channel ở version sau (đã từng xảy ra với `flutter_foreground_task` v11), test sẽ đỏ
   theo cách khó hiểu (`MissingPluginException` thay vì "stub sai tên"). Chưa rõ có nên đặt danh
   sách này thành hằng có comment "cập nhật khi nâng plugin" không.
2. **`_levelValue` dùng switch expression** (`:35-40`) — không có test nào cho mapping 4 mức; nếu
   thêm mức mới (vd `fatal`) mà quên thêm nhánh, analyzer bắt được (switch expression là exhaustive)
   nên rủi ro thấp, nhưng hành vi số level hiện chưa được khoá bằng test.
3. **`AppInfo.displayName` dùng ở 2 nơi** (`main.dart` title + test) nhưng `android:label` trong
   Manifest là chuỗi riêng ("Trợ lý giao tiếp" — viết tay) — 2 nguồn sự thật có thể lệch nhau khi
   đổi tên app. Chưa rõ ý định giữ 2 chỗ hay gộp.
