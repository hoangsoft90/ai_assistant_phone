# faq.md — Thắc mắc & hiểu sai thường gặp

Cập nhật: 2026-09-23 chiều. Mỗi mục nêu câu trả lời + căn cứ (file/mục trong plan, hoặc số liệu đo được).

**Q: P0 đã xong chưa?**
Chưa. P0 **chưa hoàn thành**: 0/5 mục Definition of Done đạt, vì toàn bộ DoD là đo đạc trên điện thoại thật mà hiện chưa có thiết bị. Đã xong phần chuẩn bị không cần thiết bị. Căn cứ: `.plan/P0-result.md`.

**Q: Code trong `spikes/p0_audio/` có phải code của app thật không?**
Không. Đây là **code thăm dò (throwaway)** của P0, sẽ không mang sang P0.5 (prompt P0 nói rõ). Chỉ có `tools/` (convert model, đo WER) và kinh nghiệm JNI/audio là tái sử dụng được cho P1C/P1D.

**Q: Tại sao nhất định không dùng cloud ASR cho chiều thu, dù khó tích hợp?**
Vì đây là **ràng buộc kiến trúc cứng**, không phải tối ưu chi phí: chiều thu phải chạy 100% on-device, không quota ẩn, không phụ thuộc 4G (`plan_final_v2.md` mục 4.2d; nhắc lại ở P1C/P1D). ~~Cloud ASR chỉ được dùng ở Post-Review (P5)~~ **Đã sửa 2026-09-23:** bước cloud ASR của Post-Review **bị loại** vì mâu thuẫn ràng buộc #4 (audio hội thoại không rời máy; app cố ý không ghi audio) — Post-Review chỉ gửi **text local** lên LLM (user chốt).

**Q: Vậy nếu máy không đủ mạnh chạy PhoWhisper thì sao?**
Chuyển sang Vosk (P1D) — vẫn offline. Nếu cả hai không đủ dùng thì **dừng và báo cáo**, không được tự ý thêm phương án cloud.

**Q: Tại sao mic phải là mic điện thoại chứ không dùng mic tai nghe Bluetooth?**
Dùng mic tai nghe sẽ buộc Android bật kênh SCO/HFP (đàm thoại 2 chiều) và hạ chất lượng audio xuống 8–16kHz → ASR tệ đi, và có thể kéo theo đổi route khi TTS đang phát. Thiết kế chốt: **mic điện thoại thu, tai nghe chỉ phát (A2DP một chiều)** (`plan_final_v2.md` mục 4.2a).

**Q: Tại sao transcript không gắn nhãn `[Bạn]/[Đối phương]`?**
Quyết định có chủ ý (mục 4.2b): để LLM tự suy luận ai đang nói từ ngữ nghĩa. Vì vậy ở các phase sau **không được** thêm trường `speaker`/`label` vào model dữ liệu transcript.

**Q: Số WER trong plan (Vosk ~12%, PhoWhisper ~4.6%) có dùng để kết luận được không?**
Không nên dùng trực tiếp. Đo thật của tôi trên FLEURS `vi_vn` (10 clip có ground-truth, host 4 CPU, chưa phải điện thoại): PhoWhisper-base q5_0 **12.4%**, tiny q5_0 **15.5%**, Vosk small **52.2%** (41.1% sau khi chuẩn hoá âm lượng), Vosk lớn **53.0%**. Con số 4.6% của PhoWhisper là trên VIVOS (đọc sách, sạch) — khác domain nên không cùng thang đo. Kết luận go/no-go vẫn phải dựa trên đo on-device với giọng người dùng.

**Q: Vosk "yếu" vậy có phải do lỗi code đo không?**
Không. Đã kiểm chứng: 2 clip Vosk trả về rỗng có mức thu rất thấp (peak 546 và 830/32767 so với 3.334–8.601 của các clip khác); sau khi khuếch đại x20–x30 thì Vosk đọc được. Tức là model thật sự kém bền với audio nhỏ — đúng kịch bản mic để xa. Đã kiểm cả bản Vosk lớn để chắc không phải do chọn nhầm bản small.

**Q: Tại sao model ASR không nằm trong APK ở P0, trong khi P1C lại yêu cầu để trong `assets/models/`?**
P0 cố tình đọc model từ thư mục riêng của app + `adb push`, để đổi model không phải build lại, và để 133MB model không lọt vào git/CI. P1C sẽ đóng gói model vào assets theo prompt vì lúc đó cần APK tự chứa.

