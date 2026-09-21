# operating_rules.md — Rule riêng của project

Cập nhật: 2026-09-21 (+07). Chỉ chứa rule **riêng của repo này**, không lặp lại nội dung đã có trong
`AGENTS.md` (hạ tầng chung + phần PROJECT) hay `.project/`.

## A. Rule về tài liệu & báo cáo (đặc thù repo này)

1. **Báo cáo phase luôn theo đúng 5 heading của `.plan/AGENT_INSTRUCTIONS.md` mục 5** và ghi vào
   `.plan/<PHASE>-result.md` (ví dụ `.plan/P0_5-result.md`). Không trả báo cáo dạng tóm tắt tự do
   rồi coi như đã theo khuôn mẫu. Tên phase viết đúng như thư mục: `P0`, `P0_5`, `P1A`, ...
2. **Người dùng không đọc code** ⇒ mọi kết luận phải kèm **bằng chứng chạy được** (lệnh + output),
   không dùng từ "chắc là", "ước lượng", "về cơ bản đã xong".
3. **Không được tick một mục DoD khi chưa có bằng chứng.** Nếu mục đó cần thiết bị/môi trường không
   có ⇒ ghi `[ ]` + lý do + cái còn thiếu để đạt.
4. **Luôn ghi rõ sai khác so với file prompt gốc** (version package đổi, dependency phải thêm, quyết
   định khác đi) — kèm lý do. Đây là mục bắt buộc trong báo cáo phase.
5. **Nếu người dùng waive một precondition**: vẫn phải ghi rõ việc waive + rủi ro còn lại vào báo
   cáo, và giữ nó như **nợ kỹ thuật** cho tới khi thực sự được kiểm chứng.
6. `.plan/` **bị gitignore** ⇒ đừng để kiến thức chỉ tồn tại ở đó. Điều gì cần cho phiên sau thì
   phải có bản trong `.project/` / `context.md` / `working.md` / `checklist.md`.

## B. Rule về code (đặc thù app audio này)

7. **Không dùng `print`** — chỉ `AppLogger` (`avoid_print` đã bật trong lint).
8. **UI không được gọi thẳng package bên thứ ba.** Phải bọc qua lớp trong `lib/services/` hoặc
   `lib/audio/`. Hai ngoại lệ đang tồn tại trong `home_screen.dart` (`WithForegroundTask`,
   `db.getVersion()`) là **chấp nhận tạm cho màn hình chẩn đoán**, không được nhân rộng.
9. **Mọi "giá trị ma thuật"** (id, tên channel, tên DB, khóa lưu trữ) phải nằm trong
   `lib/core/constants.dart`, không rải trong code.
10. **`try/catch → log → trả false` chỉ dùng cho màn hình chẩn đoán / bootstrap.** **Cấm** áp pattern
    này cho code ở vùng an toàn (đặc biệt P1F `SafeTtsOutput`): ở đó lỗi phải dẫn tới **không phát gì**,
    không được rơi vào một nhánh có thể phát ra loa ngoài.
11. **Không thêm logic audio vào `onRepeatEvent`** khi chưa tới P1A (kể cả khi thấy "tiện tay").
12. **Khi thêm plugin mới** ⇒ thêm tên MethodChannel của nó vào danh sách stub trong
    `test/app_smoke_test.dart`, nếu không `flutter test` sẽ đỏ vì thiếu native.
13. **Tài liệu `.project/modules/<module>.md` phải được cập nhật cùng lúc với code của module đó**
    (hoặc tạo mới khi feature đầu tiên xuất hiện) — không để tài liệu lệch code.

## C. Rule về an toàn & quyền riêng tư (quan trọng nhất)

14. **Audio hội thoại tuyệt đối không được gửi ra ngoài máy.** Chỉ `text` đã bóc băng mới được gửi
    tới LLM. Nếu một tính năng "cần" gửi audio thô ⇒ **dừng lại hỏi người dùng**, đây là ràng buộc cứng.
15. **Không để TTS lọt ra loa ngoài.** Bất kỳ thay đổi nào trong đường phát âm thanh phải được coi là
    vùng loại trừ Ponytail ⇒ **không tự commit**, phải trình bày và chờ xác nhận.
16. **Transcript là dữ liệu nhạy cảm** (nội dung hội thoại thật của người dùng). Không tự thêm
    export/upload/share. Không xoá DB. Không log nội dung transcript ở mức `info`.
17. **Không lưu secret vào SQLite/file cấu hình/log** — chỉ `SecureStore`.

## D. Rule về môi trường (máy dev này)

18. **Không build APK tại máy này** (thiếu Android SDK/NDK) — kế hoạch build qua GitHub Actions.
    Đừng thử `flutter build apk` rồi báo lỗi như thể code sai.
19. **Việc nặng (tải/convert model, build cache) chạy ở `/tmp`**, không ở `/home` (~396MB trống).
    Artifact cuối mới copy vào repo, và phải nằm trong `.gitignore` nếu là file lớn.
20. **Không tự cài/cấu hình lại công cụ dùng chung** (OCR, Android SDK, AgentMemory, cocoindex-code
    daemon): chỉ báo cáo là không khả dụng và tiếp tục theo phần "Graceful Degradation" của `AGENTS.md`.

## E. Rule về git

21. **Chưa chốt convention và repo đang 0 commit** ⇒ **không tự commit**. Trước lần commit đầu tiên
    phải hỏi người dùng: tách nhánh theo phase hay không, chia mấy commit, prefix thế nào.
22. `spikes/p0_audio/models/` (**~133MB**) và `.plan/` **không được commit** — đã có trong `.gitignore`,
    đừng "sửa .gitignore cho tiện".
