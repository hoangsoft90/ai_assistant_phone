import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/app_logger.dart';
import 'asr_engine.dart';

/// Tên kênh ASR dự phòng (phải khớp `VoskChannelBridge.VOSK_CHANNEL` phía Kotlin).
abstract final class VoskChannels {
  static const String control = 'com.aiassistant.phone/vosk';
}

/// Cấu hình engine Vosk (P1D — ASR dự phòng khi máy không chạy nổi PhoWhisper).
///
/// Model: `vosk-model-small-vn-0.4` (32MB nén / 51MB sau khi giải nén) — bản NHỎ NHẤT, đúng vai
/// "phương án dự phòng nhẹ" của `prompt_P1D.md`. Số đo P0 trên host cho thấy bản lớn
/// `vosk-model-vn-0.4` (74MB nén / 168MB giải nén) chính xác hơn (WER 40.3% vs 52.2%) **và** nhanh
/// hơn (RTF 0.21 vs 0.90) — nếu đo trên máy thật (K18/K19) cho thấy cần Vosk chạy nổi thời gian
/// thực thì đổi `modelAssetPath` sang bản lớn là đủ (kèm 1 dòng tải trong workflow). Chi tiết +
/// bảng so sánh: `lib/audio/asr/README.md`.
class VoskConfig {
  const VoskConfig({
    this.modelAssetPath = 'models/vosk-model-small-vn-0.4.zip',
    this.maxQueuedChunks = 25,
    this.initTimeout = const Duration(seconds: 60),
  });

  /// Đường dẫn **Android asset** (trong APK dưới `assets/`) tới file `.zip` của model — Kotlin mở
  /// bằng AssetManager, giải nén ra thư mục rồi nạp bằng Vosk. KHÔNG phải asset khai báo trong
  /// pubspec (xem `pubspec.yaml` mục `assets:` để biết lý do).
  final String modelAssetPath;

  /// Số chunk tối đa chờ trong hàng đợi (25 × 100ms = 2.5s audio). Đầy thì chunk CŨ NHẤT bị bỏ
  /// (kèm đếm) — xem `VoskStreamingEngine` phía Kotlin.
  final int maxQueuedChunks;

  /// Hạn chót cho lời gọi `loadModel` (F3 của review P1D). Rộng rãi vì lần đầu phải **giải nén
  /// 51MB** model; mục đích là cắt lần treo vô hạn để selector còn chạy fallback.
  final Duration initTimeout;

  static const VoskConfig defaults = VoskConfig();
}

