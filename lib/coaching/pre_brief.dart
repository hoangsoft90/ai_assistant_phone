import 'dart:convert';

import '../core/app_logger.dart';
import '../core/constants.dart';
import '../services/storage/meta_store.dart';

/// Phong cách muốn dùng trong buổi (mục 4.1 của plan — option "thân mật / lịch sự / hài hước...").
///
/// Là enum chứ không phải text tự do: giá trị này đi thẳng vào prompt khung ở dòng `{pre_brief}`, mà
/// prompt cần một từ khoá ổn định để LLM đổi giọng nudge. Text tự do ở đây sẽ cho ra hàng chục biến
/// thể vô nghĩa ("hơi hài hước", "vui vẻ", "thoải mái"...) mà không giúp ích gì.
enum ConversationStyle {
  intimate('intimate', 'thân mật'),
  polite('polite', 'lịch sự'),
  humorous('humorous', 'hài hước');

  const ConversationStyle(this.storageValue, this.label);

  /// Giá trị lưu trong bảng `meta` — ổn định, đừng đổi (người dùng đã có nháp trên máy).
  final String storageValue;

  /// Nhãn hiển thị trong UI.
  final String label;

  static ConversationStyle? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    final String normalized = raw.trim().toLowerCase();
    for (final ConversationStyle style in ConversationStyle.values) {
      if (style.storageValue == normalized) {
        return style;
      }
    }
    return null;
  }
}

/// Pre-Brief của một buổi (mục 4.1) — người dùng nhập TRƯỚC khi bắt đầu phiên.
///
/// Đây là dữ liệu **cá nhân** (tên người gặp, chủ đề kiêng kỵ). Vì vậy, khác với transcript (chỉ nằm
/// trong RAM + SQLite của app rồi tự xoá sau 7 ngày), Pre-Brief chỉ được:
/// - giữ trong RAM cho **phiên đang chạy** ([PreBriefStore.current]) — phần đi vào prompt;
/// - lưu thành **bản nháp** trong bảng `meta` để lần sau tự điền lại (người dùng đã chọn như vậy).
/// Không ghi vào log, không gửi đi đâu ngoài việc thay `{pre_brief}` trong prompt gửi LLM (đúng luồng
/// P2: text đã bóc băng được phép lên LLM, và Pre-Brief là text do người dùng tự nhập).
class PreBrief {
  const PreBrief({
    this.whoMet = '',
    this.relation = '',
    this.goal = '',
    this.topics = '',
    this.avoidTopics = '',
    this.style,
  });

  /// Pre-Brief rỗng (buổi không nhập gì — hoàn toàn hợp lệ, mọi tính năng phải chịu được).
  static const PreBrief empty = PreBrief();

  /// Người gặp.
  final String whoMet;

  /// Quan hệ (đồng nghiệp, bạn cũ, người mới...).
  final String relation;

  /// Mục tiêu buổi gặp.
  final String goal;

  /// Chủ đề muốn nói.
  final String topics;

  /// Chủ đề **kiêng kỵ** — dòng này chính là dữ liệu mà DoD-1 của P5 dùng để kiểm: đổi nó đi thì
  /// Suggestion Engine không được gợi ý vào chủ đề đó.
  final String avoidTopics;

  /// Phong cách mong muốn; `null` = người dùng không chọn.
  final ConversationStyle? style;

  /// Không có thông tin nào — UI dùng để hiện "chưa nhập Pre-Brief".
  bool get isEmpty =>
      whoMet.trim().isEmpty &&
      relation.trim().isEmpty &&
      goal.trim().isEmpty &&
      topics.trim().isEmpty &&
      avoidTopics.trim().isEmpty &&
      style == null;

  /// Giá trị thay cho `{pre_brief}` trong prompt khung.
  ///
  /// Giữ **một dòng** (phân tách bằng ` · `) để không phá cấu trúc các dòng `- ...` của prompt khung.
  /// Rỗng ⇒ `''` và `SuggestionContextBuilder` tự in `(chưa có)` — đúng hành vi cũ của P2 khi
  /// Pre-Brief chưa tồn tại, nên test khoá prompt khung vẫn còn hiệu lực.
  String toPromptValue() {
    final List<String> parts = <String>[];
    void add(String label, String value) {
      final String trimmed = value.trim();
      if (trimmed.isNotEmpty) {
        parts.add('$label: $trimmed');
      }
    }

    add('Người gặp', whoMet);
    add('Quan hệ', relation);
    add('Mục tiêu', goal);
    add('Chủ đề muốn nói', topics);
    // Kiêng kỵ đứng CUỐI và ghi rõ "TRÁNH" để LLM không nhầm đây là chủ đề nên khai thác — đây là
    // trường dễ bị hiểu ngược nhất trong cả prompt.
    final String avoid = avoidTopics.trim();
    if (avoid.isNotEmpty) {
      parts.add('TRÁNH (chủ đề kiêng kỵ): $avoid');
    }
    final ConversationStyle? selectedStyle = style;
    if (selectedStyle != null) {
      parts.add('Phong cách: ${selectedStyle.label}');
    }
    return parts.join(' · ');
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'whoMet': whoMet,
        'relation': relation,
        'goal': goal,
        'topics': topics,
        'avoidTopics': avoidTopics,
        'style': style?.storageValue,
      };

