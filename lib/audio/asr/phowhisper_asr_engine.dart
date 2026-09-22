import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../core/app_logger.dart';
import 'asr_engine.dart';

/// Tên kênh ASR (phải khớp `AsrChannelBridge.ASR_CHANNEL` phía Kotlin).
abstract final class AsrChannels {
  static const String control = 'com.aiassistant.phone/asr';
}

/// Cấu hình engine PhoWhisper.
///
/// - `chunkSeconds = 4`: giữa 3–5s theo prompt — đủ ngữ cảnh cho whisper, độ trễ chấp nhận được.
/// - `threads = 0` ⇒ **tự động**: `min(4, số nhân CPU)`. Trước đây hardcode 2, đo trên máy thật
///   (Pixel 3a, 8 nhân) ngày 2026-09-22 thấy chỉ dùng 2/8 nhân trong khi bản đo host P0 dùng 4
///   thread ⇒ mất tốc độ vô ích. Chặn trần 4 vì whisper.cpp không lên tuyến tính tới 8 trên
///   kiến trúc big.LITTLE (2 nhân lớn + 6 nhân nhỏ).
/// - `maxQueuedChunks = 1`: whisper KHÔNG streaming được; nếu engine bận mà tới chunk mới thì
///   chỉ giữ tối đa 1 chunk chờ, chunk sau nữa bị BỎ (kèm đếm) — thay vì xếp hàng vô hạn làm
///   transcript lệch thời gian thực ngày càng nhiều. Ghi đè (drop chunk cũ) thay vì bỏ chunk mới
///   vì chunk mới nhất luôn chứa audio gần hiện tại nhất.
class PhoWhisperConfig {
  const PhoWhisperConfig({
    this.modelAssetPath = 'assets/models/ggml-phowhisper-tiny-q5_0.bin',
    this.chunkSeconds = 4,
    this.threads = 0,
    this.maxQueuedChunks = 1,
    this.initTimeout = const Duration(seconds: 60),
  });

  /// Model được đóng gói trong APK (P0: tiny q5_0 = 29MB, WER 15.5% trên FLEURS-host).
  final String modelAssetPath;
  final int chunkSeconds;

  /// Số thread gửi xuống native; `0` = tự động (xem ghi chú ở đầu class).
  final int threads;

  final int maxQueuedChunks;

  /// Số thread thật sự dùng: `threads` nếu > 0, ngược lại `min(4, số nhân CPU)`.
  int get resolvedThreads =>
      threads > 0 ? threads : math.min(4, Platform.numberOfProcessors);

  /// Hạn chót cho lời gọi `loadModel` (F3 của review P1D). Rộng rãi — mục đích duy nhất là **cắt
  /// một lần treo vô hạn** khi phía native không bao giờ trả lời: không có timeout thì
  /// `AsrEngineSelector` không bao giờ chạy fallback và UI kẹt ở trạng thái bận mãi mãi.
  final Duration initTimeout;

  static const PhoWhisperConfig defaults = PhoWhisperConfig();
}

