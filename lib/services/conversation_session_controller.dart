import 'dart:async';
import 'dart:typed_data';

import '../audio/asr/asr_engine.dart';
import '../audio/asr/asr_engine_selector.dart';
import '../audio/asr/vosk_asr_engine.dart';
import '../audio/capture/audio_capture_controller.dart';
import '../audio/capture/capture_config.dart';
import '../audio/capture/capture_engine.dart';
import '../audio/emergency/emergency_phrase_service.dart';
import '../audio/nudge_delivery.dart';
import '../audio/tts/safe_tts_output.dart';
import '../audio/vad/conversation_state_notifier.dart';
import '../core/app_logger.dart';
import '../core/constants.dart';
import '../transcript/transcript_store.dart';
import '../trigger/trigger_manager.dart';
import 'foreground_service.dart';
import 'storage/meta_store.dart';

/// Pha điều phối **kỹ thuật** của phiên (gợi ý kỹ thuật của prompt P4).
///
/// Cố ý KHÔNG phải state ngữ nghĩa của hội thoại: `userSpeaking`/`notUserSpeaking` là việc của P1B,
/// còn các state ngữ nghĩa phức tạp (`TOPIC_DYING`, `AWKWARD_SILENCE`…) là việc của P6. Ở đây chỉ
/// trả lời đúng một câu hỏi: *"hệ thống đang bận làm gì?"* — để debug bằng log được, thay vì phải
/// đọc một mớ `if` lồng nhau.
enum SessionPhase {
  /// Chưa bật lắng nghe (hoặc vừa bị dừng vì lỗi mic).
  idle,

  /// Đang thu + VAD (+ ASR nếu nạp được). Không có gì đang phát, không có gợi ý nào đang bay.
  listening,

  /// Đang xin gợi ý (LLM đang chạy). Vẫn đang thu bình thường.
  processing,

  /// TTS đang phát ⇒ **half-duplex**: ASR tạm ngừng nhận chunk để không tự bắt giọng của chính app.
  speaking,
}

/// Orchestrator của phiên hội thoại (P4) — **nơi duy nhất** ráp P1A→P3 thành một pipeline.
///
/// Vì sao cần lớp này: trước P4, việc nối module nằm rải trong `HomeScreen` (`_toggleService`,
/// `_startAsr`…), nên không có chỗ nào **thực sự thi hành** ràng buộc half-duplex — mỗi module chạy
/// đúng khi test riêng, nhưng khi chạy cùng nhau thì ASR vẫn nhận audio trong lúc TTS đang đọc và
/// biến giọng của app thành transcript. Đây đúng là loại lỗi mà prompt P4 cảnh báo.
///
/// Trách nhiệm (đúng 5 task của prompt P4):
/// 1. Điều phối vòng đời: service → capture → VAD → ASR (+ transcript store).
/// 2. **Half-duplex**: chặn chunk vào ASR trong lúc [SafeTtsOutput] đang phát, mở lại ngay khi xong.
/// 3. Xử lý race: Push trong lúc nudge trước đang phát ⇒ **bỏ qua** (không bao giờ 2 tiếng chồng nhau).
/// 4. Đo số liệu cho DoD: độ trễ Push→bắt đầu tổng hợp, số chunk bị chặn, số lần ASR được mở lại.
/// 5. Phục hồi lỗi từng module: mic chết / ASR init lỗi / ASR feed lỗi liên tục ⇒ hạ cấp có thông
///    báo, **không** kéo sập cả phiên.
///
/// Ràng buộc kiến trúc (giữ đúng ranh giới đã thiết kế ở P1-P3):
/// - KHÔNG tự xử lý audio ở đây: mọi thứ đi qua facade có sẵn ([AudioCaptureEngine],
///   [ConversationStateMachine], [AsrEngineSelector], [TranscriptStore], [TriggerManager]).
/// - KHÔNG phát âm thanh bằng đường nào khác ngoài [SafeTtsOutput] (ràng buộc xuyên phase từ P1F).
/// - KHÔNG tự quyết định "có nên gợi ý hay không": Policy chặn cứng `userSpeaking` + debounce vẫn
///   nằm trong `SuggestionPolicy` (P2). Lớp này chỉ quyết định **thứ tự và thời điểm**, không quyết
///   định nội dung.
///
/// **Đây KHÔNG phải nơi chứa logic nghiệp vụ nào** — nếu thấy mình đang thêm một nhánh "nếu đang
/// nói thì…", khả năng cao chỗ đúng là `SuggestionPolicy` (P2) hoặc `OutputModeSelector` (P3).
class ConversationSessionController {
  ConversationSessionController({
    AudioCaptureEngine? capture,
    ConversationStateMachine? conversation,
    AsrEngineSelector? asrSelector,
    TranscriptStore? transcript,
    TriggerManager? trigger,
    SafeTtsOutput? tts,
    Future<bool> Function()? startService,
    Future<void> Function()? stopService,
    DateTime Function()? now,
  })  : _capture = capture ?? AudioCapture.instance,
        _conversation = conversation ?? ConversationStateNotifier.instance,
        _asrSelector = asrSelector ?? AsrEngineSelector(const MetaConfigStore()),
        _transcript = transcript ?? TranscriptStore.instance(),
        _trigger = trigger ?? TriggerManager(),
        _tts = tts ?? SafeTtsOutput.instance(),
        _startService = startService ?? ListeningService.start,
        _stopService = stopService ?? ListeningService.stop,
        _now = now ?? DateTime.now;

