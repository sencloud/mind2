import '../topic_service.dart';
import 'model_client.dart';
import 'tool.dart';
import 'tool_registry.dart';
import 'tools/bash_tool.dart';
import 'tools/deep_research_tool.dart';
import 'tools/edit_tool.dart';
import 'tools/glob_tool.dart';
import 'tools/grep_tool.dart';
import 'tools/knowledge_search_tool.dart';
import 'tools/read_tool.dart';
import 'tools/subagent_tool.dart';
import 'tools/web_read_tool.dart';
import 'tools/write_tool.dart';

/// 工具集工厂：为给定 agent 类型与递归深度装配 ToolRegistry，
/// 并把 task（子 agent 递归）正确接线。
///
/// 检索范式对齐 Claude Code：不预建语义索引，靠 grep（内容）+ glob（文件名）
/// + read + 子 agent 探索做 agentic search，因此 grep/glob 作为核心工具常驻可用。
class AgentToolset {
  AgentToolset({
    required this.model,
    this.maxDepth = 2,
    this.subAgentMaxTurns = 0,
    this.research,
  });

  final ModelClient model;

  /// 主题研究服务；非空时，顶层 agent 会获得 deep_research 工具。
  final TopicFetchService? research;

  /// 子 agent 最大递归深度（主 agent=0；超过则不再提供 task 工具）。
  final int maxDepth;

  /// 子 agent 的最大轮数（<= 0 表示不限轮数）。
  final int subAgentMaxTurns;

  /// 构建某类 agent 在某深度下的工具注册表。
  ToolRegistry buildRegistry(String agentType, int depth) {
    final tools = <AgentTool>[];

    // 跨模块共享能力（只读、安全）：读网页 + 检索知识库。
    // 让任何 agent（项目/实验/计划/子 agent）都能复用这些模块功能。
    final shared = <AgentTool>[
      WebReadTool(),
      KnowledgeSearchTool(model.settings.vaultPath),
    ];

    if (agentType == 'explore') {
      // 只读探索：检索类工具直接可用。
      tools.addAll([ReadTool(), GlobTool(), GrepTool(), ...shared]);
    } else {
      // 通用：读写执行 + 检索（grep/glob）全部常驻，按需 agentic 检索。
      tools.addAll([
        ReadTool(),
        WriteTool(),
        EditTool(),
        BashTool(),
        GlobTool(),
        GrepTool(),
        ...shared,
      ]);
      // 主题研究较重且不可并发，只给顶层 agent（depth==0）提供，避免子 agent 嵌套触发。
      if (research != null && depth == 0) {
        tools.add(DeepResearchTool(research!));
      }
    }

    if (depth < maxDepth) {
      tools.add(SubAgentTool(toolset: this, depth: depth));
    }

    return ToolRegistry(tools);
  }

  String subAgentSystemPrompt(String agentType) {
    if (agentType == 'explore') {
      return '你是一个只读探索子 agent，运行在某个工程目录内。'
          '用 read_file / glob / grep 把被交代的问题调查清楚，'
          '然后用简洁中文给出结论与关键发现（含相关文件路径）。'
          '不要修改任何文件。调查完成后停止调用任何工具即代表结束。';
    }
    return '你是一个能动手的子 agent，运行在某个工程目录内，可读写文件并用 bash 执行命令。'
        '独立完成被交代的子任务，必要时真正运行验证；'
        '完成后用简洁中文汇报结果与结论，并停止调用任何工具即代表结束。';
  }
}
