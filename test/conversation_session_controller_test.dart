// Test P4 — ConversationSessionController (orchestrator của pipeline + half-duplex).
//
// Đây là phần **không phụ thuộc máy** của P4: phần code của phase là lớp ráp nối, nên phải khoá được
// bằng test đúng những hành vi mà DoD của P4 nói tới:
// - DoD 2: ASR KHÔNG nhận audio trong lúc TTS đang phát (nếu không, mic sẽ thu chính giọng của app
//   thành transcript — feedback loop), và PHẢI nhận lại ngay sau khi đọc xong.
// - DoD 3: không bao giờ có 2 lần phát chồng nhau ⇒ Push trong lúc đang phát bị BỎ QUA (nhưng đây
//   KHÔNG phải cooldown: rảnh thì bấm bao nhiêu lần cũng được).
// - DoD 4: đo được độ trễ Push → native bắt đầu tổng hợp.
// - DoD 6: một module con lỗi (mic chết / ASR không nạp được model / ASR chết giữa chừng) ⇒ phiên
//   không sập, có phục hồi hoặc hạ cấp kèm thông báo.
//
// Mọi module con đều được thay bằng fake để test chạy không cần thiết bị, không đụng kênh native.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/audio/asr/asr_engine.dart';
import 'package:ai_assistant_phone/audio/asr/asr_engine_selector.dart';
import 'package:ai_assistant_phone/audio/asr/vosk_asr_engine.dart';
import 'package:ai_assistant_phone/audio/capture/capture_config.dart';
import 'package:ai_assistant_phone/audio/capture/capture_engine.dart';
import 'package:ai_assistant_phone/audio/emergency/emergency_phrase_service.dart';
import 'package:ai_assistant_phone/audio/nudge_delivery.dart';
import 'package:ai_assistant_phone/audio/output_mode_selector.dart';
import 'package:ai_assistant_phone/audio/tts/safe_tts_output.dart';
import 'package:ai_assistant_phone/audio/vad/conversation_state_notifier.dart';
import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/services/conversation_session_controller.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_models.dart';
import 'package:ai_assistant_phone/transcript/transcript_store.dart';
import 'package:ai_assistant_phone/trigger/trigger_manager.dart';

/// ---- Fake của các module con (cùng mẫu với test P1-P3: `implements` + ném ở `noSuchMethod`) ----

class _FakeCapture implements AudioCaptureEngine {
  final StreamController<Uint8List> _chunks = StreamController<Uint8List>.broadcast();
  final StreamController<CaptureStatus> _status = StreamController<CaptureStatus>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;
  CaptureError? startError;

  @override
  Stream<Uint8List> get chunks => _chunks.stream;

  @override
  Stream<CaptureStatus> get status => _status.stream;

  @override
  int get capturedBytes => 0;

  @override
  void onError(void Function(CaptureError error) handler) {}

  @override
  Future<CaptureConfig> start() async {
    startCalls++;
    final CaptureError? error = startError;
    if (error != null) {
      throw error;
    }
    return const CaptureConfig();
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> dispose() async {}

  Future<void> emitChunk(Uint8List chunk) async {
    _chunks.add(chunk);
    await pumpEventQueue();
  }

  Future<void> emitStatus(CaptureStatus value) async {
    _status.add(value);
    await pumpEventQueue();
  }
}

class _FakeConversation implements ConversationStateMachine {
  int startCalls = 0;
  int stopCalls = 0;

  @override
  void start() => startCalls++;

  @override
  Future<void> stop() async => stopCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeConversation không hỗ trợ ${invocation.memberName}');
}

class _FakeAsrEngine implements AsrEngine {
  _FakeAsrEngine({this.initFails = false, this.feedFailures = 0});

  /// `true` ⇒ `init()` ném (mô phỏng máy hết RAM / thiếu file model).
  bool initFails;

  /// Số lần `feedAudioChunk` ĐẦU TIÊN sẽ ném (mô phỏng engine chết giữa chừng).
  int feedFailures;

  final StreamController<String> _transcripts = StreamController<String>.broadcast();
  final List<int> fedChunkSizes = <int>[];
  int disposeCalls = 0;

  @override
  Future<void> init() async {
    if (initFails) {
      throw StateError('không nạp được model');
    }
  }

  @override
  Stream<String> get transcriptStream => _transcripts.stream;

  @override
  Future<void> feedAudioChunk(Uint8List chunk) async {
    if (feedFailures > 0) {
      feedFailures--;
      throw StateError('engine ASR chết khi đang nhận audio');
    }
    fedChunkSizes.add(chunk.lengthInBytes);
  }

