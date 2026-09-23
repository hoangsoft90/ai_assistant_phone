import 'package:flutter/material.dart';

import '../coaching/post_review_service.dart';

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
          if (report.fromLlm)
            ...<Widget>[
              _section(context, 'Điều đã làm tốt', report.good, Icons.thumb_up_outlined),
              _section(context, 'Cơ hội bị bỏ lỡ', report.missed, Icons.lightbulb_outline),
              _section(context, 'Bài tập cho lần sau', report.exercise, Icons.fitness_center_outlined),
            ]
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Chưa tạo được nhận xét',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(report.note ?? 'không rõ lý do'),
                    if (report.rawText != null) ...<Widget>[
                      const SizedBox(height: 12),
                      const Text('Phản hồi nguyên văn từ LLM:'),
                      const SizedBox(height: 4),
                      SelectableText(report.rawText!),
                    ],
                  ],
                ),
              ),
            ),
          if (report.truncated)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Lưu ý: buổi nói dài nên chỉ phần CUỐI của transcript được phân tích.',
              ),
            ),
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

  Widget _section(BuildContext context, String title, String body, IconData icon) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(body),
          ],
        ),
      ),
    );
  }
}
