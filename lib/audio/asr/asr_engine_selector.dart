import '../../core/app_logger.dart';
import '../../services/storage/meta_store.dart';
import 'asr_engine.dart';
import 'phowhisper_asr_engine.dart';
import 'vosk_asr_engine.dart';

/// Engine ASR app đang hỗ trợ. `id` được lưu vào config (SQLite `meta`) nên KHÔNG được đổi giá trị
/// của các engine đã phát hành — đổi sẽ làm cấu hình cũ không đọc được (khi đó selector trả về mặc
/// định, không crash).
enum AsrEngineKind {
  phoWhisper('phowhisper', 'PhoWhisper (whisper.cpp)'),
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

/// Tham số chỉnh tốc độ của engine chia chunk (PhoWhisper), đọc từ config **lúc chạy**.
///
/// Tồn tại để đo A/B trên máy thật mà **không phải build lại APK**: ghi 2 khoá trong bảng `meta`
/// (`asr.chunkSeconds`, `asr.threads`) rồi khởi động lại app là đổi được. Lý do cần đo (nợ K33):
/// mỗi lần gọi `whisper_full` đều trả giá phần cố định ~30s mel pad, nên chunk 4s có thể đang là
/// lựa chọn đắt nhất — chưa có số trên máy để chốt.
class AsrTuning {
  const AsrTuning({
    this.chunkSeconds = defaultChunkSeconds,
    this.threads = defaultThreads,
  });

  /// Số giây audio góp cho mỗi chunk gửi xuống native.
  final int chunkSeconds;

  /// Số thread native; `0` = tự động (`min(4, số nhân CPU)`, xem `PhoWhisperConfig.resolvedThreads`).
  final int threads;

  static const int defaultChunkSeconds = 4;
  static const int defaultThreads = 0;
  static const AsrTuning defaults = AsrTuning();

  @override
  String toString() =>
      'chunk=${chunkSeconds}s, threads=${threads > 0 ? threads : "auto"}';
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

  /// Khoá chỉnh tốc độ (xem [AsrTuning]). Không có khoá ⇒ dùng mặc định.
  static const String chunkSecondsKey = 'asr.chunkSeconds';
  static const String threadsKey = 'asr.threads';

  /// Khoảng hợp lệ; ngoài khoảng = giá trị hỏng ⇒ quay về mặc định (không ném lỗi, giống [readConfigured]).
  static const int minChunkSeconds = 2;
  static const int maxChunkSeconds = 30;
  static const int maxThreads = 8;

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

  /// Đọc tham số tốc độ từ config; thiếu khoá ⇒ mặc định, giá trị hỏng ⇒ mặc định + log cảnh báo.
  Future<AsrTuning> readTuning() async {
    return AsrTuning(
      chunkSeconds: _readInt(
        await _store.read(chunkSecondsKey),
        min: minChunkSeconds,
        max: maxChunkSeconds,
        fallback: AsrTuning.defaultChunkSeconds,
        key: chunkSecondsKey,
      ),
      threads: _readInt(
        await _store.read(threadsKey),
        min: 0,
        max: maxThreads,
        fallback: AsrTuning.defaultThreads,
        key: threadsKey,
      ),
    );
  }

  int _readInt(
    String? raw, {
    required int min,
    required int max,
    required int fallback,
    required String key,
  }) {
    final int? value = raw == null ? null : int.tryParse(raw.trim());
    if (value == null || value < min || value > max) {
      if (raw != null) {
        _log.warn('cấu hình $key="$raw" không hợp lệ (hợp lệ $min..$max) → dùng $fallback');
      }
      return fallback;
    }
    return value;
  }

  /// Tạo engine theo loại (chưa `init()`). Tách khỏi [createAndInit] để test/UI kiểm soát.
  ///
  /// [tuning] chỉ áp cho engine chia chunk (PhoWhisper); Vosk streaming không dùng. Khi có `factory`
  /// (test) thì factory tự quyết định engine nên `tuning` không đi qua được.
  AsrEngine create(AsrEngineKind kind, {AsrTuning tuning = AsrTuning.defaults}) {
    final AsrEngine Function(AsrEngineKind)? factory = _factory;
    if (factory != null) {
      return factory(kind);
    }
    return switch (kind) {
      AsrEngineKind.phoWhisper => PhoWhisperAsrEngine(
          config: PhoWhisperConfig(
            chunkSeconds: tuning.chunkSeconds,
            threads: tuning.threads,
          ),
        ),
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
    AsrTuning? tuning,
  }) async {
    final AsrEngineKind wanted = overrideKind ?? await readConfigured();
    final AsrTuning active = tuning ?? await readTuning();
    final AsrEngine primary = create(wanted, tuning: active);
    try {
      await primary.init();
      _log.info('engine ASR đang dùng: ${wanted.id} ($active)');
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
      final AsrEngine secondary = create(other, tuning: active);
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
