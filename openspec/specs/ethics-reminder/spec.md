# ethics-reminder Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P7 mục 4 + fix R1 từ review).
> Nguồn sự thật: `lib/coaching/ethics_gate.dart`, `lib/core/constants.dart` (EthicsConfig),
> `lib/ui/home_screen.dart` (`_maybeShowEthicsReminder`), `test/ethics_gate_test.dart`,
> `test/app_smoke_test.dart`.

## Purpose

Lời nhắc ranh giới đạo đức hiện **một lần duy nhất** khi mở app lần đầu: nhắc người dùng app chỉ hỗ
trợ giao tiếp của CHÍNH HỌ, không dùng cho nội dung riêng tư của người khác, và câu gợi ý do máy sinh
chỉ để tham khảo. Đây là lời nhắc cho chính người dùng — KHÔNG phải tính năng pháp lý: không chặn,
không ghi nhận vi phạm, không đụng audio/ASR/LLM.

## Requirements

### Requirement: Hiện một lần, ghi flag sau khi xác nhận

App **PHẢI (MUST)** hiện dialog (`EthicsConfig.dialogTitle` = "Trước khi dùng", `dialogBody`,
nút `dialogConfirm` = "Tôi hiểu") khi mở app lần đầu; flag `meta` `ethics_reminder_shown` chỉ được
ghi `'1'` **SAU KHI** dialog đóng với xác nhận `true`. Dialog đóng mà KHÔNG xác nhận (nút back hệ
thống — `barrierDismissible:false` KHÔNG chặn được back) ⇒ KHÔNG ghi flag ⇒ lần mở sau hiện lại
(hướng an toàn: chưa xác nhận thì còn nhắc). App bị kill giữa chừng cũng vậy.

#### Scenario: Xác nhận lần đầu

- **GIVEN** máy chưa có flag `ethics_reminder_shown`
- **WHEN** người dùng mở app và bấm "Tôi hiểu"
- **THEN** flag được ghi `'1'`; các lần mở app sau KHÔNG hiện dialog lại (bằng chứng buổi test adb 2026-09-23: mở lại sau force-stop không thấy dialog)

#### Scenario: Bấm back thay vì xác nhận

- **GIVEN** dialog đang hiển thị lần đầu
- **WHEN** người dùng bấm nút back hệ thống
- **THEN** flag KHÔNG được ghi; lần mở app kế tiếp dialog hiện lại (fix R1 — test khoá và đã chứng minh test biết đỏ)

### Requirement: Gate không bao giờ ném, lỗi nghiêng về nhắc lại

`EthicsGate` **PHẢI (MUST)**: đọc lỗi ⇒ coi là "chưa hiện" (dialog có thể hiện lại — an toàn);
ghi lỗi ⇒ vẫn đặt `_shown = true` trong RAM (không hiện lại liên tục trong phiên vì một lần ghi
SQLite lỗi); KHÔNG cấm dùng app trong mọi trường hợp. KHÔNG đụng storage trực tiếp từ UI — UI chỉ
gọi gate (`EthicsGate.load`/`markShown`).

#### Scenario: SQLite lỗi thoáng qua

- **GIVEN** DB không ghi được tại thời điểm mở app
- **WHEN** `load()` chạy
- **THEN** trả `false` (coi như chưa hiện) + log cảnh báo; dialog vẫn hiện bình thường, app dùng được

### Requirement: Nội dung không thể sửa tùy tiện

Nội dung dialog **PHẢI (MUST)** nằm trong `EthicsConfig` (hằng số, một nơi duy nhất) — KHÔNG nhúng
chuỗi trong widget để mọi thay đổi nội dung đều qua review có chủ đích (nội dung là tuyên bố trách
nhiệm của app với người dùng).

#### Scenario: Đổi nội dung lời nhắc

- **GIVEN** nội dung lời nhắc cần điều chỉnh
- **WHEN** lập trình viên tìm nơi khai báo
- **THEN** chỉ có `EthicsConfig` là nguồn duy nhất (title/body/confirm) — sửa ở đó là áp dụng cho toàn app, không còn bản sao rải rác trong widget
