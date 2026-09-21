/// Kiểu dữ liệu cho VAD + state machine tối giản của P1B.
///
/// Ràng buộc phạm vi (từ `prompt_P1B.md`): CHỈ có 2 state. Các state ngữ nghĩa phức tạp
/// (`TOPIC_DYING`, `AWKWARD_SILENCE`…) thuộc P6 — thêm ở đây là làm sai phạm vi.
library;

/// State hội thoại tối giản — dùng để chặn/cho phép gọi LLM ở P2.
enum ConversationState {
  /// Có tiếng nói sát mic ⇒ **khoá cứng**: tuyệt đối không gọi LLM, không gợi ý.
  userSpeaking,

  /// Không có tiếng nói sát mic ⇒ cho phép gọi LLM khi có trigger.
  notUserSpeaking,
}

/// Một kết quả VAD do native gửi lên (đã chia thành các khung 20ms).
///
/// `elapsedMs` là đồng hồ **đơn điệu** (`SystemClock.elapsedRealtime` bên Kotlin) — không dùng
/// wall clock vì state machine đo khoảng thời gian.
class VadFrameStat {
  const VadFrameStat({
    required this.speechFrames,
    required this.totalFrames,
    required this.frameMs,
    required this.elapsedMs,
  });

  /// Số khung được VAD coi là có tiếng nói.
  final int speechFrames;

  /// Tổng số khung trong buffer này.
  final int totalFrames;

  /// Độ dài mỗi khung (ms) — 20ms ở cấu hình WebRTC VAD 16kHz/320 mẫu.
  final int frameMs;

  /// Thời điểm kết thúc buffer, theo đồng hồ đơn điệu của thiết bị.
  final int elapsedMs;

  /// Buffer này bao phủ bao nhiêu ms audio.
  int get durationMs => totalFrames * frameMs;

  /// Tỉ lệ khung có tiếng nói (0.0–1.0).
  double get speechRatio =>
      totalFrames == 0 ? 0.0 : speechFrames / totalFrames;

  /// Đọc từ payload của kênh native. Lỗi format là lỗi lập trình → ném `FormatException`.
  factory VadFrameStat.fromNative(Object? payload) {
    if (payload is! Map) {
      throw FormatException('payload VAD không phải Map: $payload');
    }
    int read(String key) {
      final Object? value = payload[key];
      if (value is! num) {
        throw FormatException('payload VAD thiếu/sai kiểu "$key": $payload');
      }
      return value.toInt();
    }

    return VadFrameStat(
      speechFrames: read('speechFrames'),
      totalFrames: read('totalFrames'),
      frameMs: read('frameMs'),
      elapsedMs: read('elapsedMs'),
    );
  }

  @override
  String toString() =>
      'VadFrameStat($speechFrames/$totalFrames khung, ${durationMs}ms, t=$elapsedMs)';
}

/// Ngưỡng thời gian của state machine.
///
/// Ý nghĩa & căn cứ:
/// - [attackMs] = 300ms: cần ~300ms tiếng nói **tích luỹ** mới chuyển sang [ConversationState.userSpeaking].
///   Với VAD trả kết quả mỗi buffer 100ms, thời gian phản ứng xấu nhất ≈ 300 + 100 = **400ms < 500ms**
///   (đúng mục DoD đầu tiên của P1B). Đủ dài để tiếng động ngắn (gõ bàn phím, ho) không kích state.
/// - [releaseMs] = 1500ms: cần ~1.5s im lặng tích luỹ mới trả về [ConversationState.notUserSpeaking]
///   (DoD nói "~1–2s im lặng"). Dài hơn attack nhiều là **có chủ ý**: thà giữ khoá lâu còn hơn để
///   AI chen ngang khi người dùng chỉ đang ngập ngừng giữa câu.
/// - [speechRatioThreshold] = 0.5: một buffer được coi là "có tiếng nói" khi **đa số** khung trong đó
///   có tiếng nói — giúp chống flicker do tiếng ồn nền (nhạc/TV) chỉ vài khung lẻ.
/// - [watchdogMs] = 1500ms (F2, review P1B — user duyệt hướng "watchdog 1.5–2s"): đang
///   `userSpeaking` mà không còn buffer VAD nào đến quá 1.5s ⇒ tự mở khoá (reason `inputStalled`)
///   thay vì kẹt khoá vĩnh viễn khi VAD/capture/kênh chết. Ngắn hơn release là **có chủ ý**: đây
///   là đường thoát khẩn, không phải ngưỡng im lặng tự nhiên — và chỉ chạy khi state bị khoá.
class ConversationStateConfig {
  const ConversationStateConfig({
    this.attackMs = 300,
    this.releaseMs = 1500,
    this.speechRatioThreshold = 0.5,
    this.watchdogMs = 1500,
    this.historyLimit = 500,
  });

  final int attackMs;
  final int releaseMs;
  final double speechRatioThreshold;

  /// Không còn dữ liệu VAD quá lâu khi đang khoá ⇒ mở khoá khẩn (F2).
  final int watchdogMs;

  /// Số bản ghi lịch sử chuyển state giữ trong phiên (không lưu vĩnh viễn — yêu cầu của prompt).
  final int historyLimit;

  static const ConversationStateConfig defaults = ConversationStateConfig();

  @override
  String toString() =>
      'ConversationStateConfig(attack=$attackMs ms, release=$releaseMs ms, '
      'ratio>=$speechRatioThreshold, watchdog=$watchdogMs ms, history=$historyLimit)';
}

/// Lý do chuyển state — để đọc log/timeline hiểu được vì sao.
enum ConversationStateReason {
  /// Đủ tiếng nói tích luỹ (>= attackMs).
  speechAccumulated,

  /// Đủ im lặng tích luỹ (>= releaseMs).
  silenceAccumulated,

  /// Không còn dữ liệu VAD quá lâu khi đang khoá — watchdog mở khoá khẩn (F2).
  inputStalled,

  /// Trạng thái ban đầu khi bắt đầu nghe.
  started,
}

/// Một lần chuyển state, có mốc thời gian — dùng cho timeline kiểm thử thủ công (DoD P1B).
class ConversationStateChange {
  const ConversationStateChange({
    required this.state,
    required this.previous,
    required this.atMs,
    required this.reason,
    required this.speechRatio,
  });

  final ConversationState state;
  final ConversationState? previous;

  /// Đồng hồ đơn điệu (ms) tại thời điểm chuyển.
  final int atMs;

  final ConversationStateReason reason;

  /// Tỉ lệ khung có tiếng nói của buffer gây ra chuyển state này.
  final double speechRatio;

  @override
  String toString() =>
      '${atMs}ms: ${previous?.name ?? "-"} → ${state.name} '
      '(${reason.name}, ratio=${speechRatio.toStringAsFixed(2)})';
}
