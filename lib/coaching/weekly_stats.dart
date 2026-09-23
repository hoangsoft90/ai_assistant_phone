import '../core/app_logger.dart';
import '../services/storage/transcript_dao.dart';

/// Xu hướng tuần này so với tuần trước (mục 4.9: app chỉ **hiển thị** xu hướng để người dùng tự quyết
/// định, không tự đề xuất đổi cấp).
enum StatsTrend {
  up('tăng'),
  down('giảm'),
  flat('không đổi');

  const StatsTrend(this.label);

  final String label;
}

/// Số liệu của một ngày trong tuần.
class DayStat {
  const DayStat({required this.day, required this.sessions, required this.pushes});

  /// Đầu ngày (local).
  final DateTime day;

  final int sessions;
  final int pushes;

  bool get isEmpty => sessions == 0 && pushes == 0;

  @override
  String toString() => 'DayStat(${day.day}/${day.month}: $sessions phiên, $pushes Push)';
}

/// Số liệu tham khảo 7 ngày gần nhất (P5 task 4 — mục 4.9).
///
/// ⚠️ Bất biến: lớp này **chỉ đếm**. Không có ngưỡng, không có "đủ tốt để nâng cấp" ở đây hay ở UI —
/// quyết định chuyển cấp hoàn toàn thủ công (mục 4.9 đã patch). Nếu phase sau cần thêm gợi ý tự động,
/// đó là thay đổi quyết định, không phải thêm một dòng vào file này.
class WeeklyStats {
  const WeeklyStats({
    required this.sessionCount,
    required this.pushCount,
    required this.pushesPerSession,
    required this.previousSessionCount,
    required this.previousPushCount,
    required this.previousPushesPerSession,
    required this.days,
    this.note,
  });

  /// Không đọc được số liệu (DB lỗi). UI phải hiện [note] thay vì "0 phiên" — số 0 giả sẽ bị hiểu
  /// là "tuần này không nói chuyện gì", hoàn toàn khác nghĩa với "không đọc được dữ liệu".
  const WeeklyStats.unavailable(this.note)
      : sessionCount = 0,
        pushCount = 0,
        pushesPerSession = 0,
        previousSessionCount = 0,
        previousPushCount = 0,
        previousPushesPerSession = 0,
        days = const <DayStat>[];

  /// Số phiên trong 7 ngày gần nhất.
  final int sessionCount;

  /// Tổng số lần Push trong 7 ngày gần nhất.
  final int pushCount;

  /// Push/buổi trung bình (0 nếu tuần này không có phiên) — đúng con số mục 4.9 yêu cầu hiển thị.
  final double pushesPerSession;

  /// Tuần liền trước (7 ngày trước đó) để so xu hướng.
  final int previousSessionCount;
  final int previousPushCount;
  final double previousPushesPerSession;

  /// 7 ngày, **cũ → mới**, luôn đủ 7 phần tử (ngày không có gì vẫn xuất hiện với số 0 để người đọc
  /// thấy khoảng trống, thay vì một danh sách co giãn khó so sánh).
  final List<DayStat> days;

  /// Lý do không đọc được số liệu (`null` khi đọc thành công).
  final String? note;

  bool get available => note == null;

  bool get isEmpty => available && sessionCount == 0 && pushCount == 0;

  /// Xu hướng dựa trên **Push/buổi** nếu CẢ HAI tuần đều có phiên (so sánh có nghĩa); nếu tuần trước
  /// không có phiên nào thì so tổng Push, và khi cả hai bằng 0 thì là [StatsTrend.flat].
  ///
  /// Vì sao không luôn so tổng Push: người dùng nói chuyện nhiều hơn nhưng bấm ít hơn là tiến bộ —
  /// dùng tổng sẽ báo "giảm" sai hướng. Đổi lại phải nói rõ cơ sở so sánh trên UI.
  StatsTrend get trend {
    if (previousSessionCount > 0 && sessionCount > 0) {
      return _compare(pushesPerSession, previousPushesPerSession);
    }
    return _compare(pushCount.toDouble(), previousPushCount.toDouble());
  }

  static StatsTrend _compare(double now, double before) {
    if (now > before) {
      return StatsTrend.up;
    }
    if (now < before) {
      return StatsTrend.down;
    }
    return StatsTrend.flat;
  }

