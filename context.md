# context.md — Tổng quan dự án (tương đối tĩnh)

Cập nhật: 2026-09-21 (+07). Chỉ sửa file này khi có thay đổi **lớn về bản chất dự án**.
Việc đang làm hằng ngày → `working.md`. Chi tiết kiến trúc → `.project/`.

## 1. Dự án là gì

**`ai_assistant_phone` — "Trợ lý giao tiếp"**: app Android **cá nhân, một người dùng** giúp người dùng
trong cuộc hội thoại trực tiếp:

1. nghe hội thoại bằng **mic điện thoại**,
2. bóc băng **offline, trong app** (PhoWhisper, dự phòng Vosk),
3. gợi ý câu trả lời / từ khoá (LLM, có thể cloud — **chỉ gửi text**),
4. **đọc gợi ý qua tai nghe Bluetooth** — chỉ người dùng nghe thấy.

Bối cảnh dùng: đeo tai nghe, điện thoại trong túi/trên bàn, app chạy nền hàng chục phút.

## 2. Tech stack

- **Flutter 3.47.2** (stable), Dart `^3.13.2`, **Android only**.
- `applicationId` / namespace **`com.aiassistant.phone`**; app name hiển thị "Trợ lý giao tiếp".
- **minSdk 26**, target/compileSdk **36**, NDK **28.2.13676358**.
- **Kotlin 2.4.0**, **AGP 9.1.0**, **Gradle 9.3.1**, JDK 17.
- Dependency runtime (6, cố ý tối thiểu): `flutter_foreground_task` 11.0.3, `audio_session` 0.2.4,
  `sqflite` 2.4.4, `path` 1.9.1, `flutter_secure_storage` 11.2.0, `permission_handler` 13.0.2.
- **Chưa có** state management library, routing library, DI container — và **sẽ không có**
  auth / account / backend / payment / push notification.

## 3. Cấu trúc chính

```
lib/
├── main.dart          # bootstrap: init service → audio session → DB → transcript store → runApp
├── core/              # constants.dart + app_logger.dart
├── audio/             # app_audio_session.dart (P1A thu), capture/ (P1A), vad/ (P1B), asr/ (P1C+P1D),
│                      #   và P1F SafeTtsOutput (chưa có)
├── transcript/        # transcript_segment.dart + transcript_store.dart — P1E
├── suggestion/        # (chưa có) Suggestion Engine + Policy — P2
├── trigger/           # (chưa có) cách kích hoạt gợi ý — P3
├── ui/                # home_screen.dart (màn hình chẩn đoán)
└── services/          # foreground_service, permission_gate, storage/ (DB v2: meta + transcript)
android/               # Manifest 7 quyền + service type=microphone + JNI/C++ ASR
test/                  # 6 file test Dart (95 test, không cần thiết bị)
spikes/p0_audio/       # code thăm dò P0 — KHÔNG phải code sản phẩm
.project/              # knowledge base (entry: .project/README.md)
.plan/                 # prompt từng phase + báo cáo phase — BỊ GITIGNORE
```

Chi tiết tầng + quy ước đặt file: `.project/architecture.md`.

## 4. Quyết định kiến trúc quan trọng (đã chốt)

> **Lưu ý về ADR:** hiện các quyết định này được ghi trong `.project/` + `.plan/*-result.md` **chứ
> chưa** được lưu thành ADR chính thức (tool `manage_adr` không khả dụng trong các phiên đã chạy).
> Khi nào lưu được ADR thì đây là danh sách ứng viên đầu tiên.

| # | Quyết định | Lý do | Ghi ở đâu |
|---|---|---|---|
| D1 | **Layered theo domain**, không feature-first | Chỉ có 1 luồng nghiệp vụ liên tục; ràng buộc an toàn nằm đúng một chỗ | `.project/architecture.md` mục 0 |
| D2 | **Tai nghe chỉ phát A2DP** — không `voiceCommunication` | Tránh bị ép sang HFP/SCO, giữ chất lượng audio | `.project/modules/audio-session.md` |
| D3 | **ASR offline, audio không rời máy** | Quyền riêng tư nội dung hội thoại; chỉ text được gửi cho LLM | `.project/overview.md` mục 4 |
| D4 | **SQLite (`sqflite`)** thay vì Hive | Cần truy vấn theo khung thời gian + dump theo phiên (P1E/P5) | `.project/modules/storage.md` mục 4 |
| D5 | **Foreground service type=`microphone`** qua `flutter_foreground_task` | Nghe liên tục khi màn hình tắt; plugin này dùng tên service cố định | `.project/modules/foreground-service.md` |
| D6 | **`stopWithTask: false`** | Người dùng chỉ dừng khi bấm nút, không phải khi vuốt app khỏi recent | `.project/modules/foreground-service.md` |
| D7 | **`PermissionGate` (thêm `permission_handler`)** | Android 14+ không cho start FGS `microphone` thiếu `RECORD_AUDIO` | `.project/modules/foreground-service.md` |
| D8 | **Chưa dùng state management/routing** — mốc chốt là P1B / P5 | Tránh thêm dependency khi chưa cần | `.project/state-routing.md` |
| D9 | **Bọc plugin trong `abstract final class` + `static`** | Không cần DI ở phase khung; dễ đổi sau | `.project/patterns.md` mục 1 |
| D10 | **Không tạo OpenSpec change cho P0/P0.5** | P0 là spike, P0.5 là bootstrap khung — chưa đổi schema/API thật | `.project/openspec.md` mục 1 |

## 5. Ràng buộc cứng

Xem `.project/overview.md` mục 4 (6 ràng buộc) và mục Critical Rules trong `AGENTS.md` (12 rule đã
chi tiết hoá). **Không lặp lại ở đây** để tránh 3 bản sao lệch nhau.

## 6. Trạng thái hiện tại (cập nhật khi bản chất dự án đổi)

- Đang ở: **sau P0.5 bootstrap**. P0 (spike đo trên máy thật) **dở dang, chặn ở thiết bị**.
- **Chưa có tính năng sản phẩm nào. APK chưa từng được build. Repo 0 commit.**
- Nợ kỹ thuật K1–K10: `.project/openspec.md` mục 3.
- Phase kế tiếp: xem `.project/openspec.md` mục 4 + `next.md`.

## 7. Môi trường

- Máy dev Linux này: **chỉ có `adb`**, **không có** Android SDK platforms/build-tools/NDK ⇒ **không
  build APK tại chỗ**; kế hoạch build qua **GitHub Actions** (repo chưa có).
- `/home` gần đầy (~396MB trống) ⇒ thao tác nặng dùng `/tmp`.
- Model ASR (~133MB) nằm ở `spikes/p0_audio/models/` — **đã gitignore**, không commit (`/tmp` có bản
  backup tạm).
