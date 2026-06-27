import 'dart:convert';

/// 上下文压缩：当对话历史过大时，把较早的工具结果压成占位，控制上下文规模
/// （对应 Claude Code 的 microcompact —— 优先裁剪早期 tool_result）。
/// 这里用「字符数」作为 token 预算的近似代理，足够实验场景使用。
class Compactor {
  Compactor({this.maxChars = 120000, this.keepRecent = 8});

  /// 历史的近似上限（字符）。约 ~3-4 字符/token，120k 字符 ≈ 30-40k token。
  final int maxChars;

  /// 末尾保留不动的消息数（保证近期上下文完整）。
  final int keepRecent;

  /// 返回压缩后的消息列表（system 与最近 keepRecent 条不动）。
  List<Map<String, dynamic>> compact(List<Map<String, dynamic>> messages) {
    var total = _size(messages);
    if (total <= maxChars) return messages;
    final out = List<Map<String, dynamic>>.from(messages);
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
    return out;
  }

  int _size(List<Map<String, dynamic>> messages) =>
      messages.fold(0, (a, e) => a + jsonEncode(e).length);
}
