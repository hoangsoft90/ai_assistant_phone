// Test P5 task 3 — Post-Review.
//
// Điều cần khoá:
// - LLM trả JSON (kể cả bọc code fence) ⇒ đúng 3 mục, `fromLlm = true`.
// - LLM trả định dạng lạ ⇒ `fromLlm = false` + giữ văn bản thô (thà đưa raw còn hơn vứt cả buổi phân tích).
// - Mất mạng / thiếu key / transcript rỗng / đọc DB lỗi ⇒ KHÔNG ném, luôn có `note` cho người dùng.
// - Prompt: đúng 3 mục, cảnh báo khi transcript bị cắt, có Pre-Brief khi người dùng đã nhập.
// - Nguồn dữ liệu duy nhất rời thiết bị là **TEXT** (ràng buộc cứng #4) — không có audio/upload file.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_assistant_phone/coaching/post_review_service.dart';
import 'package:ai_assistant_phone/coaching/pre_brief.dart';
import 'package:ai_assistant_phone/services/storage/meta_store.dart';
import 'package:ai_assistant_phone/services/storage/transcript_dao.dart';
import 'package:ai_assistant_phone/suggestion/llm_provider.dart';
import 'package:ai_assistant_phone/suggestion/suggestion_models.dart';
import 'package:ai_assistant_phone/transcript/transcript_store.dart';

class _FakeConfigStore implements ConfigStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _FakeTextLlm implements TextLlmProvider {
  String result = '{"good":"a","missed":"b","exercise":"c"}';
  Object? throwError;
  int calls = 0;
  final List<String> prompts = <String>[];

  @override
  Future<String> complete({required String prompt, int maxTokens = 200}) async {
    calls++;
    prompts.add(prompt);
    final Object? error = throwError;
    if (error != null) {
      throw error;
    }
    return result;
  }
}

class _FakeTranscript implements TranscriptStore {
  SessionTranscript transcript = const SessionTranscript(
    text: 'dạ em chào anh\nanh ăn cơm chưa',
    segmentCount: 2,
    truncated: false,
  );
  bool throwOnRead = false;

  /// P5.1: `_persist` đọc `sessionId` để gắn báo cáo với phiên. Test có thể đổi để giả lập
  /// "phiên chưa mở" (`null`).
  @override
  int? sessionId = 42;

  @override
  Future<SessionTranscript> sessionTranscript({int maxChars = 6000}) async {
    if (throwOnRead) {
      throw StateError('DB chưa mở');
    }
    return transcript;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FakeTranscript không hỗ trợ ${invocation.memberName}');
}

/// Bắt mọi lời lưu báo cáo — để test khoá đúng lúc nào được lưu / không lưu (P5.1).
class _RecordingSink implements ReportSink {
  final List<PostReviewReportRow> saved = <PostReviewReportRow>[];
  Object? throwError;

