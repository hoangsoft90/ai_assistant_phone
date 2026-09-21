# app-bootstrap Specification

> Baseline spec — mô tả hành vi ĐÃ implement trong code hiện tại (P0.5). Không phải đề xuất tính năng mới.
> Nguồn sự thật: `lib/main.dart`, `lib/ui/home_screen.dart`.

## Purpose

Khởi động ứng dụng theo thứ tự bắt buộc: mở kênh giao tiếp cho isolate của foreground service, khởi
tạo cấu hình service, cấu hình audio session, mở SQLite, rồi mới dựng UI. Mỗi mảnh hạ tầng được bọc
`try/catch` riêng để lỗi một mảnh **không làm app chết** — vì màn hình chính hiện vừa là khung vừa
là công cụ chẩn đoán trạng thái hạ tầng.

Thứ tự khởi tạo là quyết định kiến trúc của repo (xem `context.md` mục 4, quyết định D1/D5/D9 và
`.project/architecture.md`), không phải ngẫu nhiên.

## Requirements

### Requirement: Thứ tự khởi tạo bắt buộc

App **PHẢI (MUST)** khởi tạo hạ tầng theo đúng thứ tự sau trước khi dựng UI, và thứ tự này **KHÔNG ĐƯỢC**
thay đổi:

1. `WidgetsFlutterBinding.ensureInitialized()` — `lib/main.dart:12`
2. `FlutterForegroundTask.initCommunicationPort()` — `lib/main.dart:16`
3. `ListeningService.init()` — `lib/main.dart:17`
4. `await AppAudioSession.configure()` — `lib/main.dart:22`
5. `await AppDatabase.instance()` — `lib/main.dart:27`
6. `runApp(const AiAssistantApp())` — `lib/main.dart:33`

#### Scenario: Khởi động thành công toàn bộ hạ tầng

- **GIVEN** app chưa chạy
- **WHEN** `main()` chạy hết mà không có exception nào
- **THEN** port giao tiếp đã mở trước khi UI dựng (bình luận tại `lib/main.dart:15` nêu rõ ràng buộc này), foreground service đã được cấu hình (chưa chạy), audio session đã cấu hình xong, SQLite đã mở, và UI (`AiAssistantApp`) được dựng

#### Scenario: Port giao tiếp phải mở trước runApp

- **GIVEN** `ListeningTaskHandler` chạy trong isolate riêng của foreground service
- **WHEN** app khởi động
- **THEN** `FlutterForegroundTask.initCommunicationPort()` được gọi **trước** `runApp` (`lib/main.dart:16` so với `lib/main.dart:33`) — theo bình luận tại `lib/main.dart:15`, đây là điều kiện để TaskHandler trao đổi dữ liệu được với UI

### Requirement: Lỗi hạ tầng không được làm app chết

Mỗi lượt gọi hạ tầng trong `main()` (audio session, SQLite) **PHẢI (MUST)** được bọc `try/catch` riêng.
Khi một mảnh lỗi, app **PHẢI (MUST)** vẫn tiếp tục khởi động UI.

#### Scenario: Cấu hình audio session lỗi

- **GIVEN** `AppAudioSession.configure()` ném exception (vd: plugin lỗi)
- **WHEN** `main()` chạy đến bước này
- **THEN** exception được bắt, ghi log qua `AppLogger('main').error(...)` (`lib/main.dart:21-24`) và `main()` vẫn tiếp tục sang bước mở SQLite rồi `runApp`

#### Scenario: Mở SQLite lỗi

- **GIVEN** `AppDatabase.instance()` ném exception (vd: thiết bị lỗi bộ nhớ)
- **WHEN** `main()` chạy đến bước này
- **THEN** exception được bắt, ghi log (`lib/main.dart:26-29`) và app vẫn chạy `runApp` — UI hiện ra với trạng thái DB hiển thị lỗi trên màn hình chẩn đoán

### Requirement: Widget gốc của app

Widget gốc **PHẢI (MUST)** là `MaterialApp` với:
- `title` = `AppInfo.displayName` (hằng `'Trợ lý giao tiếp'`, `lib/core/constants.dart:9`) — `lib/main.dart:43`
- `theme` = `ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal))` — `lib/main.dart:44`
- `home` = `HomeScreen` — `lib/main.dart:45`

#### Scenario: Dựng widget gốc

- **GIVEN** hạ tầng đã khởi tạo xong (bất kể có mảnh nào lỗi hay không)
- **WHEN** `AiAssistantApp.build` chạy
- **THEN** trả về `MaterialApp` đúng cấu hình trên, màn hình đầu tiên là `HomeScreen` (không có routing nào khác)

## Cần làm rõ

1. **Không có cơ chế chờ/khoá khi một mảnh lỗi.** Nếu SQLite lỗi, `runApp` vẫn chạy và `HomeScreen._refreshStatus()` sẽ thử mở lại DB. Hành vi "thử lại" này là chủ ý hay hệ quả chưa ai tính? (Nghi vấn: hai đường mở DB song song — `main()` và `_refreshStatus()` — đều dùng cache `_database` nên không xung đột, nhưng chưa có test nào chứng minh.)
2. **`ListeningService.init()` không được bọc try/catch** (`lib/main.dart:17`) trong khi 2 mảnh còn lại có. Nếu `FlutterForegroundTask.init` ném exception, app chết ngay trước khi UI dựng. Chưa rõ đây là chấp nhận có chủ ý (init chỉ cấu hình thuần, không đụng platform channel) hay là thiếu sót.
3. **Không có xử lý lỗi cho `runApp`** và không có error screen / retry — nếu mọi mảnh lỗi thì người dùng thấy UI với toàn bộ trạng thái "lỗi". Chưa rõ ý định sản phẩm khi hiển thị như vậy.
