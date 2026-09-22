import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/app_logger.dart';
import 'tts_channels.dart';
import 'tts_client.dart';

/// Trạng thái an toàn của đường phát TTS.
enum TtsOutputState {
  /// Chưa hỏi native lần nào (mới dựng đối tượng).
  unknown,

  /// Có tai nghe đang kết nối và route đã được xác nhận ⇒ được phép phát.
  ready,

  /// CHẾ ĐỘ IM LẶNG: không có tai nghe, hoặc vừa mất tai nghe, hoặc vừa kết nối lại nhưng chưa
  /// được người dùng xác nhận. Ở trạng thái này [SafeTtsOutput.speak] **không** gọi native.
  silent,
}

/// Kết quả một lần gọi [SafeTtsOutput.speak].
enum TtsSpeakResult {
  /// Native đã bắt đầu tổng hợp (phát xong sẽ báo qua `spoke`).
  started,

  /// Không phát vì không có tai nghe — đã rung báo + nudge chữ.
  skippedNoHeadset,

  /// Không phát vì tai nghe vừa kết nối lại và người dùng chưa xác nhận route.
  skippedNeedsConfirmation,

  /// Không phát vì lỗi. **Cố ý không có nhánh thử lại** — lỗi ⇒ im lặng (xem `operating_rules.md` 10).
  failed,
}

/// Loại thông báo fallback để UI hiện dạng chữ (prompt P1F task 1: "nudge dạng chữ trên UI").
enum TtsFallbackKind { noHeadset, needsConfirmation, headsetLost, error }

class TtsFallbackNotice {
  const TtsFallbackNotice(this.kind, this.message);

  final TtsFallbackKind kind;
  final String message;

  @override
  String toString() => 'TtsFallbackNotice(${kind.name}, $message)';
}

/// **Cổng DUY NHẤT của toàn app được phép phát âm thanh** (P1F).
///
/// Vì sao tồn tại: nếu gợi ý (nudge) lọt ra loa ngoài, người đối diện nghe được toàn bộ nội dung
/// app đang gợi ý cho người dùng — phá hỏng mục đích app và gây hại ngay tại chỗ. Vì vậy module này
/// được viết theo tinh thần **fail-safe**: mọi nhánh không chắc chắn đều dẫn tới **không phát gì**,
/// khác hẳn các module khác của app (ở đó lỗi thì log rồi chạy tiếp — `operating_rules.md` rule 10).
///
/// Trách nhiệm của lớp này (kết hợp với `SafeTtsBridge.kt` phía native):
/// 1. Trước **mỗi** lần phát: đọc **tươi** trạng thái tai nghe (không dùng cache).
/// 2. Không có tai nghe ⇒ không gọi phát; rung 1 nhịp + phát nudge chữ qua [fallbacks].
/// 3. Có tai nghe ⇒ native route **tường minh** (`AudioTrack.setPreferredDevice`) tới chính thiết bị đó.
/// 4. Mất tai nghe **giữa chừng** (kể cả đang phát) ⇒ native dừng ngay + rung 2 nhịp; lớp này
///    chuyển vĩnh viễn sang chế độ im lặng cho tới khi có xác nhận của người dùng.
/// 5. Tai nghe **kết nối lại** ⇒ KHÔNG tự phát lại; chờ [confirmHeadsetReady] (P3 sẽ gắn vào
///    floating button; ở P1F có nút tạm trên màn hình chẩn đoán).
///
/// Ràng buộc kiến trúc: từ P1F, **mọi** lời gọi phát âm thanh phải đi qua lớp này — không nơi nào
/// khác được gọi `TextToSpeech`/`flutter_tts` trực tiếp (xem `README.md` gốc repo).
///
/// CHƯA thuộc phạm vi P1F (đã ghi nợ ở `.project/openspec.md`): ràng buộc half-duplex (đang phát
/// TTS thì phải tạm dừng thu) là việc tích hợp ở P4 — lớp này không giữ tham chiếu tới tầng capture.
class SafeTtsOutput {
  SafeTtsOutput({TtsClient? client}) : _client = client ?? NativeTtsClient() {
    _client.onEvent(_handleEvent);
  }

  static const AppLogger _log = AppLogger('SafeTtsOutput');

  /// Bản dùng chung cho app (cùng kiểu `TranscriptStore.instance()`/`AudioCapture.instance`).
  static SafeTtsOutput? _instance;