  static const AppLogger _log = AppLogger('Session');

  final AudioCaptureEngine _capture;
  final ConversationStateMachine _conversation;
  final AsrEngineSelector _asrSelector;
  final TranscriptStore _transcript;

  /// Toàn bộ chồng gợi ý của P2/P3 (Policy → LLM → cache → output mode → giao nudge). Lớp này chỉ
  /// gọi đúng một hàm của nó ([TriggerManager.onSuggestRequested]) — không tự gọi LLM/TTS.
  final TriggerManager _trigger;

  /// Cổng phát duy nhất (P1F). Ở đây chỉ dùng để **nghe** sự kiện đang-đọc/đã-xong và để dừng khi
  /// kết thúc phiên — không tự phát gì.
  ///
  /// ⚠️ Khi test bơm `tts` giả thì PHẢI bơm cả `trigger` giả dùng **cùng** đối tượng TTS đó, nếu
  /// không tín hiệu half-duplex sẽ đến từ một đường phát khác với đường đang thật sự đọc.
  final SafeTtsOutput _tts;

  final Future<bool> Function() _startService;
  final Future<void> Function() _stopService;
  final DateTime Function() _now;

  final StreamController<SessionPhase> _phaseChanges =
      StreamController<SessionPhase>.broadcast();
  final StreamController<String> _notices = StreamController<String>.broadcast();

  /// Độ trễ các lần Push đã đọc được (chỉ giữ [SessionConfig.latencySampleLimit] mẫu gần nhất).
  final List<Duration> _pushLatencies = <Duration>[];

  // Subscription được `cancel()` trong `dispose()` (và lấy tham chiếu ra trước `await`), không huỷ
  // ngay trong hàm gán — lint `cancel_subscriptions` chỉ nhìn phạm vi một hàm nên báo nhầm ở đây.
  // ignore: cancel_subscriptions
  StreamSubscription<Uint8List>? _chunkSub;
  // ignore: cancel_subscriptions
  StreamSubscription<bool>? _speakingSub;
  // ignore: cancel_subscriptions
  StreamSubscription<CaptureStatus>? _captureStatusSub;
  // ignore: cancel_subscriptions
  StreamSubscription<String>? _transcriptSub;

  bool _active = false;
  bool _speaking = false;
  bool _pushInFlight = false;
  bool _busy = false;

  /// Pha đã phát ra `phaseChanges` lần cuối — tránh phát lặp cùng một pha.
  SessionPhase _emittedPhase = SessionPhase.idle;

  AsrEngine? _asr;
  AsrEngineKind _asrKind = AsrEngineSelector.defaultKind;
  String _lastTranscriptText = '(chưa có)';

  int _asrFeedFailures = 0;
  int _asrRestarts = 0;
  int _asrAudioBytes = 0;
  int _chunksDroppedWhileSpeaking = 0;
  int _asrResumeCount = 0;
  int _overlapPreventedCount = 0;
  int _recoveryCount = 0;
  DateTime? _sessionStartedAt;

