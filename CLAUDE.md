# CLAUDE.md

Xem **[AGENTS.md](AGENTS.md)** — đó là nguồn duy nhất cho hạ tầng (retrieval/memory, git & kiểm thử,
code review) **và** phần `PROJECT` (role, critical rules, workflow) của repo này. File này chỉ là
điểm vào ngắn gọn, không lặp lại nội dung.

## 30 giây để hiểu repo này

- **`ai_assistant_phone`** — app Android cá nhân (một người dùng): nghe hội thoại bằng **mic điện
  thoại**, bóc băng **offline**, gợi ý câu trả lời, **đọc qua tai nghe Bluetooth (chỉ A2DP)**.
- **Stack:** Flutter 3.47.2, Dart `^3.13.2`, Android only, `com.aiassistant.phone`, minSdk 26,
  target/compileSdk 36, Kotlin 2.4.0 / AGP 9.1.0 / Gradle 9.3.1.
- **Hiện trạng:** mới có **khung P0.5** (foreground service + audio session + SQLite + màn hình chẩn
  đoán). **Chưa có tính năng sản phẩm nào. App chưa từng chạy trên máy thật.**
  Không có auth / backend / payment — và sẽ không có.

## Đọc gì trước khi làm

| Cần gì | Đọc |
|---|---|
| Kiến thức chung về dự án | [`.project/README.md`](.project/README.md) (entry point) |
| Các ràng buộc **không được vi phạm** | [`.project/overview.md`](.project/overview.md) mục 4 |
| Đang ở phase nào, việc kế tiếp, nợ kỹ thuật | [`.project/openspec.md`](.project/openspec.md) |
| Quy ước đặt file theo tầng | [`.project/architecture.md`](.project/architecture.md) |
| Chi tiết mảng code sắp sửa | `.project/modules/<module>.md` |
| Cách build/chạy | [`README.md`](README.md) |

## Ba điều dễ sai nhất ở repo này

1. **Đừng thêm logic audio ở phase này.** `onRepeatEvent` của foreground service phải rỗng cho tới P1A.
2. **Đừng đổi `usage` của audio session sang `voiceCommunication`** — nó kéo tai nghe sang HFP và phá
   ràng buộc cứng #1 của dự án.
3. **Đừng tái sử dụng `TtsTest`** trong `spikes/p0_audio/` — nó phát âm thanh trực tiếp (cố ý, để đo
   hành vi thô của Android). Từ P1F mọi phát âm thanh phải qua `SafeTtsOutput`.
