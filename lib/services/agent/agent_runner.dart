import 'dart:io';

import 'agent_loop.dart';
import 'compaction.dart';
import 'memory/memory_service.dart';
import 'memory/memory_store.dart';
import 'memory/memory_types.dart';
import 'messages.dart';
import 'model_client.dart';
import '../topic_service.dart';
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
  AgentRunner({required this.model, required this.memory, this.research});

  final ModelClient model;
  final MemoryService memory;

  /// 可选的主题研究服务；传入后 agent 将获得 deep_research 工具。
  final TopicFetchService? research;

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

    // ① system prompt = 领域 prompt + 静态指令层 + 自进化守则 + 记忆索引（叠加非覆盖）。
    var sys = systemPrompt;
    final staticLayer = await memory.staticInstructions(dir);
    if (staticLayer.isNotEmpty) sys = '$sys\n\n$staticLayer';
    // L0 补充：技能 SOP 使用纪律 + 工作记事板守则。
    sys = '$sys\n\n${MemoryPrompts.evolutionGuide}';
    if (enableMemory) {
      final instr = await memory.instructions(project: projectStore);
      if (instr.isNotEmpty) sys = '$sys\n\n$instr';
    }

    // ② 行动前回忆：小模型选相关记忆，作为会话开头的 system-reminder 注入。
    final msgs = <Map<String, dynamic>>[...initialMessages];
    var memoryHit = false;
    if (enableMemory) {
      try {
        final recall = await memory.recall(
          query: recallQuery,
          project: projectStore,
          alreadySurfaced: alreadySurfaced,
        );
        if (!recall.isEmpty) {
          msgs.add(Msg.user(recall.injection));
          memoryHit = true;
        }
      } catch (e) {
        logFn('记忆回忆失败（不影响执行）：$e');
      }
    }

    // ②b 技能召回（L3）：匹配 SKILLS.md 索引，注入 1-2 条同类任务 SOP。
    var skillHit = false;
    if (enableMemory) {
      try {
        final sr = await memory.recallSkills(query: recallQuery);
        if (!sr.isEmpty) {
          msgs.add(Msg.user(sr.injection));
          skillHit = true;
          // 以工具卡片形式上报"命中技能"，三个领域 UI 无需改动即可展示。
          final id = 'skill-hit-${DateTime.now().microsecondsSinceEpoch}';
          reporter.onToolStart
              ?.call(id, 'skill', '命中技能：${sr.names.join('、')}');
          reporter.onToolEnd?.call(
              id, false, '已注入 ${sr.names.length} 条技能 SOP，agent 将优先按此执行。');
        }
      } catch (e) {
        logFn('技能召回失败（不影响执行）：$e');
      }
    }

    // ②c 归档召回（L4，最低优先级）：仅当 L2/L3 均无命中时才尝试长程回忆。
    if (enableMemory && !memoryHit && !skillHit) {
      try {
        final inj = await memory.recallArchive(query: recallQuery);
        if (inj.isNotEmpty) msgs.add(Msg.user(inj));
      } catch (e) {
        logFn('归档召回失败（不影响执行）：$e');
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
      research: research,
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
      // 上下文压缩时保留 agent 自己维护的工作记事板。
      checkpoint: () => ctx.workingCheckpoint,
    );
    final result = await loop.run(
      systemPrompt: sys,
      initialMessages: msgs,
      reporter: reporter,
      isCancelled: isCancelled,
    );

    // ④ 行动后抽取：按四类型抽取并路由到全局/项目库。
    if (enableMemory && extractMemory && !isCancelled()) {
      final transcript = transcriptText(result.messages);
      try {
        await memory.extract(
          transcript: transcript,
          project: projectStore,
        );
      } catch (e) {
        logFn('记忆抽取失败（不影响结果）：$e');
      }

      // ⑤ 技能沉淀（L3）：仅任务成功结束时，小模型判断是否值得固化为 SOP。
      if (result.reason == AgentStopReason.completed) {
        try {
          final name = await memory.crystallizeSkill(
            task: recallQuery,
            transcript: transcript,
          );
          if (name != null) logFn('已沉淀技能：$name');
        } catch (e) {
          logFn('技能沉淀失败（不影响结果）：$e');
        }
      }

      // ⑥ 会话归档（L4）：无论成败都留一条简短记录，供长程回忆。
      try {
        final outcome = switch (result.reason) {
          AgentStopReason.completed => '成功完成',
          AgentStopReason.maxTurns => '达最大轮数停止',
          AgentStopReason.error => '因错误结束',
          AgentStopReason.aborted => '被中止',
        };
        await memory.archiveSession(
          task: recallQuery,
          transcript: transcript,
          outcome: outcome,
        );
      } catch (e) {
        logFn('会话归档失败（不影响结果）：$e');
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
        final c = (m['content'] ?? '').toString();
        // 跳过运行时注入的记忆/技能/归档提示与记事板消息：它们不是用户说的话，
        // 混进转写会让抽取器把旧记忆当新信息重复抽取（自我强化循环）。
        if (c.startsWith('<system-reminder>') ||
            c.startsWith(Compactor.checkpointMarker)) {
          continue;
        }
        buf.writeln('[用户] ${_clip(c, 300)}');
      }
    }
    return buf.toString();
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
