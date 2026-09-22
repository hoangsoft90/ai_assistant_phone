import 'package:flutter/services.dart';

import 'tts_client.dart';

/// Tên kênh native của tầng TTS (Kotlin ↔ Dart).
///
/// Phải trùng hằng `SafeTtsChannelBridge.TTS_CHANNEL` trong
/// `android/.../tts/SafeTtsBridge.kt`. Test widget stub đúng tên này (xem `test/app_smoke_test.dart`).
abstract final class TtsChannels {
  /// MethodChannel: `outputState` / `speak` / `stop` / `vibrateFallback` / `release` (Dart → native)
  /// và `event` (native → Dart).
  static const String control = 'com.aiassistant.phone/tts';
}

/// Client thật: gọi native (TextToSpeech + AudioTrack) qua MethodChannel.
class NativeTtsClient implements TtsClient {
  NativeTtsClient({MethodChannel? control})
      : _control = control ?? const MethodChannel(TtsChannels.control);

  final MethodChannel _control;

  @override
  Future<TtsOutputInfo> outputState() async =>
      infoFromNative(await _control.invokeMethod<Object?>('outputState'));

  @override
  Future<TtsNativeSpeakResult> speak(String text, {double? rate}) async =>
      speakResultFromNative(await _control.invokeMethod<Object?>('speak', <String, Object?>{
        'text': text,
        // Chỉ gửi `rate` khi có (`?rate` = bỏ hẳn khoá nếu null): không gửi khoá này thì native không
        // đụng tới tốc độ — giữ y nguyên hợp đồng kênh của P1F cho caller không quan tâm tốc độ.
        'rate': ?rate,
      }));

  @override
  Future<bool> stop() async => await _control.invokeMethod<bool>('stop') ?? false;

  @override
  Future<void> vibrateFallback() => _control.invokeMethod<void>('vibrateFallback');

  @override
  void onEvent(void Function(TtsEvent event)? handler) {
    if (handler == null) {
      _control.setMethodCallHandler(null);
      return;
    }
    _control.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'event') {
        handler(eventFromNative(call.arguments));
      }
      return null;
    });
  }
}

/// Đọc trạng thái thiết bị native trả về. Ném `FormatException` nếu sai dạng — đây là lỗi hợp đồng
/// (phải lộ ra trong test), còn lúc chạy thì [SafeTtsOutput] bắt lỗi và coi như **không có tai nghe**.
TtsOutputInfo infoFromNative(Object? result) {
  if (result is! Map) {
    throw FormatException('native outputState trả về không phải Map: $result');
  }
  final Object? preferred = result['preferred'];
  final Object? devices = result['devices'];
  return TtsOutputInfo(
    hasPrivateOutput: result['hasPrivateOutput'] == true,
    preferred: preferred is Map ? deviceFromNative(preferred) : null,
    devices: devices is List
        ? devices.whereType<Map<Object?, Object?>>().map(deviceFromNative).toList(growable: false)
        : const <TtsDevice>[],
  );
}

TtsDevice deviceFromNative(Map<Object?, Object?> raw) => TtsDevice(
      type: (raw['type'] as num?)?.toInt() ?? -1,
      name: raw['name']?.toString(),
    );

/// Đọc kết quả `speak` của native. Giá trị lạ (kể cả `null` khi thiếu native) ⇒ [TtsNativeSpeakStatus.error]
/// để phía trên **không phát gì** (fail-safe), không đoán.
TtsNativeSpeakResult speakResultFromNative(Object? result) {
  if (result is! String) {
    return TtsNativeSpeakResult(TtsNativeSpeakStatus.error, 'phản hồi không hợp lệ: $result');
  }
  return switch (result) {
    'synthesizing' => const TtsNativeSpeakResult(TtsNativeSpeakStatus.synthesizing),
    'noHeadset' => const TtsNativeSpeakResult(TtsNativeSpeakStatus.noHeadset),
    _ => TtsNativeSpeakResult(TtsNativeSpeakStatus.error, result),
  };
}

/// Đọc sự kiện native bắn lên.
///
/// Sự kiện sai dạng được coi là **`headsetLost`** (hướng an toàn: nghi ngờ thì im lặng), KHÔNG bỏ
/// qua — bỏ qua một sự kiện mất tai nghe đúng là lỗi mà P1F tồn tại để chặn.
TtsEvent eventFromNative(Object? arguments) {
  if (arguments is! Map) {
    return const TtsEvent(
      type: TtsEventType.headsetLost,
      message: 'sự kiện native sai dạng',
    );
  }
  final Object? state = arguments['state'];
  return TtsEvent(
    type: switch (arguments['type']?.toString()) {
      'headsetFound' => TtsEventType.headsetFound,
      'headsetLost' => TtsEventType.headsetLost,
      'spoke' => TtsEventType.spoke,
      'error' => TtsEventType.error,
      _ => TtsEventType.headsetLost,
    },
    wasPlaying: arguments['wasPlaying'] == true,
    message: arguments['message']?.toString(),
    state: state is Map ? infoFromNative(state) : null,
  );
}
