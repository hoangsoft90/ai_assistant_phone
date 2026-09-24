// Test fix SnackBar không hiện (ScaffoldMessenger đặt SAI vị trí trong RootScaffold).
//
// Lỗi: `ScaffoldMessenger(key: _messengerKey)` nằm BÊN TRONG `Scaffold.body` ⇒ nó ở DƯỚI `Scaffold`
// gốc trong cây widget, ngược thứ tự đúng của Flutter. `Scaffold` chỉ đăng ký được với một
// `ScaffoldMessenger` ở TỔ TIÊN của nó, nên `Scaffold` gốc không bao giờ thấy messenger của key;
// messenger của key chỉ thấy `Scaffold` của `HistoryScreen`/`StatsScreen` — mà hai màn đó nằm trong
// `IndexedStack` (offstage khi không phải tab hiện tại) ⇒ SnackBar bị vẽ trong cây tab, không hiện
// trên màn hình. Người dùng xác nhận bằng thực nghiệm: bấm "Test LLM" không thấy phản hồi gì.
//
// Gap mà 424 test cũ không phủ: KHÔNG test nào bấm nút trong cây `RootScaffold` ĐẦY ĐỦ rồi kiểm tra
// `SnackBar` thật sự xuất hiện. Test này khoá đúng gap đó, và khoá luôn tiêu chí cấu trúc: SnackBar
// phải do `Scaffold` GỐC dựng (KHÔNG nằm trong `IndexedStack`), nếu không thì lỗi cũ quay lại.
//
// Cấu trúc tối thiểu giống `p5_3_navigation_test.dart`: stub mọi MethodChannel plugin trả null;
// service/capture/Test-LLM đều là giả (môi trường test không có native, không có mạng).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/audio/capture/capture_config.dart';
import 'package:ai_assistant_phone/audio/capture/capture_engine.dart';
import 'package:ai_assistant_phone/suggestion/test_llm_service.dart';
import 'package:ai_assistant_phone/ui/root_scaffold.dart';

/// Fake capture tối thiểu (cùng mẫu `_FakeCapture` của P4/P5.3): `start()` thành công mà không đụng
/// kênh native.
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

/// Fake Test LLM trả kết quả cố định — test không gọi HTTP thật, nhưng vẫn đi qua ĐÚNG đường
/// `SessionCoordinator.testLlm()` ⇒ `enqueueSnack` ⇒ `ScaffoldMessenger` của `RootScaffold`.
class _FakeTestLlm extends TestLlmService {
  _FakeTestLlm(this._result);

  final LlmTestResult _result;

  @override
  Future<LlmTestResult> run({String? endpointOverride, String? modelOverride}) async => _result;
}