  /// Pha hiện tại — **suy ra** từ trạng thái thật (không lưu song song). Một pha lưu riêng sẽ có
  /// ngày lệch với thực tế mỗi khi một nhánh thoát sớm quên cập nhật.
  SessionPhase get phase {
    if (!_active) {
      return SessionPhase.idle;
    }
    if (_speaking) {
      return SessionPhase.speaking;
    }
    if (_pushInFlight) {
      return SessionPhase.processing;
    }
    return SessionPhase.listening;
  }

  /// Phát khi pha đổi (UI vẽ lại; cũng là mốc để đọc log khi test máy thật).
  Stream<SessionPhase> get phaseChanges => _phaseChanges.stream;

  /// Thông báo cho người dùng khi một module con hỏng / bị hạ cấp (P4 task 5). Nội dung là câu tiếng
  /// Việt hiển thị được ngay — UI chỉ việc đưa lên SnackBar.
  Stream<String> get notices => _notices.stream;

  bool get isActive => _active;

  bool get isBusy => _busy;

  bool get isSpeaking => _speaking;

  bool get isAsrRunning => _asr != null;

  AsrEngineKind get asrKind => _asrKind;

  int get asrAudioBytes => _asrAudioBytes;

  /// Số chunk engine tự bỏ vì không theo kịp thời gian thực (số đo của P1C/P1D, đọc qua facade).
  int get asrDroppedChunks => _asr?.droppedTotal ?? 0;

  /// Text nhận dạng gần nhất (màn hình chẩn đoán).
  String get lastTranscriptText => _lastTranscriptText;

  /// Số chunk đã bị **chặn không cho vào ASR** vì TTS đang phát (bằng chứng half-duplex — DoD 2/3).
  int get chunksDroppedWhileSpeaking => _chunksDroppedWhileSpeaking;

  /// Số lần ASR được mở lại sau khi TTS đọc xong (bằng chứng nửa sau của half-duplex: có dừng thì
  /// phải có chạy lại, nếu không "dừng" hoá ra là "tắt hẳn").
  int get asrResumeCount => _asrResumeCount;

  /// Số lần bấm Push bị bỏ qua vì nudge trước đang phát (bằng chứng DoD 3: không chồng 2 TTS).
  int get overlapPreventedCount => _overlapPreventedCount;

  /// Số lần một module con đã được khởi động lại / hạ cấp (bằng chứng DoD 6).
  int get recoveryCount => _recoveryCount;

  int get asrRestartCount => _asrRestarts;

  /// Trung bình độ trễ `Push → native bắt đầu tổng hợp` trên các mẫu gần nhất (DoD 4).
  ///
  /// Đây là con số DoD yêu cầu ("độ trễ Push → nudge trung bình"). Từng mẫu riêng lẻ (để thấy cú
  /// sốc) được ghi vào log mỗi lần đo — không mở thêm getter chỉ để hiển thị con số cuối cùng.
  ///
  /// Định nghĩa độ trễ **giống P1G** (đã dùng cho Emergency Phrase): đo tới lúc native *nhận* và bắt
  /// đầu tổng hợp, KHÔNG tính thời gian đọc câu — đây là phần độ trễ mà app kiểm soát được; thời gian
  /// đọc còn phụ thuộc độ dài câu và tốc độ đọc người dùng chọn.
  Duration? get averagePushLatency {
    if (_pushLatencies.isEmpty) {
      return null;
    }
    final int totalMs = _pushLatencies.fold<int>(
      0,
      (int sum, Duration value) => sum + value.inMilliseconds,
    );
    return Duration(milliseconds: totalMs ~/ _pushLatencies.length);
  }

  DateTime? get sessionStartedAt => _sessionStartedAt;

  /// Các module con (UI cần để hiển thị/chỉnh cấu hình — không tự dựng instance riêng).
  TriggerManager get trigger => _trigger;

  TranscriptStore get transcript => _transcript;

  ConversationStateMachine get conversation => _conversation;

  EmergencyPhraseService get emergency => _trigger.emergency;

  // ------------------------------------------------------------------ vòng đời phiên

