// App spike P0 — throwaway, UI chỉ cần đủ để điều khiển và đọc log trong lúc test.
//
// Toàn bộ logic audio/ASR nằm ở tầng Kotlin/native (xem android/.../SpikeController.kt).
// File này chỉ: bấm nút -> gọi MethodChannel, và hiển thị event từ EventChannel.
//
// Nhớ: khi cắm máy thật, log đầy đủ luôn có ở logcat:
//   adb logcat -s P0Spike:I P0SpikeJni:I

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const P0SpikeApp());

class P0SpikeApp extends StatelessWidget {
  const P0SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'P0 Audio Spike',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      home: const SpikeScreen(),
    );
  }
}

class _Line {
  _Line(this.text, {this.isTranscript = false});

  final String text;
  final bool isTranscript;
}

class SpikeScreen extends StatefulWidget {
  const SpikeScreen({super.key});

  @override
  State<SpikeScreen> createState() => _SpikeScreenState();
}

class _SpikeScreenState extends State<SpikeScreen> {
  static const _control = MethodChannel('p0spike/control');
  static const _events = EventChannel('p0spike/events');

  final List<_Line> _lines = <_Line>[];
  StreamSubscription<dynamic>? _sub;
  Timer? _poll;
  Map<String, dynamic> _status = <String, dynamic>{};
  int _chunkSeconds = 3;

  @override
  void initState() {
    super.initState();
    _sub = _events.receiveBroadcastStream().listen(_onEvent);
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final event = Map<String, dynamic>.from(raw);
    if (event['type'] == 'transcript') {
      final latency = event['latencyMs'];
      final audio = event['audioMs'];
      final suffix = latency == null ? '' : '  [xử lý ${latency}ms / audio ${audio}ms]';
      final tag = event['final'] == true ? '' : '…';
      _add(_Line('[${event['engine']}] $tag${event['text']}$suffix', isTranscript: true));
    } else if (event['type'] == 'log') {
      _add(_Line('• ${event['text']}'));
    } else {
      setState(() => _status = event);
    }
  }

  void _add(_Line line) {
    if (!mounted) return;
    setState(() {
      _lines.add(line);
      if (_lines.length > 400) _lines.removeRange(0, _lines.length - 400);
    });
  }

  Future<void> _refresh() async {
    try {
      final result = await _control.invokeMethod<dynamic>('status');
      if (result is Map && mounted) {
        setState(() => _status = Map<String, dynamic>.from(result));
      }
    } on PlatformException catch (e) {
      _add(_Line('• lỗi status: ${e.message}'));
    }
  }

  Future<void> _call(String method, [Map<String, dynamic>? args]) async {
    try {
      final result = await _control.invokeMethod<dynamic>(method, args);
      if (result is Map && mounted) {
        final map = Map<String, dynamic>.from(result);
        setState(() => _status = map);
        final error = map['error'];
        if (error != null) _add(_Line('• LỖI: $error'));
      }
    } on PlatformException catch (e) {
      _add(_Line('• lỗi gọi $method: ${e.message}'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _status['mode'] != 'idle' && _status['mode'] != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('P0 — Audio feasibility spike'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
          IconButton(
            onPressed: () => setState(_lines.clear),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statusCard(),
          _buttons(running),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _lines.length,
              itemBuilder: (context, i) => Text(
                _lines[i].text,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: _lines[i].isTranscript ? Colors.indigo.shade900 : Colors.black87,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard() {
    final s = _status;
    String v(String key) => '${s[key] ?? '-'}';
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('mode=${v('mode')}  chunk=${v('chunkSeconds')}s  threads=${v('threads')}  bỏ chunk=${v('droppedChunks')}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('mic=${v('captureSampleRate')}Hz  audio=${v('audioMs')}ms  pin=${v('batteryPct')}%  FGS=${v('keepAlive')}'),
            Text('SCO=${v('scoOn')}  A2DP=${v('a2dpOn')}  mode=${v('audioMode')}  vol=${v('musicVolume')}'),
            Text('out: ${v('outputs')}', maxLines: 2, overflow: TextOverflow.ellipsis),
            Text('in : ${v('inputs')}', maxLines: 2, overflow: TextOverflow.ellipsis),
            Text('PhoWhisper: ${v('whisperModel')}   Vosk: ${v('voskModel')}'),
            SelectableText('Model dir: ${v('modelsDir')}', style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buttons(bool running) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          FilledButton(
            onPressed: running ? null : () => _call('start', {'engine': 'vosk', 'chunkSeconds': _chunkSeconds}),
            child: const Text('Chạy Vosk'),
          ),
          FilledButton(
            onPressed: running ? null : () => _call('start', {'engine': 'whisper', 'chunkSeconds': _chunkSeconds}),
            child: const Text('Chạy PhoWhisper'),
          ),
          OutlinedButton(
            onPressed: running ? () => _call('stop') : null,
            child: const Text('Dừng'),
          ),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 3, label: Text('chunk 3s')),
              ButtonSegment(value: 5, label: Text('chunk 5s')),
            ],
            selected: {_chunkSeconds},
            onSelectionChanged: (v) => setState(() => _chunkSeconds = v.first),
          ),
          OutlinedButton(
            onPressed: () => _call('speak', {'text': 'Đây là câu kiểm tra phát ra tai nghe.'}),
            child: const Text('Test TTS'),
          ),
          OutlinedButton(
            onPressed: () => _call('keepAlive', {'start': !(_status['keepAlive'] == true)}),
            child: Text(_status['keepAlive'] == true ? 'Tắt FGS' : 'Bật FGS (chạy nền)'),
          ),
        ],
      ),
    );
  }
}