Widget _app({TestLlmService? testLlm}) => MaterialApp(
      home: RootScaffold(
        startService: () async => true,
        stopService: () async {},
        capture: _FakeCapture(),
        showEthicsReminder: false,
        testLlm: testLlm,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
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

  /// Xả timer còn treo sau khi hiện SnackBar: SnackBar tự ẩn sau 4s + hàng đợi snack của coordinator
  /// chờ 4.1s/snack (`_drainSnackQueue`). Không xả thì test kết thúc khi timer còn pending ⇒
  /// invariant `!timersPending` fail. 10s đủ cho trường hợp 2 snack xếp hàng.
  Future<void> flushSnackTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  Future<void> pumpApp(WidgetTester tester, {TestLlmService? testLlm}) async {
    await tester.pumpWidget(_app(testLlm: testLlm));
    await tester.pump();
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    // Xả mọi SnackBar/queue phát sinh lúc `init()` (nếu có) — test không phụ thuộc thứ tự init.
    await flushSnackTimers(tester);
  }

  Future<void> goToTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
  }

  /// Kéo `finder` vào giữa màn hình — `ListView` của tab Cài đặt build lười.
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }

  /// Bất biến chung của fix: SnackBar phải do `Scaffold` GỐC dựng, tức KHÔNG có `IndexedStack` nào ở
  /// tổ tiên. Trước fix, SnackBar được vẽ trong `Scaffold` của `HistoryScreen`/`StatsScreen` — cả hai
  /// nằm trong `IndexedStack` ⇒ assertion này đỏ (và trên máy thật thì vô hình vì tab đó offstage).
  void expectSnackBarOnRootScaffold(String expectedText) {
    final Finder snack = find.byType(SnackBar);
    expect(snack, findsOneWidget,
        reason: 'SnackBar phải hiện ĐÚNG 1 cái (nested Scaffold không được vẽ lại lần nữa)');
    expect(find.descendant(of: snack, matching: find.text(expectedText)), findsOneWidget,
        reason: 'phải đúng thông điệp, không chỉ đúng loại widget');
    expect(find.ancestor(of: snack, matching: find.byType(IndexedStack)), findsNothing,
        reason: 'SnackBar nằm trong IndexedStack = lỗi cũ (bị tab khác che, không hiện trên màn hình)');
  }

  testWidgets(
      'bấm Test LLM (thành công) ở tab Cài đặt trong cây RootScaffold đầy đủ → SnackBar hiện THẬT',
      (WidgetTester tester) async {
    await pumpApp(
      tester,
      testLlm: _FakeTestLlm(
        const LlmTestResult.success(model: 'test-model', latency: Duration(milliseconds: 7)),
      ),
    );
    await goToTab(tester, 'Cài đặt');
    await scrollTo(tester, find.text('Test LLM'));

    await tester.tap(find.text('Test LLM'));
    await tester.pump();
    await tester.pump();

    expectSnackBarOnRootScaffold('LLM hoạt động · test-model · 7ms');

    await flushSnackTimers(tester);
  });

  testWidgets('bấm Test LLM (thất bại) → SnackBar hiện THẬT với thông điệp lỗi',
      (WidgetTester tester) async {
    await pumpApp(
      tester,
      testLlm: _FakeTestLlm(
        const LlmTestResult.failure(LlmTestKind.auth, 'Key không hợp lệ (HTTP 401).'),
      ),
    );
    await goToTab(tester, 'Cài đặt');
    await scrollTo(tester, find.text('Test LLM'));

    await tester.tap(find.text('Test LLM'));
    await tester.pump();
    await tester.pump();

    expectSnackBarOnRootScaffold('Test LLM thất bại: Key không hợp lệ (HTTP 401).');

    await flushSnackTimers(tester);
  });

  testWidgets(
      'bấm "Bật lắng nghe" từ tab Trang chủ (tab KHÔNG có Scaffold riêng) → SnackBar "Đang lắng nghe" hiện THẬT',
      (WidgetTester tester) async {
    await pumpApp(tester);

    // Đang ở tab Trang chủ (index 0) — HomeTab không có `Scaffold` riêng, nên TRƯỚC fix không có
    // `Scaffold` nào trong tầm nhìn của người dùng lắng nghe messenger ⇒ SnackBar mất hút.
    expect(find.text('Trang chủ'), findsOneWidget);

    await tester.tap(find.byTooltip('Bật lắng nghe'));
    await tester.pump();
    await tester.pump();

    expectSnackBarOnRootScaffold('Đang lắng nghe');

    await flushSnackTimers(tester);
  });

  testWidgets(
      'bấm "Bật lắng nghe" từ tab Lịch sử (tab CÓ Scaffold riêng) → SnackBar vẫn hiện ở khung gốc, không vẽ trùng',
      (WidgetTester tester) async {
    await pumpApp(tester);
    await goToTab(tester, 'Lịch sử');
    expect(find.text('Lịch sử phiên'), findsOneWidget, reason: 'đang ở tab Lịch sử');

    // Tab Lịch sử có `Scaffold` riêng. Trước fix, messenger của key chỉ thấy `Scaffold` này nên
    // SnackBar được vẽ trong cây tab; nay messenger ở khung gốc ⇒ vẫn đúng 1 SnackBar ở ngoài
    // `IndexedStack` (KHÔNG bị vẽ trùng 2 lần bởi cả Scaffold gốc lẫn Scaffold tab).
    await tester.tap(find.byTooltip('Bật lắng nghe'));
    await tester.pump();
    await tester.pump();

    expectSnackBarOnRootScaffold('Đang lắng nghe');

    await flushSnackTimers(tester);
  });
}
