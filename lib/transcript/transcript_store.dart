import 'dart:async';

import '../audio/asr/asr_engine.dart';
import '../core/app_logger.dart';
import '../core/constants.dart';
import '../services/storage/meta_store.dart';
import '../services/storage/retention_config.dart';
import '../services/storage/transcript_dao.dart';
import 'transcript_segment.dart';

/// Kết quả trả cho Suggestion Engine (P2) — đúng thứ cần để dựng prompt LLM (plan mục 7).
class TranscriptWindow {
  const TranscriptWindow({required this.segments, required this.lastPushMoment});

  /// Các dòng trong cửa sổ, đã sắp xếp tăng dần theo thời gian.
  final List<TranscriptSegment> segments;

  /// Mốc người dùng bấm Push gần nhất, `null` nếu chưa bấm.
  final DateTime? lastPushMoment;

  /// Text thô **KHÔNG nhãn người nói** — mỗi dòng một dòng, ghép bằng `\n`. Đây chính là dạng sẽ
  /// đưa vào prompt LLM; P2 tự thêm phần mô tả/mốc Push, KHÔNG thêm nhãn `[Bạn]/[Đối phương]`
  /// (quyết định 4.2b — LLM tự suy luận ai nói từ ngữ nghĩa).
  String get text =>
      segments.map((TranscriptSegment segment) => segment.text).join('\n');

  bool get isEmpty => segments.isEmpty;

  @override
  String toString() =>
      'TranscriptWindow(${segments.length} dòng, push=$lastPushMoment)';
}

/// Toàn bộ transcript của **phiên đang chạy** (P5) — khác [TranscriptWindow] (chỉ một cửa sổ 30s dùng
/// cho prompt khung của P2).
///
/// Tách riêng kiểu trả về thay vì trả `String` trần vì hai caller (tóm tắt phiên, Post-Review) đều
/// **phải báo được** cho người dùng khi nội dung bị cắt do trần ký tự gửi LLM — im lặng cắt sẽ khiến
/// báo cáo "đã phân tích cả buổi" trong khi thực tế chỉ phân tích phần cuối.
class SessionTranscript {
  const SessionTranscript({
    required this.text,
    required this.segmentCount,
    required this.truncated,
  });

  /// Text thô, mỗi dòng transcript một dòng, KHÔNG nhãn người nói (ràng buộc xuyên phase từ P1E).
  final String text;

  /// Tổng số dòng của phiên **trước** khi cắt (để đối chiếu với [truncated]).
  final int segmentCount;

  /// `true` nếu [text] đã bị cắt bớt (chỉ giữ phần cuối) do vượt trần ký tự.
  final bool truncated;

  bool get isEmpty => text.isEmpty;

  @override
  String toString() =>
      'SessionTranscript($segmentCount dòng${truncated ? ', đã cắt' : ''} · ${text.length} ký tự)';
}

/// Rolling transcript của phiên hiện tại (P1E).
///
/// Kiến trúc:
/// - Nhận text từ `AsrEngine.transcriptStream` (không tự gọi ASR) — nhờ vậy không phụ thuộc engine
///   nào đang chạy (PhoWhisper/Vosk, quyết định ở P1D).
/// - **Bộ nhớ hoạt động** chỉ giữ [rollingWindow] gần nhất (P1E task 3) để phiên dài không phình
///   RAM; truy vấn dài hơn thì đọc thẳng SQLite.
/// - **SQLite là nguồn sự thật**: mỗi dòng được ghi xuống đĩa ngay khi nhận, nên app bị OS kill
///   giữa chừng vẫn còn nguyên dữ liệu (P1E task 4).
/// - Ghi tuần tự qua [_pending]: hai dòng đến sát nhau không thể ghi xen kẽ làm đảo thứ tự.
class TranscriptStore {
  TranscriptStore({
    TranscriptDao? dao,
    DateTime Function()? now,
    Duration? rollingWindow,
    Duration? resumeGap,
    Duration? retention,
    ConfigStore? configStore,
  })  : _dao = dao ?? const SqliteTranscriptDao(),
        _now = now ?? DateTime.now,
        _rollingWindow = rollingWindow ?? StorageConfig.transcriptRollingWindow,
        _resumeGap = resumeGap ?? StorageConfig.transcriptResumeGap,
        _retention = retention ??
            (configStore == null
                ? StorageConfig.transcriptRetention
                : null /* đọc từ cấu hình ở `_open()` — init là async, constructor không đợi được */),
        _configStore = configStore;

  static TranscriptStore? _instance;

