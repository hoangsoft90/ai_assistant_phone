import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/app_logger.dart';
import '../core/constants.dart';
import '../suggestion/groq_llm_provider.dart';
import '../suggestion/llm_provider.dart';
import '../suggestion/suggestion_models.dart';
import '../services/storage/meta_store.dart';
import '../services/storage/transcript_dao.dart';
import '../transcript/transcript_store.dart';
import 'pre_brief.dart';

/// Nơi lưu báo cáo Post-Review dùng được (P5.1).
///
/// Tách interface (thay vì gọi `TranscriptDao` trực tiếp) để test `run()` không cần SQLite — cùng
/// cách `TranscriptDao`/`ConfigStore` đã làm từ P1D/P1E.
abstract class ReportSink {
  /// [report] đã mang `sessionId` — không truyền thêm tham số phiên riêng (tránh nguy cơ truyền
  /// lệch phiên so với dòng báo cáo).
  Future<void> save(PostReviewReportRow report);
}

/// Báo cáo Post-Review — đúng **3 mục** theo mục 4.10 của plan (thứ tự cố định: làm tốt → cơ hội bỏ
/// lỡ → bài tập).
class PostReviewReport {
  const PostReviewReport({
    required this.good,
    required this.missed,
    required this.exercise,
    required this.segmentCount,
    required this.truncated,
    required this.fromLlm,
    this.note,
    this.rawText,
    this.generatedAt,
    this.infrastructureFailure = false,
  });

  /// Báo cáo khi KHÔNG phân tích được (chưa có transcript / mất mạng / chưa có API key / LLM trả
  /// định dạng lạ). Cố ý vẫn trả một đối tượng báo cáo thay vì `null`: UI phải luôn nói được **lý do**
  /// cho người dùng, im lặng hoặc hiện lỗi kỹ thuật đều không chấp nhận được với một buổi đã bỏ ra.
  const PostReviewReport.unavailable({
    required this.note,
    this.segmentCount = 0,
    this.truncated = false,
    this.infrastructureFailure = false,
  })  : good = '',
        missed = '',
        exercise = '',
        fromLlm = false,
        rawText = null,
        generatedAt = null;

  /// 1 điều làm tốt.
  final String good;

  /// 1 cơ hội bị bỏ lỡ.
  final String missed;

  /// 1 bài tập gợi ý cho lần sau.
  final String exercise;

  /// Số dòng transcript tại thời điểm phân tích.
  final int segmentCount;

  /// Transcript đã bị cắt do vượt trần ký tự gửi LLM (phải nói rõ cho người dùng — xem
  /// `CoachingConfig.transcriptCharLimit`).
  final bool truncated;

  /// `true` khi 3 mục trên do LLM sinh; `false` khi không phân tích được (xem [note]).
  final bool fromLlm;

  /// Lý do không phân tích được (`null` khi [fromLlm]).
  final String? note;

  /// Văn bản thô LLM trả về khi nó **không** đúng định dạng JSON mong đợi — để phần "xem chi tiết"
  /// vẫn cho người dùng đọc được nội dung (thà đưa văn bản thô còn hơn vứt cả buổi phân tích).
  final String? rawText;

  /// Thời điểm phân tích xong (hiện trên UI để người dùng biết báo cáo thuộc buổi nào).
  final DateTime? generatedAt;

  /// **P5.4** — `true` khi lần phân tích thất bại vì **hạ tầng dùng chung** (thiếu API key, mất mạng,
  /// timeout, HTTP lỗi của endpoint), chứ không phải vì nội dung của riêng phiên này.
  ///
  /// Cần phân biệt để `PendingAnalysisService` biết khi nào phải **dừng cả lượt** phân tích bù: nếu
  /// nguyên nhân là hạ tầng thì mọi phiên còn lại cũng sẽ lỗi y hệt — thử tiếp chỉ tốn thời gian,
  /// pin và (với lỗi key/auth) cả quota API. Ngược lại, lỗi do nội dung phiên (LLM trả định dạng lạ)
  /// thì chỉ phiên đó hỏng, các phiên khác vẫn nên được thử.
  ///
  /// Mọi nhánh đi qua [SuggestionException] đều được coi là lỗi hạ tầng: provider hiện chỉ ném
  /// exception cho lỗi vận chuyển/cấu hình (thiếu key, mạng, timeout, HTTP ≠ 200) — còn lỗi nội dung
  /// được xử lý riêng ở tầng parse (không ném).
  final bool infrastructureFailure;