/// Engine ASR dự phòng: **Vosk** — streaming, 100% offline.
///
/// Khác `PhoWhisperAsrEngine` ở một điểm CÓ CHỦ Ý: **không gom chunk 3–5s ở Dart**. Vosk có
/// endpointing bên trong (native trả `true` khi hết một câu), nên mỗi chunk PCM được đẩy thẳng
/// xuống native và kết quả phát ra khi Vosk tự chốt câu. Nhờ vậy độ trễ thấp hơn và câu không bị
/// cắt giữa lúc gom — đúng thế mạnh của Vosk.
///
/// Kiến trúc:
/// ```text
/// feedAudioChunk(bytes PCM16 16kHz)            (Dart, từ stream capture P1A)
///   └─ MethodChannel invoke 'feed' ─► Kotlin VoskChannelBridge
///        └─ byte→short[] → hàng đợi có giới hạn ─► thread riêng: acceptWaveForm()
///             └─ hết câu ⇒ invoke 'transcript' {text, latencyMs, audioMs, dropped}
///                  └─ transcriptStream (broadcast)
/// ```
/// Ràng buộc: KHÔNG cloud, KHÔNG nhãn người nói (xem `AsrEngine`).
class VoskAsrEngine implements AsrEngine {
  VoskAsrEngine({this.config = VoskConfig.defaults, MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(VoskChannels.control);

  static const AppLogger _log = AppLogger('Vosk');

  final VoskConfig config;
  final MethodChannel _channel;

  final StreamController<String> _transcripts =
      StreamController<String>.broadcast();

  int _droppedTotal = 0;
  int _chunksSent = 0;
  bool _initialized = false;
  bool _disposed = false;

  @override
  Stream<String> get transcriptStream => _transcripts.stream;

  /// Số chunk bị native bỏ vì không theo kịp thời gian thực (đo ở DoD P1D).
  @override
  int get droppedTotal => _droppedTotal;

  /// Số chunk đã đẩy xuống native từ lúc init — phục vụ so sánh/đo RTF.
  int get chunksSent => _chunksSent;

  @override
  Future<void> init() async {
    if (_initialized) {
      return;
    }
    // Asset (.zip) do Kotlin giải nén ra thư mục — Dart không cần copy model như PhoWhisper
    // (Vosk nhận cả asset vì Kotlin tự mở AssetManager), nên không cần đọc rootBundle ở đây.
    await _channel
        .invokeMethod<void>('loadModel', <String, Object?>{
          'asset': config.modelAssetPath,
          'maxQueue': config.maxQueuedChunks,
        })
        .timeout(
          config.initTimeout,
          onTimeout: () => throw StateError(
            'Vosk: loadModel không phản hồi sau ${config.initTimeout.inSeconds}s',
          ),
        );
    _channel.setMethodCallHandler(_onNativeCall);
    _initialized = true;
    _log.info('Vosk sẵn sàng (${config.modelAssetPath}, '
        'hàng đợi tối đa=${config.maxQueuedChunks} chunk)');
  }

  @override
  Future<void> feedAudioChunk(Uint8List chunk) async {
    if (_disposed) {
      return;
    }
    if (!_initialized) {
      throw StateError('VoskAsrEngine.init() phải được gọi trước feedAudioChunk()');
    }
    if (chunk.isEmpty) {
      return;
    }
    _chunksSent++;
    try {
      await _channel.invokeMethod<void>('feed', <String, Object?>{
        'pcm16': chunk,
      });
    } on PlatformException catch (error) {
      _log.error('kênh Vosk lỗi: ${error.code} ${error.message}');
    } on MissingPluginException {
      // Trong test hoặc khi native chưa đăng ký — bỏ qua im lặng (test có stub riêng).
      _log.warn('kênh Vosk chưa có phía native (MissingPluginException)');
    }
  }

  /// Native chủ động gọi về khi Vosk chốt xong một câu: method `transcript`.
  Future<Object?> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'transcript':
        _applyResult(call.arguments);
      default:
        _log.warn('method không hỗ trợ từ native: ${call.method}');
    }
    return null;
  }

  /// Chỉ dành cho TEST: mô phỏng lời gọi native (cùng đường xử lý với `_onNativeCall`).
  Future<Object?> debugHandleNativeCall(MethodCall call) => _onNativeCall(call);

  void _applyResult(Object? payload) {
    if (payload is! Map) {
      return;
    }
    final Object? text = payload['text'];
    if (text is String && text.trim().isNotEmpty && !_transcripts.isClosed) {
      _transcripts.add(text.trim());
    }
    final Object? dropped = payload['dropped'];
    if (dropped is num) {
      _droppedTotal = dropped.toInt();
    }
    final Object? latency = payload['latencyMs'];
    final Object? audioMs = payload['audioMs'];
    _log.info(
      'Vosk: ${latency ?? "?"}ms xử lý ${audioMs ?? "?"}ms audio'
      '${_droppedTotal > 0 ? ", tổng chunk bỏ=$_droppedTotal" : ""}',
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    // F4 của review P1D: native flush kết quả cuối (câu đang nói dở) trong `releaseModel`, nên phải
    // gọi TRƯỚC khi đóng stream — nếu đóng trước, text cuối bị chặn ở `_applyResult` và người nghe
    // mất đúng câu cuối. `add()` của broadcast controller phát đồng bộ cho listener hiện có, nên
    // thứ tự releaseModel → close là đủ để không mất text.
    if (_initialized) {
      try {
        await _channel.invokeMethod<void>('releaseModel');
      } on PlatformException catch (error) {
        _log.warn('release model lỗi: ${error.message}');
      } on MissingPluginException {
        _log.warn('kênh Vosk chưa có phía native khi dispose');
      }
    }
    await _transcripts.close();
  }
}