  static SafeTtsOutput instance() => _instance ??= SafeTtsOutput();

  final TtsClient _client;

  final ValueNotifier<TtsOutputState> _state = ValueNotifier<TtsOutputState>(TtsOutputState.unknown);
  final StreamController<TtsFallbackNotice> _fallbacks = StreamController<TtsFallbackNotice>.broadcast();

  /// `true` = có tai nghe theo lần đọc gần nhất.
  bool _hasOutput = false;

  /// Thông tin thiết bị của lần đọc gần nhất — chỉ để màn hình chẩn đoán thấy đúng thiết bị nào
  /// đang được coi là "tai nghe" (bằng chứng khi test trên máy thật).
  TtsOutputInfo? _lastInfo;

  /// `true` = đã từng mất/kết nối lại tai nghe mà chưa được người dùng xác nhận.
  bool _needsConfirmation = false;

  bool _speaking = false;

  /// Trạng thái để UI hiển thị (không tự hỏi native — gọi [refresh] khi cần).
  ValueListenable<TtsOutputState> get stateListenable => _state;

  TtsOutputState get state => _state.value;

  /// Nguồn nudge chữ cho UI (SnackBar/dòng trạng thái). Phát cả khi bị chặn vì an toàn.
  Stream<TtsFallbackNotice> get fallbacks => _fallbacks.stream;

  bool get needsConfirmation => _needsConfirmation;

  bool get isSpeaking => _speaking;

  /// Thiết bị output của lần đọc gần nhất (null = chưa đọc được lần nào).
  TtsOutputInfo? get lastInfo => _lastInfo;

  /// Hỏi lại native trạng thái thiết bị **ngay bây giờ** và cập nhật [stateListenable].
  ///
  /// Lỗi khi đọc (kênh chết, native trả sai dạng...) ⇒ coi như **không có tai nghe** (im lặng).
  Future<void> refresh() async {
    try {
      final TtsOutputInfo info = await _client.outputState();
      _lastInfo = info;
      _hasOutput = info.hasPrivateOutput;
    } catch (error, stackTrace) {
      _log.error('không đọc được trạng thái tai nghe — coi như KHÔNG có tai nghe', error, stackTrace);
      _hasOutput = false;
    }
    _applyState();
  }

  /// Phát [text] qua tai nghe, hoặc **không phát gì** nếu không đủ điều kiện an toàn.
  ///
  /// Không bao giờ ném ra ngoài: mọi lỗi đều thành [TtsSpeakResult.failed] + im lặng.
  Future<TtsSpeakResult> speak(String text) async {
    if (text.trim().isEmpty) {
      _log.warn('bỏ qua yêu cầu đọc vì text rỗng');
      return TtsSpeakResult.failed;
    }

    // 1) Trạng thái thiết bị phải TƯƠI tại đúng thời điểm này (task 1 của prompt).
    await refresh();

    // 2) Tai nghe vừa kết nối lại mà chưa xác nhận ⇒ KHÔNG phát (task 3).
    if (_needsConfirmation) {
      _log.warn('chưa xác nhận route tai nghe sau khi kết nối lại ⇒ KHÔNG phát');
      _emit(TtsFallbackKind.needsConfirmation, 'Tai nghe đã kết nối lại. Cần xác nhận trước khi đọc.');
      return TtsSpeakResult.skippedNeedsConfirmation;
    }

    // 3) Không có tai nghe ⇒ KHÔNG gọi native speak; rung + nudge chữ.
    if (!_hasOutput || _state.value != TtsOutputState.ready) {
      await _notifyNoHeadset();
      return TtsSpeakResult.skippedNoHeadset;
    }

    // 4) Đủ điều kiện. Native vẫn kiểm tra lại lần nữa rồi mới tổng hợp (phòng thủ 2 lớp).
    try {
      final TtsNativeSpeakResult outcome = await _client.speak(text);
      switch (outcome.status) {
        case TtsNativeSpeakStatus.synthesizing:
          _speaking = true;
          return TtsSpeakResult.started;
        case TtsNativeSpeakStatus.noHeadset:
          // Native phát hiện mất tai nghe (Dart đọc trước đó đã cũ) — native đã rung báo.
          _log.warn('native từ chối vì mất tai nghe — chuyển chế độ im lặng');
          _hasOutput = false;
          _applyState();
          _emit(TtsFallbackKind.noHeadset, 'Không có tai nghe nên không đọc được. Đã rung báo.');
          return TtsSpeakResult.skippedNoHeadset;
        case TtsNativeSpeakStatus.error:
          _log.error('native không phát được TTS: ${outcome.detail}');
          _emit(TtsFallbackKind.error, 'Không đọc được (lỗi TTS).');
          return TtsSpeakResult.failed;
      }
    } catch (error, stackTrace) {
      // Fail-safe: không rơi vào bất kỳ nhánh nào có thể phát ra loa ngoài, và KHÔNG thử lại.
      _log.error('gọi native speak lỗi — KHÔNG phát', error, stackTrace);
      _emit(TtsFallbackKind.error, 'Không đọc được (lỗi kênh TTS).');
      return TtsSpeakResult.failed;
    }
  }

