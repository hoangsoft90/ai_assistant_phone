# RELEASE_NOTES.md — Trợ lý giao tiếp (ai_assistant_phone)

> Cập nhật: 2026-09-23 (sau P7 — Production Hardening, phần tĩnh).
> File này tổng kết **trạng thái thực tế** của app trước khi dùng hàng ngày: cái gì đã đạt,
> cái gì **chưa từng chạy** (phải test trên máy thật trước khi tin), và cách build/cài.

## 1. App là gì

Trợ lý nghe hội thoại **offline** (mic điện thoại → VAD → ASR PhoWhisper/Vosk), gợi ý câu trả lời
qua **LLM (Groq)** và đọc gợi ý **chỉ vào tai nghe Bluetooth** — người xung quanh không nghe thấy.
Kèm Emergency Phrase (câu thoát hiểm phát bằng localStorage khi giữ nút nổi 2 giây), Pre-Brief,
Post-Review và 5 cấp độ huấn luyện chỉnh tay.

**Không có**: auth, backend, payment, cloud ASR, ghi âm lưu đĩa. Audio hội thoại **không bao giờ**
rời thiết bị — chỉ text đã bóc băng được gửi tới LLM.

## 2. Trạng thái các phase

| Phase | Nội dung | Trạng thái |
|---|---|---|
| P0 → P1G | Khung app, capture, VAD, ASR 2 engine, transcript SQLite, TTS an toàn, Emergency | Code xong, **302+ test unit xanh** |
| P2 | Suggestion Engine (Groq + Policy) | Code xong; **chưa từng gọi LLM thật** (K39) |
| P3 | Trigger + Output Mode + Offline Nudge Cache | Code xong; chưa test máy (K41/K42) |
| P4 | Pipeline integration + half-duplex | Code xong; **0/6 DoD tick** — chưa có phiên thật (K46) |
| P5 | Pre-Brief + Post-Review + Training Level | Code xong; **0/5 DoD tick** (K48) |
| P6 | Semi-auto (bỏ qua theo lựa chọn) | Chưa làm — **không bắt buộc** |
| P7 | Hardening + release build | **Phần tĩnh xong** (báo cáo này); phần máy thật còn nợ (K51) |

## 3. P7 — phần tĩnh đã làm (bằng chứng trong `.plan/P7-result.md`)

1. **Bảo mật**: 0 API key hard-code (grep toàn repo) · key đọc từ `flutter_secure_storage`
   (Android Keystore) mỗi lần gọi · không lưu audio ra đĩa (`WavSink` chỉ là tiện ích test,
   không caller trong lib) · transcript tự xoá sau 7 ngày ở `TranscriptStore.init()` ·
   8 permission Manifest đều có người dùng thật (đã đối chiếu từng cái) ·
   `.speak(` chỉ 3 nơi, tất cả qua `SafeTtsOutput`.
2. **Xử lý lỗi vòng 3**: rà toàn bộ file chưa từng soi (`MainActivity.kt`, `main.dart`,
   `foreground_service.dart`, `permission_gate.dart`, `app_logger.dart`, DAO/DB) —
   bootstrap đã bọc try/catch từng mảnh, mọi service trả `false`/`unavailable` thay vì ném,
   service có `stopWithTask: false` + `allowWakeLock`.
3. **Dialog đạo đức** (mục 5.3): hiện **một lần duy nhất** khi mở app lần đầu — flag trong bảng
   `meta`, chỉ ghi sau khi dialog đóng; DB lỗi không cấm dùng app. 6 test unit khoá hợp đồng.
4. **R8/ProGuard**: `isMinifyEnabled + isShrinkResources` cho release; keep rules chỉ 3 nhóm
   (JNA, `org.vosk.**` — đã xác minh package thật từ import, `AsrNative` JNI) — mỗi rule có lý do.
5. **Workflow CI `build-release-apk.yml`**: `assembleRelease` + báo cáo size/ABI + upload
   `mapping.txt` (cần khi decode stack trace bản minify). RetryGradle-download như workflow debug.

## 4. Chưa xong — bắt buộc trước khi tin app "production-ready" (K51)

Toàn bộ phần sau **chỉ làm được trên máy thật** (máy dev không có Android SDK; `adb devices` rỗng):

- Cài APK → smoke test đủ luồng: Pre-Brief → Bật lắng nghe → Push → nhận nudge → Kết thúc → Post-Review.
- 3 test case an toàn P1F lần cuối **trên bản release** (R8 có thể đổi hành vi reflection/JNI —
  đây là lý do phải cài bản minify, không phải bản debug, để test).
- Pin 1-2 giờ dùng thật · Doze/Battery Optimization (loại trừ app trong Settings nếu bị giết) ·
  kịch bản lỗi thật (rút BT, tắt mic permission, mất mạng khi gọi LLM).
- Checklist nghiệm thu mục 6 của prompt (4 nguyên tắc bất biến, không TTS ra loa ngoài, không crash).
- **Signing**: tạo keystore ngoài git (`keytool` đã có sẵn trên máy dev), thêm GitHub Secrets,
  bật `signingConfig` thật — hiện APK release vẫn **debug-signed** theo chốt với user, chỉ dùng
  để test/đo size, **không phát hành**.

## 5. Build & cài

```bash
# Debug (đã dùng từ P1C): push lên main → CI build-debug-apk.yml → artifact app-debug-apk
# Release (P7): push lên main → CI build-release-apk.yml → artifact app-release-apk-unsigned-test
```

Cài trên máy: tải artifact, `adb install -r app-*.apk` (hoặc mở file APK trực tiếp trên máy).

Model Vosk (32MB) + PhoWhisper được đóng/tải theo workflow — không commit vào git.
