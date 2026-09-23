// Test P5 task 1 — Pre-Brief.
//
// Điều cần khoá:
// - Model: `{pre_brief}` sinh ra đúng dòng, chủ đề kiêng kỵ được ghi rõ là TRÁNH (không thể bị đọc
//   ngược thành "chủ đề nên khai thác").
// - Store: nháp lưu/đọc được, và **mọi lỗi đều không ném** (mở app không được chết vì một nháp hỏng).
// - DoD-1 ở mức unit: ĐỔI "chủ đề kiêng kỵ" ⇒ prompt gửi LLM đổi theo (bằng chứng tự động cho phần
//   "dữ liệu nhập vào thực sự ảnh hưởng đến gợi ý"; phần xác nhận LLM có tuân thủ hay không vẫn cần
//   máy thật + API key — nợ K39/K49).

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/coaching/pre_brief.dart';
import 'package:ai_assistant_phone/coaching/session_summary.dart';
import 'package:ai_assistant_phone/core/constants.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';
import 'package:ai_assistant_phone/suggestion/llm_provider.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_models.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_service.dart';
import 'package:ai_assistant_phone/transcript/transcript_segment.dart';
import 'package:ai_assistant_phone/transcript/transcript_store.dart';

class _FakeConfigStore implements ConfigStore {
  _FakeConfigStore({this.failRead = false, this.failWrite = false});

  final Map<String, String> values = <String, String>{};
  bool failRead;
  bool failWrite;

  @override
  Future<String?> read(String key) async {
    if (failRead) {
      throw StateError('DB lỗi khi đọc');
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) {
      throw StateError('DB lỗi khi ghi');
    }
    values[key] = value;
  }
}

/// LLM giả: giữ lại đúng `SuggestionContext` để soi prompt thật đã gửi.
class _CapturingLlm implements LlmProvider {
  final List<SuggestionContext> captured = <SuggestionContext>[];

  @override
  Future<SuggestionResult> generateSuggestion(SuggestionContext context) async {
    captured.add(context);
    return const SuggestionResult.nudge(type: NudgeType.ask, text: 'hỏi thêm đi');
  }
}

