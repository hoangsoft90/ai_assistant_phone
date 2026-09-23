# Module: Pipeline integration (P4) — orchestrator phiên + half-duplex

## 1. Mục đích

Biến 9 module rời rạc của P1A→P3 thành **một pipeline chạy trong một cuộc trò chuyện thật**, và thi
hành đúng một ràng buộc mà không module nào tự lo được: **half-duplex** — đang phát TTS thì **không**
được đưa audio vào ASR.

Vì sao cần một lớp riêng: trước P4, việc nối module nằm rải trong `HomeScreen` (`_toggleService`,
`_startAsr`, `_feedAsr`). Mỗi module đúng khi test riêng, nhưng khi chạy cùng nhau thì `_asrChunkSub`
vẫn bơm audio vào ASR trong lúc `SafeTtsOutput` đang đọc ⇒ mic thu lại chính giọng của app và biến nó
thành transcript (**feedback loop**). Không có chỗ nào trong code cũ *có thể* ngăn việc đó.

## 2. File & API

| File | Vai trò |
|---|---|
| `lib/services/conversation_session_controller.dart` | Toàn bộ orchestrator (duy nhất) |
| `lib/audio/tts/safe_tts_output.dart` | Thêm `Stream<bool> speakingChanges` — **tín hiệu** cho half-duplex (không đổi logic an toàn nào của P1F) |
| `lib/core/constants.dart` | `SessionConfig` — ngưỡng phục hồi (`maxConsecutiveAsrFeedFailures`, `maxAsrRestarts`, `latencySampleLimit`) |
| `lib/ui/home_screen.dart` | Chỉ còn bấm nút + hiện trạng thái; KHÔNG tự nối module |

API chính:

```dart
ConversationSessionController({
  AudioCaptureEngine?, ConversationStateMachine?, AsrEngineSelector?, TranscriptStore?,
  TriggerManager?, SafeTtsOutput?, Future<bool> Function()? startService,
  Future<void> Function()? stopService, DateTime Function()? now,
})

Future<bool> start()                     // service → capture → VAD → ASR; không bao giờ ném
Future<void> stop()                      // ASR → VAD → capture → service
Future<void> dispose()                   // teardown lớp điều phối (KHÔNG dừng service/capture)
Future<bool> startAsr() / Future<void> stopAsr()
Future<bool> changeEngine(AsrEngineKind) // dừng phiên + ghi config, KHÔNG tự bật lại
Future<TriggerOutcome?> push({source})   // null = bị bỏ qua vì TTS đang phát
Future<EmergencyTriggerResult> triggerEmergency()
Future<AsrEngineKind> readConfiguredEngine()

SessionPhase get phase                   // idle | listening | processing | speaking
Stream<SessionPhase> get phaseChanges
Stream<String> get notices               // thông báo cho người dùng khi hạ cấp/phục hồi
```

Số liệu đo được (bằng chứng DoD, hiện trên màn hình chẩn đoán):

| Getter | Ý nghĩa | DoD |
|---|---|---|
| `chunksDroppedWhileSpeaking` | Số chunk bị chặn không cho vào ASR khi TTS đang phát | 2 |
| `asrResumeCount` | Số lần ASR được mở lại sau khi đọc xong (nửa còn lại của half-duplex) | 2 |
| `overlapPreventedCount` | Số lần Push bị bỏ qua vì đang phát | 3 |
| `averagePushLatency` | Trung bình `Push → native bắt đầu tổng hợp` (cùng định nghĩa với P1G) | 4 |
| `recoveryCount`, `asrRestartCount` | Số lần phục hồi/hạ cấp module con | 6 |
| `sessionStartedAt` | Mốc bắt đầu phiên (đối chiếu phiên ≥ 30 phút) | 1 |

## 3. Vì sao thiết kế như vậy

### 3.1 `phase` được SUY RA, không lưu song song

`phase` tính từ `_active` / `_speaking` / `_pushInFlight`. Một biến enum được cập nhật thủ công ở mỗi
nhánh sẽ có ngày lệch với thực tế (một nhánh `return` sớm quên cập nhật) — mà lệch pha nghĩa là chốt
half-duplex hoặc chốt Push hành xử sai. Suy ra thì không thể lệch.

### 3.2 Tín hiệu half-duplex đến từ `SafeTtsOutput`, không phải bằng cách đếm ở tầng phiên

Cần biết **lúc nào tiếng đã phát xong** — thông tin đó chỉ native có. Nên `SafeTtsOutput` phát
`speakingChanges` (đổi trạng thái, không phát lặp). Cửa sổ báo hiệu **rộng hơn** thời gian có tiếng thật
(bật ngay khi native *nhận* yêu cầu tổng hợp, tắt khi native báo `spoke`) — hướng an toàn có chủ ý.

Đánh đổi đã biết: trong khoảng "native đang tổng hợp nhưng chưa ra tiếng", ASR bị chặn dù chưa có gì
đáng chặn. Với câu nudge 2-4 từ thì đó là vài trăm ms mất audio — chấp nhận được, và đây là hướng duy
nhất không có nguy cơ lọt giọng TTS vào transcript.

### 3.3 Chặn chunk thay vì dừng capture

`CaptureConfig`/P1A giữ mic thu **liên tục** (đúng thiết kế: người dùng không phải bấm gì). Khi TTS
phát, chunk bị **vứt** ở tầng phiên. Dừng/tắt capture để rồi bật lại sẽ tạo khoảng mất audio ở cả hai
đầu và làm `captureBytes`/route phải mở lại nhiều lần — rủi ro cao hơn hẳn việc bỏ vài chunk.