  /// Bật phiên lắng nghe: service → capture → VAD → ASR (đúng thứ tự cũ của P0.5/P1A).
  ///
  /// Không bao giờ ném: mọi nhánh lỗi đều quy về `false` + một thông báo cho người dùng.
  Future<bool> start() async {
    if (_active || _busy) {
      return _active;
    }
    _busy = true;
    try {
      final bool serviceStarted = await _startService();
      if (!serviceStarted) {
        _notify('Không bật được service (thiếu quyền micro?)');
        return false;
      }
      try {
        await _capture.start();
      } on CaptureError catch (error) {
        _notify(error.message);
        await _stopService();
        return false;
      } catch (error) {
        _log.error('mở micro lỗi không phân loại: $error');
        _notify('Không mở được micro: $error');
        await _stopService();
        return false;
      }

      _subscribeRuntime();
      _active = true;
      _sessionStartedAt = _now();
      _resetSessionCounters();
      _conversation.start();
      _syncPhase();
      await startAsr();
      _log.info('phiên đã bật (ASR=${_asr == null ? "không" : _asrKind.id})');
      return true;
    } catch (error, stackTrace) {
      // Lưới an toàn cuối: `start()` không được phép ném ra UI.
      _log.error('bật phiên lỗi ngoài dự kiến', error, stackTrace);
      _notify('Không bật được phiên: $error');
      return false;
    } finally {
      _busy = false;
      _syncPhase();
    }
  }

  /// Tắt phiên. Thứ tự nhả: ASR (model nặng nhất) → VAD → capture → service — mic luôn được nhả
  /// trước khi tiến trình hết foreground.
  Future<void> stop() async {
    if (_busy) {
      return;
    }
    _busy = true;
    try {
      await stopAsr();
      _active = false;
      _sessionStartedAt = null;
      await _conversation.stop();
      await _capture.stop();
      await _stopService();
      _log.info('phiên đã tắt');
    } catch (error, stackTrace) {
      _log.error('tắt phiên lỗi', error, stackTrace);
    } finally {
      _busy = false;
      _syncPhase();
    }
  }

  /// Giải phóng tài nguyên của **lớp điều phối** (gọi khi màn hình/app kết thúc).
  ///
  /// Cố ý KHÔNG dừng foreground service / capture / VAD: thiết kế của app là nghe tiếp khi ra nền
  /// (`stopWithTask: false`), việc dừng service là quyết định của người dùng qua nút "Tắt lắng nghe".
  Future<void> dispose() async {
    await stopAsr();
    await _speakingSub?.cancel();
    await _captureStatusSub?.cancel();
    await _chunkSub?.cancel();
    await _tts.stop();
    await _phaseChanges.close();
    await _notices.close();
  }

  /// Xoá số đếm khi **bắt đầu một phiên mới**.
  ///
  /// Vì sao cần: các số này là BẰNG CHỨNG cho DoD ("trong 1 phiên hội thoại 30 phút, ASR bị chặn bao
  /// nhiêu lần khi TTS phát, có lần nào 2 tiếng chồng nhau không"). Nếu tích tụ từ các lần bật/tắt
  /// trước đó thì người đọc số không biết con số đang nói về phiên nào — mất giá trị làm bằng chứng.
  void _resetSessionCounters() {
    _chunksDroppedWhileSpeaking = 0;
    _asrResumeCount = 0;
    _overlapPreventedCount = 0;
    _recoveryCount = 0;
    _asrRestarts = 0;
    _pushLatencies.clear();
  }

  // ------------------------------------------------------------------ đăng ký runtime

  /// Đăng ký các nguồn sự kiện của phiên. Idempotent: gọi lại không tạo subscription trùng.
  void _subscribeRuntime() {
    _speakingSub ??= _tts.speakingChanges.listen(_onSpeakingChanged);
    _captureStatusSub ??= _capture.status.listen(_onCaptureStatus);
    // Đăng ký ở tầng phiên (không phải trong `startAsr`) để việc **chặn chunk khi đang phát** vẫn
    // được đếm kể cả khi ASR chưa/không nạp được — số đếm đó là bằng chứng cho half-duplex.
    _chunkSub ??= _capture.chunks.listen(_onChunk);
  }