**Q: Thấy `TtsTest` gọi `TextToSpeech` trực tiếp — có vi phạm quy tắc an toàn TTS không?**
Ở P0 là **chủ ý**: Task 3 cần đo hành vi thô của Android (rút tai nghe giữa lúc phát). Quy tắc "mọi phát âm thanh phải qua `SafeTtsOutput`" áp dụng **từ P1F trở đi**; không được copy cách gọi này sang phase sau.

**Q: Cooldown áp cho cả Push thủ công à?**
Không. Push thủ công **không** có cooldown; cooldown chỉ có ở semi-auto mode (P6). Đây là điểm dễ bị vi phạm khi refactor ở phase sau.

**Q: Training Level có tự động chuyển khi người dùng tiến bộ không?**
Không (từ P5): hoàn toàn thủ công, không thêm logic tự đề xuất/chuyển cấp.

**Q: Báo cáo Post-Review có được lưu lại không (K50)?**
Từ P5.1: **có** — mỗi báo cáo dùng được được lưu vào bảng `post_review_reports` và xem lại từ màn
**Lịch sử phiên**. K50 thu hẹp còn "chưa verify xem-lại trên máy thật". Báo cáo bị xoá cùng phiên khi
retention dọn (cùng transaction).

**Q: Tại sao bấm nút nổi "Bật lắng nghe" lại thấy ở cả tab Lịch sử/Thống kê/Cài đặt — có phải nút trùng không?**
Không trùng. Từ P5.3, cụm nút điều khiển phiên là **nút nổi toàn cục** (`GlobalFloatingControls`) đè
lên mọi tab — mỗi hành động chỉ có ĐÚNG 1 điểm bấm (test khoá). Tab không còn nút phiên riêng.

**Q: Tên phiên do ai đặt? Có bắt buộc đặt lúc "Kết thúc buổi" không?**
Không bắt buộc (P5.2): tên để NULL lúc kết thúc, hiển thị bằng tên mặc định "Buổi dd/MM/yyyy HH:mm"
sinh từ `started_at`. Đổi tên bất cứ lúc nào từ Lịch sử (nút bút chì); nhập rỗng ⇒ quay về tên mặc định,
không báo lỗi.

**Q: Đổi endpoint LLM (OpenRouter/self-host) có làm mất key Groq không?**
Key **không đổi theo endpoint** (P2.1): app giữ đúng 1 key trong SecureStore. Quay lại Groq bằng nút
"Khôi phục mặc định Groq"; nếu key trước đó là của OpenRouter thì phải nhập lại key Groq.

**Q: Xoá dữ liệu cũ theo retention có xoá luôn báo cáo Post-Review không?**
Có (P5.1): `deleteOlderThan` xoá transcript + báo cáo trong **cùng một transaction** — báo cáo không
sống lâu hơn transcript (tránh "báo cáo về một buổi không còn dữ liệu").

**Q: Migration DB có làm mất dữ liệu transcript cũ không?**
Không (đã chứng minh): v1→v4 và v3-có-dữ-liệu→v4 chạy trên SQLite thật — 0 dòng mất, `title` phiên cũ
NULL (tên mặc định sinh lúc hiển thị). Nhánh migration cũ `< 2` giữ nguyên từng chữ, có test khoá.

**Q: Chưa commit gì à? Có phải agent bỏ qua bước commit không?**
Repo hiện **0 commit** và mọi thứ còn untracked. Tôi chủ động **không** commit vì cần bạn xác nhận trước (phần TTS thô thuộc vùng an toàn, và bài học từ plan yêu cầu không tự ký duyệt).

**Q: Sao `.plan/` không nằm trong git?**
`.gitignore` của repo ignore `.plan`, nên `prompt_*.md`, `plan_final_v2.md` và cả báo cáo `.plan/P0-result.md` **không** được commit. Nếu muốn báo cáo vào git thì phải copy sang thư mục khác (chưa làm, đang chờ bạn quyết).

**Q: Tại sao không cài Android SDK trên máy này?**
Theo bạn chốt: build sẽ làm trên GitHub Actions. Hệ quả cần nhớ: **APK chưa từng được build**, và phần Kotlin chưa từng được biên dịch ở bất kỳ đâu.

**Q: Có cần tạo OpenSpec change cho P0 không?**
Không. `openspec update` đã chạy (tool v1.13.1, không drift) và `openspec list` → không có change nào. P0 là spike, không phải thay đổi schema/API/kiến trúc; theo quy ước, change nên được tạo khi bắt đầu P0.5 (app thật). Lưu ý quy ước tên: **không bắt đầu bằng chữ số**, nên "P0.5" phải đặt kiểu `add-project-bootstrap`.
