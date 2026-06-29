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
import 'agent/reporter.dart';
import 'settings_service.dart';
import 'topic_service.dart';

/// 单个待办事项的 AI 执行状态。
enum PlanStatus { idle, running, success, error }

/// 一个「计划」待办事项：既是普通 todo（可勾选完成），
/// 又可交给第二大脑以 Agent 模式真正动手执行。
class PlanTodo {
  PlanTodo({
    required this.id,
    required this.title,
    required this.createdAt,
    this.done = false,
    this.status = PlanStatus.idle,
    this.result = '',
    this.workdir,
  });

  final String id;
  String title; // 待办内容 / 要执行的任务
  final DateTime createdAt;
  bool done; // 普通 todo 的手动完成勾选
  PlanStatus status; // AI 执行状态
  String result; // AI 执行的最终总结（Markdown）
  String? workdir; // AI 执行所用的工作目录

  /// 运行期：AI 执行过程的结构化事件（不持久化，仅当前会话展示）。
  final List<AgentEvent> events = [];

  bool get running => status == PlanStatus.running;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'done': done,
        'status': status.name,
        'result': result,
        'workdir': workdir,
      };

  factory PlanTodo.fromJson(Map<String, dynamic> j) => PlanTodo(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        createdAt:
            DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
        done: j['done'] as bool? ?? false,
        // 上次未跑完的状态不恢复为 running（进程已结束），统一归位 idle。
        status: PlanStatus.values.firstWhere(
          (s) => s.name == j['status'] && s != PlanStatus.running,
          orElse: () => PlanStatus.idle,
        ),
        result: j['result'] as String? ?? '',
        workdir: j['workdir'] as String?,
      );
}

/// 「计划」服务：管理每日待办（增删改、持久化），
/// 并能调用统一 Agent 内核（与做实验/项目开发同一套工具）真正执行待办——
/// 支持「按顺序」或「并行」批量执行。
class PlanService extends ChangeNotifier {
  PlanService(this.settings, this.memory, {TopicFetchService? research})
      : _model = ModelClient(settings) {
    // 把主题研究服务接入 Agent：计划执行器即可调用 deep_research 工具，
    // 真正做到「先深研某主题、再据此动手」的跨模块协作。
    _runner = AgentRunner(model: _model, memory: memory, research: research);
  }

  final SettingsService settings;
  final MemoryService memory;
  final ModelClient _model;
  late final AgentRunner _runner;

  List<PlanTodo> todos = [];
  File? _store;

  /// 收到停止请求的待办 id 集合（在下一步生效）。
  final Set<String> _cancelled = {};

  bool get anyRunning => todos.any((t) => t.running);

  // ---------------------------------------------------------------------------
  // 持久化
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _store = File('${dir.path}\\plan_todos.json');
    if (await _store!.exists()) {
      try {
        final list = jsonDecode(await _store!.readAsString()) as List;
        todos = list
            .map((e) => PlanTodo.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        todos = [];
      }
    }
  }

  Future<void> _persist() async {
    if (_store == null) return;
    await _store!.writeAsString(jsonEncode(todos.map((t) => t.toJson()).toList()));
  }

  // ---------------------------------------------------------------------------
  // 增删改（普通 todo 操作）
  // ---------------------------------------------------------------------------

  void add(String title) {
    final text = title.trim();
    if (text.isEmpty) return;
    todos.insert(
      0,
      PlanTodo(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: text,
        createdAt: DateTime.now(),
      ),
    );
    notifyListeners();
    _persist();
  }

  void toggleDone(PlanTodo t) {
    t.done = !t.done;
    notifyListeners();
    _persist();
  }

  void rename(PlanTodo t, String title) {
    final text = title.trim();
    if (text.isEmpty) return;
    t.title = text;
    notifyListeners();
    _persist();
  }

  void remove(PlanTodo t) {
    _cancelled.add(t.id); // 若正在跑，请求停止
    todos.remove(t);
    notifyListeners();
    _persist();
  }

  void cancel(PlanTodo t) {
    if (t.running) {
      _cancelled.add(t.id);
      _pushStatus(t, '⏹ 收到停止请求，将在当前步骤后结束…');
    }
  }

  void cancelAll() {
    for (final t in todos.where((t) => t.running)) {
      cancel(t);
    }
  }

  // ---------------------------------------------------------------------------
  // AI 分析并执行
  // ---------------------------------------------------------------------------

  /// 批量执行所有「未完成且未成功」的待办。
  /// [parallel] 为 true 时并行执行，否则按顺序逐个执行。
  Future<void> executeAll({required bool parallel}) async {
    final pending = todos
        .where((t) => !t.done && t.status != PlanStatus.success && !t.running)
        .toList();
    if (pending.isEmpty) return;
    if (parallel) {
      await Future.wait(pending.map(_run));
    } else {
      for (final t in pending) {
        await _run(t);
      }
    }
  }

