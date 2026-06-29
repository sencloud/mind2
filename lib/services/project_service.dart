import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'agent/agent_event.dart';
import 'agent/agent_loop.dart';
import 'agent/agent_runner.dart';
import 'agent/memory/memory_service.dart';
import 'agent/memory/memory_store.dart';
import 'agent/memory/memory_types.dart';
import 'agent/messages.dart';
import 'agent/model_client.dart';
import 'agent/prompts.dart';
import 'agent/reporter.dart';
import 'code_index_service.dart';
import 'settings_service.dart';
import 'topic_service.dart';

/// 会话类型：dev=项目开发会话；research=基于会话发起的主题研究会话。
enum ConvKind { dev, research }

/// 一次项目开发的「对话会话」：包含该次会话的全部运行事件（用户指令、
/// 助手思考、工具调用等），可落盘持久化并随时加载回来（参考 Cursor 的会话历史）。
class ProjectConversation {
  ProjectConversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.events,
    this.kind = ConvKind.dev,
    this.researchPath,
  });

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<AgentEvent> events;

  /// 会话类型（开发 / 研究），用于在会话列表上区分与打标。
  final ConvKind kind;

  /// 研究会话产出的报告笔记路径（仅 research 会话有）。
  String? researchPath;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'events': events.map((e) => e.toJson()).toList(),
        'kind': kind.name,
        if (researchPath != null) 'researchPath': researchPath,
      };

  factory ProjectConversation.fromJson(Map<String, dynamic> j) =>
      ProjectConversation(
        id: j['id'] as String,
        title: j['title'] as String? ?? '(未命名会话)',
        createdAt:
            DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
        updatedAt:
            DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
        events: ((j['events'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => AgentEvent.fromJson(e.cast<String, dynamic>()))
            .toList(),
        kind: ConvKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => ConvKind.dev,
        ),
        researchPath: j['researchPath'] as String?,
      );
}

/// 工程与「主题研究」的关联：标明该项目源自哪一份研究报告，
/// 作为项目页的 tag 展示，并把研究内容作为开发记忆注入。
class ProjectLink {
  ProjectLink({required this.researchPath, required this.researchTitle});

  /// 关联的研究报告笔记文件路径。
  final String researchPath;

  /// 研究报告标题（用于 tag 展示）。
  final String researchTitle;

  Map<String, dynamic> toJson() =>
      {'researchPath': researchPath, 'researchTitle': researchTitle};

  factory ProjectLink.fromJson(Map<String, dynamic> j) => ProjectLink(
        researchPath: j['researchPath'] as String? ?? '',
        researchTitle: j['researchTitle'] as String? ?? '',
      );
}

/// 「项目开发」：复用做实验的同一套通用 agent 内核（lib/services/agent/），
/// 让第二大脑在用户的软件工程目录内真正动手开发——读代码、写代码、装依赖、
/// 运行调试，直到达成开发需求。
///
/// 每个项目维护一组可持久化的对话会话（保存在应用数据目录，按工程路径建键），
/// 可随时加载历史会话继续查看或开发。
class ProjectService extends ChangeNotifier {
  ProjectService(this.settings, this.memory, {TopicFetchService? research})
      : _model = ModelClient(settings),
        index = CodeIndexService(),
        _research = research {
    _runner = AgentRunner(model: _model, memory: memory);
  }

  final SettingsService settings;
  final MemoryService memory;
  final ModelClient _model;
  late final AgentRunner _runner;

  /// 主题研究服务：用于"基于当前会话发起主题研究"，复用同一套研究引擎。
  final TopicFetchService? _research;

  /// 是否具备发起研究的能力（已接入主题研究服务）。
  bool get canResearch => _research != null;

  /// 当前工程的文件扫描服务（供 UI 显示文件数 / 工程概览 / 改动检测）。
  final CodeIndexService index;

  bool running = false;

  /// 最近打开/创建的工程路径（最新在前）。
  final List<String> projects = [];

  /// 工程路径 → 关联研究。用于 tag 展示与开发记忆注入。
  final Map<String, ProjectLink> _links = {};

  ProjectLink? linkFor(String path) => _links[path];

  /// 当前选中的工程路径。
  String? current;

  /// 当前工程的对话会话（最新在前）。
  List<ProjectConversation> conversations = [];

