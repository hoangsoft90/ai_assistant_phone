import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

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
import '../coaching/ethics_gate.dart';
import '../coaching/post_review_service.dart';
import '../coaching/session_summary.dart';
import '../coaching/training_level.dart';
import '../core/app_logger.dart';
import '../core/constants.dart';
import '../suggestion/suggestion_models.dart';
import '../trigger/trigger_manager.dart';
import 'floating_button.dart';
import 'post_review_screen.dart';
import 'pre_brief_screen.dart';
import 'stats_screen.dart';
import '../services/conversation_session_controller.dart';
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

  /// P4: **orchestrator DUY NHẤT** của phiên hội thoại.
  ///
  /// Từ P4, UI không tự nối capture → VAD → ASR → TTS nữa: việc ráp nối, ràng buộc **half-duplex**
  /// và phục hồi khi một module con lỗi đều nằm trong [ConversationSessionController]. UI chỉ bấm nút
  /// và hiện trạng thái — nhờ vậy chỉ còn MỘT chỗ có thể sai thứ tự, thay vì rải rác trong các hàm UI.
  late final ConversationSessionController _session = ConversationSessionController();

  /// Controller capture dùng chung (lazy singleton) — chỉ chạm kênh native khi thực sự dùng.
  final AudioCaptureController _capture = AudioCapture.instance;

  /// State machine hội thoại (P1B) — P2 dùng chính instance này để chặn gọi LLM.
  final ConversationStateMachine _conversation = ConversationStateNotifier.instance;

  /// Đếm version của stat VAD gần nhất: ValueNotifier thay đổi giá trị mỗi buffer (10/s) để
  /// ValueListenableBuilder vẽ lại dòng "Hội thoại" mà không rebuild cả card.
  final ValueNotifier<int> _vadTick = ValueNotifier<int>(0);
  StreamSubscription<CaptureStatus>? _captureStatusSub;
  StreamSubscription<VadFrameStat>? _vadStatSub;
  StreamSubscription<String>? _sessionNoticeSub;
  StreamSubscription<SessionPhase>? _sessionPhaseSub;
  bool _snackQueueBusy = false;
  final List<String> _snackQueue = <String>[];

  /// P4: các module con do phiên sở hữu — UI chỉ đọc/ghi QUA ĐÂY.
  ///
  /// Vì sao không tự dựng instance riêng: hai `EmergencyPhraseService` sẽ xoay vòng câu khác nhau
  /// (nút nổi và nút chẩn đoán nói hai câu lệch nhau), hai `TriggerManager` sẽ có hai bộ đếm/anti-
  /// repetition khác nhau. Một chủ sở hữu, nhiều người đọc.
  AsrEngineKind get _asrKind => _session.asrKind;
  TriggerManager get _trigger => _session.trigger;
  TranscriptStore get _transcript => _session.transcript;

  /// P1F: cổng phát TTS an toàn — **mọi** âm thanh phát ra phải đi qua đây. Màn hình chẩn đoán
  /// chỉ gọi nó để chạy 3 test case bắt buộc của P1F (nút thật của người dùng là P3).
  final SafeTtsOutput _safeTts = SafeTtsOutput.instance();
  StreamSubscription<TtsFallbackNotice>? _ttsFallbackSub;

  /// P7 mục 4: lời nhắc ranh giới đạo đức hiện **một lần duy nhất** khi mở app lần đầu.
  /// (`_ethicsDialogOpen` chặn hiện đúp khi `setState` dựng lại cây trong lúc dialog đang mở.)
  bool _ethicsDialogOpen = false;

  SuggestionResult? _lastSuggestion;
  EffectiveNudgeOutput? _lastDelivery;
  NudgeOutputMode _outputMode = OutputModeSelector.defaultMode;

  /// P3 mục 4.8: tốc độ đọc TTS (0.9x-1.2x, mặc định 1.05x) — nạp từ bảng `meta` khi mở màn hình.
  double _speechRate = OutputConfig.defaultSpeechRate;
  bool _suggesting = false;

  /// P5 (mục 4.9): cấp độ huấn luyện — người dùng tự chọn, app KHÔNG tự đề xuất.
  TrainingLevel _level = TrainingLevelStore.defaultLevel;

  /// P5 task 3: Post-Review dùng transcript cục bộ (text), chạy khi người dùng bấm "Kết thúc buổi".
  late final PostReviewService _postReview = PostReviewService();

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _listenInfrastructure();
    unawaited(_loadAsrConfig());
    unawaited(_refreshTts());
    unawaited(_loadOutputSettings()); // P3: chế độ hiển thị + tốc độ đọc đã lưu.
    unawaited(_loadCoachingSettings()); // P5: Pre-Brief đã lưu + Training Level.
    unawaited(_maybeShowEthicsReminder()); // P7 mục 4: lời nhắc đạo đức, chỉ lần đầu.
  }

  /// P7 mục 4 (mục 5.3 kế hoạch): **lời nhắc ranh giới đạo đức** hiện một lần khi mở app lần
  /// đầu — nhắc cho chính người dùng, không phải tính năng pháp lý: không chặn, không ghi nhận
  /// vi phạm, không đụng audio/ASR/LLM. Nội dung + vị trí đặt theo đúng quy định của prompt.
  ///
  /// Vì sao dùng `showDialog` thay vì route đầu tiên: app có foreground service + khôi phục phiên,
  /// người dùng có thể đang giữa một thao tác khi mở lại app; dialog trên `HomeScreen` không thay
  /// đổi ngăn xếp điều hướng và không chặn việc đọc trạng thái của các loader khác.
  Future<void> _maybeShowEthicsReminder() async {
    final bool shown = await EthicsGate.load(const MetaConfigStore());
    if (shown || !mounted || _ethicsDialogOpen) {
      return;
    }
    _ethicsDialogOpen = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text(EthicsConfig.dialogTitle),
        content: const Text(EthicsConfig.dialogBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(EthicsConfig.dialogConfirm),
          ),
        ],
      ),
    );
    // Đánh dấu "đã hiện" CHỈ SAU KHI dialog đóng: nếu app bị kill giữa chừng, lần mở sau vẫn
    // thấy lời nhắc (hướng an toàn).
    await EthicsGate.markShown(const MetaConfigStore());
    _ethicsDialogOpen = false;
  }

  /// P5: nạp Pre-Brief đã lưu (dùng làm ngữ cảnh cho phiên đang chuẩn bị) + Training Level.
  ///
  /// Đặt Pre-Brief đã lưu làm Pre-Brief **của phiên** ngay khi mở app: người dùng thường mở app rồi
  /// bấm "Bật lắng nghe" luôn; nếu chỉ hiện nó trong form thì `{pre_brief}` vẫn rỗng cho tới khi họ
  /// mở màn hình Pre-Brief một lần nữa.
  Future<void> _loadCoachingSettings() async {
    final TrainingLevel level = await _session.trigger.suggestions.levels.load();
    await _session.trigger.suggestions.preBriefs.restoreDraftAsCurrent();
    if (mounted) {
      setState(() => _level = level);
    }
  }

  /// Đăng ký mọi nguồn sự kiện hạ tầng (F4). Mỗi nguồn bọc riêng: một mảnh lỗi không cản mảnh
  /// khác. Subscriptions được hủy trong `dispose()`.
  ///
  /// P4: **lỗi mic không còn được xử lý ở đây** — nó thuộc về phiên ([ConversationSessionController]
  /// tự dừng VAD/ASR/service rồi thông báo). UI chỉ hiển thị, không tự quyết định dừng module nào.
  void _listenInfrastructure() {
    _captureStatusSub = _capture.status.listen((CaptureStatus status) {
      if (!mounted) {
        return;
      }
      setState(() {}); // Dòng "Thu âm" đọc _capture.currentStatus nên chỉ cần vẽ lại.
    }, onError: (Object error) {
      _log.warn('stream trạng thái capture lỗi: $error');
    });
    _vadStatSub = _conversation.stats.listen((VadFrameStat _) {
      _vadTick.value++; // Vẽ lại dòng "Hội thoại" mỗi buffer (10/s) — giá trị đọc trực tiếp.
    });
    // P4: phiên thông báo khi một module con hỏng/hạ cấp (mic chết, ASR lỗi phải khởi động lại,
    // Push bị bỏ qua vì đang phát...) ⇒ UI chỉ việc đưa lên SnackBar.
    _sessionNoticeSub = _session.notices.listen((String message) {
      _log.warn('phiên: $message');
      _enqueueSnack(message);
    });
    // P4: pha phiên đổi (thu ↔ đang xin gợi ý ↔ đang phát) ⇒ vẽ lại nút + dòng trạng thái ngay, không
    // phải chờ người dùng bấm "Làm mới".
    _sessionPhaseSub = _session.phaseChanges.listen((SessionPhase phase) {
      if (!mounted) {
        return;
      }
      setState(() => _serviceRunning = _session.isActive);
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
    _vadStatSub?.cancel();
    _sessionNoticeSub?.cancel();
    _sessionPhaseSub?.cancel();
    _ttsFallbackSub?.cancel();
    // P4: phiên tự lo phần teardown của nó (tắt ASR + ngắt transcript store + dừng TTS). Cố ý KHÔNG
    // dừng foreground service/capture ở đây — đúng thiết kế "nghe tiếp khi ra nền" của P0.5.
    unawaited(_session.dispose());
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
  ///
  /// P4: dùng CHUNG `EmergencyPhraseService` với nút nổi (qua phiên) — hai nút phải xoay vòng trên
  /// cùng một danh sách câu, không phải hai bộ đếm riêng nói hai câu lệch nhau.
  Future<void> _triggerEmergency() async {
    final EmergencyTriggerResult result = await _session.triggerEmergency();
    final EmergencyPhraseService emergency = _session.emergency;
    final Duration? latency = emergency.lastTriggerToSynthLatency;
    _log.info('emergency: $result · câu "${emergency.lastPhrase}" · độ trễ ${latency?.inMilliseconds ?? "-"}ms');
    if (latency != null) {
      _enqueueSnack('Emergency: "${emergency.lastPhrase}" · phát sau ${latency.inMilliseconds}ms');
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
    await _session.readConfiguredEngine();
    if (mounted) {
      setState(() {});
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
      // Phiên lo việc dừng ĐÚNG THỨ TỰ (ASR → VAD → capture → service) rồi ghi cấu hình; KHÔNG tự
      // bật lại — người dùng bấm "Bật lắng nghe" nếu muốn chạy lại bằng engine vừa chọn.
      final bool saved = await _session.changeEngine(kind);
      if (saved && mounted) {
        _enqueueSnack('Đã đổi engine. Bấm Bật lắng nghe để chạy lại.');
      }
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

  /// Bật/tắt ASR thủ công (nút chẩn đoán riêng).
  ///
  /// Việc nạp model, nối transcript store và **chặn chunk khi TTS đang phát** đều do phiên lo — UI
  /// chỉ gọi rồi vẽ lại. Giữ nút này (khác nút "Bật lắng nghe") để đo A/B 2 engine ASR trên máy thật
  /// mà không phải bật cả phiên: nó chỉ nạp/tắt model.
  Future<void> _toggleAsr() async {
    if (_session.isAsrRunning) {
      await _session.stopAsr();
    } else {
      await _session.startAsr();
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
      // P4: đi qua PHIÊN, không gọi thẳng TriggerManager — phiên mới là chỗ giữ chốt "đang phát thì
      // không nhận Push mới" và đo độ trễ Push → native bắt đầu tổng hợp.
      final TriggerOutcome? outcome = await _session.push(source: source);
      if (outcome == null) {
        return; // bị bỏ qua vì TTS đang phát (phiên đã thông báo cho người dùng)
      }
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
  ///
  /// P4: đi qua phiên; đường khẩn cấp CỐ Ý không bị chốt chống-chồng-tiếng chặn (phải phát ngay).
  Future<void> _requestEmergency() async {
    final EmergencyTriggerResult result = await _session.triggerEmergency();
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

  // ------------------------------------------------------------------ P5: coaching

  /// Mở màn hình Pre-Brief (P5 task 1). Kết quả đã được store ghi sẵn — UI chỉ cần thông báo.
  Future<void> _openPreBrief() async {
    final NavigatorState navigator = Navigator.of(context);
    final bool? saved = await navigator.push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext _) =>
            PreBriefScreen(store: _session.trigger.suggestions.preBriefs),
      ),
    );
    if (saved != true || !mounted) {
      return;
    }
    final bool has = _session.trigger.suggestions.preBriefs.hasCurrent;
    _enqueueSnack(has ? 'Đã lưu Pre-Brief cho buổi này.' : 'Đã xoá Pre-Brief.');
    setState(() {});
  }

  /// Đổi Training Level (P5 task 4 — mục 4.9). Chỉ ghi cấu hình; **không** kèm bất kỳ gợi ý đổi cấp nào.
  Future<void> _selectLevel(TrainingLevel? level) async {
    if (level == null || level == _level) {
      return;
    }
    final bool saved = await _session.trigger.suggestions.levels.save(level);
    if (!mounted) {
      return;
    }
    setState(() => _level = _session.trigger.suggestions.levels.current);
    _enqueueSnack(
      saved
          ? 'Cấp độ: ${level.label} — ${level.behavior}'
          : 'Không lưu được cấp độ (${level.label})',
    );
  }

  /// Mở màn hình số liệu 7 ngày (P5 task 4). Chỉ hiển thị — xem ghi chú ở `stats_screen.dart`.
  void _openStats() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => StatsScreen(currentLevelLabel: _level.label),
      ),
    );
  }

  /// **Kết thúc buổi** → Post-Review (P5 task 3): tắt phiên rồi phân tích transcript của buổi vừa nói.
  ///
  /// Thứ tự có ý nghĩa: `stop()` trước (nhả ASR/model, đúng thứ tự của P4) rồi mới phân tích — nếu
  /// phân tích trước, LLM có thể đang chạy trong lúc mic/ASR còn sống, và tệ hơn là nudge mới sẽ chen
  /// vào bản nhận xét. Transcript thì KHÔNG bị mất khi tắt phiên (`TranscriptStore` giữ nguyên phiên
  /// cho tới khi mở app tạo phiên mới), nên vẫn đọc được đầy đủ sau `stop()`.
  Future<void> _finishSessionAndReview() async {
    final NavigatorState navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      if (_session.isActive) {
        await _session.stop();
        if (mounted) {
          _enqueueSnack('Đã kết thúc buổi — đang tạo nhận xét...');
        }
      }
      final PostReviewReport report = await _postReview.run();
      // Transcript đầy đủ chỉ để hiện ở "xem chi tiết" — đọc lỗi thì vẫn hiện báo cáo, chỉ mất phần chi
      // tiết (không được để một lần đọc DB lỗi làm mất cả bản nhận xét).
      String detail = '';
      try {
        detail = (await _transcript.sessionTranscript()).text;
      } catch (error) {
        _log.warn('không đọc được transcript cho phần chi tiết: $error');
      }
      _log.info('post-review: ${report.toString()}');
      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext _) =>
              PostReviewScreen(report: report, detailTranscript: detail),
        ),
      );
    } catch (error, stackTrace) {
      // `PostReviewService.run()` cam kết không ném; đây là lưới an toàn cuối cùng của UI.
      _log.error('Post-Review lỗi ngoài dự kiến', error, stackTrace);
      if (mounted) {
        _enqueueSnack('Không tạo được nhận xét: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
      await _refreshStatus();
    }
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

  /// Bật/tắt phiên lắng nghe.
  ///
  /// Toàn bộ thứ tự mở (service → capture → VAD → ASR) và đóng (ngược lại, model ASR nặng nhất nên
  /// nhả trước) nằm trong [ConversationSessionController] — UI chỉ bấm nút.
  Future<void> _toggleService() async {
    setState(() => _busy = true);
    try {
      if (_session.isActive) {
        await _session.stop();
        _enqueueSnack('Đã tắt lắng nghe');
      } else {
        // Phiên tự xử lý `CaptureError` (thông báo + tắt service) — không ném ra UI.
        final bool started = await _session.start();
        if (started) {
          _enqueueSnack('Đang lắng nghe');
        }
      }
    } catch (error, stackTrace) {
      _log.error('đổi trạng thái phiên lỗi', error, stackTrace);
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
            onPressed: (_busy || _session.isBusy) ? null : _toggleAsr,
            icon: Icon(_session.isAsrRunning
                ? Icons.stop_circle_outlined
                : Icons.record_voice_over_outlined),
            label: Text(
              _session.isAsrRunning ? 'Tắt nhận dạng (ASR)' : 'Bật nhận dạng (ASR)',
            ),
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
          // P5 task 1: Pre-Brief của buổi — dữ liệu này thay `{pre_brief}` rỗng của P2 trong prompt.
          OutlinedButton.icon(
            onPressed: _busy ? null : () => unawaited(_openPreBrief()),
            icon: const Icon(Icons.checklist_outlined),
            label: const Text('Pre-Brief buổi này (P5)'),
          ),
          const SizedBox(height: 8),
          // P5 task 4 (mục 4.9): cấp độ do người dùng tự chọn — không có nút "đề xuất", không có nhắc
          // nhở tự động. Mô tả hành vi hiện ngay dưới để biết mình vừa chọn gì.
          DropdownButtonFormField<TrainingLevel>(
            key: ValueKey<TrainingLevel>(_level),
            initialValue: _level,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Cấp độ huấn luyện (P5)',
              // Hành vi của cấp ĐANG chọn hiện ở helperText (không nhét vào item): nhét cả câu mô tả vào
              // item làm dropdown tràn ngang trên màn hẹp — smoke test bắt được lỗi overflow này.
              helperText: _level.behavior,
              border: const OutlineInputBorder(),
            ),
            items: TrainingLevel.values
                .map((TrainingLevel level) => DropdownMenuItem<TrainingLevel>(
                      value: level,
                      child: Text(level.label),
                    ))
                .toList(),
            onChanged: _busy ? null : _selectLevel,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => unawaited(_finishSessionAndReview()),
            icon: const Icon(Icons.school_outlined),
            label: const Text('Kết thúc buổi + nhận xét (P5)'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _openStats,
            icon: const Icon(Icons.bar_chart_outlined),
            label: const Text('Số liệu 7 ngày (P5)'),
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
            // P4: pha phiên + số liệu half-duplex — bằng chứng cho DoD 2/3/4 hiện NGAY trên máy,
            // không phải đọc logcat.
            _infoRow('Phiên (P4)', _sessionText()),
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
            _infoRow('Nhận dạng', _session.lastTranscriptText),
            _infoRow('Gợi ý (P3)', _suggestionText()),
            _infoRow('Coaching (P5)', _coachingText()),
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
    if (!_session.isAsrRunning) {
      return 'chưa chạy · engine đã chọn: ${_asrKind.label}';
    }
    // PCM16 mono 16kHz = 32000 byte/giây.
    final String seconds = (_session.asrAudioBytes / 32000).toStringAsFixed(1);
    final int dropped = _session.asrDroppedChunks;
    return '${_asrKind.label} · đang chạy · ${seconds}s audio'
        '${dropped > 0 ? " · bỏ $dropped chunk" : ""}';
  }

  /// Pha phiên + số liệu half-duplex/phục hồi (P4).
  ///
  /// Đây là **bề mặt bằng chứng trên máy thật**: DoD của P4 nói về những thứ không nhìn thấy được
  /// (ASR có bị chặn đúng lúc TTS phát không, có được mở lại không, có lần nào 2 tiếng chồng nhau
  /// không, độ trễ Push bao nhiêu) nên chúng phải hiện thành SỐ ngay trên màn hình chẩn đoán.
  String _sessionText() {
    if (!_session.isActive) {
      return 'chưa bật';
    }
    final StringBuffer buffer = StringBuffer(_session.phase.name);
    final int dropped = _session.chunksDroppedWhileSpeaking;
    if (dropped > 0) {
      buffer.write(' · chặn $dropped chunk khi đang phát');
    }
    if (_session.asrResumeCount > 0) {
      buffer.write(' · ASR nhận lại ${_session.asrResumeCount} lần');
    }
    if (_session.overlapPreventedCount > 0) {
      buffer.write(' · bỏ qua ${_session.overlapPreventedCount} Push (đang phát)');
    }
    if (_session.recoveryCount > 0) {
      buffer.write(' · phục hồi ${_session.recoveryCount} lần');
    }
    final Duration? latency = _session.averagePushLatency;
    if (latency != null) {
      buffer.write(' · Push→tổng hợp ${latency.inMilliseconds}ms (tb)');
    }
    // Mốc bắt đầu phiên: bằng chứng cho DoD "chạy ≥ 30 phút liên tục" — người test chỉ cần so giờ
    // trên máy với mốc này, không phải mò trong logcat.
    final DateTime? started = _session.sessionStartedAt;
    if (started != null) {
      buffer.write(' · từ ${started.hour.toString().padLeft(2, '0')}:'
          '${started.minute.toString().padLeft(2, '0')}');
    }
    return buffer.toString();
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

  /// Trạng thái lớp Coaching (P5) cho màn hình chẩn đoán.
  ///
  /// Hiện **số liệu** của tóm tắt phiên (số lần + lý do lần cuối thất bại), KHÔNG hiện nội dung tóm
  /// tắt: nội dung đó suy ra từ hội thoại thật, cùng mức nhạy cảm với transcript (quyết định từ review
  /// P2 — nội dung nudge/transcript không lên logcat, và đây cũng là màn hình chẩn đoán).
  String _coachingText() {
    final bool hasPreBrief = _session.trigger.suggestions.preBriefs.hasCurrent;
    final SessionSummaryService summaries = _session.trigger.suggestions.summaries;
    final StringBuffer buffer = StringBuffer(_level.label);
    buffer.write(hasPreBrief ? ' · Pre-Brief: có' : ' · Pre-Brief: chưa nhập');
    if (summaries.refreshCount > 0) {
      final DateTime? at = summaries.updatedAt;
      buffer.write(' · tóm tắt ${summaries.refreshCount} lần');
      if (at != null) {
        buffer.write(' (mới nhất '
            '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')})');
      }
    } else {
      buffer.write(' · chưa tóm tắt');
    }
    // Số lần chạy Post-Review là bằng chứng cho phần "học hỏi sau" của P5 (DoD-2) — hiện ở đây để
    // không phải mở màn hình nhận xét mới biết nó có chạy hay không.
    if (_postReview.runCount > 0) {
      buffer.write(' · nhận xét ${_postReview.runCount} lần');
    }
    final String? note = summaries.lastNote;
    if (note != null) {
      buffer.write(' ($note)');
    }
    return buffer.toString();
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
    final String? phrase = _session.emergency.lastPhrase;
    if (phrase == null) {
      return 'chưa kích hoạt · câu kế tiếp: "${_session.emergency.nextPhrase}"';
    }
    final Duration? latency = _session.emergency.lastTriggerToSynthLatency;
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
