import 'package:flutter/material.dart';

import '../audio/asr/asr_engine_selector.dart';
import '../audio/output_mode_selector.dart';
import '../coaching/training_level.dart';
import '../core/constants.dart' show OutputConfig;
import '../services/storage/retention_config.dart' show allowedRetentionDays;
import 'session_coordinator.dart';

/// Tab **Cài đặt** (P5.3) — gom TẤT CẢ phần cấu hình trước đây là nút rời rạc trong
/// `home_screen.dart`, nhóm theo chức năng. KHÔNG chứa hành động tức thời (Bật lắng nghe,
/// Kết thúc buổi, Làm mới — những cái đó đã là nút nổi toàn cục).
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key, required this.coordinator});

  final SessionCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: coordinator,
      builder: (BuildContext context, Widget? _) {
        final bool busy = coordinator.busy;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _section(context, Icons.psychology_outlined, 'Nhận dạng (ASR)', <Widget>[
              // P1D: chọn engine nhận dạng — ghi vào cấu hình, không cần build lại app. Đổi engine
              // khi đang lắng nghe sẽ TẮT hẳn phiên hiện tại (không tự bật lại).
              DropdownButtonFormField<AsrEngineKind>(
                key: ValueKey<AsrEngineKind>(coordinator.asrKind),
                initialValue: coordinator.asrKind,
                decoration: const InputDecoration(
                  labelText: 'Engine nhận dạng (ASR)',
                  border: OutlineInputBorder(),
                ),
                items: AsrEngineKind.values
                    .map((AsrEngineKind kind) => DropdownMenuItem<AsrEngineKind>(
                          value: kind,
                          child: Text(kind.label),
                        ))
                    .toList(),
                onChanged: busy ? coordinator.selectAsrEngine : null,
              ),
              const SizedBox(height: 8),
              // Nút chẩn đoán ASR riêng (khác nút "Bật lắng nghe" nổi toàn cục): chỉ nạp/tắt model
              // để đo A/B 2 engine trên máy thật mà không phải bật cả phiên.
              OutlinedButton.icon(
                onPressed: (busy || coordinator.session.isBusy) ? null : coordinator.toggleAsr,
                icon: Icon(coordinator.session.isAsrRunning
                    ? Icons.stop_circle_outlined
                    : Icons.record_voice_over_outlined),
                label: Text(
                  coordinator.session.isAsrRunning ? 'Tắt nhận dạng (ASR)' : 'Bật nhận dạng (ASR)',
                ),
              ),
            ]),
            const SizedBox(height: 16),
            _section(context, Icons.auto_awesome_outlined, 'Gợi ý (LLM)', <Widget>[
              DropdownButtonFormField<NudgeOutputMode>(
                key: ValueKey<NudgeOutputMode>(coordinator.outputMode),
                initialValue: coordinator.outputMode,
                decoration: const InputDecoration(
                  labelText: 'Chế độ hiển thị gợi ý',
                  border: OutlineInputBorder(),
                ),
                items: NudgeOutputMode.values
                    .map((NudgeOutputMode mode) => DropdownMenuItem<NudgeOutputMode>(
                          value: mode,
                          child: Text(mode.label),
                        ))
                    .toList(),
                onChanged: coordinator.selectOutputMode,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: busy ? null : () => coordinator.editApiKey(context),
                icon: const Icon(Icons.key_outlined),
                // issue1_fix mục 2: label GENERIC — key là của cấu hình LLM hiện tại (endpoint tuỳ
                // ý), không phải "Groq key". (Trạng thái key vẫn hiện ở dòng chẩn đoán API key.)
                label: const Text('Nhập API key LLM'),
              ),
              const SizedBox(height: 8),
              // P2.1: cấu hình endpoint/model cho provider OpenAI-compatible; để trống = Groq mặc định.
              OutlinedButton.icon(
                onPressed: busy ? null : () => coordinator.editLlmConfig(context),
                icon: const Icon(Icons.dns_outlined),
                label: const Text('Cấu hình LLM Endpoint/Model (P2.1)'),
              ),
              // issue1_fix mục 4: Test LLM — request thật tối thiểu, không đụng phiên.
              OutlinedButton.icon(
                onPressed: coordinator.testingLlm ? null : coordinator.testLlm,
                icon: coordinator.testingLlm
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check),
                label: Text(coordinator.testingLlm ? 'Testing...' : 'Test LLM'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : coordinator.resetLlmConfig,
                icon: const Icon(Icons.restart_alt_outlined),
                label: const Text('Khôi phục mặc định Groq'),
              ),
              const SizedBox(height: 8),
              // P3 task 3 (mục 4.8): tốc độ đọc TTS 0.9x-1.2x, mặc định 1.05x.
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text('Tốc độ đọc: ${coordinator.speechRate.toStringAsFixed(2)}x'),
                  ),
                  Text('${OutputConfig.minSpeechRate.toStringAsFixed(1)}x'),
                ],
              ),
              Slider(
                value: coordinator.speechRate,
                min: OutputConfig.minSpeechRate,
                max: OutputConfig.maxSpeechRate,
                // 6 bước ⇒ đúng lưới 0.05x trong khoảng 0.9-1.2.
                divisions: 6,
                label: '${coordinator.speechRate.toStringAsFixed(2)}x',
                // Kéo = chỉ xem trước (setState); nhả = lưu (onChangeEnd — cùng pattern bản cũ).
                onChanged: coordinator.setSpeechRatePreview,
                onChangeEnd: coordinator.saveSpeechRate,
              ),
            ]),
            const SizedBox(height: 16),
            _section(context, Icons.school_outlined, 'Huấn luyện (P5)', <Widget>[
              // P5 task 4 (mục 4.9): cấp độ do người dùng tự chọn — không có nút "đề xuất".
              DropdownButtonFormField<TrainingLevel>(
                key: ValueKey<TrainingLevel>(coordinator.level),
                initialValue: coordinator.level,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Cấp độ huấn luyện (P5)',
                  // Hành vi của cấp ĐANG chọn hiện ở helperText (không nhét vào item): nhét cả câu
                  // mô tả vào item làm dropdown tràn ngang trên màn hẹp — smoke test bắt lỗi này.
                  helperText: coordinator.level.behavior,
                  border: const OutlineInputBorder(),
                ),
                items: TrainingLevel.values
                    .map((TrainingLevel level) => DropdownMenuItem<TrainingLevel>(
                          value: level,
                          child: Text(level.label),
                        ))
                    .toList(),
                onChanged: busy ? coordinator.selectLevel : null,
              ),
            ]),
            const SizedBox(height: 16),
            _section(context, Icons.storage_outlined, 'Lưu trữ & quyền riêng tư', <Widget>[
              // P1E: nút Push thật là P3; nút này chỉ để kiểm API `markPushMoment` trên máy thật.
              OutlinedButton.icon(
                onPressed: coordinator.transcript.sessionId == null
                    ? null
                    : coordinator.markPush,
                icon: const Icon(Icons.flag_outlined),
                label: const Text('Đánh dấu Push (P1E)'),
              ),
              const SizedBox(height: 8),
              // P5.1: hạn tự xoá dữ liệu (mặc định 7 ngày) — danh sách cố định tránh giá trị vô lý.
              DropdownButtonFormField<int>(
                key: ValueKey<int?>(coordinator.retentionDays),
                initialValue: coordinator.retentionDays,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Tự xoá dữ liệu sau (P5.1)',
                  helperText:
                      'Transcript + nhận xét cuối buổi cũ hơn mốc này bị xoá (mặc định 7 ngày).',
                  border: OutlineInputBorder(),
                ),
                items: allowedRetentionDays
                    .map(
                      (int days) => DropdownMenuItem<int>(
                        value: days,
                        child: Text('$days ngày'),
                      ),
                    )
                    .toList(),
                onChanged: busy
                    ? null
                    : (int? days) => coordinator.changeRetentionDays(days!),
              ),
            ]),
            const SizedBox(height: 16),
            _section(context, Icons.headphones_outlined, 'Kiểm tra tai nghe (P1F/P1G)', <Widget>[
              // 3 nút chẩn đoán tạm để chạy 3 test case bắt buộc trên máy thật (nút thật là P3).
              OutlinedButton.icon(
                onPressed: busy ? null : () => coordinator.speakTest(),
                icon: const Icon(Icons.volume_up_outlined),
                label: const Text('Đọc thử qua tai nghe (P1F)'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: busy ? null : () => coordinator.confirmHeadset(),
                icon: const Icon(Icons.headset_outlined),
                label: const Text('Xác nhận tai nghe đã sẵn sàng (P1F)'),
              ),
              const SizedBox(height: 8),
              // Không có dialog xác nhận nào — đường khẩn cấp phải phản hồi ngay lập tức.
              OutlinedButton.icon(
                onPressed: busy ? null : () => coordinator.triggerEmergency(),
                icon: const Icon(Icons.emergency_outlined),
                label: const Text('Emergency Phrase (P1G)'),
              ),
            ]),
          ],
        );
      },
    );
  }

  /// Khung một nhóm cấu hình — tiêu đề + icon + nội dung trong Card.
  Widget _section(BuildContext context, IconData icon, String title, List<Widget> children) {
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
            const Divider(height: 24),
            ...children,
          ],
        ),
      ),
    );
  }
}
