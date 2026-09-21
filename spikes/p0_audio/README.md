# P0 — Audio Feasibility Spike (throwaway)

Code trong thư mục này là **code thăm dò của Phase 0**, sẽ KHÔNG mang sang P0.5 (xem
`.plan/prompt_P0.md`). Mục đích duy nhất: trả lời go/no-go cho pipeline audio trước khi đầu tư code thật.

> **TRẠNG THÁI: CHƯA HOÀN THÀNH P0.**
> Precondition của P0 (1 điện thoại Android thật + 1 tai nghe Bluetooth + USB debug) **chưa đạt** trong
> môi trường hiện tại: `adb devices` rỗng, máy dev không có Bluetooth. Toàn bộ 5 mục Definition of Done
> của P0 là đo đạc trên thiết bị thật nên **chưa mục nào được tính là đạt**.
> Phần đã làm được là phần không cần thiết bị: chuẩn bị model + tooling + đo baseline trên host.

---

## 1. Đã xong (không cần điện thoại)

### 1.1 Model ASR đã convert & kiểm chứng chạy được

| Model | File | Dung lượng | Ghi chú |
|---|---|---|---|
| PhoWhisper-base GGML q5_0 | `ggml-phowhisper-base-q5_0.bin` | 55 MB | **ứng viên chính** |
| PhoWhisper-tiny GGML q5_0 | `ggml-phowhisper-tiny-q5_0.bin` | 30 MB | nhanh gấp ~1.8x, kém chính xác hơn |
| PhoWhisper-base GGML f16 | `ggml-phowhisper-base-f16.bin` | 148 MB | chỉ để đối chiếu ảnh hưởng của quantize |
| PhoWhisper-tiny GGML f16 | `ggml-phowhisper-tiny-f16.bin` | 78 MB | chỉ để đối chiếu |
| Vosk tiếng Việt (small) | `vosk-model-small-vn-0.4/` | 51 MB | như prompt P0 yêu cầu |
| Vosk tiếng Việt (bản lớn) | `vosk-model-vn-0.4/` | 168 MB | test thêm vì bản small cho kết quả rất kém |

Vị trí:
- Trong repo (đã gitignore, để tiện đẩy sang điện thoại): `models/` — chứa `ggml-phowhisper-base-q5_0.bin`,
  `ggml-phowhisper-tiny-q5_0.bin`, `vosk-model-small-vn-0.4/` (133 MB).
- Bản đầy đủ (thêm f16, vosk bản lớn, bộ audio test): `/tmp/p0spike/models/`.

Model convert lại được bất cứ lúc nào bằng `tools/convert_phowhisper.sh` (~10 phút).

Cách kiểm chứng: đã load được bằng `whisper-cli` của whisper.cpp và decode ra tiếng Việt đúng
trên bộ mẫu có ground-truth (không phải chỉ "file tồn tại"). Chi tiết ở mục 2.

### 1.2 Tooling (dùng lại được cho P1C/P1D)

| File | Việc |
|---|---|
| `tools/convert_phowhisper.sh` | HF → GGML f16 → quantize q5_0, end-to-end (chính là việc cần cho P1C) |
| `tools/fetch_test_audio.py` | Tải 10 clip tiếng Việt thật (FLEURS vi_vn) + transcript ground-truth, chuẩn hoá về WAV 16kHz mono PCM16 |
| `tools/normalize_audio.py` | Peak-normalize WAV (để so sánh công bằng giữa các engine, và để kiểm chứng giả thuyết "engine yếu vì âm lượng") |
| `tools/verify_models.py` | Chạy whisper-cli trên bộ mẫu, tính WER + RTF, xuất JSON |
| `tools/verify_vosk.py` | Chạy Vosk trên cùng bộ mẫu, tính WER + RTF, xuất JSON |
| `reports/*.json` | Số liệu thô của các lần đo dưới đây (bằng chứng) |

---

## 2. Số liệu baseline trên HOST (không phải điện thoại)

Điều kiện đo: 10 clip FLEURS `vi_vn/validation`, giọng người thật, có transcript chuẩn; host 4 CPU
(`nproc=4`); whisper.cpp build Release, 4 threads; Vosk Python API.
`RTF` = thời gian xử lý / độ dài audio (< 1 = nhanh hơn realtime).
Cột "raw" = audio gốc; "norm" = đã peak-normalize về 0.5.