  bool get isUsable => fromLlm && good.isNotEmpty && missed.isNotEmpty && exercise.isNotEmpty;

  @override
  String toString() => fromLlm
      ? 'PostReviewReport(fromLlm · $segmentCount dòng${truncated ? ' (cắt)' : ''})'
      : 'PostReviewReport(không phân tích được: $note)';
}

/// Post-Review (P5 task 3) — lớp "học hỏi sau" khép kín vòng lặp Pre-Brief → phiên → nhận xét.
///
/// ⚠️ **Sai khác so với `.plan/prompt_P5.md` (có lý do, xem `.plan/P5-result.md`)**: prompt P5 yêu cầu
/// gửi transcript lên **ASR cloud** (Groq Whisper/Deepgram). Bước đó **không được làm** vì:
/// 1. Ràng buộc cứng #4 (`.project/overview.md`): *audio hội thoại KHÔNG được gửi lên cloud*, và
///    `WavSink` ghi rõ app **không** ghi audio ra đĩa ⇒ không có audio nào để gửi (muốn có phải bật
///    ghi audio cho cả phiên — thay đổi quyết định riêng tư, không thuộc phạm vi một phase tính năng).
/// 2. ASR cloud **không nhận text**, nên "gửi transcript lên ASR" cũng không phải một phép toán hợp lệ.
/// ⇒ Phần phân tích chạy trên **transcript đã bóc băng ngay trên máy** (text) — đúng thứ duy nhất
/// được phép rời thiết bị. Đổi lại: không cần `connectivity_plus`, không cần chờ Wi-Fi (vài KB text,
/// cùng mức với Suggestion Engine P2 vốn dùng cả 4G), và **không phát sinh dữ liệu lưu trữ mới** nên
/// hạn 7 ngày của P1E không phải mở rộng.
///
/// Không bao giờ ném (cùng hợp đồng với `SuggestionService.push`).
class PostReviewService {
  PostReviewService({
    TextLlmProvider? provider,
    TranscriptStore? transcript,
    PreBriefStore? preBriefs,
    DateTime Function()? now,
    this.maxTokens = 500,
    ConfigStore? llmConfigStore,
    ReportSink? reportSink,
    TranscriptDao? transcriptDao,
    http.Client? llmClient,
    Future<String?> Function()? llmApiKeyReader,
  })  : _provider = provider ??
            GroqLlmProvider(
              client: llmClient,
              apiKeyReader: llmApiKeyReader,
              configStore: llmConfigStore,
              // P5.4: Post-Review KHÔNG chặn cuộc trò chuyện (chạy sau khi đối tác đã về) ⇒ dùng mốc 5
              // phút, KHÔNG phải 4s của Push. Trước phase này nó thừa hưởng mặc định 4s và bị cắt
              // ngang khi LLM phản hồi chậm.
              timeout: SuggestionConfig.postReviewTimeout,
            ),
        _transcript = transcript ?? TranscriptStore.instance(),
        _preBriefs = preBriefs ?? PreBriefStore.instance(),
        _now = now ?? DateTime.now,
        _reportSink = reportSink ?? const SqliteReportSink(),
        _transcriptDao = transcriptDao ?? const SqliteTranscriptDao();

  static const AppLogger _log = AppLogger('PostReview');

  final TextLlmProvider _provider;
  final TranscriptStore _transcript;
  final PreBriefStore _preBriefs;
  final DateTime Function() _now;

