# `lib/transcript/` — transcript store (P1E)

Rolling transcript của phiên hội thoại hiện tại: có timestamp, khôi phục được sau khi app bị OS kill,
tự xoá sau 7 ngày. Đây là **nguồn dữ liệu cho Suggestion Engine (P2)** và **Post-Review (P5)**.

| File | Nội dung |
|---|---|
| `transcript_segment.dart` | Model `TranscriptSegment` — **chỉ** `text` + `timestamp`. |
| `transcript_store.dart` | `TranscriptStore` (rolling trong RAM + ghi đĩa ngay) và `TranscriptWindow` (kết quả cho P2). |

Phần chạm SQLite nằm ở `lib/services/storage/transcript_dao.dart` (interface `TranscriptDao` + bản
`SqliteTranscriptDao`), theo đúng cách `ConfigStore`/`MetaConfigStore` của P1D đã làm — nhờ vậy store
test được bằng DAO giả trong bộ nhớ, không cần platform channel.

## 1. Ràng buộc không được vi phạm ở các phase sau

- **KHÔNG có trường `speaker`/`label`** trong model (quyết định 4.2b, `AGENT_INSTRUCTIONS.md` mục 3).
  Text đưa cho LLM là **thô, không nhãn** — LLM tự suy luận ai đang nói từ ngữ nghĩa. Thêm nhãn "cho
  tiện" ở P2/P5/P6 là vi phạm.
- **KHÔNG lưu audio thô** (mục 5.3). Chỉ text. (`lib/audio/capture/wav_sink.dart` là tiện ích debug từ
  P1A và hiện **không được dùng ở đâu** trong app — nếu phase sau định bật nó để gỡ lỗi, phải xoá file
  WAV ngay sau khi xong, hoặc bỏ tính năng đó.)
- **KHÔNG gọi cloud** ở tầng này (chiều thu 100% offline).
- **KHÔNG thêm API `endSession()`** khi chưa có ai gọi. Phiên kết thúc bằng quy tắc "im lặng quá
  `StorageConfig.transcriptResumeGap`" — xem mục 3.

## 2. API cho P2

```dart
final TranscriptStore store = TranscriptStore.instance();   // đã init() ở main()
store.attach(engine);                    // mỗi text từ AsrEngine.transcriptStream → 1 dòng

final TranscriptWindow w = await store.recentWindow(window: const Duration(minutes: 3));
w.text             // text thô, mỗi dòng 1 dòng cách nhau bằng '\n' — KHÔNG nhãn
w.lastPushMoment   // mốc Push gần nhất (null nếu chưa bấm)
```

Ghi mốc Push (nút thật là việc của P3 — `home_screen.dart` hiện có nút tạm để kiểm trên máy):

```dart
await store.markPushMoment(DateTime.now());
```

Cửa sổ ≤ `rollingWindow` (8 phút) đọc từ RAM; dài hơn thì đọc SQLite — **không bao giờ cắt cụt âm thầm**.

## 3. Quy tắc phiên (session)

- Phiên = một lần "mở app và nói chuyện". `transcript_sessions` có `started_at_ms` +
  `last_activity_at_ms`, **không có `ended_at`**: phiên mới bắt đầu khi phiên gần nhất đã im lặng quá
  `transcriptResumeGap` (30 phút).
- **Khôi phục (crash recovery):** `TranscriptStore.init()` chạy ở `main()` lúc bootstrap. Nếu phiên gần
  nhất còn trong hạn 30 phút ⇒ **nối tiếp** phiên đó, nạp lại các dòng trong cửa sổ rolling, và
  `recoveredSegmentCount > 0`. Nếu quá hạn ⇒ mở phiên mới, **phiên cũ vẫn nằm trên đĩa** (P5 cần).
- Mỗi dòng được ghi xuống SQLite **ngay khi nhận** (không gom lô) — vì bị kill đột ngột là tình huống
  phải chịu được, mất một lô là mất dữ liệu thật.

## 4. Quyền riêng tư & lưu trữ

- Tự xoá mọi phiên có hoạt động cuối cũ hơn **7 ngày** (`StorageConfig.transcriptRetention`), chạy ở
  `init()` (mỗi lần mở app). Xoá theo transaction: dòng transcript + mốc Push + phiên cùng xong hoặc
  cùng không (không để dòng mồ côi).
- **Chưa mã hoá DB.** Đã kiểm tài liệu package: `sqflite` **không** hỗ trợ mã hoá; muốn mã hoá phải
  đổi sang `sqflite_sqlcipher` (package thay thế trực tiếp). Prompt P1E cho phép bỏ qua mã hoá ở phase
  này ("KHÔNG mã hoá phức tạp ở phase này nếu chưa cần"), nên dữ liệu hiện nằm trong **thư mục riêng
  của app** (Android sandbox) và bị xoá sau 7 ngày. **Nợ mở:** quyết định có chuyển sang SQLCipher
  không — cần người dùng chốt trước khi phát hành cho người khác dùng.
- Khi chuyển sang SQLCipher sau này: đây **không** phải migration schema (giữ nguyên 3 bảng), mà là
  đổi cách mở DB + chuyển dữ liệu cũ sang DB mã hoá (`sqlcipher_export`), hoặc chấp nhận xoá dữ liệu
  cũ một lần. Đừng lặng lẽ tạo file DB mới mà bỏ quên file cũ (còn plaintext trên đĩa mãi mãi).

## 5. Test

- **Unit test (đã có, tự động):** `test/transcript_store_test.dart` — 15 test: ghi dòng + timestamp,
  bỏ chuỗi trắng, giữ thứ tự khi 3 dòng đến sát nhau, cửa sổ rolling, **khôi phục phiên đang dở**
  (dựng sẵn dữ liệu trong DAO giả như lần chạy trước rồi tạo store mới), phiên quá hạn ⇒ phiên mới,
  **xoá sau 7 ngày** (kiểm cả mốc cutoff truyền xuống DAO), mốc Push, API text thô không nhãn, cửa sổ
  dài hơn RAM đọc từ đĩa, và regression "attach lần hai không nhân đôi dòng".
- **Migration SQL:** kiểm offline bằng `sqlite3` của Python — trích thẳng 5 câu `CREATE ...` trong
  `app_database.dart`, chạy trên DB v1 giả: bảng + index mới đúng, dữ liệu `meta` cũ còn nguyên. (Máy
  dev không có Android SDK nên đây là mức kiểm cao nhất làm được tại chỗ.)

### Kiểm trên máy thật (DoD P1E — chưa chạy, thuộc nợ K27)

```bash
# 1) Crash recovery
#    Mở app → "Bật lắng nghe" → nói vài câu (dòng "Transcript" trên màn hình phải tăng)
adb shell am kill com.aiassistant.phone          # OS kill tiến trình, DB giữ nguyên
#    Mở lại app → dòng "Transcript" phải ghi "khôi phục N dòng sau khi app bị kill"
#    (N > 0). Nếu mất dữ liệu: ghi lại số dòng trước/sau — không được crash.

# 2) Hạn 7 ngày
#    Đổi ngày hệ thống tiến 8 ngày → mở lại app → dòng "Transcript" bắt đầu phiên mới;
adb shell run-as com.aiassistant.phone ls -l databases/   # DB vẫn còn, chỉ dữ liệu cũ bị xoá
#    (đổi ngày về như cũ sau khi kiểm)

# 3) Xem log: adb logcat -s TranscriptStore TranscriptDao AppDatabase
```
