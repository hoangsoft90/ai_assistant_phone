# tts-safety Specification

> Baseline spec — mô tả hành vi ĐÃ implement (P1F + các sửa K45/A54 từ P4). **Đây là spec an toàn
> quan trọng nhất của app** — mọi thay đổi chạm file này phải qua xác nhận người dùng (rule 12).
> Nguồn sự thật: `lib/audio/tts/safe_tts_output.dart`, `tts_client.dart`, `tts_channels.dart`,
> `android/.../tts/SafeTtsBridge.kt`, `test/safe_tts_output_test.dart`,
> `.project/modules/tts-safety.md`.

## Purpose

Đọc gợi ý **CHỈ vào tai nghe** (Bluetooth A2DP một chiều), tuyệt đối KHÔNG lọt ra loa ngoài trong
bất kỳ tình huống nào (ràng buộc #3). Native dùng `TextToSpeech.synthesizeToFile` rồi tự phát PCM qua
`AudioTrack.setPreferredDevice(<tai nghe>)` với `USAGE_MEDIA` — CỐ Ý KHÔNG dùng
`USAGE_VOICE_COMMUNICATION` (kéo HFP/SCO hạ chất lượng — ràng buộc #1). Kênh TTS đăng ký cho engine UI
(K36b còn nợ: phát khi app ở nền).

## Requirements

### Requirement: Không tai nghe ⇒ KHÔNG phát (fail-closed)

Trước MỌI lần đọc, Dart **PHẢI (MUST)** đọc tươi trạng thái tai nghe: không có tai nghe ⇒ KHÔNG gọi
phát, chỉ rung + nudge chữ (`TtsSpeakResult.silentFallback`, `TtsFallbackKind.noHeadset`). Vùng cấm
cũng áp dụng cho Emergency Phrase (P1G) — không tai nghe thì câu thoát hiểm cũng không phát.

#### Scenario: Đọc thử khi không có tai nghe

- **GIVEN** không có thiết bị output riêng tư nào kết nối
- **WHEN** `speak()` được gọi
- **THEN** KHÔNG có AudioTrack nào được tạo, KHÔNG một tiếng nào ra loa ngoài; app rung báo 1 nhịp + phát `TtsFallbackNotice` cho UI (bằng chứng buổi test adb 2026-09-23: `đã rung: SILENT_FALLBACK`, 0 AudioTrack)

### Requirement: Hai lớp phát hiện mất tai nghe

App **PHẢI (MUST)** dừng phát NGAY khi mất tai nghe bằng 2 lớp: `ACTION_AUDIO_BECOMING_NOISY` (sớm
nhất — hệ thống bắn TRƯỚC khi đổi route) + `AudioDeviceCallback` (bảo hiểm phủ cả Bluetooth). Khi
mất giữa chừng: dừng phát, rung 2 nhịp, đặt `needsConfirmation = true` và KHÔNG phát gì thêm cho tới
khi người dùng gọi `confirmHeadsetReady()`.

#### Scenario: Rút tai nghe giữa lúc đọc

- **GIVEN** TTS đang phát qua tai nghe
- **WHEN** tai nghe bị ngắt kết nối giữa chừng
- **THEN** tiếng tắt ngay lập tức, phần còn lại KHÔNG phát tiếp ra loa ngoài, rung 2 nhịp; sau khi cắm lại app KHÔNG tự đọc lại — cần xác nhận rồi đọc lại bằng tay (TC3; rút-trước-khi-đọc là TC2, rút-giữa là TC3 của giáo trình P1F)

### Requirement: Xác nhận sau reconnect

Sau khi mất tai nghe (kể cả callback baseline của `registerAudioDeviceCallback` — hiện đang bị phân
loại thành "kết nối lại", nợ K37), app **PHẢI (MUST)** chặn mọi phát cho tới `confirmHeadsetReady()`.
⚠️ K37 là fail-closed ĐANG GÁNH AN TOÀN thay cho K36 (chưa phân biệt tai nghe ↔ loa BT cùng
`TYPE_BLUETOOTH_A2DP`) — KHÔNG được bỏ cổng này cho tới khi K36 xong + verify máy thật.

#### Scenario: Mở app có tai nghe cắm sẵn

- **GIVEN** tai nghe đã kết nối trước khi mở app
- **WHEN** app khởi động và người dùng bấm đọc
- **THEN** app từ chối phát + báo cần xác nhận; sau khi bấm "Xác nhận tai nghe đã sẵn sàng (P1F)" thì đọc được bình thường

### Requirement: Thế hệ phát và file WAV tạm

Mỗi lần phát có **thế hệ** (token tăng dần). File WAV tạm **PHẢI (MUST)** được quản theo thế hệ:
`wavFor(gen)` là nguồn duy nhất của đường dẫn, `cleanTemp(file)` chỉ null field khi đúng file đó,
`onError`/`onStop` **PHẢI (MUST)** qua `isCurrentGeneration()` trước khi chạm trạng thái — call-site
của thế hệ CŨ không được xoá file/state của câu MỚI (sửa K45 — lỗi làm Emergency im lặng khi đang
đọc nudge; cùng họ A54). File tạm nằm trong `cacheDir`, xoá sau phát.

#### Scenario: Emergency khi đang đọc nudge

- **GIVEN** một nudge đang được đọc (thế hệ N)
- **WHEN** Emergency Phrase kích hoạt (thế hệ N+1)
- **THEN** thế hệ cũ thoát mà KHÔNG xoá file WAV của thế hệ mới ⇒ câu thoát hiểm vẫn kêu (chờ xác nhận tai trên máy — nợ K45/K34)

### Requirement: Báo hiệu speaking cho half-duplex

`SafeTtsOutput` **PHẢI (MUST)** phát stream `speakingChanges` (bật khi native NHẬN yêu cầu tổng hợp
— cửa sổ rộng hơn thời gian có tiếng, hướng an toàn có chủ ý) để tầng phiên P4 chặn ASR đúng lúc;
đồng thời mọi trạng thái nội bộ KHÔNG ĐƯỢC log nội dung text (quyết định review P2).

#### Scenario: Phiên biết TTS đang phát

- **GIVEN** phiên hội thoại (P4) đang lắng nghe `speakingChanges`
- **WHEN** một lần `speak()` bắt đầu rồi kết thúc
- **THEN** stream phát `true` rồi `false` đúng thứ tự — số `chặn N chunk khi đang phát` / `ASR nhận lại N lần` trên dòng `Phiên (P4)` tăng tương ứng