  /// **Chốt half-duplex** (P4 task 1 + DoD 2).
  ///
  /// Trong lúc TTS phát, audio từ mic bị **vứt bỏ hoàn toàn** thay vì đưa vào ASR: tai nghe A2DP
  /// vẫn rò một phần tiếng ra ngoài, và mic điện thoại sẽ thu lại chính giọng đọc của app — nếu đưa
  /// vào ASR thì transcript chứa "lời của chính app", đúng feedback loop mà DoD 2 cấm.
  void _onChunk(Uint8List chunk) {
    if (_speaking) {
      _chunksDroppedWhileSpeaking++;
      return;
    }
    final AsrEngine? engine = _asr;
    if (engine == null) {
      return;
    }
    unawaited(_feedAsr(engine, chunk));
  }

  void _onSpeakingChanged(bool speaking) {
    final bool finished = _speaking && !speaking;
    _speaking = speaking;
    if (finished && _asr != null) {
      // Đếm cả khi phiên đã bị dừng giữa chừng: cái cần chứng minh là "cửa ASR đã mở lại".
      _asrResumeCount++;
      _log.info('TTS đọc xong ⇒ ASR nhận lại chunk (lần $_asrResumeCount)');
    }
    _syncPhase();
  }

  /// Mic chết giữa phiên (P4 task 5).
  ///
  /// Cố ý nghe theo `status` CHỨ không dùng `errors`: `errors` là tiện ích riêng của
  /// `AudioCaptureController` (ngoài hợp đồng engine của P1A), còn `CaptureStatus.error` nằm trong
  /// hợp đồng — nhờ vậy mọi engine capture cắm vào sau này đều được xử lý, kể cả engine không có
  /// stream lỗi. Hợp đồng P1A đã bảo đảm engine tự dừng sạch trước khi chuyển sang trạng thái lỗi.
  void _onCaptureStatus(CaptureStatus status) {
    if (status != CaptureStatus.error) {
      return;
    }
    _log.warn('capture chuyển sang trạng thái lỗi giữa phiên');
    _notify('Micro gặp lỗi — đã dừng phiên. Bấm "Bật lắng nghe" để thử lại.');
    unawaited(_handleCaptureLoss());
  }

  /// Mic chết (P4 task 5): hạ cấp **cả phiên** nhưng không làm app chết — dừng VAD/ASR, tắt service
  /// để notification không còn nói "đang lắng nghe" trong khi thực tế không thu gì. Người dùng bấm
  /// "Bật lắng nghe" để thử lại.
  Future<void> _handleCaptureLoss() async {
    if (!_active) {
      return;
    }
    _recoveryCount++;
    _active = false;
    _sessionStartedAt = null;
    _syncPhase();
    await stopAsr();
    await _conversation.stop();
    await _capture.stop();
    await _stopService();
    _syncPhase();
  }

  // ------------------------------------------------------------------ ASR (+ phục hồi)

  /// Bật (hoặc bật lại) ASR cho phiên. Không ném.
  ///
  /// Nếu **cả hai** engine đều không `init()` được, phiên KHÔNG chết: vẫn nghe + VAD, chỉ mất
  /// transcript, kèm một thông báo rõ ràng (P4 task 5). Đây là khác biệt có chủ ý so với việc ném lỗi
  /// lên UI như trước P4 — mất transcript là suy giảm tính năng, không phải lý do để dừng cả phiên.
  Future<bool> startAsr() async {
    if (_asr != null) {
      return true;
    }
    _subscribeRuntime();
    try {
      final AsrEngine engine = await _asrSelector.createAndInit();
      _attachAsr(engine);
      _log.info('ASR đã bật: ${_asrKind.id}');
      return true;
    } catch (error, stackTrace) {
      _log.error('không nạp được engine ASR nào', error, stackTrace);
      _notify('Không nạp được model nhận dạng — vẫn nghe nhưng sẽ KHÔNG có transcript.');
      return false;
    }
  }

  /// Tắt ASR (nhả model + ngắt khỏi transcript store). Không ném.
  Future<void> stopAsr() async {
    final AsrEngine? engine = _asr;
    _asr = null;
    _asrFeedFailures = 0;
    await _transcriptSub?.cancel();
    _transcriptSub = null;
    try {
      await _transcript.detach();
    } catch (error) {
      _log.warn('ngắt transcript store lỗi (vẫn tiếp tục tắt ASR): $error');
    }
    if (engine == null) {
      return;
    }
    try {
      await engine.dispose();
      _log.info('ASR đã tắt (${_asrKind.id})');
    } catch (error) {
      // Dispose lỗi không được làm chết phiên — model coi như đã bị bỏ.
      _log.warn('dispose ASR lỗi: $error');
    }
  }

