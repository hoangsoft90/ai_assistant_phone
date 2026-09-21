import 'package:flutter/services.dart';

import 'conversation_state.dart';

/// Tên kênh VAD (phải khớp `CaptureChannelBridge.VAD_CHANNEL` phía Kotlin).
abstract final class VadChannels {
  static const String events = 'com.aiassistant.phone/vad';
}

/// Hợp đồng client VAD — tách interface để state machine test được bằng timeline tổng hợp
/// (không cần thiết bị, không cần mic).
abstract class VadClient {
  /// Kết quả VAD theo từng buffer, có mốc thời gian đơn điệu.
  Stream<VadFrameStat> frames();
}

/// Client thật: nghe EventChannel do native phát.
class NativeVadClient implements VadClient {
  NativeVadClient({EventChannel? channel})
      : _channel = channel ?? const EventChannel(VadChannels.events);

  final EventChannel _channel;

  @override
  Stream<VadFrameStat> frames() => _channel
      .receiveBroadcastStream()
      .map((Object? payload) => VadFrameStat.fromNative(payload));
}
