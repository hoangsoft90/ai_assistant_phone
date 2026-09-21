import '../../core/app_logger.dart';
import '../../services/storage/meta_store.dart';
import 'asr_engine.dart';
import 'phowhisper_asr_engine.dart';
import 'vosk_asr_engine.dart';

/// Engine ASR app đang hỗ trợ. `id` được lưu vào config (SQLite `meta`) nên KHÔNG được đổi giá trị
/// của các engine đã phát hành — đổi sẽ làm cấu hình cũ không đọc được (khi đó selector trả về mặc
/// định, không crash).
enum AsrEngineKind {
  phoWhisper('phowhisper', 'PhoWhisper (whisper.cpp, chunk 4s)'),
  vosk('vosk', 'Vosk (streaming, dự phòng)');

  const AsrEngineKind(this.id, this.label);

  final String id;
  final String label;

  static AsrEngineKind? fromId(String? id) {
    for (final AsrEngineKind kind in AsrEngineKind.values) {
      if (kind.id == id) {
        return kind;
      }
    }
    return null;
  }
}

/// Chọn engine ASR theo **config lúc chạy** (không hard-code) — để đổi engine không phải build lại
/// app và không phải sửa tầng trên (transcript store P1E, suggestion engine P2 chỉ nhận `AsrEngine`).
///
/// Quyết định engine mặc định + lý do: xem `lib/audio/asr/README.md` (bàn giao của P1D).
class AsrEngineSelector {
  /// [store] là nơi đọc/ghi cấu hình; tham số thứ hai (tuỳ chọn) là factory để test bơm engine giả —
  /// không truyền thì tự tạo engine thật theo [AsrEngineKind].
  AsrEngineSelector(this._store, [this._factory]);

  /// Khoá cấu hình trong bảng `meta`. Đổi giá trị này = mọi máy mất cấu hình đã chọn.
  static const String configKey = 'asr.engine';

  /// Mặc định hiện tại: **PhoWhisper** — xem lý do ở README (WER 15.5% vs Vosk 52.2% trên host P0).
  /// Quyết định này là TẠM THỜI cho tới khi có số đo trên máy thật (nợ K18).
  static const AsrEngineKind defaultKind = AsrEngineKind.phoWhisper;

  static const AppLogger _log = AppLogger('AsrEngineSelector');

  final ConfigStore _store;
  final AsrEngine Function(AsrEngineKind)? _factory;

  /// Engine đang được cấu hình; giá trị lạ/thiếu ⇒ [defaultKind] (không ném lỗi).
  Future<AsrEngineKind> readConfigured() async {
    final String? stored = await _store.read(configKey);
    final AsrEngineKind? kind = AsrEngineKind.fromId(stored);
    if (kind == null) {
      if (stored != null) {
        _log.warn('giá trị engine không nhận ra ("$stored") → dùng ${defaultKind.id}');
      }
      return defaultKind;
    }
    return kind;
  }

  Future<void> writeConfigured(AsrEngineKind kind) => _store.write(configKey, kind.id);

  /// Tạo engine theo loại (chưa `init()`). Tách khỏi [createAndInit] để test/UI kiểm soát.
  AsrEngine create(AsrEngineKind kind) {
    final AsrEngine Function(AsrEngineKind)? factory = _factory;
    if (factory != null) {
      return factory(kind);
    }
    return switch (kind) {
      AsrEngineKind.phoWhisper => PhoWhisperAsrEngine(),
      AsrEngineKind.vosk => VoskAsrEngine(),
    };
  }

  /// Tạo + `init()` engine theo config, có **fallback tự động** sang engine còn lại nếu `init()`
  /// thất bại (ví dụ máy không đủ RAM để nạp model PhoWhisper) — log rõ lý do để không "âm thầm" đổi
  /// chất lượng nhận dạng.
  ///
  /// Ném `StateError` nếu CẢ HAI engine đều không init được.
  Future<AsrEngine> createAndInit({
    AsrEngineKind? overrideKind,
    bool allowFallback = true,
  }) async {
    final AsrEngineKind wanted = overrideKind ?? await readConfigured();
    final AsrEngine primary = create(wanted);
    try {
      await primary.init();
      _log.info('engine ASR đang dùng: ${wanted.id}');
      return primary;
    } catch (error, stackTrace) {
      _log.error('init engine ${wanted.id} thất bại', error, stackTrace);
      await primary.dispose();
      if (!allowFallback) {
        rethrow;
      }
      final AsrEngineKind other = wanted == AsrEngineKind.phoWhisper
          ? AsrEngineKind.vosk
          : AsrEngineKind.phoWhisper;
      final AsrEngine secondary = create(other);
      try {
        await secondary.init();
        _log.warn('đã FALLBACK sang engine ${other.id} (lý do: ${error.runtimeType})');
        return secondary;
      } catch (fallbackError, fallbackStack) {
        _log.error('fallback sang ${other.id} cũng thất bại', fallbackError, fallbackStack);
        await secondary.dispose();
        throw StateError(
          'Không engine ASR nào init được: ${wanted.id} ($error) và ${other.id} ($fallbackError)',
        );
      }
    }
  }
}