  @override
  Future<void> dispose() async => disposeCalls++;

  @override
  int get droppedTotal => 0;

  void emitTranscript(String text) => _transcripts.add(text);
}

class _FakeTranscript implements TranscriptStore {
  int attachCalls = 0;
  int detachCalls = 0;
  AsrEngine? attachedEngine;

  @override
  void attach(AsrEngine engine) {
    attachCalls++;
    attachedEngine = engine;
  }

  @override
  Future<void> detach() async => detachCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeTranscript không hỗ trợ ${invocation.memberName}');
}

class _FakeTts implements SafeTtsOutput {
  final StreamController<bool> _speaking = StreamController<bool>.broadcast();
  int stopCalls = 0;

  @override
  Stream<bool> get speakingChanges => _speaking.stream;

  @override
  Future<void> stop() async => stopCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeTts không hỗ trợ ${invocation.memberName}');

  /// Mô phỏng native: bắt đầu tổng hợp (`true`) / đọc xong (`false`).
  Future<void> emitSpeaking(bool value) async {
    _speaking.add(value);
    await pumpEventQueue();
  }
}

class _FakeEmergency implements EmergencyPhraseService {
  int triggers = 0;

  @override
  Future<EmergencyTriggerResult> triggerEmergency() async {
    triggers++;
    return EmergencyTriggerResult.started;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeEmergency không hỗ trợ ${invocation.memberName}');
}

class _FakeTrigger implements TriggerManager {
  /// Gọi mỗi lần `onSuggestRequested` — test gài hành vi (trả kết quả / ném / nhích đồng hồ) sau khi
  /// đã dựng harness (đặt trong constructor sẽ tự tham chiếu chính harness đó).
  Future<TriggerOutcome> Function()? onPush;

  int pushCalls = 0;
  final _FakeEmergency emergencyService = _FakeEmergency();

  @override
  Future<TriggerOutcome> onSuggestRequested({
    SuggestTriggerSource source = SuggestTriggerSource.floatingButton,
  }) async {
    pushCalls++;
    final Future<TriggerOutcome> Function()? handler = onPush;
    return handler == null ? _nudgeOutcome() : handler();
  }

  @override
  Future<EmergencyTriggerResult> onEmergencyRequested() => emergencyService.triggerEmergency();

  @override
  EmergencyPhraseService get emergency => emergencyService;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeTrigger không hỗ trợ ${invocation.memberName}');
}

class _FakeConfigStore implements ConfigStore {
  _FakeConfigStore([Map<String, String>? initial]) : _values = <String, String>{...?initial};

  final Map<String, String> _values;
  bool throwOnWrite = false;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    if (throwOnWrite) {
      throw StateError('DB lỗi khi ghi cấu hình');
    }
    _values[key] = value;
  }
}

TriggerOutcome _nudgeOutcome({
  NudgeDeliveryResult delivery = NudgeDeliveryResult.spoken,
}) =>
    TriggerOutcome(
      source: SuggestTriggerSource.floatingButton,
      result: SuggestionResult.nudge(type: NudgeType.ask, text: 'hỏi thêm đi'),
      effectiveMode: delivery == NudgeDeliveryResult.spoken
          ? EffectiveNudgeOutput.ear
          : EffectiveNudgeOutput.text,
      delivery: delivery,
    );

/// Bộ đồ nghề dựng controller cho test: mọi module con đều là fake, không đụng DB/kênh native.
class _Harness {
  _Harness({List<_FakeAsrEngine>? engines, bool serviceStarts = true}) {
    capture = _FakeCapture();
    conversation = _FakeConversation();
    transcript = _FakeTranscript();
    tts = _FakeTts();
    trigger = _FakeTrigger();
    configStore = _FakeConfigStore();
    engineQueue = <_FakeAsrEngine>[...?engines];
    selector = AsrEngineSelector(
      configStore,
      (AsrEngineKind kind) =>
          engineQueue.isEmpty ? _FakeAsrEngine() : engineQueue.removeAt(0),
    );
    controller = ConversationSessionController(
      capture: capture,
      conversation: conversation,
      asrSelector: selector,
      transcript: transcript,
      trigger: trigger,
      tts: tts,
      startService: () async => serviceStarts,
      stopService: () async => serviceStopCalls++,
      now: () => DateTime(2026, 1, 1).add(Duration(milliseconds: clockMs)),
    );
  }