| Model | Size | WER raw | WER norm | RTF raw | RTF norm | Ghi chú |
|---|---|---|---|---|---|---|
| PhoWhisper-base f16 | 148 MB | **12.3 %** | 12.3 % | 0.49 | 0.50 | |
| PhoWhisper-base q5_0 | 55 MB | **12.4 %** | 13.0 % | 0.54 | 0.53 | quantize gần như không mất chất lượng |
| PhoWhisper-tiny f16 | 78 MB | 15.8 % | 15.5 % | 0.27 | 0.26 | |
| PhoWhisper-tiny q5_0 | 30 MB | 15.5 % | 16.6 % | 0.30 | 0.29 | nhanh nhất, WER cao hơn base ~3-4 điểm |
| Vosk small vn 0.4 | 51 MB | 52.2 % | 41.1 % | 0.95 | 1.09 | raw: **2/10 clip trả về RỖNG** |
| Vosk vn 0.4 (bản lớn) | 168 MB | 53.0 % | 40.3 % | 0.18 | 0.21 | raw: cũng 2/10 clip rỗng |

Kết luận sơ bộ có bằng chứng: **PhoWhisper thắng Vosk rõ rệt** (12-16% so với 40-53% WER) và Vosk
không hề nhanh hơn — bản Vosk lớn thậm chí chạy nhanh hơn bản small. Đây là cơ sở định hướng, **không
thay thế** quyết định cuối vì chưa đo trên CPU điện thoại và chưa đo bằng chính giọng người dùng.

### Phát hiện đáng chú ý

1. **Vosk trả về rỗng khi audio nhỏ tiếng.** 2 clip có mức thu thấp (peak 546 và 830 trên thang 32767)
   → cả Vosk small lẫn Vosk lớn đều cho transcript rỗng hoàn toàn; sau khi khuếch đại x20-x30 thì đọc
   được. Với app này, kịch bản thật là **mic điện thoại để xa người nói → mức thu thấp**, nên đây là
   rủi ro kiến trúc thật nếu chọn Vosk, và là lý do phải có AGC/kiểm soát gain ở P1A.
2. **Quantize q5_0 gần như miễn phí**: base 148MB → 55MB, WER 12.3% → 12.4%. Rất đáng dùng cho mobile.
3. **Tốc độ PhoWhisper-base trên host 4 CPU: RTF 0.53** → chunk 3 giây mất ~1.6s xử lý; tiny ~0.9s.
   Trên CPU điện thoại sẽ chậm hơn nhiều lần → đây chính là con số P0 phải đo lại trên máy thật
   (DoD: "độ trễ… đo trên chính giọng người dùng").
4. **WER 12-16% của PhoWhisper ở đây cao hơn con số 4.6% mà `plan_final_v2.md` trích dẫn** — vì con số
   kia đo trên VIVOS (đọc sách, sạch, gần domain train), còn FLEURS khó hơn. Không có nghĩa model hỏng;
   nhưng khi so sánh với tài liệu kế hoạch cần biết hai bộ số không cùng thang đo.

---

## 3. Số liệu chưa có (bắt buộc phải đo trên thiết bị thật)

Các mục dưới đây **vẫn là việc trống của P0**, không được coi là xong:

- [ ] Task 1: độ chính xác trên **giọng người dùng**, đo tại chỗ (phòng yên tĩnh + ồn vừa).
- [ ] Task 1: độ trễ thật trên CPU điện thoại (Vosk streaming vs PhoWhisper theo chunk 3-5s).
- [ ] Task 1: **tiêu hao pin** 30 phút cho từng model (chạy riêng, không đồng thời).
- [ ] Task 1: ổn định 45-60 phút, màn hình tắt, chế độ máy bay (xác nhận không cần mạng).
- [ ] Task 2: **giữ A2DP hay bị ép HFP** khi mic điện thoại thu + tai nghe Bluetooth chỉ phát.
- [ ] Task 3: rút tai nghe đột ngột / mất kết nối đúng lúc TTS phát — xác nhận **không lọt ra loa ngoài**.
- [ ] Task 4: chạy full pipeline 45-60 phút liên tục, đếm số lần tự dừng/mất transcript/crash.
- [ ] Quyết định go/no-go bằng văn bản (PhoWhisper hay Vosk mặc định cho P1C/P1D).

### Protocol đề xuất khi có máy