  /// Bản dùng chung cho app (cùng kiểu với `AppDatabase.instance()`): `main()` gọi `init()` một lần
  /// lúc bootstrap, màn hình chính lấy lại đúng instance đó để `attach()` vào engine ASR.
  ///
  /// P5.1: bản dùng chung đọc hạn tự xoá từ bảng `meta` (Settings) lúc `init()` — không đổi gì
  /// với người dùng chưa từng vào Settings (resolver fallback về 7 ngày).
  static TranscriptStore instance() =>
      _instance ??= TranscriptStore(configStore: const MetaConfigStore());

  static const AppLogger _log = AppLogger('TranscriptStore');

  final TranscriptDao _dao;
  final DateTime Function() _now;
  final Duration _rollingWindow;
  final Duration _resumeGap;

  /// Hạn tự xoá. `null` nghĩa là "chưa biết — phải resolve từ [_configStore] ở `_open()`"
  /// (P5.1: khi bản dùng chung được tạo với `configStore`). Khi tham số `retention` được truyền
  /// trực tiếp (test/cleanup tuỳ chỉnh) thì giá trị ở đây là hạn cuối cùng, không qua resolver.
  final Duration? _retention;

  /// Nguồn cấu hình retention (P5.1). `null` khi caller truyền `retention` cứng (test) hoặc khi
  /// dùng constructor mặc định không có `configStore` — khi đó fallback về hằng số mặc định.
  final ConfigStore? _configStore;

  Future<void>? _initFuture;
  int? _sessionId;
  final List<TranscriptSegment> _memory = <TranscriptSegment>[];
  DateTime? _lastPushMoment;

  // Subscription này ĐƯỢC huỷ trong `detach()` (và `close()` gọi `detach()`), nhưng qua biến cục bộ
  // lấy ra trước `await` — cần thiết để `attach()` chạy xen vào không bị xoá nhầm (xem `attach`).
  // Lint không lần theo được lối gián tiếp đó nên báo ở đây; giữ race-safe, không "sửa" cho vừa lint.
  // ignore: cancel_subscriptions
  StreamSubscription<String>? _asrSub;
  Future<void> _pending = Future<void>.value();
  int _recoveredSegments = 0;

  /// Phiên đang ghi, `null` khi [init] chưa chạy xong.
  int? get sessionId => _sessionId;

  /// Số dòng đang giữ trong bộ nhớ hoạt động (≤ cửa sổ rolling).
  int get memorySegmentCount => _memory.length;

  /// Số dòng khôi phục được từ phiên cũ ở lần [init] gần nhất (> 0 nghĩa là app đã bị kill giữa
  /// phiên và dữ liệu đã được cứu). Dùng cho màn hình chẩn đoán + test crash recovery.
  int get recoveredSegmentCount => _recoveredSegments;

  DateTime? get lastPushMoment => _lastPushMoment;

  /// Các dòng trong bộ nhớ hoạt động (không đọc đĩa) — dùng cho UI chẩn đoán.
  List<TranscriptSegment> get memorySegments => List<TranscriptSegment>.unmodifiable(_memory);