  @override
  String toString() => available
      ? 'WeeklyStats($sessionCount phiên · $pushCount Push · '
          '${pushesPerSession.toStringAsFixed(1)} Push/buổi · xu hướng ${trend.label})'
      : 'WeeklyStats(không đọc được: $note)';
}

/// Đọc số liệu thống kê tuần từ SQLite và gộp thành [WeeklyStats].
///
/// Tách khỏi UI để gộp số liệu là logic thuần — test được bằng `TranscriptDao` giả, không cần SQLite
/// (cùng cách `AsrEngineSelector`/`PreBriefStore` đã làm).
class WeeklyStatsService {
  WeeklyStatsService({TranscriptDao? dao, DateTime Function()? now})
      : _dao = dao ?? const SqliteTranscriptDao(),
        _now = now ?? DateTime.now;

  static const AppLogger _log = AppLogger('WeeklyStats');

  /// Số ngày của cửa sổ thống kê (7 ngày gần nhất, gồm hôm nay) — mục 4.9: "số liệu tham khảo mỗi tuần".
  static const int windowDays = 7;

  final TranscriptDao _dao;
  final DateTime Function() _now;

  /// Đọc số liệu. Không bao giờ ném — lỗi DB quy về [WeeklyStats.unavailable] (màn hình thống kê không
  /// được làm sập app).
  Future<WeeklyStats> load() async {
    final DateTime now = _now();
    final DateTime today = _startOfDay(now);
    final DateTime weekStart = today.subtract(const Duration(days: windowDays - 1));
    final DateTime previousWeekStart = weekStart.subtract(const Duration(days: windowDays));

    try {
      // Truy vấn rộng theo `lastActivityAt` (xem doc của `sessionsSince`) rồi phân loại tuần/ngày bằng
      // `startedAt` — ngày mà người dùng *bắt đầu* nói là ngày họ nhớ.
      final List<TranscriptSession> sessions = await _dao.sessionsSince(previousWeekStart);
      final List<TranscriptPush> pushes = await _dao.pushesSince(previousWeekStart);

      final List<TranscriptSession> thisWeekSessions = sessions
          .where((TranscriptSession s) => !s.startedAt.isBefore(weekStart))
          .toList();
      final List<TranscriptSession> previousSessions = sessions
          .where((TranscriptSession s) =>
              !s.startedAt.isBefore(previousWeekStart) && s.startedAt.isBefore(weekStart))
          .toList();

      int countPushes(DateTime? from, DateTime? to) => pushes
          .where((TranscriptPush p) =>
              (from == null || !p.at.isBefore(from)) && (to == null || p.at.isBefore(to)))
          .length;

      final int thisWeekPushes = countPushes(weekStart, null);
      final int previousPushes = countPushes(previousWeekStart, weekStart);

      final List<DayStat> days = <DayStat>[];
      for (int i = 0; i < windowDays; i++) {
        final DateTime day = weekStart.add(Duration(days: i));
        final DateTime dayEnd = day.add(const Duration(days: 1));
        days.add(
          DayStat(
            day: day,
            sessions: thisWeekSessions
                .where((TranscriptSession s) =>
                    !s.startedAt.isBefore(day) && s.startedAt.isBefore(dayEnd))
                .length,
            pushes: pushes
                .where((TranscriptPush p) => !p.at.isBefore(day) && p.at.isBefore(dayEnd))
                .length,
          ),
        );
      }

      return WeeklyStats(
        sessionCount: thisWeekSessions.length,
        pushCount: thisWeekPushes,
        pushesPerSession:
            thisWeekSessions.isEmpty ? 0 : thisWeekPushes / thisWeekSessions.length,
        previousSessionCount: previousSessions.length,
        previousPushCount: previousPushes,
        previousPushesPerSession:
            previousSessions.isEmpty ? 0 : previousPushes / previousSessions.length,
        days: days,
      );
    } catch (error, stackTrace) {
      _log.error('không đọc được số liệu tuần', error, stackTrace);
      return WeeklyStats.unavailable('lỗi đọc dữ liệu: $error');
    }
  }

  static DateTime _startOfDay(DateTime moment) {
    final DateTime local = moment.toLocal();
    return DateTime(local.year, local.month, local.day);
  }
}
