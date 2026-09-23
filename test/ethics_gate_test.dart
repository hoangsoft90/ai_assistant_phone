// Test P7 mục 4 — EthicsGate (lời nhắc ranh giới đạo đức, một lần duy nhất).
//
// Hợp đồng phải khoá (xem .project/modules/coaching.md):
// - load(): thiếu/giá trị lạ/DB lỗi ⇒ `false` (chưa hiện) + KHÔNG ném — DB lỗi không được cấm dùng app.
// - markShown(): ghi '1' + RAM true; DB lỗi ⇒ RAM VẪN true, KHÔNG ném (dialog là lời nhắc,
//   không hiện lại liên tục vì một lần ghi lỗi — hướng người dùng, có ghi trong KDoc).
// - Trước khi markShown, load() trả về đúng giá trị đã lưu.

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/coaching/ethics_gate.dart';
import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';

/// Store giả trong bộ nhớ, có thể ép lỗi đọc/ghi từng loại.
class _FakeConfigStore implements ConfigStore {
  _FakeConfigStore({this.failRead = false, this.failWrite = false});

  final bool failRead;
  final bool failWrite;
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> read(String key) async {
    if (failRead) {
      throw StateError('SQLite lỗi (giả lập)');
    }
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) {
      throw StateError('SQLite đầy (giả lập)');
    }
    data[key] = value;
  }
}

void main() {
  setUp(EthicsGate.resetForTest);

  group('EthicsGate.load —', () {
    test('chưa có flag ⇒ false (hiện dialog lần đầu)', () async {
      final _FakeConfigStore store = _FakeConfigStore();
      expect(await EthicsGate.load(store), isFalse);
      expect(EthicsGate.hasShown, isFalse);
    });

    test('đã ghi "1" ⇒ true (không hiện lại)', () async {
      final _FakeConfigStore store = _FakeConfigStore()
        ..data[EthicsConfig.shownFlagKey] = '1';
      expect(await EthicsGate.load(store), isTrue);
      expect(EthicsGate.hasShown, isTrue);
    });

    test('giá trị lạ ("2", "yes") ⇒ false — chỉ "1" được nhận', () async {
      final _FakeConfigStore store = _FakeConfigStore()
        ..data[EthicsConfig.shownFlagKey] = '2';
      expect(await EthicsGate.load(store), isFalse);
    });

    test('DB lỗi khi đọc ⇒ false + KHÔNG ném (mở app không được chết vì flag)', () async {
      final _FakeConfigStore store = _FakeConfigStore(failRead: true);
      expect(await EthicsGate.load(store), isFalse);
      expect(EthicsGate.hasShown, isFalse);
    });
  });

  group('EthicsGate.markShown —', () {
    test('ghi "1" đúng khoá + RAM true; load() sau đó trả true', () async {
      final _FakeConfigStore store = _FakeConfigStore();
      await EthicsGate.markShown(store);
      expect(store.data[EthicsConfig.shownFlagKey], '1');
      expect(EthicsGate.hasShown, isTrue);

      EthicsGate.resetForTest();
      expect(await EthicsGate.load(store), isTrue);
    });

    test('DB lỗi khi ghi ⇒ RAM VẪN true + KHÔNG ném (không hiện lại liên tục)', () async {
      final _FakeConfigStore store = _FakeConfigStore(failWrite: true);
      await EthicsGate.markShown(store);
      expect(EthicsGate.hasShown, isTrue);
      expect(store.data.containsKey(EthicsConfig.shownFlagKey), isFalse);
    });
  });
}
