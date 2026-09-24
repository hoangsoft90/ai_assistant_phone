# .project/ — Knowledge base của dự án

Cập nhật: 2026-09-24 (+07). Đây là **entry point**: đọc file này trước, rồi theo link đi sâu.

> **Đọc cái này trước nếu bạn là agent mới mở project:** trạng thái hiện tại là
> **app Flutter có đủ khung + pipeline P0.5→P5.4 (code, chưa verify máy trọn vẹn) — KHÔNG có
> auth / cart / payment / API / multi-tenant**: repo này **không có và sẽ không có** những thứ đó.
> Vòng test máy thật gộp đang chờ (**K51**) — danh mục trong `human.md` + `TESTING.md`.

## Điều hướng

| File | Trả lời câu hỏi |
|---|---|
| [overview.md](overview.md) | App này là gì, cho ai, tech stack, các ràng buộc cứng bất di bất dịch |
| [architecture.md](architecture.md) | Cấu trúc thư mục, luồng dữ liệu dự kiến, biên giới giữa các tầng |
| [state-routing.md](state-routing.md) | Đang dùng state management / routing gì (hiện tại: **chưa có**), kế hoạch khi nào chọn |
| [modules/](modules/README.md) | Từng module: cái gì đã có thật, cái gì mới là kế hoạch |
| [integrations.md](integrations.md) | Thư viện & dịch vụ bên thứ ba, quyền hệ thống, CI/CD |
| [design-system.md](design-system.md) | Màu/spacing/typography — hiện là Material 3 mặc định, chưa có token riêng |
| [patterns.md](patterns.md) | Pattern code đang thực sự dùng trong repo (constructor injection cho seam test, quy ước clock trong test, và pattern đã *định* dùng nhưng chưa có) |
| [openspec.md](openspec.md) | Tiến độ theo OpenSpec, việc đang làm, nợ kỹ thuật, bug đã biết |

## Bản đồ file ở gốc repo (ngoài `.project/`)

| File | Vai trò |
|---|---|
| `AGENTS.md` | Hạ tầng chung (retrieval/memory/git/review) + phần PROJECT của repo này |
| `CLAUDE.md` | Điểm vào ngắn cho Claude Code → trỏ sang `AGENTS.md` |
| `context.md` | Tổng quan tương đối tĩnh: mục đích, stack, cấu trúc |
| `working.md` | Nhật ký đang làm, đổi thường xuyên |
| `operating_rules.md` | Rule riêng của project (ràng buộc cứng, điều cấm) |
| `README.md` | Cách build/chạy app + kiểm tra nhanh trên máy thật |
| `checklist.md` | Đã làm / chưa làm / cần làm / cần hỏi lại (theo phase) |
| `features.md` | Tính năng hiện có & toàn bộ tính năng tương lai |
| `next.md` | Roadmap 15 phase + việc sắp tới + rủi ro |
| `faq.md` | Thắc mắc/hiểu sai đã gặp, kèm câu trả lời |
| `result_*.txt` / `handoff_*.md` | Kết quả + bàn giao từng buổi (mới nhất: `*20260924-2*` — fix SnackBar) |
| `LESSONS_LEARNED.md` | Lỗi thật đã mắc + quy tắc chống tái phạm |
| `.plan/` | **Bị gitignore** — prompt từng phase + `P0-result.md`, `P0_5-result.md`, `plan_final_v2.md` |
| `spikes/p0_audio/` | Code thăm dò P0 (Flutter+Kotlin+JNI). Model ~133MB đã gitignore |

## Quy ước đọc nhanh

- Muốn biết **đang ở phase nào / việc kế tiếp**: `next.md` + `.project/openspec.md`.
- Muốn biết **được phép và không được phép làm gì**: [overview.md](overview.md) mục "Ràng buộc cứng" + `operating_rules.md`.
- Muốn sửa code: đọc [architecture.md](architecture.md) mục quy ước đặt file trước, tránh đặt sai tầng.
- Tài liệu `.plan/` **không vào git** — nếu cần trích dẫn cho người khác, chép sang `.project/`.