  void _attachAsr(AsrEngine engine) {
    _asr = engine;
    // Suy ra engine THẬT đang chạy thay vì engine đã cấu hình: `createAndInit()` có thể đã fallback
    // sang engine còn lại (P1D) — hiển thị nhầm engine là báo cáo sai trên máy thật.
    _asrKind = engine is VoskAsrEngine ? AsrEngineKind.vosk : AsrEngineKind.phoWhisper;
    _asrAudioBytes = 0;
    _asrFeedFailures = 0;
    _lastTranscriptText = '(chưa có)';
    // P1E: mọi text engine phát ra đi thẳng vào transcript store (store tự hủy subscription cũ).
    _transcript.attach(engine);
    // Màn hình chẩn đoán cần text gần nhất; `transcriptStream` là broadcast nên nghe song song với
    // store là hợp lệ. Subscription được giữ lại để `stopAsr()` huỷ HẲN — nếu không, mỗi lần khởi
    // động lại ASR lại để lại một subscription sống trên object đã bị bỏ.
    _transcriptSub = engine.transcriptStream.listen(
      (String text) => _lastTranscriptText = text,
      onError: (Object error) => _log.warn('stream transcript ASR lỗi: $error'),
    );
  }

  Future<void> _feedAsr(AsrEngine engine, Uint8List chunk) async {
    _asrAudioBytes += chunk.lengthInBytes;
    try {
      await engine.feedAudioChunk(chunk);
      _asrFeedFailures = 0;
    } catch (error) {
      _asrFeedFailures++;
      _log.warn('feed ASR lỗi (lần $_asrFeedFailures liên tiếp): $error');
      if (_asrFeedFailures >= SessionConfig.maxConsecutiveAsrFeedFailures) {
        _asrFeedFailures = 0;
        unawaited(_recoverAsr());
      }
    }
  }

  /// Khởi động lại ASR sau khi feed lỗi liên tiếp, có trần số lần (P4 task 5).
  ///
  /// Vì sao khởi động lại chứ không chỉ tắt: engine ASR là module dễ chết nhất trong pipeline
  /// (native, giữ model vài trăm MB) mà lại là module **có thể dựng lại được**; tắt luôn sẽ biến một
  /// lỗi tạm thời thành mất tính năng cho hết phiên.
  Future<void> _recoverAsr() async {
    _recoveryCount++;
    if (_asrRestarts >= SessionConfig.maxAsrRestarts) {
      _log.warn('ASR lỗi liên tiếp và đã hết lượt khởi động lại ⇒ hạ cấp');
      _notify('Nhận dạng lỗi nhiều lần — đã tắt để phiên tiếp tục chạy (vẫn nghe, không transcript).');
      await stopAsr();
      return;
    }
    _asrRestarts++;
    _notify('Nhận dạng gặp lỗi — đang khởi động lại '
        '(lần $_asrRestarts/${SessionConfig.maxAsrRestarts}).');
    _log.warn('khởi động lại ASR (lần $_asrRestarts)');
    await stopAsr();
    await startAsr();
  }

  // ------------------------------------------------------------------ trigger

  /// **Điểm vào duy nhất** cho mọi nguồn Push của phiên (nút nổi, nút chẩn đoán, adapter sau này).
  ///
  /// Trả `null` khi lần bấm bị **bỏ qua** vì nudge trước đang phát (đã có thông báo cho người dùng).
  ///
  /// ⚠️ Chốt này **không phải cooldown**: cooldown (12-15s, chặn cả khi rảnh) chỉ thuộc semi-auto mode
  /// P6 — ràng buộc xuyên phase. Ở đây chỉ chặn đúng khoảng thời gian có tiếng đang phát, tức khoảng
  /// thời gian mà cho qua sẽ làm câu đang đọc bị cắt giữa từ (native luôn `pause()` track cũ trước
  /// khi phát câu mới). Người dùng bấm lại sau khi đọc xong là được ngay.
  Future<TriggerOutcome?> push({
    SuggestTriggerSource source = SuggestTriggerSource.floatingButton,
  }) async {
    if (_speaking) {
      _overlapPreventedCount++;
      _log.info('Push bị bỏ qua: TTS đang phát (chống chồng tiếng)');
      _notify('Đang đọc gợi ý trước — bỏ qua lần bấm này.');
      return null;
    }
    _pushInFlight = true;
    _syncPhase();
    final DateTime startedAt = _now();
    try {
      final TriggerOutcome outcome = await _trigger.onSuggestRequested(source: source);
      if (outcome.delivery == NudgeDeliveryResult.spoken) {
        _recordPushLatency(_now().difference(startedAt));
      }
      return outcome;
    } catch (error, stackTrace) {
      // `TriggerManager` đã tự cam kết không ném; đây là lưới an toàn cuối cùng của phiên.
      _log.error('push lỗi ngoài dự kiến', error, stackTrace);
      _notify('Xin gợi ý lỗi: $error');
      return null;
    } finally {
      _pushInFlight = false;
      _syncPhase();
    }
  }

