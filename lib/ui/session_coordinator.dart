import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../audio/asr/asr_engine_selector.dart';
import '../audio/capture/audio_capture_controller.dart';
import '../audio/capture/capture_config.dart';
import '../audio/capture/capture_engine.dart';
import '../audio/emergency/emergency_phrase_service.dart';
import '../audio/nudge_delivery.dart';
import '../audio/output_mode_selector.dart';
import '../audio/tts/safe_tts_output.dart';
import '../audio/tts/tts_client.dart';
import '../audio/vad/conversation_state.dart';
import '../audio/vad/conversation_state_notifier.dart';
import '../coaching/ethics_gate.dart';
import '../coaching/pending_analysis_service.dart';
import '../coaching/post_review_service.dart';
import '../coaching/session_summary.dart';
import '../coaching/training_level.dart';
import '../core/app_logger.dart';
import '../core/constants.dart';
import '../services/conversation_session_controller.dart';
import '../services/foreground_service.dart';
import '../services/permission_gate.dart';
import '../services/storage/app_database.dart';
import '../services/storage/meta_store.dart';
import '../services/storage/retention_config.dart';
import '../services/storage/secure_store.dart';
import '../suggestion/llm_provider_config.dart';
import '../suggestion/suggestion_models.dart';
import '../suggestion/test_llm_service.dart';
import '../transcript/transcript_store.dart';
import '../trigger/trigger_manager.dart';
import 'post_review_screen.dart';
import 'pre_brief_screen.dart';

/// Toàn bộ trạng thái + logic điều khiển của màn hình chính (trước P5.3 nằm trong
/// `_HomeScreenState`), tách ra khỏi widget để **RootScaffold**, **GlobalFloatingControls**,
/// **HomeTab** và **SettingsTab** dùng CHUNG một nguồn sự thật (P5.3).
///
/// Ranh giới của P5.3: đây là phase **tái tổ chức UI** — mọi method ở đây là code đã có trong
/// `home_screen.dart` cũ, CHỈ chuyển vị trí (`setState` → `notifyListeners`; `mounted` →
/// `context.mounted` chỗ cần ngữ cảnh; SnackBar qua `ScaffoldMessenger` key). KHÔNG đổi cách
/// `ConversationSessionController`/`TriggerManager`/`SafeTtsOutput` hoạt động.
class SessionCoordinator extends ChangeNotifier {
  SessionCoordinator({
    required this.messengerKey,
    Future<bool> Function()? startService,
    Future<void> Function()? stopService,
    AudioCaptureEngine? capture,
    PendingAnalysisService? pendingAnalysis,
  })  : session = ConversationSessionController(
          llmConfigStore: const MetaConfigStore(),
          startService: startService,
          stopService: stopService,
          capture: capture,
        ),
        pendingAnalysis = pendingAnalysis ?? PendingAnalysisService(),
        _startServiceOverride = startService;

  static const AppLogger _log = AppLogger('HomeScreen');

  /// SnackBar hiện trên Scaffold gốc của RootScaffold — không phụ thuộc `context` của tab nào.
  final GlobalKey<ScaffoldMessengerState> messengerKey;

  // ------------------------------------------------------------------ state (nguyên vẹn từ bản cũ)
  bool _serviceRunning = false;
  bool _busy = false;
  String _databaseStatus = 'chưa kiểm tra';
  Map<String, bool> _permissions = <String, bool>{};
  int? _retentionDays;

  /// P4: **orchestrator DUY NHẤT** của phiên hội thoại. P2.1: truyền config store xuống provider LLM.
  /// P5.3: cho phép bơm `startService`/`stopService` (test widget không có native ⇒ service thật
  /// luôn trả `false` vì thiếu quyền — test P5.3 cần đường bật phiên chạy được end-to-end).
  /// Bơm thêm `capture` cùng mục đích: `AudioCapture.instance` thật gọi kênh native trong `start()`
  /// ⇒ stub MethodChannel trả `null` ⇒ `FormatException` ⇒ CaptureUnavailable ⇒ phiên không bao
  /// giờ bật được trong test. Fake capture (cùng mẫu P4) chặn đúng điểm này.
  final ConversationSessionController session;

  final Future<bool> Function()? _startServiceOverride;

  /// **P5.4**: phân tích bù các buổi đã kết thúc mà chưa có báo cáo (Post-Review lỗi lúc "Kết thúc
  /// buổi"). Bơm được để test không cần LLM/DB thật.
  final PendingAnalysisService pendingAnalysis;

  /// Cờ chặn hai lượt phân tích bù chạy chồng lên nhau khi `init()` bị gọi lại (mở lại app / dựng lại
  /// màn hình nhiều lần liên tiếp). Trước phase này chưa có nhu cầu nên không có cờ.
  bool _catchUpRunning = false;

  /// Controller capture dùng chung (lazy singleton) — chỉ chạm kênh native khi thực sự dùng.
  final AudioCaptureController capture = AudioCapture.instance;

  /// State machine hội thoại (P1B) — P2 dùng chính instance này để chặn gọi LLM.
  final ConversationStateMachine conversation = ConversationStateNotifier.instance;

  /// Đếm version của stat VAD gần nhất: ValueNotifier thay đổi giá trị mỗi buffer (10/s) để
  /// ValueListenableBuilder vẽ lại dòng "Hội thoại" mà không rebuild cả card.
  final ValueNotifier<int> vadTick = ValueNotifier<int>(0);

  StreamSubscription<CaptureStatus>? _captureStatusSub;
  StreamSubscription<VadFrameStat>? _vadStatSub;
  StreamSubscription<String>? _sessionNoticeSub;
  StreamSubscription<SessionPhase>? _sessionPhaseSub;
  bool _snackQueueBusy = false;
  final List<String> _snackQueue = <String>[];

  final SafeTtsOutput safeTts = SafeTtsOutput.instance();
  StreamSubscription<TtsFallbackNotice>? _ttsFallbackSub;

  /// P7 mục 4: chặn hiện đúp dialog đạo đức khi `setState` dựng lại cây trong lúc dialog đang mở.
  bool _ethicsDialogOpen = false;

