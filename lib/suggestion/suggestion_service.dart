import 'dart:async';

import '../audio/vad/conversation_state_notifier.dart';
import '../coaching/pre_brief.dart';
import '../coaching/session_summary.dart';
import '../coaching/training_level.dart';
import '../core/app_logger.dart';
import '../transcript/transcript_store.dart';
import 'groq_llm_provider.dart';
import 'llm_provider.dart';
import 'offline_nudge_cache.dart';
import 'session_memory.dart';
import 'suggestion_context_builder.dart';
import 'suggestion_models.dart';
import 'suggestion_policy.dart';

/// Orchestrator của Suggestion Engine (P2): nối Push trigger → Policy → Context → LLM → Parse →
/// kết quả. P3 sẽ thay nút debug bằng trigger thật và thêm Offline Nudge Cache.
///
/// Luồng `push()`:
/// 1. Policy chặn CỨNG: `userSpeaking` / debounce — KHÔNG build context, KHÔNG gọi LLM khi bị chặn.
/// 2. Build context (transcript P1E + bộ nhớ phiên).
/// 3. Gọi LLM (timeout ở tầng provider). Lỗi/JSON hỏng ⇒ retry đúng 1 lần ⇒ vẫn lỗi ⇒
///    `NO_SUGGESTION` — không crash, không lộ lỗi kỹ thuật cho người dùng.
/// 4. Anti-repetition: nudge trùng chủ đề/type trong 2 phút ⇒ quy về `NO_SUGGESTION`.
/// 5. Nudge hợp lệ ⇒ ghi vào bộ nhớ phiên + trả về.
class SuggestionService {
  SuggestionService({
    LlmProvider? provider,
    SuggestionPolicy? policy,
    SuggestionContextBuilder? builder,
    SessionMemory? memory,
    TranscriptStore? transcript,
    OfflineNudgeCache? cache,
    DateTime Function()? now,
    PreBriefStore? preBriefs,
    SessionSummaryService? summaries,
    TrainingLevelStore? levels,
  })  : _provider = provider ?? GroqLlmProvider(),
        _policy = policy ?? SuggestionPolicy(),
        _builder = builder ?? SuggestionContextBuilder(),
        _memory = memory ?? SessionMemory(),
        _transcript = transcript ?? TranscriptStore.instance(),
        _cache = cache ?? OfflineNudgeCache.instance(),
        _now = now ?? DateTime.now,
        _preBriefs = preBriefs ?? PreBriefStore.instance(),
        _summaries = summaries ?? SessionSummaryService(),
        _levels = levels ?? TrainingLevelStore.instance();

  static const AppLogger _log = AppLogger('Suggestion');

  final LlmProvider _provider;
  final SuggestionPolicy _policy;
  final SuggestionContextBuilder _builder;
  final SessionMemory _memory;
  final TranscriptStore _transcript;
  final OfflineNudgeCache _cache;
  final DateTime Function() _now;

  /// P5: Pre-Brief của phiên (thay `{pre_brief}` mock rỗng của P2) và bản tóm tắt phiên
  /// (thay `{summary}`). Hai thứ này là **ngữ cảnh**, không phải luật — luật cấp độ nằm ở
  /// [SuggestionPolicy], còn việc tóm tắt nằm ở [SessionSummaryService].
  final PreBriefStore _preBriefs;
  final SessionSummaryService _summaries;

  /// P5: Training Level (mục 4.9) — nguồn duy nhất của luật "cấp này có được nudge realtime không".
  final TrainingLevelStore _levels;

  DateTime? _lastAttemptAt;
  int _cacheFallbackCount = 0;

  /// Số nudge đã ghi trong **phiên hiện tại** (đếm riêng, không lấy từ `_memory`).
  ///
  /// Vì sao không dùng `_memory.recentSuggestions.length`: bộ nhớ phiên có trần 20 bản ghi (chống phình
  /// RAM) ⇒ sau nudge thứ 20 con số đó **đứng yên** và nhịp tóm tắt theo nudge không bao giờ đủ nữa
  /// (chỉ còn nhịp theo thời gian). Đây là lỗi tôi tự tìm thấy khi review phần P5.
  int _sessionNudgeCount = 0;

  /// Bộ nhớ phiên cho UI/test đọc (nudge đã hiển thị trong phiên).
  SessionMemory get memory => _memory;

  /// Số lần đã phải lấy nudge từ Offline Cache (P3 mục 4.12: theo dõi tần suất fallback).
  int get cacheFallbackCount => _cacheFallbackCount;

