// Test P3 task 4 — Offline Nudge Cache (mục 4.12).
//
// Bất biến quan trọng nhất: kho này **chỉ là fallback** và **không bao giờ ném**. Nếu cả nó cũng
// lỗi, tầng trên phải quay về hành vi P2 (`NO_SUGGESTION` im lặng) chứ không được crash.
//
// Có một test đọc THẲNG file asset thật (`assets/offline_nudge_cache.json`) — vì file đó là dữ liệu
// bàn giao, sửa tay có thể làm sai số câu/số từ mà code không hề biết.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/suggestion/offline_nudge_cache.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_models.dart';

String _cacheJson(Map<String, List<String>> byType) => jsonEncode(<String, Object?>{
      'version': 1,
      'nudges': byType,
    });

/// Kho nhỏ cho test xoay vòng: 2 câu mỗi type.
final Map<String, List<String>> _small = <String, List<String>>{
  for (final NudgeType type in NudgeType.values)
    type.apiName: <String>['${type.apiName} một', '${type.apiName} hai'],
};

void main() {
  group('OfflineNudgeCache — nạp + xoay vòng', () {
    test('nạp được: đếm đủ câu theo từng type', () async {
      final OfflineNudgeCache cache =
          OfflineNudgeCache(loader: () async => _cacheJson(_small));

      await cache.ensureLoaded();

      expect(cache.isLoaded, isTrue);
      expect(cache.lastError, isNull);
      expect(cache.totalCount, NudgeType.values.length * 2);
      for (final NudgeType type in NudgeType.values) {
        expect(cache.countFor(type), 2);
        expect(cache.textsFor(type).first, '${type.apiName} một');
      }
    });

    test('xoay vòng qua các type: 6 lần liên tiếp ⇒ 6 type KHÁC nhau, câu đầu của mỗi type', () async {
      final OfflineNudgeCache cache =
          OfflineNudgeCache(loader: () async => _cacheJson(_small));

      final List<NudgeType> picked = <NudgeType>[];
      for (int i = 0; i < NudgeType.values.length; i++) {
        final CachedNudge? nudge = await cache.pickNext();
        expect(nudge, isNotNull);
        picked.add(nudge!.type);
      }

      expect(picked.toSet().length, NudgeType.values.length, reason: 'không được lặp type');
    });

    test('avoidTexts: bỏ qua câu vừa hiện rồi mới tới câu khác của cùng type', () async {
      final OfflineNudgeCache cache =
          OfflineNudgeCache(loader: () async => _cacheJson(_small));

      final CachedNudge? first = await cache.pickNext();
      expect(first?.type, NudgeType.ask);
      expect(first?.text, 'ASK một');

      final CachedNudge? second = await cache.pickNext(avoidTexts: <String>[first!.text]);

      // Xoay vòng tiếp sang type kế tiếp, nhưng nếu quay lại ASK thì phải là câu còn lại.
      expect(second?.text, isNot(first.text));
    });

    test('avoidTexts: chỉ còn 1 câu chưa dùng ⇒ chọn đúng câu đó (không lặp câu vừa hiện)', () async {
      final OfflineNudgeCache cache =
          OfflineNudgeCache(loader: () async => _cacheJson(_small));
      await cache.ensureLoaded();

      final CachedNudge? nudge = await cache.pickNext(
        avoidTexts: <String>[
          for (final NudgeType type in NudgeType.values)
            if (type != NudgeType.ask) ...cache.textsFor(type),
          'ASK một',
        ],
      );

      expect(nudge?.type, NudgeType.ask);
      expect(nudge?.text, 'ASK hai');
    });

    test('mọi câu đều đã dùng gần đây ⇒ trả null (KHÔNG ném, KHÔNG lặp)', () async {
      final OfflineNudgeCache cache =
          OfflineNudgeCache(loader: () async => _cacheJson(_small));

      final CachedNudge? nudge = await cache.pickNext(
        avoidTexts: <String>[for (final List<String> texts in _small.values) ...texts],
      );

      expect(nudge, isNull);
    });

    test('câu rỗng / phần tử không phải chuỗi bị lọc bỏ ngay khi nạp', () async {
      final OfflineNudgeCache cache = OfflineNudgeCache(
        loader: () async => jsonEncode(<String, Object?>{
          'nudges': <String, Object?>{
            'ASK': <Object?>['  ', 'hỏi thêm đi', 123, null, ''],
            'REACT': <Object?>[],
          },
        }),
      );

      await cache.ensureLoaded();

      expect(cache.countFor(NudgeType.ask), 1);
      expect(cache.textsFor(NudgeType.ask).single, 'hỏi thêm đi');
      expect(cache.countFor(NudgeType.react), 0);
      expect(cache.totalCount, 1);
    });
  });

  group('OfflineNudgeCache — không bao giờ ném (fail-safe)', () {
    test('JSON không phải object ⇒ isLoaded=false, pickNext() = null', () async {
      final OfflineNudgeCache cache = OfflineNudgeCache(loader: () async => '[1, 2, 3]');

      expect(await cache.pickNext(), isNull);
      expect(cache.isLoaded, isFalse);
      expect(cache.lastError, isNotNull);
    });

    test('thiếu object "nudges" ⇒ null, không ném', () async {
      final OfflineNudgeCache cache =
          OfflineNudgeCache(loader: () async => jsonEncode(<String, Object?>{'version': 1}));

      expect(await cache.pickNext(), isNull);
      expect(cache.lastError, isNotNull);
    });

    test('JSON hỏng (không parse được) ⇒ null, không ném', () async {
      final OfflineNudgeCache cache = OfflineNudgeCache(loader: () async => '{khong-phai-json');

      expect(await cache.pickNext(), isNull);
      expect(cache.isLoaded, isFalse);
    });

    test('loader ném (asset thiếu) ⇒ null, không ném', () async {
      final OfflineNudgeCache cache =
          OfflineNudgeCache(loader: () async => throw StateError('asset không tồn tại'));

      expect(await cache.pickNext(), isNull);
      expect(cache.lastError, isNotNull);
    });

    test('lỗi thoáng qua: lần sau nạp lại được, KHÔNG nhân đôi type (regression)', () async {
      // Lần 1 lỗi, lần 2 OK. Nếu `_load` không xoá sạch `_order`/`_byType` trước khi nạp lại,
      // lần 2 sẽ nối thêm type trùng và vòng xoay vòng đi sai nhịp.
      bool fail = true;
      final OfflineNudgeCache cache = OfflineNudgeCache(
        loader: () async {
          if (fail) {
            throw StateError('lỗi tạm thời');
          }
          return _cacheJson(_small);
        },
      );

      expect(await cache.pickNext(), isNull);

      fail = false;
      final CachedNudge? recovered = await cache.pickNext();
      expect(recovered, isNotNull);
      expect(cache.isLoaded, isTrue);
      expect(cache.totalCount, NudgeType.values.length * 2);
    });
  });

  group('File asset thật (bàn giao của P3)', () {
    test('có đủ 5 type prompt yêu cầu, 10-15 câu mỗi type, nudge 2-4 từ', () {
      final File file = File(OutputConfig.offlineNudgeCacheAsset);
      expect(file.existsSync(), isTrue, reason: 'thiếu ${OutputConfig.offlineNudgeCacheAsset}');

      final Object? decoded = jsonDecode(file.readAsStringSync());
      expect(decoded, isA<Map<String, dynamic>>());
      final Object? nudges = (decoded! as Map<String, dynamic>)['nudges'];
      expect(nudges, isA<Map<String, dynamic>>());
      final Map<String, dynamic> byType = nudges! as Map<String, dynamic>;

      // 5 type trong prompt P3 (ASK/FOLLOW_UP/REACT/CLARIFY/CHANGE_TOPIC) + RELATE của plan 4.5.
      for (final String required in <String>[
        'ASK',
        'FOLLOW_UP',
        'REACT',
        'CLARIFY',
        'CHANGE_TOPIC',
      ]) {
        expect(byType.containsKey(required), isTrue, reason: 'thiếu type $required');
      }

      for (final MapEntry<String, dynamic> entry in byType.entries) {
        final List<dynamic> texts = entry.value as List<dynamic>;
        expect(texts.length, inInclusiveRange(10, 15), reason: 'type ${entry.key}');
        for (final Object? text in texts) {
          expect(text, isA<String>());
          final int words = (text! as String).trim().split(RegExp(r'\s+')).length;
          expect(words, inInclusiveRange(2, 4), reason: 'nudge "$text" phải 2-4 từ');
        }
      }
    });

    test('nạp được bằng loader của app (đường đi thật: rootBundle qua file asset)', () async {
      // `rootBundle` cần binding/asset bundle của Flutter — ở đây đọc file thật để khẳng định
      // `_load()` parse được đúng định dạng mà asset sẽ cung cấp lúc chạy.
      final OfflineNudgeCache cache = OfflineNudgeCache(
        loader: () async => File(OutputConfig.offlineNudgeCacheAsset).readAsString(),
      );

      await cache.ensureLoaded();

      expect(cache.isLoaded, isTrue);
      expect(cache.totalCount, greaterThanOrEqualTo(50));
      expect(await cache.pickNext(), isNotNull);
    });
  });
}
