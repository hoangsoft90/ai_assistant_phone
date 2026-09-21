import 'package:audio_session/audio_session.dart';

import '../core/app_logger.dart';

/// Cấu hình audio session mức KHUNG (P0.5 task 5). Phase này chưa thu, chưa phát gì.
///
/// RÀNG BUỘC KIẾN TRÚC — đọc trước khi sửa (`plan_final_v2.md` mục 4.2a):
/// - Tai nghe Bluetooth **chỉ để phát** (A2DP một chiều). TUYỆT ĐỐI không dùng
///   `AndroidAudioUsage.voiceCommunication` / `voiceCommunicationSignalling`: hai usage đó kéo
///   hệ thống sang chế độ đàm thoại (HFP/SCO) và hạ chất lượng audio.
/// - Mic thu là **mic điện thoại**; việc chọn nguồn thu thuộc P1A (AudioRecord), không đi qua
///   package này.
/// - `audio_session` chỉ đặt thuộc tính PHÁT (playback attributes). Cấu hình chốt cuối cùng sẽ
///   được xác nhận ở P1A/P1F sau khi có số liệu đo thật về A2DP/HFP — số liệu đó thuộc P0 và
///   hiện **chưa có** (xem `.plan/P0-result.md`).
abstract final class AppAudioSession {
  static const AppLogger _log = AppLogger('AppAudioSession');

  /// Cấu hình session và trả về instance để các tầng sau dùng tiếp.
  static Future<AudioSession> configure() async {
    final AudioSession session = await AudioSession.instance;

    await session.configure(
      const AudioSessionConfiguration(
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.media,
          flags: AndroidAudioFlags.none,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: true,
      ),
    );

    _log.info(
      'đã cấu hình audio session: content=speech, usage=media '
      '(cố ý KHÔNG dùng voiceCommunication để không kéo sang HFP)',
    );

    // P1F sẽ dùng sự kiện này để xử lý khi tai nghe bị rút/mất kết nối (không được để lọt ra
    // loa ngoài). P0.5 chỉ ghi log để quan sát.
    session.becomingNoisyEventStream.listen((_) {
      _log.warn('becomingNoisy: thiết bị ra thay đổi (tai nghe rút hoặc mất kết nối?)');
    });

    return session;
  }
}