```bash
# 0. Xác nhận kết nối
adb devices -l

# 1. Đẩy model sang máy (không cần build lại app khi đổi model)
adb push /tmp/p0spike/models/ggml-phowhisper-base-q5_0.bin /sdcard/Download/
adb push /tmp/p0spike/models/vosk-model-small-vn-0.4 /sdcard/Download/

# 2. Đo route audio trong lúc app đang thu mic + phát TTS (Task 2)
adb shell dumpsys audio | grep -iE "a2dp|sco|bluetooth|route" | head -40
#    -> "giữ A2DP" hay "bị ép HFP" là kết luận go/no-go của mục 4.2a

# 3. Đo pin (Task 1): đọc mức pin trước/sau 30 phút, tách pin của app
adb shell dumpsys batterystats --charged | grep -A5 "Uid u0a"     # thay bằng uid của app
adb shell dumpsys battery | grep -E "level|status"

# 4. Theo dõi ổn định 45-60 phút, màn hình tắt
adb shell input keyevent 26
adb logcat -s P0Spike:I | tee /tmp/p0_run.log
```

Sau khi có số liệu, cập nhật bảng ở mục 2 (thêm cột "on-device") rồi mới kết luận go/no-go.

---

## 4. Bàn giao của P0

- [x] Tooling + model đã convert & kiểm chứng chạy được trên host (bằng chứng: `reports/*.json`).
- [ ] Báo cáo P0 đầy đủ với số liệu on-device và quyết định go/no-go — **chưa làm được**, chờ thiết bị.
- [x] Code app spike throwaway (mục 5) — `flutter analyze` + `flutter test` sạch, JNI biên dịch sạch; APK chưa build (thiếu SDK, sẽ build trên CI).

## 5. App spike (đã viết code, CHƯA build lần nào)

`app/` là app Flutter (throwaway) tạo bằng `flutter create` (Flutter 3.47.2 / Dart 3.13.2,
AGP 9.1.0, Kotlin 2.4.0, NDK 28.2.13676358, minSdk 24).

Kiến trúc: **mọi thứ audio/ASR nằm ở Kotlin/native, Flutter chỉ là màn hình điều khiển + log** —
đúng hướng P1A/P1C, nên phần kiểm chứng được ở P0 dùng lại được về sau.

| File | Việc |
|---|---|
| `lib/main.dart` | UI: nút chạy Vosk / PhoWhisper (chunk 3s, 5s), Test TTS, bật FGS, hiển thị transcript + trạng thái route |
| `.../SpikeController.kt` | Điều phối: `AudioRecord` (nguồn `MIC`), gom chunk, vòng log trạng thái route/pin mỗi 5s |
| `.../AsrEngines.kt` | `VoskEngine` (streaming) + `WhisperEngine` (chunk, bỏ chunk nếu xử lý không kịp) + JNI binding |
| `.../RouteProbe.kt` | Đọc SCO/A2DP/thiết bị in-out/pin — phục vụ Task 2; `TtsTest` phục vụ Task 2/3 |
| `.../SpikeService.kt` | Foreground service `type=microphone` + `PARTIAL_WAKE_LOCK` để chạy nền 45-60 phút |
| `cpp/whisper_jni.cpp` + `cpp/CMakeLists.txt` | whisper.cpp kéo qua FetchContent, **pin theo commit `307869a`** (đúng bản đã dùng để convert model) |

### Đã kiểm chứng được (không cần thiết bị)

- `flutter analyze` → **No issues found**.
- `flutter test` → **All tests passed** (smoke test UI).
- `whisper_jni.cpp` → **biên dịch sạch** (kiểm tra cú pháp + API `whisper.h` bằng g++ host
  với `jni.h` của JDK và stub `android/log.h`). Đây là phần dễ sai nhất nên đã kiểm tra riêng.

### CHƯA kiểm chứng (nói rõ để không hiểu nhầm là đã chạy)

- **Chưa từng build APK**: máy dev thiếu Android SDK platform/build-tools/NDK. Rủi ro còn lại
  tập trung ở Gradle/NDK (`externalNativeBuild`, AGP 9.1) và phần Kotlin (chưa có compiler để check).
- Chưa chạy trên điện thoại: chưa xác nhận mic mở được, model load được, transcript ra đúng,
  route A2DP/SCO, TTS có lọt loa ngoài hay không, foreground service có sống qua 45-60 phút không.

### Build (dự kiến chạy trên GitHub Actions)

