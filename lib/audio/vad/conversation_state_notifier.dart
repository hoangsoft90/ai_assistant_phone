import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/app_logger.dart';
import 'conversation_state.dart';
import 'vad_client.dart';

/// Singleton dùng chung (UI hiện trạng thái, P2 sẽ subscribe để chặn gọi LLM).
abstract final class ConversationStateNotifier {
  static final ConversationStateMachine instance = ConversationStateMachine();
}

/// State machine tối giản của P1B: **chỉ 2 state** `userSpeaking` / `notUserSpeaking`.
///
/// Thuật toán (bộ tích luỹ rò — leaky bucket):
/// - Mỗi buffer VAD đến: nếu tỉ lệ khung có tiếng nói >= [ConversationStateConfig.speechRatioThreshold]
///   thì cộng `durationMs` vào `_speechAccumMs`, ngược lại trừ đi (không xuống dưới 0).
///   Chiều còn lại làm tương tự với `_silenceAccumMs`.
/// - Chuyển sang [ConversationState.userSpeaking] khi `_speechAccumMs >= attackMs`;
///   về [ConversationState.notUserSpeaking] khi `_silenceAccumMs >= releaseMs`.
///
/// **Vì sao dùng bộ tích luỹ rò chứ không phải "đếm chuỗi liên tục":** một khung im lặng ngắn giữa
/// câu (ngập ngừng, tiếng ồn che) sẽ **reset** bộ đếm liên tục và state không bao giờ bật — đúng
/// lỗi mà DoD thứ 3 ("không flicker") đang nhắm tới. Bộ tích luỹ rò cho phép mất vài khung mà vẫn
/// giữ được đà, đồng thời vẫn cần đủ thời lượng thật mới đổi state.
///
/// **Watchdog (F2, review P1B — quyết định của user):** nếu đang `userSpeaking` mà **không còn
/// buffer VAD nào đến** quá [ConversationStateConfig.watchdogMs] (VAD chết, capture chết, kênh
/// platform đứt), máy **tự mở khoá** về `notUserSpeaking` kèm reason `inputStalled` — không AI bị
/// chặn gọi LLM vĩnh viễn. Chọn **watchdog thay vì reset tức thì khi stream lỗi** vì:
/// (a) lỗi nhất thời không đáng mở khoá ngay, (b) mở khoá tức thì = AI chen ngang đúng lúc người
/// dùng đang nói mà VAD hiccup. Watchdog không can thiệp khi VAD vẫn phát bình thường (dữ liệu
/// đến liên tục sẽ liên tục đẩy deadline ra xa).
///
/// Ràng buộc phạm vi: **KHÔNG** phân biệt ai đang nói (không diarization, không dùng amplitude để
/// đoán người nói) — chỉ biết "có tiếng nói gần mic hay không". **KHÔNG** thêm state thứ 3.
class ConversationStateMachine {
  ConversationStateMachine({
    VadClient? client,
    this.config = ConversationStateConfig.defaults,
  }) : _client = client ?? NativeVadClient();

  static const AppLogger _log = AppLogger('ConversationState');

  final VadClient _client;
  final ConversationStateConfig config;

  final ValueNotifier<ConversationState> _state =
      ValueNotifier<ConversationState>(ConversationState.notUserSpeaking);
  final StreamController<ConversationState> _changes =
      StreamController<ConversationState>.broadcast();
  final StreamController<ConversationStateChange> _transitions =
      StreamController<ConversationStateChange>.broadcast();
  final StreamController<VadFrameStat> _stats =
      StreamController<VadFrameStat>.broadcast();
  final List<ConversationStateChange> _history = <ConversationStateChange>[];

  // Subscription được `cancel()` trong `stop()`/`dispose()` (không phải trong hàm tạo nó) —
  // lint `cancel_subscriptions` chỉ nhìn phạm vi một hàm nên báo nhầm ở đây.
  // ignore: cancel_subscriptions
  StreamSubscription<VadFrameStat>? _subscription;
  int _speechAccumMs = 0;
  int _silenceAccumMs = 0;
  VadFrameStat? _lastStat;
  Timer? _watchdog;