  SuggestionResult? _lastSuggestion;
  EffectiveNudgeOutput? _lastDelivery;
  NudgeOutputMode _outputMode = OutputModeSelector.defaultMode;

  /// P3 mục 4.8: tốc độ đọc TTS (0.9x-1.2x, mặc định 1.05x) — nạp từ bảng `meta`.
  double _speechRate = OutputConfig.defaultSpeechRate;
  bool _suggesting = false;

  /// P5 (mục 4.9): cấp độ huấn luyện — người dùng tự chọn, app KHÔNG tự đề xuất.
  TrainingLevel _level = TrainingLevelStore.defaultLevel;

  /// P5 task 3: Post-Review dùng transcript cục bộ (text), chạy khi bấm "Kết thúc buổi".
  /// P2.1: cùng `configStore` với provider của phiên.
  final PostReviewService postReview = PostReviewService(llmConfigStore: const MetaConfigStore());

  /// P2.1: trạng thái cấu hình LLM hiện tại; null = chưa đọc xong.
  ResolvedLlmConfig? _llmConfig;
  bool? _hasApiKey;

  /// issue1_fix mục 3: giá trị RAW đã lưu của cấu hình LLM (để dialog hiện đúng giá trị persisted,
  /// kể cả khi resolver đã fallback về mặc định vì giá trị hỏng). `null` = chưa đọc xong.
  /// Endpoint/model không nhạy cảm (meta); key đọc riêng từ SecureStore mỗi lần mở dialog.
  ({String? url, String? model})? _rawLlmConfig;

  /// issue1_fix mục 4: trạng thái nút Test LLM (đang chạy / kết quả gần nhất).
  bool _testingLlm = false;
  LlmTestResult? _llmTestResult;

  bool _disposed = false;

  // ------------------------------------------------------------------ getters đọc cho UI
  bool get serviceRunning => _serviceRunning;
  bool get busy => _busy;
  bool get suggesting => _suggesting;
  String get databaseStatus => _databaseStatus;
  Map<String, bool> get permissions => _permissions;
  int? get retentionDays => _retentionDays;
  NudgeOutputMode get outputMode => _outputMode;
  double get speechRate => _speechRate;
  TrainingLevel get level => _level;
  ResolvedLlmConfig? get llmConfig => _llmConfig;
  bool? get hasApiKey => _hasApiKey;

  /// issue1_fix mục 3: giá trị RAW persisted (endpoint/model, key đọc riêng). `null` = chưa load.
  ({String? url, String? model})? get rawLlmConfig => _rawLlmConfig;
  bool get testingLlm => _testingLlm;
  LlmTestResult? get llmTestResult => _llmTestResult;

  /// issue1_fix mục 4: nút Test LLM (SnackBar trả kết quả; không đụng phiên).
  Future<void> testLlm() async {
    if (_testingLlm) {
      return; // chặn spam (prompt mục 4 — loading state).
    }
    _testingLlm = true;
    _llmTestResult = null;
    _notify();
    try {
      final LlmTestResult result = await _testLlm.run();
      _llmTestResult = result;
      enqueueSnack(
        result.isSuccess
            ? 'LLM hoạt động · ${result.model} · ${result.latency!.inMilliseconds}ms'
            : 'Test LLM thất bại: ${result.message}',
      );
    } finally {
      _testingLlm = false;
      _notify();
    }
  }

  /// issue1_fix mục 4: service Test LLM dùng CHUNG resolver với Post-Review/Suggestion (mục 5).
  /// Client HTTP riêng (không dùng client của provider — test không được ảnh hưởng bởi state provider).
  final TestLlmService _testLlm = TestLlmService();
  SuggestionResult? get lastSuggestion => _lastSuggestion;
  EffectiveNudgeOutput? get lastDelivery => _lastDelivery;

  AsrEngineKind get asrKind => session.asrKind;
  TriggerManager get trigger => session.trigger;
  TranscriptStore get transcript => session.transcript;

  // ------------------------------------------------------------------ init / dispose (mục 4 của prompt)
  /// Mọi lệnh load lúc mở app chạy TẠI ĐÂY, MỘT LẦN — các tab KHÔNG tự load lại (tránh lệch state).
  /// Nguyên vẹn danh sách `unawaited(...)` của `initState` cũ.
  void init() {
    unawaited(refreshStatus());
    _listenInfrastructure();
    unawaited(loadAsrConfig());
    unawaited(refreshTts());
    unawaited(loadOutputSettings()); // P3: chế độ hiển thị + tốc độ đọc đã lưu.
    unawaited(loadLlmConfig()); // P2.1: endpoint/model LLM đang dùng (hiển thị trạng thái).
    unawaited(loadCoachingSettings()); // P5: Pre-Brief đã lưu + Training Level.
    unawaited(loadRetentionDays()); // P5.1: hạn tự xoá đang có hiệu lực (hiển thị dropdown).
    // P5.4: phân tích bù chạy SAU các lệnh load ở trên (không tranh tài nguyên với việc mở app) và
    // luôn `unawaited` — không được chặn UI. Tự bỏ qua khi chưa có API key (kiểm trong service).
    unawaited(catchUpPendingAnalyses());
  }

