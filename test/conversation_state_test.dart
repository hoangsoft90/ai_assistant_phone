// Unit test cho VAD state machine (P1B) — thuần Dart, KHÔNG cần mic/thiết bị.
//
// Phần cần máy thật (phản hồi <500ms với giọng nói thật, chạy 30 phút, phòng ồn thật) KHÔNG thể
// test ở đây — xem `.plan/P1B-result.md`. Test này dùng **timeline tổng hợp** (mục "Bàn giao" của
// prompt_P1B yêu cầu ghi lại timeline state cho một đoạn hội thoại mẫu).

import 'dart:async';
import 'dart:io';

import 'package:ai_assistant_phone/audio/vad/conversation_state.dart';
import 'package:ai_assistant_phone/audio/vad/conversation_state_notifier.dart';
import 'package:ai_assistant_phone/audio/vad/vad_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake client: đẩy timeline VAD tổng hợp vào, không cần kênh native.
///
/// `sync: true`: sự kiện phát **đồng bộ** trong zone hiện tại — cần cho test watchdog với
/// `fakeAsync` (nếu phát async, `_onStat` chạy ở zone ngoài và Timer watchdog không nằm trong
/// đồng hồ giả ⇒ `async.elapse` không bao giờ làm nó nổ).
class _FakeVadClient implements VadClient {
  final StreamController<VadFrameStat> _controller =
      StreamController<VadFrameStat>.broadcast(sync: true);

  @override
  Stream<VadFrameStat> frames() => _controller.stream;

  void emit(VadFrameStat stat) => _controller.add(stat);

  /// Mô phỏng lỗi stream (kênh platform đứt, engine chết...).
  void emitError(Object error) => _controller.addError(error);

  Future<void> close() => _controller.close();
}

/// Một buffer VAD "chuẩn": 5 khung 20ms = 100ms audio (đúng bằng chunk capture hiện tại).
VadFrameStat _stat({
  required int speechFrames,
  required int atMs,
  int totalFrames = 5,
}) =>
    VadFrameStat(
      speechFrames: speechFrames,
      totalFrames: totalFrames,
      frameMs: 20,
      elapsedMs: atMs,
    );

/// Buffer toàn tiếng nói.
VadFrameStat _speech(int atMs) => _stat(speechFrames: 5, atMs: atMs);

/// Buffer toàn im lặng.
VadFrameStat _silence(int atMs) => _stat(speechFrames: 0, atMs: atMs);

