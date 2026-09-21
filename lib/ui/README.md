# `lib/ui/` — màn hình và widget

| File | Nội dung |
|---|---|
| `home_screen.dart` | Màn hình chính tối thiểu của P0.5: trạng thái "Sẵn sàng" / "Đang lắng nghe", nút bật/tắt service, và trạng thái các mảnh hạ tầng (quyền, SQLite, API key) để test tay trên máy thật. |

Màn hình sẽ được thêm sau:
- **Pre-Brief** (P5): nhập ngữ cảnh buổi trước khi bắt đầu; bắt buộc theo mục 4.1.
- **Floating button Push** (P3/P4): nút xin gợi ý — hành động chính của app.
- **Settings** (P2/P7): nhập API key, mức Training Level, loại bỏ battery optimization.

Nguyên tắc: UI **không** gọi trực tiếp plugin native; mọi thứ đi qua `lib/services/` và
`lib/audio/` để giữ ranh giới tầng rõ ràng (xem thêm ghi chú ở `lib/services/README.md`).
