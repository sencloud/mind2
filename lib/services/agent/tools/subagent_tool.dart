import '../agent_loop.dart';
import '../messages.dart';
import '../permissions.dart';
import '../reporter.dart';
import '../tool.dart';
import '../tool_execution.dart';
import '../toolset.dart';

/// 子 agent 工具（对应 Claude Code 的 AgentTool）：把一个明确、可独立交付的
/// 子任务委派给一个拥有独立上下文与工具的嵌套 agent，完成后只把结论返回给父 agent。
/// 通过 [AgentToolset] 递归构建子工具集，并由深度上限防止无限递归。
class SubAgentTool extends AgentTool {
  SubAgentTool({required this.toolset, required this.depth});

  /// 用于构建子 agent 工具集的工厂。
  final AgentToolset toolset;

  /// 父 agent 的深度（子 agent 为 depth+1）。
  final int depth;

  @override
  String get name => 'task';

  @override
  String get description =>
      '启动一个子 agent 自主完成一个明确、可独立交付的子任务。它拥有独立的上下文与工具，'
      '完成后只把结论返回给你——适合：探索工程/定位问题、独立跑通某个子实验，从而保持你自己的上下文清爽。\n'
      'agent_type：explore=只读探索（read_file/glob/grep，不改文件）；general=可读写并执行命令。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'description': {'type': 'string', 'description': '子任务的一句话标题'},
          'prompt': {
            'type': 'string',
            'description': '交给子 agent 的完整任务说明。子 agent 看不到你的上下文，请写成自包含的。',
          },
          'agent_type': {
            'type': 'string',
            'enum': ['explore', 'general'],
            'description': '子 agent 类型，默认 general',
          },
        },
        'required': ['prompt'],
      };

  @override
  String describeCall(Map<String, dynamic> input) =>
      '委派子任务：${input['description'] ?? input['prompt']}';

  @override
  Future<ToolResult> call(Map<String, dynamic> input, ToolContext ctx) async {
    final agentType = (input['agent_type'] ?? 'general').toString();
    final prompt = (input['prompt'] ?? '').toString().trim();
    if (prompt.isEmpty) return ToolResult.error('缺少 prompt。');

    final childDepth = depth + 1;
    final title = (input['description'] ?? prompt).toString();
    ctx.log('  ↪ 启动子 agent[$agentType]（深度 $childDepth）：$title');

    final registry = toolset.buildRegistry(agentType, childDepth);
    final childCtx = ToolContext(
      projectDir: ctx.projectDir,
      log: ctx.log,
      isCancelled: ctx.isCancelled,
      depth: childDepth,
    );
    final executor = ToolExecutor(
      registry: registry,
      permissions: Permissions(ctx.root),
      ctx: childCtx,
    );
    final loop = AgentLoop(
      model: toolset.model,
      registry: registry,
      executor: executor,
      maxTurns: toolset.subAgentMaxTurns,
      checkpoint: () => childCtx.workingCheckpoint,
    );

    final result = await loop.run(
      systemPrompt: toolset.subAgentSystemPrompt(agentType),
      initialMessages: [Msg.user(prompt)],
      reporter: AgentReporter.silent(),
      isCancelled: ctx.isCancelled,
    );

    final text = result.lastText.trim();
    final body = text.isEmpty ? '（子 agent 未给出文本结论）' : text;
    return ToolResult(
        '子 agent[$agentType] 完成（${result.reason.name}，${result.turns} 轮）：\n$body');
  }
}
