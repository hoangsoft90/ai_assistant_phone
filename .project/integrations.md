# integrations.md — Tích hợp bên thứ ba & cấu hình hệ thống

Cập nhật: 2026-09-24 (+07).

> Trả lời thẳng mấy câu hay bị giả định sai: **không có Firebase, không có Supabase, không có push
> notification, không có payment, không có backend.** CI/CD: **đã có GitHub Actions build APK** từ
> P1E (mục 5). Chi tiết ở mục 2.

## 1. Thư viện đang dùng (tất cả trong `pubspec.yaml`)

### Runtime dependencies — 6 package, cố ý giữ tối thiểu

| Package | Version | Vì sao | Phase |
|---|---|---|---|
| `flutter_foreground_task` | `^11.0.3` | Giữ tiến trình sống khi tắt màn hình / app bị minimize (yêu cầu cốt lõi: nghe liên tục hàng chục phút) | P0.5 |
| `audio_session` | `^0.2.4` | Đặt thuộc tính audio phía hệ thống (content=speech, usage=media). **Chỉ cấu hình PLAYBACK** | P0.5 |
| `sqflite` | `^2.4.4` | SQLite cho transcript store (truy vấn theo thời gian + dump theo phiên) | P0.5 (khung), P1E |
| `path` | `^1.9.1` | Ghép đường dẫn file DB | P0.5 |
| `flutter_secure_storage` | `^11.2.0` | Lưu API key LLM trong keystore của OS | P2 |
| `permission_handler` | `^13.0.2` | Xin quyền runtime mic + notification (điều kiện để start FGS `type=microphone` trên Android 14+) | P0.5 |
| `cupertino_icons` | `^1.0.8` | Mặc định template | — |

### Dev dependencies

| Package | Version | Ghi chú |
|---|---|---|
| `flutter_test` | sdk | Test |
| `flutter_lints` | `^6.0.0` | Nền lint; `analysis_options.yaml` bật thêm 8 rule |

### Đã cân nhắc và **cố ý không dùng**

| Không dùng | Lý do |
|---|---|
| `hive` / `shared_preferences` | Chọn `sqflite` cho transcript store — xem [patterns.md](patterns.md) |
| `path_provider` | Chưa cần ở P0.5; chỉ thêm khi thực sự dùng tới |
| `go_router`, `auto_route` | Chưa có màn hình thứ 2 — xem [state-routing.md](state-routing.md) |
| Bất kỳ state management library | Chưa chốt — mốc là P1B |

## 2. Dịch vụ cloud / backend

| Hạng mục | Trạng thái | Ghi chú |
|---|---|---|
| **Firebase** | ❌ **không dùng** | Không có `google-services.json`, không có Google Services plugin trong Gradle |
| **Supabase** | ❌ **không dùng** | |
| **Backend tự dựng** | ❌ **không có** | App là công cụ cá nhân, chạy đơn lẻ trên 1 máy |
| **Auth / tài khoản** | ❌ **không có, và không nằm trong kế hoạch** | Một người dùng duy nhất |
| **Push notification (FCM)** | ❌ **không dùng** | Chỉ có **local notification** của foreground service |
| **Payment gateway** (Stripe/ZaloPay/…) | ❌ **không áp dụng** | Không phải app thương mại |
| **Analytics / crash reporting** | ❌ **chưa có** | Chưa quyết có dùng hay không |
| **LLM API** | ⏳ **chưa chọn nhà cung cấp** | Sẽ chốt ở **P2**; đây là **thành phần duy nhất cần mạng** |
| **ASR cloud** | ❌ **không dùng, và bị CẤM** | ASR phải chạy offline trong app — ràng buộc cứng #4 ở [overview.md](overview.md) |

## 3. Quyền hệ thống đã khai báo (`AndroidManifest.xml`) — 7 quyền

