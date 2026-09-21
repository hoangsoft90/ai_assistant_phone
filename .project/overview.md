# overview.md — Tổng quan ứng dụng

Cập nhật: 2026-09-21 (+07).

## 1. App là gì

**Trợ lý giao tiếp** (`ai_assistant_phone`) — trợ lý AI realtime chạy trên Android, giúp người dùng
trong một cuộc hội thoại trực tiếp (nói mặt đối mặt):

1. **Nghe** hội thoại bằng **mic của điện thoại** (không phải mic tai nghe),
2. **Bóc băng (ASR) tại chỗ, offline**,
3. **Gợi ý** câu trả lời / từ khoá cần nói (có thể dùng LLM cloud),
4. **Đọc gợi ý đó** qua **tai nghe Bluetooth đã kết nối — chỉ có người dùng nghe thấy**.

App được thiết kế để **hỗ trợ người dùng đang phải giao tiếp bằng lời trong tình huống khó**
(căng thẳng, ngoại ngữ, cần nói đúng ý) chứ không phải để ghi âm/ghi chú cuộc họp.

## 2. Đối tượng người dùng

- **Một người dùng duy nhất (cá nhân)**, dùng trên **điện thoại Android thật của chính họ**.
- Bối cảnh dùng: đeo tai nghe Bluetooth, điện thoại trong túi/trên bàn, app chạy nền hàng chục phút.
- **Không phải** sản phẩm nhiều người dùng ⇒ **không có** auth, tài khoản, multi-tenant, sync giữa
  các máy ở bất kỳ phase nào. Xem [integrations.md](integrations.md).
- Ngôn ngữ chính: **tiếng Việt** (ASR + gợi ý).

## 3. Tech stack

| Thành phần | Chọn | Ghi chú |
|---|---|---|
| Framework | **Flutter 3.47.2** (stable), Dart SDK `^3.13.2` | Không dùng React Native |
| Nền tảng | **Android only** | Không tạo `ios/`, `web/`, `linux/`, `macos/` |
| Ngôn ngữ chính | Dart (UI + logic) + **Kotlin** (native: audio, service) | Có cả C/C++ qua JNI ở spike P0 |
| `applicationId` / namespace | `com.aiassistant.phone` | |
| **minSdk** | **26** (Android 8.0) | Đặt tường minh — mặc định Flutter là 24 |
| **targetSdk / compileSdk** | **36** | Lấy từ Flutter default (`flutter.targetSdkVersion`) |
| NDK | `28.2.13676358` | Lấy từ Flutter default. **Chỉ cần** khi build phần JNI whisper.cpp (P1C+) |
| Java / Kotlin toolchain | JDK 17 (`sourceCompatibility`/`jvmTarget`), Kotlin **2.4.0** | |
| Build system | Gradle **9.3.1** (wrapper), AGP **9.1.0** | |
| State management | **chưa có** | Xem [state-routing.md](state-routing.md) |
| Routing | **chưa có** (1 màn hình) | |
| Local storage | **SQLite** (`sqflite`) | Lý do chọn thay vì Hive: xem [patterns.md](patterns.md) |
| Secret storage | `flutter_secure_storage` (keystore OS) | Chỉ dùng từ P2 cho API key LLM |
| ASR | **PhoWhisper** (chính, GGML q5_0) + **Vosk** (dự phòng) | Cả hai **offline**, chạy trong app |
| LLM | **chưa chọn** | P2 mới quyết; đây là phần duy nhất cần `INTERNET` |

## 4. Ràng buộc cứng (KHÔNG được vi phạm ở bất kỳ phase nào)

Đây là các ràng buộc **kiến trúc/sản phẩm**, không phải sở thích kỹ thuật. Vi phạm = làm lại.

1. **Tai nghe Bluetooth chỉ để PHÁT (A2DP một chiều).** Tuyệt đối không dùng
   `AndroidAudioUsage.voiceCommunication` / `voiceCommunicationSignalling` — hai usage này kéo hệ
   thống sang chế độ đàm thoại (HFP/SCO) và hạ chất lượng audio của cả cuộc gọi khác.
2. **Mic thu là mic điện thoại**, không phải mic tai nghe. Không được đổi nguồn thu.
3. **Không được để tiếng TTS lọt ra loa ngoài** trong bất kỳ tình huống nào — kể cả khi tai nghe bị
   rút đột ngột giữa lúc đang phát. Đây là ràng buộc an toàn quan trọng nhất của dự án (P1F).
4. **ASR phải chạy offline, trong app.** Audio hội thoại **không được gửi lên cloud**. Chỉ phần
   văn bản đã bóc băng mới được gửi tới LLM (P2), và phải qua chính sách của Suggestion Engine.
5. **Một chiều tại một thời điểm (half-duplex):** đang phát TTS thì không thu, đang thu thì không phát.
6. Là app cá nhân, **không có auth / tài khoản / payment / backend tự dựng**.

## 5. Trạng thái hiện tại (một câu)

**Đã có:** project Flutter khung + foreground service + cấu hình audio session + SQLite + màn hình
trạng thái; model ASR đã convert sẵn và đã đo baseline **trên host** (chưa trên điện thoại).
**Chưa có:** bất kỳ tính năng sản phẩm nào (thu âm, ASR, TTS, gợi ý). **APK chưa từng được build.**

Chi tiết tiến độ: [openspec.md](openspec.md).

## 6. Quy ước đặt tên & tài liệu

- **Tên OpenSpec change/spec KHÔNG được bắt đầu bằng chữ số.** Nếu tên tự nhiên có số ở đầu
  (`2fa-...`), phải đổi để ký tự đầu là chữ (`two-factor-...`, `add-2fa-...`) và báo user biết.
- Báo cáo phase: `.plan/<PHASE>-result.md` (bị gitignore), ví dụ `.plan/P0_5-result.md`.
- Code review theo `AGENTS.md`; **vùng loại trừ Ponytail** (an toàn/tiền/xác thực/ràng buộc cứng)
  phải dừng lại hỏi user trước khi commit — với dự án này, **audio routing & TTS safety thuộc vùng đó**.
