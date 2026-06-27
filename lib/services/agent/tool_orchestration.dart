import 'messages.dart';
import 'tool_execution.dart';
import 'tool_registry.dart';

/// 工具编排：把连续的「并发安全（只读）」工具调用并行执行，其余串行，
/// 并按原始顺序返回 tool 结果消息（对应 Claude Code 的 partitionToolCalls）。
class ToolOrchestrator {
  ToolOrchestrator({
    required this.registry,
    required this.executor,
    this.maxConcurrency = 6,
  });

  final ToolRegistry registry;
  final ToolExecutor executor;
  final int maxConcurrency;

  Future<List<Map<String, dynamic>>> run(
    List<ToolCall> calls, {
    required bool Function() isCancelled,
  }) async {
    final results = List<Map<String, dynamic>?>.filled(calls.length, null);
    var i = 0;
    while (i < calls.length) {
      if (isCancelled()) {
        for (var j = i; j < calls.length; j++) {
          results[j] = Msg.tool(toolCallId: calls[j].id, content: '已取消。');
        }
        break;
      }
      if (!_isSafe(calls[i])) {
        results[i] = await executor.run(calls[i]);
        i++;
        continue;
      }
      // 收集连续的并发安全调用并并行执行。
      final batch = <int>[];
      while (i < calls.length &&
          _isSafe(calls[i]) &&
          batch.length < maxConcurrency) {
        batch.add(i);
        i++;
      }
      final res = await Future.wait(batch.map((idx) => executor.run(calls[idx])));
      for (var k = 0; k < batch.length; k++) {
        results[batch[k]] = res[k];
      }
    }
    return [
      for (var k = 0; k < calls.length; k++)
        results[k] ?? Msg.tool(toolCallId: calls[k].id, content: '已取消。'),
    ];
  }

  bool _isSafe(ToolCall c) => registry.find(c.name)?.isConcurrencySafe ?? false;
}
