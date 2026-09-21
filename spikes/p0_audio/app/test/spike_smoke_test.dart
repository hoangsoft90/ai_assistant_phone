// Smoke test tối giản: app spike dựng được khung UI mà không crash.
// Logic audio/ASR thật nằm ở tầng Kotlin/native nên test ở đây chỉ có giá trị chống hồi quy UI.
//
// Lưu ý: trong môi trường test, MethodChannel không có handler phía Android -> lệnh gọi trả
// PlatformException và được UI nuốt lại thành dòng log, không làm test fail.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p0_spike/main.dart';

void main() {
  testWidgets('hiển thị đủ nút điều khiển chính', (tester) async {
    await tester.pumpWidget(const P0SpikeApp());
    await tester.pump();

    expect(find.text('Chạy Vosk'), findsOneWidget);
    expect(find.text('Chạy PhoWhisper'), findsOneWidget);
    expect(find.text('Test TTS'), findsOneWidget);
    expect(find.byType(SegmentedButton<int>), findsOneWidget);
  });
}
