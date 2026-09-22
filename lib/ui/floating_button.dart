import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';

/// Nút nổi của P3 (task 1 + task 2): **tap** = xin gợi ý, **giữ 2 giây** = Emergency Phrase.
///
/// Vì sao dùng `LongPressGestureRecognizer` với `duration` tuỳ chỉnh thay vì `onLongPress` của
/// `GestureDetector`: `GestureDetector` khoá cứng ngưỡng `kLongPressTimeout` (~500ms) cho long press,
/// còn prompt yêu cầu **đúng 2 giây** (ngắn hơn nữa thì người dùng dễ kích hoạt nhầm câu thoát hiểm).
/// `RawGestureDetector` cho phép truyền `duration` xuống recognizer, nên ngưỡng đúng bằng
/// [holdDuration] tính từ lúc chạm — không cần tự đếm `Timer`.
///
/// Vì sao KHÔNG tự đếm bằng `Timer` (bản đầu tôi viết vậy, đã bỏ): `GestureDetector.onTapDown` chỉ
/// bắn sau `kPressTimeout` (100ms), nên ngưỡng thật thành 2,1 giây; đồng thời phải tự khoá thêm cờ
/// "đã kích hoạt" để một cử chỉ không chạy cả hai đường. Để hai recognizer trong arena tự giải quyết
/// (long press thắng ở mốc 2s ⇒ tap bị loại) là cách chuẩn của Flutter và ít code hơn hẳn.
///
/// Quy tắc chống nhầm lẫn (được khoá bằng `test/floating_button_test.dart`):
/// - Nhả trước [holdDuration] ⇒ chỉ gọi [onSuggest].
/// - Đủ [holdDuration] ⇒ gọi [onEmergency] **một lần**; nhả sau đó **KHÔNG** gọi [onSuggest].
/// - Huỷ cử chỉ (kéo ngón ra ngoài) ⇒ không gọi gì.
class SuggestFloatingButton extends StatefulWidget {
  const SuggestFloatingButton({
    super.key,
    required this.onSuggest,
    required this.onEmergency,
    this.enabled = true,
    this.holdDuration = TriggerConfig.emergencyHold,
  });

  /// Tap ngắn ⇒ xin gợi ý (Push).
  final Future<void> Function() onSuggest;

  /// Giữ đủ [holdDuration] ⇒ Emergency Phrase.
  final Future<void> Function() onEmergency;

  /// `false` ⇒ nút mờ, không nhận cử chỉ (đang bận xử lý lần trước).
  final bool enabled;

  final Duration holdDuration;

  @override
  State<SuggestFloatingButton> createState() => _SuggestFloatingButtonState();
}

class _SuggestFloatingButtonState extends State<SuggestFloatingButton> {
  /// Đang giữ nút nhưng CHƯA tới ngưỡng (dùng cho phản hồi thị giác + chữ hướng dẫn).
  bool _holding = false;

  /// Đã kích hoạt Emergency trong lần giữ hiện tại (để nhả tay không chạy thêm Push).
  bool _emergencyFired = false;

  void _onTapDown() {
    if (!widget.enabled) {
      return;
    }
    setState(() {
      _holding = true;
      _emergencyFired = false;
    });
  }

  void _onTap() {
    setState(() => _holding = false);
    if (!widget.enabled || _emergencyFired) {
      return;
    }
    unawaited(widget.onSuggest());
  }

  void _onCancel() {
    if (mounted) {
      setState(() => _holding = false);
    }
  }

  void _onLongPress() {
    if (!widget.enabled) {
      return;
    }
    // Mốc 2 giây: recognizer long press đã thắng arena ⇒ tap bị loại, không cần chặn gì thêm.
    _emergencyFired = true;
    setState(() => _holding = false);
    unawaited(widget.onEmergency());
  }

  /// Màu chữ/icon tương phản với nền nút. `Material` không có tham số `foregroundColor` như
  /// `FloatingActionButton` nên phải tự đặt cho từng con (bản đầu tôi truyền `foregroundColor`
  /// cho `Material` và `flutter analyze` bắt được).
  Color _foreground(ColorScheme colors) =>
      _highlighted ? colors.onErrorContainer : colors.onPrimaryContainer;

  bool get _highlighted => _holding || _emergencyFired;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    // Cố ý KHÔNG dùng `FloatingActionButton`: nút đó luôn có `InkWell`/recognizer của riêng nó và
    // sẽ TRANH gesture arena với hai recognizer dưới đây, làm ngưỡng giữ 2 giây khó đoán.
    return RawGestureDetector(
      gestures: <Type, GestureRecognizerFactory<GestureRecognizer>>{
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          TapGestureRecognizer.new,
          // Thân dạng khối (không dùng `=> instance..a = b`): các setter đó trả `void`, cascade trên
          // một biểu thức `void` không hợp lệ trong Dart (bản đầu tôi viết vậy — `flutter analyze` bắt).
          (TapGestureRecognizer instance) {
            instance.onTapDown = (TapDownDetails _) => _onTapDown();
            instance.onTap = _onTap;
            instance.onTapCancel = _onCancel;
          },
        ),
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(duration: widget.holdDuration),
          (LongPressGestureRecognizer instance) => instance.onLongPress = _onLongPress,
        ),
      },
      child: Semantics(
        button: true,
        enabled: widget.enabled,
        label: 'Xin gợi ý. Giữ 2 giây để phát câu thoát hiểm.',
        child: Opacity(
          opacity: widget.enabled ? 1 : 0.5,
          child: Material(
            color: _highlighted ? colors.errorContainer : colors.primaryContainer,
            elevation: 6,
            shape: const StadiumBorder(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    _highlighted ? Icons.emergency_outlined : Icons.lightbulb_outline,
                    color: _foreground(colors),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: _foreground(colors),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _label {
    if (_emergencyFired) {
      return 'Đã gửi câu thoát hiểm';
    }
    return _holding ? 'Giữ tiếp để thoát hiểm…' : 'Gợi ý';
  }
}