  /// Đọc lại bản nháp đã lưu. KHÔNG dùng `as` để ép kiểu (bài học A50): nháp hỏng/sửa tay trong DB
  /// phải cho ra Pre-Brief rỗng chứ không được ném `TypeError` từ lúc mở app.
  static PreBrief fromJson(Object? decoded) {
    if (decoded is! Map<String, dynamic>) {
      return empty;
    }
    String text(Object? value) => value is String ? value : '';
    final Object? rawStyle = decoded['style'];
    return PreBrief(
      whoMet: text(decoded['whoMet']),
      relation: text(decoded['relation']),
      goal: text(decoded['goal']),
      topics: text(decoded['topics']),
      avoidTopics: text(decoded['avoidTopics']),
      style: ConversationStyle.tryParse(rawStyle is String ? rawStyle : null),
    );
  }

  @override
  String toString() => 'PreBrief(${toPromptValue()})';
}

/// Giữ Pre-Brief **của phiên đang chạy** (RAM) + bản nháp đã lưu (bảng `meta`).
///
/// Tách khỏi `SuggestionService` để: (a) UI nhập Pre-Brief chỉ cần đối tượng này, (b) test bơm một
/// `ConfigStore` giả là kiểm được cả đường đọc/ghi mà không cần SQLite (cùng cách `AsrEngineSelector`/
/// `OutputModeSelector` đã làm ở P1D/P3).
class PreBriefStore {
  PreBriefStore({ConfigStore? store}) : _store = store ?? const MetaConfigStore();

  /// Bản dùng chung cho app (cùng kiểu `TranscriptStore.instance()`/`SafeTtsOutput.instance()`):
  /// màn hình nhập Pre-Brief, phiên và Suggestion Service phải nói về CÙNG một đối tượng — hai instance
  /// sẽ cho ra cảnh "UI lưu xong mà prompt vẫn rỗng".
  static PreBriefStore? _shared;

  static PreBriefStore instance() => _shared ??= PreBriefStore();

  static const AppLogger _log = AppLogger('PreBrief');

  final ConfigStore _store;

  PreBrief _current = PreBrief.empty;

  /// Pre-Brief của phiên đang chạy (rỗng nếu chưa nhập).
  PreBrief get current => _current;

  bool get hasCurrent => !_current.isEmpty;

  /// Đặt Pre-Brief cho phiên hiện tại (gọi khi người dùng bấm "Lưu" ở màn hình Pre-Brief).
  void setCurrent(PreBrief brief) => _current = brief;

  /// Xoá Pre-Brief của phiên (giữ nguyên bản nháp đã lưu trên đĩa).
  void clearCurrent() => _current = PreBrief.empty;

  /// Đọc bản nháp đã lưu. Lỗi/JSON hỏng ⇒ Pre-Brief rỗng (không ném — mở app không được chết vì một
  /// bản nháp hỏng).
  Future<PreBrief> loadDraft() async {
    try {
      final String? raw = await _store.read(CoachingConfig.preBriefDraftKey);
      if (raw == null || raw.trim().isEmpty) {
        return PreBrief.empty;
      }
      final PreBrief brief = PreBrief.fromJson(jsonDecode(raw));
      _log.info('đã đọc bản nháp Pre-Brief (rỗng=${brief.isEmpty})');
      return brief;
    } catch (error) {
      _log.warn('không đọc được bản nháp Pre-Brief: $error');
      return PreBrief.empty;
    }
  }

  /// Lưu bản nháp. Không ném: lưu nháp lỗi không được làm hỏng buổi nói chuyện (Pre-Brief của phiên
  /// trong RAM vẫn dùng được).
  Future<void> saveDraft(PreBrief brief) async {
    try {
      await _store.write(CoachingConfig.preBriefDraftKey, jsonEncode(brief.toJson()));
      _log.info('đã lưu bản nháp Pre-Brief (rỗng=${brief.isEmpty})');
    } catch (error) {
      _log.warn('không lưu được bản nháp Pre-Brief: $error');
    }
  }

  /// Nhập bản nháp thành Pre-Brief của phiên (dùng khi mở app lại: người dùng không phải gõ lại).
  Future<PreBrief> restoreDraftAsCurrent() async {
    final PreBrief draft = await loadDraft();
    if (!draft.isEmpty) {
      _current = draft;
    }
    return draft;
  }
}
