import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../audio/asr/asr_engine.dart';
import '../audio/asr/asr_engine_selector.dart';
import '../transcript/transcript_store.dart';
import '../audio/capture/audio_capture_controller.dart';
import '../audio/capture/capture_config.dart';
import '../audio/vad/conversation_state.dart';
import '../audio/vad/conversation_state_notifier.dart';
import '../core/app_logger.dart';
import '../core/constants.dart';
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
  }

  @override
  void dispose() {
    _captureStatusSub?.cancel();
    _captureErrorSub?.cancel();
    _vadStatSub?.cancel();
    _asrChunkSub?.cancel();
    _asrTranscriptSub?.cancel();
    _asrTicker?.cancel();
    unawaited(_transcript.detach());
    unawaited(_asr?.dispose());
    _vadTick.dispose();
    super.dispose();
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

  /// Đổi engine ASR (P1D task 2/3): ghi cấu hình rồi khởi động lại ASR nếu đang chạy. Không cần
  /// build lại app và không đụng tới code tầng trên.
  Future<void> _selectAsrEngine(AsrEngineKind? kind) async {
    if (kind == null || kind == _asrKind) {
      return;
    }
    setState(() => _asrKind = kind);
    try {
      await _asrSelector.writeConfigured(kind);
    } catch (error) {
      _log.warn('không ghi được cấu hình engine ASR: $error');
      _enqueueSnack('Không lưu được lựa chọn engine: $error');
    }
    final bool wasRunning = _asr != null;
    if (wasRunning) {
      await _stopAsr();
      await _startAsr(); // Chạy lại bằng engine vừa chọn để so sánh ngay trên máy.
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
            onPressed: _busy ? null : _refreshStatus,
            child: const Text('Làm mới trạng thái'),
          ),
          const SizedBox(height: 16),
          // P1D: chọn engine nhận dạng ngay trên máy — ghi vào cấu hình (bảng `meta`), không cần
          // build lại app. Đổi engine khi đang chạy sẽ tự khởi động lại để so sánh trực tiếp.
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
          const SizedBox(height: 24),
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
            _infoRow('Nhận dạng', _lastTranscript),
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
