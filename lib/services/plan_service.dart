import 'dart:async';
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
import 'plan_models.dart';
import 'settings_service.dart';
import 'topic_service.dart';

export 'plan_models.dart';

/// 排序方式。
enum PlanSort { manual, due, priority, status }

/// 「计划」服务：管理每日待办（增删改、日期/优先级/标签/子任务/备注/关联、持久化），
/// 内置应用内调度器（到期提醒 / 自动执行 / 重复任务生成），
/// 并能调用统一 Agent 内核真正执行待办——支持「先拆解确认」、按顺序/并行批量、重跑与续做。
class PlanService extends ChangeNotifier {
  PlanService(this.settings, this.memory, {TopicFetchService? research})
      : _model = ModelClient(settings) {
    // 把主题研究服务接入 Agent：计划执行器即可调用 deep_research 工具。
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

  /// 已弹过提醒 / 已自动触发过的任务 id，避免重复打扰。
  final Set<String> _reminded = {};
  final Set<String> _autoFired = {};

  /// 待展示给用户的到期提醒（UI 取走后清空）。
  final List<PlanTodo> dueReminders = [];

  Timer? _scheduler;

  bool get anyRunning => todos.any((t) => t.running);

  // ---------------------------------------------------------------------------
  // 持久化与调度器
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
    // 每 30 秒检查一次到期提醒与自动执行（应用打开时生效）。
    _scheduler = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }

  @override
  void dispose() {
    _scheduler?.cancel();
    super.dispose();
  }

  Future<void> _persist() async {
    if (_store == null) return;
    await _store!.writeAsString(jsonEncode(todos.map((t) => t.toJson()).toList()));
  }

