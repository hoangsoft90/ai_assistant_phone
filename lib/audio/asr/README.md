# ASR — chọn engine nào làm mặc định (P1D)

> **Quyết định:** engine mặc định là **PhoWhisper** (`AsrEngineKind.phoWhisper`), **Vosk** giữ vai
> trò dự phòng và có thể bật bằng cấu hình **không cần build lại app**.
>
> ⚠️ Quyết định này là **TẠM THỜI** cho tới khi có số đo trên máy thật (nợ **K18/K19**). Toàn bộ số
> liệu bên dưới đo trên **CPU của máy dev** (spike P0), KHÔNG phải trên điện thoại — xem mục
> "Còn thiếu gì để chốt".

## 1. Hai engine

| | PhoWhisper (whisper.cpp) | Vosk |
|---|---|---|
| Cách chạy | Một lượt cho cả đoạn; Dart gom **4s** rồi gửi xuống native | **Streaming**; mỗi chunk đẩy thẳng xuống, tự endpointing khi hết câu |
| Cài đặt | JNI + CMake tự viết, model GGML convert thủ công | AAR chính chủ `com.alphacephei:vosk-android` (JNA), model có sẵn |
| Cùng thread với mic | Không (executor riêng) | Không (thread riêng + hàng đợi giới hạn) |

## 2. Số đo trên host (spike P0) — cơ sở của quyết định

WER = tỉ lệ lỗi từ; RTF = thời gian xử lý / thời gian audio (nhỏ hơn 1 = nhanh hơn thời gian thực).

| Model | Kích thước | WER | RTF | Nguồn |
|---|---|---|---|---|
| **PhoWhisper tiny q5_0** ← đang đóng gói trong app | 29.9 MB | **16.64%** | **0.29** | `verify_report_norm.json` |
| PhoWhisper tiny f16 | 77.7 MB | 15.5% | 0.264 | `verify_report_norm.json` |
| PhoWhisper base q5_0 | 55.3 MB | 12.98% | 0.529 | `verify_report_norm.json` |
| PhoWhisper base f16 | 148 MB | 12.34% | 0.498 | `verify_report_norm.json` |
| **Vosk small-vn-0.4** ← đang đóng gói trong app | 32.1 MB (zip) / 51 MB (giải nén) | **52.18%** | **0.899** | `verify_vosk_report_raw.json` |
| Vosk vn-0.4 (bản lớn) | 74.4 MB (zip) / 168 MB (giải nén) | 40.34% (norm) · 52.99% (raw) | 0.214 · 0.182 | `verify_vosk_report.json`, `verify_vosk_big_raw.json` |

**Đọc bảng này ra 3 kết luận:**

1. **PhoWhisper thắng về chất lượng rất rõ** — 16.6% so với 40–52% WER cho tiếng Việt. Với một trợ
   lý giao tiếp (transcript sẽ đi vào P1E/P2), sai 40–52% từ là gần như không dùng được.
2. **Vosk bản "small" không hề rẻ**: WER tệ hơn **và** RTF 0.899 (chậm hơn PhoWhisper tiny 3×). Đây
   là kết quả phản trực giác so với các ngôn ngữ khác, nên đừng suy đoán theo tên model.
3. **Vosk chỉ có một lợi thế đo được: bản lớn `vn-0.4` chạy 0.18–0.21 RTF** (nhanh hơn thời gian
   thực ~5×) — nhưng phải trả giá 74.4 MB zip / **168 MB** giải nén trên máy.

> Ghi chú so sánh: số của Vosk small lấy từ báo cáo **raw** (không có bản normalize cho model này),
> còn số PhoWhisper lấy từ bản **normalize**. Vosk big có cả hai: 40.34% (norm) / 52.99% (raw). Chênh
> lệch ~3× về WER lớn hơn nhiều so với sai số giữa hai cách chuẩn hoá, nên không đổi kết luận.

## 3. Vì sao chọn PhoWhisper làm mặc định

- Chất lượng là ràng buộc cứng với phase này: transcript sai 40%+ sẽ làm P1E (transcript store) và
  P2 (gợi ý) vô nghĩa, trong khi mục tiêu cả app là hỗ trợ giao tiếp.
- RTF 0.29 trên host ⇒ ước lượng trên điện thoại vẫn có khả năng chạy nổi; **đây chính là điều chưa
  có bằng chứng** (K18/K19). Vosk bản lớn là đường thoát nếu đo ra ngược lại.
- Vosk bản small đang đóng gói chỉ đủ cho việc "có tiếng nói hay không" — mà việc đó **đã có VAD
  WebRTC (P1B)** lo rồi, nên không dùng được để biện minh cho chất lượng thấp.

## 4. Đổi engine thế nào (không cần build lại)

- **Trên máy:** màn hình chính → mục `Engine nhận dạng (ASR)` → chọn PhoWhisper/Vosk. Đang chạy thì
  app tự khởi động lại engine để so sánh ngay.