  /// Người dùng bấm Push (thủ công). Trả về kết quả để UI hiển thị; **KHÔNG bao giờ ném**
  /// (mọi nhánh lỗi — policy, transcript, mạng, timeout, JSON — đều quy về `NO_SUGGESTION`).
  ///
  /// [isUserSpeaking] đọc từ state machine (P1B) — truyền vào để test được; trong app, caller dùng
  /// `pushFromState()` bên dưới.
  Future<SuggestionResult> push({required bool isUserSpeaking}) async {
    final DateTime now = _now();
    final TrainingLevel level = _levels.current;

    // 1) Policy — chặn CỨNG trước khi build context (constraint P2). Từ P5 có thêm luật Training Level
    //    (Level 4/5 ⇒ `NO_SUGGESTION` có chủ đích, mục 4.9).
    final PolicyDecision decision = _policy.canSuggest(
      isUserSpeaking: isUserSpeaking,
      lastAttemptAt: _lastAttemptAt,
      now: now,
      level: level,
    );
    // Ghi nhận MỌI lần bấm (kể cả bị chặn) làm mốc debounce — double-tap phải bị chặn dù lần
    // trước đã bị chặn vì userSpeaking.
    _lastAttemptAt = now;
    if (!decision.allowed) {
      _log.info('Push bị chặn bởi policy: ${decision.reason}');
      return SuggestionResult.noSuggestion(note: 'bị chặn: ${decision.reason}');
    }

    // 2) Build context từ transcript (P1E) + bộ nhớ phiên. Đọc transcript có thể NÉM (SQLite lỗi/
    // DB chưa mở) — bọc lại, vì hợp đồng của `push()` là KHÔNG BAO GIỜ ném.
    final SuggestionContext context;
    final TranscriptWindow window;
    try {
      window = await _transcript.recentWindow(window: _builder.recentWindow);
      context = _builder.build(
        window: window,
        memory: _memory,
        now: now,
        // P5: thay hai chỗ mock rỗng của P2 bằng dữ liệu thật — Pre-Brief người dùng vừa nhập và bản
        // tóm tắt phiên do LLM cập nhật định kỳ.
        preBrief: _preBriefs.current,
        summary: _summaries.summary,
      );
    } catch (error, stackTrace) {
      _log.error('không đọc được transcript để dựng context', error, stackTrace);
      return SuggestionResult.noSuggestion(note: 'lỗi đọc transcript');
    }

    // 2b) Cổng thứ HAI theo Training Level (P5 mục 4.9) — cần transcript nên phải nằm sau bước dựng
    //     context, nhưng vẫn TRƯỚC khi gọi LLM. Trả về `NO_SUGGESTION` có chủ đích: đây là quyết
    //     định học tập của người dùng (Level 4/5 "không cứu realtime"), KHÔNG phải lỗi ⇒ cố ý KHÔNG
    //     fallback sang Offline Nudge Cache (fallback ở đây là phá đúng cấp độ người dùng chọn).
    final PolicyDecision contextDecision = _policy.canSuggestWithContext(
      level: level,
      hasPreBrief: _preBriefs.hasCurrent,
      hasRecentTranscript: !window.isEmpty,
      lastTranscriptAt:
          window.segments.isEmpty ? null : window.segments.last.timestamp,
      now: now,
    );
    if (!contextDecision.allowed) {
      _log.info('Push bị chặn theo training level: ${contextDecision.reason}');
      return SuggestionResult.noSuggestion(note: 'bị chặn: ${contextDecision.reason}');
    }

    // 3) Gọi LLM — retry đúng 1 lần khi JSON lỗi (constraint prompt P2 mục 5). Timeout/mất mạng
    //    do provider ném [SuggestionException] — quy về NO_SUGGESTION, không treo app.
    SuggestionResult result;
    try {
      result = await _generateOnce(context);
    } on SuggestionException catch (error) {
      if (!error.retryable) {
        // Timeout/mất mạng/HTTP lỗi: retry chỉ nhân đôi thời gian chờ (vi phạm mục 6 "NO_SUGGESTION
        // sau ~3-4s") ⇒ fail NGAY, không thử lại — và đây chính là ca cần Offline Cache (P3).
        _log.warn('LLM lỗi (không retry): $error');
        return _fallbackToCache(now: now, reason: error.message);
      }
      // JSON lỗi: retry đúng 1 lần (prompt P2 mục 5).
      _log.warn('output LLM lỗi lần 1: $error — thử lại 1 lần');
      try {
        result = await _generateOnce(context);
      } on SuggestionException catch (retryError) {
        _log.warn('output LLM lỗi lần 2: $retryError — chuyển sang Offline Cache');
        return _fallbackToCache(now: now, reason: retryError.message);
      }
    }

    // 4) Anti-repetition (mục 4.7) — chỉ lọc nudge.
    if (_policy.isRepetition(
      result: result,
      recent: _memory.recentForRepetition(now),
      now: now,
    )) {
      _log.info('nudge trùng chủ đề/type trong 2 phút — quy về NO_SUGGESTION');
      return SuggestionResult.noSuggestion(note: 'trùng gợi ý gần đây');
    }

    // 5) Ghi bộ nhớ phiên + trả về.
    _memory.record(result, at: now);
    _sessionNudgeCount++;
    _maybeRefreshSummary();
    // KHÔNG log nội dung nudge: đó là nội dung suy ra từ hội thoại (dữ liệu nhạy cảm — cùng loại
    // với transcript). Logcat chỉ ghi loại + trạng thái; nội dung đã hiện trên màn hình chẩn đoán.
    _log.info(
      result.isNudge
          ? 'kết quả Push: NUDGE(${result.type!.apiName}'
              '${result.source == NudgeSource.cache ? ', CACHE' : ''})'
          : 'kết quả Push: NO_SUGGESTION'
              '${result.note == null ? '' : ' (${result.note})'}'
              '${result.unavailable ? ' · LLM không dùng được' : ''}',
    );
    return result;
  }