  /// Trạng thái hiện tại (đọc đồng bộ — P2 dùng cái này để chặn gọi LLM).
  ConversationState get state => _state.value;

  /// `true` khi người dùng đang nói ⇒ **khoá cứng**, không được gọi LLM (ràng buộc P2).
  bool get isUserSpeaking => _state.value == ConversationState.userSpeaking;

  /// Lắng nghe thay đổi trạng thái (chỉ phát khi giá trị **đổi**, không phát lặp).
  Stream<ConversationState> get changes => _changes.stream;

  /// Dạng `ValueListenable` để widget dùng `ValueListenableBuilder` (không phải tự subscribe).
  ValueListenable<ConversationState> get stateListenable => _state;

  /// Chi tiết từng lần chuyển state (kèm lý do + tỉ lệ tiếng nói) — dùng cho timeline kiểm thử.
  Stream<ConversationStateChange> get transitions => _transitions.stream;

  /// Lịch sử chuyển state **trong phiên hiện tại** (không lưu vĩnh viễn). Bản mới nhất ở cuối.
  List<ConversationStateChange> get history => List.unmodifiable(_history);

  /// Kết quả VAD gần nhất (để UI/debug hiện tỉ lệ tiếng nói).
  VadFrameStat? get lastStat => _lastStat;

  /// Stream mọi stat VAD đến (kể cả khi state không đổi) — UI dùng để hiện tỉ lệ nói live.
  Stream<VadFrameStat> get stats => _stats.stream;

  bool get isRunning => _subscription != null;

  /// Bắt đầu nghe VAD. Bắt đầu ở [ConversationState.notUserSpeaking] (chưa có bằng chứng có tiếng nói).
  void start() {
    if (_subscription != null) {
      return;
    }
    _speechAccumMs = 0;
    _silenceAccumMs = config.releaseMs; // Đủ để giữ notUserSpeaking ngay từ đầu.
    _subscription = _client.frames().listen(
      _onStat,
      onError: (Object error, StackTrace stackTrace) {
        // F2: lỗi stream KHÔNG reset state tức thì (quyết định của user) — chỉ log. Nếu dữ liệu
        // thật sự đứt hẳn thì watchdog dưới đây sẽ mở khoá sau [config.watchdogMs].
        _log.error('kênh VAD lỗi', error, stackTrace);
      },
    );
    _log.info('bắt đầu nghe VAD ($config)');
  }

  /// Ngừng nghe VAD. Trạng thái giữ nguyên giá trị cuối (không tự đổi); hủy watchdog.
  Future<void> stop() async {
    final StreamSubscription<VadFrameStat>? subscription = _subscription;
    _subscription = null;
    _cancelWatchdog();
    await subscription?.cancel();
    _log.info('ngừng nghe VAD (state cuối=${_state.value.name})');
  }

  /// Giải phóng vĩnh viễn (test/teardown).
  Future<void> dispose() async {
    await stop();
    await _changes.close();
    await _transitions.close();
    await _stats.close();
    _state.dispose();
    _history.clear();
  }

  /// Giảm bộ tích luỹ theo kiểu "rò" (không xuống dưới 0, không vượt trần `cap`).
  ///
  /// Viết tay thay vì `int.clamp` vì `clamp` trả `num` — với `strict-casts: true` của repo thì
  /// phải `.toInt()` mới gán được vào `int`, dễ sinh lỗi ngầm về sau.
  static int _decrease(int value, int delta, int cap) {
    final int next = value - delta;
    return next < 0 ? 0 : (next > cap ? cap : next);
  }

  void _onStat(VadFrameStat stat) {
    _lastStat = stat;
    _emitStat(stat);
    _armWatchdog(stat.elapsedMs);
    final int durationMs = stat.durationMs;
    final bool speechTick = stat.speechRatio >= config.speechRatioThreshold;

    if (speechTick) {
      _speechAccumMs += durationMs;
      _silenceAccumMs = _decrease(_silenceAccumMs, durationMs, config.releaseMs);
    } else {
      _silenceAccumMs += durationMs;
      _speechAccumMs = _decrease(_speechAccumMs, durationMs, config.attackMs);
    }

    switch (_state.value) {
      case ConversationState.notUserSpeaking:
        if (_speechAccumMs >= config.attackMs) {
          _publish(ConversationState.userSpeaking,
              ConversationStateReason.speechAccumulated, stat);
        }
      case ConversationState.userSpeaking:
        if (_silenceAccumMs >= config.releaseMs) {
          _publish(ConversationState.notUserSpeaking,
              ConversationStateReason.silenceAccumulated, stat);
        }
    }
  }

