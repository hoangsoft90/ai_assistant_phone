// Test P5.3 — Bottom nav 4 tab + nút nổi toàn cục.
//
// Phiên hội thoại được bật bằng **service giả** (`startService: () async => true`) và
// **capture giả** — cùng cách `conversation_session_controller_test.dart` (P4) đã bơm service:
// môi trường test không có native. Stub MethodChannel một mình KHÔNG đủ: `startNative` nhận
// `null` ⇒ `FormatException` ⇒ CaptureUnavailable ⇒ phiên không bao giờ bật được trong test.
// Ethics dialog được tắt qua `showEthicsReminder: false` (đã được `app_smoke_test.dart` test riêng).
//
// Điều cần khoá (theo DoD prompt P5.3):
// - 4 tab hiển thị + chuyển được; IndexedStack giữ state tab (không dựng lại từ đầu).
// - Cụm nút nổi (Bật lắng nghe / Kết thúc buổi / Làm mới / Gợi ý-Emergency) HIỆN ở MỌI tab và
//   bấm được từ tab không phải Trang chủ (DoD 2 + 3).
// - "Kết thúc buổi" MỜ khi chưa có phiên đang chạy, BẬT khi đang chạy (DoD 4).
// - Mỗi hành động chỉ có ĐÚNG 1 điểm bấm (constraint: không trùng nút).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/audio/capture/capture_config.dart';
import 'package:ai_assistant_phone/audio/capture/capture_engine.dart';
import 'package:ai_assistant_phone/ui/global_floating_controls.dart';
import 'package:ai_assistant_phone/ui/root_scaffold.dart';

/// Fake capture tối thiểu (cùng mẫu `_FakeCapture` của P4 trong
/// `conversation_session_controller_test.dart`): `start()` thành công mà không đụng native.
class _FakeCapture implements AudioCaptureEngine {
  @override
  Future<CaptureConfig> start() async => const CaptureConfig();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  int get capturedBytes => 0;

  @override
  void onError(void Function(CaptureError error) handler) {}

  @override
  Stream<Uint8List> get chunks => const Stream<Uint8List>.empty();

  @override
  Stream<CaptureStatus> get status => const Stream<CaptureStatus>.empty();
}