  /// Fallback **Offline Nudge Cache** (P3 mục 4.12) — CHỈ gọi khi không dùng được LLM.
  ///
  /// Không được gọi cho: (a) Policy chặn (đang nói / debounce), (b) LLM trả `NO_SUGGESTION` hợp lệ,
  /// (c) nudge bị lọc vì lặp lại — ba ca đó là quyết định "không gợi ý", KHÔNG phải "không hỏi
  /// được LLM". Cache cũng không bao giờ thay thế LLM khi có mạng (constraint P3).
  Future<SuggestionResult> _fallbackToCache({required DateTime now, required String reason}) async {
    _cacheFallbackCount++;
    final List<String> avoid = _memory
        .recentForRepetition(now)
        .map((SuggestionRecord r) => r.text)
        .toList();
    final CachedNudge? cached = await _cache.pickNext(avoidTexts: avoid);
    if (cached == null) {
      _log.warn('LLM không dùng được và Offline Cache cũng không có nudge ($reason)');
      return SuggestionResult.noSuggestion(note: 'LLM lỗi: $reason', unavailable: true);
    }
    final SuggestionResult result = SuggestionResult.nudge(
      type: cached.type,
      text: cached.text,
      source: NudgeSource.cache,
      note: 'offline cache ($reason)',
    );
    // KHÔNG đếm nudge cache vào nhịp tóm tắt: nhánh này nghĩa là **LLM vừa không dùng được**, nên gọi
    // tóm tắt ngay sau đó chỉ tạo thêm một request chắc chắn hỏng (mỗi lần tốn cả timeout).
    _memory.record(result, at: now);
    _log.warn(
      'LLM không dùng được ⇒ nudge từ OFFLINE CACHE (${cached.type.apiName}) · '
      'lần fallback thứ $_cacheFallbackCount · lý do: $reason',
    );
    return result;
  }

  /// Gọi provider và **chuẩn hoá mọi lỗi về [SuggestionException]**.
  ///
  /// Cần thiết vì hợp đồng "`push()` không bao giờ ném" phải chịu được cả lỗi NGOÀI dự kiến
  /// (provider mới thêm sau, cast sai trong thư viện, `TypeError` khi thân phản hồi dị dạng...):
  /// nếu chỉ bắt `SuggestionException` thì những lỗi đó xuyên thẳng lên UI. Lỗi ngoài dự kiến được
  /// coi là **không retryable** (không rõ nguyên nhân thì thử lại chỉ tốn thời gian của người dùng).
  Future<SuggestionResult> _generateOnce(SuggestionContext context) async {
    try {
      return await _provider.generateSuggestion(context);
    } on SuggestionException {
      rethrow;
    } catch (error, stackTrace) {
      _log.error('provider ném lỗi ngoài dự kiến', error, stackTrace);
      throw SuggestionException('lỗi provider: $error', error);
    }
  }

  /// Tiện lợi cho caller trong app: đọc trạng thái hội thoại từ state machine P1B.
  Future<SuggestionResult> pushFromState() =>
      push(isUserSpeaking: ConversationStateNotifier.instance.isUserSpeaking);

  /// Xoá bộ nhớ phiên (test / bắt đầu phiên mới) + bản tóm tắt của phiên cũ.
  ///
  /// ⚠️ KHÔNG xoá Pre-Brief: Pre-Brief được nhập **cho** phiên sắp bắt đầu, nên xoá nó ở đây sẽ làm
  /// người dùng mất ngữ cảnh vừa gõ ngay khi bấm "Bật lắng nghe".
  void resetSession() {
    _memory.clear();
    _lastAttemptAt = null;
    _sessionNudgeCount = 0;
    _summaries.reset();
  }

  /// Nguồn ngữ cảnh cho UI (màn hình Pre-Brief + dòng chẩn đoán) — không mở thêm đường ghi nào khác.
  PreBriefStore get preBriefs => _preBriefs;

  SessionSummaryService get summaries => _summaries;

  TrainingLevelStore get levels => _levels;

  /// Gọi tóm tắt phiên nếu đã tới nhịp. **Cố ý không `await`**: tóm tắt là tính năng phụ, chờ nó chỉ
  /// làm nudge tới muộn (DoD P4 đo độ trễ Push→tổng hợp). `maybeRefresh` tự nuốt mọi lỗi.
  void _maybeRefreshSummary() {
    unawaited(_summaries.maybeRefresh(nudgeCount: _sessionNudgeCount));
  }
}
