import '../core/app_logger.dart';
import '../core/constants.dart';
import '../services/storage/secure_store.dart';
import '../services/storage/transcript_dao.dart';
import 'post_review_service.dart';

/// Kết quả một lượt **phân tích bù** (P5.4).
///
/// Trả cả [analyzed] LẪN [stoppedReason] thay vì chỉ một con số: UI phải phân biệt được ba tình huống
/// rất khác nhau — \"không có gì để làm\", \"đã làm xong N buổi\", và \"dừng giữa chừng vì lý do X\". Nếu
/// chỉ trả về `int` thì cả ba đều là `0` và người dùng sẽ không biết vì sao bấm nút mà không có gì
/// xảy ra.
class PendingAnalysisOutcome {
  /// Đã đi hết danh sách phiên còn thiếu báo cáo (không dừng sớm vì lỗi).
  const PendingAnalysisOutcome.done(this.analyzed) : stoppedReason = null;

  /// Dừng sớm — [stoppedReason] là lý do hiển thị được cho người dùng.
  const PendingAnalysisOutcome.stopped({required this.analyzed, required this.stoppedReason});

  /// Số phiên đã phân tích **THÀNH CÔNG** trong lượt này (có báo cáo dùng được + đã lưu).
  final int analyzed;

  /// Lý do dừng sớm (`null` = đã chạy hết danh sách).
  final String? stoppedReason;

  @override
  String toString() =>
      'PendingAnalysisOutcome(analyzed=$analyzed${stoppedReason == null ? '' : ', dừng: $stoppedReason'})';
}

/// **Phân tích bù cho các buổi còn thiếu báo cáo** (P5.4, phần C của prompt).
///
/// Vấn đề nó giải: phiên LUÔN được lưu + đánh dấu kết thúc độc lập với kết quả LLM (đúng ý người
/// dùng), nhưng nếu Post-Review thất bại đúng lúc bấm \"Kết thúc buổi\" (mất mạng, hết quota, timeout)
/// thì trước phase này **không có cơ chế nào chạy lại** — màn hình Lịch sử hiện \"chưa có báo cáo\"
/// vĩnh viễn.
///
/// Ràng buộc tự đặt (đều là quyết định có lý do, không phải thiếu sót):
/// - **Tuần tự, không song song** ([catchUp] `await` từng phiên): dồn nhiều request LLM cùng lúc sẽ ăn
///   quota/pin và làm chậm máy — trong khi đây vốn là việc \"làm dần cũng được\".
/// - **Không catch-up khi chưa có API key** (kiểm TRƯỚC khi lấy danh sách): tránh một lượt \"thử rồi
///   lỗi\" vô nghĩa, và quan trọng hơn là tránh ghi mốc throttle lên mọi phiên chỉ vì thiếu key.
/// - **Dừng cả lượt khi lỗi hạ tầng** ([PostReviewReport.infrastructureFailure]): mất mạng/thiếu key
///   thì mọi phiên còn lại cũng lỗi y hệt — thử tiếp chỉ tốn thời gian. Lỗi do nội dung riêng của một
///   phiên (LLM trả định dạng lạ) thì bỏ qua phiên đó và đi tiếp.
/// - **Không tạo Android background service/WorkManager mới**, không xin thêm quyền: \"chạy ngầm\" ở
///   đây nghĩa là chạy bất đồng bộ trong tiến trình app đang mở (đúng phạm vi hạ tầng hiện có).
class PendingAnalysisService {
  PendingAnalysisService({
    TranscriptDao? dao,
    PostReviewService? postReview,
    DateTime Function()? now,
    Future<bool> Function()? hasApiKey,
  })  : _dao = dao ?? const SqliteTranscriptDao(),
        _postReview = postReview ?? PostReviewService(),
        _now = now ?? DateTime.now,
        _hasApiKey = hasApiKey ?? SecureStore.hasLlmApiKey;

  static const AppLogger _log = AppLogger('PendingAnalysis');

  final TranscriptDao _dao;
  final PostReviewService _postReview;
  final DateTime Function() _now;

  /// Kiểm tra \"đã có API key chưa\" — inject được để test không cần keystore thật.
  final Future<bool> Function() _hasApiKey;

  /// Chạy một lượt phân tích bù. **Không bao giờ ném** — mọi lỗi quy về [PendingAnalysisOutcome].
  ///
  /// [limit] trần số phiên mỗi lượt (phiên cũ nhất trước) — xem
  /// [CoachingConfig.analysisCatchUpLimit] để biết vì sao có trần.
  Future<PendingAnalysisOutcome> catchUp({int limit = CoachingConfig.analysisCatchUpLimit}) async {
    if (!await _hasApiKey()) {
      _log.info('bỏ qua phân tích bù: chưa cấu hình API key');
      return const PendingAnalysisOutcome.stopped(
        analyzed: 0,
        stoppedReason: 'chưa có API key cho LLM',
      );
    }

    final List<TranscriptSession> pending;
    try {
      pending = await _dao.finishedSessionsWithoutReport(limit: limit);
    } catch (error, stackTrace) {
      _log.error('không đọc được danh sách phiên cần phân tích bù', error, stackTrace);
      return const PendingAnalysisOutcome.stopped(
        analyzed: 0,
        stoppedReason: 'lỗi đọc lịch sử phiên',
      );
    }
    if (pending.isEmpty) {
      _log.info('không có phiên nào cần phân tích bù');
      return const PendingAnalysisOutcome.done(0);
    }

    int analyzed = 0;
    for (final TranscriptSession session in pending) {
      // Ghi mốc THỬ trước khi gọi LLM: app bị OS kill giữa chừng thì lần mở kế tiếp vẫn phải chờ hết
      // throttle, không thử lại đúng phiên đó ngay lập tức. Ghi lỗi cũng không chặn việc phân tích.
      try {
        await _dao.markAnalysisAttempted(session.id, _now());
      } catch (error) {
        _log.warn('không ghi được mốc thử phân tích phiên #${session.id}: $error');
      }

      final PostReviewReport report = await _postReview.runForSession(session.id);
      if (report.isUsable) {
        analyzed++;
        continue;
      }
      if (report.infrastructureFailure) {
        _log.warn('dừng phân tích bù: lỗi hạ tầng — ${report.note}');
        return PendingAnalysisOutcome.stopped(
          analyzed: analyzed,
          stoppedReason: report.note ?? 'lỗi hạ tầng',
        );
      }
      _log.warn('phiên #${session.id} vẫn chưa có báo cáo: ${report.note}');
    }

    _log.info('phân tích bù xong: $analyzed/${pending.length} phiên có báo cáo');
    return PendingAnalysisOutcome.done(analyzed);
  }
}
