import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 统一的「回车发送、Ctrl/Shift+回车换行」按键处理。
///
/// 用法：把多行输入框（[TextField] 等）作为 [child] 包进来。
/// - 单独按回车（不带修饰键）：触发 [onSubmit]，相当于发送。
/// - 按住 Ctrl 或 Shift 再回车：交还给输入框，正常换行。
///
/// 这样全局所有「输入内容并发送」的对话框就有一致的操作逻辑。
class EnterToSend extends StatelessWidget {
  const EnterToSend({
    super.key,
    required this.onSubmit,
    required this.child,
    this.enabled = true,
  });

  /// 回车（无修饰键）时执行的发送动作。
  final VoidCallback onSubmit;

  /// 被包裹的输入框。
  final Widget child;

  /// 是否启用回车发送；忙碌/禁用时传 false，回车不发送。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Focus(
      // 只拦截回车键，其余按键一律放行给输入框。
      onKeyEvent: (node, event) {
        if (!enabled) return KeyEventResult.ignored;
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter) {
          return KeyEventResult.ignored;
        }
        // 判断此刻是否按住了 Ctrl / Shift，按住则表示用户想换行。
        final keys = HardwareKeyboard.instance.logicalKeysPressed;
        final newline =
            keys.contains(LogicalKeyboardKey.controlLeft) ||
            keys.contains(LogicalKeyboardKey.controlRight) ||
            keys.contains(LogicalKeyboardKey.shiftLeft) ||
            keys.contains(LogicalKeyboardKey.shiftRight);
        if (newline) return KeyEventResult.ignored; // 交给输入框换行
        onSubmit();
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}