  /// Một lượt phân tích bù các buổi còn thiếu báo cáo (P5.4). Chạy nền, không bao giờ ném.
  ///
  /// Cố ý chỉ báo SnackBar khi **có** kết quả: mỗi lần mở app mà hiện thông báo "không có buổi nào
  /// cần phân tích" sẽ thành tiếng ồn vô nghĩa. Ngược lại, khi vừa phân tích bù xong N buổi thì người
  /// dùng cần biết (báo cáo xuất hiện "tự dưng" ở tab Lịch sử).
  Future<void> catchUpPendingAnalyses() async {
    if (_catchUpRunning) {
      return;
    }
    _catchUpRunning = true;
    try {
      final PendingAnalysisOutcome outcome = await pendingAnalysis.catchUp();
      if (outcome.analyzed > 0) {
        enqueueSnack('Đã phân tích lại ${outcome.analyzed} buổi còn thiếu báo cáo.');
      }
    } catch (error, stackTrace) {
      // Hợp đồng của service là không ném; đây là lưới an toàn cuối cùng — mở app không được crash.
      _log.warn('phân tích bù lỗi ngoài dự kiến: $error');
      _log.error('chi tiết phân tích bù lỗi', error, stackTrace);
    } finally {
      _catchUpRunning = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _captureStatusSub?.cancel();
    _vadStatSub?.cancel();
    _sessionNoticeSub?.cancel();
    _sessionPhaseSub?.cancel();
    _ttsFallbackSub?.cancel();
    // P4: phiên tự lo phần teardown của nó (tắt ASR + ngắt transcript store + dừng TTS). Cố ý KHÔNG
    // dừng foreground service/capture ở đây — đúng thiết kế "nghe tiếp khi ra nền" của P0.5.
    unawaited(session.dispose());
    vadTick.dispose();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ listeners hạ tầng (F4, nguyên vẹn)
  void _listenInfrastructure() {
    _captureStatusSub = capture.status.listen((CaptureStatus status) {
      _notify(); // Dòng "Thu âm" đọc capture.currentStatus nên chỉ cần vẽ lại.
    }, onError: (Object error) {
      _log.warn('stream trạng thái capture lỗi: $error');
    });
    _vadStatSub = conversation.stats.listen((VadFrameStat _) {
      vadTick.value++; // Vẽ lại dòng "Hội thoại" mỗi buffer (10/s).
    });
    // P4: phiên thông báo khi một module con hỏng/hạ cấp ⇒ UI chỉ việc đưa lên SnackBar.
    _sessionNoticeSub = session.notices.listen((String message) {
      _log.warn('phiên: $message');
      enqueueSnack(message);
    });
    // P4: pha phiên đổi (thu ↔ đang xin gợi ý ↔ đang phát) ⇒ vẽ lại nút + dòng trạng thái ngay.
    _sessionPhaseSub = session.phaseChanges.listen((SessionPhase phase) {
      _serviceRunning = session.isActive;
      _notify();
    });
    // P1F: nudge chữ khi không đọc được qua tai nghe.
    _ttsFallbackSub = safeTts.fallbacks.listen((TtsFallbackNotice notice) {
      _log.warn('TTS fallback (${notice.kind.name}): ${notice.message}');
      enqueueSnack(notice.message);
      _notify();
    });
  }

  // ------------------------------------------------------------------ P7: lời nhắc đạo đức (nguyên vẹn)
  /// P7 mục 4: lời nhắc ranh giới đạo đức hiện **một lần duy nhất** khi mở app lần đầu.
  /// [context] là context của RootScaffold — chờ một nhịp async trước (`EthicsGate.load`) nên
  /// element đã dựng xong khi dialog hiện (cùng pattern bản cũ).
  Future<void> maybeShowEthicsReminder(BuildContext context) async {
    final bool shown = await EthicsGate.load(const MetaConfigStore());
    if (shown || !context.mounted || _ethicsDialogOpen) {
      return;
    }
    _ethicsDialogOpen = true;
    final bool? acknowledged = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => AlertDialog(
        // `scrollable: true` vì nội dung là một đoạn văn: ở cỡ chữ hệ thống lớn (accessibility)
        // AlertDialog mặc định KHÔNG cuộn ⇒ phần cuối lời nhắc bị cắt mà không báo gì.
        scrollable: true,
        title: const Text(EthicsConfig.dialogTitle),
        content: const Text(EthicsConfig.dialogBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(EthicsConfig.dialogConfirm),
          ),
        ],
      ),
    );
    _ethicsDialogOpen = false;
    // `barrierDismissible: false` KHÔNG chặn được nút back hệ thống ⇒ chỉ đánh dấu "đã hiện" khi
    // người dùng THỰC SỰ bấm "Tôi hiểu" (nguyên vẹn từ bản cũ — hai đường đều nghiêng về "nhắc lại").
    if (acknowledged != true) {
      _log.info('lời nhắc đạo đức đóng mà chưa xác nhận — sẽ nhắc lại ở lần mở app sau');
      return;
    }
    await EthicsGate.markShown(const MetaConfigStore());
  }

  // ------------------------------------------------------------------ P5: coaching (nguyên vẹn)
  /// P5: nạp Pre-Brief đã lưu (dùng làm ngữ cảnh cho phiên đang chuẩn bị) + Training Level.
  Future<void> loadCoachingSettings() async {
    final TrainingLevel loaded = await session.trigger.suggestions.levels.load();
    await session.trigger.suggestions.preBriefs.restoreDraftAsCurrent();
    _level = loaded;
    _notify();
  }

  // ------------------------------------------------------------------ P1F: TTS (nguyên vẹn)
  /// P1F: đọc lại trạng thái tai nghe + vẽ lại dòng "TTS".
  Future<void> refreshTts() async {
    await safeTts.refresh();
    _notify();
  }

  /// P1F: đọc thử 1 câu qua tai nghe (3 test case bắt buộc trên máy thật).
  Future<void> speakTest() async {
    final TtsSpeakResult result = await safeTts.speak('Đây là câu kiểm tra phát ra tai nghe.');
    _log.info('đọc thử TTS: $result');
    _notify();
  }

  /// P1F task 3: người dùng xác nhận tai nghe đã kết nối lại ổn định.
  Future<void> confirmHeadset() async {
    await safeTts.confirmHeadsetReady();
    _notify();
  }

  /// P1G: kích hoạt Emergency Phrase. Đường KHÔNG qua LLM; dùng CHUNG `EmergencyPhraseService`
  /// với nút nổi (qua phiên) — hai nguồn xoay vòng trên cùng một danh sách câu.
  Future<void> triggerEmergency() async {
    final EmergencyTriggerResult result = await session.triggerEmergency();
    final EmergencyPhraseService emergency = session.emergency;
    final Duration? latency = emergency.lastTriggerToSynthLatency;
    _log.info('emergency: $result · câu "${emergency.lastPhrase}" · độ trễ ${latency?.inMilliseconds ?? "-"}ms');
    if (latency != null) {
      enqueueSnack('Emergency: "${emergency.lastPhrase}" · phát sau ${latency.inMilliseconds}ms');
    }
    _notify();
  }