| Quyền | Vì sao | Phase dùng thật |
|---|---|---|
| `RECORD_AUDIO` | Thu từ mic điện thoại | P1A |
| `FOREGROUND_SERVICE` | Chạy service | P0.5 |
| `FOREGROUND_SERVICE_MICROPHONE` | Service `type=microphone` (Android 14+ **bắt buộc** khai báo + phải đang giữ `RECORD_AUDIO` mới start được) | P0.5 |
| `BLUETOOTH_CONNECT` | Truy vấn/điều khiển thiết bị Bluetooth đã kết nối (Android 12+) | P1F |
| `POST_NOTIFICATIONS` | Hiện notification của FGS (Android 13+) | P0.5 |
| `INTERNET` | **Chỉ** để gọi LLM ở P2. **KHÔNG** dùng cho ASR | P2 |
| `WAKE_LOCK` | Do `ForegroundTaskOptions(allowWakeLock: true)` — giữ CPU thức khi nghe liên tục | P0.5 |

**Service khai báo:** `com.pravera.flutter_foreground_task.service.ForegroundService` với
`android:foregroundServiceType="microphone"`. **Tên service không được đổi** (ràng buộc của plugin).

**Deep link:** không có. Manifest chỉ có intent-filter `MAIN`/`LAUNCHER`; activity dùng
`launchMode="singleTop"`.

## 4. Model AI (không phải cloud — chạy local trong app)

| Thành phần | Kích thước | WER đo trên host (10 clip FLEURS `vi_vn`) | Trạng thái |
|---|---|---|---|
| **PhoWhisper-base** GGML q5_0 | 55 MB | **12.4%** (RTF 0.53) | Đã convert, đã verify decode |
| PhoWhisper-tiny GGML q5_0 | 30 MB | 15.5% (RTF 0.29) | Đã convert, đã verify decode |
| Vosk `vosk-model-small-vn-0.4` | 51 MB | 52.2% → 41.1% sau chuẩn hoá âm lượng | Đã tải |
| Vosk `vosk-model-vn-0.4` | 168 MB | 53.0% → 40.3% | Đã tải |

- Model nằm ở `spikes/p0_audio/models/` — **đã gitignore** (artifact ~133MB, không commit).
- ⚠ **Vosk trả về RỖNG khi audio nhỏ tiếng** (đúng kịch bản mic điện thoại để xa) — nếu chọn Vosk thì
  P1A **bắt buộc** phải có AGC/kiểm soát gain.
- Số WER ở trên là **trên host (PC)**, **chưa đo trên điện thoại**. Chưa có quyết định go/no-go.
- Lệnh/công cụ tái sử dụng: `spikes/p0_audio/tools/`, số liệu thô ở `spikes/p0_audio/reports/*.json`.

## 5. CI/CD

| Hạng mục | Trạng thái |
|---|---|
| GitHub Actions | ✅ **đã có, chạy mỗi push `main`** — 2 workflow: `build-debug-apk.yml` (artifact `app-debug-apk`, ~115 MB) + `build-release-apk.yml` (R8/minify, APK release unsigned ~71 MB, upload `mapping.txt`). Máy dev không có Android SDK ⇒ **mọi APK đều đến từ CI** |
| Fastlane | ❌ không có kế hoạch (app cá nhân, không phát hành store) |
| Keystore/release signing | ⏳ chưa thiết lập (chốt với user ở P7 — release hiện debug-signed) |
| Repo GitHub | ✅ `github.com/hoangsoft90/ai_assistant_phone` (private) |

**Bối cảnh máy dev (để hiểu vì sao mọi thứ phải build qua CI):**
- Máy dev Linux này **chỉ có `platform-tools` (adb)**, **không có** Android platforms / build-tools / NDK
  ⇒ **không build được APK tại đây**.
- `/home` gần như đầy (**~396MB trống**) — các thao tác nặng phải chạy ở `/tmp`.

## 6. Kiểm chứng cần thiết trước khi tin một tích hợp này "chạy được"

- `flutter analyze` + `flutter test` phải sạch (đã sạch ở P0.5).
- **APK chưa từng build** → toàn bộ Gradle/AGP/Kotlin/plugin chưa được biên dịch lần nào. Rủi ro còn
  nằm ở bước này, không ở code Dart.
- Trên máy thật phải kiểm: quyền mic+notification, FGS sống khi tắt màn hình, DB tạo được,
  log `becomingNoisy` khi rút tai nghe. Danh sách 4 bước nằm ở `README.md` (gốc repo).