  /// Dừng ngay (dùng khi cần im lặng gấp: chuẩn bị thu, người dùng tắt app...).
  Future<void> stop() async {
    _speaking = false;
    try {
      await _client.stop();
    } catch (error) {
      _log.warn('không dừng được TTS: $error', error);
    }
  }

  /// Người dùng xác nhận đã ổn (task 3): chỉ từ đây mới cho phép phát lại sau khi mất/kết nối lại.
  ///
  /// Vẫn đọc lại trạng thái tươi — xác nhận mà tai nghe vẫn không có thì **vẫn** ở chế độ im lặng.
  Future<void> confirmHeadsetReady() async {
    _needsConfirmation = false;
    await refresh();
    _log.info('người dùng đã xác nhận route TTS (state=${_state.value.name})');
  }

  // ------------------------------------------------------------------ nội bộ

  void _applyState() {
    final TtsOutputState next = (!_hasOutput || _needsConfirmation)
        ? TtsOutputState.silent
        : TtsOutputState.ready;
    if (_state.value != next) {
      _log.info('trạng thái TTS: ${_state.value.name} → ${next.name} '
          '(hasOutput=$_hasOutput, needsConfirmation=$_needsConfirmation)');
      _state.value = next;
    }
  }

  Future<void> _notifyNoHeadset() async {
    _log.warn('không có tai nghe ⇒ KHÔNG phát TTS, chuyển nudge chữ + rung');
    try {
      await _client.vibrateFallback();
    } catch (error) {
      // Không rung được cũng không sao — điều bắt buộc là KHÔNG phát ra loa ngoài.
      _log.warn('không rung được thông báo fallback: $error', error);
    }
    _emit(TtsFallbackKind.noHeadset, 'Không có tai nghe nên không đọc được. Đã rung báo.');
  }

  void _handleEvent(TtsEvent event) {
    switch (event.type) {
      case TtsEventType.headsetFound:
        // KHÔNG tự cho phép phát lại: route coi như chưa ổn định cho tới khi người dùng xác nhận.
        _needsConfirmation = true;
        _hasOutput = event.state?.hasPrivateOutput ?? true;
        _applyState();
        _emit(
          TtsFallbackKind.needsConfirmation,
          'Tai nghe đã kết nối lại. Xác nhận rồi mới đọc được trở lại.',
        );
      case TtsEventType.headsetLost:
        // Native đã dừng phát + rung 2 nhịp trước khi bắn sự kiện này. Việc còn lại của Dart:
        // vào chế độ im lặng và đòi xác nhận trước lần đọc kế tiếp.
        if (event.wasPlaying) {
          _log.warn('tai nghe mất GIỮA CHỪNG lúc đang đọc — native đã dừng phát');
        }
        _speaking = false;
        _hasOutput = false;
        _needsConfirmation = true;
        _applyState();
        // Gọi thêm lần nữa cho chắc (native đã dừng; đây là lớp thứ hai, rẻ và không gây hại).
        unawaited(stop());
        _emit(
          TtsFallbackKind.headsetLost,
          'Tai nghe đã ngắt — đang chuyển chế độ im lặng (đã rung báo).',
        );
      case TtsEventType.spoke:
        _speaking = false;
      case TtsEventType.error:
        _speaking = false;
        _log.error('native báo lỗi TTS: ${event.message}');
        _emit(TtsFallbackKind.error, 'Lỗi đọc TTS: ${event.message ?? "không rõ"}');
    }
  }

  void _emit(TtsFallbackKind kind, String message) {
    if (_fallbacks.isClosed) {
      return;
    }
    _fallbacks.add(TtsFallbackNotice(kind, message));
  }
}
