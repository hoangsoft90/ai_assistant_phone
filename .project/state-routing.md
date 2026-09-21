# state-routing.md — Quản lý trạng thái & Routing

Cập nhật: 2026-09-21 (+07).

> **Tóm tắt một dòng:** hiện **chưa có** state management library và **chưa có** router.
> Đây là **quyết định có chủ ý** ở phase bootstrap, không phải thiếu sót — và có mốc để chốt.

## 1. State management

### Hiện tại: không dùng thư viện

- `main.dart` chỉ bootstrap rồi `runApp`.
- `ui/home_screen.dart` là `StatefulWidget` + `setState` cho **5 giá trị cục bộ**:
  `_serviceRunning`, `_busy`, `_databaseStatus`, `_hasApiKey`, `_permissions`.
- Mọi thứ khác là `static` trên các lớp bọc (`ListeningService`, `PermissionGate`,
  `AppDatabase`, `SecureStore`) — tức trạng thái **không** được quản lý tập trung.

Điều này chấp nhận được vì màn hình này chỉ để **chẩn đoán** trạng thái hạ tầng, không có nghiệp vụ.

### Khi nào BẮT BUỘC chốt state management

Mốc rõ ràng: **trước khi bắt đầu P1B (VAD + State tối giản)**. Lý do: P1B sinh ra **state machine**
thật (Sẵn sàng / Đang nghe / Đang phát / Tạm dừng) được chia sẻ giữa **isolate của foreground
service** và **UI** — `setState` không giải quyết được việc này.

### Ràng buộc đã biết cho lựa chọn đó

1. **Trạng thái phải sống ngoài widget tree** — service chạy ở isolate riêng, UI có thể bị đóng.
2. **Phải giao tiếp được với `flutter_foreground_task`** (nó cung cấp port `initCommunicationPort`),
   nên state không được buộc chặt vào một widget.
3. **Không được thêm dependency chỉ vì tiện** — repo đang cố ý giữ danh sách dependency tối thiểu
   (xem `Constraints` trong `prompt_P0_5.md`).

### Chưa chốt giữa các phương án

Chưa quyết giữa (a) `ChangeNotifier`/`ValueNotifier` thuần của Flutter + `ListenableBuilder`,
(b) Riverpod, (c) BLoC. **Không được tự chọn khi chưa tới P1B** — khi tới đó phải nêu lựa chọn kèm
lý do và ghi lại vào đây (và nếu là quyết định kiến trúc thì ghi ADR theo `AGENTS.md`).

Lưu ý: agent **không được** tự suy luận từ tài liệu kế hoạch rằng "chắc là dùng Riverpod" — trong
`.plan/plan_final_v2.md` không chốt thư viện nào cụ thể.

## 2. Routing

### Hiện tại: không có router

- `MaterialApp(home: HomeScreen())` — **một màn hình duy nhất**, không có `routes`, không có `onGenerateRoute`.
- Không có `go_router`, `auto_route`, hay bất kỳ package routing nào.
- **Không có deep link**: không có `intent-filter` cho `VIEW`/`BROWSABLE` trong `AndroidManifest.xml`
  (chỉ có `MAIN`/`LAUNCHER`). Nếu sau này cần mở app từ notification hay URL thì phải thêm cả
  intent-filter **lẫn** cấu hình routing.

### Khi nào chốt routing

Mốc: **P5 (Pre-Brief / Post-Review / Coaching / Training Level)** — đây là lúc xuất hiện nhiều màn
hình độc lập. Trước đó (P1A–P4) nên giữ 1 màn hình + các panel/bottom sheet trong cùng screen.

Khi chốt, phải cân nhắc: nhiều màn hình trong P5 có thể nên là **modal/bottom sheet** thay vì route
riêng (người dùng đang giữa cuộc hội thoại, ít thao tác được) — xem [design-system.md](design-system.md).

## 3. Điều gì thay thế navigation trong giai đoạn hiện tại

- **Notification của foreground service**: hiện `notificationText = 'Chạm để quay lại app'`; hành vi
  "quay lại app" do plugin xử lý, chưa có route riêng.
- **`WithForegroundTask`** (bọc ngoài `Scaffold`): giữ app sống khi người dùng bấm back cứng lúc
  service đang chạy. Đây là cơ chế vòng đời, không phải routing.

## 4. Bảng trạng thái

| Hạng mục | Hiện tại | Chốt ở phase |
|---|---|---|
| State management | `setState`, không thư viện | **P1B** (bắt buộc) |
| State machine (Sẵn sàng/Nghe/Phát) | chưa có | P1B |
| Router | không có | P5 |
| Deep link | không có | chưa có kế hoạch |
| Đa màn hình | 1 | P5 |
| DI (dependency injection) | không có, dùng `static` | xem [patterns.md](patterns.md) mục 4 |
