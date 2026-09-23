import 'package:flutter/material.dart';

import '../coaching/post_review_service.dart';
import 'report_sections.dart';

/// Màn hình **Post-Review** (P5 task 3 — mục 4.10): hiển thị báo cáo 3 mục sau khi kết thúc buổi.
///
/// Quy tắc hiển thị theo mục 4.10:
/// - 3 mục hiện ngay (đó là toàn bộ giá trị của tính năng);
/// - **dữ liệu chi tiết (transcript đầy đủ) ẩn mặc định**, mở bằng nút "xem chi tiết".
///
/// Không đọc DB, không gọi LLM: màn hình chỉ vẽ đúng những gì `PostReviewService` đã tạo (nhờ vậy nó
/// test được bằng `pumpWidget` mà không cần SQLite/mạng).
class PostReviewScreen extends StatelessWidget {
  const PostReviewScreen({
    super.key,
    required this.report,
    this.detailTranscript = '',
  });

  final PostReviewReport report;

  /// Transcript đầy đủ của buổi — chỉ hiện khi người dùng mở "xem chi tiết".
  final String detailTranscript;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nhận xét buổi vừa rồi')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          // P5.1: 3 mục báo cáo vẽ bởi widget dùng chung với màn hình xem lại từ Lịch sử.
          ReportSections(report: report),
          const SizedBox(height: 8),
          Text(
            'Phân tích trên ${report.segmentCount} dòng transcript của buổi này'
            '${report.generatedAt == null ? '' : ' · lúc ${_formatTime(report.generatedAt!)}'}. '
            'Toàn bộ transcript vẫn bị xoá tự động sau 7 ngày.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          // "Dữ liệu chi tiết ẩn mặc định" — dùng `ExpansionTile` để không phải thêm state/màn hình
          // riêng chỉ để giấu một khối text.
          ExpansionTile(
            title: const Text('Xem chi tiết transcript buổi này'),
            childrenPadding: const EdgeInsets.all(16),
            children: <Widget>[
              if (detailTranscript.trim().isEmpty)
                const Text('Không có dòng transcript nào trong buổi này.')
              else
                SelectableText(detailTranscript),
            ],
          ),
        ],
      ),
    );
  }

  /// Giờ:phút ngày/tháng (không dùng `intl` — thêm cả một package chỉ để format một dòng là thừa).
  static String _formatTime(DateTime moment) {
    final DateTime local = moment.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)} '
        '${two(local.day)}/${two(local.month)}';
  }
}
