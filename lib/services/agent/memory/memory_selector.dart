import 'dart:convert';

import '../model_client.dart';
import 'memory_store.dart';
import 'memory_types.dart';

/// 记忆选择器：用**小模型**从索引清单里挑出与当前请求相关的记忆（最多 N 条）。
/// 对应 Claude Code 的 findRelevantMemories——「廉价模型做选择题」。
class MemorySelector {
  MemorySelector(this.model);

  /// 必须是小模型通道（`ModelClient(settings, small: true)`）。
  final ModelClient model;

  /// 从 [headers] 中选出与 [query] 相关的记忆。
  /// - [manifest]：已格式化的清单文本（`- [type] file (age): desc`）。
  /// - [alreadySurfaced]：本会话已注入过的记忆路径，跳过。
  /// - [recentTools]：最近用过的工具名（暂作为上下文线索，不强制过滤）。
  Future<List<MemoryHeader>> select({
    required String query,
    required List<MemoryHeader> headers,
    required String manifest,
    Set<String> alreadySurfaced = const {},
    List<String> recentTools = const [],
    int maxResults = 5,
  }) async {
    final candidates =
        headers.where((h) => !alreadySurfaced.contains(h.path)).toList();
    if (candidates.isEmpty || query.trim().isEmpty) return [];

    final user = StringBuffer()
      ..writeln('记忆清单：')
      ..writeln(manifest)
      ..writeln()
      ..writeln('当前用户请求：')
      ..writeln(query.trim());
    if (recentTools.isNotEmpty) {
      user
        ..writeln()
        ..writeln('（最近用过的工具：${recentTools.join(', ')}）');
    }
    user
      ..writeln()
      ..writeln('请选出最相关的不超过 $maxResults 条，只输出 JSON。');

    final turn = await model.stream(
      messages: [
        {'role': 'system', 'content': MemoryPrompts.selectionSystem},
        {'role': 'user', 'content': user.toString()},
      ],
      jsonMode: true,
    );

    final chosen = _parseFiles(turn.content);
    if (chosen.isEmpty) return [];

    final byName = {for (final h in candidates) h.filename: h};
    final out = <MemoryHeader>[];
    for (final f in chosen) {
      final h = byName[f] ?? byName[_ensureMd(f)];
      if (h != null && !out.contains(h)) out.add(h);
      if (out.length >= maxResults) break;
    }
    return out;
  }

  String _ensureMd(String f) => f.toLowerCase().endsWith('.md') ? f : '$f.md';

  List<String> _parseFiles(String raw) {
    try {
      final obj = jsonDecode(raw);
      if (obj is Map && obj['files'] is List) {
        return (obj['files'] as List)
            .whereType<String>()
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // 选择器无把握/解析失败时返回空，绝不臆造（不静默兜底）。
    }
    return [];
  }
}