  /// P5.4: đọc transcript của **phiên bất kỳ** (không phải phiên đang mở) khi phân tích lại các buổi
  /// đã kết thúc mà chưa có báo cáo. Tách khỏi [_transcript] vì `TranscriptStore` chỉ đọc được phiên
  /// hiện tại — dùng lầm nó cho việc này sẽ phân tích nhầm phiên.
  final TranscriptDao _transcriptDao;

  /// Nơi lưu báo cáo dùng được (P5.1) — tách interface để test không cần SQLite.
  final ReportSink _reportSink;

  /// Trần token cho mỗi lần phân tích (3 mục, mỗi mục một câu).
  final int maxTokens;

  int _runCount = 0;

  /// Số lần đã chạy Post-Review trong vòng đời đối tượng (bằng chứng trên UI chẩn đoán).
  int get runCount => _runCount;

  /// Phân tích buổi vừa kết thúc trên **transcript của phiên hiện tại**. Không bao giờ ném.
  ///
  /// Đọc transcript TRƯỚC khi caller tắt phiên/đổi phiên transcript (dữ liệu nằm trong phiên đang mở
  /// của `TranscriptStore`), nên caller phải gọi hàm này khi phiên transcript còn là phiên vừa nói.
  Future<PostReviewReport> run() async {
    _runCount++;
    final SessionTranscript transcript;
    try {
      transcript = await _transcript.sessionTranscript();
    } catch (error, stackTrace) {
      _log.error('không đọc được transcript cho Post-Review', error, stackTrace);
      return const PostReviewReport.unavailable(note: 'lỗi đọc transcript');
    }
    if (transcript.isEmpty) {
      return const PostReviewReport.unavailable(note: 'phiên này chưa có dòng transcript nào');
    }

    return _analyze(
      transcript.text,
      sessionId: _transcript.sessionId,
      segmentCount: transcript.segmentCount,
      truncated: transcript.truncated,
    );
  }

  /// Phân tích lại **một phiên đã kết thúc** bất kỳ (P5.4) — dùng cho việc "chạy bù" các buổi mà
  /// Post-Review lúc "Kết thúc buổi" đã thất bại (mất mạng/hết pin API/timeout).
  ///
  /// Khác [run] đúng ở **nguồn transcript**: đọc qua `TranscriptDao.fullSessionText(sessionId)` thay
  /// vì `TranscriptStore` — phiên cần phân tích lại không phải phiên đang mở (thường là buổi hôm
  /// trước), nên không thể đi qua cửa sổ phiên hiện tại. Phần build prompt / gọi LLM / parse / lưu
  /// dùng CHUNG hàm [_analyze] với [run], nên "phân tích ngay" và "phân tích lại sau" không thể lệch
  /// hành vi. Cùng hợp đồng với [run]: **không bao giờ ném**.
  Future<PostReviewReport> runForSession(int sessionId) async {
    _runCount++;
    final SessionText dump;
    try {
      dump = await _transcriptDao.fullSessionText(sessionId);
    } catch (error, stackTrace) {
      _log.error('không đọc được transcript của phiên #$sessionId', error, stackTrace);
      return const PostReviewReport.unavailable(note: 'lỗi đọc transcript');
    }
    if (dump.isEmpty) {
      return const PostReviewReport.unavailable(note: 'phiên này chưa có dòng transcript nào');
    }
    return _analyze(
      dump.text,
      sessionId: sessionId,
      segmentCount: dump.segmentCount,
      truncated: dump.truncated,
    );
  }

