import 'dart:io';

import 'memory_store.dart';
import 'memory_types.dart';

/// 记忆注入：把选中的记忆正文包进 `<system-reminder>`，并加上**时间感知**的
/// 老化警告（移植 Claude Code 的 memoryAge）。会话开头以一条 user 消息注入。
class MemoryInjector {
  /// 距今天数（向下取整，今天=0）。
  static int ageDays(int mtimeMs) {
    final diff = DateTime.now().millisecondsSinceEpoch - mtimeMs;
    if (diff <= 0) return 0;
    return (diff / 86400000).floor();
  }

  /// 可读的"多久以前"。
  static String age(int mtimeMs) {
    final days = ageDays(mtimeMs);
    if (days <= 0) return '今天';
    if (days == 1) return '昨天';
    if (days < 30) return '$days 天前';
    if (days < 365) return '${(days / 30).floor()} 个月前';
    return '${(days / 365).floor()} 年前';
  }

  /// 新鲜度提示：超过 1 天的记忆附 stale 警告。
  static String freshnessText(int mtimeMs) {
    final days = ageDays(mtimeMs);
    if (days <= 1) return '记于${age(mtimeMs)}';
    return '记于${age(mtimeMs)}，可能已过时——使用前请先核实';
  }

  /// 组装注入文本。读取每条选中记忆的正文，按新鲜度排版。
  /// 返回空串表示无可注入。
  static Future<String> build(List<MemoryHeader> headers) async {
    if (headers.isEmpty) return '';
    final buf = StringBuffer()
      ..writeln('<system-reminder>')
      ..writeln('以下是与当前任务可能相关的长期记忆（过去的快照，用前请核实）：')
      ..writeln();
    var any = false;
    for (final h in headers) {
      String? body;
      try {
        body = await File(h.path).readAsString();
      } catch (_) {
        body = null;
      }
      if (body == null || body.trim().isEmpty) continue;
      any = true;
      buf
        ..writeln('### ${h.name}  [${h.type.id}] · ${freshnessText(h.mtimeMs)}')
        ..writeln(body.trim())
        ..writeln();
    }
    buf.write('</system-reminder>');
    return any ? buf.toString() : '';
  }
}
