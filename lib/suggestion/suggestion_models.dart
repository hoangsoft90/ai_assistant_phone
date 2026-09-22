import 'dart:convert';

/// Loại nudge theo mục 4.5 của plan — nudge 2-4 từ, KHÔNG viết câu hoàn chỉnh.
///
/// [apiName] là mã LLM trả về trong JSON (`"type": "ASK"`), giữ nguyên chính tả trong prompt khung.
enum NudgeType {
  ask('ASK'),
  followUp('FOLLOW_UP'),
  relate('RELATE'),
  react('REACT'),
  clarify('CLARIFY'),
  changeTopic('CHANGE_TOPIC');

  const NudgeType(this.apiName);

  final String apiName;

  /// Đọc mã từ output LLM; trả `null` nếu không nhận ra (caller coi như output không hợp lệ).
  static NudgeType? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    final String normalized = raw.trim().toUpperCase();
    for (final NudgeType type in NudgeType.values) {
      if (type.apiName == normalized) {
        return type;
      }
    }
    return null;
  }
}

/// Kết quả một lần xin gợi ý.
///
/// `NO_SUGGESTION` là một kết quả **HỢP LỆ** (không phải lỗi) — LLM được phép trả nó, và mọi nhánh
/// lỗi ở tầng dưới (timeout, mất mạng, JSON hỏng) cũng phải quy về nó để app KHÔNG bao giờ crash
/// hay hiện lỗi kỹ thuật cho người dùng. [note] chỉ là ghi chú chẩn đoán (hiện trên màn hình
/// chẩn đoán/log; UI thật ở P3 không đọc nó).
class SuggestionResult {
  const SuggestionResult.noSuggestion({this.note})
      : isNudge = false,
        type = null,
        text = null;

  const SuggestionResult.nudge({required this.type, required this.text, this.note})
      : isNudge = true;

  final bool isNudge;
  final NudgeType? type;
  final String? text;

  /// Ghi chú chẩn đoán (lý do bị chặn/lỗi), `null` nếu không có gì đặc biệt.
  final String? note;

  @override
  String toString() => isNudge
      ? 'NUDGE(${type!.apiName}): "$text"'
      : 'NO_SUGGESTION${note == null ? '' : ' ($note)'}';
}

/// Ngữ cảnh một lần xin gợi ý — đã dựng xong (kể cả prompt khung đã thay placeholder).
///
/// [prompt] là chuỗi gửi thẳng cho LLM (1 message `user` duy nhất): giữ nguyên văn prompt khung,
/// chỉ thay `{placeholder}` bằng giá trị thật. Các trường còn lại để test/UI soi dữ liệu đầu vào
/// mà không phải parse lại prompt.
class SuggestionContext {
  const SuggestionContext({
    required this.prompt,
    required this.recentTranscript,
    required this.pushTimestamp,
    required this.topicsExplored,
    required this.lastSuggestions,
    this.preBrief = '',
    this.summary = '',
  });

  /// Prompt hoàn chỉnh (nguyên văn khung + giá trị đã thay).
  final String prompt;

  /// Transcript ~30s gần nhất, text thô KHÔNG nhãn speaker (từ `TranscriptStore`).
  final String recentTranscript;

  /// Mốc Push gần nhất (đã format đọc được), rỗng nếu chưa bấm.
  final String pushTimestamp;

  /// Các chủ đề đã gợi ý trong phiên (P2: chính là text của các nudge trước).
  final List<String> topicsExplored;

  /// Các gợi ý gần nhất dạng "TYPE: text".
  final List<String> lastSuggestions;

  /// P2 để rỗng — Pre-Brief thật làm ở P5.
  final String preBrief;

  /// P2 để rỗng — summary thật cần LLM tóm tắt định kỳ (cải thiện ở phase sau).
  final String summary;
}

/// Lỗi từ tầng LLM (mạng, timeout, HTTP, JSON hỏng, thiếu API key). Tầng trên bắt loại này để
/// retry đúng 1 lần rồi quy về `NO_SUGGESTION` — KHÔNG để lộ ra ngoài Under Exception khác.
class SuggestionException implements Exception {
  const SuggestionException(this.message, [this.cause, this.retryable = false]);

  final String message;
  final Object? cause;

  /// `true` khi lỗi có khả năng hết ở lần gọi lại (vd LLM trả JSON hỏng — lần sau có thể đúng).
  /// Timeout/mất mạng/HTTP lỗi ⇒ `false`: retry chỉ nhân đôi thời gian chờ (vi phạm mục 6 "không
  /// treo app, NO_SUGGESTION sau ~3-4s").
  final bool retryable;

  @override
  String toString() =>
      'SuggestionException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Parse output LLM — đúng 2 dạng hợp lệ (prompt P2 mục 5):
/// `{"action":"NO_SUGGESTION"}` hoặc
/// `{"action":"NUDGE","type":"ASK|...","text":"..."}`.
///
/// Ném [SuggestionException] cho mọi thứ khác (JSON hỏng, action lạ, NUDGE thiếu type/text,
/// type lạ) — caller (service) sẽ retry rồi quy về `NO_SUGGESTION`, KHÔNG crash.
SuggestionResult parseSuggestionOutput(String raw) {
  // LLM có thể bọc JSON trong code fence (```json ... ```) dù đã yêu cầu — bóc lớp bọc trước
  // khi parse; sau khi bóc vẫn sai thì mới tính là lỗi.
  final String cleaned = _stripCodeFence(raw.trim());
  final Object? decoded;
  try {
    decoded = jsonDecode(cleaned);
  } on FormatException catch (error) {
    throw SuggestionException('output LLM không phải JSON hợp lệ', error, true);
  }
  if (decoded is! Map<String, dynamic>) {
    throw const SuggestionException('output LLM không phải JSON object', null, true);
  }

  final Object? action = decoded['action'];
  if (action is! String) {
    throw const SuggestionException('thiếu trường "action"', null, true);
  }
  switch (action.trim().toUpperCase()) {
    case 'NO_SUGGESTION':
      return const SuggestionResult.noSuggestion();
    case 'NUDGE':
      // KHÔNG cast cứng (`as String?`): LLM trả `"type": 123` sẽ ném TypeError xuyên qua mọi
      // `on SuggestionException` ⇒ `push()` ném ra UI (vi phạm DoD "JSON lỗi ⇒ không crash").
      final Object? rawType = decoded['type'];
      final NudgeType? type = NudgeType.tryParse(rawType is String ? rawType : null);
      final Object? rawText = decoded['text'];
      final String text = rawText is String ? rawText.trim() : '';
      if (type == null) {
        throw SuggestionException(
            'NUDGE thiếu/không nhận ra "type" (nhận: ${decoded['type']})',
            null,
            true);
      }
      if (text.isEmpty) {
        throw const SuggestionException('NUDGE thiếu "text"', null, true);
      }
      return SuggestionResult.nudge(type: type, text: text);
    default:
      throw SuggestionException('action lạ: "$action"', null, true);
    }
}

/// Bóc code fence ```json ... ``` (và ``` ... ```) nếu LLM tự ý bọc.
String _stripCodeFence(String text) {
  if (!text.startsWith('```')) {
    return text;
  }
  final int firstNewline = text.indexOf('\n');
  if (firstNewline < 0) {
    return text;
  }
  String body = text.substring(firstNewline + 1);
  if (body.trimRight().endsWith('```')) {
    body = body.trimRight().substring(0, body.trimRight().length - 3);
  }
  return body.trim();
}
