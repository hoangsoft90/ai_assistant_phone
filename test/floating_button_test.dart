// Test P3 task 2 — nút nổi: **tap = Push**, **giữ 2 giây = Emergency Phrase**.
//
// Đây là bằng chứng cho DoD "gesture giữ 2s ⇒ Emergency đúng, KHÔNG nhầm lẫn với Push thường" mà
// không cần máy thật: thời gian trong `flutter_test` là đồng hồ giả nên đo được đúng mốc 2 giây.
//
// Điều đáng khoá nhất: một cử chỉ KHÔNG được chạy cả hai đường, và nhả trước ngưỡng thì tuyệt đối
// không được phát câu thoát hiểm (người dùng chỉ định xin gợi ý).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/ui/floating_button.dart';

/// Bộ đếm + host tối thiểu (MaterialApp để có Theme/Material cho nút).
class _Host {
  int suggest = 0;
  int emergency = 0;

  Widget build({bool enabled = true, Duration hold = TriggerConfig.emergencyHold}) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SuggestFloatingButton(
              enabled: enabled,
              holdDuration: hold,
              onSuggest: () async => suggest++,
              onEmergency: () async => emergency++,
            ),
          ),
        ),
      );
}

Finder _button() => find.byType(SuggestFloatingButton);

void main() {
  test('ngưỡng giữ mặc định = 2 giây (prompt P3 task 2)', () {
    expect(TriggerConfig.emergencyHold, const Duration(seconds: 2));
  });

  testWidgets('tap ngắn ⇒ gọi Push, KHÔNG gọi Emergency', (WidgetTester tester) async {
    final _Host host = _Host();
    await tester.pumpWidget(host.build());

    await tester.tap(_button());
    await tester.pump();

    expect(host.suggest, 1);
    expect(host.emergency, 0);
  });

  testWidgets('giữ ĐÚNG 2 giây ⇒ gọi Emergency, KHÔNG gọi Push (kể cả lúc nhả tay)', (WidgetTester tester) async {
    final _Host host = _Host();
    await tester.pumpWidget(host.build());

    final TestGesture gesture = await tester.startGesture(tester.getCenter(_button()));
    await tester.pump(const Duration(seconds: 2)); // Chạm đúng mốc ngưỡng.
    await gesture.up();
    await tester.pump();

    expect(host.emergency, 1);
    expect(host.suggest, 0, reason: 'giữ đủ ngưỡng thì nhả tay KHÔNG được chạy thêm Push');
  });

  testWidgets('giữ hụt 100ms (1,9s) ⇒ chỉ Push, KHÔNG Emergency', (WidgetTester tester) async {
    final _Host host = _Host();
    await tester.pumpWidget(host.build());

    final TestGesture gesture = await tester.startGesture(tester.getCenter(_button()));
    await tester.pump(const Duration(milliseconds: 1900));
    await gesture.up();
    await tester.pump();

    expect(host.suggest, 1);
    expect(host.emergency, 0);
  });

  testWidgets('giữ rất lâu (5s) ⇒ Emergency đúng MỘT lần', (WidgetTester tester) async {
    final _Host host = _Host();
    await tester.pumpWidget(host.build());

    final TestGesture gesture = await tester.startGesture(tester.getCenter(_button()));
    await tester.pump(const Duration(seconds: 5));
    await gesture.up();
    await tester.pump();

    expect(host.emergency, 1);
    expect(host.suggest, 0);
  });

  testWidgets('kéo ngón ra ngoài rồi nhả trước ngưỡng ⇒ KHÔNG gọi gì (huỷ cử chỉ)', (WidgetTester tester) async {
    final _Host host = _Host();
    await tester.pumpWidget(host.build());

    final TestGesture gesture = await tester.startGesture(tester.getCenter(_button()));
    await gesture.moveBy(const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pump();

    expect(host.suggest, 0);
    expect(host.emergency, 0);
  });

  testWidgets('bấm 2 lần liên tiếp ⇒ 2 lần Push (không có cooldown ở tầng này)', (WidgetTester tester) async {
    final _Host host = _Host();
    await tester.pumpWidget(host.build());

    await tester.tap(_button());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(_button());
    await tester.pump();

    expect(host.suggest, 2);
  });

  testWidgets('nút bị vô hiệu (đang bận) ⇒ không gọi gì', (WidgetTester tester) async {
    final _Host host = _Host();
    await tester.pumpWidget(host.build(enabled: false));

    await tester.tap(_button());
    await tester.pump();

    expect(host.suggest, 0);
    expect(host.emergency, 0);
  });

  testWidgets('ngưỡng giữ truyền vào được (dùng cho test/đổi sau này)', (WidgetTester tester) async {
    final _Host host = _Host();
    await tester.pumpWidget(host.build(hold: const Duration(milliseconds: 500)));

    final TestGesture gesture = await tester.startGesture(tester.getCenter(_button()));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pump();

    expect(host.emergency, 1);
    expect(host.suggest, 0);
  });
}
