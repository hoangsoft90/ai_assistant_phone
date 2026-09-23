import 'package:flutter/material.dart';

import '../coaching/pre_brief.dart';
import '../core/app_logger.dart';

/// Màn hình **Pre-Brief** (P5 task 1 — mục 4.1): nhập ngữ cảnh buổi gặp TRƯỚC khi bắt đầu phiên.
///
/// Vì sao là màn hình riêng (không nhét vào `HomeScreen`): Pre-Brief có 6 trường, mỗi trường là một
/// câu người dùng phải *nghĩ* rồi gõ. Đặt nó lẫn giữa nút Bật/Tắt và các nút chẩn đoán sẽ khiến người
/// dùng bỏ qua nó — mà bỏ qua Pre-Brief thì `{pre_brief}` lại rỗng như hồi P2.
///
/// Kết quả trả về qua `Navigator.pop`: `true` nếu người dùng đã lưu (màn hình gọi tự thông báo).
/// Việc ghi xuống `meta` do [PreBriefStore] lo — màn hình không tự mở `ConfigStore` (giữ ranh giới
/// tầng: UI không chạm hạ tầng lưu trữ).
class PreBriefScreen extends StatefulWidget {
  const PreBriefScreen({super.key, this.store});

  /// Cho test bơm store giả; app dùng `PreBriefStore.instance()`.
  final PreBriefStore? store;

  @override
  State<PreBriefScreen> createState() => _PreBriefScreenState();
}

class _PreBriefScreenState extends State<PreBriefScreen> {
  static const AppLogger _log = AppLogger('PreBriefScreen');

  late final PreBriefStore _store = widget.store ?? PreBriefStore.instance();

  final TextEditingController _whoMet = TextEditingController();
  final TextEditingController _relation = TextEditingController();
  final TextEditingController _goal = TextEditingController();
  final TextEditingController _topics = TextEditingController();
  final TextEditingController _avoid = TextEditingController();
  ConversationStyle? _style;

  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Bốn controller này thuộc về màn hình (khác hộp thoại API key ở `HomeScreen` — ở đó cố ý dùng
    // `onChanged` vì dialog biến mất sau animation). Ở đây màn hình bị `pop()` rồi mới `dispose`, nên
    // huỷ controller là an toàn và bắt buộc.
    _whoMet.dispose();
    _relation.dispose();
    _goal.dispose();
    _topics.dispose();
    _avoid.dispose();
    super.dispose();
  }

  /// Nạp bản nháp đã lưu (người dùng chọn "tự điền lại lần sau") — đồng thời đặt làm Pre-Brief của
  /// phiên đang chuẩn bị, để tình huống "mở app → bấm Bật lắng nghe luôn" vẫn có ngữ cảnh.
  Future<void> _load() async {
    final PreBrief draft = await _store.loadDraft();
    if (!mounted) {
      return;
    }
    setState(() {
      _whoMet.text = draft.whoMet;
      _relation.text = draft.relation;
      _goal.text = draft.goal;
      _topics.text = draft.topics;
      _avoid.text = draft.avoidTopics;
      _style = draft.style;
      _loading = false;
    });
  }

  /// Đọc nội dung form. Không mutate store — hàm thuần để `_save` và `_clear` dùng chung.
  PreBrief _readForm() => PreBrief(
        whoMet: _whoMet.text,
        relation: _relation.text,
        goal: _goal.text,
        topics: _topics.text,
        avoidTopics: _avoid.text,
        style: _style,
      );

  Future<void> _save() async {
    final PreBrief brief = _readForm();
    setState(() => _saving = true);
    _store.setCurrent(brief);
    await _store.saveDraft(brief);
    _log.info('lưu Pre-Brief (rỗng=${brief.isEmpty})');
    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    Navigator.of(context).pop(true);
  }

  /// Xoá Pre-Brief của buổi (cả bản nháp): người dùng có buổi không cần ngữ cảnh, và lần sau không
  /// phải tự tay xoá 6 ô.
  Future<void> _clear() async {
    setState(() {
      _whoMet.clear();
      _relation.clear();
      _goal.clear();
      _topics.clear();
      _avoid.clear();
      _style = null;
    });
    _store.clearCurrent();
    await _store.saveDraft(PreBrief.empty);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pre-Brief buổi gặp')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                const Text(
                  'Điền trước khi bắt đầu — nội dung này đi vào ngữ cảnh gợi ý. Bỏ qua cũng được.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _whoMet,
                  decoration: const InputDecoration(
                    labelText: 'Người gặp',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _relation,
                  decoration: const InputDecoration(
                    labelText: 'Quan hệ (đồng nghiệp, bạn cũ, người mới...)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _goal,
                  decoration: const InputDecoration(
                    labelText: 'Mục tiêu buổi gặp',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _topics,
                  decoration: const InputDecoration(
                    labelText: 'Chủ đề muốn nói',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _avoid,
                  decoration: const InputDecoration(
                    labelText: 'Chủ đề kiêng kỵ (không muốn gợi ý)',
                    helperText: 'Ví dụ: chuyện lương, chuyện gia đình...',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Phong cách muốn dùng',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(height: 8),
                // `Wrap` + ChoiceChip: chọn/bỏ chọn được (bấm lại chip đang chọn ⇒ bỏ trống), trong khi
                // dropdown bắt buộc phải có một giá trị — Pre-Brief "không chọn phong cách" là hợp lệ.
                Wrap(
                  spacing: 8,
                  children: ConversationStyle.values
                      .map(
                        (ConversationStyle style) => ChoiceChip(
                          label: Text(style.label),
                          selected: _style == style,
                          onSelected: (bool selected) =>
                              setState(() => _style = selected ? style : null),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _saving ? null : () => _save(),
                  child: const Text('Lưu & dùng cho buổi này'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _saving ? null : () => _clear(),
                  child: const Text('Xoá hết Pre-Brief'),
                ),
              ],
            ),
    );
  }
}