Widget _app() => MaterialApp(
      home: RootScaffold(
        startService: () async => true,
        stopService: () async {},
        capture: _FakeCapture(),
        showEthicsReminder: false,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Mọi MethodChannel plugin được stub trả null — bắt chước `app_smoke_test.dart`, để các lệnh
    // load cấu hình lúc mở app (DB, secure storage, quyền...) không ném trong môi trường test.
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const List<String> channels = <String>[
      'flutter_foreground_task/methods',
      'com.tekartik.sqflite',
      'plugins.it_nomads.com/flutter_secure_storage',
      'flutter.baseflow.com/permissions/methods',
      'com.aiassistant.phone/audio_capture',
      'com.aiassistant.phone/audio_capture_pcm',
      'com.aiassistant.phone/vad',
      'com.aiassistant.phone/asr',
      'com.aiassistant.phone/vosk',
      'com.aiassistant.phone/tts',
    ];
    for (final String name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (MethodCall call) async => null);
    }
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(_app());
    await tester.pump();
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
  }

  Future<void> goToTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
  }

  /// Kéo `finder` vào giữa màn hình — cần cho các mục nằm dưới `ListView` (build lười).
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  /// Xả timer còn treo sau một hành động có hiện SnackBar: SnackBar tự ẩn sau 4s (timer riêng)
  /// và hàng đợi snack của coordinator chờ 4.1s/snack (`_drainSnackQueue`) — nếu không bơm đủ
  /// đồng hồ giả, test kết thúc khi timer còn pending ⇒ invariant `!timersPending` fail.
  /// Bơm 10s là đủ cho trường hợp 2 snack xếp hàng (bật phiên + không nạp được ASR trong test).
  Future<void> flushSnackTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  testWidgets('khởi động: 4 tab + cụm nút nổi hiện ngay ở tab Trang chủ',
      (WidgetTester tester) async {
    await pumpApp(tester);

    expect(find.byType(BottomNavigationBar), findsOneWidget);
    expect(find.text('Trang chủ'), findsOneWidget);
    expect(find.text('Lịch sử'), findsOneWidget);
    expect(find.text('Thống kê'), findsOneWidget);
    expect(find.text('Cài đặt'), findsOneWidget);

    // Cụm nút nổi toàn cục: đúng 1 instance, đè lên trên (không thuộc tab nào).
    expect(find.byType(GlobalFloatingControls), findsOneWidget);
    // Nhóm A: Bắt đầu lắng nghe (FAB tooltip) + Làm mới + Kết thúc buổi (mờ khi chưa có phiên).
    expect(find.byTooltip('Bật lắng nghe'), findsOneWidget);
    expect(find.byTooltip('Làm mới trạng thái'), findsOneWidget);
    final Finder finish = find.text('Kết thúc buổi');
    expect(finish, findsOneWidget);
    final FilledButton finishButton = tester.widget<FilledButton>(
        find.ancestor(of: finish, matching: find.byType(FilledButton)));
    expect(finishButton.onPressed, isNull,
        reason: 'chưa có phiên đang chạy ⇒ Kết thúc buổi phải MỜ (DoD 4)');
    // Nhóm B: nút Gợi ý của P3.
    expect(find.text('Gợi ý'), findsOneWidget);
  });

  testWidgets('chuyển đủ 4 tab: cụm nút nổi vẫn hiện nguyên ở mọi tab (DoD 2)',
      (WidgetTester tester) async {
    await pumpApp(tester);

    for (final String tab in <String>['Lịch sử', 'Thống kê', 'Cài đặt', 'Trang chủ']) {
      await goToTab(tester, tab);
      expect(find.byType(GlobalFloatingControls), findsOneWidget,
          reason: 'nút nổi phải hiện ở tab $tab');
      expect(find.byTooltip('Bật lắng nghe'), findsOneWidget,
          reason: 'nút Bật lắng nghe phải bấm được ở tab $tab');
      expect(find.text('Gợi ý'), findsOneWidget,
          reason: 'nút Gợi ý (P3) phải hiện ở tab $tab');
    }
  });

  testWidgets(
      'đang ở tab Lịch sử, bấm "Bật lắng nghe" → nút đổi thành "Tắt lắng nghe" ngay (DoD 3)',
      (WidgetTester tester) async {
    await pumpApp(tester);
    await goToTab(tester, 'Lịch sử');

    expect(find.text('Lịch sử phiên'), findsOneWidget, reason: 'đang ở tab Lịch sử');

    await tester.tap(find.byTooltip('Bật lắng nghe'));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await flushSnackTimers(tester);

    // Không cần quay về tab Trang chủ: trạng thái đổi đúng tại chỗ (nút nổi là toàn cục).
    expect(find.byTooltip('Tắt lắng nghe'), findsOneWidget,
        reason: 'bấm từ tab Lịch sử phải bật phiên như bấm từ Trang chủ (DoD 3)');
    // Nhãn tab Trang chủ cũng đổi theo (đọc cùng coordinator — IndexedStack giữ nguyên cây).
    await goToTab(tester, 'Trang chủ');
    expect(find.text('Đang lắng nghe'), findsOneWidget);
  });

  testWidgets('"Kết thúc buổi" bật lên sau khi phiên đang chạy (DoD 4)',
      (WidgetTester tester) async {
    await pumpApp(tester);

    Finder finishButton() => find.ancestor(
          of: find.text('Kết thúc buổi'),
          matching: find.byType(FilledButton),
        );
    expect(tester.widget<FilledButton>(finishButton()).onPressed, isNull);

    await tester.tap(find.byTooltip('Bật lắng nghe'));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await flushSnackTimers(tester);

    expect(tester.widget<FilledButton>(finishButton()).onPressed, isNotNull,
        reason: 'phiên đang chạy ⇒ Kết thúc buổi phải BẬT');
    // Vẫn bật khi sang tab khác: nút nổi toàn cục đọc cùng coordinator.
    await goToTab(tester, 'Thống kê');
    expect(tester.widget<FilledButton>(finishButton()).onPressed, isNotNull,
        reason: '"Kết thúc buổi" bật ở MỌI tab khi phiên đang chạy');
  });

  testWidgets('không trùng nút: mỗi hành động phiên chỉ có ĐÚNG 1 điểm bấm trong UI (constraint)',
      (WidgetTester tester) async {
    await pumpApp(tester);

    // Nút nổi: đúng 1 điểm bấm cho mỗi hành động.
    expect(find.byTooltip('Bật lắng nghe'), findsOneWidget);
    expect(find.byTooltip('Làm mới trạng thái'), findsOneWidget);
    expect(find.text('Kết thúc buổi'), findsOneWidget);
    expect(find.text('Gợi ý'), findsOneWidget);

    // Tab Trang chủ KHÔNG còn nút hành động phiên nào (đã chuyển thành nổi toàn cục).
    // Mở "Chi tiết kỹ thuật" để mọi nội dung tab có trong cây, rồi khẳng định không có bản sao.
    await tester.tap(find.text('Chi tiết kỹ thuật'));
    await tester.pumpAndSettle();
    // Lưu ý: nút nổi vẫn hiện (đúng DoD 2) — chỉ cấm BẢN SAO trong nội dung tab.
    expect(find.text('Bật lắng nghe'), findsNothing,
        reason: 'Trang chủ không được còn nút Bật lắng nghe riêng (bản nút nổi là tooltip)');
    expect(find.text('Làm mới trạng thái'), findsNothing,
        reason: 'Trang chủ không được còn nút Làm mới riêng (bản nút nổi là tooltip)');
    expect(find.textContaining('Kết thúc buổi + nhận xét'), findsNothing,
        reason: 'nút "Kết thúc buổi + nhận xét (P5)" cũ đã hợp nhất vào nút nổi');
    expect(find.textContaining('Làm mới'), findsNothing,
        reason: 'Trang chủ không được còn nút làm mới riêng');

    // Sang tab Cài đặt: cũng không có bản sao nút điều khiển phiên. Riêng "Kết thúc buổi" là
    // nhãn của NÚT NỔI TOÀN CỤC (đúng DoD 2 — hiện ở mọi tab) nên phải thấy đúng 1, không phải 0.
    await goToTab(tester, 'Cài đặt');
    expect(find.text('Bật lắng nghe'), findsNothing);
    expect(find.text('Kết thúc buổi'), findsOneWidget,
        reason: 'nhãn duy nhất của "Kết thúc buổi" thuộc nút nổi toàn cục (DoD 2)');
    // Nút chẩn đoán ASR là hành động KHÁC (nạp/tắt model, không bật phiên) — vẫn đúng 1 cái.
    await scrollTo(tester, find.text('Bật nhận dạng (ASR)'));
    expect(find.text('Bật nhận dạng (ASR)'), findsOneWidget);
  });

  testWidgets('IndexedStack giữ state: nội dung tab đã mở vẫn còn khi quay lại',
      (WidgetTester tester) async {
    await pumpApp(tester);

    // Tab Trang chủ mở "Chi tiết kỹ thuật" → dòng chẩn đoán hiện ra.
    await tester.tap(find.text('Chi tiết kỹ thuật'));
    await tester.pumpAndSettle();
    expect(find.text('Quyền'), findsOneWidget);

    // ...chuyển sang tab khác rồi quay lại: trạng thái mở vẫn giữ (không dựng lại).
    await goToTab(tester, 'Cài đặt');
    await goToTab(tester, 'Trang chủ');
    expect(find.text('Quyền'), findsOneWidget,
        reason: 'IndexedStack giữ state — ExpansionTile không tự đóng khi chuyển tab');
  });

  testWidgets('tab Cài đặt: đủ các nhóm cấu hình (ASR + LLM + level + retention)',
      (WidgetTester tester) async {
    await pumpApp(tester);
    await goToTab(tester, 'Cài đặt');

    // ListView build lười: phải kéo tới mục nào thì mục đó mới có trong cây.
    expect(find.text('Nhận dạng (ASR)'), findsOneWidget);
    await scrollTo(tester, find.text('Gợi ý (LLM)'));
    expect(find.text('Gợi ý (LLM)'), findsOneWidget);
    // issue1_fix: label đổi thành GENERIC (key là của cấu hình LLM hiện tại) + thêm nút Test LLM.
    expect(find.text('Nhập API key LLM'), findsOneWidget);
    expect(find.text('Cấu hình LLM Endpoint/Model (P2.1)'), findsOneWidget);
    expect(find.text('Test LLM'), findsOneWidget);
    expect(find.text('Khôi phục mặc định Groq'), findsOneWidget);
    await scrollTo(tester, find.text('Huấn luyện (P5)'));
    expect(find.text('Huấn luyện (P5)'), findsOneWidget);
    await scrollTo(tester, find.text('Lưu trữ & quyền riêng tư'));
    expect(find.text('Lưu trữ & quyền riêng tư'), findsOneWidget);
    expect(find.text('Tự xoá dữ liệu sau (P5.1)'), findsOneWidget);
  });
}
