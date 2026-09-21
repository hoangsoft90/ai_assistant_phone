# Module: conversation-state (VAD) — P1B

Trạng thái: 🟡 **code xong, CHƯA xác minh trên máy thật** (0/4 mục DoD — xem `.plan/P1B-result.md`).
Ngưỡng hiện tại là **giá trị khởi đầu có lý giải**, chưa tinh chỉnh bằng giọng nói thật (nợ K15).

## 1. Mục đích

Phát hiện "có tiếng nói sát mic hay không" từ luồng thu của P1A, suy ra **đúng 2** state
`userSpeaking` / `notUserSpeaking`, để **P2** dùng làm điều kiện **khoá cứng**: đang `userSpeaking`
thì tuyệt đối không gọi LLM, không gợi ý.

## 2. Kiến trúc

```
AudioRecord (thread thu, P1A)
   └─ buffer 100ms ─┬─► copy → EventChannel pcm → Dart (dành cho ASR ở P1C/P1D)
                    └─► VadDetector.analyze() chia khung 20ms ─► VadResult
                          └─► EventChannel vad {speechFrames,totalFrames,frameMs,elapsedMs}
                                └─► ConversationStateMachine (Dart) ─► state 2 giá trị
                                      ├─ ValueNotifier / Stream changes  → UI
                                      └─ isUserSpeaking                  → P2 (chặn LLM)
```

Vì sao VAD chạy ở native chứ không ở Dart: WebRTC VAD chỉ nhận khung 10/20/30ms (chunk PCM của P1A
là 100ms), và làm ngay trên thread thu tránh một vòng dữ liệu qua kênh platform. Chi tiết + lý do
đầy đủ: `.plan/P1B-result.md` mục Sai khác 1.

## 3. File & API

| File | Vai trò |
|---|---|
| `lib/audio/vad/conversation_state.dart` | `ConversationState` (**2 giá trị**), `VadFrameStat` (+`fromNative`), `ConversationStateConfig` (ngưỡng + căn cứ), `ConversationStateChange`, `ConversationStateReason` |
| `lib/audio/vad/vad_client.dart` | `VadChannels.events` + interface `VadClient` + `NativeVadClient` |
| `lib/audio/vad/conversation_state_notifier.dart` | `ConversationStateMachine` (state machine + watchdog mở khoá F2) + `ConversationStateNotifier.instance` |
| `android/.../audio/VadDetector.kt` | Bọc WebRTC VAD: 16kHz, khung 320 mẫu (20ms), `Mode.VERY_AGGRESSIVE`; `frameMs` suy từ cấu hình thật (F3) |
| `android/.../audio/MicCaptureEngine.kt` | Bật/tắt VAD (`setVadEnabled`), chạy `analyze` trên thread thu |
| `android/.../audio/CaptureChannelBridge.kt` | EventChannel `com.aiassistant.phone/vad`, tự bật VAD khi có listener; **F1: đăng ký theo engine (map theo messenger) + `unregister()` bắt buộc khi engine destroy** |

Kênh VAD: `com.aiassistant.phone/vad` → map `{speechFrames, totalFrames, frameMs, elapsedMs}`
(`elapsedMs` = `SystemClock.elapsedRealtime` — đồng hồ **đơn điệu**, không phải wall clock).

## 4. Ngưỡng & thuật toán (đọc trước khi tinh chỉnh)

| Tham số | Giá trị | Căn cứ |
|---|---|---|
| `attackMs` | 300 | Nói ≥300ms tích luỹ → `userSpeaking`; + độ trễ 1 buffer (100ms) ⇒ ≤400ms < 500ms (DoD 1) |
| `releaseMs` | 1500 | Im lặng ≥1.5s → về `notUserSpeaking` (DoD 2 nói ~1–2s). Dài hơn attack **có chủ ý**: thà giữ khoá hơn để AI chen ngang |
| `speechRatioThreshold` | 0.5 | Buffer được coi là "có tiếng nói" khi **đa số** khung (3/5) có tiếng nói → chống nhiễu vài khung lẻ |
| `watchdogMs` | 1500 | **F2 (review P1B, user duyệt)**: đang khoá mà KHÔNG còn buffer VAD nào tới quá 1.5s ⇒ tự mở khoá (reason `inputStalled`) — đường thoát khẩn khi VAD/capture/kênh chết, không phải ngưỡng im lặng tự nhiên. Lỗi stream KHÔNG reset tức thì (quyết định user) — chỉ watchdog mới mở khoá |
| `historyLimit` | 500 | Trần lịch sử trong phiên (RAM) |

