/// Model dữ liệu của tầng transcript (P1E).
///
/// Quyết định nằm trong model này, KHÔNG được đổi mà không có chủ đích (ràng buộc xuyên phase —
/// `plan_final_v2.md` mục 4.2b và `AGENT_INSTRUCTIONS.md` mục 3):
/// **KHÔNG có trường `speaker`/`speakerLabel`/`[Bạn]`/`[Đối phương]`.** Lý do: nhãn dù ghi "không
/// chắc" vẫn dễ làm LLM tin theo nhãn sai hơn là tự đọc ngữ cảnh — việc suy luận ai đang nói là của
/// Suggestion Engine (P2), không phải của tầng lưu trữ này.
library;

/// Một dòng transcript đã nhận dạng được.
///
/// `text` là text **thô** từ ASR engine (đã `trim()`, không thêm/bớt gì khác).
/// `timestamp` là **thời điểm dòng này được nhận từ engine** — không phải thời điểm bắt đầu của
/// đoạn audio. Với engine gom chunk (PhoWhisper ~4s) thì nó là lúc chunk kết thúc (độ lệch tối đa
/// ~1 độ dài chunk). Đây là điều đã biết và chấp nhận ở P1E: cửa sổ "N phút gần nhất" của P2 dùng
/// mốc này, đủ chính xác cho ngữ cảnh hội thoại.
class TranscriptSegment {
  const TranscriptSegment({required this.text, required this.timestamp});

  /// Text thô, KHÔNG nhãn người nói.
  final String text;

  /// Thời điểm engine trả về dòng này.
  final DateTime timestamp;

  @override
  bool operator ==(Object other) =>
      other is TranscriptSegment &&
      other.text == text &&
      other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(text, timestamp);

  @override
  String toString() => 'TranscriptSegment(${timestamp.toIso8601String()}, "$text")';
}