void main() {
  group('VadFrameStat', () {
    test('tính durationMs và speechRatio đúng', () {
      final VadFrameStat stat = _stat(speechFrames: 2, atMs: 100, totalFrames: 5);
      expect(stat.durationMs, 100);
      expect(stat.speechRatio, closeTo(0.4, 0.0001));
    });

    test('durationMs = 0 thì speechRatio = 0 (không chia cho 0)', () {
      final VadFrameStat stat = _stat(speechFrames: 0, atMs: 0, totalFrames: 0);
      expect(stat.speechRatio, 0.0);
    });

    test('fromNative parse payload đúng', () {
      final VadFrameStat stat = VadFrameStat.fromNative(<String, Object?>{
        'speechFrames': 3,
        'totalFrames': 5,
        'frameMs': 20,
        'elapsedMs': 1234,
      });
      expect(stat.speechFrames, 3);
      expect(stat.totalFrames, 5);
      expect(stat.durationMs, 100);
      expect(stat.elapsedMs, 1234);
    });

    test('fromNative ném FormatException khi payload sai', () {
      expect(() => VadFrameStat.fromNative('không phải map'), throwsFormatException);
      expect(
        () => VadFrameStat.fromNative(<String, Object?>{'speechFrames': 1}),
        throwsFormatException,
      );
    });
  });

  group('Phạm vi state — khoá cứng ràng buộc P1B', () {
    test('CHỈ có đúng 2 state (thêm state thứ 3 là làm sai phạm vi phase)', () {
      expect(ConversationState.values, hasLength(2));
      expect(ConversationState.values, containsAll(<ConversationState>[
        ConversationState.userSpeaking,
        ConversationState.notUserSpeaking,
      ]));
    });
  });

  group('ConversationStateMachine — chuyển state', () {
    late _FakeVadClient client;
    late ConversationStateMachine machine;

    setUp(() {
      client = _FakeVadClient();
      machine = ConversationStateMachine(client: client);
      machine.start();
    });

    tearDown(() async {
      await machine.dispose();
      await client.close();
    });

    test('bắt đầu ở notUserSpeaking (chưa có bằng chứng có tiếng nói)', () {
      expect(machine.state, ConversationState.notUserSpeaking);
      expect(machine.isUserSpeaking, isFalse);
    });

    test('300ms tiếng nói liên tục → userSpeaking, phản hồi <= 500ms (DoD 1)', () async {
      final List<ConversationStateChange> changes = <ConversationStateChange>[];
      machine.transitions.listen(changes.add);

      client.emit(_speech(100));
      client.emit(_speech(200));
      client.emit(_speech(300));
      await Future<void>.delayed(Duration.zero);

      expect(machine.state, ConversationState.userSpeaking);
      expect(machine.isUserSpeaking, isTrue);
      expect(changes, hasLength(1));
      expect(changes.single.reason, ConversationStateReason.speechAccumulated);
      // Phản hồi tính từ lúc bắt đầu có tiếng nói (buffer đầu kết thúc ở 100ms).
      expect(changes.single.atMs, lessThanOrEqualTo(500));
    });

    test('1500ms im lặng ổn định → quay lại notUserSpeaking (DoD 2)', () async {
      for (int i = 1; i <= 3; i++) {
        client.emit(_speech(i * 100));
      }
      await Future<void>.delayed(Duration.zero);
      expect(machine.state, ConversationState.userSpeaking);

      // 15 buffer 100ms im lặng = 1500ms.
      for (int i = 4; i <= 18; i++) {
        client.emit(_silence(i * 100));
      }
      await Future<void>.delayed(Duration.zero);

      expect(machine.state, ConversationState.notUserSpeaking);
      final ConversationStateChange last = machine.history.last;
      expect(last.reason, ConversationStateReason.silenceAccumulated);
      expect(last.previous, ConversationState.userSpeaking);
    });

    test('im lặng ngắn giữa câu KHÔNG reset đà nói (chống flicker, DoD 3)', () async {
      client.emit(_speech(100));
      client.emit(_speech(200));
      client.emit(_silence(300)); // 1 khung im lặng ngắn (ngập ngừng)
      client.emit(_speech(400));
      client.emit(_speech(500));
      await Future<void>.delayed(Duration.zero);

      expect(machine.state, ConversationState.userSpeaking,
          reason: 'bộ tích luỹ rò phải giữ được đà qua 1 buffer im lặng ngắn');
      expect(machine.history, hasLength(1));
    });

    test('nhiễu nền ngắn (dưới ngưỡng attack) KHÔNG kéo state', () async {
      client.emit(_silence(100));
      client.emit(_silence(200));
      client.emit(_speech(300)); // tiếng động ngắn 100ms
      client.emit(_silence(400));
      client.emit(_silence(500));
      await Future<void>.delayed(Duration.zero);

      expect(machine.state, ConversationState.notUserSpeaking);
      expect(machine.history, isEmpty);
    });

    test('ngưỡng tỉ lệ khung quyết định buffer có được coi là tiếng nói', () async {
      // ratio 0.2 (1/5) — không đủ, không được coi là tiếng nói.
      client.emit(_stat(speechFrames: 1, atMs: 100));
      client.emit(_stat(speechFrames: 1, atMs: 200));
      client.emit(_stat(speechFrames: 1, atMs: 300));
      await Future<void>.delayed(Duration.zero);
      expect(machine.state, ConversationState.notUserSpeaking,
          reason: 'nhiễu lẻ khung không được coi là tiếng nói');

      // ratio 0.6 (3/5) — đủ ngưỡng 0.5.
      client.emit(_stat(speechFrames: 3, atMs: 400));
      client.emit(_stat(speechFrames: 3, atMs: 500));
      client.emit(_stat(speechFrames: 3, atMs: 600));
      await Future<void>.delayed(Duration.zero);
      expect(machine.state, ConversationState.userSpeaking);
    });

    test('changes chỉ phát khi state ĐỔI (không phát lặp)', () async {
      final List<ConversationState> values = <ConversationState>[];
      machine.changes.listen(values.add);

      for (int i = 1; i <= 5; i++) {
        client.emit(_speech(i * 100));
      }
      await Future<void>.delayed(Duration.zero);

      expect(values, <ConversationState>[ConversationState.userSpeaking]);
    });

    test('lastStat được cập nhật theo buffer mới nhất', () async {
      client.emit(_stat(speechFrames: 4, atMs: 100));
      await Future<void>.delayed(Duration.zero);
      expect(machine.lastStat?.speechFrames, 4);
    });

    test('start() gọi hai lần là no-op an toàn', () {
      machine.start();
      expect(machine.isRunning, isTrue);
    });
  });

  group('ConversationStateMachine — lịch sử trong phiên', () {
    test('history chỉ giữ trong phiên và bị cắt theo historyLimit', () async {
      final _FakeVadClient client = _FakeVadClient();
      final ConversationStateMachine machine = ConversationStateMachine(
        client: client,
        config: const ConversationStateConfig(historyLimit: 3),
      );
      machine.start();

      int t = 0;
      for (int i = 0; i < 6; i++) {
        // 3 buffer nói -> bật, 15 buffer im -> tắt, lặp lại (mỗi vòng 2 lần chuyển state).
        for (int j = 0; j < 3; j++) {
          client.emit(_speech(t += 100));
        }
        for (int j = 0; j < 15; j++) {
          client.emit(_silence(t += 100));
        }
      }
      await Future<void>.delayed(Duration.zero);

      expect(machine.history.length, lessThanOrEqualTo(3));
      // Bản mới nhất ở cuối danh sách.
      expect(machine.history.last.state, ConversationState.notUserSpeaking);

      await machine.dispose();
      await client.close();
    });

    test('history là read-only với bên ngoài', () async {
      final _FakeVadClient client = _FakeVadClient();
      final ConversationStateMachine machine = ConversationStateMachine(client: client);
      machine.start();
      expect(
        () => machine.history.add(
          const ConversationStateChange(
            state: ConversationState.userSpeaking,
            previous: null,
            atMs: 0,
            reason: ConversationStateReason.started,
            speechRatio: 1,
          ),
        ),
        throwsUnsupportedError,
      );
      await machine.dispose();
      await client.close();
    });
  });

  group('Timeline hội thoại mẫu (Bàn giao P1B)', () {
    test('dựng timeline state cho một đoạn hội thoại tổng hợp', () async {
      final _FakeVadClient client = _FakeVadClient();
      final ConversationStateMachine machine = ConversationStateMachine(client: client);
      machine.start();

      // Kịch bản (mỗi buffer = 100ms):
      //   0.0–0.4s  : im lặng nền (chuẩn bị)
      //   0.4–2.4s  : người dùng nói (2.0s) -> phải bật userSpeaking
      //   2.4–3.4s  : im lặng ngắn (1.0s)   -> CHƯA đủ release, phải giữ userSpeaking
      //   3.4–4.4s  : nói tiếp (1.0s)       -> vẫn userSpeaking
      //   4.4–6.4s  : im lặng 2.0s          -> phải về notUserSpeaking
      int t = 0;
      void silenceFor(int buffers) {
        for (int i = 0; i < buffers; i++) {
          client.emit(_silence(t += 100));
        }
      }

      void speechFor(int buffers) {
        for (int i = 0; i < buffers; i++) {
          client.emit(_speech(t += 100));
        }
      }

      const int onsetMs = 400; // Kịch bản: bắt đầu nói ở 400ms.
      silenceFor(4); // 100..400ms im lặng.
      speechFor(20); // 500..2400ms nói.
      silenceFor(10); // 2500..3400ms im lặng ngắn (chưa đủ release).
      speechFor(10); // 3500..4400ms nói tiếp.
      silenceFor(20); // 4500..6400ms im lặng dài.
      await Future<void>.delayed(Duration.zero);

      final List<String> timeline =
          machine.history.map((ConversationStateChange c) => c.toString()).toList();

      // Timeline ghi lại được để đối chiếu khi chạy thật trên máy (DoD P1B).
      // ignore: avoid_print
      print('TIMELINE hội thoại mẫu:\n  ${timeline.join('\n  ')}');

      expect(machine.history, hasLength(2));
      expect(machine.history.first.state, ConversationState.userSpeaking);
      // F5 (review P1B): assert theo MỐC BẮT ĐẦU NÓI, không phải tuyệt đối với 0 — DoD là
      // "phản hồi <= 500ms từ lúc có tiếng nói". Bản cũ assert <= 900 (lỏng hơn DoD 700ms).
      expect(machine.history.first.atMs - onsetMs, lessThanOrEqualTo(500),
          reason: 'phải bật trong vòng 500ms tính từ lúc bắt đầu có tiếng nói (DoD 1)');
      expect(machine.history.last.state, ConversationState.notUserSpeaking);

      await machine.dispose();
      await client.close();
    });
  });

  group('Watchdog mở khoá khi mất dữ liệu VAD (F2)', () {
    late _FakeVadClient client;
    late ConversationStateMachine machine;

    setUp(() {
      client = _FakeVadClient();
      machine = ConversationStateMachine(client: client);
      // LƯU Ý: KHÔNG gọi machine.start() ở đây. Stream handler chạy trong zone nơi `listen()`
      // được đăng ký — nếu đăng ký ngoài `fakeAsync` thì Timer watchdog là Timer THẬT, nằm ngoài
      // đồng hồ giả và `async.elapse` không bao giờ làm nó nổ (bẫy zone đã mất 1 vòng debug).
    });

    tearDown(() async {
      await machine.dispose();
      await client.close();
    });

    test('đang userSpeaking mà không còn buffer > watchdogMs ⇒ mở khoá (inputStalled)',
        () async {
      fakeAsync((FakeAsync async) {
        machine.start(); // Đăng ký listener TRONG fake zone (xem LƯU Ý ở setUp).
        final List<ConversationStateChange> changes = <ConversationStateChange>[];
        machine.transitions.listen(changes.add);

        for (int i = 1; i <= 3; i++) {
          client.emit(_speech(i * 100)); // 300ms tiếng nói → khoá.
        }
        async.flushMicrotasks();
        expect(machine.state, ConversationState.userSpeaking);

        // Không phát thêm buffer nào — watchdog (1500ms) phải tự nổ.
        async.elapse(const Duration(milliseconds: 1499));
        expect(machine.state, ConversationState.userSpeaking,
            reason: 'chưa tới watchdog thì không mở khoá');

        async.elapse(const Duration(milliseconds: 1));
        expect(machine.state, ConversationState.notUserSpeaking,
            reason: 'watchdog phải mở khoá đúng sau watchdogMs');
        expect(changes.last.reason, ConversationStateReason.inputStalled);
        expect(machine.history.last.reason, ConversationStateReason.inputStalled);
      });
    });

    test('buffer VAD tiếp tục đến ⇒ watchdog được đẩy lùi, không nổ oan', () async {
      fakeAsync((FakeAsync async) {
        machine.start(); // Trong fake zone (xem LƯU Ý ở setUp).

        for (int i = 1; i <= 3; i++) {
          client.emit(_speech(i * 100));
        }
        async.flushMicrotasks();
        expect(machine.state, ConversationState.userSpeaking);

        // VAD vẫn phát (dù toàn im lặng) — deadline liên tục bị đẩy lùi.
        for (int i = 4; i <= 20; i++) {
          async.elapse(const Duration(milliseconds: 100));
          client.emit(_silence(i * 100));
        }
        // 17 buffer im lặng × 100ms = 1700ms > watchdogMs, nhưng watchdog liên tục re-arm.
        expect(machine.state, ConversationState.notUserSpeaking,
            reason: 'im lặng đủ releaseMs nên chuyển state theo luồng chính, không phải watchdog');
        expect(machine.history.last.reason, ConversationStateReason.silenceAccumulated);
      });
    });

    test('lỗi stream KHÔNG reset tức thì — watchdog mới là đường thoát (quyết định user)',
        () async {
      fakeAsync((FakeAsync async) {
        machine.start(); // Trong fake zone (xem LƯU Ý ở setUp).

        for (int i = 1; i <= 3; i++) {
          client.emit(_speech(i * 100));
        }
        async.flushMicrotasks();
        expect(machine.state, ConversationState.userSpeaking);

        client.emitError(const SocketException('kênh đứt'));
        async.flushMicrotasks();
        expect(machine.state, ConversationState.userSpeaking,
            reason: 'lỗi nhất thời không được mở khoá ngay');

        async.elapse(const Duration(milliseconds: 1500));
        expect(machine.state, ConversationState.notUserSpeaking,
            reason: 'sau watchdogMs không có buffer mới ⇒ mở khoá');
      });
    });
  });
}
