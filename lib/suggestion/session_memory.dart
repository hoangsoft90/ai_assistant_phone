import '../core/constants.dart';
import 'suggestion_models.dart';

/// Bộ nhớ phiên (P2 task 7) — giữ trong RAM, chưa cần persist phức tạp.
///
/// Đủ để Anti-repetition hoạt động: `recentSuggestions` (kèm mốc giờ để lọc theo cửa sổ 2 phút),
/// `topicsExplored` (chủ đề đã gợi ý — P2 dùng chính text nudge làm "chủ đề"), `lastNudgeType`.
class SessionMemory {
  // `this._limit` không hợp lệ với named parameter (Dart cấm param bắt đầu bằng `_`) —
  // đúng mẫu A23 trong LESSONS_LEARNED.md.
  // ignore: prefer_initializing_formals
  SessionMemory({int limit = 20}) : _limit = limit;

  /// Trần số nudge giữ lại (chống phình RAM khi phiên dài — đủ cho anti-repetition).
  final int _limit;

  // Mới nhất ở cuối — lấy từ đuôi khi đọc.
  final List<SuggestionRecord> _records = <SuggestionRecord>[];

  NudgeType? _lastNudgeType;

  /// Mọi nudge đã hiển thị trong phiên (mới nhất ở cuối).
  List<SuggestionRecord> get recentSuggestions =>
      List<SuggestionRecord>.unmodifiable(_records);

  NudgeType? get lastNudgeType => _lastNudgeType;

  /// Nudge trong cửa sổ [window] gần nhất (dùng cho anti-repetition + mục "Last suggestions").
  List<SuggestionRecord> recentWithin(Duration window, DateTime now) {
    final DateTime cutoff = now.subtract(window);
    return _records.where((SuggestionRecord r) => r.at.isAfter(cutoff)).toList();
  }

  /// Nudge gần nhất trong cửa sổ mặc định của anti-repetition (2 phút).
  List<SuggestionRecord> recentForRepetition(DateTime now) =>
      recentWithin(SuggestionConfig.antiRepetitionWindow, now);

  /// Ghi nhận 1 nudge đã hiển thị. `NO_SUGGESTION` không ghi (không có gì để lặp lại).
  void record(SuggestionResult result, {required DateTime at}) {
    if (!result.isNudge) {
      return;
    }
    _records.add(SuggestionRecord(
      type: result.type!,
      text: result.text!,
      at: at,
    ));
    _lastNudgeType = result.type;
    if (_records.length > _limit) {
      _records.removeRange(0, _records.length - _limit);
    }
  }

  /// Đầu vào cho dòng "Last suggestions" của prompt khung: dạng "TYPE: text", mới nhất ở cuối.
  List<String> lastSuggestionLines({int max = 5}) {
    final int from = _records.length > max ? _records.length - max : 0;
    return _records
        .sublist(from)
        .map((SuggestionRecord r) => '${r.type.apiName}: ${r.text}')
        .toList();
  }

  /// Đầu vào cho dòng "Topics explored" (P2: text nudge đã dùng).
  List<String> topicsExplored() =>
      _records.map((SuggestionRecord r) => r.text).toList();

  void clear() {
    _records.clear();
    _lastNudgeType = null;
  }
}

/// Một nudge đã hiển thị (để lọc anti-repetition theo thời gian).
class SuggestionRecord {
  const SuggestionRecord({
    required this.type,
    required this.text,
    required this.at,
  });

  final NudgeType type;
  final String text;
  final DateTime at;
}
