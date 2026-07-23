import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'agent/agent_event.dart';
import 'agent/agent_loop.dart';
import 'agent/agent_runner.dart';
import 'agent/memory/memory_service.dart';
import 'agent/messages.dart';
import 'agent/model_client.dart';
import 'agent/prompts.dart';
import 'agent/reporter.dart';
import 'settings_service.dart';

/// 「做实验」：在用户给定的工程路径下，由第二大脑以 **Agent 模式真正动手**
/// 完成实验——自己写代码、装依赖、运行程序、读报错、修复，循环直到实验跑通。
///
/// 本版本基于复刻自 Claude Code 的通用 agent 内核（lib/services/agent/）：
/// 原生 Function Calling 工具调用（read/write/edit/glob/grep/bash）、统一执行管道、
/// 工程目录权限限定、SSE 流式输出。退出条件为「模型不再调用任何工具」。
///
/// 记忆体系（参考 Claude Code）：统一走 [AgentRunner] 的「回忆(前)+抽取(后)」钩子——
/// 行动前由小模型从索引里选相关记忆并注入，行动后按四类型抽取结构化记忆落盘到
/// 实验工程目录下的 `memory/`（含 `MEMORY.md` 索引）；跨功能的用户画像写入全局库。
/// 「审题/澄清」结果：模型对实验与报告关系的理解，以及需向用户确认的问题。
class ExperimentClarification {
  ExperimentClarification({required this.understanding, required this.questions});

  final String understanding;
  final List<String> questions;

  /// 是否需要先向用户确认（有待澄清的问题）。
  bool get needsInput => questions.isNotEmpty;
}

class ExperimentService extends ChangeNotifier {
  ExperimentService(this.settings, this.memory)
      : _model = ModelClient(settings) {
    _runner = AgentRunner(model: _model, memory: memory);
  }

  final SettingsService settings;
  final MemoryService memory;
  final ModelClient _model;
  late final AgentRunner _runner;

  bool running = false;

  /// 结构化运行事件（状态 / 助手文本 / 工具调用），供 UI 以卡片形式渲染。
  final List<AgentEvent> events = [];

  bool _cancel = false;

  /// 正在流式生成的助手文本事件 + 各工具调用事件（按 callId 索引）。
  AgentEvent? _streaming;
  final Map<String, AgentEvent> _toolEvents = {};

  final Map<String, String> _projects = {};
  File? _store;

  // 0 = 不限轮数：实验只在「任务完成」或「用户手动停止」时结束。
  static const _maxTurns = 0;

  void _status(String m) {
    events.add(AgentEvent.status(m));
    notifyListeners();
  }

  Future<void> init() async {
    try {
      final base = await getApplicationSupportDirectory();
      _store = File('${base.path}\\experiments.json');
      if (await _store!.exists()) {
        final data = jsonDecode(await _store!.readAsString());
        if (data is Map) {
          _projects.addAll(
              data.map((k, v) => MapEntry(k.toString(), v.toString())));
        }
      }
    } catch (_) {}
  }

  String? projectFor(String key) {
    final p = _projects[key];
    if (p == null) return null;
    return Directory(p).existsSync() ? p : null;
  }

  Future<void> _recordProject(String key, String path) async {
    _projects[key] = path;
    notifyListeners();
    try {
      await _store?.writeAsString(jsonEncode(_projects));
    } catch (_) {}
  }

  /// 审题/澄清：动手前先判断实验目标是否清晰、是否紧扣报告。
  /// 返回模型的理解与（可能的）需向用户确认的问题；问题非空表示应先问用户再开始。
  Future<ExperimentClarification> clarify({
    required String objective,
    required String reportContent,
  }) async {
    final turn = await _model.stream(
      messages: [
        Msg.system(ExperimentPrompts.clarifySystem()),
        Msg.user(ExperimentPrompts.clarifyTask(objective, reportContent)),
      ],
      jsonMode: true,
      isCancelled: () => false,
    );
    final m = _parseJson(turn.content);
    final understanding = (m?['understanding'] as String? ?? '').trim();
    final questions = ((m?['questions'] as List?) ?? const [])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return ExperimentClarification(
        understanding: understanding, questions: questions);
  }

  /// 请求中止当前 agent 循环（在下一步生效）。
  void cancel() {
    if (running) {
      _cancel = true;
      _status('⏹ 收到停止请求，将在当前步骤后结束…');
    }
  }

  Future<String> run({
    required String objective,
    required String projectPath,
    String context = '',
    String? memoryKey,
  }) async {
    return _session(
      projectPath: '$projectPath\\${_folderName(objective)}',
      isNew: true,
      task: objective,
      context: context,
      memoryKey: memoryKey,
    );
  }

  Future<String> continueRun({
    required String instruction,
    required String projectPath,
    String context = '',
    String? memoryKey,
  }) async {
    return _session(
      projectPath: projectPath,
      isNew: false,
      task: instruction,
      context: context,
      memoryKey: memoryKey,
    );
  }

