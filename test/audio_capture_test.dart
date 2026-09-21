// Unit test cho tầng audio capture (P1A) — thuần Dart, KHÔNG cần thiết bị.
//
// Phần cần máy thật (chất lượng audio, route A2DP/SCO, chạy 60 phút) KHÔNG thể test ở đây —
// xem DoD của `.plan/prompt_P1A.md` và phần "còn nợ" trong `.plan/P1A-result.md`.

import 'dart:async';

import 'package:ai_assistant_phone/audio/capture/audio_capture_controller.dart';
import 'package:ai_assistant_phone/audio/capture/capture_channels.dart';
import 'package:ai_assistant_phone/audio/capture/capture_client.dart';
import 'package:ai_assistant_phone/audio/capture/capture_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake client: không có kênh native, cho phép điều khiển mọi nhánh thành công/thất bại.
class _FakeCaptureClient implements CaptureClient {
  final StreamController<Uint8List> _pcm = StreamController<Uint8List>.broadcast();
  void Function(CaptureError error)? _onError;

  CaptureConfig returnedConfig = const CaptureConfig();
  Object? startFailure;
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  void emitChunk(int length) => _pcm.add(Uint8List(length));
  void emitRuntimeError(CaptureError error) => _onError?.call(error);

  @override
  Future<CaptureConfig> startNative(CaptureConfig config) async {
    startCalls++;
    final Object? failure = startFailure;
    if (failure != null) {
      throw failure;
    }
    return returnedConfig;
  }

  @override
  Future<void> stopNative() async => stopCalls++;

  @override
  Future<void> disposeNative() async => disposeCalls++;

  @override
  void onError(void Function(CaptureError error) handler) => _onError = handler;

  @override
  Stream<Uint8List> pcmChunks() => _pcm.stream;

  Future<void> close() => _pcm.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CaptureConfig', () {
    test('giá trị mặc định đúng chuẩn ASR (16kHz mono PCM16)', () {
      const CaptureConfig config = CaptureConfig();
      expect(config.sampleRate, 16000);
      expect(config.numChannels, 1);
      expect(config.bitsPerSample, 16);
      expect(config.bytesPerSample, 2);
    });

    test('chunkBytes tính đúng cho các cấu hình dùng thật', () {
      // 16000 mẫu/s * 0.1s = 1600 mẫu * 2 byte/mẫu = 3200 byte
      expect(const CaptureConfig(chunkMs: 100).chunkBytes, 3200);
      // 20ms -> 320 mẫu -> 640 byte
      expect(const CaptureConfig(chunkMs: 20).chunkBytes, 640);
      // 25ms -> 400 mẫu -> 800 byte
      expect(const CaptureConfig(chunkMs: 25).chunkBytes, 800);
    });

