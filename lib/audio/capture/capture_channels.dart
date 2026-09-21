import 'dart:async';

import 'package:flutter/services.dart';

import 'capture_client.dart';
import 'capture_config.dart';

/// Tên kênh native của audio capture (Kotlin ↔ Dart).
///
/// Phải trùng với hằng trong `android/.../audio/CaptureChannelBridge.kt`. Test stub đúng tên
/// 2 kênh này (xem `test/app_smoke_test.dart`).
abstract final class CaptureChannels {
  /// MethodChannel: `start` / `stop` / `dispose` (Dart → native) và `error` (native → Dart).
  static const String control = 'com.aiassistant.phone/audio_capture';

  /// EventChannel: chunk PCM16 mono (native → Dart).
  static const String pcm = 'com.aiassistant.phone/audio_capture_pcm';
}

/// Client thật: gọi native (AudioRecord) qua MethodChannel/EventChannel.
class NativeCaptureClient implements CaptureClient {
  NativeCaptureClient({MethodChannel? control, EventChannel? pcm})
      : _control = control ?? const MethodChannel(CaptureChannels.control),
        _pcm = pcm ?? const EventChannel(CaptureChannels.pcm);

  final MethodChannel _control;
  final EventChannel _pcm;

  @override
  Future<CaptureConfig> startNative(CaptureConfig config) async {
    final Object? result = await _control.invokeMethod('start', <String, Object?>{
      'sampleRate': config.sampleRate,
      'numChannels': config.numChannels,
      'bitsPerSample': config.bitsPerSample,
      'chunkMs': config.chunkMs,
    });
    return _configFromNative(result);
  }

  @override
  Future<void> stopNative() => _control.invokeMethod('stop');

  @override
  Future<void> disposeNative() => _control.invokeMethod('dispose');

  @override
  void onError(void Function(CaptureError error) handler) {
    _control.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'error') {
        handler(_errorFromNative(call.arguments));
      }
      return null;
    });
  }

  @override
  Stream<Uint8List> pcmChunks() => _pcm
      .receiveBroadcastStream()
      .map((Object? event) => event! as Uint8List);

  /// Đọc map cấu hình native trả về. Lỗi format là lỗi lập trình (hợp đồng sai), không phải
  /// lỗi thiết bị — ném `FormatException` để lộ ra ngay trong test.
  CaptureConfig _configFromNative(Object? result) {
    if (result is! Map) {
      throw FormatException('native start trả về không phải Map: $result');
    }
    int read(String key) {
      final Object? value = result[key];
      if (value is! num) {
        throw FormatException('native start thiếu/ sai kiểu khoá "$key": $result');
      }
      return value.toInt();
    }

    return CaptureConfig(
      sampleRate: read('sampleRate'),
      numChannels: read('numChannels'),
      bitsPerSample: read('bitsPerSample'),
      chunkMs: read('chunkMs'),
    );
  }

  /// Map lỗi native sang kiểu Dart tương ứng (theo `code`).
  CaptureError _errorFromNative(Object? arguments) {
    if (arguments is! Map) {
      return CaptureFailed('native gửi lỗi sai format: $arguments');
    }
    final String code = arguments['code']?.toString() ?? 'UNKNOWN';
    final String message = arguments['message']?.toString() ?? 'không có mô tả';
    return switch (code) {
      'PERMISSION_DENIED' => CapturePermissionDenied(message),
      'UNAVAILABLE' => CaptureUnavailable(message),
      _ => CaptureFailed(message),
    };
  }
}