  /// 当前正在查看/开发的会话。
  ProjectConversation? activeConv;

  /// 当前会话的运行事件（供 UI 渲染）。
  List<AgentEvent> get events => activeConv?.events ?? const [];

  bool _cancel = false;
  AgentEvent? _streaming;
  final Map<String, AgentEvent> _toolEvents = {};

  File? _store;
  File? _linksStore;
  Directory? _root;

  void _status(String m) {
    activeConv?.events.add(AgentEvent.status(m));
    notifyListeners();
  }

  Future<void> init() async {
    try {
      final base = await getApplicationSupportDirectory();
      _store = File('${base.path}\\projects.json');
      _linksStore = File('${base.path}\\project_links.json');
      _root = Directory('${base.path}\\project_data');
      await _root!.create(recursive: true);
      if (await _store!.exists()) {
        final data = jsonDecode(await _store!.readAsString());
        if (data is List) {
          for (final p in data) {
            final s = p.toString();
            if (Directory(s).existsSync()) projects.add(s);
          }
        }
      }
      if (await _linksStore!.exists()) {
        final data = jsonDecode(await _linksStore!.readAsString());
        if (data is Map) {
          data.forEach((k, v) {
            if (v is Map) {
              _links[k.toString()] =
                  ProjectLink.fromJson(v.cast<String, dynamic>());
            }
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _persistProjects() async {
    try {
      await _store?.writeAsString(jsonEncode(projects));
    } catch (_) {}
  }

  Future<void> _persistLinks() async {
    try {
      await _linksStore?.writeAsString(
          jsonEncode(_links.map((k, v) => MapEntry(k, v.toJson()))));
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // 项目管理
  // ---------------------------------------------------------------------------

  /// 打开一个已存在的工程目录，并加载它的对话历史。
  void openProject(String path) {
    if (!Directory(path).existsSync()) return;
    projects.remove(path);
    projects.insert(0, path);
    current = path;
    _loadConversations(path);
    activeConv = conversations.isNotEmpty ? conversations.first : null;
    notifyListeners();
    _persistProjects();
    _bindIndex(path);
  }

  /// 把一次实验的工程目录作为「项目」打开，并关联到其来源研究报告：
  /// - 记录工程→研究的关联（tag），用于项目页展示与跳转；
  /// - 研究报告正文会在每次开发回忆时作为来源记忆注入，指导后续工程化完善。
  void openFromExperiment({
    required String projectPath,
    required String researchPath,
    required String researchTitle,
  }) {
    final link =
        ProjectLink(researchPath: researchPath, researchTitle: researchTitle);
    _links[projectPath] = link;
    unawaited(_persistLinks());
    unawaited(_seedResearchMemory(projectPath, link));
    openProject(projectPath);
  }

  /// 绑定当前工程并扫描一次文件清单（用于概览与改动检测，纯 IO，快速）。
  Future<void> _bindIndex(String path) async {
    try {
      await index.bind(Directory(path));
    } catch (_) {}
  }

  /// 手动重新扫描当前工程文件清单。
  Future<void> rescanProject() async {
    if (current == null) return;
    await index.rescan();
  }

  /// 在父目录下新建工程目录并打开；返回新建的工程路径。
  Future<String?> createProject(String parentDir, String name) async {
    final clean = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (clean.isEmpty) return null;
    final path = '$parentDir\\$clean';
    final dir = Directory(path);
    if (!await dir.exists()) await dir.create(recursive: true);
    openProject(path);
    return path;
  }

  void removeProject(String path) {
    projects.remove(path);
    if (current == path) {
      current = null;
      conversations = [];
      activeConv = null;
      index.unbind();
    }
    notifyListeners();
    _persistProjects();
  }

  void closeProject() {
    current = null;
    conversations = [];
    activeConv = null;
    index.unbind();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 对话会话
  // ---------------------------------------------------------------------------

  /// 新建一个空会话并设为当前会话。
  void newConversation() {
    if (running) return;
    final conv = ProjectConversation(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: '新会话',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      events: [],
    );
    conversations.insert(0, conv);
    activeConv = conv;
    notifyListeners();
  }

  void openConversation(ProjectConversation conv) {
    if (running) return;
    activeConv = conv;
    notifyListeners();
  }

  Future<void> deleteConversation(ProjectConversation conv) async {
    if (running && activeConv == conv) return;
    conversations.remove(conv);
    if (activeConv == conv) {
      activeConv = conversations.isNotEmpty ? conversations.first : null;
    }
    notifyListeners();
    await _saveConversations();
  }

  /// 请求中止当前开发循环（在下一步生效）。
  void cancel() {
    if (running) {
      _cancel = true;
      _status('⏹ 收到停止请求，将在当前步骤后结束…');
    }
  }

  /// 在当前工程目录内执行一次开发需求（追加到当前会话）。
  Future<void> develop(String instruction) async {
    final path = current;
    if (path == null) throw StateError('请先打开或新建一个项目');
    if (running) throw StateError('已有开发任务在进行中');
    final dir = Directory(path);
    if (!await dir.exists()) throw StateError('项目目录不存在：$path');

    // 没有活动会话则新建一个；首条指令作为会话标题。
    if (activeConv == null) newConversation();
    final conv = activeConv!;
    if (conv.events.isEmpty || conv.title == '新会话') {
      conv.title = instruction.length > 30
          ? '${instruction.substring(0, 30)}…'
          : instruction;
    }
    conv.events.add(AgentEvent.user(instruction));
    conv.updatedAt = DateTime.now();

    running = true;
    _cancel = false;
    _streaming = null;
    _toolEvents.clear();
    notifyListeners();
    try {
      // 记录改动前的文件快照（用于汇总本轮改动了哪些文件）。
      final before = index.bound ? index.snapshotMtimes() : const <String, int>{};

      final reporter = _buildReporter();
      final result =
          await _runAgent(dir: dir, task: instruction, reporter: reporter);

      // 汇总本轮改动文件（按 mtime 差异）。
      if (index.bound) {
        final after = index.snapshotMtimes();
        final changed = <String>[];
        after.forEach((rel, mtime) {
          if (!before.containsKey(rel) || before[rel] != mtime) {
            changed.add(rel);
          }
        });
        changed.sort();
        if (changed.isNotEmpty) {
          _push(AgentEvent.changes('本次改动了 ${changed.length} 个文件', changed));
          notifyListeners();
        }
        unawaited(index.rescan());
      }

      final tip = switch (result.reason) {
        AgentStopReason.completed => '✅ 开发任务完成',
        AgentStopReason.maxTurns => '⚠ 达最大轮数停止',
        AgentStopReason.aborted => '⏹ 已中止',
        AgentStopReason.error => '✖ 因错误结束',
      };
      _status('$tip · 工程：$path');
    } finally {
      running = false;
      _cancel = false;
      _streaming = null;
      conv.updatedAt = DateTime.now();
      await _saveConversations();
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // 基于当前会话发起主题研究（复用主题研究引擎，研究会话落在项目会话列表）
  // ---------------------------------------------------------------------------

  /// 把当前会话压成一段简短转写，作为研究背景（需求、已实现要点、改动文件）。
  String _conversationDigest() {
    final conv = activeConv;
    if (conv == null) return '';
    final buf = StringBuffer();
    for (final e in conv.events) {
      switch (e.kind) {
        case AgentEventKind.user:
          buf.writeln('[需求] ${_clip(e.text, 400)}');
        case AgentEventKind.assistant:
          if (e.text.trim().isNotEmpty) {
            buf.writeln('[助手] ${_clip(e.text, 400)}');
          }
        case AgentEventKind.tool:
          if (e.title.trim().isNotEmpty) buf.writeln('[操作] ${_clip(e.title, 120)}');
        case AgentEventKind.changes:
          buf.writeln('[改动文件] ${e.detail.replaceAll('\n', '、')}');
        case AgentEventKind.status:
          break; // 进度行不计入背景。
      }
    }
    return _clip(buf.toString().trim(), 4000);
  }

  /// 基于当前会话，请模型提一个"值得深入研究的新算法/新思路/方案"主题，
  /// 用于研究方向对话框的预填。失败返回空串（仅为输入便利，不阻断流程）。
  Future<String> suggestResearchTopic() async {
    if (_research == null || activeConv == null) return '';
    final digest = _conversationDigest();
    if (digest.isEmpty) return '';
    try {
      final out = await ModelClient(settings, role: ModelRole.research).complete(
        system: '你擅长从工程实践里发现值得研究的方向。',
        user: '基于下面这段项目开发会话，提炼一个值得深入研究的'
            '“新算法 / 新思路 / 设计或实现方案”作为研究主题。'
            '只返回一行、聚焦、不超过 30 字的主题本身，不要解释、不要标点结尾。\n\n会话：\n$digest',
      );
      return out.split('\n').first.trim();
    } catch (_) {
      return '';
    }
  }

  /// 研究会话的原始输入（topic, clarification），按会话 id 暂存于内存，
  /// 供「重发」在同一会话内用相同输入重跑（失败重试）。本进程内有效。
  final Map<String, (String, String)> _researchInputs = {};

  /// 基于当前会话 + 用户想法发起一次主题研究：
  /// 新建一个「研究」类型会话（落在项目会话列表，tag 研究），复用主题研究引擎执行，
  /// 报告存入知识库（但不登记主题研究历史），并把结论并入本项目记忆以指导后续开发。
  Future<void> startResearch(String idea) async {
    final path = current;
    if (path == null) throw StateError('请先打开一个项目');
    if (_research == null) throw StateError('主题研究服务不可用');
    if (running) throw StateError('已有任务在进行中');
    final topic = idea.trim();
    if (topic.isEmpty) throw StateError('请填写研究方向');

    // 先取背景（必须在新建研究会话前取，否则 activeConv 会被切走）。
    final digest = _conversationDigest();

    // 把会话背景 + 工程概览作为研究的澄清说明，引导研究聚焦到落地方案。
    final buf = StringBuffer()
      ..writeln('本研究源自项目「${path.split('\\').last}」的一次开发会话，'
          '请围绕用户的想法，研究可落地的新算法 / 新思路 / 设计实现方案。')
      ..writeln()
      ..writeln('【用户想法】')
      ..writeln(topic);
    if (digest.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【会话背景（需求与已实现要点）】')
        ..writeln(digest);
    }
    final overview = index.overview();
    if (overview.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【工程概览】')
        ..writeln(_clip(overview, 1500));
    }
    final clarification = buf.toString();

    final conv = ProjectConversation(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: topic.length > 30 ? '${topic.substring(0, 30)}…' : topic,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      events: [AgentEvent.user('🔬 基于当前会话研究：$topic')],
      kind: ConvKind.research,
    );
    conversations.insert(0, conv);
    activeConv = conv;
    _researchInputs[conv.id] = (topic, clarification);
    notifyListeners();

    await _runResearchInto(conv, path, topic, clarification);
  }

  /// 重发：在同一研究会话内用相同输入重新跑一次研究（失败后重试）。
  Future<void> resendResearch(ProjectConversation conv) async {
    final path = current;
    if (path == null) throw StateError('请先打开一个项目');
    if (_research == null) throw StateError('主题研究服务不可用');
    if (running) throw StateError('已有任务在进行中');
    final input = _researchInputs[conv.id];
    if (input == null) {
      throw StateError('该研究的原始输入已不可用，请从源开发会话重新发起');
    }
    activeConv = conv;
    conv.events.add(AgentEvent.user('🔁 重新研究：${input.$1}'));
    notifyListeners();
    await _runResearchInto(conv, path, input.$1, input.$2);
  }

  /// 把一次研究跑进指定会话：复用主题研究引擎，报告作为助手消息呈现，
  /// 报告存知识库（不登记主题研究历史），并把结论并入本项目记忆。
  Future<void> _runResearchInto(
      ProjectConversation conv, String path, String topic, String clarification) async {
    running = true;
    _cancel = false;
    notifyListeners();
    try {
      final report = await _research!.researchForAgent(
        topic,
        clarification: clarification,
        log: _status,
        recordInHistory: false, // 研究归项目所有，不进主题研究历史。
      );
      _push(AgentEvent.assistant(report)..status = StepStatus.done);
      conv.researchPath = _research.lastReportPath;
      _status('完成！研究报告已存入知识库'
          '${conv.researchPath != null ? '：${conv.researchPath!.split('\\').last}' : ''}');
      await _rememberResearch(path, topic, report);
    } catch (e) {
      _status('研究失败：$e（可点用户消息上的「重发」重试）');
    } finally {
      running = false;
      _cancel = false;
      conv.updatedAt = DateTime.now();
      await _saveConversations();
      notifyListeners();
    }
  }

  /// 把研究结论并入本项目记忆库，让后续开发能回忆到这次研究。
  Future<void> _rememberResearch(String path, String topic, String report) async {
    try {
      final body = StringBuffer()
        ..writeln('**Why:** 这是基于本项目会话发起的一次深度研究，结论可指导后续实现。')
        ..writeln('**How to apply:** 推进相关功能时对照该研究的方案与结论。')
        ..writeln()
        ..writeln('## 研究：$topic')
        ..writeln(_clip(report, 4000));
      await memory.remember(
        store: _projectStore(path),
        type: MemoryType.project,
        name: '研究：$topic',
        description: '基于本项目会话发起的研究结论，供后续开发参考',
        body: body.toString(),
      );
    } catch (e) {
      _status('研究结论并入记忆失败（不影响结果）：$e');
    }
  }

  Future<AgentResult> _runAgent({
    required Directory dir,
    required String task,
    required AgentReporter reporter,
  }) async {
    final path = dir.path;
    return _runner.run(
      dir: dir,
      systemPrompt: ProjectPrompts.system(),
      initialMessages: [
        Msg.user(ProjectPrompts.task(task, '', overview: index.overview()))
      ],
      recallQuery: task,
      reporter: reporter,
      isCancelled: () => _cancel,
      projectStore: _projectStore(path),
      maxTurns: 0, // 不限轮数：仅在任务完成或用户停止时结束。
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
    activeConv?.events.add(e);
    return e;
  }

  // ---------------------------------------------------------------------------
  // 会话与记忆的持久化（应用数据目录，按工程路径建键，不污染用户仓库）
  // ---------------------------------------------------------------------------

  String _key(String projectPath) =>
      projectPath.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  Directory _dataDir(String projectPath) =>
      Directory('${_root!.path}\\${_key(projectPath)}');

  File _chatsFile(String projectPath) =>
      File('${_dataDir(projectPath).path}\\conversations.json');

  void _loadConversations(String projectPath) {
    conversations = [];
    try {
      final f = _chatsFile(projectPath);
      if (f.existsSync()) {
        final data = jsonDecode(f.readAsStringSync());
        if (data is List) {
          conversations = data
              .whereType<Map>()
              .map((e) =>
                  ProjectConversation.fromJson(e.cast<String, dynamic>()))
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        }
      }
    } catch (_) {
      conversations = [];
    }
  }

  Future<void> _saveConversations() async {
    final path = current;
    if (path == null) return;
    try {
      final dir = _dataDir(path);
      await dir.create(recursive: true);
      await _chatsFile(path)
          .writeAsString(jsonEncode(conversations.map((c) => c.toJson()).toList()));
    } catch (_) {}
  }

  /// 本项目的结构化记忆库（独立记忆文件 + MEMORY.md 索引，放在应用数据目录下）。
  MemoryStore _projectStore(String projectPath) =>
      memory.projectStore('${_dataDir(projectPath).path}\\memory');

  /// 把关联研究的报告正文并入项目记忆系统（作为一条 project 记忆，可被回忆选中）。
  Future<void> _seedResearchMemory(String projectPath, ProjectLink link) async {
    try {
      var research = '';
      final f = File(link.researchPath);
      if (await f.exists()) research = (await f.readAsString()).trim();
      final body = StringBuffer()
        ..writeln('**Why:** 本项目源自该主题研究，研究结论是工程化的目标与背景依据。')
        ..writeln(
            '**How to apply:** 推进项目时对照研究目标与结论，确保实现不偏离研究意图。')
        ..writeln()
        ..writeln('## 关联研究：${link.researchTitle}');
      if (research.isNotEmpty) body.writeln(_clip(research, 4000));
      await memory.remember(
        store: _projectStore(projectPath),
        type: MemoryType.project,
        name: '来源研究：${link.researchTitle}',
        description: '本项目源自研究《${link.researchTitle}》，作为目标与背景依据',
        body: body.toString(),
      );
    } catch (e) {
      _status('关联研究并入记忆失败（不影响开发）：$e');
    }
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}\n…（已截断 ${s.length - max} 字）';
}