- **Bằng tay (khi debug):** bảng `meta` trong SQLite của app, khoá `asr.engine`, giá trị
  `phowhisper` hoặc `vosk` (`AsrEngineSelector.configKey`). Giá trị lạ ⇒ quay về mặc định, không crash.
- **Fallback tự động:** `init()` engine đã chọn thất bại (ví dụ không đủ RAM) ⇒ tự chuyển engine còn
  lại và **ghi log rõ lý do**; cấu hình đã lưu KHÔNG bị đổi (fallback chỉ cho phiên đó).

Tầng trên (P1E transcript store, P2 suggestion) chỉ nhận `AsrEngine` — đổi engine không phải sửa
một dòng nào ở trên.

## 5. Model đóng gói thế nào (và vì sao khác model PhoWhisper)

| | Model PhoWhisper | Model Vosk |
|---|---|---|
| Vị trí | `assets/models/ggml-phowhisper-tiny-q5_0.bin` | `android/app/src/main/assets/models/vosk-model-small-vn-0.4.zip` |
| Khai báo | `assets:` trong `pubspec.yaml` | **không** khai trong pubspec (Android asset thuần) |
| Trong git | Có (29 MB, artifact convert thủ công ở P0) | **Không** — CI tải về + kiểm SHA256 |
| Dart có đọc bytes? | Có (`rootBundle` → copy ra file cho JNI) | Không — Kotlin tự mở AssetManager + giải nén |

Lý do bỏ Vosk khỏi `pubspec.yaml`: máy dev chỉ còn ~150 MB đĩa nên model không commit được; mà asset
khai trong pubspec **thiếu file thì `flutter test` fail ngay** ở bước build asset bundle (đã thử).
Dùng Android asset thì `analyze`/`test` chạy bình thường, CI chỉ cần tải file vào đúng thư mục trước
khi build. Muốn build local: chạy lệnh `curl` trong `.github/workflows/build-debug-apk.yml` (step
"Tải model Vosk + kiểm SHA256") trước.

### Đổi sang model Vosk bản lớn (nếu K18/K19 cho thấy cần)

1. `VoskConfig.modelAssetPath` → `models/vosk-model-vn-0.4.zip`.
2. Workflow: đổi `URL` thành `.../vosk-model-vn-0.4.zip` và `EXPECTED` (SHA256) thành
   `a8ce6ee52e369b8f23f56e87e037db10322e6d94779b08d5e1ab21cb4b737380`.
3. Chạy lại CI. Không phải sửa Dart/Kotlin.

## 6. Ràng buộc không được vi phạm

- **100% offline** ở chiều thu: KHÔNG có đường cloud ASR nào trong hai engine này (ràng buộc xuyên
  phase — chỉ Post-Review P5 được dùng cloud, và chỉ khi có Wi-Fi).
- **Không gắn nhãn người nói** trong transcript của bất kỳ engine nào.

## 6b. Chỉnh tốc độ không cần build lại (`AsrTuning`, nợ K33)

Hai khoá trong bảng `meta` (đọc lúc bật ASR, giá trị hỏng/ngoài khoảng ⇒ quay về mặc định):

| Khoá | Ý nghĩa | Hợp lệ | Mặc định |
|---|---|---|---|
| `asr.chunkSeconds` | Số giây audio góp cho mỗi chunk gửi xuống native | 2–30 | 4 |
| `asr.threads` | Số thread native; `0` = tự động `min(4, số nhân)` | 0–8 | 0 |

Số đo trên máy 2026-09-22 (Pixel 3a, `-O3`, `threads=4`, chunk 4s): **RTF 1.13** (trung vị 4 511 ms
cho 4 000 ms audio) — nhanh hơn 35 lần so với trước khi sửa, nhưng vẫn ≥ 1 nên còn rớt ~1 chunk/40s.
Nghi vấn cần đo (K33): mỗi lần gọi `whisper_full` đều trả giá phần cố định ~30s mel pad ⇒ chunk lớn
hơn có thể rẻ hơn nhiều trên mỗi giây audio.

Cách đo A/B (không cần build lại): dừng app → sửa 2 khoá trong `databases/ai_assistant.db` → mở app
→ bật ASR → đọc log engine `ASR: <latencyMs>ms xử lý <audioMs>ms audio` (qua VM Service `Logging`)
rồi tính `RTF = latencyMs / audioMs`.

## 7. Còn thiếu gì để chốt quyết định (nợ)

| Việc | Vì sao chưa làm được |
|---|---|
| RTF/pin/nhiệt của cả hai engine **trên điện thoại** (K18/K19) | Cần APK + máy thật; mọi số ở mục 2 đều là CPU máy dev |
| So sánh "cùng một đoạn hội thoại" theo DoD P1D | Cần 2 bản APK chạy trên máy + logcat |
| Vosk chạy ổn định ≥45 phút liên tục (DoD P1D) | Như trên |
| JNA có nạp được `libjnidispatch.so` trên máy thật không | `useLegacyPackaging = true` đã bật phòng ngừa (LottieFiles/dotlottie-android#98 từng lỗi) — phải xác nhận bằng logcat `VoskBridge` |
