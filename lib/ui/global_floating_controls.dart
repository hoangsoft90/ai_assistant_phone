import 'package:flutter/material.dart';

import '../trigger/trigger_manager.dart' show SuggestTriggerSource;
import 'floating_button.dart';
import 'session_coordinator.dart';

/// Cụm nút nổi **toàn cục** (P5.3) — đè lên MỌI tab của RootScaffold, bấm được ở bất kỳ đâu.
///
/// Nhóm A — điều khiển phiên: Bắt đầu/Dừng lắng nghe (1 nút đổi trạng thái), Kết thúc buổi (chỉ
/// bật khi phiên đang chạy), Làm mới trạng thái.
/// Nhóm B — Push/Emergency: [SuggestFloatingButton] của P3, **giữ nguyên logic bên trong**
/// (file `floating_button.dart` không bị sửa) — chỉ thay đổi NƠI nó được mount.
///
/// State đọc trực tiếp từ [SessionCoordinator] (AnimatedBuilder): vì coordinator là MỘT instance
/// duy nhất của RootScaffold, trạng thái nút luôn đúng ở mọi tab — không có cơ hội "1 tab quên
/// cập nhật khi đang lắng nghe".
class GlobalFloatingControls extends StatelessWidget {
  const GlobalFloatingControls({super.key, required this.coordinator});

  final SessionCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: coordinator,
      builder: (BuildContext context, Widget? _) {
        final bool sessionActive = coordinator.session.isActive;
        final bool busy = coordinator.busy;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            // --- Nhóm A: điều khiển phiên (nút mới của P5.3, tái dùng handler có sẵn).
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // "Kết thúc buổi": chỉ bật khi phiên đang chạy — ẩn/mờ đúng ở MỌI tab (DoD 4).
                // Cùng một handler `_finishSessionAndReview` — KHÔNG còn nút y hệt ở tab nào khác.
                FilledButton.tonalIcon(
                  onPressed: sessionActive && !busy
                      ? () => coordinator.finishSessionAndReview(context)
                      : null,
                  icon: const Icon(Icons.school_outlined),
                  label: const Text('Kết thúc buổi'),
                ),
                const SizedBox(width: 8),
                // "Làm mới trạng thái": tái dùng đúng handler `_refreshAll` của bản cũ.
                FloatingActionButton.small(
                  heroTag: 'p53-refresh',
                  tooltip: 'Làm mới trạng thái',
                  onPressed: busy ? null : () => coordinator.refreshAll(),
                  child: const Icon(Icons.refresh),
                ),
                const SizedBox(width: 8),
                // "Bắt đầu lắng nghe / Đang lắng nghe (bấm để dừng)": 1 nút đổi trạng thái,
                // icon + màu đổi theo đang nghe hay không — tái dùng đúng `toggleService`.
                FloatingActionButton(
                  heroTag: 'p53-toggle-session',
                  tooltip: sessionActive ? 'Tắt lắng nghe' : 'Bật lắng nghe',
                  onPressed: busy ? null : () => coordinator.toggleService(),
                  backgroundColor: sessionActive
                      ? Theme.of(context).colorScheme.errorContainer
                      : null,
                  child: Icon(
                    sessionActive ? Icons.stop : Icons.mic,
                    color: sessionActive
                        ? Theme.of(context).colorScheme.onErrorContainer
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // --- Nhóm B: Push/Emergency của P3 (chỉ đổi chỗ mount, không sửa logic).
            SuggestFloatingButton(
              enabled: !coordinator.suggesting,
              onSuggest: () => coordinator
                  .requestSuggestion(source: SuggestTriggerSource.floatingButton),
              onEmergency: coordinator.requestEmergency,
            ),
          ],
        );
      },
    );
  }
}
