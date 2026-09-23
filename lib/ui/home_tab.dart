import 'package:flutter/material.dart';

import 'session_coordinator.dart';

/// Tab **Trang chủ** (P5.3) — nội dung rút gọn của `home_screen.dart` cũ:
///
/// - Card trạng thái rút gọn: chỉ các dòng người dùng cuối thật sự cần theo dõi khi đang dùng.
/// - Mọi dòng chẩn đoán kỹ thuật CÒN LẠI gom vào "Chi tiết kỹ thuật" ([ExpansionTile], mặc định
///   ĐÓNG) — **không xoá dòng nào** (constraint của prompt P5.3): app vẫn đang ở giai đoạn test
///   thực địa, các dòng này vẫn cần để debug khi có sự cố, chỉ không phải thứ đập vào mắt trước.
/// - KHÔNG có nút điều khiển phiên ở đây (Bắt đầu/Kết thúc/Làm mới đã chuyển thành nổi toàn cục
///   trong `GlobalFloatingControls`) — tránh trùng lặp 2 nơi cùng 1 hành động.
class HomeTab extends StatelessWidget {
  const HomeTab({super.key, required this.coordinator});

  final SessionCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: coordinator,
      builder: (BuildContext context, Widget? _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text(
              coordinator.session.isActive ? 'Đang lắng nghe' : 'Sẵn sàng',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            _summaryCard(context),
            const SizedBox(height: 16),
            // P5 task 1: Pre-Brief của buổi — dữ liệu này thay `{pre_brief}` rỗng của P2 trong prompt.
            OutlinedButton.icon(
              onPressed: coordinator.busy
                  ? null
                  : () => coordinator.openPreBrief(context),
              icon: const Icon(Icons.checklist_outlined),
              label: const Text('Pre-Brief buổi này (P5)'),
            ),
            const SizedBox(height: 16),
            _technicalDetailsCard(context),
          ],
        );
      },
    );
  }

  /// Card trạng thái rút gọn — các dòng người dùng cuối cần khi đang dùng app.
  Widget _summaryCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.monitor_heart_outlined),
                const SizedBox(width: 8),
                Text('Trạng thái', style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const Divider(height: 24),
            _infoRow(context, 'Phiên', coordinator.sessionText()),
            // F4: vẽ lại theo vadTick (mỗi buffer VAD) — ratio không đóng băng.
            ValueListenableBuilder<int>(
              valueListenable: coordinator.vadTick,
              builder: (BuildContext context, int _, Widget? _) =>
                  _infoRow(context, 'Hội thoại', coordinator.conversationText()),
            ),
            _infoRow(context, 'TTS', coordinator.ttsText()),
            _infoRow(context, 'Gợi ý (P3)', coordinator.suggestionText()),
          ],
        ),
      ),
    );
  }

  /// Khu "Chi tiết kỹ thuật" — gom mọi dòng chẩn đoán còn lại, mặc định ĐÓNG (P5.3).
  /// Các hàm `xxxText()` và luồng cập nhật của chúng giữ nguyên từ bản cũ — chỉ chuyển chỗ vẽ.
  Widget _technicalDetailsCard(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        // Mặc định đóng: chẩn đoán không phải thứ đầu tiên đập vào mắt mỗi lần mở app.
        initiallyExpanded: false,
        title: const Text('Chi tiết kỹ thuật'),
        subtitle: const Text('ASR/TTS/Thu âm/Lưu trữ/quyền — để debug khi có sự cố'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _infoRow(context, 'Quyền', coordinator.permissionText()),
                _infoRow(context, 'Thu âm', coordinator.captureStatusText()),
                _infoRow(context, 'ASR', coordinator.asrText()),
                _infoRow(context, 'Emergency', coordinator.emergencyText()),
                _infoRow(context, 'Nhận dạng', coordinator.session.lastTranscriptText),
                _infoRow(context, 'Coaching (P5)', coordinator.coachingText()),
                _infoRow(context, 'Transcript', coordinator.transcriptText()),
                _infoRow(context, 'Push gần nhất', coordinator.pushText()),
                _infoRow(context, 'Lưu trữ', coordinator.databaseStatus),
                _infoRow(
                  context,
                  'API key LLM',
                  coordinator.hasApiKey == null
                      ? 'lỗi đọc'
                      : (coordinator.hasApiKey! ? 'đã lưu' : 'chưa có'),
                ),
                _infoRow(
                  context,
                  'LLM Endpoint',
                  coordinator.llmConfig == null
                      ? 'chưa kiểm tra'
                      : (coordinator.llmConfig!.isDefault
                          ? 'Groq mặc định (${coordinator.llmConfig!.model})'
                          : 'tuỳ chỉnh: ${coordinator.llmConfig!.endpoint} · ${coordinator.llmConfig!.model}'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
