import 'dart:async';

import 'package:http/http.dart' as http;

import '../core/app_logger.dart';
import '../core/constants.dart';
import '../services/storage/meta_store.dart';
import '../suggestion/groq_llm_provider.dart';
import '../suggestion/llm_provider.dart';
import '../suggestion/suggestion_models.dart';
import '../transcript/transcript_store.dart';

/// Tóm tắt phiên thật (P5 task 2) — thay `{summary}` rỗng mà P2 để lại.
///
/// **Vì sao cần**: prompt khung của P2 có `{summary}` = "diễn biến cuộc trò chuyện tới thời điểm hiện
/// tại", nhưng P2 luôn gửi `(chưa có)`. Không có nó, mỗi lần Push chỉ có 30 giây transcript gần nhất
/// ⇒ các nudge sau dễ lặp lại/mất mạch chuyện đã nói từ đầu buổi (đúng mối lo ghi ở bàn giao P2:
/// "giúp context cho các lần Push sau không bị lặp lại/mất mạch").
///
/// **Ràng buộc tự đặt (để không phá đường gợi ý)**: việc tóm tắt là *phụ*, không bao giờ được:
/// - chặn `push()` (caller gọi bằng `unawaited`);
/// - ném ra ngoài (mọi lỗi ⇒ giữ bản tóm tắt cũ + ghi [lastNote]);
/// - chạy chồng (cờ `_inFlight`);
/// - gọi LLM quá dày (chỉ khi đủ [CoachingConfig.summaryEveryNudges] nudge mới hoặc quá
///   [CoachingConfig.summaryInterval]).
///
/// Chỉ **TEXT** đi lên cloud (ràng buộc cứng #4): đối tượng này đọc transcript đã bóc băng, không có
/// đường nào chạm tới audio.
class SessionSummaryService {
  SessionSummaryService({
    TextLlmProvider? provider,
    /// P2.1: khi không inject provider, tóm tắt dùng CÙNG endpoint/model người dùng cấu hình
    /// (resolve mỗi lần gọi — cùng [LlmProviderConfigResolver] + key SecureStore) thay vì luôn
    /// mặc định Groq. `null` = mặc định Groq, y hệt hành vi trước khi có P2.1.
    ConfigStore? llmConfigStore,
    TranscriptStore? transcript,
    DateTime Function()? now,
    this.everyNudges = CoachingConfig.summaryEveryNudges,
    this.interval = CoachingConfig.summaryInterval,
    this.maxTokens = 200,
    http.Client? llmClient,
    Future<String?> Function()? llmApiKeyReader,
  })  : _provider = provider ??
            GroqLlmProvider(
              client: llmClient,
              apiKeyReader: llmApiKeyReader,
              // `null` ⇒ y hệt `GroqLlmProvider()` (mặc định Groq) — P2.1 vẫn nguyên.
              configStore: llmConfigStore,
              // **P5.4**: tóm tắt phiên KHÔNG chặn cuộc trò chuyện (caller gọi bằng `unawaited`, người
              // dùng đang nói) ⇒ dùng mốc 5 phút, KHÔNG phải 4s của Push. Trước phase này nó thừa
              // hưởng mặc định 4s nên bản tóm tắt hay bị bỏ khi LLM phản hồi chậm.
              timeout: SuggestionConfig.postReviewTimeout,
            ),
        _transcript = transcript ?? TranscriptStore.instance(),
        _now = now ?? DateTime.now;

  static const AppLogger _log = AppLogger('SessionSummary');

  final TextLlmProvider _provider;
  final TranscriptStore _transcript;
  final DateTime Function() _now;

  /// Nhịp tóm tắt (điều kiện HOẶC) — công khai để test đặt lại cho dễ đọc (xem class doc).
  final int everyNudges;
  final Duration interval;

  /// Trần token cho mỗi lần tóm tắt (bản tóm tắt chỉ cần ≤ 40 từ).
  final int maxTokens;

  String _summary = '';
  DateTime? _updatedAt;
  String? _lastNote;
  int _refreshCount = 0;

  /// Mốc **lần THỬ** gần nhất (thành công hay thất bại) — chặn thử lại dồn dập khi LLM đang hỏng.
  ///
  /// Nếu chỉ ghi mốc khi thành công: hết 4 nudge mà mất mạng thì nudge thứ 5, 6, 7... mỗi cái lại tạo
  /// một request hỏng (mỗi lần tốn đúng timeout 4s). Đó là lỗi tôi tự tìm thấy khi review phần này.
  DateTime? _lastAttemptAt;
  int _nudgeCountAtLastAttempt = 0;
  bool _inFlight = false;

  /// Token **thế hệ phiên**: tăng mỗi lần [reset]. Một lần tóm tắt đang chạy có thể xong SAU khi phiên
  /// mới bắt đầu (người dùng tắt rồi bật lại ngay sau một nudge) — khi đó kết quả của phiên CŨ phải bị
  /// **vứt bỏ**, nếu không phiên mới sẽ thừa hưởng `{summary}` của buổi trước (đúng lỗi mà việc reset
  /// sinh ra để chống). Đây là cùng một họ với lỗi "callback của thế hệ cũ chạm state dùng chung" đã gặp
  /// ở `SafeTtsBridge` (K45/A54) — cách chữa cũng giống: mọi ghi trạng thái phải qua kiểm token.
  int _generation = 0;

  /// Bản tóm tắt đang dùng cho `{summary}` (rỗng = chưa tóm tắt được lần nào).
  String get summary => _summary;

  DateTime? get updatedAt => _updatedAt;

  /// Số lần đã tóm tắt thành công trong phiên (bằng chứng cho DoD/UI chẩn đoán).
  int get refreshCount => _refreshCount;

