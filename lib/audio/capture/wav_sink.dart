import 'dart:io';
import 'dart:typed_data';

import '../../core/app_logger.dart';

/// Ghi PCM16 mono ra file `.wav` để **kiểm tra chất lượng thu âm bằng tai** (DoD P1A).
///
/// ⚠ Đây là tiện ích **kiểm thử thủ công**, KHÔNG phải tính năng: theo ràng buộc của dự án,
/// app **không** ghi audio ra đĩa mặc định (bảo mật + nhẹ máy). Chỉ dùng khi chủ động bật để
/// nghe lại, và **xoá file sau khi xác nhận** — không được nối vào luồng sản phẩm.
///
/// Cách dùng (trên máy thật, tạm thời):
/// ```dart
/// final sink = WavSink(path: '/data/data/<pkg>/files/capture_check.wav',
///                      sampleRate: 16000, numChannels: 1);
/// await sink.start(AudioCapture.instance.chunks);   // thu ~10-30s
/// await sink.stop();                                // đóng file, nghe lại
/// ```
class WavSink {
  WavSink({
    required this.path,
    required this.sampleRate,
    required this.numChannels,
    this.bitsPerSample = 16,
  });

  static const AppLogger _log = AppLogger('WavSink');

  final String path;
  final int sampleRate;
  final int numChannels;
  final int bitsPerSample;

  final List<int> _pcm = <int>[];
  bool _active = false;

  /// Số byte PCM đã gom.
  int get byteLength => _pcm.length;

  /// Bắt đầu gom dữ liệu từ [source]. Không ghi gì ra đĩa cho tới khi [stop].
  void start(Stream<Uint8List> source) {
    if (_active) {
      return;
    }
    _active = true;
    _pcm.clear();
    source.listen(
      (Uint8List chunk) {
        if (_active) {
          _pcm.addAll(chunk);
        }
      },
      onError: (Object error) => _log.error('nguồn chunk lỗi khi ghi wav', error),
    );
    _log.info('bắt đầu gom PCM để kiểm tra (đích: $path)');
  }

  /// Đóng gom và ghi file WAV hoàn chỉnh. Trả về độ dài dữ liệu đã ghi.
  Future<int> stop() async {
    _active = false;
    final int dataLength = _pcm.length;
    final BytesBuilder builder = BytesBuilder();
    builder.add(_header(dataLength));
    builder.add(_pcm);
    await File(path).writeAsBytes(builder.takeBytes(), flush: true);
    _log.info('đã ghi $dataLength byte PCM (~${_seconds(dataLength)}s) vào $path');
    return dataLength;
  }

  double _seconds(int byteLength) =>
      byteLength / (sampleRate * numChannels * (bitsPerSample ~/ 8));

  /// Header WAV 44 byte chuẩn (RIFF/WAVE/fmt /data), PCM16 little-endian.
  Uint8List _header(int dataLength) {
    final int byteRate = sampleRate * numChannels * (bitsPerSample ~/ 8);
    final int blockAlign = numChannels * (bitsPerSample ~/ 8);
    final ByteData header = ByteData(44);
    void ascii(int offset, String value) {
      for (int i = 0; i < value.length; i++) {
        header.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + dataLength, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little); // kích thước khối fmt
    header.setUint16(20, 1, Endian.little); // PCM = 1
    header.setUint16(22, numChannels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, dataLength, Endian.little);
    return header.buffer.asUint8List();
  }
}