Máy dev này cố tình không cài SDK. Khi có repo GitHub:

```bash
flutter build apk --release      # hoặc --debug cho lần chạy thử đầu
```

APK cần: Android SDK (compileSdk 36, build-tools), **NDK 28.2.13676358** (Gradle tự tải nếu runner
có `sdkmanager`), và mạng để tải whisper.cpp về qua FetchContent ở bước CMake.
Nếu build lần đầu fail, ba chỗ nên xem trước tiên: cờ `GGML_*` trong `cpp/CMakeLists.txt`,
`abiFilters` (đang chỉ build `arm64-v8a`), và `ndkVersion` trong `android/app/build.gradle.kts`.

### Đẩy model sang máy (không cần build lại app khi đổi model)

App đọc model từ thư mục riêng của nó; bấm refresh trên UI để xem đúng đường dẫn tuyệt đối
(dạng `/sdcard/Android/data/vn.p0spike.p0_spike/files/models`):

```bash
DIR=/sdcard/Android/data/vn.p0spike.p0_spike/files/models
adb shell mkdir -p $DIR
adb push spikes/p0_audio/models/ggml-phowhisper-base-q5_0.bin $DIR/
adb push spikes/p0_audio/models/ggml-phowhisper-tiny-q5_0.bin $DIR/
adb push spikes/p0_audio/models/vosk-model-small-vn-0.4 $DIR/
adb shell ls -l $DIR
```

Nếu thiết bị chặn ghi vào `Android/data` qua adb: bật Developer options → tắt "Verify apps over USB",
hoặc dùng `flutter run` + copy model vào bộ nhớ trong của app bằng chính UI/`adb shell run-as`.
App cũng hiện luôn dòng "THIẾU" ở ô model nào chưa có để biết ngay cần đẩy file gì.

### Nhật ký khi chạy test thật

```bash
adb logcat -c
adb logcat -s P0Spike:I P0SpikeJni:I | tee /tmp/p0_run.log
```

Mỗi 5 giây app tự ghi 1 dòng `ROUTE sco=… a2dp=… mode=… out=[…] | pin=…% | audio=…ms` — đây là
dấu vết để trả lời Task 2/3 và đo pin Task 1.

## 6. Ràng buộc môi trường (quan trọng trước khi làm tiếp)

- **Đĩa:** `/home` (chứa repo) còn rất ít trống (khoảng **445 MB** sau khi copy 133 MB model vào repo).
  Thao tác nặng phải nằm ngoài repo (đang dùng `/tmp/p0spike`, ~52 GB). `/tmp` có thể bị xoá khi reboot —
  model trong repo (`models/`) là bản đã sao lưu, chỉ mất các file f16/vosk-bản-lớn trong `/tmp`.
- **Android SDK:** thiếu `platforms`/`build-tools`/`ndk` → chưa `flutter build apk` được (theo yêu cầu,
  sẽ build trên GitHub Actions thay vì cài SDK ở máy này).
- **Thiết bị:** hiện chưa có điện thoại/Bluetooth kết nối tới máy dev; người dùng sẽ cắm điện thoại
  vào máy này sau khi code xong.
- **Cài đặt đã thực hiện trên máy:** python venv + torch CPU + transformers + vosk tại `/tmp/p0spike/venv`
  (không cài gì global, không đụng vào site-packages của hệ thống).

## 7. Sai khác so với `prompt_P0.md`

| Prompt ghi | Thực tế | Xử lý |
|---|---|---|
| "model Vosk tiếng Việt (bản nhỏ, ~50MB)" | `vosk-model-small-vn-0.4`, giải nén 51 MB (zip 33 MB) — vẫn đúng ý | giữ nguyên, ghi lại version cụ thể |
| "Vosk (~12% WER, model cũ 2020)" (trích trong P1C) | Đo thật trên FLEURS: 40-53% WER cho cả 2 bản Vosk | ghi nhận, không dùng số 12% để lập luận |
| "PhoWhisper ~4.6% WER trên VIVOS" | Đo trên FLEURS: 12.3-12.4% (base) | khác domain benchmark, không phải lỗi model |
| Convert bằng `convert-h5-to-ggml.py` | Đúng, script còn tồn tại | giữ nguyên; đã ghi lại pitfall `hf download --include` bỏ sót `config.json` |
| Đo audio route bằng `dumpsys audio` | Chưa chạy được (không có thiết bị) | để nguyên trong protocol mục 3 |