  // ------------------------------------------------------------------ P1D: engine ASR (nguyên vẹn)
  /// Đọc engine đã chọn trong cấu hình để hiện lên UI (không tự bật ASR — đọc lúc mở app).
  Future<void> loadAsrConfig() async {
    await session.readConfiguredEngine();
    _notify();
  }

  /// Đổi engine ASR (P1D task 2/3): ghi cấu hình để lần bật kế tiếp dùng engine mới.
  /// Nếu đang lắng nghe: TẮT hẳn theo đúng luồng rồi để người dùng tự bật lại.
  Future<void> selectAsrEngine(AsrEngineKind? kind) async {
    if (kind == null || kind == asrKind) {
      return;
    }
    _busy = true;
    _notify();
    try {
      final bool saved = await session.changeEngine(kind);
      if (saved) {
        enqueueSnack('Đã đổi engine. Bấm Bật lắng nghe để chạy lại.');
      }
    } catch (error, stackTrace) {
      _log.error('đổi engine ASR lỗi', error, stackTrace);
      enqueueSnack('Lỗi: $error');
    } finally {
      _busy = false;
      _notify();
      await refreshStatus();
    }
  }

  /// Bật/tắt ASR thủ công (nút chẩn đoán riêng — khác nút "Bật lắng nghe": chỉ nạp/tắt model
  /// để đo A/B 2 engine mà không phải bật cả phiên).
  Future<void> toggleAsr() async {
    if (session.isAsrRunning) {
      await session.stopAsr();
    } else {
      await session.startAsr();
    }
    _notify();
  }

  // ------------------------------------------------------------------ P3: gợi ý + Emergency (nguyên vẹn)
  /// P3: xin gợi ý qua [TriggerManager] — CÙNG một đường với nút nổi (không có logic riêng cho
  /// từng nguồn). Không bao giờ ném: mọi lỗi đã được quy về `NO_SUGGESTION`/nudge cache.
  Future<void> requestSuggestion({SuggestTriggerSource source = SuggestTriggerSource.floatingButton}) async {
    _suggesting = true;
    _notify();
    try {
      // P4: đi qua PHIÊN, không gọi thẳng TriggerManager.
      final TriggerOutcome? outcome = await session.push(source: source);
      if (outcome == null) {
        return; // bị bỏ qua vì TTS đang phát (phiên đã thông báo cho người dùng)
      }
      _log.info('Push gợi ý: $outcome');
      _lastSuggestion = outcome.result;
      _lastDelivery = outcome.delivery == null ? null : outcome.effectiveMode;
      if (outcome.hasNudge) {
        enqueueSnack(
          outcome.delivery == NudgeDeliveryResult.spoken
              ? 'Nudge (đã đọc qua tai nghe): "${outcome.result.text}"'
              : 'Nudge: "${outcome.result.text}" (${outcome.result.type!.apiName})',
        );
      }
    } finally {
      _suggesting = false;
      _notify();
    }
  }

  /// P3 task 2: giữ 2 giây trên nút nổi → Emergency Phrase (KHÔNG qua LLM/Policy).
  Future<void> requestEmergency() async {
    final EmergencyTriggerResult result = await session.triggerEmergency();
    _log.info('emergency qua nút nổi: $result');
    _notify();
  }

  // ------------------------------------------------------------------ P3: output settings (nguyên vẹn)
  /// P3 task 3: đổi chế độ hiển thị nudge (ghi vào bảng `meta`, đổi được không cần build lại).
  Future<void> selectOutputMode(NudgeOutputMode? mode) async {
    if (mode == null || mode == _outputMode) {
      return;
    }
    _outputMode = mode;
    _notify();
    await trigger.outputModes.write(mode);
    enqueueSnack('Chế độ gợi ý: ${mode.label}');
  }

  Future<void> loadOutputSettings() async {
    final NudgeOutputMode mode = await trigger.outputModes.read();
    final double rate = await trigger.outputModes.readSpeechRate();
    _outputMode = mode;
    _speechRate = rate;
    _notify();
  }