    test('chunkBytes không đổi khi thêm kênh (mono là ràng buộc hợp lệ duy nhất)', () {
      expect(const CaptureConfig(numChannels: 2).chunkBytes, 6400);
    });
  });

  group('mapPlatformCode', () {
    test('map đúng code native sang kiểu CaptureError', () {
      expect(mapPlatformCode('PERMISSION_DENIED', 'x'), isA<CapturePermissionDenied>());
      expect(mapPlatformCode('UNAVAILABLE', 'x'), isA<CaptureUnavailable>());
      expect(mapPlatformCode('CAPTURE_FAILED', 'x'), isA<CaptureFailed>());
      expect(mapPlatformCode('LA_GI_DO', null), isA<CaptureFailed>());
    });

    test('dùng message mặc định có hướng dẫn khi native không gửi message', () {
      final CaptureError error = mapPlatformCode('PERMISSION_DENIED', null);
      expect(error.message.toLowerCase(), contains('cài đặt'));
    });
  });

  group('AudioCaptureController — lifecycle', () {
    late _FakeCaptureClient client;
    late AudioCaptureController controller;

    setUp(() {
      client = _FakeCaptureClient();
      controller = AudioCaptureController(client: client);
    });

    tearDown(() async {
      await controller.dispose();
      await client.close();
    });

    test('start() chuyển trạng thái starting → capturing và dùng cấu hình native trả về', () async {
      client.returnedConfig = const CaptureConfig(sampleRate: 44100, chunkMs: 20);
      final List<CaptureStatus> seen = <CaptureStatus>[];
      controller.status.listen(seen.add);

      final CaptureConfig actual = await controller.start();
      await Future<void>.delayed(Duration.zero);

      expect(actual.sampleRate, 44100);
      expect(controller.currentStatus, CaptureStatus.capturing);
      expect(controller.activeConfig.chunkMs, 20);
      expect(seen, <CaptureStatus>[CaptureStatus.starting, CaptureStatus.capturing]);
      expect(client.startCalls, 1);
    });

    test('start() khi đang capturing là no-op (không mở mic lần hai)', () async {
      await controller.start();
      await controller.start();
      expect(client.startCalls, 1);
    });

    test('chunk từ native được phát ra stream và cộng vào capturedBytes', () async {
      final List<int> sizes = <int>[];
      controller.chunks.listen((Uint8List chunk) => sizes.add(chunk.length));
      await controller.start();

      client.emitChunk(3200);
      client.emitChunk(3200);
      await Future<void>.delayed(Duration.zero);

      expect(sizes, <int>[3200, 3200]);
      expect(controller.capturedBytes, 6400);
    });

    test('chunk tới TRƯỚC khi start bị bỏ (không phát ra stream)', () async {
      final List<int> sizes = <int>[];
      controller.chunks.listen((Uint8List chunk) => sizes.add(chunk.length));

      client.emitChunk(100);
      await Future<void>.delayed(Duration.zero);
      expect(sizes, isEmpty);
      expect(controller.capturedBytes, 0);
    });

    test('stop() chuyển sang stopped và bỏ chunk tới sau khi dừng', () async {
      final List<int> sizes = <int>[];
      controller.chunks.listen((Uint8List chunk) => sizes.add(chunk.length));
      await controller.start();
      await controller.stop();

      client.emitChunk(200);
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentStatus, CaptureStatus.stopped);
      expect(client.stopCalls, 1);
      expect(sizes, isEmpty);
    });

    test('stop() khi chưa chạy là no-op', () async {
      await controller.stop();
      expect(client.stopCalls, 0);
      expect(controller.currentStatus, CaptureStatus.idle);
    });

    test('start() lại sau stop() vẫn hoạt động (engine tái sử dụng được)', () async {
      await controller.start();
      await controller.stop();
      await controller.start();
      expect(client.startCalls, 2);
      expect(controller.currentStatus, CaptureStatus.capturing);
    });
  });

  group('AudioCaptureController — lỗi', () {
    late _FakeCaptureClient client;
    late AudioCaptureController controller;

    setUp(() {
      client = _FakeCaptureClient();
      controller = AudioCaptureController(client: client);
    });

    tearDown(() async {
      await controller.dispose();
      await client.close();
    });

    test('start() map PlatformException PERMISSION_DENIED thành CapturePermissionDenied', () async {
      client.startFailure = PlatformException(code: 'PERMISSION_DENIED', message: 'bị từ chối');

      await expectLater(controller.start(), throwsA(isA<CapturePermissionDenied>()));
      expect(controller.currentStatus, CaptureStatus.error);
    });

    test('start() map PlatformException lạ thành CaptureFailed', () async {
      client.startFailure = PlatformException(code: 'WEIRD', message: 'lạ');

      await expectLater(controller.start(), throwsA(isA<CaptureFailed>()));
    });

    test('lỗi runtime từ native báo qua onError, stream errors, và đổi trạng thái', () async {
      final List<CaptureError> handlerErrors = <CaptureError>[];
      final List<CaptureError> streamErrors = <CaptureError>[];
      controller.onError(handlerErrors.add);
      controller.errors.listen(streamErrors.add);
      await controller.start();

      client.emitRuntimeError(const CaptureFailed('read lỗi -3'));
      await Future<void>.delayed(Duration.zero);

      expect(handlerErrors.single, isA<CaptureFailed>());
      expect(handlerErrors.single.message, 'read lỗi -3');
      expect(streamErrors.single.message, 'read lỗi -3');
      expect(controller.currentStatus, CaptureStatus.error);
    });

    test('onError chỉ giữ một handler — đăng ký lần sau ghi đè (theo hợp đồng)', () async {
      final List<CaptureError> first = <CaptureError>[];
      final List<CaptureError> second = <CaptureError>[];
      controller.onError(first.add);
      controller.onError(second.add);
      await controller.start();

      client.emitRuntimeError(const CaptureFailed('x'));
      await Future<void>.delayed(Duration.zero);

      expect(first, isEmpty);
      expect(second, hasLength(1));
    });
  });

  group('AudioCaptureController — dispose', () {
    test('dispose() đóng stream và chặn dùng lại', () async {
      final _FakeCaptureClient client = _FakeCaptureClient();
      final AudioCaptureController controller = AudioCaptureController(client: client);

      await controller.start();
      await controller.dispose();

      expect(client.disposeCalls, 1);
      expect(controller.currentStatus, CaptureStatus.idle);
      await expectLater(controller.start(), throwsA(isA<StateError>()));
      await controller.dispose(); // gọi lại phải an toàn (no-op)
      await client.close();
    });
  });

  group('NativeCaptureClient — hợp đồng kênh', () {
    const MethodChannel control = MethodChannel(CaptureChannels.control);
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;
    late MethodCall? Function() responder;

    setUp(() {
      calls = <MethodCall>[];
      responder = () => null;
      messenger.setMockMethodCallHandler(control, (MethodCall call) async {
        calls.add(call);
        return responder()?.arguments;
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(control, null));

    test('startNative gửi đúng tham số và parse cấu hình native trả về', () async {
      responder = () => const MethodCall('start', <String, Object?>{
            'sampleRate': 16000,
            'numChannels': 1,
            'bitsPerSample': 16,
            'chunkMs': 100,
          });

      final CaptureConfig actual =
          await NativeCaptureClient().startNative(const CaptureConfig());

      expect(calls.single.method, 'start');
      expect(calls.single.arguments, <String, Object?>{
        'sampleRate': 16000,
        'numChannels': 1,
        'bitsPerSample': 16,
        'chunkMs': 100,
      });
      expect(actual.chunkBytes, 3200);
    });

    test('startNative ném FormatException khi native trả về sai format', () async {
      responder = () => const MethodCall('start', 'không phải map');
      await expectLater(
        NativeCaptureClient().startNative(const CaptureConfig()),
        throwsA(isA<FormatException>()),
      );
    });

    test('stopNative/disposeNative gửi đúng method', () async {
      final NativeCaptureClient client = NativeCaptureClient();
      await client.stopNative();
      await client.disposeNative();
      expect(calls.map((MethodCall c) => c.method), <String>['stop', 'dispose']);
    });
  });
}