  /// Phần dùng chung của [run] và [runForSession]: prompt → LLM → parse → lưu. Không bao giờ ném.
  ///
  /// [sessionId] là phiên mà báo cáo sẽ được gắn vào; `null` = phiên transcript chưa mở (khi đó
  /// vẫn trả báo cáo cho UI, chỉ không lưu được — xem [_persist]).
  Future<PostReviewReport> _analyze(
    String text, {
    required int? sessionId,
    required int segmentCount,
    required bool truncated,
  }) async {
    final String prompt = buildPrompt(
      transcript: text,
      preBrief: _preBriefs.current.toPromptValue(),
      truncated: truncated,
    );
    final String raw;
    try {
      raw = await _provider.complete(prompt: prompt, maxTokens: maxTokens);
    } on SuggestionException catch (error) {
      _log.warn('Post-Review không gọi được LLM: ${error.message}');
      // P5.4: lỗi từ provider luôn là lỗi HẠ TẦNG (key/mạng/timeout/HTTP) — phiên khác cũng sẽ lỗi
      // y hệt ⇒ lượt phân tích bù phải dừng, xem `PendingAnalysisService`.
      return PostReviewReport.unavailable(
        note: error.message,
        segmentCount: segmentCount,
        truncated: truncated,
        infrastructureFailure: true,
      );
    } catch (error, stackTrace) {
      _log.error('Post-Review lỗi ngoài dự kiến', error, stackTrace);
      return PostReviewReport.unavailable(
        note: 'lỗi không xác định',
        segmentCount: segmentCount,
        truncated: truncated,
        infrastructureFailure: true,
      );
    }

    final PostReviewReport? parsed = tryParseReport(
      raw,
      segmentCount: segmentCount,
      truncated: truncated,
      generatedAt: _now(),
    );
    if (parsed == null) {
      // Lỗi do NỘI DUNG phiên này (LLM trả định dạng lạ) ⇒ KHÔNG phải lỗi hạ tầng: các phiên khác
      // vẫn nên được thử trong cùng lượt phân tích bù.
      _log.warn('LLM trả định dạng lạ cho Post-Review — giữ văn bản thô');
      return PostReviewReport(
        good: '',
        missed: '',
        exercise: '',
        segmentCount: segmentCount,
        truncated: truncated,
        fromLlm: false,
        note: 'LLM trả định dạng lạ (không phải JSON 3 mục)',
        rawText: raw,
      );
    }
    // Log chỉ ghi SỐ LIỆU, không ghi nội dung (nội dung sinh từ hội thoại thật — quyết định từ P2).
    _log.info(
      'Post-Review xong: $segmentCount dòng${truncated ? ' (transcript đã cắt)' : ''}',
    );

    // P5.1: lưu báo cáo dùng được để xem lại từ màn hình Lịch sử. GHI TRƯỚC khi caller đổi phiên
    // transcript (report được gắn với `sessionId` hiện tại — đúng dữ liệu vừa phân tích). Việc lưu
    // lỗi KHÔNG được làm hỏng trải nghiệm Post-Review: vẫn trả báo cáo cho UI như bình thường.
    await _persist(parsed, sessionId: sessionId, segmentCount: segmentCount, truncated: truncated);

    return parsed;
  }

  /// Lưu báo cáo vào DB (P5.1). Chỉ lưu khi `isUsable` — báo cáo `unavailable`/thiếu mục không có
  /// giá trị xem lại, chỉ gây nhiễu Lịch sử. KHÔNG BAO GIỜ ném: DB đầy/lỗi chỉ được log.
  Future<void> _persist(
    PostReviewReport report, {
    required int? sessionId,
    required int segmentCount,
    required bool truncated,
  }) async {
    if (!report.isUsable) {
      return;
    }
    if (sessionId == null) {
      _log.warn('không lưu được báo cáo: phiên transcript chưa mở');
      return;
    }
    try {
      await _reportSink.save(
        PostReviewReportRow(
          sessionId: sessionId,
          generatedAt: report.generatedAt ?? _now(),
          good: report.good,
          missed: report.missed,
          exercise: report.exercise,
          segmentCount: segmentCount,
          truncated: truncated,
        ),
      );
    } catch (error, stackTrace) {
      _log.error('không lưu được báo cáo Post-Review (bỏ qua — trải nghiệm không đổi)', error, stackTrace);
    }
  }

