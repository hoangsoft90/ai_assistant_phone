# openspec.md — Tiến độ, bug, todo (góc nhìn OpenSpec)

Cập nhật: 2026-09-21 15:30 (+07).

## 1. Trạng thái OpenSpec

| Hạng mục | Giá trị |
|---|---|
| CLI | `openspec` **1.13.1** |
| Tool đã cài (adapter) | `antigravity`, `claude`, `opencode` — tất cả up to date, **không drift** |
| Profile | 6 workflow đang bật |
| **Changes đang mở** | **KHÔNG CÓ** (`openspec list` → *No active changes*) |
| **Specs đã chốt** | **KHÔNG CÓ** (`openspec/specs/` chỉ có `.gitkeep`) |
| `openspec/config.yaml` | ✅ đã điền `context` (tech stack + 5 ràng buộc cứng + quy ước tên) và `rules` cho `proposal`/`tasks`; đã parse lại bằng `yaml.safe_load` → hợp lệ |

**Vì sao chưa có change nào:** P0 là spike thăm dò (không thay đổi schema/API), P0.5 là bootstrap khung.
Theo quy ước, change đầu tiên nên được tạo **trước khi code** ở phase thay đổi kiến trúc thật —
dự kiến là P1A/P1B.

**Việc cần làm khi tạo change đầu tiên:**
1. Chạy `openspec` theo workflow đang có (không tự chế quy trình).
2. **Tên change không được bắt đầu bằng chữ số** (xem `AGENTS.md` + `openspec/config.yaml`).
3. Đọc `rules` trong `openspec/config.yaml` trước khi viết `proposal.md`/`tasks.md`.

## 2. Phase: đã xong / đang làm / pending

> Nguồn đầy đủ: `next.md`. Ở đây chỉ ghi trạng thái OpenSpec-hoá.

| Phase | Nội dung | Trạng thái |
|---|---|---|
| **P0** | Audio Feasibility Spike (đo trên máy thật) | 🟡 **dở dang, chặn ở thiết bị** — xong phần không cần thiết bị; **0/5 mục DoD đạt** |
| **P0.5** | Project Bootstrap | 🟡 **xong phần làm được; 2/5 mục DoD đạt**, 3 mục còn lại chưa xác minh (cần build + máy thật) |
| **P1A** | Audio Capture Foundation (mic-only) | 🟡 code xong (5 file Dart + 2 file Kotlin, 21 test pass) — **0/5 mục DoD** vì chưa build/đo trên máy |
| **P1B** | VAD + State tối giản | 🟡 code xong (3 file Dart + 1 file Kotlin, 38 test pass) — **0/4 mục DoD** vì chưa build/đo trên máy |
| P1C | ASR PhoWhisper (chính) | ⬜ — model GGML đã convert sẵn |
| P1D | ASR Vosk (dự phòng) + abstraction | ⬜ — model đã tải sẵn |
| P1E | Transcript Store | ⬜ — khung SQLite đã có |
| P1F | TTS Output Safety Layer (A2DP-only) | ⬜ — **phase an toàn quan trọng nhất** |
| P1G | Emergency Phrase (local) | ⬜ |
| P2 | Suggestion Engine (LLM + Policy) | ⬜ |
| P3 | Trigger Abstraction + Output Modes + Offline Nudge Cache | ⬜ |
| P4 | Full Pipeline Integration (half-duplex) | ⬜ |
| P5 | Pre-Brief + Post-Review + Coaching + Training Level | ⬜ |
| P6 | Semi-auto Mode (tuỳ chọn) | ⬜ — cần dùng thực địa ≥2 tuần |
| P7 | Production Hardening & Release | ⬜ |

Ước tính còn lại tới lúc dùng được (bỏ P6): **~9–11 tuần** (theo `production_roadmap.md`).

## 3. Bug đã biết

**Chưa có bug nào được filed** — app **chưa từng chạy trên thiết bị**, nên chưa có bug runtime nào
được phát hiện. Danh sách dưới đây là **vấn đề/nợ kỹ thuật đã biết** (khác với bug đã quan sát):