  /// Mở kho transcript: **xoá dữ liệu cũ hơn 7 ngày** rồi **khôi phục phiên đang dở** (P1E task 4/7).
  ///
  /// Gọi nhiều lần vô hại (trả về cùng một future). Ném lỗi nếu SQLite không dùng được — tầng gọi
  /// ở bootstrap bọc try/catch để app không chết vì một mảnh hạ tầng (cùng cách P0.5 đã làm).
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    try {
      await _open();
    } catch (error) {
      // KHÔNG cache future đã hỏng: SQLite có thể lỗi thoáng qua (DB đang bị khoá...), nếu cache
      // thì store chết vĩnh viễn cho tới khi khởi động lại app. Lỗi vẫn được ném cho tầng gọi.
      _initFuture = null;
      _log.error('không mở được kho transcript: $error');
      rethrow;
    }
  }

  Future<void> _open() async {
    final DateTime now = _now();

    // P5.1: hạn tự xoá đọc từ cấu hình (Settings) nếu bản này được tạo với `configStore`;
    // không thì giữ hạn được truyền trực tiếp, hoặc cuối cùng là mặc định 7 ngày (hành vi y hệt
    // trước P5.1 — DoD "không đổi mặc định"). Lỗi đọc/parse do resolver tự nuốt, không ném ở đây.
    final Duration retention;
    final Duration? configured = _retention;
    if (configured != null) {
      retention = configured;
    } else {
      final ConfigStore? store = _configStore;
      retention = store == null
          ? StorageConfig.transcriptRetention
          : await RetentionConfigResolver.resolve(store);
    }

    final int removedSessions = await _dao.deleteOlderThan(now.subtract(retention));
    if (removedSessions > 0) {
      _log.info(
        'đã xoá $removedSessions phiên transcript cũ hơn ${retention.inDays} ngày (quyền riêng tư)',
      );
    }

    final TranscriptSession? latest = await _dao.latestSession();
    // issue1_fix mục 6: chỉ resume khi (1) còn trong resumeGap **VÀ** (2) phiên chưa kết thúc chủ
    // động. Điều kiện (2) là mới: trước đây phiên người dùng bấm "Kết thúc buổi" vẫn bị resume nếu
    // Start lại trong 30 phút ⇒ transcript lẫn vào phiên cũ + báo cáo Post-Review ghi đè nhầm.
    if (latest != null &&
        !latest.isFinished &&
        now.difference(latest.lastActivityAt) <= _resumeGap) {
      // Khôi phục phiên đang dở: app bị OS kill giữa chừng thì mở lại vẫn còn dữ liệu đã ghi.
      _sessionId = latest.id;
      final List<TranscriptSegment> restored =
          await _dao.segmentsSince(latest.id, now.subtract(_rollingWindow));
      _memory
        ..clear()
        ..addAll(restored);
      _recoveredSegments = restored.length;
      _lastPushMoment = await _dao.latestPush(latest.id);
      _log.info(
        'khôi phục phiên transcript #${latest.id}: ${restored.length} dòng trong cửa sổ '
        '${_rollingWindow.inMinutes} phút (phiên vẫn còn hoạt động)',
      );
    } else {
      final TranscriptSession created = await _dao.createSession(now);
      _sessionId = created.id;
      _recoveredSegments = 0;
      _log.info('bắt đầu phiên transcript mới #${created.id}');
    }
  }

  /// Gắn vào engine ASR đang chạy: mỗi text engine phát ra thành một dòng transcript.
  ///
  /// Không giữ tham chiếu tới engine (engine do tầng trên sở hữu) — chỉ lắng nghe stream, và luôn
  /// hủy subscription cũ trước khi gắn cái mới (đổi engine ở P1D sẽ gọi lại hàm này).
  void attach(AsrEngine engine) {
    // Đổi subscription trong bộ nhớ TRƯỚC, huỷ cái cũ SAU — và huỷ trên chính tham chiếu đã lấy ra.
    //
    // Không được viết `unawaited(detach())` ở đây: `detach()` treo ở `await`, nên nếu nó chạy tiếp
    // SAU khi dòng dưới đã gán `_asrSub` thì nó sẽ gán `null` đè lên subscription mới ⇒ stream cũ
    // vẫn sống nhưng không ai còn tham chiếu để huỷ (bug đã bị test bắt ở P1E).
    final StreamSubscription<String>? previous = _asrSub;
    _asrSub = engine.transcriptStream.listen(
      (String text) => unawaited(add(text)),
      onError: (Object error) => _log.warn('stream transcript lỗi (bỏ qua dòng): $error'),
    );
    if (previous != null) {
      unawaited(previous.cancel());
    }
    _log.info('đã gắn TranscriptStore vào engine ASR');
  }

  /// Hủy lắng nghe ASR (gọi khi tắt ASR / dispose màn hình).
  Future<void> detach() async {
    // Lấy tham chiếu ra rồi `null` NGAY (trước `await`): nếu `attach()` chạy xen vào lúc đang chờ
    // `cancel()`, subscription mới không bị xoá nhầm.
    final StreamSubscription<String>? current = _asrSub;
    _asrSub = null;
    await current?.cancel();
  }

  /// Thêm một dòng text thô vào phiên hiện tại. Trả về `null` nếu text rỗng (ASR có thể phát chuỗi
  /// trắng — không lưu rác) hoặc nếu ghi đĩa lỗi (đã log; một dòng mất không được làm chết phiên).
  ///
  /// [at] chỉ dùng cho test/backfill; mặc định lấy đồng hồ của store.
  Future<TranscriptSegment?> add(String text, {DateTime? at}) {
    final Future<TranscriptSegment?> result = _pending.then(
      (_) => _addSequential(text, at: at),
    );
    // Nuốt lỗi ở chuỗi nối: một lần ghi lỗi không được làm kẹt mọi lần ghi sau (lỗi đã log trong
    // `_addSequential`).
    _pending = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<TranscriptSegment?> _addSequential(String text, {DateTime? at}) async {
    final String cleaned = text.trim();
    if (cleaned.isEmpty) {
      return null;
    }
    try {
      await init();
      final int sessionId = _sessionId!;
      final TranscriptSegment segment =
          TranscriptSegment(text: cleaned, timestamp: at ?? _now());
      // Ghi đĩa TRƯỚC, bộ nhớ sau: bộ nhớ là bản sao rút gọn của đĩa, không bao giờ được chứa
      // dòng mà đĩa không có (nếu không, UI báo "đã lưu" trong khi thực ra đã mất).
      await _dao.appendSegment(sessionId, segment);
      await _dao.touchSession(sessionId, segment.timestamp);
      _memory.add(segment);
      _prune(segment.timestamp);
      return segment;
    } catch (error, stackTrace) {
      _log.error('không ghi được dòng transcript', error, stackTrace);
      return null;
    }
  }

  /// Ghi mốc người dùng bấm Push (P1E task 5 — P3 mới có nút thật, P2 dùng API này).
  Future<void> markPushMoment(DateTime at) async {
    await init();
    try {
      await _dao.recordPush(_sessionId!, at);
      _lastPushMoment = at;
      _log.info('mốc Push: ${at.toIso8601String()}');
    } catch (error, stackTrace) {
      _log.error('không ghi được mốc Push', error, stackTrace);
    }
  }

  /// API cho P2: transcript [window] gần nhất (text thô, không nhãn) + mốc Push gần nhất.
  ///
  /// Cửa sổ ≤ [rollingWindow] lấy từ bộ nhớ; dài hơn thì đọc SQLite (không bị cắt cụt âm thầm).
  Future<TranscriptWindow> recentWindow({Duration? window}) async {
    await init();
    final Duration span = window ?? _rollingWindow;
    final DateTime cutoff = _now().subtract(span);
    final int sessionId = _sessionId!;
    final List<TranscriptSegment> segments = span <= _rollingWindow
        ? _memory
            .where((TranscriptSegment s) => !s.timestamp.isBefore(cutoff))
            .toList()
        : await _dao.segmentsSince(sessionId, cutoff);
    return TranscriptWindow(segments: segments, lastPushMoment: _lastPushMoment);
  }

  /// Toàn bộ transcript của phiên đang chạy (P5) — nguồn dữ liệu cho tóm tắt định kỳ và Post-Review.
  ///
  /// Đọc thẳng SQLite (không qua bộ nhớ rolling) vì cần cả phiên. Cắt từ **ĐẦU** khi vượt
  /// [maxChars]: phần gần đây là phần quyết định cho cả gợi ý lẫn nhận xét cuối buổi (lý do chi tiết
  /// ở `CoachingConfig.transcriptCharLimit`).
  ///
  /// **P5.4:** uỷ quyền cho [TranscriptDao.fullSessionText] — cùng một hàm ghép/cắt dùng chung với
  /// đường "phân tích lại buổi cũ" (`PostReviewService.runForSession`), nên hai đường không thể lệch
  /// hành vi. Hàm này vẫn chỉ đọc phiên **đang mở**.
  Future<SessionTranscript> sessionTranscript({
    int maxChars = CoachingConfig.transcriptCharLimit,
  }) async {
    await init();
    final SessionText dump = await _dao.fullSessionText(_sessionId!, maxChars: maxChars);
    return SessionTranscript(
      text: dump.text,
      segmentCount: dump.segmentCount,
      truncated: dump.truncated,
    );
  }

  /// Đánh dấu phiên hiện tại đã kết thúc **chủ động** (issue1_fix mục 6) — gọi trong
  /// `finishSessionAndReview` SAU khi `stop()` phiên và TRƯỚC khi Post-Review chạy.
  ///
  /// Ghi mốc `ended_at` xuống đĩa ⇒ lần `_open()` kế tiếp (Start mới / mở lại app) sẽ **không bao
  /// giờ** resume phiên này, dù còn trong `resumeGap`. Không ném: lỗi DB chỉ được log — việc đánh
  /// dấu thất bại không được chặn Post-Review (vẫn tốt hơn Crash-recovery sai phiên).
  /// Phiên chưa mở (`_sessionId == null`) ⇒ vô hại.
  Future<void> markCurrentSessionEnded() async {
    final int? sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    try {
      await _dao.markSessionEnded(sessionId, _now());
    } catch (error, stackTrace) {
      _log.error('không đánh dấu được kết thúc phiên #$sessionId', error, stackTrace);
    }
  }

  /// Hủy lắng nghe và chờ hết các lần ghi đang dở (gọi khi app/màn hình kết thúc).
  Future<void> close() async {
    await detach();
    await _pending;
  }

  /// Bỏ các dòng đã ra khỏi cửa sổ rolling khỏi bộ nhớ (P1E task 3). Dữ liệu vẫn còn nguyên trên
  /// đĩa — đây chỉ là bản sao trong RAM.
  void _prune(DateTime reference) {
    final DateTime cutoff = reference.subtract(_rollingWindow);
    _memory.removeWhere((TranscriptSegment s) => s.timestamp.isBefore(cutoff));
  }
}
