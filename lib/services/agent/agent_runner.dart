import 'dart:io';

import 'agent_loop.dart';
import 'memory/memory_service.dart';
import 'memory/memory_store.dart';
import 'messages.dart';
import 'model_client.dart';
import 'permissions.dart';
import 'reporter.dart';
import 'tool.dart';
import 'tool_execution.dart';
import 'toolset.dart';

/// 统一的 Agent 内核：把"做实验/项目开发"中重复的
/// `ToolContext → AgentToolset → ToolExecutor(Permissions) → AgentLoop.run` 接线收敛到一处，
/// 并内置「回忆(前) + 抽取(后)」记忆钩子与静态指令层（全局规则 + 项目 AGENTS.md）。
///
/// 领域 service 只负责组织领域 system prompt / 任务消息，再调用本类。
class AgentRunner {
  AgentRunner({required this.model, required this.memory});

  final ModelClient model;
  final MemoryService memory;

  /// 跑一次完整会话（含记忆回忆与抽取）。
  ///
  /// - [systemPrompt]：领域 system prompt（会叠加静态指令层与记忆索引）。
  /// - [initialMessages]：领域任务消息（如已构造好的 user 任务）。
  /// - [recallQuery]：用于挑选相关记忆的查询文本（一般即任务本身）。
  /// - [projectStore]：项目记忆库；为空表示只用全局库。
  Future<AgentResult> run({
    required Directory dir,
    required String systemPrompt,
    required List<Map<String, dynamic>> initialMessages,
    required String recallQuery,
    required AgentReporter reporter,
    required bool Function() isCancelled,
    MemoryStore? projectStore,
    bool enableMemory = true,
    bool extractMemory = true,
    Set<String> alreadySurfaced = const {},
    int maxTurns = 0,
    int maxDepth = 2,
    int subAgentMaxTurns = 0,
    void Function(String line)? log,
  }) async {
    final logFn = log ?? reporter.onStatus ?? (_) {};

    // ① system prompt = 领域 prompt + 静态指令层 + 记忆索引（叠加非覆盖）。
    var sys = systemPrompt;
    final staticLayer = await memory.staticInstructions(dir);
    if (staticLayer.isNotEmpty) sys = '$sys\n\n$staticLayer';
    if (enableMemory) {
      final instr = await memory.instructions(project: projectStore);
      if (instr.isNotEmpty) sys = '$sys\n\n$instr';
    }

    // ② 行动前回忆：小模型选相关记忆，作为会话开头的 system-reminder 注入。
    final msgs = <Map<String, dynamic>>[...initialMessages];
    if (enableMemory) {
      try {
        final recall = await memory.recall(
          query: recallQuery,
          project: projectStore,
          alreadySurfaced: alreadySurfaced,
        );
        if (!recall.isEmpty) msgs.add(Msg.user(recall.injection));
      } catch (e) {
        logFn('记忆回忆失败（不影响执行）：$e');
      }
    }

    // ③ 组装工具内核并运行多轮循环。
    final ctx = ToolContext(
      projectDir: dir,
      log: logFn,
      isCancelled: isCancelled,
    );
    final toolset = AgentToolset(
      model: model,
      maxDepth: maxDepth,
      subAgentMaxTurns: subAgentMaxTurns,
    );
    final registry = toolset.buildRegistry('general', 0);
    final executor = ToolExecutor(
      registry: registry,
      permissions: Permissions(dir.path),
      ctx: ctx,
      reporter: reporter,
    );
    final loop = AgentLoop(
      model: model,
      registry: registry,
      executor: executor,
      maxTurns: maxTurns,
    );
    final result = await loop.run(
      systemPrompt: sys,
      initialMessages: msgs,
      reporter: reporter,
      isCancelled: isCancelled,
    );

    // ④ 行动后抽取：按四类型抽取并路由到全局/项目库。
    if (enableMemory && extractMemory && !isCancelled()) {
      try {
        await memory.extract(
          transcript: transcriptText(result.messages),
          project: projectStore,
        );
      } catch (e) {
        logFn('记忆抽取失败（不影响结果）：$e');
      }
    }

    return result;
  }

  /// 把对话记录压成纯文本转写，供记忆抽取使用。
  static String transcriptText(List<Map<String, dynamic>> messages) {
    final buf = StringBuffer();
    for (final m in messages) {
      final role = m['role'];
      if (role == 'system') continue;
      if (role == 'assistant') {
        final c = (m['content'] ?? '').toString().trim();
        if (c.isNotEmpty) buf.writeln('[助手] $c');
        final calls = m['tool_calls'];
        if (calls is List) {
          for (final call in calls) {
            final fn = (call as Map)['function'] as Map?;
            buf.writeln(
                '[调用] ${fn?['name']} ${_clip('${fn?['arguments']}', 160)}');
          }
        }
      } else if (role == 'tool') {
        buf.writeln('[结果] ${_clip('${m['content']}', 500)}');
      } else if (role == 'user') {
        buf.writeln('[用户] ${_clip('${m['content']}', 300)}');
      }
    }
    return buf.toString();
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