/// Engine ASR chính của app: **PhoWhisper** (whisper.cpp) — 100% offline.
///
/// Kiến trúc (khớp nội dung spike P0 đã kiểm, nâng lên mức app thật):
/// ```text
/// feedAudioChunk(bytes PCM16 16kHz)          (Dart, từ stream capture P1A)
///   └─ _accumulator: gom đủ 4s (_ChunkReady) ─► MethodChannel invoke 'feed'
///         └─ Kotlin AsrChannelBridge: PCM16→float, WhisperEngine (single-thread executor,
///              busy → giữ 1 chunk mới nhất, dư bị DROP và đếm) ─► whisper.cpp JNI
///                   └─ invoke 'transcript' {text, latencyMs, audioMs, dropped}
///                         └─ transcriptStream (broadcast)
/// ```
/// Model load 1 lần trong `init()`: Dart copy asset ra file thật (JNI đọc theo đường dẫn),
/// rồi gọi `loadModel`. Toàn bộ inference nằm ở native thread — không block UI.
///
/// Ràng buộc: KHÔNG cloud, KHÔNG nhãn người nói (xem `AsrEngine`).
class PhoWhisperAsrEngine implements AsrEngine {
  PhoWhisperAsrEngine({this.config = PhoWhisperConfig.defaults, MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(AsrChannels.control);

  static const AppLogger _log = AppLogger('PhoWhisper');

  final PhoWhisperConfig config;
  final MethodChannel _channel;

  final StreamController<String> _transcripts =
      StreamController<String>.broadcast();
  final BytesBuilder _accumulator = BytesBuilder(copy: true);

  int _droppedTotal = 0;
  bool _initialized = false;
  bool _disposed = false;

  @override
  Stream<String> get transcriptStream => _transcripts.stream;

  /// Số chunk bị bỏ kể từ khi bắt đầu (để đo "bỏ sót transcript" ở DoD P1C).
  @override
  int get droppedTotal => _droppedTotal;

  /// Số byte PCM đang gom trong accumulator (chưa đủ 1 chunk) — để UI/debug.
  int get pendingBytes => _accumulator.length;

  @override
  Future<void> init() async {
    if (_initialized) {
      return;
    }
    // JNI đọc model theo đường dẫn file, không đọc được asset trực tiếp → copy ra Documents.
    final ByteData asset =
        await rootBundle.load(config.modelAssetPath); // Ném nếu thiếu asset.
    final Directory dir = await getApplicationSupportDirectorySafe();
    final File modelFile = File('${dir.path}/${_assetFileName()}');
    if (!modelFile.existsSync() ||
        modelFile.lengthSync() != asset.lengthInBytes) {
      await modelFile
          .writeAsBytes(asset.buffer.asUint8List(), flush: true);
      _log.info(
          'đã copy model ra file: ${modelFile.path} (${asset.lengthInBytes ~/ 1048576}MB)');
    }
    await _channel
        .invokeMethod<void>('loadModel', <String, Object?>{
          'path': modelFile.path,
          'threads': config.resolvedThreads,
        })
        .timeout(
          config.initTimeout,
          onTimeout: () => throw StateError(
            'PhoWhisper: loadModel không phản hồi sau ${config.initTimeout.inSeconds}s',
          ),
        );
    _channel.setMethodCallHandler(_onNativeCall);
    _initialized = true;
    _log.info('PhoWhisper sẵn sàng (${config.modelAssetPath}, '
        'chunk=${config.chunkSeconds}s, threads=${config.resolvedThreads}/'
        '${Platform.numberOfProcessors} nhân)');
  }

  @override
  Future<void> feedAudioChunk(Uint8List chunk) async {
    if (_disposed) {
      return;
    }
    if (!_initialized) {
      throw StateError('PhoWhisperAsrEngine.init() phải được gọi trước feedAudioChunk()');
    }
    _accumulator.add(chunk);
    const int bytesPerSecond = 16000 * 2; // PCM16 mono 16kHz.
    final int targetBytes = config.chunkSeconds * bytesPerSecond;
    while (_accumulator.length >= targetBytes) {
      final Uint8List all = _accumulator.takeBytes();
      final Uint8List chunkToSend = Uint8List.sublistView(all, 0, targetBytes);
      // Phần dư (nếu có) gộp lại cho chunk kế tiếp — không mất mẫu.
      if (all.length > targetBytes) {
        _accumulator.add(Uint8List.sublistView(all, targetBytes));
      }
      await _dispatch(chunkToSend);
    }
  }

  Future<void> _dispatch(Uint8List pcm16) async {
    try {
      final Object? result = await _channel.invokeMethod<Object?>(
        'feed',
        <String, Object?>{
          'pcm16': pcm16,
          'maxQueue': config.maxQueuedChunks,
        },
      );
      _applyResult(result);
    } on PlatformException catch (error) {
      // Lỗi trả về từ native (engine chưa load, JNI fail...) — log, không crash app.
      _log.error('kênh ASR lỗi: ${error.code} ${error.message}');
    } on MissingPluginException {
      // Trong test hoặc khi native chưa đăng ký — bỏ qua im lặng (test có stub riêng).
      _log.warn('kênh ASR chưa có phía native (MissingPluginException)');
    }
  }

  /// Native chủ động gọi về khi inference xong: method `transcript`.
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
  /// Không dùng trong code sản phẩm.
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
      'ASR: ${latency ?? "?"}ms xử lý ${audioMs ?? "?"}ms audio'
      '${_droppedTotal > 0 ? ", tổng chunk bỏ=$_droppedTotal" : ""}',
    );
  }

  String _assetFileName() => config.modelAssetPath.split('/').last;

/// `getApplicationSupportDirectory` không dùng `path_provider` (tránh thêm dependency mới) —
/// Kotlin mới là nơi quyết định thư mục thật (`context.filesDir`) khi nhận lời gọi `loadModel`;
/// Dart chỉ gửi tên file model. Hàm này chỉ phục vụ test: tạo thư mục tạm để ghi đường dẫn giả
/// mà không chạm platform channel.
static Future<Directory> getApplicationSupportDirectorySafe() async {
  final Directory dir = await Directory.systemTemp
      .resolveSymbolicLinks()
      .then((String path) => Directory('$path/phowhisper'));
  await dir.create(recursive: true);
  return dir;
}

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _transcripts.close();
    if (_initialized) {
      try {
        await _channel.invokeMethod<void>('releaseModel');
      } on PlatformException catch (error) {
        _log.warn('release model lỗi: ${error.message}');
      }
    }
    _accumulator.clear();
  }
}