| # | Vấn đề | Mức | Nguồn |
|---|---|---|---|
| K1 | **Ràng buộc "không lọt tiếng ra loa ngoài" CHƯA được kiểm chứng** trên Android thật (Task 3 của P0 chưa chạy) | 🔴 cao (an toàn) | `.plan/P0-result.md` |
| K2 | **Chưa biết TTS qua tai nghe giữ A2DP hay bị ép HFP** (Task 2 của P0 chưa chạy) ⇒ cấu hình `audio_session` hiện chỉ là mức khung, có thể phải sửa | 🔴 cao | `lib/audio/app_audio_session.dart`, `.plan/P0-result.md` |
| K3 | **Chưa chốt ASR mặc định** (PhoWhisper hay Vosk) — nợ kỹ thuật treo từ P0 | 🟠 vừa | `next.md`, `.plan/P0-result.md` |
| K4 | **APK chưa từng được build** ⇒ Gradle/AGP 9.1/Kotlin 2.4.0/plugin chưa biên dịch lần nào | 🟠 vừa | `.plan/P0_5-result.md` |
| K5 | **Vosk trả về RỖNG với audio nhỏ tiếng** — cần AGC/kiểm soát gain ở P1A nếu chọn Vosk | 🟠 vừa | `spikes/p0_audio/reports/*.json` |
| K6 | **Code spike còn sót `TtsTest` phát trực tiếp** — không được tái sử dụng; prompt P0.5 nói phải "thay thế hoàn toàn" code thăm dò | 🟠 vừa (an toàn) | `spikes/p0_audio/`, `checklist.md` |
| K7 | **Chưa có state management** ⇒ mốc bắt buộc chốt trước P1B | 🟡 thấp | [state-routing.md](state-routing.md) |
| K8 | **Chưa có CI/CD, chưa có keystore release** | 🟡 thấp | [integrations.md](integrations.md) |
| K9 | **Design system chưa có** + vài giá trị màu/chữ hardcode trong `home_screen.dart` | 🟡 thấp | [design-system.md](design-system.md) |
| K10 | **`/home` chỉ còn ~396MB** — chưa đủ chỗ build Gradle tại máy dev | 🟡 thấp | `.plan/P0_5-result.md` |
| K11 | **Mã Kotlin của P1A chưa từng được biên dịch** — chỉ review thủ công + kiểm ngoặc + đối chiếu API plugin | 🔴 cao | `.plan/P1A-result.md` mục Sai khác 8 |
| ~~K12~~ | ~~`chunkMs=100` chưa đối chiếu ngưỡng VAD~~ → **đã giải quyết ở P1B**: VAD chia khung 20ms ngay ở native, không cần hạ `chunkMs` của luồng PCM | ✅ xong | `.plan/P1B-result.md` mục Sai khác 1 |
| K14 | **Dependency JitPack (`android-vad:webrtc:2.0.10`) + toàn bộ mã Kotlin P1B chưa từng được biên dịch** — chỉ kiểm bằng đọc source + HTTP 200 của artifact | 🔴 cao | `.plan/P1B-result.md` mục Sai khác 6 |
| K15 | **3 ngưỡng VAD (300ms/1500ms/ratio 0.5) chưa tinh chỉnh bằng giọng nói thật** — mới là giá trị khởi đầu có lý giải | 🟠 vừa | `.project/modules/conversation-state.md` mục 4 |
| K16 | **VAD chạy cùng thread thu** với việc copy chunk cho Dart — chưa xác nhận không gây drop mẫu khi CPU bận | 🟡 thấp | `.plan/P1B-result.md` mục Đề xuất |
| K13 | **`permanentlyDenied` chưa có đường thoát** trong app (không `openAppSettings()`); P1A mới hiện hướng dẫn bằng chữ | 🟠 vừa | `.project/modules/audio-capture.md` mục 7 |

## 4. Todo ngay tiếp theo (thứ tự)

1. **Chốt đường build APK**: GitHub Actions (chờ repo) hoặc cài Android SDK/NDK tạm vào `/tmp`.
2. **Build APK + cài lên điện thoại** → xác minh 3 mục DoD còn lại của P0.5 (K4).
3. Chạy 4 bước kiểm tra nhanh ở `README.md` (gốc repo).
4. Chạy protocol P0 Task 1→4 trên máy thật bằng app spike → giải quyết **K1, K2, K3**.
5. Điền số liệu vào DoD, viết kết luận go/no-go.
6. Quyết định số phận `spikes/p0_audio/` (**K6**).
7. Tạo `context.md`/`operating_rules.md` (đã xong ở phiên này) + OpenSpec change đầu tiên cho P1A.

## 5. Việc cần hỏi người dùng (đang treo)

- [ ] Repo GitHub nào + có dựng workflow build APK ngay không?
- [ ] Có commit phần P0 + P0.5 hiện tại không? (repo **0 commit** — xem mục 6)
- [ ] Xoá hay giữ `spikes/p0_audio/`?
- [ ] Cho phép xoá model f16/vosk-bản-lớn trong `/tmp/p0spike` để lấy chỗ build?
- [ ] `.plan/` bị gitignore → có copy báo cáo phase sang thư mục được commit không?
- [ ] Cho phép tạo skill từ `LESSONS_LEARNED.md` không?

## 6. Trạng thái git

- **Repo hiện có 0 commit** (`git log` → *"does not have any commits yet"*). Mọi thứ đang là untracked.
- Hệ quả: `git diff` rỗng, `detect_changes`/impact review không dùng được cho tới khi có commit đầu.
- **Chưa commit gì** — agent không tự commit; đang chờ người dùng xác nhận (DoD Bàn giao của P0.5 yêu
  cầu commit theo từng bước).