  late final _FakeCapture capture;
  late final _FakeConversation conversation;
  late final _FakeTranscript transcript;
  late final _FakeTts tts;
  late final _FakeTrigger trigger;
  late final _FakeConfigStore configStore;
  late final AsrEngineSelector selector;
  late final ConversationSessionController controller;
  late final List<_FakeAsrEngine> engineQueue;

  int serviceStopCalls = 0;
  int clockMs = 0;
}

/// Chunk PCM16 100ms @16kHz — đúng kích thước `CaptureConfig` mặc định phát ra.
final Uint8List _chunk = Uint8List(const CaptureConfig().chunkBytes);

void main() {
  // Cần binding để stub kênh native (test suy ra engine thật từ engine Vosk) và để `pumpEventQueue`
  // chạy được.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P4 — half-duplex: ASR không nghe chính giọng TTS của app (DoD 2)', () {
    test('đang phát ⇒ chunk bị CHẶN; đọc xong ⇒ ASR nhận lại ngay', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      final _FakeAsrEngine engine = h.engineQueue.first;
      await h.controller.start();
      expect(h.controller.phase, SessionPhase.listening);

      // 1) Chưa phát: chunk tới được engine.
      await h.capture.emitChunk(_chunk);
      expect(engine.fedChunkSizes.length, 1);
      expect(h.controller.chunksDroppedWhileSpeaking, 0);

      // 2) TTS bắt đầu phát ⇒ chunk bị chặn HOÀN TOÀN (không đưa vào ASR).
      await h.tts.emitSpeaking(true);
      expect(h.controller.phase, SessionPhase.speaking);
      await h.capture.emitChunk(_chunk);
      await h.capture.emitChunk(_chunk);
      expect(engine.fedChunkSizes.length, 1, reason: 'audio lúc đang phát không được vào ASR');
      expect(h.controller.chunksDroppedWhileSpeaking, 2);

      // 3) Đọc xong ⇒ mở lại NGAY (dừng mà không mở lại thì "dừng" hoá ra là tắt hẳn).
      await h.tts.emitSpeaking(false);
      expect(h.controller.phase, SessionPhase.listening);
      expect(h.controller.asrResumeCount, 1);
      await h.capture.emitChunk(_chunk);
      expect(engine.fedChunkSizes.length, 2);

      await h.controller.dispose();
    });

