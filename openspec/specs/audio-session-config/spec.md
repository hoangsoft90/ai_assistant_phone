# audio-session-config Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P0.5). Không phải đề xuất.
> Nguồn sự thật: `lib/audio/app_audio_session.dart`, `lib/main.dart`.

## Purpose

Cấu hình audio session phía hệ thống cho phần **PHÁT** (playback attributes) sao cho không kéo hệ
thống sang chế độ đàm thoại (HFP/SCO) — giữ tai nghe Bluetooth ở **A2DP** — và đăng ký lắng nghe sự
kiện `becomingNoisy` (thiết bị ra thay đổi) làm nền cho P1F.

Ranh giới quan trọng: `audio_session` chỉ đặt thuộc tính **phát**. Việc chọn nguồn thu (mic điện
thoại, AudioRecord) thuộc P1A và **không đi qua** module này. Cấu hình hiện tại là **mức khung dựa
trên giả định** — số liệu đo A2DP/HFP thật chưa có (nợ P0 Task 2, xem `.project/openspec.md` K2).

Quyết định `usage=media` là ràng buộc cứng #1 của dự án (xem `context.md` mục 4, quyết định D2 và
`.project/overview.md` mục 4).

## Requirements

### Requirement: Thuộc tính playback cố định

`AppAudioSession.configure()` (`lib/audio/app_audio_session.dart:20-40`) **PHẢI (MUST)** cấu hình session
với đúng các giá trị sau — **KHÔNG ĐƯỢC** đổi `usage` sang `voiceCommunication` hay
`voiceCommunicationSignalling`:

| Thuộc tính | Giá trị | Dòng |
|---|---|---|
| `androidAudioAttributes.contentType` | `AndroidAudioContentType.speech` | :26 |
| `androidAudioAttributes.usage` | `AndroidAudioUsage.media` | :27 |
| `androidAudioAttributes.flags` | `AndroidAudioFlags.none` | :28 |
| `androidAudioFocusGainType` | `AndroidAudioFocusGainType.gain` | :30 |
| `androidWillPauseWhenDucked` | `true` | :31 |

Hàm **PHẢI (MUST)** trả về instance `AudioSession` sau khi cấu hình (:37).

#### Scenario: Cấu hình session lần đầu

- **GIVEN** app vừa khởi động, chưa có session nào được cấu hình
- **WHEN** `AppAudioSession.configure()` chạy
- **THEN** `AudioSession.instance` được lấy, `session.configure(...)` được gọi với đúng 5 giá trị trong bảng trên, và hàm trả về session để tầng sau dùng tiếp

#### Scenario: Giá trị usage bị kiểm soát

- **GIVEN** code module này
- **WHEN** đọc cấu hình được gửi cho `session.configure`
- **THEN** `usage` là `AndroidAudioUsage.media` — bình luận tại `app_audio_session.dart:27` (và log ở `:34-36`) nêu rõ đây là lựa chọn **cố ý** để không kéo hệ thống sang HFP/SCO; đổi giá trị này là vi phạm ràng buộc kiến trúc của repo

### Requirement: Ghi log xác nhận cấu hình

Sau khi cấu hình xong, module **PHẢI (MUST)** ghi log `info` nêu rõ `content=speech, usage=media` và lý do
"cố ý KHÔNG dùng voiceCommunication" (`app_audio_session.dart:34-36`).

#### Scenario: Kiểm log sau cấu hình

- **GIVEN** `configure()` chạy thành công
- **WHEN** xem log (ví dụ `adb logcat` trên thiết bị)
- **THEN** thấy dòng `đã cấu hình audio session: content=speech, usage=media (cố ý KHÔNG dùng voiceCommunication để không kéo sang HFP)` với tag `AppAudioSession/info`

### Requirement: Đăng ký lắng nghe becomingNoisy — hiện chỉ ghi log

Module **PHẢI (MUST)** đăng ký `session.becomingNoisyEventStream.listen(...)` và trong handler **CHỈ** ghi
log `warn` ("becomingNoisy: thiết bị ra thay đổi (tai nghe rút hoặc mất kết nối?)")
(`app_audio_session.dart:42-44`). **Không có hành vi dừng phát nào** — vì app chưa phát gì; việc
**dừng phát khi tai nghe rút** là yêu cầu của P1F (`SafeTtsOutput`), chưa implement.

#### Scenario: Tai nghe bị rút khỏi máy

- **GIVEN** app đang chạy và `configure()` đã đăng ký listener
- **WHEN** hệ thống phát sự kiện `becomingNoisy` (tai nghe có dây bị rút)
- **THEN** app ghi log warn như trên và **không** có hành vi nào khác (không dừng/thay đổi gì — vì hiện chưa phát âm thanh)

#### Scenario: Ranh giới trách nhiệm với P1F

- **GIVEN** tình huống "rút tai nghe giữa lúc TTS phát" — ràng buộc cứng #3 của dự án
- **WHEN** sự kiện `becomingNoisy` xảy ra **sau** khi P1F tồn tại
- **THEN** hành vi bắt buộc (dừng phát, không lọt ra loa ngoài) **phải** được implement trong
  `SafeTtsOutput` (P1F) — code hiện tại chỉ có log; spec này mô tả đúng trạng thái "chỉ log" của P0.5

## Cần làm rõ

1. **Cấu hình chưa được xác minh bằng số liệu thật.** Toàn bộ choice `usage=media` dựa trên giả định
   "không kéo sang HFP" — chưa có phép đo `dumpsys audio` nào trên thiết bị thật (Task 2 của P0 chưa
   chạy). Nếu số liệu sau này chứng minh hệ thống vẫn ép HFP, phần này phải sửa lại thiết kế của P1F.
2. **`becomingNoisyEventStream` theo tài liệu Android chỉ phủ tai nghe CÓ DÂY** (ACTION_AUDIO_BECOMING_NOISY).
   Bluetooth tai nghe mất kết nối **không** chắc chắn phát sự kiện này — bình luận trong code ghi
   "tai nghe rút hoặc mất kết nối?" (dấu hỏi), và P1F sẽ cần API bổ sung (vd: theo dõi trạng thái
   thiết bị Bluetooth qua `BLUETOOTH_CONNECT`). Chưa rõ thiết kế P1F đã tính điều này chưa.
3. **Subscription không được lưu và không được hủy** (`:42` gọi `listen` trực tiếp, không gán biến)
   — lint `cancel_subscriptions` đang bật nhưng rule này không bắt được pattern trả về void như vậy.
   Với session sống suốt vòng đời app thì chấp nhận được, nhưng nếu `configure()` được gọi lần thứ
   hai (hiện không ai gọi) sẽ tạo listener trùng lặp. Chưa rõ có cần cơ chế chống đăng ký kép không.
4. **`AudioFocusGainType.gain`**: chưa có kịch bản mất/giữ audio focus nào được định nghĩa (cuộc gọi
   đến, app nhạc khác mở). Chưa rõ ý định xử lý focus khi có tiếng cuộc gọi — sẽ ảnh hưởng tới P1F/P4.