  /// Parse output LLM thành báo cáo 3 mục; trả `null` khi không đúng định dạng.
  ///
  /// Đọc bằng `is` (không cast cứng — bài học A50). Một mục rỗng bị coi là **không đúng định dạng**:
  /// báo cáo thiếu mục thì không còn đúng "đúng 3 mục" của mục 4.10, và người dùng sẽ thấy ô trống
  /// không biết vì sao.
  static PostReviewReport? tryParseReport(
    String raw, {
    required int segmentCount,
    required bool truncated,
    required DateTime generatedAt,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(stripCodeFence(raw.trim()));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    // Gán ra biến mới thay vì đọc `decoded[...]` trong closure: type-promotion KHÔNG đi vào trong
    // closure của một biến local (dù biến đó `final`), nên đọc trực tiếp sẽ là lỗi biên dịch
    // `unchecked_use_of_nullable_value`.
    final Map<String, dynamic> map = decoded;
    String item(String key) {
      final Object? value = map[key];
      return value is String ? value.trim() : '';
    }

    final String good = item('good');
    final String missed = item('missed');
    final String exercise = item('exercise');
    if (good.isEmpty || missed.isEmpty || exercise.isEmpty) {
      return null;
    }
    return PostReviewReport(
      good: good,
      missed: missed,
      exercise: exercise,
      segmentCount: segmentCount,
      truncated: truncated,
      fromLlm: true,
      generatedAt: generatedAt,
    );
  }

  /// Prompt Post-Review (mục 4.10). `static` để test khoá được yêu cầu về **đúng 3 mục**.
  ///
  /// Tông giọng được yêu cầu rõ ràng: người dùng là người lo âu xã hội, báo cáo để *học*, không phải
  /// để tự trách — không có yêu cầu này thì model rất dễ viết kiểu phê bình.
  static String buildPrompt({
    required String transcript,
    required String preBrief,
    required bool truncated,
  }) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('Bạn là huấn luyện viên giao tiếp cho một người ít nói, hay lo âu xã hội.')
      ..writeln('Dưới đây là transcript buổi nói chuyện vừa kết thúc (KHÔNG nhãn người nói, hãy tự')
      ..writeln('suy luận ai nói dựa vào ngữ cảnh).')
      ..writeln();
    if (preBrief.trim().isNotEmpty) {
      buffer
        ..writeln('Ngữ cảnh người dùng đã chuẩn bị trước buổi:')
        ..writeln(preBrief)
        ..writeln();
    }
    if (truncated) {
      buffer
        ..writeln('LƯU Ý: transcript đã bị cắt bớt (chỉ còn phần cuối buổi). Đừng khẳng định điều gì')
        ..writeln('về phần đầu buổi.')
        ..writeln();
    }
    buffer
      ..writeln('Hãy đưa ra ĐÚNG 3 mục, mỗi mục MỘT câu ngắn, cụ thể, gắn với chi tiết trong')
      ..writeln('transcript (không khen/chê chung chung):')
      ..writeln('- good: một điều người dùng đã làm tốt')
      ..writeln('- missed: một cơ hội bị bỏ lỡ')
      ..writeln('- exercise: một bài tập gợi ý cho lần sau')
      ..writeln()
      ..writeln('Giọng điệu trung tính, không phán xét, không tự trách.')
      ..writeln('Chỉ trả về JSON đúng format:')
      ..writeln('{"good":"...","missed":"...","exercise":"..."}')
      ..writeln()
      ..writeln('Transcript:')
      ..writeln(transcript);
    return buffer.toString();
  }
}

/// Bản thật: ghi bảng `post_review_reports` qua `TranscriptDao.saveReport` (đơn thuần uỷ quyền —
/// DAO mới là nơi nắm schema/transaction; service không đụng SQL).
class SqliteReportSink implements ReportSink {
  const SqliteReportSink();

  @override
  Future<void> save(PostReviewReportRow report) =>
      const SqliteTranscriptDao().saveReport(report.sessionId, report);
}
