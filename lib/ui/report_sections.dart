import 'package:flutter/material.dart';

import '../coaching/post_review_service.dart';

/// Phần hiển thị **3 mục báo cáo Post-Review** tách ra từ `PostReviewScreen` (P5.1).
///
/// Hai nơi dùng chung đúng một bản vẽ: "vừa phân tích xong" (`PostReviewScreen`) và "xem lại từ
/// Lịch sử" (`ReportDetailScreen`) — tránh trùng code phải sửa 2 chỗ khi đổi cách hiển thị.
class ReportSections extends StatelessWidget {
  const ReportSections({super.key, required this.report});

  final PostReviewReport report;

  @override
  Widget build(BuildContext context) {
    return Column(
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
      ],
    );
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
