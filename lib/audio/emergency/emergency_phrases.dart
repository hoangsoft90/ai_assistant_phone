/// Danh sách câu thoát khẩn cấp (P1G) — **file cấu hình riêng** theo yêu cầu bàn giao của
/// prompt P1G: "Danh sách câu thoát trong file cấu hình riêng, dễ chỉnh sửa sau".
///
/// Nguyên tắc (plan_final_v2.md mục 4.11): Emergency Phrase chạy 100% local, KHÔNG qua LLM —
/// vì vậy danh sách này là **cố định trong code**, không có API/cloud nào đọc được nó.
///
/// Prompt cho phép 3–5 câu; 2 slot còn lại có thể để trống cho người dùng tự tuỳ chỉnh sau
/// (không bắt buộc ở phase này). `EmergencyPhraseService` tự bỏ qua phần tử rỗng nếu sau này
/// thêm vào.
library;

/// Các câu thoát cố định. Chỉnh sửa tại đây — không cần đụng logic.
const List<String> emergencyPhrases = <String>[
  'Mình đi lấy nước một chút.',
  'Xin phép mình ra ngoài một lát.',
  'Chờ mình chút, mình nghe điện thoại.',
];