Thuật toán: **bộ tích luỹ rò (leaky bucket)** — buffer nói thì `speechAccum += durationMs` và
`silenceAccum -= durationMs` (sàn 0), buffer im thì ngược lại; đổi state khi vượt ngưỡng tương ứng.
Không dùng "đếm chuỗi liên tục" vì 1 khung im lặng ngắn giữa câu sẽ reset đà → state không bao giờ bật.

⚠️ **Bẫy khi sửa watchdog:** Timer phải được hẹn NGAY LÚC vào khoá (trong `_publish`), không chỉ
re-arm trong `_onStat` — buffer gây chuyển state là buffer cuối trước khi hẹn; nếu chỉ re-arm trong
`_onStat` thì lúc vào khoá watchdog chưa hẹn, mất dữ liệu ngay sau đó ⇒ kẹt khoá vĩnh viễn (đúng
bug mà F2 nhắm). Test watchdog phải gọi `machine.start()` BÊN TRONG `fakeAsync` — stream handler
chạy trong zone nơi `listen()` được đăng ký; đăng ký ngoài thì Timer là Timer thật và
`async.elapse` không nổ được nó.

## 5. API endpoints

Không có. Không gửi audio/state đi đâu.

## 6. Local storage

Không ghi gì. `history` chỉ trong RAM, mất khi app thoát (đúng yêu cầu "chỉ trong session hiện tại").

## 7. Test

`test/conversation_state_test.dart` — 20 test: `VadFrameStat`, **khoá phạm vi 2 state**, attack
(≤500ms), release (1500ms), 1 buffer im lặng ngắn không reset đà, nhiễu ngắn không kéo state, ngưỡng
tỉ lệ khung, `changes` chỉ phát khi đổi, `history` cắt theo limit + read-only, `start()` idempotent,
**timeline hội thoại mẫu** (assert theo mốc bắt đầu nói — F5), và **3 test watchdog F2** (nổ đúng
sau watchdogMs; buffer liên tục thì không nổ oan; lỗi stream không reset tức thì).

## 8. Việc còn thiếu

- [ ] ⚠ **Cả 4 mục DoD chưa đo** (phản hồi <500ms với giọng thật, ngừng nói 1–2s, không flicker khi
      có nhạc/TV, chạy 30 phút) — cần APK + thiết bị.
- [ ] **Tinh chỉnh 3 ngưỡng bằng dữ liệu thật** rồi ghi lại giá trị chốt (nợ K15).
- [ ] **Kotlin + dependency JitPack chưa từng được biên dịch** (nợ K14).

## 9. Cảnh báo khi sửa — ⚠ đọc trước

1. **KHÔNG thêm state thứ 3.** Test `ConversationState.values` có `hasLength(2)` sẽ đỏ — đó là chủ ý
   để bảo vệ phạm vi phase (state ngữ nghĩa phức tạp thuộc P6).
2. **KHÔNG phân biệt ai đang nói** (không diarization, không dùng amplitude để đoán người nói) —
   ràng buộc của dự án, đã bị bác bỏ trong `plan_final_v2.md` mục 2.
3. **Đừng bật `speechDurationMs`/`silenceDurationMs` của thư viện** khi chưa bỏ lớp smoothing ở Dart:
   hai lớp chồng nhau sẽ khiến ngưỡng thật khác hẳn ngưỡng khai báo (nợ K15 khó chẩn đoán).
4. **`elapsedMs` phải là đồng hồ đơn điệu**, không dùng `System.currentTimeMillis()` (đổi giờ máy làm
   sai phép đo khoảng thời gian).
5. **VAD chỉ chạy khi có listener** — nếu thêm nơi tiêu thụ mới, nhớ nó phải đăng ký qua EventChannel
   để `setVadEnabled(true)` được gọi, đừng gọi trực tiếp vào engine.
6. Chạm vào audio/VAD ⇒ **vùng loại trừ Ponytail** (an toàn, khó tái tạo để test) ⇒ không tự commit.
