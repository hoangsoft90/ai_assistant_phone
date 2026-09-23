import 'package:flutter/material.dart';

import '../audio/capture/capture_engine.dart';
import 'global_floating_controls.dart';
import 'history_screen.dart';
import 'home_tab.dart';
import 'session_coordinator.dart';
import 'settings_tab.dart';
import 'stats_screen.dart';

/// Khung điều hướng gốc (P5.3) — thay `HomeScreen` cũ làm `home:` của `MaterialApp`.
///
/// Kiến trúc (đúng sơ đồ prompt P5.3):
/// ```
/// RootScaffold
/// ├── Scaffold
/// │   ├── body: Stack
/// │   │   ├── IndexedStack(index: _tabIndex, children: [HomeTab, HistoryScreen, StatsScreen, SettingsTab])
/// │   │   └── Positioned(bottom: ..., child: GlobalFloatingControls)  // ĐÈ LÊN mọi tab
/// │   └── bottomNavigationBar: BottomNavigationBar(4 tab)
/// ```
/// - `IndexedStack` thay vì Navigator/route riêng: giữ nguyên state từng tab khi chuyển qua lại
///   (đang xem Thống kê → Lịch sử → quay lại, không load lại từ đầu) — hành vi bottom-nav chuẩn.
/// - Nút nổi đặt ở RootScaffold (NGOÀI IndexedStack): cách duy nhất để "bấm được ở bất kỳ đâu" —
///   nếu đặt trong từng tab thì mỗi tab phải tự dựng lại, dễ lệch trạng thái.
/// - Load cấu hình lúc mở app nằm hết ở [SessionCoordinator.init] (mục 4 của prompt): mỗi tab
///   đọc state qua coordinator, KHÔNG tự load riêng gây trùng lặp/lệch dữ liệu.
class RootScaffold extends StatefulWidget {
  const RootScaffold({
    super.key,
    this.startService,
    this.stopService,
    this.capture,
    this.showEthicsReminder = true,
  });

  /// Cho test bơm service giả (môi trường test không có native — service thật luôn trả `false`);
  /// app thật dùng mặc định `null` = [ListeningService.start].
  final Future<bool> Function()? startService;
  final Future<void> Function()? stopService;

  /// Cho test bơm capture giả (cùng mục đích `startService` — xem [SessionCoordinator]).
  final AudioCaptureEngine? capture;

  /// Cho test tắt lời nhắc đạo đức (đã được test riêng ở `app_smoke_test.dart`).
  final bool showEthicsReminder;

  @override
  State<RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends State<RootScaffold> {
  /// SnackBar của MỌI tab đi qua key này (coordinator không giữ `context` của tab nào).
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  late final SessionCoordinator _coordinator = SessionCoordinator(
    messengerKey: _messengerKey,
    startService: widget.startService,
    stopService: widget.stopService,
    capture: widget.capture,
  );

  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    // Mọi lệnh load cấu hình lúc mở app (danh sách nguyên vẹn từ initState của HomeScreen cũ).
    _coordinator.init();
    // P7 mục 4: lời nhắc đạo đức, chỉ lần đầu. Chạy sau khung đầu tiên để `showDialog` có
    // ScaffoldMessenger ổn định (như bản cũ — initState của HomeScreen cũng gọi lúc mở màn hình).
    // P5.3: test điều hướng tắt qua `showEthicsReminder: false` (dialog được test riêng).
    if (!widget.showEthicsReminder) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _coordinator.maybeShowEthicsReminder(context);
    });
  }

  @override
  void dispose() {
    _coordinator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Tiêu đề app giữ nguyên như mọi phiên bản trước (tên tab đã hiện ở bottom nav).
      appBar: AppBar(title: const Text('Trợ lý giao tiếp')),
      body: ScaffoldMessenger(
        key: _messengerKey,
        child: Stack(
          children: <Widget>[
            // IndexedStack giữ state 4 tab khi chuyển qua lại (prompt P5.3 mục 1).
            IndexedStack(
              index: _tabIndex,
              children: <Widget>[
                HomeTab(coordinator: _coordinator),
                const HistoryScreen(),
                StatsScreen(currentLevelLabel: _coordinator.level.label),
                SettingsTab(coordinator: _coordinator),
              ],
            ),
            // Cụm nút nổi ĐÈ LÊN mọi tab (Positioned cuối Stack = on top).
            Positioned(
              right: 16,
              bottom: 16,
              child: GlobalFloatingControls(coordinator: _coordinator),
            ),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _tabIndex,
        onTap: (int index) => setState(() => _tabIndex = index),
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(icon: Icon(Icons.home_outlined), label: 'Trang chủ'),
          BottomNavigationBarItem(icon: Icon(Icons.history_outlined), label: 'Lịch sử'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart_outlined), label: 'Thống kê'),
          BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), label: 'Cài đặt'),
        ],
      ),
    );
  }
}