  /// Lý do lần tóm tắt gần nhất không thành công (mất mạng, chưa có API key, chưa có transcript...).
  ///
  /// Có trường này để màn hình chẩn đoán trả lời được câu "vì sao `{summary}` vẫn rỗng" mà không phải
  /// mò logcat — bản tóm tắt không hiện trên UI (nội dung suy từ hội thoại = dữ liệu nhạy cảm), nên
  /// không thể kiểm bằng mắt.
  String? get lastNote => _lastNote;

  /// Xoá sạch trạng thái — gọi khi **bắt đầu phiên mới** (nếu không, phiên sau sẽ dùng bản tóm tắt của
  /// buổi trước làm ngữ cảnh cho LLM ⇒ gợi ý sai chủ đề, và đây là loại lỗi rất khó lần vì prompt vẫn
  /// hợp lệ).
  void reset() {
    _generation++;
    _summary = '';
    _updatedAt = null;
    _lastNote = null;
    _refreshCount = 0;
    _lastAttemptAt = null;
    _nudgeCountAtLastAttempt = 0;
  }

  /// Gọi sau mỗi nudge đã hiển thị. Không bao giờ ném, không bao giờ chặn caller.
  ///
  /// [nudgeCount] là số nudge **trong phiên hiện tại** (nguồn: `SessionMemory.recentSuggestions`).
  Future<void> maybeRefresh({required int nudgeCount}) async {
    if (_inFlight) {
      return;
    }
    final int generation = _generation;
    final DateTime now = _now();
    final bool enoughNewNudges = nudgeCount - _nudgeCountAtLastAttempt >= everyNudges;
    final DateTime? lastAttempt = _lastAttemptAt;
    final bool timeDue = lastAttempt != null && now.difference(lastAttempt) >= interval;
    if (!enoughNewNudges && !timeDue) {
      return;
    }
    _inFlight = true;
    // Ghi mốc THỬ ngay (không phải mốc thành công): lỗi thì lần sau phải chờ thêm [interval] hoặc thêm
    // [everyNudges] nudge, thay vì mỗi nudge tiếp theo lại đập vào LLM đang chết.
    _lastAttemptAt = now;
    _nudgeCountAtLastAttempt = nudgeCount;
    try {
      final SessionTranscript transcript = await _transcript.sessionTranscript();
      if (transcript.isEmpty) {
        _lastNote = 'chưa có transcript để tóm tắt';
        return;
      }
      final String text = await _provider.complete(
        prompt: buildSummaryPrompt(transcript.text),
        maxTokens: maxTokens,
      );
      if (generation != _generation) {
        // Phiên đã đổi trong lúc chờ LLM ⇒ bỏ kết quả (xem doc của `_generation`).
        _log.info('bỏ kết quả tóm tắt của phiên cũ (phiên đã đổi trong lúc chờ LLM)');
        return;
      }
      _summary = clampSummary(text);
      _updatedAt = now;
      _refreshCount++;
      _lastNote = null;
      // KHÔNG log nội dung tóm tắt (suy ra từ hội thoại thật — cùng mức nhạy cảm với transcript,
      // quyết định từ review P2).
      _log.info(
        'đã cập nhật session summary (lần $_refreshCount · ${_summary.length} ký tự'
        '${transcript.truncated ? ' · transcript đã cắt' : ''})',
      );
    } on SuggestionException catch (error) {
      if (generation == _generation) {
        _lastNote = error.message;
      }
      _log.warn('không tóm tắt được phiên (giữ bản cũ): ${error.message}');
    } catch (error, stackTrace) {
      // Lỗi ngoài dự kiến (parse, provider mới, thư viện...): tóm tắt là tính năng phụ ⇒ nuốt lỗi.
      if (generation == _generation) {
        _lastNote = 'lỗi không xác định';
      }
      _log.error('tóm tắt phiên lỗi ngoài dự kiến', error, stackTrace);
    } finally {
      _inFlight = false;
    }
  }

  /// Prompt tóm tắt — tách `static` để test khoá được nội dung (giống cách `buildPrompt` của P2 được
  /// test khoá): các quy tắc ở đây là hợp đồng với LLM, không phải chữ trang trí.
  static String buildSummaryPrompt(String transcript) => '''
Bạn đang hỗ trợ một người ít nói, hay lo âu xã hội trong một cuộc trò chuyện trực tiếp.
Dưới đây là transcript cuộc trò chuyện tới thời điểm hiện tại (KHÔNG có nhãn người nói — hãy tự suy
luận ai đang nói dựa vào ngữ cảnh, câu hỏi/câu trả lời, xưng hô).

Hãy tóm tắt ngắn gọn (tối đa 40 từ) gồm: đã nói tới chủ đề gì, mối quan tâm/hoàn cảnh của đối
phương, và điều gì còn dang dở. Không suy đoán thông tin không có trong transcript.

Chỉ trả về phần tóm tắt (một đoạn văn), không thêm tiêu đề, danh sách hay giải thích.

Transcript:
$transcript
''';

  /// Cắt bản tóm tắt về trần ký tự trước khi nhét vào prompt khung (`{summary}`).
  ///
  /// Giữ phần **đầu** (khác transcript — transcript cắt phần cuối): câu tóm tắt thường mở đầu bằng
  /// chủ đề chính, nên phần đầu là phần mang thông tin; cắt lấy đoạn cuối chỉ còn mệnh đề phụ.
  static String clampSummary(String raw) {
    final String cleaned = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.length <= CoachingConfig.summaryCharLimit) {
      return cleaned;
    }
    return '${cleaned.substring(0, CoachingConfig.summaryCharLimit).trimRight()}…';
  }
}