  /// 调度器心跳：到期提醒 + 到点自动执行。
  void _tick() {
    final now = DateTime.now();
    var changed = false;
    for (final t in todos) {
      if (t.done || t.archived || t.dueAt == null) continue;
      final due = !t.dueAt!.isAfter(now); // dueAt <= now
      if (!due) continue;
      // 到点自动执行（仅一次）。
      if (t.autoRun &&
          !t.running &&
          t.status != PlanStatus.success &&
          !_autoFired.contains(t.id)) {
        _autoFired.add(t.id);
        _run(t); // 自动执行不走"先确认"，直接动手。
        continue;
      }
      // 到期提醒（仅一次）。
      if (!_reminded.contains(t.id)) {
        _reminded.add(t.id);
        dueReminders.add(t);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// UI 消费完提醒后调用，清空提醒队列。
  void clearReminders() {
    dueReminders.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 增删改
  // ---------------------------------------------------------------------------

  /// 快速添加（仅标题）；详细字段用 [addTodo] / [update]。
  void add(String title) {
    final text = title.trim();
    if (text.isEmpty) return;
    addTodo(PlanTodo(
      id: _newId(),
      title: text,
      createdAt: DateTime.now(),
    ));
  }

  void addTodo(PlanTodo t) {
    todos.insert(0, t);
    _renumber();
    notifyListeners();
    _persist();
  }

  /// 编辑已有任务后调用，持久化并刷新。
  void update(PlanTodo t) {
    notifyListeners();
    _persist();
  }

  void toggleDone(PlanTodo t) {
    t.done = !t.done;
    // 重复任务：完成时自动生成下一次发生。
    if (t.done && t.recur != PlanRecur.none) {
      _spawnNext(t);
      t.archived = true; // 完成的重复实例归档，避免与新实例混在一起。
    }
    notifyListeners();
    _persist();
  }

  void toggleArchived(PlanTodo t) {
    t.archived = !t.archived;
    notifyListeners();
    _persist();
  }

  void remove(PlanTodo t) {
    _cancelled.add(t.id); // 若正在跑，请求停止
    todos.remove(t);
    notifyListeners();
    _persist();
  }

  void toggleSubtask(PlanTodo t, PlanSubtask s) {
    s.done = !s.done;
    notifyListeners();
    _persist();
  }

  /// 拖拽重排（仅在"手动排序、未搜索"下生效）。
  /// [active] 为当前可见的未归档任务列表；重排后已归档任务统一沉到末尾。
  void reorderActive(List<PlanTodo> active, int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final list = List.of(active);
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    final archived = todos.where((t) => t.archived).toList();
    todos = [...list, ...archived];
    _renumber();
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

  /// 生成重复任务的下一次发生。
  void _spawnNext(PlanTodo t) {
    final base = t.dueAt ?? DateTime.now();
    final next = t.recur.next(base);
    if (next == null) return;
    todos.insert(
      0,
      PlanTodo(
        id: _newId(),
        title: t.title,
        createdAt: DateTime.now(),
        notes: t.notes,
        priority: t.priority,
        tags: List.of(t.tags),
        dueAt: next,
        recur: t.recur,
        autoRun: t.autoRun,
        // 子任务复制为未完成的模板。
        subtasks: t.subtasks
            .map((s) => PlanSubtask(id: _newId(), title: s.title))
            .toList(),
        links: t.links.map((l) => PlanLink(kind: l.kind, label: l.label)).toList(),
      ),
    );
    _renumber();
  }

  // ---------------------------------------------------------------------------
  // AI 分析并执行
  // ---------------------------------------------------------------------------

  /// 批量执行所有「未完成、未归档、未成功」的待办（直接动手，不走逐项确认）。
  Future<void> executeAll({required bool parallel}) async {
    final pending = todos
        .where((t) =>
            !t.done &&
            !t.archived &&
            t.status != PlanStatus.success &&
            !t.running)
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

  /// 执行单个待办：
  /// [withApproval] 为 true 时，先让 AI 拆解步骤填入子任务、等待用户确认后再 [approveAndRun]。
  Future<void> executeOne(PlanTodo t, {bool withApproval = true}) async {
    if (t.running) return;
    if (withApproval) {
      await _proposePlan(t);
    } else {
      await _run(t);
    }
  }

  /// 用户确认（可能已编辑过子任务）后真正执行。
  Future<void> approveAndRun(PlanTodo t) async {
    t.awaitingApproval = false;
    await _run(t);
  }

  /// 取消"先拆解确认"，回到未执行状态。
  void rejectPlan(PlanTodo t) {
    t.awaitingApproval = false;
    notifyListeners();
  }

  /// 让 AI 把任务拆成 3~7 个可执行步骤，写入子任务，等待用户确认。
  Future<void> _proposePlan(PlanTodo t) async {
    t.awaitingApproval = false;
    t.events.clear();
    _pushStatus(t, '正在拆解执行步骤…');
    try {
      final raw = await _model.complete(
        system: '你是任务规划助手。把用户的待办拆成 3~7 个具体、可执行、有先后顺序的步骤。'
            '只输出 JSON：{"steps":["步骤1","步骤2",...]}，不要多余解释。',
        user: '待办：「${t.title}」'
            '${t.notes.trim().isEmpty ? '' : '\n备注：${t.notes.trim()}'}',
        jsonMode: true,
      );
      final steps = _parseSteps(raw);
      if (steps.isNotEmpty) {
        t.subtasks
          ..clear()
          ..addAll(steps.map((s) => PlanSubtask(id: _newId(), title: s)));
      }
      t.events.clear();
      t.awaitingApproval = true;
    } catch (e) {
      t.events.clear();
      _pushStatus(t, '拆解失败，可直接执行或手动添加步骤：$e');
      t.awaitingApproval = true;
    }
    notifyListeners();
    await _persist();
  }

  List<String> _parseSteps(String raw) {
    try {
      final obj = jsonDecode(raw);
      final list = (obj is Map ? obj['steps'] : obj) as List?;
      return list
              ?.map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty)
              .toList() ??
          [];
    } catch (_) {
      return [];
    }
  }

  /// 在最近一次产物基础上追加指令继续做（续跑同一工作目录）。
  Future<void> continueWith(PlanTodo t, String instruction) async {
    final text = instruction.trim();
    if (text.isEmpty || t.running) return;
    await _run(t, followUp: text);
  }

  Future<void> _run(PlanTodo t, {String? followUp}) async {
    if (t.running) return;
    _cancelled.remove(t.id);
    t.awaitingApproval = false;
    t.status = PlanStatus.running;
    t.events.clear();
    notifyListeners();

    // 每个待办在独立工作目录内执行；续跑复用上次目录以便接着上次产物做。
    final dir = (followUp != null && t.workdir != null)
        ? Directory(t.workdir!)
        : Directory(
            '${settings.vaultPath}\\计划\\${_folderName(t.title)}-${t.id}');
    final run = PlanRun(id: _newId(), startedAt: DateTime.now());
    try {
      await dir.create(recursive: true);
      t.workdir = dir.path;
      run.workdir = dir.path;
      final result = await _runner.run(
        dir: dir,
        systemPrompt: _systemPrompt(),
        initialMessages: [Msg.user(_taskMessage(t, followUp: followUp))],
        recallQuery: t.title,
        reporter: _reporterFor(t),
        isCancelled: () => _cancelled.contains(t.id),
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
      // 落一条历史记录（含过程事件，便于回看/对比）。
      run
        ..finishedAt = DateTime.now()
        ..status = t.status == PlanStatus.running ? PlanStatus.idle : t.status
        ..result = t.result
        ..events.addAll(t.events.map((e) => AgentEvent.fromJson(e.toJson())));
      t.runs.insert(0, run);
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

  String _taskMessage(PlanTodo t, {String? followUp}) {
    final n = DateTime.now();
    final today =
        '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
    final buf = StringBuffer('今天是 $today。');
    if (followUp != null) {
      // 续跑：在上次产物基础上继续。
      buf
        ..writeln('上次你已对这个待办做过工作，产出在当前工作目录里。')
        ..writeln('原待办：「${t.title}」')
        ..writeln('现在请按以下补充指令继续完善：')
        ..writeln(followUp);
      return buf.toString();
    }
    buf.writeln('请完成这个待办事项：\n「${t.title}」');
    if (t.notes.trim().isNotEmpty) {
      buf.writeln('补充说明：${t.notes.trim()}');
    }
    if (t.subtasks.isNotEmpty) {
      buf.writeln('请按以下步骤推进（可调整）：');
      for (var i = 0; i < t.subtasks.length; i++) {
        buf.writeln('${i + 1}. ${t.subtasks[i].title}');
      }
    }
    if (t.links.isNotEmpty) {
      buf.writeln('相关参考（按需用 search_knowledge / read_url 等工具查阅）：');
      for (final l in t.links) {
        buf.writeln('- [${l.kindLabel}] ${l.label}');
      }
    }
    buf.writeln('现在开始动手执行。');
    return buf.toString();
  }

  void _renumber() {
    for (var i = 0; i < todos.length; i++) {
      todos[i].order = i;
    }
  }

  // 自增序号避免同一微秒内多次取 id 冲突（如复制多个子任务）。
  int _idSeq = 0;
  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_idSeq++}';

  static String _folderName(String title) {
    var out = title.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_').trim();
    if (out.length > 30) out = out.substring(0, 30);
    if (out.isEmpty) out = 'todo';
    return out;
  }
}