    test('nhiều lần phát liên tiếp ⇒ đếm đủ số lần mở lại cửa ASR', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      await h.controller.start();

      for (int i = 0; i < 3; i++) {
        await h.tts.emitSpeaking(true);
        await h.capture.emitChunk(_chunk);
        await h.tts.emitSpeaking(false);
        await h.capture.emitChunk(_chunk);
      }

      expect(h.controller.asrResumeCount, 3);
      expect(h.controller.chunksDroppedWhileSpeaking, 3);

      await h.controller.dispose();
    });

    test('phát khi ASR chưa nạp được ⇒ vẫn đếm chunk bị chặn (chốt nằm ở tầng phiên)', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[
        _FakeAsrEngine(initFails: true),
        _FakeAsrEngine(initFails: true),
      ]);
      await h.controller.start();
      expect(h.controller.isAsrRunning, isFalse);

      await h.tts.emitSpeaking(true);
      await h.capture.emitChunk(_chunk);
      await h.capture.emitChunk(_chunk);

      expect(h.controller.chunksDroppedWhileSpeaking, 2);
      await h.controller.dispose();
    });
  });

  group('P4 — race Push khi TTS đang phát (DoD 3: không bao giờ 2 tiếng chồng nhau)', () {
    test('Push trong lúc đang phát ⇒ BỎ QUA, không gọi TriggerManager', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      await h.controller.start();
      await h.tts.emitSpeaking(true);

      final TriggerOutcome? outcome = await h.controller.push();

      expect(outcome, isNull);
      expect(h.trigger.pushCalls, 0, reason: 'không được xin gợi ý mới khi câu trước còn đang đọc');
      expect(h.controller.overlapPreventedCount, 1);

      await h.controller.dispose();
    });

    test('đọc xong rồi bấm ⇒ đi qua bình thường (chốt này KHÔNG phải cooldown)', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      await h.controller.start();
      await h.tts.emitSpeaking(true);
      await h.controller.push(); // bị bỏ qua
      await h.tts.emitSpeaking(false);

      final TriggerOutcome? outcome = await h.controller.push();

      expect(outcome, isNotNull);
      expect(h.trigger.pushCalls, 1);
      expect(h.controller.overlapPreventedCount, 1);

      await h.controller.dispose();
    });

    test('bấm liên tiếp khi RẢNH ⇒ mọi lần đều đi qua (không cooldown ngoài Policy)', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      await h.controller.start();

      await h.controller.push();
      await h.controller.push();
      await h.controller.push();

      expect(h.trigger.pushCalls, 3);
      expect(h.controller.overlapPreventedCount, 0);

      await h.controller.dispose();
    });

    test('Emergency KHÔNG bị chốt chống-chồng-tiếng chặn (phải phát ngay)', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      await h.controller.start();
      await h.tts.emitSpeaking(true);

      final EmergencyTriggerResult result = await h.controller.triggerEmergency();

      expect(result, EmergencyTriggerResult.started);
      expect(h.trigger.emergencyService.triggers, 1);

      await h.controller.dispose();
    });
  });

  group('P4 — phục hồi lỗi từng module (DoD 6: không kéo sập cả phiên)', () {
    test('mic chết giữa phiên ⇒ dừng VAD/ASR/service, thông báo, KHÔNG ném', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      final List<String> notices = <String>[];
      h.controller.notices.listen(notices.add);
      await h.controller.start();

      await h.capture.emitStatus(CaptureStatus.error);

      expect(h.controller.isActive, isFalse);
      expect(h.controller.phase, SessionPhase.idle);
      expect(h.conversation.stopCalls, 1);
      expect(h.capture.stopCalls, 1);
      expect(h.serviceStopCalls, 1);
      expect(h.controller.recoveryCount, 1);
      expect(notices, isNotEmpty, reason: 'phải báo cho người dùng biết vì sao dừng');
      expect(h.transcript.detachCalls, greaterThan(0));

      await h.controller.dispose();
    });

    test('CẢ HAI engine ASR không init được ⇒ phiên VẪN chạy, chỉ mất transcript', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[
        _FakeAsrEngine(initFails: true),
        _FakeAsrEngine(initFails: true),
      ]);
      final List<String> notices = <String>[];
      h.controller.notices.listen(notices.add);

      final bool started = await h.controller.start();
      await pumpEventQueue(); // thông báo đi qua stream nên cần một nhịp để tới listener

      expect(started, isTrue, reason: 'mất ASR là suy giảm tính năng, không phải lý do dừng phiên');
      expect(h.controller.isActive, isTrue);
      expect(h.controller.phase, SessionPhase.listening);
      expect(h.controller.isAsrRunning, isFalse);
      expect(h.conversation.startCalls, 1, reason: 'VAD vẫn phải chạy để còn biết ai đang nói');
      expect(notices.single, contains('KHÔNG có transcript'));

      await h.controller.dispose();
    });

    test('ASR chết giữa chừng ⇒ tự khởi động lại 1 lần rồi chạy tiếp', () async {
      final _FakeAsrEngine first =
          _FakeAsrEngine(feedFailures: SessionConfig.maxConsecutiveAsrFeedFailures);
      final _FakeAsrEngine second = _FakeAsrEngine();
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[first, second]);
      final List<String> notices = <String>[];
      h.controller.notices.listen(notices.add);
      await h.controller.start();

      for (int i = 0; i < SessionConfig.maxConsecutiveAsrFeedFailures; i++) {
        await h.capture.emitChunk(_chunk);
      }
      await pumpEventQueue();

      expect(first.disposeCalls, 1, reason: 'engine hỏng phải được giải phóng trước khi dựng lại');
      expect(h.controller.asrRestartCount, 1);
      expect(h.controller.isAsrRunning, isTrue);
      expect(h.transcript.attachCalls, 2,
          reason: 'engine mới phải được gắn lại vào transcript store');
      expect(notices.single, contains('khởi động lại'));

      // Engine mới nhận audio bình thường.
      await h.capture.emitChunk(_chunk);
      expect(second.fedChunkSizes.length, 1);

      await h.controller.dispose();
    });

    test('ASR chết liên tục ⇒ hết lượt khởi động lại thì HẠ CẤP (không restart vô hạn)', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[
        for (int i = 0; i <= SessionConfig.maxAsrRestarts; i++)
          _FakeAsrEngine(feedFailures: SessionConfig.maxConsecutiveAsrFeedFailures),
      ]);
      final List<String> notices = <String>[];
      h.controller.notices.listen(notices.add);
      await h.controller.start();

      for (int round = 0; round <= SessionConfig.maxAsrRestarts; round++) {
        for (int i = 0; i < SessionConfig.maxConsecutiveAsrFeedFailures; i++) {
          await h.capture.emitChunk(_chunk);
        }
        await pumpEventQueue();
      }

      expect(h.controller.isAsrRunning, isFalse, reason: 'hết lượt khởi động lại ⇒ phải hạ cấp');
      expect(notices.any((String n) => n.contains('đã tắt')), isTrue);
      expect(h.controller.isActive, isTrue, reason: 'hạ cấp ASR KHÔNG được dừng cả phiên');

      await h.controller.dispose();
    });

    test('TriggerManager ném lỗi bất ngờ ⇒ nuốt lại, thông báo, trả null (không ném ra UI)',
        () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      final List<String> notices = <String>[];
      h.controller.notices.listen(notices.add);
      h.trigger.onPush = () async => throw StateError('lỗi lạ trong tầng gợi ý');
      await h.controller.start();

      final TriggerOutcome? outcome = await h.controller.push();
      await pumpEventQueue();

      expect(outcome, isNull);
      expect(notices.single, contains('Xin gợi ý lỗi'));
      expect(h.controller.phase, SessionPhase.listening, reason: 'pha phải được nhả về bình thường');

      await h.controller.dispose();
    });

    test('service bị từ chối ⇒ KHÔNG mở mic, thông báo, trả false', () async {
      final _Harness h = _Harness(serviceStarts: false);
      final List<String> notices = <String>[];
      h.controller.notices.listen(notices.add);

      final bool started = await h.controller.start();
      await pumpEventQueue();

      expect(started, isFalse);
      expect(h.capture.startCalls, 0);
      expect(h.controller.isActive, isFalse);
      expect(notices.single, contains('service'));

      await h.controller.dispose();
    });

    test('mở mic lỗi quyền ⇒ tắt service đã bật, thông báo, không ném', () async {
      final _Harness h = _Harness();
      h.capture.startError = const CapturePermissionDenied('Thiếu quyền ghi âm (micro).');
      final List<String> notices = <String>[];
      h.controller.notices.listen(notices.add);

      final bool started = await h.controller.start();

      expect(started, isFalse);
      expect(h.controller.isActive, isFalse);
      expect(h.serviceStopCalls, 1,
          reason: 'không được để notification "đang nghe" khi thực tế không thu gì');
      expect(notices.single, contains('Thiếu quyền'));

      await h.controller.dispose();
    });
  });

  group('P4 — số liệu cho DoD (độ trễ + pha phiên)', () {
    test('nudge được đọc ⇒ ghi độ trễ Push → native bắt đầu tổng hợp', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      h.trigger.onPush = () async {
        h.clockMs += 250; // LLM + tổng hợp mất 250ms
        return _nudgeOutcome();
      };
      await h.controller.start();

      await h.controller.push();

      expect(h.controller.averagePushLatency, const Duration(milliseconds: 250));

      await h.controller.dispose();
    });

    test('trung bình độ trễ tính trên nhiều mẫu', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      int step = 0;
      h.trigger.onPush = () async {
        step += 100;
        h.clockMs += step;
        return _nudgeOutcome();
      };
      await h.controller.start();

      await h.controller.push(); // 100ms
      await h.controller.push(); // 200ms

      expect(h.controller.averagePushLatency, const Duration(milliseconds: 150));

      await h.controller.dispose();
    });

    test('không phát nudge (chế độ chữ) ⇒ KHÔNG ghi mẫu độ trễ', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      h.trigger.onPush = () async {
        h.clockMs += 900;
        return _nudgeOutcome(delivery: NudgeDeliveryResult.textOnly);
      };
      await h.controller.start();

      await h.controller.push();

      expect(h.controller.averagePushLatency, isNull);

      await h.controller.dispose();
    });

    test('chuỗi pha: idle → listening → processing → speaking → listening → idle', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      final Completer<TriggerOutcome> gate = Completer<TriggerOutcome>();
      h.trigger.onPush = () => gate.future;
      final List<SessionPhase> phases = <SessionPhase>[];
      h.controller.phaseChanges.listen(phases.add);

      expect(h.controller.phase, SessionPhase.idle);
      await h.controller.start();
      expect(h.controller.phase, SessionPhase.listening);

      final Future<TriggerOutcome?> pending = h.controller.push();
      await pumpEventQueue();
      expect(h.controller.phase, SessionPhase.processing);

      gate.complete(_nudgeOutcome());
      await pumpEventQueue();
      await pending;

      await h.tts.emitSpeaking(true);
      expect(h.controller.phase, SessionPhase.speaking);
      await h.tts.emitSpeaking(false);
      expect(h.controller.phase, SessionPhase.listening);

      await h.controller.stop();
      await pumpEventQueue();
      expect(h.controller.phase, SessionPhase.idle);
      expect(h.controller.isActive, isFalse);
      expect(phases, <SessionPhase>[
        SessionPhase.listening,
        SessionPhase.processing,
        SessionPhase.listening, // xin gợi ý xong ⇒ trở lại trạng thái thu
        SessionPhase.speaking,
        SessionPhase.listening,
        SessionPhase.idle,
      ]);

      await h.controller.dispose();
    });
  });

  group('P4 — vòng đời phiên và cấu hình engine', () {
    test('start đúng thứ tự: service → capture → VAD → ASR (+ gắn transcript store)', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);

      await h.controller.start();

      expect(h.capture.startCalls, 1);
      expect(h.conversation.startCalls, 1);
      expect(h.controller.isAsrRunning, isTrue);
      expect(h.transcript.attachCalls, 1);
      expect(h.controller.sessionStartedAt, isNotNull);

      await h.controller.dispose();
    });

    test('start gọi lần hai khi đang chạy ⇒ không mở mic lần nữa', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      await h.controller.start();

      final bool again = await h.controller.start();

      expect(again, isTrue);
      expect(h.capture.startCalls, 1);

      await h.controller.dispose();
    });

    test('stop nhả ASR + transcript và tắt service', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      await h.controller.start();

      await h.controller.stop();

      expect(h.controller.isActive, isFalse);
      expect(h.serviceStopCalls, 1);
      expect(h.transcript.detachCalls, greaterThan(0));

      await h.controller.dispose();
    });

    test('đổi engine ⇒ dừng phiên + ghi cấu hình, KHÔNG tự bật lại', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      await h.controller.start();

      final bool saved = await h.controller.changeEngine(AsrEngineKind.vosk);

      expect(saved, isTrue);
      expect(await h.configStore.read(AsrEngineSelector.configKey), AsrEngineKind.vosk.id);
      expect(h.controller.isActive, isFalse, reason: 'không tự bật lại (người dùng phải bấm)');
      expect(h.controller.asrKind, AsrEngineKind.vosk);

      await h.controller.dispose();
    });

    test('ghi cấu hình lỗi ⇒ giữ engine cũ, trả false, không ném', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      h.configStore.throwOnWrite = true;
      await h.controller.start();

      final bool saved = await h.controller.changeEngine(AsrEngineKind.vosk);

      expect(saved, isFalse);
      expect(h.controller.asrKind, AsrEngineKind.phoWhisper);
      expect(await h.configStore.read(AsrEngineSelector.configKey), isNull);

      await h.controller.dispose();
    });

    test('engine THẬT đang chạy được suy ra từ engine trả về (không tin engine đã cấu hình)',
        () async {
      // Cấu hình là PhoWhisper nhưng `createAndInit` trả về engine Vosk (như khi fallback) ⇒ hiển thị
      // phải là Vosk, nếu không bảng so sánh 2 engine trên máy thật sẽ ghi nhầm tên engine.
      final MethodChannel channel = const MethodChannel(VoskChannels.control);
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final _Harness h = _Harness();
      final AsrEngineSelector selector = AsrEngineSelector(
        _FakeConfigStore(),
        (AsrEngineKind kind) => VoskAsrEngine(channel: channel),
      );
      final ConversationSessionController controller = ConversationSessionController(
        capture: h.capture,
        conversation: h.conversation,
        asrSelector: selector,
        transcript: h.transcript,
        trigger: h.trigger,
        tts: h.tts,
        startService: () async => true,
        stopService: () async {},
      );

      await controller.startAsr();

      expect(controller.asrKind, AsrEngineKind.vosk);
      expect(controller.isAsrRunning, isTrue);

      await controller.dispose();
    });

    test('dispose KHÔNG dừng service/capture (nghe tiếp khi ra nền là thiết kế của app)', () async {
      final _Harness h = _Harness(engines: <_FakeAsrEngine>[_FakeAsrEngine()]);
      await h.controller.start();

      await h.controller.dispose();

      expect(h.serviceStopCalls, 0);
      expect(h.capture.stopCalls, 0);
      expect(h.controller.isAsrRunning, isFalse, reason: 'model ASR phải được nhả khi teardown');
    });
  });
}
