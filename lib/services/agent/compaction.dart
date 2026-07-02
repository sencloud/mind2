import 'dart:convert';

/// 上下文压缩：当对话历史过大时，把较早的工具结果压成占位，控制上下文规模
/// （对应 Claude Code 的 microcompact —— 优先裁剪早期 tool_result）。
/// 这里用「字符数」作为 token 预算的近似代理，足够实验场景使用。
///
/// 与工作记事板联动（GenericAgent 的 working checkpoint）：
/// 压缩发生时，把 Agent 自己维护的最新记事板以 system-reminder 追加在末尾，
/// 保证早期中间结论被裁掉后仍能延续。
class Compactor {
  Compactor({this.maxChars = 120000, this.keepRecent = 8});

  /// 历史的近似上限（字符）。约 ~3-4 字符/token，120k 字符 ≈ 30-40k token。
  final int maxChars;

  /// 末尾保留不动的消息数（保证近期上下文完整）。
  final int keepRecent;

  /// 记事板注入消息的识别标记（避免重复注入；transcriptText 也据此过滤）。
  static const checkpointMarker = '<!--working-checkpoint-->';

  /// 返回压缩后的消息列表（system 与最近 keepRecent 条不动）。
  /// [checkpoint] 非空时，压缩发生后会把它作为 system-reminder 追加到末尾。
  List<Map<String, dynamic>> compact(
    List<Map<String, dynamic>> messages, {
    String checkpoint = '',
  }) {
    var total = _size(messages);
    if (total <= maxChars) return messages;

    // 先移除上一轮注入的旧记事板消息（user 角色，可安全移除，不破坏 tool 配对）。
    final out = messages
        .where((m) => !(m['role'] == 'user' &&
            (m['content'] ?? '').toString().startsWith(checkpointMarker)))
        .toList();
    total = _size(out);

    final limit = out.length - keepRecent;
    for (var i = 1; i < limit && total > maxChars; i++) {
      final m = out[i];
      if (m['role'] != 'tool') continue;
      final c = (m['content'] ?? '').toString();
      if (c.length <= 200) continue;
      final trimmed = '${c.substring(0, 160)}\n…（早期工具结果已压缩，如需可重新读取）';
      total -= (c.length - trimmed.length);
      out[i] = {...m, 'content': trimmed};
    }

    // 压缩后追加最新记事板：放在末尾（此时最后一批 tool 结果已完整，插入合法）。
    if (checkpoint.trim().isNotEmpty) {
      out.add({
        'role': 'user',
        'content': '$checkpointMarker<system-reminder>\n'
            '上下文已压缩。以下是你自己维护的最新工作记事板：\n\n'
            '${checkpoint.trim()}\n</system-reminder>',
      });
    }
    return out;
  }

  int _size(List<Map<String, dynamic>> messages) =>
      messages.fold(0, (a, e) => a + jsonEncode(e).length);
}
