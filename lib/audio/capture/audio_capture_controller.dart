import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;

import '../../core/app_logger.dart';
import 'capture_channels.dart';
import 'capture_client.dart';
import 'capture_config.dart';
import 'capture_engine.dart';

/// Singleton dùng chung cho UI và (sau này) foreground service.
///
/// Cố ý lazy: chỉ tạo khi có ai thực sự dùng, nên test widget không đụng tới kênh native
/// trừ khi chúng thực sự bấm nút.
abstract final class AudioCapture {
  static final AudioCaptureController instance = AudioCaptureController();
}

/// Facade duy nhất của tầng capture (P1A) — bọc [CaptureClient] sau hợp đồng
/// [AudioCaptureEngine] và biến callback đơn của native thành **broadcast stream**.
///
/// Nhiều subscriber cùng nghe `chunks` được: UI hiện trạng thái, P1B (VAD) và P1C/P1D (ASR) sẽ
/// cùng subscribe. Ràng buộc P1A: KHÔNG VAD/ASR/xử lý audio, KHÔNG ghi file mặc định,
/// KHÔNG đụng TTS/tai nghe.
class AudioCaptureController implements AudioCaptureEngine {
  AudioCaptureController({CaptureClient? client, CaptureConfig? config})
      : _client = client ?? NativeCaptureClient(),
        _config = config ?? const CaptureConfig() {
    _subscribeToNative();
  }

  static const AppLogger _log = AppLogger('AudioCapture');

  final CaptureClient _client;
  final CaptureConfig _config;

  CaptureStatus _status = CaptureStatus.idle;
  int _capturedBytes = 0;
  bool _disposed = false;
  CaptureConfig _activeConfig = const CaptureConfig();
  void Function(CaptureError error)? _errorHandler;
  StreamSubscription<Uint8List>? _pcmSubscription;

  final StreamController<Uint8List> _chunks =
      StreamController<Uint8List>.broadcast();
  final StreamController<CaptureStatus> _statusChanges =
      StreamController<CaptureStatus>.broadcast();
  final StreamController<CaptureError> _errors =
      StreamController<CaptureError>.broadcast();

  @override
  Stream<Uint8List> get chunks => _chunks.stream;

  @override
  Stream<CaptureStatus> get status => _statusChanges.stream;

  /// Tiện ích thêm (ngoài hợp đồng engine): stream lỗi để UI hiện thông báo.
  Stream<CaptureError> get errors => _errors.stream;

  @override
  int get capturedBytes => _capturedBytes;

  /// Trạng thái hiện tại — đọc đồng bộ cho UI (nguồn sự thật vẫn là [status] stream).
  CaptureStatus get currentStatus => _status;

  /// Cấu hình thực tế đang được native dùng (sau khi `start()` thành công).
  CaptureConfig get activeConfig => _activeConfig;

  @override
  void onError(void Function(CaptureError error) handler) {
    _errorHandler = handler; // Chỉ giữ MỘT handler (hợp đồng engine).
  }

  void _subscribeToNative() {
    try {
      _pcmSubscription = _client.pcmChunks().listen(
        _ingestChunk,
        onError: (Object error, StackTrace stackTrace) {
          _log.error('stream pcm lỗi', error, stackTrace);
          _pushError(CaptureFailed('kênh PCM lỗi: $error'));
        },
      );
      _client.onError((CaptureError error) {
        _log.warn('capture lỗi giữa lúc ghi: $error');
        // Native đã tự dừng sạch trước khi báo — chỉ cần phản ánh trạng thái.
        _status = CaptureStatus.error;
        _pushError(error);
      });
    } catch (error, stackTrace) {
      // Không được để việc đăng ký kênh làm chết app: ghi log rồi để UI báo khi bấm nút.
      _log.error('không đăng ký được kênh native', error, stackTrace);
    }
  }

  void _pushError(CaptureError error) {
    _status = CaptureStatus.error;
    if (!_statusChanges.isClosed) {
      _statusChanges.add(CaptureStatus.error);
    }
    if (!_errors.isClosed) {
      _errors.add(error);
    }
    _errorHandler?.call(error);
  }

  void _setStatus(CaptureStatus value) {
    if (_status == value) {
      return;
    }
    _status = value;
    if (!_statusChanges.isClosed) {
      _statusChanges.add(value);
    }
  }

  void _ingestChunk(Uint8List chunk) {
    // Chunk tới sau khi stop/dispose hoặc khi chưa capturing: bỏ, không phát ra stream.
    if (_disposed || _status != CaptureStatus.capturing) {
      return;
    }
    _capturedBytes += chunk.lengthInBytes;
    if (!_chunks.isClosed) {
      _chunks.add(chunk);
    }
  }

  @override
  Future<CaptureConfig> start() async {
    if (_disposed) {
      throw StateError('AudioCaptureController đã dispose — không dùng lại được');
    }
    if (_status == CaptureStatus.capturing) {
      return _activeConfig; // no-op an toàn (hợp đồng engine).
    }
    _setStatus(CaptureStatus.starting);
    try {
      _activeConfig = await _client.startNative(_config);
      _capturedBytes = 0;
      _setStatus(CaptureStatus.capturing);
      _log.info('capture start OK: $_activeConfig');
      return _activeConfig;
    } on PlatformException catch (error) {
      final CaptureError mapped = mapPlatformCode(error.code, error.message);
      _setStatus(CaptureStatus.error);
      _log.error('capture start thất bại ($mapped)');
      throw mapped;
    } on CaptureError {
      _setStatus(CaptureStatus.error);
      rethrow; // Đã là lỗi đúng kiểu: không bọc lại lần nữa.
    } catch (error, stackTrace) {
      _setStatus(CaptureStatus.error);
      _log.error('capture start lỗi không phân loại', error, stackTrace);
      throw CaptureUnavailable('lỗi không xác định khi mở micro: $error');
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed || _status == CaptureStatus.idle) {
      return; // no-op an toàn (hợp đồng engine).
    }
    try {
      await _client.stopNative();
    } catch (error, stackTrace) {
      _log.error('stop capture lỗi (vẫn coi là đã dừng)', error, stackTrace);
    }
    _setStatus(CaptureStatus.stopped);
    _log.info('capture stop (đã thu $_capturedBytes byte)');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      await _client.disposeNative();
    } catch (error, stackTrace) {
      _log.error('dispose capture lỗi', error, stackTrace);
    }
    await _pcmSubscription?.cancel();
    _pcmSubscription = null;
    _status = CaptureStatus.idle;
    await _chunks.close();
    await _statusChanges.close();
    await _errors.close();
  }
}

/// Map `code` lỗi của native sang [CaptureError] — dùng chung cho `start()` và lỗi runtime,
/// để hai đường không lệch nhau.
CaptureError mapPlatformCode(String code, String? message) {
  return switch (code) {
    'PERMISSION_DENIED' => CapturePermissionDenied(
        message ?? 'Thiếu quyền ghi âm (micro). Hãy cấp quyền trong Cài đặt > Ứng dụng.',
      ),
    'UNAVAILABLE' => CaptureUnavailable(
        message ?? 'Không mở được micro — thiết bị đang bị ứng dụng khác chiếm hoặc không hỗ trợ.',
      ),
    _ => CaptureFailed(message ?? 'Lỗi micro không phân loại ($code)'),
  };
}