  /// P3 (bổ sung nhỏ để DoD-1 chạy được trên máy thật): mở hộp thoại nhập **API key Groq**.
  /// Không log giá trị key (ràng buộc: không secret trong log/SQLite).
  Future<void> editApiKey(BuildContext context) async {
    // Cố ý dùng `onChanged` thay vì `TextEditingController`: dialog chỉ biến mất sau animation,
    // dispose controller ngay sau `showDialog` làm TextField còn trong cây đọc controller đã hủy.
    String typed = '';
    // issue1_fix mục 3 + 13: user YÊU CẦU HIỂN THỊ PLAINTEXT để debug — đọc key hiện có (nếu có)
    // và điền sẵn vào ô nhập. DEBUG-ONLY: sẽ mask lại khi user muốn (comment mốc P7). KHÔNG log.
    final String currentKey = await SecureStore.readLlmApiKey() ?? '';
    typed = currentKey;
    // `context.mounted` guard sau await đọc key — lint use_build_context_synchronously (A-bài học:
    // không dùng BuildContext qua async gap không kiểm tra).
    if (!context.mounted) {
      return;
    }
    final String? entered = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(currentKey.isEmpty ? 'API key LLM — CHƯA CẤU HÌNH' : 'API key LLM (đang dùng)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              autofocus: true,
              // issue1_fix mục 3/13: KHÔNG obscureText — plaintext theo yêu cầu debug của user.
              // (Xem mục 13 của prompt: chỉ đổi UI display, không làm yếu SecureStore, không log.)
              obscureText: false,
              controller: TextEditingController(text: currentKey),
              onChanged: (String value) => typed = value,
              decoration: InputDecoration(
                labelText: currentKey.isEmpty ? 'Chưa cấu hình — dán key vào đây' : 'API key hiện tại',
                helperText: 'Lưu trong keystore của máy (SecureStore), không vào SQLite/log.',
              ),
            ),
          ],
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
    if (entered == null || !context.mounted) {
      return;
    }
    try {
      // issue1_fix: nhập rỗng ⇒ XOÁ key (đổi từ "bỏ qua" — để UI khớp "Chưa cấu hình" thật sự).
      if (entered.isEmpty) {
        await SecureStore.deleteLlmApiKey();
        _log.info('đã xoá API key LLM (nhập rỗng)');
        enqueueSnack('Đã xoá API key.');
      } else {
        await SecureStore.saveLlmApiKey(entered);
        _log.info('đã lưu API key LLM vào SecureStore (không ghi giá trị)');
        enqueueSnack('Đã lưu API key — bấm Test LLM để kiểm tra.');
      }
    } catch (error) {
      _log.warn('không lưu được API key: $error');
      enqueueSnack('Không lưu được API key: $error');
    }
    await refreshStatus();
  }

  /// P2.1: đọc cấu hình LLM hiện hành để hiển thị trạng thái. Chỉ ĐỌC.
  Future<void> loadLlmConfig() async {
    try {
      final ResolvedLlmConfig config =
          await LlmProviderConfigResolver.resolve(const MetaConfigStore());
      _llmConfig = config;
      // issue1_fix mục 3: đọc thêm giá trị RAW đã lưu (để dialog hiện đúng, kể cả khi hỏng/fallback).
      final ConfigStore store = const MetaConfigStore();
      _rawLlmConfig = (
        url: await store.read(LlmProviderConfig.baseUrlKey),
        model: await store.read(LlmProviderConfig.modelKey),
      );
      _notify();
    } catch (error) {
      // resolve() không ném theo hợp đồng; lưới an toàn cuối cùng.
      _log.warn('không đọc được cấu hình LLM: $error');
    }
  }

  /// P2.1: mở hộp thoại cấu hình endpoint/model LLM. KHÔNG lưu giá trị hỏng — validate ngay trong
  /// dialog (báo lỗi trước khi cho lưu).
  Future<void> editLlmConfig(BuildContext context) async {
    // issue1_fix mục 3: điền sẵn GIÁ TRỊ PERSISTED (không phải placeholder) — "save → reopen →
    // identical". Giá trị rỗng hiện đúng ô trống + helperText mặc định.
    final ({String? url, String? model})? raw = _rawLlmConfig;
    String typedUrl = raw?.url ?? '';
    String typedModel = raw?.model ?? '';
    String? urlError =
        typedUrl.isEmpty ? null : LlmProviderConfigResolver.validateEndpoint(typedUrl);
    final Map<String, Object?>? result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext dialogContext, StateSetter setDialogState) => AlertDialog(
          title: const Text('Cấu hình LLM (OpenAI-compatible)'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                autofocus: true,
                controller: TextEditingController(text: typedUrl),
                onChanged: (String value) {
                  typedUrl = value;
                  setDialogState(() => urlError = LlmProviderConfigResolver.validateEndpoint(value));
                },
                decoration: InputDecoration(
                  labelText: 'Endpoint URL (để trống = Groq)',
                  helperText: SuggestionConfig.groqEndpoint,
                  errorText: urlError,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: TextEditingController(text: typedModel),
                onChanged: (String value) => typedModel = value,
                decoration: const InputDecoration(
                  labelText: 'Model (để trống = mặc định)',
                  helperText: SuggestionConfig.groqModel,
                ),
              ),
              const SizedBox(height: 12),
              // issue1_fix mục 4: Test LLM ngay trong dialog — dùng giá trị ĐANG HIỆN trên UI
              // (ưu tiên trước giá trị đã lưu, đúng yêu cầu prompt).
              OutlinedButton.icon(
                onPressed: _testingLlm
                    ? null
                    : () async {
                        setDialogState(() {}); // vô hiệu hoá nút ngay (loading state)
                        final LlmTestResult test = await _testLlm.run(
                          endpointOverride: typedUrl,
                          modelOverride: typedModel,
                        );
                        if (!dialogContext.mounted) {
                          return;
                        }
                        setDialogState(() => _llmTestResult = test);
                        final ScaffoldMessengerState? messenger = messengerKey.currentState;
                        messenger?.showSnackBar(
                          SnackBar(
                            content: Text(
                              test.isSuccess
                                  ? 'LLM hoạt động · ${test.model} · ${test.latency!.inMilliseconds}ms'
                                  : 'Test LLM thất bại: ${test.message}',
                            ),
                          ),
                        );
                      },
                icon: _testingLlm
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check),
                label: Text(_testingLlm ? 'Testing...' : 'Test LLM'),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Huỷ'),
            ),
            FilledButton(
              // URL hỏng ⇒ không đóng dialog bằng đường Lưu (không lưu giá trị hỏng).
              onPressed: urlError == null
                  ? () => Navigator.of(dialogContext).pop(
                        <String, Object?>{'url': typedUrl.trim(), 'model': typedModel.trim()},
                      )
                  : null,
              child: const Text('Lưu'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !context.mounted) {
      return;
    }
    try {
      final ConfigStore store = const MetaConfigStore();
      final String url = result['url']! as String;
      final String model = result['model']! as String;
      // Chỉ ghi giá trị hợp lệ; rỗng = xoá cấu hình tuỳ chỉnh (quay về mặc định).
      if (url.isEmpty) {
        await store.write(LlmProviderConfig.baseUrlKey, '');
      } else {
        await LlmProviderConfigResolver.writeEndpoint(store, url);
      }
      if (model.isEmpty) {
        await store.write(LlmProviderConfig.modelKey, '');
      } else {
        await LlmProviderConfigResolver.writeModel(store, model);
      }
      enqueueSnack('Đã lưu cấu hình LLM — lần gọi Gợi ý kế tiếp dùng cấu hình mới.');
    } catch (error) {
      _log.warn('không lưu được cấu hình LLM: $error');
      enqueueSnack('Không lưu được cấu hình LLM: $error');
    }
    await loadLlmConfig();
  }

  /// P2.1: xoá 2 khoá cấu hình LLM ⇒ provider quay về Groq mặc định (DoD "Khôi phục mặc định").
  Future<void> resetLlmConfig() async {
    try {
      await LlmProviderConfigResolver.reset(const MetaConfigStore());
      enqueueSnack('Đã khôi phục mặc định Groq.');
    } catch (error) {
      _log.warn('không khôi phục được cấu hình LLM: $error');
      enqueueSnack('Không khôi phục được: $error');
    }
    await loadLlmConfig();
  }

  /// Xem trước tốc độ đọc khi đang kéo thanh trượt (chỉ vẽ lại, chưa ghi DB — ghi ở [saveSpeechRate]).
  void setSpeechRatePreview(double rate) {
    _speechRate = rate;
    _notify();
  }

  /// P3 mục 4.8: lưu tốc độ đọc TTS. Chỉ gọi khi người dùng **nhả** thanh trượt (`onChangeEnd`).
  Future<void> saveSpeechRate(double rate) async {
    final double normalized = OutputConfig.clampSpeechRate(rate);
    _speechRate = normalized;
    _notify();
    await trigger.outputModes.writeSpeechRate(normalized);
    enqueueSnack('Tốc độ đọc: ${normalized.toStringAsFixed(2)}x');
  }

  // ------------------------------------------------------------------ P5: Pre-Brief + Training Level
  /// Mở màn hình Pre-Brief (P5 task 1). Kết quả đã được store ghi sẵn — UI chỉ cần thông báo.
  Future<void> openPreBrief(BuildContext context) async {
    final NavigatorState navigator = Navigator.of(context);
    final bool? saved = await navigator.push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext _) =>
            PreBriefScreen(store: session.trigger.suggestions.preBriefs),
      ),
    );
    if (saved != true || !context.mounted) {
      return;
    }
    final bool has = session.trigger.suggestions.preBriefs.hasCurrent;
    enqueueSnack(has ? 'Đã lưu Pre-Brief cho buổi này.' : 'Đã xoá Pre-Brief.');
    _notify();
  }

  /// Đổi Training Level (P5 task 4 — mục 4.9). Chỉ ghi cấu hình; **không** kèm bất kỳ gợi ý đổi cấp nào.
  Future<void> selectLevel(TrainingLevel? level) async {
    if (level == null || level == _level) {
      return;
    }
    final bool saved = await session.trigger.suggestions.levels.save(level);
    _level = session.trigger.suggestions.levels.current;
    _notify();
    enqueueSnack(
      saved
          ? 'Cấp độ: ${level.label} — ${level.behavior}'
          : 'Không lưu được cấp độ (${level.label})',
    );
  }

  // ------------------------------------------------------------------ P5.1: retention (nguyên vẹn)
  /// Đọc hạn tự xoá đang có hiệu lực để hiển thị trên dropdown. Lỗi resolver tự nuốt.
  Future<void> loadRetentionDays() async {
    try {
      final Duration retention =
          await RetentionConfigResolver.resolve(const MetaConfigStore());
      _retentionDays = retention.inDays;
      _notify();
    } catch (error) {
      _log.warn('không đọc được hạn tự xoá — hiển thị mặc định: $error');
      _retentionDays = StorageConfig.transcriptRetention.inDays;
      _notify();
    }
  }

  /// Đổi hạn tự xoá (P5.1): lưu ngay + **chạy cleanup ngay lập tức** — không đợi lần mở app sau.
  Future<void> changeRetentionDays(int days) async {
    if (days == _retentionDays) {
      return;
    }
    final ConfigStore store = const MetaConfigStore();
    try {
      await RetentionConfigResolver.save(store, days);
    } catch (error, stackTrace) {
      _log.error('không lưu được hạn tự xoá', error, stackTrace);
      enqueueSnack('Không lưu được hạn tự xoá: $error');
      return;
    }
    _retentionDays = days;
    _notify();
    try {
      final int? removed = await RetentionCleanup.runNow(configStore: store);
      enqueueSnack(
        removed == null
            ? 'Đã lưu hạn $days ngày — chưa chạy được dọn dữ liệu cũ, sẽ chạy khi mở app sau.'
            : (removed > 0
                ? 'Đã lưu hạn $days ngày — đã dọn $removed phiên cũ.'
                : 'Đã lưu hạn $days ngày. Không có dữ liệu nào quá hạn.'),
      );
    } catch (error) {
      // `runNow` tự nuốt lỗi rồi trả `null`, nhưng giữ lưới an toàn cho trường hợp bất ngờ.
      _log.warn('cleanup theo hạn mới lỗi: $error');
      enqueueSnack('Đã lưu hạn $days ngày — dọn dữ liệu cũ lỗi: $error');
    }
  }

  // ------------------------------------------------------------------ phiên: kết thúc + Post-Review
  /// **Kết thúc buổi** → Post-Review (P5 task 3): tắt phiên rồi phân tích transcript của buổi vừa nói.
  ///
  /// Thứ tự có ý nghĩa: `stop()` trước (nhả ASR/model, đúng thứ tự của P4) rồi mới phân tích.
  /// Transcript KHÔNG bị mất khi tắt phiên, nên vẫn đọc được đầy đủ sau `stop()`.
  Future<void> finishSessionAndReview(BuildContext context) async {
    final NavigatorState navigator = Navigator.of(context);
    _busy = true;
    _notify();
    try {
      if (session.isActive) {
        // issue1_fix mục 6: capture sessionId TRƯỚC mọi async — `stop()` không đổi sessionId của
        // TranscriptStore, nhưng Post-Review đọc `transcript.sessionId` bên trong `run()` nên phải
        // chốt ngay từ đầu để đánh dấu đúng phiên vừa nói (tránh race khi có code nào đổi phiên).
        final int finalSessionId = transcript.sessionId!;
        await session.stop();
        enqueueSnack('Đã kết thúc buổi — đang tạo nhận xét...');
        // issue1_fix mục 6: đánh dấu kết thúc CHỦ ĐỘNG ngay sau khi stop, TRƯỚC Post-Review (lần
        // Start kế tiếp sẽ tạo phiên MỚI, không resume phiên này dù còn trong resumeGap).
        await transcript.markCurrentSessionEnded();
        _log.info('phiên #$finalSessionId đã đánh dấu kết thúc (user-initiated)');
      }
      final PostReviewReport report = await postReview.run();
      // Transcript đầy đủ chỉ để hiện ở "xem chi tiết" — đọc lỗi thì vẫn hiện báo cáo, chỉ mất phần chi
      // tiết (không được để một lần đọc DB lỗi làm mất cả bản nhận xét).
      String detail = '';
      try {
        detail = (await transcript.sessionTranscript()).text;
      } catch (error) {
        _log.warn('không đọc được transcript cho phần chi tiết: $error');
      }
      _log.info('post-review: ${report.toString()}');
      if (!context.mounted) {
        return;
      }
      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext _) =>
              PostReviewScreen(report: report, detailTranscript: detail),
        ),
      );
    } catch (error, stackTrace) {
      // `PostReviewService.run()` cam kết không ném; đây là lưới an toàn cuối cùng của UI.
      _log.error('Post-Review lỗi ngoài dự kiến', error, stackTrace);
      enqueueSnack('Không tạo được nhận xét: $error');
    } finally {
      _busy = false;
      _notify();
      await refreshStatus();
    }
  }

  // ------------------------------------------------------------------ SnackBar queue (nguyên vẹn, qua key)
  /// Hàng đợi SnackBar: mọi lỗi/tiến trình đi qua đây để không hiện đè nhau khi nhiều lỗi đến
  /// liên tục. P5.3: gọi qua `ScaffoldMessenger` key của RootScaffold — không phụ thuộc context tab.
  void enqueueSnack(String message) {
    _snackQueue.add(message);
    _drainSnackQueue();
  }

  Future<void> _drainSnackQueue() async {
    if (_snackQueueBusy) {
      return;
    }
    _snackQueueBusy = true;
    try {
      while (_snackQueue.isNotEmpty) {
        final ScaffoldMessengerState? messenger = messengerKey.currentState;
        if (messenger == null) {
          break;
        }
        final String message = _snackQueue.removeAt(0);
        messenger.showSnackBar(SnackBar(content: Text(message)));
        // Chờ SnackBar đóng hẳn (4s hiển thị) rồi mới hiện cái kế tiếp — tránh đè nhau.
        await Future<void>.delayed(const Duration(milliseconds: 4100));
      }
    } finally {
      _snackQueueBusy = false;
    }
  }

  // ------------------------------------------------------------------ refresh (nguyên vẹn)
  /// "Làm mới trạng thái" = trạng thái hạ tầng + trạng thái tai nghe cho tầng TTS (P1F).
  Future<void> refreshAll() async {
    await refreshStatus();
    await refreshTts();
  }

  /// Đọc trạng thái. Mọi lời gọi plugin đều bọc try/catch: màn hình chính không được crash
  /// chỉ vì một mảnh hạ tầng lỗi (đây là màn hình dùng để chẩn đoán trên máy thật).
  Future<void> refreshStatus() async {
    bool running = false;
    String database = 'chưa kiểm tra';
    bool? keyPresent;
    Map<String, bool> perms = <String, bool>{};

    try {
      running = await ListeningService.isRunning();
    } catch (error) {
      _log.warn('không đọc được trạng thái service: $error');
    }
    try {
      perms = await PermissionGate.currentStatus();
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
      keyPresent = await SecureStore.hasLlmApiKey();
    } catch (error) {
      _log.warn('không đọc được secure storage: $error');
    }

    _serviceRunning = running;
    _permissions = perms;
    _databaseStatus = database;
    _hasApiKey = keyPresent;
    _notify();
  }

  // ------------------------------------------------------------------ bật/tắt phiên (nguyên vẹn)
  /// Bật/tắt phiên lắng nghe. Toàn bộ thứ tự mở (service → capture → VAD → ASR) và đóng (ngược lại)
  /// nằm trong [ConversationSessionController] — UI chỉ bấm nút.
  Future<void> toggleService() async {
    _busy = true;
    _notify();
    try {
      if (session.isActive) {
        await session.stop();
        enqueueSnack('Đã tắt lắng nghe');
      } else {
        // Phiên tự xử lý `CaptureError` (thông báo + tắt service) — không ném ra UI.
        final bool started = await session.start();
        if (started) {
          enqueueSnack('Đang lắng nghe');
        } else if (!hasFakeService) {
          enqueueSnack('Không bật được phiên — kiểm tra quyền micro (tab Cài đặt hoặc hệ thống).');
        }
      }
    } catch (error, stackTrace) {
      _log.error('đổi trạng thái phiên lỗi', error, stackTrace);
      enqueueSnack('Lỗi: $error');
    } finally {
      _busy = false;
      _notify();
      await refreshStatus();
    }
  }

  /// `true` khi test bơm service giả (không đụng permission/plugin thật) — khi đó không hiện
  /// cảnh báo "thiếu quyền" vì môi trường test không có ý nghĩa quyền.
  bool get hasFakeService => _startServiceOverride != null;

  // ------------------------------------------------------------------ P1E: mốc Push (nguyên vẹn)
  Future<void> markPush() async {
    await transcript.markPushMoment(DateTime.now());
    _notify();
  }

  // ------------------------------------------------------------------ các dòng chẩn đoán (nguyên vẹn)
  String permissionText() {
    final Map<String, bool> perms = _permissions;
    return perms.isEmpty
        ? 'chưa kiểm tra'
        : perms.entries.map((MapEntry<String, bool> e) {
            final String name = e.key
                .replaceAll('android.permission.', '')
                .replaceAll('Permission.', '');
            return '$name=${e.value ? "có" : "không"}';
          }).join(' · ');
  }

  /// Trạng thái đường phát TTS (P1F) — hiện thẳng thiết bị đang được coi là "tai nghe".
  String ttsText() {
    final TtsOutputInfo? info = safeTts.lastInfo;
    final TtsDevice? device = info?.preferred;
    final String deviceText = device == null
        ? 'không thấy thiết bị riêng tư nào'
        : '${device.name ?? "thiết bị lạ"} (type ${device.type}) · ${info!.devices.length} thiết bị riêng tư';
    return switch (safeTts.state) {
      TtsOutputState.unknown => 'chưa kiểm tra',
      TtsOutputState.ready =>
        safeTts.isSpeaking ? 'đang đọc · $deviceText' : 'sẵn sàng · $deviceText',
      TtsOutputState.silent => safeTts.needsConfirmation
          ? 'CHẾ ĐỘ IM LẶNG · chờ xác nhận tai nghe (bấm nút xác nhận)'
          : 'CHẾ ĐỘ IM LẶNG · $deviceText',
    };
  }

  /// Trạng thái hội thoại cho màn hình chẩn đoán (P1B). Vẽ lại mỗi buffer VAD nhờ `vadTick` (F4).
  String conversationText() {
    if (!conversation.isRunning) {
      return 'chưa nghe';
    }
    final String label = conversation.isUserSpeaking ? 'USER_SPEAKING' : 'NOT_USER_SPEAKING';
    final double? ratio = conversation.lastStat?.speechRatio;
    return ratio == null ? label : '$label · tỉ lệ nói ${ratio.toStringAsFixed(2)}';
  }

  /// Trạng thái ASR (P1D) — số giây audio đã đưa vào engine, số chunk bị bỏ.
  String asrText() {
    if (!session.isAsrRunning) {
      return 'chưa chạy · engine đã chọn: ${asrKind.label}';
    }
    // PCM16 mono 16kHz = 32000 byte/giây.
    final String seconds = (session.asrAudioBytes / 32000).toStringAsFixed(1);
    final int dropped = session.asrDroppedChunks;
    return '${asrKind.label} · đang chạy · ${seconds}s audio'
        '${dropped > 0 ? " · bỏ $dropped chunk" : ""}';
  }

  /// Pha phiên + số liệu half-duplex/phục hồi (P4) — bề mặt bằng chứng trên máy thật.
  String sessionText() {
    if (!session.isActive) {
      return 'chưa bật';
    }
    final StringBuffer buffer = StringBuffer(session.phase.name);
    final int dropped = session.chunksDroppedWhileSpeaking;
    if (dropped > 0) {
      buffer.write(' · chặn $dropped chunk khi đang phát');
    }
    if (session.asrResumeCount > 0) {
      buffer.write(' · ASR nhận lại ${session.asrResumeCount} lần');
    }
    if (session.overlapPreventedCount > 0) {
      buffer.write(' · bỏ qua ${session.overlapPreventedCount} Push (đang phát)');
    }
    if (session.recoveryCount > 0) {
      buffer.write(' · phục hồi ${session.recoveryCount} lần');
    }
    final Duration? latency = session.averagePushLatency;
    if (latency != null) {
      buffer.write(' · Push→tổng hợp ${latency.inMilliseconds}ms (tb)');
    }
    final DateTime? started = session.sessionStartedAt;
    if (started != null) {
      buffer.write(' · từ ${started.hour.toString().padLeft(2, '0')}:'
          '${started.minute.toString().padLeft(2, '0')}');
    }
    return buffer.toString();
  }

  /// Trạng thái transcript (P1E): số dòng RAM + số dòng đã khôi phục sau kill.
  String transcriptText() {
    final int? sessionId = transcript.sessionId;
    if (sessionId == null) {
      return 'chưa mở (xem log bootstrap)';
    }
    final StringBuffer buffer = StringBuffer('phiên #$sessionId');
    buffer.write(' · RAM ${transcript.memorySegmentCount} dòng');
    if (transcript.recoveredSegmentCount > 0) {
      buffer.write(' · khôi phục ${transcript.recoveredSegmentCount} dòng sau khi app bị kill');
    }
    return buffer.toString();
  }

  /// Kết quả gợi ý gần nhất (P2): nudge kèm type; NO_SUGGESTION hiển thị nguyên nhân.
  String suggestionText() {
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

  /// Trạng thái lớp Coaching (P5) — hiện **số liệu**, không hiện nội dung tóm tắt (nhạy cảm như transcript).
  String coachingText() {
    final bool hasPreBrief = session.trigger.suggestions.preBriefs.hasCurrent;
    final SessionSummaryService summaries = session.trigger.suggestions.summaries;
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
    // Số lần chạy Post-Review là bằng chứng cho phần "học hỏi sau" của P5 (DoD-2).
    if (postReview.runCount > 0) {
      buffer.write(' · nhận xét ${postReview.runCount} lần');
    }
    final String? note = summaries.lastNote;
    if (note != null) {
      buffer.write(' ($note)');
    }
    return buffer.toString();
  }

  /// Mốc Push gần nhất (P1E) — P2 sẽ đưa mốc này vào prompt LLM.
  String pushText() {
    final DateTime? moment = transcript.lastPushMoment;
    return moment == null ? 'chưa bấm' : moment.toIso8601String();
  }

  /// Trạng thái Emergency Phrase (P1G): câu của lần trigger gần nhất + độ trễ đo được.
  String emergencyText() {
    final String? phrase = session.emergency.lastPhrase;
    if (phrase == null) {
      return 'chưa kích hoạt · câu kế tiếp: "${session.emergency.nextPhrase}"';
    }
    final Duration? latency = session.emergency.lastTriggerToSynthLatency;
    return '"$phrase" · phát sau ${latency?.inMilliseconds ?? "?"}ms (chưa tính thời gian đọc)';
  }

  /// Trạng thái capture cho màn hình chẩn đoán (P1A) — đọc đồng bộ; widget tự vẽ lại theo stream (F4).
  String captureStatusText() {
    final CaptureStatus status = capture.currentStatus;
    return switch (status) {
      CaptureStatus.capturing =>
        'đang ghi · ${(capture.capturedBytes / 1024).toStringAsFixed(0)} KB',
      CaptureStatus.starting => 'đang mở mic…',
      CaptureStatus.error => 'lỗi (xem thông báo)',
      CaptureStatus.stopped => 'đã dừng',
      CaptureStatus.idle => 'chưa ghi',
    };
  }
}