Hệ quả đã biết: buffer nội bộ của engine ASR có một "lỗ" giữa phần trước và sau khi đọc. Với PhoWhisper
(chia chunk) và Vosk (streaming) đều chấp nhận được; **số chunk bị chặn được đếm và hiện lên màn hình**
để không ai phải đoán.

### 3.4 Push bị bỏ qua khi đang phát — và vì sao đó KHÔNG phải cooldown

`SafeTtsBridge.speak()` luôn `stopPlaybackInternal(keepGeneration = true)` ⇒ `AudioTrack.pause()` trước
khi phát câu mới. Nghĩa là cho Push đi qua sẽ **cắt câu đang đọc giữa từ**. Phương án đơn giản nhất
(prompt P4 task 2 cho phép agent chọn) là **bỏ qua Push mới** + nói rõ cho người dùng.

⚠️ Ràng buộc xuyên phase: cooldown 12-15s (chặn cả khi rảnh) **chỉ** thuộc semi-auto mode P6. Chốt ở
đây chỉ chặn đúng khoảng có tiếng đang phát — rảnh thì bấm bao nhiêu lần cũng đi qua
(`test/...: 'bấm liên tiếp khi RẢNH ⇒ mọi lần đều đi qua'`).

### 3.5 Emergency KHÔNG bị chốt đó chặn

Câu thoát hiểm mà phải chờ "đang đọc câu khác" là mất đúng mục đích. Đường này đi thẳng
`TriggerManager.onEmergencyRequested()` → `SafeTtsOutput`. An toàn vẫn được giữ ở tầng native (một
`AudioTrack` tại một thời điểm).

## 4. Phục hồi lỗi (prompt P4 task 5)

| Module con lỗi | Hành vi | Vì sao |
|---|---|---|
| Mic chết (`CaptureStatus.error`) | Dừng ASR + VAD + capture + **service**, thông báo, phiên về `idle`. App không sập. | Không thu được thì để notification "đang lắng nghe" là nói sai sự thật. |
| Cả 2 engine ASR không `init()` được | Phiên **vẫn chạy**: VAD + capture tiếp tục, chỉ mất transcript, có thông báo. | Mất transcript là suy giảm tính năng, không phải lý do dừng phiên. |
| `feedAudioChunk` lỗi 3 lần liên tiếp | Dựng lại engine 1 lần (tối đa `maxAsrRestarts` = 2/phiên), gắn lại transcript store. | ASR là module dễ chết nhất nhưng **dựng lại được** — tắt luôn sẽ biến lỗi tạm thời thành mất tính năng cả phiên. |
| Hết lượt khởi động lại | Hạ cấp: tắt ASR, giữ phiên, thông báo. | Khởi động lại vô hạn = nạp/xả model vài trăm MB liên tục (nóng máy, tụt pin). |
| `TriggerManager` ném lỗi lạ | Nuốt, thông báo, trả `null`; pha về lại `listening`. | `push()` là đường đi từ UI ⇒ không được ném ra UI. |

## 5. Trạng thái & việc còn thiếu

- **Code xong**, `flutter analyze` sạch, **236/236 test** (25 test mới cho P4 — xem
  `test/conversation_session_controller_test.dart`).
- **CHƯA verify trên máy thật** ⇒ 5/6 mục DoD của P4 còn `[~]` (nợ **K46**):
  phiên ≥ 30 phút, xác nhận half-duplex bằng tai + `dumpsys audio`, đo pin, rút tai nghe giữa phiên,
  tắt mạng giữa phiên. Xem `.plan/P4-result.md` mục "Giáo trình kiểm trên máy thật".

## 6. Cảnh báo khi sửa

1. **Đừng thêm nhánh nghiệp vụ vào orchestrator.** "Nếu đang nói thì…" ⇒ `SuggestionPolicy` (P2);
   "nếu không có tai nghe thì…" ⇒ `OutputModeSelector`/`SafeTtsOutput` (P1F/P3).
2. **Đừng tự dựng instance module con trong UI.** Hai `EmergencyPhraseService` ⇒ hai bộ xoay vòng câu
   khác nhau; hai `TriggerManager` ⇒ hai bộ đếm/anti-repetition khác nhau. Truy cập qua
   `controller.trigger` / `.transcript` / `.conversation` / `.emergency`.
3. **Đừng đổi thứ tự mở/đóng phiên.** Mở: service → capture → VAD → ASR. Đóng: ngược lại (model ASR
   nặng nhất nhả trước; mic luôn nhả trước khi tiến trình hết foreground).
4. **Đừng "tối ưu" `_onChunk` thành đưa chunk vào ASR khi đang phát** (ví dụ để "đỡ mất audio") — đó
   chính là feedback loop mà P4 tồn tại để chặn.
5. Nếu thêm nguồn trigger mới (volume key / nút BT / notification): gọi
   `ConversationSessionController.push(source: …)`, KHÔNG gọi `TriggerManager` trực tiếp.
6. **Lỗi native đã biết chưa sửa:** phát câu mới khi câu trước còn đang đọc có thể bị **im lặng** do
   `SafeTtsBridge` dùng chung field `tempWav` giữa hai "thế hệ" — xem `tts-safety.md` mục 7 (nợ **K45**).
   Đây là lý do `push()` bỏ qua khi đang phát; đường Emergency thì vẫn phơi ra rủi ro này.
