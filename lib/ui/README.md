# `lib/ui/` — màn hình và widget

| File | Nội dung |
|---|---|
| `home_screen.dart` | Màn hình chính tối thiểu của P0.5: trạng thái "Sẵn sàng" / "Đang lắng nghe", nút bật/tắt service, và trạng thái các mảnh hạ tầng (quyền, SQLite, API key) để test tay trên máy thật. Từ P3/P5 có thêm khu điều khiển nhanh (chế độ output, tốc độ đọc, API key, Pre-Brief, cấp độ huấn luyện, kết thúc buổi + nhận xét, số liệu 7 ngày). |
| `floating_button.dart` | **(P3)** Nút nổi: tap = Push, giữ đúng 2 giây = Emergency Phrase. |
| `pre_brief_screen.dart` | **(P5)** Nhập ngữ cảnh buổi trước khi bắt đầu (mục 4.1). |
| `post_review_screen.dart` | **(P5)** Báo cáo 3 mục sau buổi; transcript chi tiết **ẩn** sau "Xem chi tiết". |
| `stats_screen.dart` | **(P5)** Số liệu 7 ngày (số buổi, Push, Push/buổi, xu hướng) — **chỉ hiển thị**. |

Màn hình sẽ được thêm sau:
- **Settings** (P7): gom nhập API key, Pre-Brief, cấp độ huấn luyện, chế độ output, tốc độ đọc, loại bỏ battery optimization vào một chỗ (hiện nằm rải ở màn hình chính để test tay được).

Nguyên tắc: UI **không** gọi trực tiếp plugin native; mọi thứ đi qua `lib/services/` và
`lib/audio/` để giữ ranh giới tầng rõ ràng (xem thêm ghi chú ở `lib/services/README.md`).