  @override
  Future<void> save(PostReviewReportRow report) async {
    final Object? error = throwError;
    if (error != null) {
      throw error;
    }
    saved.add(report);
  }
}

void main() {
  late _FakeTextLlm llm;
  late _FakeTranscript transcript;
  late PreBriefStore preBriefs;
  late _RecordingSink sink;

  PostReviewService build() => PostReviewService(
        provider: llm,
        transcript: transcript,
        preBriefs: preBriefs,
        now: () => DateTime(2026, 9, 23, 21, 0),
        reportSink: sink,
      );

  setUp(() {
    llm = _FakeTextLlm();
    transcript = _FakeTranscript();
    preBriefs = PreBriefStore(store: _FakeConfigStore());
    sink = _RecordingSink();
  });

  group('PostReviewService — báo cáo 3 mục', () {
    test('JSON hợp lệ ⇒ 3 mục đúng thứ tự nội dung + fromLlm', () async {
      llm.result = jsonEncode(<String, String>{
        'good': 'đã chủ động chào trước',
        'missed': 'bỏ lỡ câu hỏi về công việc của đối phương',
        'exercise': 'lần sau thử hỏi thêm một câu về sở thích',
      });

      final PostReviewReport report = await build().run();

      expect(report.fromLlm, isTrue);
      expect(report.isUsable, isTrue);
      expect(report.good, 'đã chủ động chào trước');
      expect(report.missed, contains('công việc'));
      expect(report.exercise, contains('sở thích'));
      expect(report.segmentCount, 2);
      expect(report.truncated, isFalse);
      expect(report.note, isNull);
      expect(llm.calls, 1);
    });

    test('LLM bọc code fence vẫn parse được', () async {
      llm.result = '```json\n{"good":"a","missed":"b","exercise":"c"}\n```';
      final PostReviewReport report = await build().run();
      expect(report.fromLlm, isTrue);
      expect(report.good, 'a');
    });

    test('prompt chứa đúng 3 mục bắt buộc + transcript không nhãn người nói', () async {
      await build().run();
      final String prompt = llm.prompts.single;
      expect(prompt, contains('- good:'));
      expect(prompt, contains('- missed:'));
      expect(prompt, contains('- exercise:'));
      expect(prompt, contains('ĐÚNG 3 mục'));
      expect(prompt, contains('dạ em chào anh'));
      expect(prompt.contains('[Bạn]'), isFalse);
      expect(prompt.contains('[Đối phương]'), isFalse);
    });

    test('có Pre-Brief ⇒ đưa ngữ cảnh (kể cả chủ đề kiêng kỵ) vào prompt', () async {
      preBriefs.setCurrent(
        const PreBrief(whoMet: 'chị Hằng', avoidTopics: 'chuyện lương'),
      );
      await build().run();
      final String prompt = llm.prompts.single;
      expect(prompt, contains('chị Hằng'));
      expect(prompt, contains('chuyện lương'));
    });

    test('transcript bị cắt ⇒ nói rõ trong prompt + đánh dấu trên báo cáo', () async {
      transcript.transcript = const SessionTranscript(
        text: 'phần cuối buổi',
        segmentCount: 500,
        truncated: true,
      );

      final PostReviewReport report = await build().run();

      expect(report.truncated, isTrue);
      expect(report.segmentCount, 500);
      expect(llm.prompts.single, contains('đã bị cắt bớt'));
    });
  });

  group('PostReviewService — mọi nhánh lỗi đều có lời giải thích, không ném', () {
    test('LLM trả định dạng lạ ⇒ fromLlm=false, giữ văn bản thô, KHÔNG ném', () async {
      llm.result = 'Xin lỗi, tôi cần thêm thông tin.';

      final PostReviewReport report = await build().run();

      expect(report.fromLlm, isFalse);
      expect(report.isUsable, isFalse);
      expect(report.note, contains('định dạng lạ'));
      expect(report.rawText, 'Xin lỗi, tôi cần thêm thông tin.');
    });

    test('thiếu 1 trong 3 mục ⇒ coi như định dạng lạ (báo cáo phải đủ 3 mục)', () async {
      llm.result = '{"good":"a","missed":"b"}';
      final PostReviewReport report = await build().run();
      expect(report.fromLlm, isFalse);
      expect(report.note, contains('3 mục'));
    });

    test('mất mạng/thiếu key (SuggestionException) ⇒ note = lý do, KHÔNG ném', () async {
      llm.throwError = const SuggestionException('chưa có API key Groq (lưu qua SecureStore)');

      final PostReviewReport report = await build().run();

      expect(report.fromLlm, isFalse);
      expect(report.note, contains('API key'));
      expect(report.segmentCount, 2, reason: 'vẫn phải nói buổi này có bao nhiêu dòng');
    });

    test('provider ném lỗi NGOÀI dự kiến ⇒ nuốt (bài học A50)', () async {
      llm.throwError = TypeError();
      final PostReviewReport report = await build().run();
      expect(report.fromLlm, isFalse);
      expect(report.note, 'lỗi không xác định');
    });

    test('phiên chưa có dòng transcript nào ⇒ note rõ ràng, không gọi LLM', () async {
      transcript.transcript = const SessionTranscript(
        text: '',
        segmentCount: 0,
        truncated: false,
      );

      final PostReviewReport report = await build().run();

      expect(report.note, contains('chưa có dòng transcript'));
      expect(llm.calls, 0);
    });

    test('đọc transcript lỗi (SQLite) ⇒ note, KHÔNG ném', () async {
      transcript.throwOnRead = true;
      final PostReviewReport report = await build().run();
      expect(report.note, 'lỗi đọc transcript');
      expect(llm.calls, 0);
    });
  });

  group('PostReviewService — chỉ TEXT rời thiết bị (ràng buộc cứng #4)', () {
    test('nguồn dữ liệu duy nhất là text đã bóc băng (không file, không đường dẫn)', () async {
      await build().run();
      final String prompt = llm.prompts.single;
      // Đúng nội dung transcript trên máy...
      expect(prompt, contains(transcript.transcript.text));
      // ...và không có dấu hiệu của file/audio (không có bước "gửi audio lên cloud ASR").
      for (final String forbidden in <String>['/data/', 'file://', '.wav', 'base64']) {
        expect(prompt.contains(forbidden), isFalse, reason: 'prompt nhắc tới "$forbidden"');
      }
    });

    test('runCount tăng theo số lần chạy (bề mặt bằng chứng cho UI chẩn đoán)', () async {
      final PostReviewService service = build();
      await service.run();
      await service.run();
      expect(service.runCount, 2);
    });
  });

  group('PostReviewService — lưu báo cáo để xem lại từ Lịch sử (P5.1)', () {
    test('báo cáo dùng được ⇒ lưu đúng session_id + đủ 3 mục + số dòng/cắt', () async {
      transcript.transcript = const SessionTranscript(
        text: 'một\nhai\nba',
        segmentCount: 3,
        truncated: true,
      );
      llm.result = jsonEncode(<String, String>{
        'good': 'g',
        'missed': 'm',
        'exercise': 'e',
      });

      await build().run();

      expect(sink.saved, hasLength(1));
      final PostReviewReportRow row = sink.saved.single;
      expect(row.sessionId, 42);
      expect(row.good, 'g');
      expect(row.missed, 'm');
      expect(row.exercise, 'e');
      expect(row.segmentCount, 3);
      expect(row.truncated, isTrue);
      expect(row.generatedAt, DateTime(2026, 9, 23, 21, 0));
    });

    test('báo cáo KHÔNG dùng được (định dạng lạ) ⇒ KHÔNG lưu gì (chỉ gây nhiễu Lịch sử)', () async {
      llm.result = 'Xin lỗi, tôi cần thêm thông tin.';
      await build().run();
      expect(sink.saved, isEmpty);
    });

    test('mất mạng (SuggestionException) ⇒ KHÔNG lưu', () async {
      llm.throwError = const SuggestionException('chưa có API key Groq');
      await build().run();
      expect(sink.saved, isEmpty);
    });

    test('lỗi lưu DB ⇒ run() vẫn trả báo cáo bình thường, KHÔNG ném (ràng buộc prompt P5.1)', () async {
      sink.throwError = StateError('đĩa đầy');
      final PostReviewReport report = await build().run();
      expect(report.isUsable, isTrue);
      expect(report.good, 'a');
    });

    test('phiên transcript chưa mở (sessionId = null) ⇒ không lưu, không ném', () async {
      transcript.sessionId = null;
      final PostReviewReport report = await build().run();
      expect(report.isUsable, isTrue);
      expect(sink.saved, isEmpty);
    });
  });
}