  /// 执行单个待办。
  Future<void> executeOne(PlanTodo t) => _run(t);

  Future<void> _run(PlanTodo t) async {
    if (t.running) return;
    _cancelled.remove(t.id);
    t.status = PlanStatus.running;
    t.events.clear();
    t.result = '';
    notifyListeners();

    // 每个待办在独立工作目录内执行，避免并行时互相干扰。
    final dir = Directory('${settings.vaultPath}\\计划\\${_folderName(t.title)}-${t.id}');
    try {
      await dir.create(recursive: true);
      t.workdir = dir.path;
      final result = await _runner.run(
        dir: dir,
        systemPrompt: _systemPrompt(),
        initialMessages: [Msg.user(_taskMessage(t.title))],
        recallQuery: t.title,
        reporter: _reporterFor(t),
        isCancelled: () => _cancelled.contains(t.id),
        // 待办执行属于临时任务，不参与全局记忆回忆/抽取，保持干净简单。
        enableMemory: false,
        extractMemory: false,
        log: (m) => _pushStatus(t, m),
      );
      t.result = result.lastText;
      t.status = switch (result.reason) {
        AgentStopReason.completed => PlanStatus.success,
        AgentStopReason.aborted => PlanStatus.idle,
        _ => PlanStatus.error,
      };
    } catch (e) {
      t.status = PlanStatus.error;
      _pushStatus(t, '执行失败：$e');
    } finally {
      _cancelled.remove(t.id);
      notifyListeners();
      await _persist();
    }
  }

  /// 为某个待办构造把 agent 事件写入其 events 列表的上报器。
  AgentReporter _reporterFor(PlanTodo t) {
    AgentEvent? streaming;
    final toolEvents = <String, AgentEvent>{};
    return AgentReporter(
      onStatus: (m) => _pushStatus(t, m),
      onAssistantDelta: (delta) {
        streaming ??= _push(t, AgentEvent.assistant(''));
        streaming!.text += delta;
        notifyListeners();
      },
      onAssistantText: (full) {
        if (streaming != null) {
          streaming!
            ..text = full
            ..status = StepStatus.done;
        } else {
          _push(t, AgentEvent.assistant(full)..status = StepStatus.done);
        }
        streaming = null;
        notifyListeners();
      },
      onToolStart: (id, tool, title) {
        streaming?.status = StepStatus.done;
        streaming = null;
        toolEvents[id] = _push(t, AgentEvent.tool(tool: tool, title: title));
        notifyListeners();
      },
      onToolEnd: (id, isError, result) {
        final e = toolEvents[id];
        if (e != null) {
          e.status = isError ? StepStatus.error : StepStatus.done;
          e.detail = result;
          notifyListeners();
        }
      },
    );
  }

  AgentEvent _push(PlanTodo t, AgentEvent e) {
    t.events.add(e);
    return e;
  }

  void _pushStatus(PlanTodo t, String m) {
    t.events.add(AgentEvent.status(m));
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 提示词与工具方法
  // ---------------------------------------------------------------------------

  String _systemPrompt() {
    final os = Platform.isWindows
        ? 'Windows（bash 工具经 cmd /c 执行命令）'
        : 'Unix（bash 工具经 bash -lc 执行命令）';
    return '''
你是用户得力的私人助理 Agent，运行环境为 $os。
用户给你一个「待办事项」，请你**真正动手把它做好/做完**，而不是只给建议。
你在一个独立的工作目录内工作，可用工具（路径限定在工作目录内）：
- read_file / write_file / edit_file：读写、编辑文件
- bash：执行命令
- grep / glob：搜索文件内容 / 按文件名查找
- read_url：读取网页正文（查在线资料、读文档/GitHub 页面）
- search_knowledge：检索用户本地知识库里的相关笔记
- deep_research：对某主题做一次完整的深度研究并存入知识库（耗时较长，仅在确需系统性调研时使用）
- task：把可独立交付的子任务委派给子 agent（explore=只读探索；general=可动手）

工作方式：
1. 先分析这件事要怎么做、拆成可执行的步骤。
2. 动手执行：需要产出文档/代码/数据，就用 write_file/edit_file 写到工作目录；需要跑命令就用 bash。
3. 完成后用一段 **Markdown** 总结：做了什么、产出在哪、结论或下一步建议，然后**停止调用任何工具**即结束。

若该事项无需产出文件（如规划、整理思路类），直接给出高质量、可执行的分析与方案作为最终结果。
''';
  }

  String _taskMessage(String title) {
    final n = DateTime.now();
    final today = '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
    return '今天是 $today。请完成这个待办事项：\n「$title」\n现在开始动手执行。';
  }

  static String _folderName(String title) {
    var out = title.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_').trim();
    if (out.length > 30) out = out.substring(0, 30);
    if (out.isEmpty) out = 'todo';
    return out;
  }
}
