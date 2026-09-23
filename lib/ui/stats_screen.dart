import 'package:flutter/material.dart';

import '../coaching/weekly_stats.dart';

/// Màn hình **thống kê tuần** (P5 task 4 — mục 4.9): "số lần Push/buổi + xu hướng" để người dùng
/// **tự** quyết định có đổi Training Level hay không.
///
/// ⚠️ Màn hình này chỉ HIỂN THỊ. Không có, và sẽ không có, câu kiểu "bạn đã sẵn sàng lên cấp 3" —
/// mục 4.9 đã patch quyết định chuyển cấp thành hoàn toàn thủ công. Cấp độ hiện tại chỉ được nhắc lại
/// kèm đường dẫn tới nơi đổi (dropdown ở màn hình chính), để người dùng biết chỗ sửa mà không bị gợi ý.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, this.service, this.currentLevelLabel});

  /// Cho test bơm service giả; app dùng `WeeklyStatsService()`.
  final WeeklyStatsService? service;

  /// Nhãn cấp độ đang dùng (chỉ để hiển thị — màn hình này không đổi cấp).
  final String? currentLevelLabel;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  late final WeeklyStatsService _service = widget.service ?? WeeklyStatsService();

  WeeklyStats? _stats;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final WeeklyStats stats = await _service.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _stats = stats;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final WeeklyStats? stats = _stats;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Số liệu 7 ngày'),
        actions: <Widget>[
          IconButton(
            onPressed: () {
              setState(() => _loading = true);
              _load();
            },
            icon: const Icon(Icons.refresh),
            tooltip: 'Đọc lại',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : stats == null || !stats.available
              ? _unavailable(stats)
              : _content(stats),
    );
  }

  Widget _unavailable(WeeklyStats? stats) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          stats?.note ?? 'không đọc được số liệu',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );
  }

  Widget _content(WeeklyStats stats) {
    final String levelLabel = widget.currentLevelLabel ?? '(không rõ)';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('7 ngày gần nhất', style: Theme.of(context).textTheme.titleMedium),
                const Divider(height: 24),
                _row('Số buổi', '${stats.sessionCount}'),
                _row('Tổng số lần Push', '${stats.pushCount}'),
                _row('Push mỗi buổi', stats.pushesPerSession.toStringAsFixed(1)),
                _row(
                  'Xu hướng',
                  '${stats.trend.label} '
                      '(tuần trước: ${stats.previousPushCount} Push · '
                      '${stats.previousSessionCount} buổi)',
                ),
                const SizedBox(height: 8),
                Text(
                  'Xu hướng so theo ${stats.previousSessionCount > 0 && stats.sessionCount > 0 ? "Push mỗi buổi" : "tổng số lần Push"} '
                  '— chỉ là số liệu tham khảo.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Theo ngày', style: Theme.of(context).textTheme.titleMedium),
                const Divider(height: 24),
                if (stats.isEmpty)
                  const Text('Chưa có dữ liệu trong 7 ngày qua.')
                else
                  ...stats.days.map(_dayRow),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Cấp độ đang dùng', style: Theme.of(context).textTheme.titleMedium),
                const Divider(height: 24),
                Text(levelLabel),
                const SizedBox(height: 8),
                // Nói rõ quy tắc ngay tại chỗ người dùng hay thắc mắc nhất: app không tự đề xuất.
                const Text(
                  'App không tự đề xuất đổi cấp — bạn tự chọn ở màn hình chính khi thấy phù hợp.',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _dayRow(DayStat day) {
    final String label = '${day.day.day.toString().padLeft(2, '0')}/'
        '${day.day.month.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(width: 56, child: Text(label)),
          Expanded(
            child: Text(
              day.isEmpty ? '—' : '${day.sessions} buổi · ${day.pushes} Push',
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 140, child: Text(label)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
