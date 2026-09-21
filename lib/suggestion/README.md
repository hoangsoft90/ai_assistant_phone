# `lib/suggestion/` — suggestion engine (LLM + policy)

Chưa có file Dart nào. Được điền ở **P2**, bổ sung ở **P3** và **P5**.

Dự kiến:
- Gọi LLM (Groq Llama / Gemini Flash) khi người dùng bấm Push; API key đọc từ
  `SecureStore.readLlmApiKey()` (đã có khung ở P0.5).
- Suggestion Policy: giới hạn số lượng/độ dài gợi ý; nội dung phải ngắn để nghe được ngay.
- Phân loại nudge (mục 4.5) + anti-repetition & session memory (4.7).
- Offline Nudge Cache (4.12) cho trường hợp mất mạng.
- Pre-Brief + Post-Review + Training Level (P5) — Training Level **thủ công**, không tự động
  chuyển cấp.

Lưu ý: **Push thủ công không có cooldown**; cooldown chỉ thuộc semi-auto mode (P6).
