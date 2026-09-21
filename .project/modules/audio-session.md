# Module: audio-session

Trạng thái: 🟡 **mức khung** — chưa thu, chưa phát gì; cấu hình **chưa được xác nhận bằng số liệu
thật** (P0.5).

> ⚠ Đây là module **nằm trong vùng an toàn** của dự án (ràng buộc cứng #1 và #3 ở `overview.md`).
> Sửa file này khi chưa có số liệu đo thật là rủi ro cao — xem mục 6.

## 1. Mục đích

Đặt thuộc tính audio phía hệ thống cho phần **PHÁT** (playback), sao cho:
- Không kéo hệ thống sang chế độ đàm thoại (HFP/SCO) — để tai nghe Bluetooth giữ **A2DP**.
- Có chỗ để bắt sự kiện **thiết bị ra thay đổi** (`becomingNoisy`) — nền tảng cho P1F.

## 2. File & API (`lib/audio/app_audio_session.dart` → `AppAudioSession`)

| Thành phần | Chi tiết |
|---|---|
| `configure()` | `AudioSession.instance` → `session.configure(AudioSessionConfiguration(...))` → trả `AudioSession` |

Cấu hình đã đặt (mỗi giá trị là **quyết định**, không phải mặc định):

| Thuộc tính | Giá trị | Lý do |
|---|---|---|
| `androidAudioAttributes.contentType` | `speech` | Nội dung là lời nói (giọng đọc gợi ý) |
| `androidAudioAttributes.usage` | **`media`** | **Cố ý KHÔNG dùng `voiceCommunication`** — usage đó kéo hệ thống sang HFP/SCO, hạ chất lượng audio |
| `androidAudioAttributes.flags` | `none` | Không cần cờ đặc biệt |
| `androidAudioFocusGainType` | `gain` | Lấy focus bình thường khi phát |
| `androidWillPauseWhenDucked` | `true` | Bị ducked thì tạm dừng (không phát chồng lên thứ khác) |

Ngoài ra đăng ký `session.becomingNoisyEventStream.listen(...)` — hiện **chỉ ghi log warn**.

## 3. API endpoints

Không có.

## 4. Local storage

Không dùng.

## 5. Việc còn thiếu

- [ ] ⚠ **Xác nhận bằng số liệu thật** rằng TTS qua tai nghe **giữ A2DP, không bị ép HFP**
      (`adb shell dumpsys audio` trong lúc phát) — nợ từ P0 Task 2 (**chưa chạy**).
- [ ] **P1A**: chọn nguồn thu = **mic điện thoại** (đi qua `AudioRecord`, **không** qua file này).
- [ ] **P1F**: dùng `becomingNoisy` (hoặc API tương đương) để **dừng phát** khi tai nghe bị rút —
      hiện mới log.
- [ ] Kiểm tra tương tác khi có cuộc gọi đến / app khác lấy audio focus.

## 6. Cảnh báo khi sửa — ⚠ vùng an toàn, phải hỏi trước

1. **TUYỆT ĐỐI không đổi `usage` sang `voiceCommunication` / `voiceCommunicationSignalling`.**
   Đây là ràng buộc cứng #1 của dự án; đổi là phá thiết kế (tai nghe bị chuyển sang chế độ đàm thoại
   hai chiều và hạ chất lượng).
2. **`audio_session` chỉ cấu hình phần PHÁT.** Việc chọn nguồn thu thuộc P1A (`AudioRecord`), **không**
   đi qua file này. Đừng "tiện tay" thêm cấu hình thu vào đây.
3. **Cấu hình hiện tại là mức khung dựa trên giả định** — số liệu A2DP/HFP **chưa có** (xem
   `.plan/P0-result.md`). Khi có số liệu, phần này **có thể phải sửa**; nếu sửa ảnh hưởng tới cách P1F
   phát TTS thì phải báo người dùng trước khi làm.
4. File này thuộc **vùng loại trừ Ponytail** (an toàn/không thể hoàn tác đối với trải nghiệm người
   dùng) ⇒ theo `AGENTS.md`, **không tự commit** thay đổi ở đây khi chưa có xác nhận của người dùng.
5. Trong code spike P0 có `TtsTest` phát **trực tiếp** để đo hành vi thô — **không được tái sử dụng**.
   Từ P1F, mọi phát âm thanh phải đi qua `SafeTtsOutput`.