  /// Emergency Phrase — đường thoát hiểm (P1G/P3).
  ///
  /// Cố ý **KHÔNG** bị chốt chống-chồng-tiếng chặn như [push]: đây là câu phải phát ngay lúc nguy
  /// cấp, chậm một nhịp vì "đang đọc câu khác" là mất đúng mục đích. An toàn vẫn giữ nguyên vì
  /// `SafeTtsBridge.speak()` luôn `pause()` track đang phát trước khi phát câu mới ⇒ về mặt vật lý
  /// không thể có hai tiếng chồng nhau.
  Future<EmergencyTriggerResult> triggerEmergency() => _trigger.onEmergencyRequested();

  void _recordPushLatency(Duration latency) {
    _pushLatencies.add(latency);
    if (_pushLatencies.length > SessionConfig.latencySampleLimit) {
      _pushLatencies.removeAt(0);
    }
    final Duration? average = averagePushLatency;
    _log.info(
      'độ trễ Push → native bắt đầu tổng hợp: ${latency.inMilliseconds}ms '
      '(trung bình ${average?.inMilliseconds ?? latency.inMilliseconds}ms / '
      '${_pushLatencies.length} mẫu)',
    );
  }

  // ------------------------------------------------------------------ cấu hình engine

  /// Đọc engine đã cấu hình (lúc mở màn hình). Không ghi đè engine đang chạy.
  Future<AsrEngineKind> readConfiguredEngine() async {
    if (_asr != null) {
      return _asrKind;
    }
    try {
      _asrKind = await _asrSelector.readConfigured();
    } catch (error) {
      _log.warn('không đọc được cấu hình engine ASR: $error');
      _asrKind = AsrEngineSelector.defaultKind;
    }
    return _asrKind;
  }

  /// Đổi engine nhận dạng (P1D): **dừng hẳn** phiên rồi ghi cấu hình, KHÔNG tự bật lại.
  ///
  /// Đổi engine ngay giữa lúc thu làm app lỗi (engine cũ bị `dispose()` trong khi capture còn bơm
  /// chunk và store còn attach) — đây là lỗi đã gặp thật, xem `LESSONS_LEARNED.md`. Trả `false` nếu
  /// không ghi được cấu hình (khi đó giữ nguyên engine cũ).
  Future<bool> changeEngine(AsrEngineKind kind) async {
    if (kind == _asrKind && !_active) {
      return true; // đã đúng engine và phiên đang tắt ⇒ không cần làm gì
    }
    await stop();
    try {
      await _asrSelector.writeConfigured(kind);
    } catch (error) {
      _log.warn('không ghi được cấu hình engine ASR: $error');
      _notify('Không lưu được lựa chọn engine: $error');
      return false;
    }
    _asrKind = kind;
    _log.info('đã đổi engine ASR sang ${kind.id} (phiên đang tắt)');
    return true;
  }

  // ------------------------------------------------------------------ nội bộ

  void _syncPhase() {
    final SessionPhase next = phase;
    if (next == _emittedPhase) {
      return;
    }
    _emittedPhase = next;
    _log.info('pha phiên: ${next.name}');
    if (!_phaseChanges.isClosed) {
      _phaseChanges.add(next);
    }
  }

  void _notify(String message) {
    if (_notices.isClosed) {
      return;
    }
    _notices.add(message);
  }
}
