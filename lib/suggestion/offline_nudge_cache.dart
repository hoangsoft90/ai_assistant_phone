import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../core/app_logger.dart';
import '../core/constants.dart';
import 'suggestion_models.dart';

/// Một nudge lấy từ kho offline (kèm type để ghi bộ nhớ phiên + hiển thị).
class CachedNudge {
  const CachedNudge({required this.type, required this.text});

  final NudgeType type;
  final String text;

  @override
  String toString() => 'CachedNudge(${type.apiName}: "$text")';
}

/// **Offline Nudge Cache** (P3, mục 4.12): kho nudge chung trong `assets/offline_nudge_cache.json`,
/// dùng khi Suggestion Engine **không gọi được LLM** (timeout / mất mạng / lỗi).
///
/// Nguyên tắc:
/// - Đây CHỈ là fallback: khi gọi được LLM thì kết quả của LLM luôn thắng (constraint P3).
/// - Nudge trong kho là câu **chung chung**, không nêu chủ đề (ta không biết nội dung hội thoại khi
///   LLM không trả về) ⇒ chọn XOAY VÒNG qua các câu/type thay vì "đoán chủ đề".
/// - Bỏ qua câu đã dùng gần đây (tránh lặp với chính các gợi ý vừa hiện).
/// - **Không bao giờ ném**: lỗi đọc/parse ⇒ coi như không có cache (`pickNext` trả `null`) và tầng
///   trên quay về hành vi P2 (`NO_SUGGESTION`) — đúng tinh thần "Silent mode là chốt an toàn".
class OfflineNudgeCache {
  OfflineNudgeCache({Future<String> Function()? loader}) : _loader = loader ?? _loadFromAssets;

  static const AppLogger _log = AppLogger('OfflineNudgeCache');

  static OfflineNudgeCache? _instance;

  /// Bản dùng chung cho app (cùng kiểu `TranscriptStore.instance()`).
  static OfflineNudgeCache instance() => _instance ??= OfflineNudgeCache();

  static Future<String> _loadFromAssets() =>
      rootBundle.loadString(OutputConfig.offlineNudgeCacheAsset);

  final Future<String> Function() _loader;

  /// `type` → danh sách câu, theo đúng thứ tự trong file.
  final Map<NudgeType, List<String>> _byType = <NudgeType, List<String>>{};

  /// Thứ tự type cố định để xoay vòng (ổn định giữa các lần chạy — dễ test, dễ đoán).
  final List<NudgeType> _order = <NudgeType>[];

  Future<void>? _loading;
  bool _loaded = false;
  Object? _lastError;
  int _nextIndex = 0;

  bool get isLoaded => _loaded;

  /// Lỗi của lần nạp gần nhất (`null` nếu nạp được).
  Object? get lastError => _lastError;

  /// Số câu có trong kho cho [type] (0 nếu chưa nạp được / file thiếu type đó).
  int countFor(NudgeType type) => _byType[type]?.length ?? 0;

  /// Toàn bộ câu của một type (test + chẩn đoán).
  List<String> textsFor(NudgeType type) =>
      List<String>.unmodifiable(_byType[type] ?? const <String>[]);

  /// Tổng số nudge đang có (0 khi chưa nạp được).
  int get totalCount =>
      _byType.values.fold(0, (int sum, List<String> texts) => sum + texts.length);

  /// Nạp kho (idempotent). Lỗi KHÔNG được ném ra ngoài — chỉ ghi log + `isLoaded = false`.
  Future<void> ensureLoaded() {
    if (_loaded) {
      return Future<void>.value();
    }
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      // Nạp lại từ đầu: lần nạp hỏng trước đó có thể đã ghi một phần vào `_byType`/`_order`, và
      // nối tiếp vào dữ liệu cũ sẽ làm `_order` có type trùng (xoay vòng sai nhịp).
      _byType.clear();
      _order.clear();
      final String raw = await _loader();
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('offline nudge cache: JSON gốc không phải object');
      }
      final Object? nudges = decoded['nudges'];
      if (nudges is! Map<String, dynamic>) {
        throw const FormatException('offline nudge cache: thiếu object "nudges"');
      }
      // Duyệt theo thứ tự enum (ổn định), KHÔNG theo thứ tự key trong file: nhờ vậy xoay vòng
      // không phụ thuộc việc ai đó sắp xếp lại JSON.
      for (final NudgeType type in NudgeType.values) {
        final Object? rawList = nudges[type.apiName];
        if (rawList is! List) {
          continue;
        }
        final List<String> texts = rawList
            .whereType<String>()
            .map((String text) => text.trim())
            .where((String text) => text.isNotEmpty)
            .toList();
        if (texts.isNotEmpty) {
          _byType[type] = texts;
          _order.add(type);
        }
      }
      _loaded = _byType.isNotEmpty;
      if (!_loaded) {
        throw const FormatException('offline nudge cache: không có câu nào dùng được');
      }
      _log.info('đã nạp $totalCount nudge offline cho ${_order.length} type');
    } catch (error, stackTrace) {
      _lastError = error;
      _loaded = false;
      // Cho phép thử nạp lại lần sau (lỗi asset thoáng qua không được làm cache chết vĩnh viễn —
      // họ lỗi đã gặp ở P1E với `TranscriptStore.init`).
      _loading = null;
      _log.error('không nạp được Offline Nudge Cache — sẽ trả về NO_SUGGESTION', error, stackTrace);
    }
  }

  /// Chọn nudge kế tiếp.
  ///
  /// [avoidTexts] — các câu vừa hiện (chống lặp); so khớp không phân biệt hoa/thường.
  /// Trả `null` khi cache không dùng được hoặc mọi câu đều đã dùng gần đây.
  ///
  /// Bản đầu tôi còn có tham số `preferType` (P5 "có thể" truyền loại mong muốn) — **đã bỏ** vì
  /// không có caller nào trong `lib/` (bài học A8): khi LLM không trả về thì ta **không biết** loại
  /// phù hợp, nên tham số đó chỉ là nhánh code không ai chạy. Thêm lại khi P5 có caller thật.
  Future<CachedNudge?> pickNext({List<String> avoidTexts = const <String>[]}) async {
    await ensureLoaded();
    if (!_loaded) {
      return null;
    }
    final Set<String> avoid = avoidTexts
        .map((String text) => text.trim().toLowerCase())
        .where((String text) => text.isNotEmpty)
        .toSet();

    // Xoay vòng qua các type còn câu chưa dùng (bước 1 type mỗi lần).
    for (int step = 0; step < _order.length; step++) {
      final int index = (_nextIndex + step) % _order.length;
      final NudgeType type = _order[index];
      final String? picked = _pickFrom(type, avoid);
      if (picked != null) {
        _nextIndex = (index + 1) % _order.length;
        return CachedNudge(type: type, text: picked);
      }
    }
    _log.warn('mọi nudge offline đều đã dùng gần đây ⇒ không có gì để fallback');
    return null;
  }

  String? _pickFrom(NudgeType type, Set<String> avoid) {
    final List<String>? texts = _byType[type];
    if (texts == null || texts.isEmpty) {
      return null;
    }
    for (final String text in texts) {
      if (!avoid.contains(text.toLowerCase())) {
        return text;
      }
    }
    return null;
  }
}
