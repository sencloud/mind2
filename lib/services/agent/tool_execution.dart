import 'dart:convert';

import 'messages.dart';
import 'permissions.dart';
import 'reporter.dart';
import 'tool.dart';
import 'tool_registry.dart';

/// 单个工具调用的完整生命周期：解析参数 → 校验 → 权限 → 执行 → 截断。
class ToolExecutor {
  ToolExecutor({
    required this.registry,
    required this.permissions,
    required this.ctx,
    AgentReporter? reporter,
  }) : reporter = reporter ?? AgentReporter.silent();

  final ToolRegistry registry;
  final Permissions permissions;
  final ToolContext ctx;
  final AgentReporter reporter;

  /// 执行一次工具调用，返回回灌给模型的 tool 消息。
  Future<Map<String, dynamic>> run(ToolCall call) async {
    final result = await _execute(call);
    var content = result.content;
    if (content.length > _maxFor(call.name)) {
      content = '${content.substring(0, _maxFor(call.name))}\n…（结果过长已截断）';
    }
    reporter.onToolEnd?.call(call.id, result.isError, content);
    return Msg.tool(
        toolCallId: call.id,
        content: result.isError ? '错误：$content' : content);
  }

  int _maxFor(String name) => registry.find(name)?.maxResultChars ?? 30000;

  Future<ToolResult> _execute(ToolCall call) async {
    if (ctx.isCancelled()) {
      reporter.onToolStart?.call(call.id, call.name, '已取消');
      return ToolResult.error('已取消。');
    }

    final tool = registry.find(call.name);
    if (tool == null) {
      reporter.onToolStart?.call(call.id, call.name, '未知工具 ${call.name}');
      return ToolResult.error('未知工具：${call.name}');
    }

    Map<String, dynamic> input;
    try {
      final raw = call.arguments.trim();
      input = raw.isEmpty
          ? <String, dynamic>{}
          : (jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      reporter.onToolStart?.call(call.id, tool.name, '${tool.name}（参数错误）');
      return ToolResult.error('参数不是合法 JSON：$e');
    }

    reporter.onToolStart?.call(call.id, tool.name, tool.describeCall(input));

    final validationError = tool.validate(input);
    if (validationError != null) {
      return ToolResult.error('参数校验失败：$validationError');
    }

    final perm = permissions.check(tool, input);
    if (!perm.allowed) {
      return ToolResult.error(perm.reason);
    }

    try {
      return await tool.call(input, ctx);
    } catch (e, st) {
      return ToolResult.error('工具执行异常：$e\n$st');
    }
  }
}
