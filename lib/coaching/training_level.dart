import '../core/app_logger.dart';
import '../core/constants.dart';
import '../services/storage/meta_store.dart';

/// 5 cấp độ Training Level (mục 4.9 của plan — đã patch: **hoàn toàn thủ công**).
///
/// ⚠️ Quyết định đã chốt: app **KHÔNG** tự đề xuất chuyển cấp ở bất kỳ đâu, không có logic "đủ tốt
/// thì nâng cấp" — người dùng tự chọn trong Settings, dựa trên số liệu tham khảo ở màn hình thống kê.
/// Đây là ràng buộc xuyên phase (AGENT_INSTRUCTIONS §3): nếu phase sau thấy "tiện" mà thêm gợi ý
/// chuyển cấp, đó là vi phạm quyết định đã patch.
///
/// [label]/[behavior] lấy nguyên tinh thần bảng mục 4.9 để UI và báo cáo nói cùng một ngôn ngữ.
enum TrainingLevel {
  fullAssist('full_assist', 'Full Assist', 'Gợi ý khá thường khi push'),
  lightAssist('light_assist', 'Light Assist', 'Chỉ khi push + ngữ cảnh rõ'),
  minimal('minimal', 'Minimal', 'Chỉ khi thật sự kẹt'),
  training('training', 'Training', 'Không cứu realtime — chỉ Post-Review'),
  independent('independent', 'Independent', 'Chỉ ghi nhận + báo cáo');

  const TrainingLevel(this.storageValue, this.label, this.behavior);

  /// Giá trị lưu trong bảng `meta` — ổn định, đừng đổi (người dùng đã có cấu hình trên máy).
  final String storageValue;

  /// Nhãn hiển thị.
  final String label;

  /// Mô tả hành vi (hiện ngay dưới dropdown để người dùng biết mình vừa chọn gì).
  final String behavior;

  /// Cấp độ này có **chặn mọi nudge realtime** hay không.
  ///
  /// Level 4 (Training) và 5 (Independent) theo mục 4.9 là "không cứu realtime": Push vẫn hoạt động
  /// (nút vẫn bấm được, mốc Push vẫn ghi) nhưng Suggestion Engine trả `NO_SUGGESTION` **có chủ đích**,
  /// dồn giá trị học tập vào Post-Review. Emergency Phrase KHÔNG bị ảnh hưởng — câu thoát hiểm đi
  /// thẳng `EmergencyPhraseService` → `SafeTtsOutput`, không qua Policy/LLM (quyết định từ P1G/P3).
  bool get blocksRealtimeNudges => this == training || this == independent;

  /// Cấp độ này có cần "ngữ cảnh rõ" mới cho nudge (mục 4.9: Level 2 "chỉ khi push + context rõ").
  bool get requiresClearContext => this == lightAssist;

  /// Cấp độ này chỉ cho nudge khi người dùng **thật sự kẹt** (Level 3).
  bool get requiresStuck => this == minimal;

  static TrainingLevel? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    final String normalized = raw.trim().toLowerCase();
    for (final TrainingLevel level in TrainingLevel.values) {
      if (level.storageValue == normalized) {
        return level;
      }
    }
    return null;
  }
}

/// Đọc/ghi Training Level đã chọn + giữ bản đang dùng trong RAM.
///
/// Vì sao giữ trong RAM: cấp độ được đọc ở **mỗi** lần Push (để quyết định chặn hay không) — đọc SQLite
/// mỗi lần bấm nút là lãng phí và thêm một điểm có thể lỗi ngay trên đường gợi ý. RAM chỉ được cập nhật
/// qua [save] (UI Settings) hoặc [load] (lúc mở màn hình), nên không có nguy cơ lệch với đĩa.
class TrainingLevelStore {
  TrainingLevelStore({ConfigStore? store}) : _store = store ?? const MetaConfigStore();

  static TrainingLevelStore? _shared;

  static TrainingLevelStore instance() => _shared ??= TrainingLevelStore();

  static const AppLogger _log = AppLogger('TrainingLevel');

  /// Mặc định Level 1 (Full Assist) — đúng mục 4.9: người mới dùng cần được hỗ trợ nhiều nhất, và app
  /// không được tự "kỷ luật" người dùng bằng cách mặc định cấp cao hơn. Không có khoá trong `meta`
  /// (máy mới) cũng rơi về đây.
  static const TrainingLevel defaultLevel = TrainingLevel.fullAssist;

  final ConfigStore _store;

  TrainingLevel _current = defaultLevel;

  /// Cấp độ đang có hiệu lực.
  TrainingLevel get current => _current;

  /// Đọc từ cấu hình; thiếu/giá trị lạ ⇒ [defaultLevel] + log cảnh báo (không ném).
  Future<TrainingLevel> load() async {
    try {
      final String? raw = await _store.read(CoachingConfig.trainingLevelKey);
      final TrainingLevel? parsed = TrainingLevel.tryParse(raw);
      if (parsed == null) {
        if (raw != null) {
          _log.warn('training level không nhận ra ("$raw") → dùng ${defaultLevel.storageValue}');
        }
        _current = defaultLevel;
        return _current;
      }
      _current = parsed;
      _log.info('training level: ${parsed.storageValue}');
      return _current;
    } catch (error) {
      _log.warn('không đọc được training level — dùng mặc định: $error');
      _current = defaultLevel;
      return _current;
    }
  }

  /// Ghi cấu hình + cập nhật RAM ngay (UI đổi là có hiệu lực tức thì cho Push kế tiếp).
  ///
  /// Chỉ đổi RAM khi ghi thành công: nếu SQLite lỗi mà vẫn đổi RAM thì lần mở app sau cấp độ "tự
  /// quay về" cũ mà người dùng không biết vì sao — sai lệch im lặng khó lần nhất.
  Future<bool> save(TrainingLevel level) async {
    try {
      await _store.write(CoachingConfig.trainingLevelKey, level.storageValue);
      _current = level;
      _log.info('đã đổi training level sang ${level.storageValue}');
      return true;
    } catch (error) {
      _log.warn('không lưu được training level: $error');
      return false;
    }
  }
}