/// Transcript giả cho `SuggestionService` (chỉ cần cửa sổ 30s) — NÉM ở mọi method khác để test ĐỎ nếu
/// service bắt đầu dùng thêm API (bài học A8).
class _FakeTranscriptStore implements TranscriptStore {
  @override
  Future<TranscriptWindow> recentWindow({Duration? window}) async =>
      TranscriptWindow(
        segments: <TranscriptSegment>[
          TranscriptSegment(text: 'chào bạn', timestamp: DateTime(2026, 9, 23, 9, 0)),
        ],
        lastPushMoment: null,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeTranscriptStore không hỗ trợ ${invocation.memberName}');
}

class _FakeTextLlm implements TextLlmProvider {
  @override
  Future<String> complete({required String prompt, int maxTokens = 200}) async => 'tóm tắt giả';
}

SessionSummaryService _silentSummaries() => SessionSummaryService(
      provider: _FakeTextLlm(),
      transcript: _FakeTranscriptStore(),
      // Ngưỡng cao: test Pre-Brief không muốn chạy thêm đường tóm tắt (đường đó có test riêng).
      everyNudges: 99,
    );

void main() {
  group('PreBrief — model', () {
    test('rỗng ⇒ toPromptValue() rỗng (prompt khung tự in "(chưa có)")', () {
      expect(PreBrief.empty.isEmpty, isTrue);
      expect(PreBrief.empty.toPromptValue(), '');
    });

    test('đủ trường ⇒ một dòng có nhãn, chủ đề kiêng kỵ ghi rõ TRÁNH', () {
      const PreBrief brief = PreBrief(
        whoMet: 'chị Hằng',
        relation: 'đồng nghiệp cũ',
        goal: 'xin lỗi chuyện hôm trước',
        topics: 'công việc mới',
        avoidTopics: 'chuyện lương',
        style: ConversationStyle.polite,
      );
      final String value = brief.toPromptValue();
      expect(value, contains('Người gặp: chị Hằng'));
      expect(value, contains('Quan hệ: đồng nghiệp cũ'));
      expect(value, contains('Mục tiêu: xin lỗi chuyện hôm trước'));
      expect(value, contains('Chủ đề muốn nói: công việc mới'));
      expect(value, contains('TRÁNH (chủ đề kiêng kỵ): chuyện lương'));
      expect(value, contains('Phong cách: lịch sự'));
      // MỘT dòng: prompt khung đặt giá trị này ngay sau "- Pre-brief: " nên xuống dòng sẽ phá cấu trúc.
      expect(value.contains('\n'), isFalse);
    });

    test('trường chỉ có khoảng trắng ⇒ coi như không nhập', () {
      const PreBrief brief = PreBrief(whoMet: '   ', goal: '');
      expect(brief.isEmpty, isTrue);
      expect(brief.toPromptValue(), '');
    });

    test('JSON roundtrip giữ nguyên dữ liệu', () {
      const PreBrief brief = PreBrief(
        whoMet: 'Nam',
        avoidTopics: 'gia đình',
        style: ConversationStyle.humorous,
      );
      final PreBrief restored = PreBrief.fromJson(brief.toJson());
      expect(restored.whoMet, 'Nam');
      expect(restored.avoidTopics, 'gia đình');
      expect(restored.style, ConversationStyle.humorous);
    });

    test('REVIEW: JSON rác ⇒ PreBrief rỗng, KHÔNG ném (nháp hỏng không được làm chết app)', () {
      for (final Object? garbage in <Object?>[
        null,
        'không phải map',
        42,
        <String, Object?>{'whoMet': 123, 'style': 'không tồn tại'},
      ]) {
        final PreBrief brief = PreBrief.fromJson(garbage);
        expect(brief.isEmpty, isTrue, reason: 'input: $garbage');
      }
    });
  });

  group('PreBriefStore', () {
    test('saveDraft rồi loadDraft ⇒ đúng dữ liệu, ghi vào đúng khoá meta', () async {
      final _FakeConfigStore config = _FakeConfigStore();
      final PreBriefStore store = PreBriefStore(store: config);

      await store.saveDraft(const PreBrief(whoMet: 'Hằng', avoidTopics: 'lương'));
      expect(config.values.containsKey(CoachingConfig.preBriefDraftKey), isTrue);

      final PreBrief loaded = await PreBriefStore(store: config).loadDraft();
      expect(loaded.whoMet, 'Hằng');
      expect(loaded.avoidTopics, 'lương');
    });

    test('chưa có nháp ⇒ PreBrief rỗng', () async {
      expect((await PreBriefStore(store: _FakeConfigStore()).loadDraft()).isEmpty, isTrue);
    });

    test('REVIEW: đọc/ghi lỗi đều KHÔNG ném (mất nháp không phải lỗi chặn app)', () async {
      final _FakeConfigStore broken = _FakeConfigStore(failRead: true, failWrite: true);
      final PreBriefStore store = PreBriefStore(store: broken);

      expect((await store.loadDraft()).isEmpty, isTrue);
      await store.saveDraft(const PreBrief(whoMet: 'X')); // không được ném
    });

    test('setCurrent/clearCurrent + restoreDraftAsCurrent', () async {
      final _FakeConfigStore config = _FakeConfigStore();
      final PreBriefStore store = PreBriefStore(store: config);

      expect(store.hasCurrent, isFalse);
      store.setCurrent(const PreBrief(goal: 'chào hỏi'));
      expect(store.hasCurrent, isTrue);

      store.clearCurrent();
      expect(store.hasCurrent, isFalse);

      // Mở app lại: nháp trở thành Pre-Brief của phiên đang chuẩn bị.
      await store.saveDraft(const PreBrief(whoMet: 'chị Hằng'));
      final PreBrief restored = await store.restoreDraftAsCurrent();
      expect(restored.whoMet, 'chị Hằng');
      expect(store.current.whoMet, 'chị Hằng');
    });
  });

  group('Pre-Brief ảnh hưởng tới gợi ý (DoD-1, mức unit)', () {
    SuggestionService serviceWith(
      PreBriefStore preBriefs,
      _CapturingLlm llm,
      _FakeTranscriptStore transcript,
    ) =>
        SuggestionService(
          provider: llm,
          transcript: transcript,
          preBriefs: preBriefs,
          summaries: _silentSummaries(),
        );

    test('đổi "chủ đề kiêng kỵ" ⇒ prompt gửi LLM đổi theo, không còn placeholder', () async {
      final PreBriefStore preBriefs = PreBriefStore(store: _FakeConfigStore());
      final _CapturingLlm llm = _CapturingLlm();
      final SuggestionService service = serviceWith(preBriefs, llm, _FakeTranscriptStore());

      preBriefs.setCurrent(const PreBrief(whoMet: 'chị Hằng', avoidTopics: 'chuyện lương'));
      await service.push(isUserSpeaking: false);

      final SuggestionContext first = llm.captured.single;
      expect(first.prompt, contains('- Pre-brief: '));
      expect(first.prompt, contains('chuyện lương'));
      expect(first.prompt.contains('{pre_brief}'), isFalse);
      expect(first.preBrief, contains('chuyện lương'));
      // Không được lọt nhãn người nói vào prompt (ràng buộc xuyên phase từ P1E).
      expect(first.prompt.contains('[Bạn]'), isFalse);

      // Đổi chủ đề kiêng kỵ ⇒ prompt lần sau phải khác, chủ đề cũ KHÔNG còn.
      service.resetSession();
      preBriefs.setCurrent(const PreBrief(whoMet: 'chị Hằng', avoidTopics: 'chuyện gia đình'));
      await service.push(isUserSpeaking: false);

      final SuggestionContext second = llm.captured[1];
      expect(second.prompt, contains('chuyện gia đình'));
      expect(second.prompt.contains('chuyện lương'), isFalse,
          reason: 'chủ đề kiêng kỵ cũ không được còn trong prompt');
    });

    test('chưa nhập Pre-Brief ⇒ prompt in "(chưa có)" (giữ nguyên hành vi P2)', () async {
      final _CapturingLlm llm = _CapturingLlm();
      final SuggestionService service = serviceWith(
        PreBriefStore(store: _FakeConfigStore()),
        llm,
        _FakeTranscriptStore(),
      );

      await service.push(isUserSpeaking: false);
      expect(llm.captured.single.prompt, contains('- Pre-brief: (chưa có)'));
    });
  });
}