  // ---------------------------------------------------------------------------
  // 一次完整会话：回忆 → agent 循环执行 → 写回记忆
  // ---------------------------------------------------------------------------

  Future<String> _session({
    required String projectPath,
    required bool isNew,
    required String task,
    required String context,
    String? memoryKey,
  }) async {
    if (running) throw StateError('已有实验在进行中');
    running = true;
    _cancel = false;
    events.clear();
    _streaming = null;
    _toolEvents.clear();
    notifyListeners();
    final dir = Directory(projectPath);
    try {
      await dir.create(recursive: true);
      if (memoryKey != null) await _recordProject(memoryKey, dir.path);

      final reporter = _buildReporter();

      // agent 循环（内置回忆与抽取记忆钩子）：真正写代码、跑程序、修报错。
      final result =
          await _runAgent(dir: dir, task: task, context: context, reporter: reporter);

      // 实验收尾自检：用 explore 子 agent 审计目录整洁度，再清理多余文件、规整结构。
      if (!_cancel && result.reason != AgentStopReason.aborted) {
        _status('实验收尾自检：检查目录整洁度并清理多余文件…');
        await _wrapUp(dir: dir, reporter: reporter);
      }

      final tip = switch (result.reason) {
        AgentStopReason.completed => '✅ 实验完成',
        AgentStopReason.maxTurns => '⚠ 达最大轮数停止',
        AgentStopReason.aborted => '⏹ 已中止',
        AgentStopReason.error => '✖ 因错误结束',
      };
      _status('$tip · 工程位于 ${dir.path}');
      return dir.path;
    } finally {
      running = false;
      _cancel = false;
      _streaming = null;
      notifyListeners();
    }
  }

  Future<AgentResult> _runAgent({
    required Directory dir,
    required String task,
    required String context,
    required AgentReporter reporter,
  }) async {
    return _runner.run(
      dir: dir,
      systemPrompt: ExperimentPrompts.system(),
      initialMessages: [Msg.user(ExperimentPrompts.task(task, context, ''))],
      recallQuery: task,
      reporter: reporter,
      isCancelled: () => _cancel,
      projectStore: memory.projectStore('${dir.path}\\memory'),
      maxTurns: _maxTurns,
      subAgentMaxTurns: _maxTurns,
      log: _status,
    );
  }

  /// 收尾自检：先用 explore 子 agent 审计目录整洁度，再清理多余/临时文件、规整结构。
  /// 收尾不参与记忆回忆/抽取（属于清理动作，避免污染记忆）。
  Future<void> _wrapUp({
    required Directory dir,
    required AgentReporter reporter,
  }) async {
    await _runner.run(
      dir: dir,
      systemPrompt: ExperimentPrompts.wrapUpSystem(),
      initialMessages: [Msg.user(ExperimentPrompts.wrapUpTask())],
      recallQuery: '',
      reporter: reporter,
      isCancelled: () => _cancel,
      enableMemory: false,
      extractMemory: false,
      maxTurns: _maxTurns,
      subAgentMaxTurns: _maxTurns,
      log: _status,
    );
  }

  AgentReporter _buildReporter() => AgentReporter(
        onStatus: _status,
        onAssistantDelta: (delta) {
          final e = _streaming ??= _push(AgentEvent.assistant(''));
          e.text += delta;
          notifyListeners();
        },
        onAssistantText: (full) {
          final e = _streaming;
          if (e != null) {
            e.text = full;
            e.status = StepStatus.done;
          } else {
            _push(AgentEvent.assistant(full)..status = StepStatus.done);
          }
          _streaming = null;
          notifyListeners();
        },
        onToolStart: (id, tool, title) {
          _streaming?.status = StepStatus.done;
          _streaming = null;
          final e = _push(AgentEvent.tool(tool: tool, title: title));
          _toolEvents[id] = e;
          notifyListeners();
        },
        onToolEnd: (id, isError, result) {
          final e = _toolEvents[id];
          if (e != null) {
            e.status = isError ? StepStatus.error : StepStatus.done;
            e.detail = result;
            notifyListeners();
          }
        },
      );

  AgentEvent _push(AgentEvent e) {
    events.add(e);
    return e;
  }

  // ---------------------------------------------------------------------------
  // 工具方法
  // ---------------------------------------------------------------------------

  /// 容错版 JSON 提取：复用 [ModelClient.parseJsonObject]，解析失败返回 null。
  Map<String, dynamic>? _parseJson(String reply) {
    try {
      return ModelClient.parseJsonObject(reply);
    } catch (_) {
      return null;
    }
  }

  static String _stamp() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${p(n.month)}${p(n.day)}-${p(n.hour)}${p(n.minute)}${p(n.second)}';
  }

  static String _folderName(String objective) {
    var out = objective.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_').trim();
    if (out.length > 40) out = out.substring(0, 40);
    if (out.isEmpty) out = 'experiment';
    return '$out-${_stamp()}';
  }
}
