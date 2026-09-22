import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../audio/asr/asr_engine.dart';
import '../audio/asr/asr_engine_selector.dart';
import '../audio/emergency/emergency_phrase_service.dart';
import '../audio/tts/safe_tts_output.dart';
import '../audio/tts/tts_client.dart';
import '../transcript/transcript_store.dart';
import '../audio/capture/audio_capture_controller.dart';
import '../audio/capture/capture_config.dart';
import '../audio/vad/conversation_state.dart';
import '../audio/vad/conversation_state_notifier.dart';
import '../audio/nudge_delivery.dart';
import '../audio/output_mode_selector.dart';
import '../core/app_logger.dart';
import '../core/constants.dart';
import '../suggestion/suggestion_models.dart';
import '../trigger/trigger_manager.dart';
import 'floating_button.dart';
import '../services/foreground_service.dart';
import '../services/permission_gate.dart';
import '../services/storage/app_database.dart';
import '../services/storage/meta_store.dart';
import '../services/storage/secure_store.dart';

/// Màn hình chính tối thiểu của P0.5.
///
/// Ở phase này màn hình chỉ cần: hiện trạng thái "Sẵn sàng"/"Đang lắng nghe" + nút bật/tắt
/// service, đồng thời phơi ra trạng thái các mảnh hạ tầng đã dựng (quyền, SQLite, secure storage)
/// để test tay trên máy thật không phải đọc log.
/// Pre-Brief / floating button / settings là việc của các phase sau (P5, P3).
///
/// F4 (review P1B): màn hình **sống theo sự kiện** chứ không chỉ vẽ lại khi bấm nút:
/// - dòng "Thu âm" tự cập nhật theo stream `status` của controller;
/// - lỗi giữa luồng capture hiện lên bằng SnackBar (trước đây lỗi lỗi mà UI vẫn ghi "đang ghi");
/// - dòng "Hội thoại" tự vẽ lại theo từng stat VAD (ratio cập nhật 10 lần/s, không đóng băng
///   giữa 2 lần chuyển state) nhờ `ValueNotifier` cập nhật trong `_conversation`.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const AppLogger _log = AppLogger('HomeScreen');

  bool _serviceRunning = false;
  bool _busy = false;
  String _databaseStatus = 'chưa kiểm tra';
  bool? _hasApiKey;
  Map<String, bool> _permissions = <String, bool>{};

  /// Controller capture dùng chung (lazy singleton) — chỉ chạm kênh native khi thực sự dùng.
  final AudioCaptureController _capture = AudioCapture.instance;

  /// State machine hội thoại (P1B) — P2 sẽ dùng chính instance này để chặn gọi LLM.
  final ConversationStateMachine _conversation = ConversationStateNotifier.instance;

  /// Đếm version của stat VAD gần nhất: ValueNotifier thay đổi giá trị mỗi buffer (10/s) để
  /// ValueListenableBuilder vẽ lại dòng "Hội thoại" mà không rebuild cả card.
  final ValueNotifier<int> _vadTick = ValueNotifier<int>(0);
  StreamSubscription<CaptureStatus>? _captureStatusSub;
  StreamSubscription<CaptureError>? _captureErrorSub;
  StreamSubscription<VadFrameStat>? _vadStatSub;
  bool _snackQueueBusy = false;
  final List<String> _snackQueue = <String>[];

  /// P1D: chọn engine ASR qua cấu hình (bảng `meta` của SQLite) — đổi engine KHÔNG cần build lại,
  /// và tầng trên (P1E/P2) chỉ nhận `AsrEngine` nên không bị ảnh hưởng khi đổi.
  final AsrEngineSelector _asrSelector = AsrEngineSelector(const MetaConfigStore());

  /// P1E: kho transcript của phiên hiện tại. Lấy đúng instance mà `main()` đã `init()` lúc bootstrap
  /// (nơi đã xoá dữ liệu cũ hơn 7 ngày + khôi phục phiên đang dở).
  final TranscriptStore _transcript = TranscriptStore.instance();

  /// P1F: cổng phát TTS an toàn — **mọi** âm thanh phát ra phải đi qua đây. Màn hình chẩn đoán
  /// chỉ gọi nó để chạy 3 test case bắt buộc của P1F (nút thật của người dùng là P3).
  final SafeTtsOutput _safeTts = SafeTtsOutput.instance();
  StreamSubscription<TtsFallbackNotice>? _ttsFallbackSub;

  /// P1G: câu thoát khẩn cấp — đường tắt 100% local, không qua LLM/network. Nút tạm dưới đây chỉ
  /// để kiểm trên máy thật; gesture thật (giữ nút nổi 2 giây) là việc của P3.
  final EmergencyPhraseService _emergency = EmergencyPhraseService();

  /// P3: **điểm vào duy nhất** cho mọi nguồn trigger (nút nổi, nút chẩn đoán, sau này là thông báo/
  /// volume key). Trigger lo mốc Push (P1E) → Suggestion Engine → Offline Cache → giao nudge theo
  /// chế độ output đã chọn. KHÔNG cooldown cho Push thủ công (chỉ debounce trong Policy).
  late final TriggerManager _trigger = TriggerManager();
  SuggestionResult? _lastSuggestion;
  EffectiveNudgeOutput? _lastDelivery;
  NudgeOutputMode _outputMode = OutputModeSelector.defaultMode;

  /// P3 mục 4.8: tốc độ đọc TTS (0.9x-1.2x, mặc định 1.05x) — nạp từ bảng `meta` khi mở màn hình.
  double _speechRate = OutputConfig.defaultSpeechRate;
  bool _suggesting = false;

  AsrEngine? _asr;
  AsrEngineKind _asrKind = AsrEngineSelector.defaultKind;
  StreamSubscription<Uint8List>? _asrChunkSub;
  StreamSubscription<String>? _asrTranscriptSub;
  Timer? _asrTicker;
  String _lastTranscript = '(chưa có)';
  int _asrAudioBytes = 0;
  bool _asrBusy = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _listenInfrastructure();
    unawaited(_loadAsrConfig());
    unawaited(_refreshTts());
    unawaited(_loadOutputSettings()); // P3: chế độ hiển thị + tốc độ đọc đã lưu.
  }

  /// Đăng ký mọi nguồn sự kiện hạ tầng (F4). Mỗi nguồn bọc riêng: một mảnh lỗi không cản mảnh
  /// khác. Subscriptions được hủy trong `dispose()`.
  void _listenInfrastructure() {
    _captureStatusSub = _capture.status.listen((CaptureStatus status) {
      if (!mounted) {
        return;
      }
      setState(() {}); // Dòng "Thu âm" đọc _capture.currentStatus nên chỉ cần vẽ lại.
    }, onError: (Object error) {
      _log.warn('stream trạng thái capture lỗi: $error');
    });
    _captureErrorSub = _capture.errors.listen((CaptureError error) {
      _log.warn('capture lỗi giữa luồng: ${error.message}');
      _enqueueSnack('Micro gặp lỗi: ${error.message}');
      // Capture chết ⇒ VAD cũng hết dữ liệu. Watchdog của state machine sẽ mở khoá; tại đây
      // dừng nghe VAD để UI thể hiện đúng "chưa nghe" thay vì treo state cũ.
      _conversation.stop();
      // P1D: mic chết thì ASR cũng hết dữ liệu — dừng luôn để không giữ model trong RAM vô ích.
      unawaited(_stopAsr());
      if (mounted) {
        setState(() {});
      }
    }, onError: (Object error) {
      _log.warn('stream lỗi capture lỗi: $error');
    });
    _vadStatSub = _conversation.stats.listen((VadFrameStat _) {
      _vadTick.value++; // Vẽ lại dòng "Hội thoại" mỗi buffer (10/s) — giá trị đọc trực tiếp.
    });
    // P1F: nudge chữ khi không đọc được qua tai nghe (không có tai nghe / vừa mất / vừa nối lại).
    _ttsFallbackSub = _safeTts.fallbacks.listen((TtsFallbackNotice notice) {
      _log.warn('TTS fallback (${notice.kind.name}): ${notice.message}');
      _enqueueSnack(notice.message);
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _captureStatusSub?.cancel();
    _captureErrorSub?.cancel();
    _vadStatSub?.cancel();
    _asrChunkSub?.cancel();
    _asrTranscriptSub?.cancel();
    _asrTicker?.cancel();
    _ttsFallbackSub?.cancel();
    unawaited(_transcript.detach());
    unawaited(_asr?.dispose());
    // `SafeTtsOutput` là singleton dùng cả app nên ở đây chỉ DỪNG phát, KHÔNG dispose (dispose sẽ
    // đóng stream vĩnh viễn và mọi chỗ dùng lại sau đó sẽ chết).
    unawaited(_safeTts.stop());
    _vadTick.dispose();
    super.dispose();
  }

  /// P1F: đọc lại trạng thái tai nghe + vẽ lại dòng "TTS".
  Future<void> _refreshTts() async {
    await _safeTts.refresh();
    if (mounted) {
      setState(() {});
    }
  }

  /// P1F: đọc thử 1 câu qua tai nghe (để chạy 3 test case bắt buộc trên máy thật).
  Future<void> _speakTest() async {
    final TtsSpeakResult result = await _safeTts.speak('Đây là câu kiểm tra phát ra tai nghe.');
    _log.info('đọc thử TTS: $result');
    if (mounted) {
      setState(() {});
    }
  }

  /// P1F task 3: người dùng xác nhận tai nghe đã kết nối lại ổn định (P3 sẽ gắn vào floating button).
  Future<void> _confirmHeadset() async {
    await _safeTts.confirmHeadsetReady();
    if (mounted) {
      setState(() {});
    }
  }

  /// P1G: kích hoạt Emergency Phrase (nút tạm — gesture thật là P3). Đường này KHÔNG qua LLM;
  /// hành vi an toàn (không tai nghe ⇒ im lặng + rung) do `SafeTtsOutput` bảo đảm sẵn.
  Future<void> _triggerEmergency() async {
    final EmergencyTriggerResult result = await _emergency.triggerEmergency();
    final Duration? latency = _emergency.lastTriggerToSynthLatency;
    _log.info('emergency: $result · câu "${_emergency.lastPhrase}" · độ trễ ${latency?.inMilliseconds ?? "-"}ms');
    if (latency != null) {
      _enqueueSnack('Emergency: "${_emergency.lastPhrase}" · phát sau ${latency.inMilliseconds}ms');
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// Trạng thái đường phát TTS (P1F) cho màn hình chẩn đoán. Hiện thẳng thiết bị đang được coi là
  /// "tai nghe" để biết ngay vì sao bị chặn phát mà không phải đọc logcat.
  String _ttsText() {
    final TtsOutputInfo? info = _safeTts.lastInfo;
    final TtsDevice? device = info?.preferred;
    final String deviceText = device == null
        ? 'không thấy thiết bị riêng tư nào'
        : '${device.name ?? "thiết bị lạ"} (type ${device.type}) · ${info!.devices.length} thiết bị riêng tư';
    return switch (_safeTts.state) {
      TtsOutputState.unknown => 'chưa kiểm tra',
      TtsOutputState.ready =>
        _safeTts.isSpeaking ? 'đang đọc · $deviceText' : 'sẵn sàng · $deviceText',
      TtsOutputState.silent => _safeTts.needsConfirmation
          ? 'CHẾ ĐỘ IM LẶNG · chờ xác nhận tai nghe (bấm nút xác nhận)'
          : 'CHẾ ĐỘ IM LẶNG · $deviceText',
    };
  }

  /// Đọc engine đã chọn trong cấu hình để hiện lên UI (không tự bật ASR — đọc lúc mở màn hình).
  Future<void> _loadAsrConfig() async {
    AsrEngineKind kind;
    try {
      kind = await _asrSelector.readConfigured();
    } catch (error) {
      _log.warn('không đọc được cấu hình engine ASR: $error');
      kind = AsrEngineSelector.defaultKind;
    }
    if (mounted) {
      setState(() => _asrKind = kind);
    }
  }

  /// Đổi engine ASR (P1D task 2/3): ghi cấu hình để lần bật kế tiếp dùng engine mới.
  ///
  /// Nếu đang lắng nghe/ASR đang chạy: **tắt hẳn** theo đúng luồng của nút "Tắt lắng nghe"
  /// (ASR + detach transcript → VAD → capture → service) rồi để người dùng tự bật lại.
  /// Lý do: đổi engine ngay giữa lúc thu làm app lỗi — engine cũ bị `dispose()` trong khi capture
  /// còn bơm chunk và transcript store còn attach. KHÔNG tự start lại service/capture/ASR.
  Future<void> _selectAsrEngine(AsrEngineKind? kind) async {
    if (kind == null || kind == _asrKind) {
      return;
    }
    setState(() => _busy = true);
    try {
      final bool active = _serviceRunning ||
          _asr != null ||
          _capture.currentStatus == CaptureStatus.starting ||
          _capture.currentStatus == CaptureStatus.capturing;
      if (active) {
        // Cùng thứ tự tắt như `_toggleService()`: nhả dần từ trong ra ngoài (model ASR nặng nhất
        // nên giải phóng trước), mic luôn được nhả trước khi tiến trình hết foreground.
        await _stopAsr();
        await _conversation.stop();
        await _capture.stop();
        await ListeningService.stop();
      }
      try {
        await _asrSelector.writeConfigured(kind);
      } catch (error) {
        // Ghi hỏng ⇒ GIỮ engine cũ: `_asrKind` phải luôn là engine thật đang có hiệu lực, và nếu
        // gán `_asrKind = kind` ở đây thì guard `kind == _asrKind` phía trên sẽ chặn luôn lần bấm
        // lại đúng engine đó (không thể thử lưu lại).
        _log.warn('không ghi được cấu hình engine ASR: $error');
        _enqueueSnack('Không lưu được lựa chọn engine: $error');
        return;
      }
      if (mounted) {
        setState(() => _asrKind = kind);
      }
      _enqueueSnack('Đã đổi engine. Bấm Bật lắng nghe để chạy lại.');
    } catch (error, stackTrace) {
      _log.error('đổi engine ASR lỗi', error, stackTrace);
      _enqueueSnack('Lỗi: $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
      await _refreshStatus();
    }
  }

  /// Bật ASR với engine đang cấu hình: tạo + init engine, rồi feed chunk PCM của capture vào.
  /// Có fallback tự động sang engine còn lại nếu init lỗi (xem `AsrEngineSelector`).
  Future<void> _startAsr() async {
    if (_asr != null) {
      return;
    }
    setState(() => _asrBusy = true);
    try {
      final AsrEngine engine = await _asrSelector.createAndInit();
      _asr = engine;
      // P1E: mọi text engine phát ra đi thẳng vào transcript store (kèm timestamp) để P2 dùng.
      _transcript.attach(engine);
      _asrAudioBytes = 0;
      _lastTranscript = '(chưa có)';
      _asrTranscriptSub = engine.transcriptStream.listen((String text) {
        if (!mounted) {
          return;
        }
        setState(() => _lastTranscript = text);
      }, onError: (Object error) => _log.warn('stream transcript ASR lỗi: $error'));
      _asrChunkSub = _capture.chunks.listen((Uint8List chunk) {
        final AsrEngine? current = _asr;
        if (current != null) {
          unawaited(_feedAsr(current, chunk));
        }
      }, onError: (Object error) => _log.warn('stream chunk ASR lỗi: $error'));
      // Nhịp 1s chỉ để dòng trạng thái nhích theo (số giây audio đã đưa vào engine) — đây là số liệu
      // cần cho bảng so sánh 2 engine trên máy thật (DoD P1D).
      _asrTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _asr != null) {
          setState(() {});
        }
      });
      _log.info('ASR đã bật: ${_asrKind.id}');
    } catch (error, stackTrace) {
      _log.error('không bật được ASR', error, stackTrace);
      _enqueueSnack('Không bật được ASR: $error');
      await _stopAsr();
    } finally {
      if (mounted) {
        setState(() => _asrBusy = false);
      }
    }
  }

  Future<void> _feedAsr(AsrEngine engine, Uint8List chunk) async {
    _asrAudioBytes += chunk.length;
    try {
      await engine.feedAudioChunk(chunk);
    } catch (error) {
      _log.warn('feed ASR lỗi: $error');
    }
  }

  Future<void> _stopAsr() async {
    _asrTicker?.cancel();
    _asrTicker = null;
    await _asrChunkSub?.cancel();
    _asrChunkSub = null;
    await _asrTranscriptSub?.cancel();
    _asrTranscriptSub = null;
    // P1E: ngắt khỏi store trước khi engine bị dispose (engine đổi ⇔ attach lại ở `_startAsr`).
    await _transcript.detach();
    final AsrEngine? engine = _asr;
    _asr = null;
    if (engine != null) {
      await engine.dispose();
      _log.info('ASR đã tắt (${_asrKind.id})');
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// P3: xin gợi ý qua [TriggerManager] — CÙNG một đường với nút nổi (không có logic riêng cho
  /// từng nguồn). Không bao giờ ném: mọi lỗi đã được quy về `NO_SUGGESTION`/nudge cache.
  Future<void> _requestSuggestion({SuggestTriggerSource source = SuggestTriggerSource.diagnosticButton}) async {
    setState(() => _suggesting = true);
    try {
      final TriggerOutcome outcome = await _trigger.onSuggestRequested(source: source);
      _log.info('Push gợi ý: $outcome');
      if (!mounted) {
        return;
      }
      setState(() {
        _lastSuggestion = outcome.result;
        _lastDelivery = outcome.delivery == null ? null : outcome.effectiveMode;
      });
      if (outcome.hasNudge) {
        // Chế độ chữ (Silent, hoặc Ear bị hạ cấp) cần hiện nội dung nudge — đây chính là "nudge
        // dạng chữ trên UI" mà P1F yêu cầu khi không đọc được qua tai nghe.
        _enqueueSnack(
          outcome.delivery == NudgeDeliveryResult.spoken
              ? 'Nudge (đã đọc qua tai nghe): "${outcome.result.text}"'
              : 'Nudge: "${outcome.result.text}" (${outcome.result.type!.apiName})',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _suggesting = false);
      }
    }
  }

  /// P3 task 2: gesture giữ 2 giây trên nút nổi → Emergency Phrase (KHÔNG qua LLM/Policy).
  Future<void> _requestEmergency() async {
    final EmergencyTriggerResult result = await _trigger.onEmergencyRequested();
    _log.info('emergency qua nút nổi: $result');
    if (mounted) {
      setState(() {});
    }
  }

  /// P3 task 3: đổi chế độ hiển thị nudge (ghi vào bảng `meta`, đổi được không cần build lại).
  Future<void> _selectOutputMode(NudgeOutputMode? mode) async {
    if (mode == null || mode == _outputMode) {
      return;
    }
    setState(() => _outputMode = mode);
    await _trigger.outputModes.write(mode);
    _enqueueSnack('Chế độ gợi ý: ${mode.label}');
  }

  Future<void> _loadOutputSettings() async {
    final NudgeOutputMode mode = await _trigger.outputModes.read();
    final double rate = await _trigger.outputModes.readSpeechRate();
    if (mounted) {
      setState(() {
        _outputMode = mode;
        _speechRate = rate;
      });
    }
  }

  /// P3 (bổ sung nhỏ để DoD-1 chạy được trên máy thật): mở hộp thoại nhập **API key Groq**.
  ///
  /// Vì sao cần: từ P2, `GroqLlmProvider` đọc key từ `SecureStore`, nhưng KHÔNG có chỗ nào trong
  /// app ghi vào — nghĩa là máy thật không thể có nudge thật từ LLM (DoD-1 của P2 lẫn P3 đều bị
  /// chặn ở đúng bước "nuôi key"). Hộp thoại này chỉ ghi vào keystore OS.
  ///
  /// Không log giá trị key (ràng buộc: không secret trong log/SQLite).
  Future<void> _editApiKey() async {
    // Cố ý dùng `onChanged` thay vì `TextEditingController`: dialog chỉ biến mất sau animation, nên
    // dispose controller ngay sau `showDialog` sẽ làm `TextField` (còn đang trong cây) đọc controller
    // đã hủy — lỗi kinh điển của Flutter. Cách này không có gì để dispose.
    String typed = '';
    final String? entered = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('API key LLM (Groq)'),
        content: TextField(
          autofocus: true,
          obscureText: true,
          onChanged: (String value) => typed = value,
          decoration: const InputDecoration(
            labelText: 'gsk_...',
            helperText: 'Chỉ lưu trong keystore của máy (SecureStore), không vào SQLite/log.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(typed.trim()),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    if (entered == null || entered.isEmpty || !mounted) {
      return;
    }
    try {
      await SecureStore.saveLlmApiKey(entered);
      _log.info('đã lưu API key LLM vào SecureStore (không ghi giá trị)');
      _enqueueSnack('Đã lưu API key — bấm Gợi ý để gọi LLM thật.');
    } catch (error) {
      _log.warn('không lưu được API key: $error');
      _enqueueSnack('Không lưu được API key: $error');
    }
    await _refreshStatus();
  }

  /// P3 mục 4.8: lưu tốc độ đọc TTS. Chỉ gọi khi người dùng **nhả** thanh trượt (`onChangeEnd`) —
  /// ghi SQLite mỗi bước kéo sẽ đập vào DB vô ích mà không ai đọc.
  Future<void> _saveSpeechRate(double rate) async {
    final double normalized = OutputConfig.clampSpeechRate(rate);
    setState(() => _speechRate = normalized);
    await _trigger.outputModes.writeSpeechRate(normalized);
    // `SafeTtsOutput` không giữ cấu hình tốc độ (đọc mỗi lần phát từ `TriggerManager`), nên ở đây
    // không cần đồng bộ gì thêm — lần đọc kế tiếp đã dùng giá trị mới.
    _enqueueSnack('Tốc độ đọc: ${normalized.toStringAsFixed(2)}x');
  }

  /// Hàng đợi SnackBar: mọi lỗi/tiến trình đi qua đây để không tự ý gọi `context` sau khi
  /// widget đã bị hủy, và không hiện đè nhau khi nhiều lỗi đến liên tục.
  void _enqueueSnack(String message) {
    _snackQueue.add(message);
    _drainSnackQueue();
  }

  Future<void> _drainSnackQueue() async {
    if (_snackQueueBusy || !mounted) {
      return;
    }
    _snackQueueBusy = true;
    try {
      while (_snackQueue.isNotEmpty) {
        // Guard `mounted` ngay trước lần dùng context trong từng vòng lặp: giữa các vòng có
        // `await` (chờ SnackBar đóng) — widget có thể đã bị hủy từ vòng trước.
        if (!mounted) {
          break;
        }
        final String message = _snackQueue.removeAt(0);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
        // Chờ SnackBar đóng hẳn (4s hiển thị) rồi mới hiện cái kế tiếp — tránh đè nhau.
        await Future<void>.delayed(const Duration(milliseconds: 4100));
      }
    } finally {
      _snackQueueBusy = false;
    }
  }

  /// "Làm mới trạng thái" = trạng thái hạ tầng + trạng thái tai nghe cho tầng TTS (P1F).
  Future<void> _refreshAll() async {
    await _refreshStatus();
    await _refreshTts();
  }

  /// Đọc trạng thái. Mọi lời gọi plugin đều bọc try/catch: màn hình chính không được crash
  /// chỉ vì một mảnh hạ tầng lỗi (đây là màn hình dùng để chẩn đoán trên máy thật).
  Future<void> _refreshStatus() async {
    bool running = false;
    String database = 'chưa kiểm tra';
    bool? hasApiKey;
    Map<String, bool> permissions = <String, bool>{};

    try {
      running = await ListeningService.isRunning();
    } catch (error) {
      _log.warn('không đọc được trạng thái service: $error');
    }
    try {
      permissions = await PermissionGate.currentStatus();
    } catch (error) {
      _log.warn('không đọc được trạng thái quyền: $error');
    }
    try {
      final Database db = await AppDatabase.instance();
      database = 'SQLite v${await db.getVersion()} · ${StorageConfig.databaseName}';
    } catch (error) {
      database = 'lỗi: $error';
    }
    try {
      hasApiKey = await SecureStore.hasLlmApiKey();
    } catch (error) {
      _log.warn('không đọc được secure storage: $error');
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _serviceRunning = running;
      _permissions = permissions;
      _databaseStatus = database;
      _hasApiKey = hasApiKey;
    });
  }

  /// Bật: service trước (để app lên foreground trước khi mở mic), rồi mới mở capture.
  /// Tắt: capture trước, rồi service — mic luôn được nhả trước khi tiến trình hết foreground.
  Future<void> _toggleService() async {
    setState(() => _busy = true);
    try {
      if (_serviceRunning) {
        // Thứ tự tắt: ASR -> VAD -> capture -> service (nhả dần từ trong ra ngoài; model ASR nặng
        // nhất nên giải phóng trước).
        await _stopAsr();
        await _conversation.stop();
        await _capture.stop();
        await ListeningService.stop();
        _enqueueSnack('Đã tắt lắng nghe');
      } else {
        final bool started = await ListeningService.start();
        if (!started) {
          _enqueueSnack('Không bật được service (thiếu quyền micro?)');
        } else {
          await _capture.start();
          _conversation.start(); // P1B: nghe VAD trên cùng luồng thu
          await _startAsr(); // P1D: ASR chạy trên cùng luồng chunk PCM
          _enqueueSnack('Đang lắng nghe');
        }
      }
    } on CaptureError catch (error) {
      // Quyền bị từ chối / mic bận: không crash, hiện hướng dẫn, và trả service về trạng thái tắt
      // để không còn notification "đang lắng nghe" mà thực tế không thu gì.
      _log.warn('không mở được micro: ${error.message}');
      await _conversation.stop();
      await _capture.stop();
      await ListeningService.stop();
      _enqueueSnack(error.message);
    } catch (error, stackTrace) {
      _log.error('đổi trạng thái service lỗi', error, stackTrace);
      _enqueueSnack('Lỗi: $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
      await _refreshStatus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trợ lý giao tiếp')),
      // P3 task 1: nút nổi TRONG APP (fallback chắc chắn nhất, không cần quyền hệ thống).
      floatingActionButton: SuggestFloatingButton(
        enabled: !_suggesting,
        onSuggest: () => _requestSuggestion(source: SuggestTriggerSource.floatingButton),
        onEmergency: _requestEmergency,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            _serviceRunning ? 'Đang lắng nghe' : 'Sẵn sàng',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _toggleService,
            child: Text(_serviceRunning ? 'Tắt lắng nghe' : 'Bật lắng nghe'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _refreshAll,
            child: const Text('Làm mới trạng thái'),
          ),
          const SizedBox(height: 16),
          // P1D: chọn engine nhận dạng ngay trên máy — ghi vào cấu hình (bảng `meta`), không cần
          // build lại app. Đổi engine khi đang lắng nghe sẽ TẮT hẳn phiên hiện tại (không tự bật
          // lại) — người dùng bấm "Bật lắng nghe" để chạy lại bằng engine vừa chọn.
          DropdownButtonFormField<AsrEngineKind>(
            key: ValueKey<AsrEngineKind>(_asrKind),
            initialValue: _asrKind,
            decoration: const InputDecoration(
              labelText: 'Engine nhận dạng (ASR)',
              border: OutlineInputBorder(),
            ),
            items: AsrEngineKind.values
                .map((AsrEngineKind kind) => DropdownMenuItem<AsrEngineKind>(
                      value: kind,
                      child: Text(kind.label),
                    ))
                .toList(),
            onChanged: _busy ? null : _selectAsrEngine,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: (_busy || _asrBusy)
                ? null
                : (_asr == null ? _startAsr : _stopAsr),
            icon: Icon(_asr == null
                ? Icons.record_voice_over_outlined
                : Icons.stop_circle_outlined),
            label: Text(_asr == null ? 'Bật nhận dạng (ASR)' : 'Tắt nhận dạng (ASR)'),
          ),
          const SizedBox(height: 8),
          // P1E: nút Push thật là việc của P3; nút này chỉ để kiểm API `markPushMoment` trên máy thật
          // (mốc Push sẽ vào prompt LLM ở P2). Bấm khi transcript chưa mở thì vô hiệu.
          OutlinedButton.icon(
            onPressed: _transcript.sessionId == null ? null : () => unawaited(_markPush()),
            icon: const Icon(Icons.flag_outlined),
            label: const Text('Đánh dấu Push (P1E)'),
          ),
          const SizedBox(height: 8),
          // P1F: 2 nút tạm để chạy 3 test case bắt buộc trên máy thật (nút thật của người dùng là P3).
          OutlinedButton.icon(
            onPressed: _busy ? null : () => unawaited(_speakTest()),
            icon: const Icon(Icons.volume_up_outlined),
            label: const Text('Đọc thử qua tai nghe (P1F)'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => unawaited(_confirmHeadset()),
            icon: const Icon(Icons.headset_outlined),
            label: const Text('Xác nhận tai nghe đã sẵn sàng (P1F)'),
          ),
          const SizedBox(height: 8),
          // P1G: nút tạm để kiểm Emergency Phrase trên máy thật (gesture thật là P3). Không có
          // dialog xác nhận nào — đường khẩn cấp phải phản hồi ngay lập tức.
          OutlinedButton.icon(
            onPressed: _busy ? null : () => unawaited(_triggerEmergency()),
            icon: const Icon(Icons.emergency_outlined),
            label: const Text('Emergency Phrase (P1G)'),
          ),
          const SizedBox(height: 8),
          // P3: nút chẩn đoán đi CÙNG đường với nút nổi (cùng `TriggerManager.onSuggestRequested`).
          // Policy chặn CỨNG userSpeaking trước khi gọi LLM; không có API key/mất mạng thì Offline
          // Cache tiếp quản nên vẫn có nudge.
          OutlinedButton.icon(
            onPressed: _suggesting ? null : () => unawaited(_requestSuggestion()),
            icon: const Icon(Icons.lightbulb_outline),
            label: const Text('Xin gợi ý (P3)'),
          ),
          const SizedBox(height: 8),
          // P3 task 3: chọn chế độ hiển thị nudge (Settings tối thiểu — màn hình cài đặt thật là P5/P7).
          DropdownButtonFormField<NudgeOutputMode>(
            key: ValueKey<NudgeOutputMode>(_outputMode),
            initialValue: _outputMode,
            decoration: const InputDecoration(
              labelText: 'Chế độ hiển thị gợi ý',
              border: OutlineInputBorder(),
            ),
            items: NudgeOutputMode.values
                .map((NudgeOutputMode mode) => DropdownMenuItem<NudgeOutputMode>(
                      value: mode,
                      child: Text(mode.label),
                    ))
                .toList(),
            onChanged: _selectOutputMode,
          ),
          const SizedBox(height: 8),
          // P3: cấu hình key LLM (P2 chỉ đọc key từ SecureStore, chưa có chỗ ghi ⇒ máy thật không
          // thể có nudge thật). Nút này là điều kiện để chạy DoD-1 trên máy.
          OutlinedButton.icon(
            onPressed: _busy ? null : () => unawaited(_editApiKey()),
            icon: const Icon(Icons.key_outlined),
            label: const Text('Nhập API key LLM (Groq)'),
          ),
          const SizedBox(height: 8),
          // P3 task 3 (mục 4.8): tốc độ đọc TTS 0.9x-1.2x, mặc định 1.05x.
          Row(
            children: <Widget>[
              Expanded(child: Text('Tốc độ đọc: ${_speechRate.toStringAsFixed(2)}x')),
              Text('${OutputConfig.minSpeechRate.toStringAsFixed(1)}x'),
            ],
          ),
          Slider(
            value: _speechRate,
            min: OutputConfig.minSpeechRate,
            max: OutputConfig.maxSpeechRate,
            // 6 bước ⇒ đúng lưới 0.05x trong khoảng 0.9-1.2.
            divisions: 6,
            label: '${_speechRate.toStringAsFixed(2)}x',
            onChanged: (double value) => setState(() => _speechRate = value),
            onChangeEnd: (double value) => unawaited(_saveSpeechRate(value)),
          ),
          const SizedBox(height: 16),
          _statusCard(),
        ],
      ),
    );
  }

  Widget _statusCard() {
    final String permissionText = _permissions.isEmpty
        ? 'chưa kiểm tra'
        : _permissions.entries.map((MapEntry<String, bool> e) {
            final String name = e.key
                .replaceAll('android.permission.', '')
                .replaceAll('Permission.', '');
            return '$name=${e.value ? "có" : "không"}';
          }).join(' · ');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.monitor_heart_outlined),
                const SizedBox(width: 8),
                Text(
                  'Trạng thái hạ tầng',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const Divider(height: 24),
            _infoRow('Quyền', permissionText),
            _infoRow('Thu âm', _captureStatusText()),
            // F4: vẽ lại theo _vadTick (mỗi buffer VAD) — ratio không còn đóng băng.
            ValueListenableBuilder<int>(
              valueListenable: _vadTick,
              builder: (BuildContext context, int _, Widget? _) =>
                  _infoRow('Hội thoại', _conversationText()),
            ),
            _infoRow('ASR', _asrText()),
            _infoRow('TTS', _ttsText()),
            _infoRow('Emergency', _emergencyText()),
            _infoRow('Nhận dạng', _lastTranscript),
            _infoRow('Gợi ý (P3)', _suggestionText()),
            _infoRow('Transcript', _transcriptText()),
            _infoRow('Push gần nhất', _pushText()),
            _infoRow('Lưu trữ', _databaseStatus),
            _infoRow('API key LLM', _hasApiKey == null ? 'lỗi đọc' : (_hasApiKey! ? 'đã lưu' : 'chưa có')),
          ],
        ),
      ),
    );
  }

  /// Trạng thái hội thoại cho màn hình chẩn đoán (P1B). Được vẽ lại mỗi buffer VAD nhờ
  /// `_vadTick` (F4) — `_conversation` tự cập nhật `lastStat`/state nội bộ.
  String _conversationText() {
    if (!_conversation.isRunning) {
      return 'chưa nghe';
    }
    final String label = _conversation.isUserSpeaking ? 'USER_SPEAKING' : 'NOT_USER_SPEAKING';
    final double? ratio = _conversation.lastStat?.speechRatio;
    return ratio == null ? label : '$label · tỉ lệ nói ${ratio.toStringAsFixed(2)}';
  }

  /// Trạng thái ASR (P1D). Hiện thẳng số liệu cần cho việc so sánh 2 engine trên máy thật (số giây
  /// audio đã đưa vào engine, số chunk bị bỏ) để không phải đọc logcat mới biết engine có theo kịp
  /// thời gian thực hay không.
  String _asrText() {
    final AsrEngine? engine = _asr;
    if (engine == null) {
      return 'chưa chạy · engine đã chọn: ${_asrKind.label}';
    }
    // PCM16 mono 16kHz = 32000 byte/giây.
    final String seconds = (_asrAudioBytes / 32000).toStringAsFixed(1);
    final int dropped = engine.droppedTotal;
    return '${_asrKind.label} · đang chạy · ${seconds}s audio'
        '${dropped > 0 ? " · bỏ $dropped chunk" : ""}';
  }

  /// Trạng thái transcript (P1E) cho màn hình chẩn đoán: số dòng trong cửa sổ bộ nhớ + số dòng đã
  /// **khôi phục** sau khi app bị OS kill. Đây chính là dữ liệu để kiểm DoD P1E trên máy thật mà
  /// không phải đọc logcat (xem quy trình ở `lib/transcript/README.md`).
  String _transcriptText() {
    final int? sessionId = _transcript.sessionId;
    if (sessionId == null) {
      return 'chưa mở (xem log bootstrap)';
    }
    final StringBuffer buffer = StringBuffer('phiên #$sessionId');
    buffer.write(' · RAM ${_transcript.memorySegmentCount} dòng');
    if (_transcript.recoveredSegmentCount > 0) {
      buffer.write(' · khôi phục ${_transcript.recoveredSegmentCount} dòng sau khi app bị kill');
    }
    return buffer.toString();
  }

  /// Kết quả gợi ý gần nhất (P2) cho màn hình chẩn đoán: nudge hiển thị kèm type; NO_SUGGESTION
  /// hiển thị nguyên nhân (bị chặn / LLM lỗi / không có gì đáng nói) để biết vì sao không gợi ý.
  String _suggestionText() {
    final SuggestionResult? result = _lastSuggestion;
    if (result == null) {
      return 'chưa bấm Push · chế độ ${_outputMode.label}';
    }
    final String source = result.source == NudgeSource.cache ? ' · CACHE OFFLINE' : '';
    final String via = _lastDelivery == null ? '' : ' · ${_lastDelivery!.name}';
    if (result.isNudge) {
      return '${result.type!.apiName}: "${result.text}"$source$via';
    }
    return 'NO_SUGGESTION${result.note == null ? '' : ' · ${result.note}'}'
        '${result.unavailable ? ' · LLM không dùng được' : ''}';
  }

  /// Mốc Push gần nhất (P1E) — P2 sẽ đưa mốc này vào prompt LLM.
  String _pushText() {
    final DateTime? moment = _transcript.lastPushMoment;
    return moment == null ? 'chưa bấm' : moment.toIso8601String();
  }

  Future<void> _markPush() async {
    await _transcript.markPushMoment(DateTime.now());
    if (mounted) {
      setState(() {});
    }
  }

  /// Trạng thái Emergency Phrase (P1G) cho màn hình chẩn đoán: câu của lần trigger gần nhất +
  /// độ trễ đo được (bằng chứng DoD P1G ngay trên máy, không cần logcat).
  String _emergencyText() {
    final String? phrase = _emergency.lastPhrase;
    if (phrase == null) {
      return 'chưa kích hoạt · câu kế tiếp: "${_emergency.nextPhrase}"';
    }
    final Duration? latency = _emergency.lastTriggerToSynthLatency;
    return '"$phrase" · phát sau ${latency?.inMilliseconds ?? "?"}ms (chưa tính thời gian đọc)';
  }

  /// Trạng thái capture cho màn hình chẩn đoán (P1A) — đọc đồng bộ từ controller; widget tự vẽ
  /// lại khi `status` stream phát (F4).
  String _captureStatusText() {
    final CaptureStatus status = _capture.currentStatus;
    return switch (status) {
      CaptureStatus.capturing =>
        'đang ghi · ${(_capture.capturedBytes / 1024).toStringAsFixed(0)} KB',
      CaptureStatus.starting => 'đang mở mic…',
      CaptureStatus.error => 'lỗi (xem thông báo)',
      CaptureStatus.stopped => 'đã dừng',
      CaptureStatus.idle => 'chưa ghi',
    };
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
