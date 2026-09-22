import 'dart:async';

import '../audio/asr/asr_engine.dart';
import '../core/app_logger.dart';
import '../core/constants.dart';
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
  })  : _dao = dao ?? const SqliteTranscriptDao(),
        _now = now ?? DateTime.now,
        _rollingWindow = rollingWindow ?? StorageConfig.transcriptRollingWindow,
        _resumeGap = resumeGap ?? StorageConfig.transcriptResumeGap,
        _retention = retention ?? StorageConfig.transcriptRetention;

  /// Bản dùng chung cho app (cùng kiểu với `AppDatabase.instance()`): `main()` gọi `init()` một lần
  /// lúc bootstrap, màn hình chính lấy lại đúng instance đó để `attach()` vào engine ASR.
  static TranscriptStore? _instance;

  static TranscriptStore instance() => _instance ??= TranscriptStore();

  static const AppLogger _log = AppLogger('TranscriptStore');

  final TranscriptDao _dao;
  final DateTime Function() _now;
  final Duration _rollingWindow;
  final Duration _resumeGap;
  final Duration _retention;

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

    final int removedSessions = await _dao.deleteOlderThan(now.subtract(_retention));
    if (removedSessions > 0) {
      _log.info(
        'đã xoá $removedSessions phiên transcript cũ hơn ${_retention.inDays} ngày (quyền riêng tư)',
      );
    }

    final TranscriptSession? latest = await _dao.latestSession();
    if (latest != null && now.difference(latest.lastActivityAt) <= _resumeGap) {
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
