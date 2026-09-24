import 'dart:async';

import 'package:flutter/material.dart';

import '../coaching/pending_analysis_service.dart';
import '../coaching/post_review_service.dart';
import '../services/storage/transcript_dao.dart';
import '../transcript/session_display_name.dart';
import 'report_sections.dart';

/// Màn hình **Lịch sử phiên** (P5.1): liệt kê các buổi đã qua + trạng thái báo cáo Post-Review,
/// bấm vào để xem lại báo cáo đã lưu.
///
/// P5.2: mỗi dòng hiện **tên phiên** (tên người dùng đặt, hoặc tên mặc định sinh từ thời gian bắt
/// đầu — xem `SessionDisplayName`) và có nút **đổi tên**.
///
/// Không có thao tác xoá/sửa nội dung ở đây: dữ liệu được xoá **duy nhất** bởi cơ chế tự xoá theo
/// hạn retention (mục 5.3 — quyền riêng tư). Người dùng không tự xoá từng dòng — tránh trạng thái
/// "vì sao mất dữ liệu" không đoán được.
///
/// **P5.4:** thêm nút "Phân tích lại các buổi còn thiếu" trên AppBar — cùng service mà lúc mở app tự
/// chạy, để người dùng chủ động chạy bù ngay khi cần thay vì chờ lần mở app sau.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.dao, this.pendingAnalysis});

  /// Cho test bơm DAO giả; app dùng `SqliteTranscriptDao()`.
  final TranscriptDao? dao;

  /// Cho test bơm service giả (P5.4); app dùng `PendingAnalysisService()` thật.
  final PendingAnalysisService? pendingAnalysis;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final TranscriptDao _dao = widget.dao ?? const SqliteTranscriptDao();
  late final PendingAnalysisService _pendingAnalysis =
      widget.pendingAnalysis ?? PendingAnalysisService();

  List<TranscriptSession>? _sessions;
  final Set<int> _withReport = <int>{};
  String? _error;

  /// Đang chạy phân tích bù (P5.4) — vừa là dấu hiệu trên icon, vừa chặn bấm chồng (mỗi lượt có thể
  /// mất tới 5 phút/phiên theo `SuggestionConfig.postReviewTimeout`).
  bool _catchingUp = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final List<TranscriptSession> sessions = await _dao.allSessions();
      // P5.1 review: một query `sessionIdsWithReport()` thay vì N+1 lần `reportForSession` —
      // 100 phiên trước đây là 101 query, giờ là 2 query không phụ thuộc số phiên.
      final Set<int> withReport = await _dao.sessionIdsWithReport();
      if (!mounted) {
        return;
      }
      setState(() {
        _sessions = sessions;
        _withReport
          ..clear()
          ..addAll(withReport);
        _error = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'không đọc được lịch sử: $error';
        _sessions = const <TranscriptSession>[];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<TranscriptSession>? sessions = _sessions;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lịch sử phiên'),
        actions: <Widget>[
          IconButton(
            onPressed: _catchingUp ? null : () => unawaited(_catchUp()),
            icon: _catchingUp
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high_outlined),
            tooltip: 'Phân tích lại các buổi còn thiếu',
          ),
          IconButton(
            onPressed: () {
              setState(() => _sessions = null);
              _load();
            },
            icon: const Icon(Icons.refresh),
            tooltip: 'Đọc lại',
          ),
        ],
      ),
      body: sessions == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
              : sessions.isEmpty
                  ? const Center(child: Text('Chưa có buổi nào được ghi lại.'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: sessions.length,
                      itemBuilder: (BuildContext context, int index) {
                        final TranscriptSession session = sessions[index];
                        final bool hasReport = _withReport.contains(session.id);
                        return ListTile(
                          leading: Icon(
                            hasReport ? Icons.description_outlined : Icons.notes_outlined,
                          ),
                          title: Text(SessionDisplayName.of(session)),
                          subtitle: Text(
                            hasReport
                                ? 'có nhận xét cuối buổi — bấm để xem lại'
                                : 'chưa có báo cáo',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: 'Đổi tên buổi',
                            onPressed: () => unawaited(_rename(session)),
                          ),
                          // Chỉ mở chi tiết khi CÓ báo cáo; không có thì không mở màn hình trống.
                          onTap: hasReport
                              ? () => unawaited(_openReport(session))
                              : () => _enqueueNoReportSnack(),
                        );
                      },
                    ),
    );
  }

  /// **Phân tích lại các buổi còn thiếu báo cáo** (P5.4) — chạy đúng service mà lúc mở app tự chạy,
  /// rồi đọc lại danh sách để chú thích "có nhận xét cuối buổi" cập nhật ngay.
  ///
  /// Mỗi tình huống có một câu khác nhau (xem `PendingAnalysisOutcome`): người dùng phải phân biệt
  /// được "không có gì để làm" với "đã làm N buổi" với "dừng vì lý do X" — nếu không, bấm nút mà
  /// không thấy gì sẽ bị hiểu là nút hỏng.
  Future<void> _catchUp() async {
    setState(() => _catchingUp = true);
    PendingAnalysisOutcome? outcome;
    String? failure;
    try {
      outcome = await _pendingAnalysis.catchUp();
    } catch (error) {
      // Hợp đồng của service là không ném; giữ lưới an toàn để UI không bao giờ treo ở trạng thái
      // "đang chạy" vì một lỗi ngoài dự kiến.
      failure = '$error';
    }
    if (!mounted) {
      return;
    }
    setState(() => _catchingUp = false);
    // Biến `final` cục bộ: `outcome` được gán trong `try` nên analyzer không promote nó sau đó.
    final PendingAnalysisOutcome? result = outcome;
    final String message;
    if (result == null) {
      message = 'Không phân tích lại được: $failure';
    } else if (result.analyzed > 0) {
      message = result.stoppedReason == null
          ? 'Đã phân tích lại ${result.analyzed} buổi.'
          : 'Đã phân tích lại ${result.analyzed} buổi. Dừng lại: ${result.stoppedReason}';
    } else if (result.stoppedReason != null) {
      message = 'Không phân tích lại được: ${result.stoppedReason}';
    } else {
      message = 'Không có buổi nào cần phân tích.';
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    await _load();
  }

  void _enqueueNoReportSnack() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Phiên này chưa có báo cáo.')),
    );
  }

  /// Đổi tên phiên (P5.2). Ô nhập điền sẵn **tên đang hiển thị** (nên xoá hết = quay về tên mặc
  /// định, không cần nhớ tên gốc). Lưu xong cập nhật ngay tại chỗ — không đọc lại cả danh sách.
  Future<void> _rename(TranscriptSession session) async {
    final String current = SessionDisplayName.of(session);
    // `TextFormField.initialValue` (không dùng `TextEditingController`) — tránh phải dispose sau
    // dialog, cùng bài học đã áp dụng cho dialog API key / cấu hình LLM.
    String typed = current;
    final String? entered = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Đổi tên buổi'),
        content: TextFormField(
          initialValue: current,
          autofocus: true,
          maxLength: SessionDisplayName.maxLength,
          onChanged: (String value) => typed = value,
          decoration: const InputDecoration(
            labelText: 'Tên buổi',
            helperText: 'Để trống để quay về tên mặc định theo thời gian.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            // Trả nguyên chuỗi người dùng gõ (kể cả rỗng) — rỗng = xoá tên tự đặt, KHÔNG phải huỷ.
            onPressed: () => Navigator.of(dialogContext).pop(typed),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    if (entered == null || !mounted) {
      return;
    }
    final String? title = SessionDisplayName.normalize(entered);
    try {
      await _dao.renameSession(session.id, title);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không đổi được tên: $error')),
        );
      }
      return;
    }
    if (!mounted) {
      return;
    }
    final List<TranscriptSession>? sessions = _sessions;
    if (sessions == null) {
      return;
    }
    setState(() {
      _sessions = <TranscriptSession>[
        for (final TranscriptSession s in sessions)
          s.id == session.id
              ? TranscriptSession(
                  id: s.id,
                  startedAt: s.startedAt,
                  lastActivityAt: s.lastActivityAt,
                  title: title,
                )
              : s,
      ];
    });
  }

  Future<void> _openReport(TranscriptSession session) async {
    final NavigatorState navigator = Navigator.of(context);
    try {
      final PostReviewReportRow? row = await _dao.reportForSession(session.id);
      if (!mounted) {
        return;
      }
      if (row == null) {
        _enqueueNoReportSnack();
        return;
      }
      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext _) => ReportDetailScreen(session: session, row: row),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không mở được báo cáo: $error')),
        );
      }
    }
  }
}

/// Màn hình **xem lại báo cáo đã lưu** (P5.1) — tái dùng đúng widget 3 mục của `PostReviewScreen`.
///
/// P5.2: tiêu đề dùng **tên phiên** (giống danh sách Lịch sử) để người dùng biết đang xem buổi nào.
class ReportDetailScreen extends StatelessWidget {
  const ReportDetailScreen({super.key, required this.session, required this.row});

  final TranscriptSession session;
  final PostReviewReportRow row;

  @override
  Widget build(BuildContext context) {
    final PostReviewReport report = PostReviewReport(
      good: row.good,
      missed: row.missed,
      exercise: row.exercise,
      segmentCount: row.segmentCount,
      truncated: row.truncated,
      fromLlm: true,
      generatedAt: row.generatedAt,
    );
    return Scaffold(
      appBar: AppBar(title: Text(SessionDisplayName.of(session))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          ReportSections(report: report),
          const SizedBox(height: 8),
          Text(
            'Báo cáo đã lưu lúc ${SessionDisplayName.timestamp(row.generatedAt)} · '
            'phiên #${row.sessionId}. Sẽ tự xoá theo hạn trong Cài đặt (mặc định 7 ngày).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
