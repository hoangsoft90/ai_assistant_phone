# `lib/core/` — hằng số, logging, tiện ích dùng chung

Tầng thấp nhất: **không được import ngược lên** các tầng khác (audio/ui/services). Mọi tầng đều
được phép import tầng này.

| File | Nội dung |
|---|---|
| `constants.dart` | Tập trung mọi hằng "ma thuật": tên app, cấu hình foreground service, tên DB, khóa lưu trữ. Sửa hằng ở đây, không sửa rải rác. |
| `app_logger.dart` | Logger duy nhất của app (qua `dart:developer`, xem được bằng `adb logcat`). Không dùng `print`. |

Ghi chú cho phase sau:
- Quy ước xử lý lỗi (`Result`/exception riêng của app) sẽ được thêm khi có logic thật (P1A trở đi);
  P0.5 cố ý chưa dựng để tránh abstraction không ai dùng.
