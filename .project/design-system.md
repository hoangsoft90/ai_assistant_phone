# design-system.md — Design System & UI Components

Cập nhật: 2026-09-21 (+07).

> **Trạng thái thật:** **CHƯA có design system.** Hiện chỉ dùng Material 3 mặc định + vài giá trị
> hardcode trong một màn hình duy nhất. File này ghi lại **đúng những gì đang có** và **ràng buộc
> thiết kế** mà phase sau phải tuân theo — **không** phải một bộ token đã chốt.

## 1. Hiện đang có gì

**Theme** (`lib/main.dart`):

```dart
theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal))
```

- Material 3 (mặc định của Flutter 3.47), **một màu seed duy nhất là `Colors.teal`**.
- Không có `darkTheme`, không có `textTheme` tuỳ biến, không có `ThemeExtension`, không có token.
- Không tự đặt font — dùng font hệ thống, **không có `assets/` và không có font nào được khai báo**.

**Spacing/giá trị hardcode trong `ui/home_screen.dart`:**

| Giá trị | Dùng ở đâu |
|---|---|
| `EdgeInsets.all(16)` | padding `ListView` và padding trong `Card` |
| `SizedBox(height: 16)` | khoảng cách giữa các khối |
| `EdgeInsets.symmetric(vertical: 4)` | padding từng dòng thông tin |
| `SizedBox(width: 8)` / `SizedBox(width: 96)` | khoảng cách icon–text / bề rộng nhãn |
| `Divider(height: 24)` | phân cách trong card |
| `TextStyle(fontSize: 12, color: Colors.black54)` | dòng chú thích — **hardcode, sẽ phải bỏ** |
| `Colors.green` / `Colors.blueGrey` | màu icon trạng thái — **hardcode, sẽ phải bỏ** |

**Typography hiện có:** chỉ dùng 1 token chuẩn là `Theme.of(context).textTheme.titleMedium` (tiêu đề
trạng thái). Còn lại là `Text` mặc định hoặc style hardcode.

## 2. Shared widgets / component tái sử dụng

**Hiện có: KHÔNG có widget dùng chung nào.** `_statusCard()` và `_infoRow()` là **private trong
`_HomeScreenState`**, không thể tái sử dụng ở màn hình khác. Đây là chấp nhận tạm cho màn hình chẩn
đoán: chưa trích ra `ui/widgets/` vì mới có 1 màn hình (trích bây giờ là over-engineering).

**Quy ước:** khi widget thứ **hai** cần hình dạng tương tự → mới trích sang `lib/ui/widgets/`.
Các component dự kiến sẽ cần (từ `features.md`): badge trạng thái nghe/phát, card gợi ý, nút
Emergency Phrase, thanh điều khiển nhanh trên notification.

## 3. Ràng buộc thiết kế BẮT BUỘC (quan trọng hơn token)

Người dùng dùng app **đang ở giữa cuộc hội thoại**, không nhìn màn hình lâu, có thể đang căng thẳng.
Ràng buộc:

1. **Đọc được trong một lần liếc.** Chữ gợi ý phải to; không được dùng cỡ chữ nhỏ cho nội dung chính.
2. **Trạng thái phải phân biệt được KHÔNG chỉ bằng màu** (màu + icon + chữ). Lý do: đang đi đường,
   ánh sáng thay đổi, và người dùng có thể có vấn đề về phân biệt màu.
3. **Tối thiểu thao tác.** Ưu tiên tự động/bán tự động; nút bấm phải to và ở vị trí ngón tay với tới.
4. **Không dùng animation/transition dài** gây phân tâm giữa hội thoại.
5. **Ít chữ Việt dài dòng** — gợi ý phải là câu ngắn nói được ngay.
6. Màu phải đọc được **ngoài trời** (không dùng chữ xám nhạt trên nền trắng cho nội dung chính).

## 4. Việc phải làm (chưa làm) về design system

| Việc | Phase | Ghi chú |
|---|---|---|
| Tạo `lib/ui/theme/` với token (spacing, text style, semantic color) | **P3** (khi UI thật bắt đầu) | Gộp luôn việc thay các hardcode ở mục 1 |
| Định nghĩa **semantic color** thay `Colors.green`/`Colors.blueGrey` | P3 | Phải map vào `ColorScheme`, không hardcode |
| Trích shared widget sang `lib/ui/widgets/` | khi có widget thứ 2 | Xem mục 2 |
| Kiểm tra dark mode | chưa có kế hoạch | Dùng chủ yếu ngoài sáng; chưa ưu tiên |
| Kiểm thử UI trên máy thật (kích thước chữ, độ tương phản) | P1A trở đi | **Chưa từng chạy app trên máy thật** |

## 5. Cảnh báo cho agent

- **Đừng tạo design system "cho đẹp" ở phase này.** Ở P1A–P2 có rất ít UI; thêm token/theme chưa dùng
  tới là làm phình code mà không có lợi ích (xem `AGENTS.md` — chống over-engineering).
- **Đừng copy style hardcode ở `home_screen.dart` sang file mới.** Nếu cần style mới, hỏi trước để
  làm luôn bước tạo token ở mục 4 (P3).
- Khi nào chuẩn bị làm UI thật (P3), **phải hỏi người dùng** về màu chủ đạo/brand mong muốn — hiện
  `Colors.teal` chỉ là mặc định tạm lúc bootstrap, chưa ai chọn.