  /// Bật lại watchdog (chỉ khi đang `userSpeaking` — watchdog chỉ có nhiệm vụ mở khoá).
  ///
  /// Dùng `elapsedMs` của buffer làm mốc, rồi đếm thêm [ConversationStateConfig.watchdogMs] bằng
  /// thời gian **thật** (Timer) — không tin wall clock, không cần liên hệ với buffer kế tiếp.
  void _armWatchdog(int elapsedMs) {
    if (state != ConversationState.userSpeaking) {
      _cancelWatchdog();
      return;
    }
    _watchdog?.cancel();
    _watchdog = Timer(
      Duration(milliseconds: config.watchdogMs),
      () => _onWatchdogFired(elapsedMs),
    );
  }

  /// Watchdog nổ: đang `userSpeaking` mà quá lâu không có buffer VAD nào ⇒ mở khoá.
  ///
  /// Kiểm lại state trước khi publish vì giữa lúc hẹn và lúc nổ có thể đã có buffer mới
  /// (re-arm) hoặc `stop()` đã được gọi.
  void _onWatchdogFired(int elapsedMs) {
    _watchdog = null;
    if (state != ConversationState.userSpeaking) {
      return;
    }
    _log.warn(
      'không còn dữ liệu VAD trong ${config.watchdogMs}ms (t=$elapsedMs) — '
      'mở khoá hội thoại (inputStalled)',
    );
    _publish(
      ConversationState.notUserSpeaking,
      ConversationStateReason.inputStalled,
      _lastStat ??
          VadFrameStat(
            speechFrames: 0,
            totalFrames: 0,
            frameMs: 0,
            elapsedMs: elapsedMs,
          ),
    );
  }

  void _cancelWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  void _publish(
    ConversationState next,
    ConversationStateReason reason,
    VadFrameStat stat,
  ) {
    final ConversationState previous = _state.value;
    if (previous == next) {
      return;
    }
    _state.value = next;
    // Reset cả hai bộ tích luỹ khi đã đổi state: vòng đếm mới bắt đầu từ 0.
    _speechAccumMs = 0;
    _silenceAccumMs = 0;
    // Watchdog theo state: vào khoá thì hẹn ngay (buffer gây chuyển state là buffer CUỐI cùng
    // trước khi hẹn — nếu chỉ re-arm trong _onStat thì lúc vào khoá watchdog chưa được hẹn và
    // mất dữ liệu ngay sau đó sẽ kẹt khoá vĩnh viễn, đúng bug mà F2 nhắm); ra khỏi khoá thì hủy.
    if (next == ConversationState.userSpeaking) {
      _armWatchdog(stat.elapsedMs);
    } else {
      _cancelWatchdog();
    }

    final ConversationStateChange change = ConversationStateChange(
      state: next,
      previous: previous,
      atMs: stat.elapsedMs,
      reason: reason,
      speechRatio: stat.speechRatio,
    );
    _recordHistory(change);
    if (!_changes.isClosed) {
      _changes.add(next);
    }
    if (!_transitions.isClosed) {
      _transitions.add(change);
    }
    _log.info('chuyển state: $change');
  }

  /// Đẩy stat vào stream cho UI (F4). Gọi trong `_onStat` TRƯỚC logic state — UI được cập nhật
  /// cả khi state giữ nguyên.
  void _emitStat(VadFrameStat stat) {
    if (!_stats.isClosed) {
      _stats.add(stat);
    }
  }

  void _recordHistory(ConversationStateChange change) {
    _history.add(change);
    if (_history.length > config.historyLimit) {
      _history.removeRange(0, _history.length - config.historyLimit);
    }
  }
}
