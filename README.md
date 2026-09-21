# ai_assistant_phone — Trợ lý AI hỗ trợ giao tiếp realtime (Android, cá nhân)

App Android chạy trên **1 điện thoại + 4G + 1 tai nghe Bluetooth** (không có server riêng): nghe
cuộc trò chuyện realtime và đưa **gợi ý ngắn (nudge)** khi người dùng chủ động bấm nút xin gợi ý.

## Trạng thái hiện tại

Đang ở **P0.5 — Project Bootstrap**: đã có **khung dự án Flutter** (cấu trúc tầng, permissions,
foreground service skeleton, audio session, lưu trữ, lint). **Chưa có tính năng sản phẩm nào**
nghe/ASR/TTS/gợi ý — các phần đó lần lượt thuộc P1A trở đi.

Tài liệu điều phối ở gốc repo: `checklist.md` (đã/chưa/cần làm), `next.md` (roadmap),
`features.md` (tính năng), `faq.md` (thắc mắc), `LESSONS_LEARNED.md`, `working.md`.
Kế hoạch gốc và báo cáo từng phase nằm trong `.plan/` (ví dụ `.plan/P0-result.md`,
`.plan/P0_5-result.md`).

## Yêu cầu môi trường

| Thành phần | Phiên bản / ghi chú |
|---|---|
| Flutter | 3.47.2+ (Dart 3.13+) |
| JDK | 17 (AGP 9.1 / Kotlin 2.4 build bằng Java 17) |
| Android SDK | `compileSdk 36` + build-tools — **cần cho mọi bước build APK** |
| NDK | **chưa cần ở P0.5**; sẽ cần (NDK 28.2) từ P1C khi tích hợp whisper.cpp |
| Thiết bị | Android **8.0 (minSdk 26)** trở lên, có mic; tai nghe Bluetooth sẽ cần từ P1F |

> Máy dev hiện tại **không cài Android SDK** (theo quyết định của chủ dự án: build sẽ chạy trên
> GitHub Actions). Vì vậy các lệnh `flutter build/run` **chưa từng chạy thành công** ở máy dev —
> xem mục "DoD chưa xác minh" trong `.plan/P0_5-result.md`.

## Build & chạy

```bash
flutter pub get

# Kiểm tra tĩnh + test (chạy được ở mọi máy, không cần SDK/thiết bị)
flutter analyze          # DoD: phải sạch
flutter test

# Build & cài lên máy thật (cần Android SDK + thiết bị đã bật USB debugging)
flutter run --release
# hoặc
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk

# Xem log của app trên thiết bị
adb logcat -s flutter
```

App id: `com.aiassistant.phone`.

## Kiểm tra nhanh trên máy thật (P0.5)

1. Mở app → màn hình chính hiện **"Sẵn sàng"**, các dòng trạng thái quyền/lưu trữ hiện ra.
2. Bấm **"Bật lắng nghe"** → app xin quyền micro + thông báo → phải hiện notification
   **"Đang lắng nghe"** và trạng thái đổi thành "Đang lắng nghe".
3. Bấm Home/thoát ra ngoài vài phút → service vẫn chạy, notification còn đó (không crash).
4. Bấm **"Tắt lắng nghe"** → service dừng, notification biến mất.

## Cấu trúc

```
lib/
  core/        hằng số, logging dùng chung (tầng thấp nhất, không import ngược lên)
  audio/       capture, VAD, ASR, TTS          (P1A-P1G) — P0.5 chỉ có cấu hình audio session
  transcript/  transcript store                (P1E)
  suggestion/  suggestion engine + LLM client  (P2, P3, P5)
  trigger/     trigger abstraction             (P3)
  ui/          màn hình, widget                (P0.5: home; P5: pre-brief/settings...)
  services/    foreground service, lưu trữ, quyền
android/        cấu hình Android (manifest, gradle, MainActivity)
test/           test chạy bằng `flutter test`
spikes/p0_audio/ code thăm dò của Phase 0 (throwaway, không dùng ở P0.5 trở đi; giữ lại để
                 tra cứu tooling + cách gọi whisper.cpp/JNI)
.plan/          kế hoạch gốc + báo cáo từng phase (bị .gitignore)
```

Mỗi thư mục trong `lib/` có `README.md` riêng giải thích vai trò và phase nào sẽ điền vào.

## Ràng buộc kiến trúc (áp dụng cho MỌI thay đổi sau này)

1. **Chiều thu (nghe + ASR) chạy 100% offline** — không thêm cloud ASR cho luồng realtime ở bất kỳ
   phase nào. Cloud chỉ dùng ở Post-Review (P5), và chỉ khi có Wi-Fi.
2. **TTS chỉ phát ra tai nghe**, tuyệt đối không ra loa ngoài. Từ **P1F** trở đi mọi phát âm thanh
   phải đi qua `SafeTtsOutput` (không gọi `flutter_tts`/`TextToSpeech` trực tiếp).
3. **Mic thu là mic điện thoại**; tai nghe Bluetooth chỉ để phát (A2DP). Không dùng audio usage
   `voiceCommunication` vì sẽ kéo hệ thống sang HFP/SCO.
4. **Transcript không gắn nhãn người nói** — không thêm trường `speaker`/`label`.
5. **Push thủ công không cooldown** — cooldown chỉ thuộc semi-auto mode (P6).
6. **Training Level chuyển thủ công** — không tự động đề xuất/chuyển cấp.
