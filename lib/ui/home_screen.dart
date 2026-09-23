import 'package:flutter/material.dart';

import 'root_scaffold.dart';

export 'root_scaffold.dart' show RootScaffold;

/// **Đã thay bởi [RootScaffold] từ P5.3** (bottom nav 4 tab + nút nổi toàn cục).
///
/// Toàn bộ state + logic của màn hình cũ đã chuyển sang `lib/ui/session_coordinator.dart`
/// (`SessionCoordinator`) và được chia vào 4 tab (`home_tab.dart`, `history_screen.dart`,
/// `stats_screen.dart`, `settings_tab.dart`). Class này chỉ còn là lớp dẫn để những chỗ nào
/// (nếu còn) tham chiếu `HomeScreen` tiếp tục build được — `main.dart` đã trỏ thẳng vào
/// `RootScaffold`.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => const RootScaffold();
}
