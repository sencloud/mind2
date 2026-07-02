import 'compaction.dart';
import 'messages.dart';
import 'model_client.dart';
import 'reporter.dart';
import 'tool_execution.dart';
import 'tool_orchestration.dart';
import 'tool_registry.dart';

enum AgentStopReason { completed, maxTurns, aborted, error }

/// 一次 agent 会话的结果。
class AgentResult {
  AgentResult({
    required this.reason,
    required this.lastText,
    required this.turns,
    required this.messages,
  });

  final AgentStopReason reason;
  final String lastText;
  final int turns;

  /// 完整对话记录（含 system），用于记忆蒸馏或续跑。
  final List<Map<String, dynamic>> messages;
}

/// Agent 主循环：多轮「调模型 → 执行工具 → 回灌结果」，
/// 直到模型不再调用工具（completed）或被取消（aborted）。
/// [maxTurns] <= 0 表示不限轮数（仅在任务完成或被取消时结束）。
class AgentLoop {
  AgentLoop({
    required this.model,
    required this.registry,
    required this.executor,
    this.maxTurns = 0,
    this.checkpoint,
  })  : _orchestrator =
            ToolOrchestrator(registry: registry, executor: executor),
        _compactor = Compactor();

  final ModelClient model;
  final ToolRegistry registry;
  final ToolExecutor executor;
  final int maxTurns;

  /// 工作记事板读取器（来自 ToolContext）；压缩发生时由 Compactor 保留其内容。
  final String Function()? checkpoint;

  final ToolOrchestrator _orchestrator;
  final Compactor _compactor;

  Future<AgentResult> run({
    required String systemPrompt,
    required List<Map<String, dynamic>> initialMessages,
    required AgentReporter reporter,
    required bool Function() isCancelled,
  }) async {
    var messages = <Map<String, dynamic>>[
      Msg.system(systemPrompt),
      ...initialMessages,
    ];
    var turn = 0;
    var lastText = '';

    while (true) {
      if (isCancelled()) {
        return AgentResult(
            reason: AgentStopReason.aborted,
            lastText: lastText,
            turns: turn,
            messages: messages);
      }
      turn++;

      messages =
          _compactor.compact(messages, checkpoint: checkpoint?.call() ?? '');
      final tools = registry.toApiSchema();

      AssistantTurn t;
      try {
        t = await model.stream(
          messages: messages,
          tools: tools,
          isCancelled: isCancelled,
          onTextDelta: reporter.onAssistantDelta,
        );
      } catch (e) {
        reporter.onStatus?.call('模型调用失败：$e');
        return AgentResult(
            reason: AgentStopReason.error,
            lastText: lastText,
            turns: turn,
            messages: messages);
      }

      if (t.content.trim().isNotEmpty) {
        lastText = t.content;
        reporter.onAssistantText?.call(t.content);
      }
      messages.add(t.toApi());

      if (!t.hasToolCalls) {
        return AgentResult(
            reason: AgentStopReason.completed,
            lastText: lastText,
            turns: turn,
            messages: messages);
      }

      // 并发安全的只读工具并行执行，写操作串行；按原顺序回填，避免孤立 tool_call。
      final toolMessages =
          await _orchestrator.run(t.toolCalls, isCancelled: isCancelled);
      messages.addAll(toolMessages);
      if (isCancelled()) {
        return AgentResult(
            reason: AgentStopReason.aborted,
            lastText: lastText,
            turns: turn,
            messages: messages);
      }

      if (maxTurns > 0 && turn >= maxTurns) {
        reporter.onStatus?.call('已达最大轮数 $maxTurns，停止。');
        return AgentResult(
            reason: AgentStopReason.maxTurns,
            lastText: lastText,
            turns: turn,
            messages: messages);
      }
    }
  }
}
