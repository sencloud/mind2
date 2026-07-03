import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'agent/agent_runner.dart';
import 'agent/memory/memory_service.dart';
import 'agent/messages.dart';
import 'agent/model_client.dart';
import 'agent/reporter.dart';
import 'project_service.dart';
import 'settings_service.dart';

/// 走读源码过程中的一条日志（供 UI 完整展示进度）。
class PromoLogEntry {
  PromoLogEntry(this.kind, this.text);

  /// status=流程状态；tool=工具调用；result=工具结果；thought=模型阶段说明。
  final String kind;
  final String text;
}

/// 一篇针对某个应用/产品的知乎推广推文草稿。
class PromoDraft {
  PromoDraft({
    required this.id,
    required this.appName,
    this.appIntro = '',
    this.sellingPoints = '',
    this.audience = '',
    this.angle = '',
    this.tone = '真诚种草',
    this.title = '',
    this.content = '',
    this.projectPath = '',
    this.projectBrief = '',
    List<String>? titleOptions,
    required this.createdAt,
    required this.updatedAt,
  }) : titleOptions = titleOptions ?? [];

  final String id;

  /// 应用/产品名称。
  String appName;

  /// 应用简介与核心功能。
  String appIntro;

  /// 卖点/亮点（可留空，AI 会自行提炼）。
  String sellingPoints;

  /// 目标读者。
  String audience;

  /// 切入角度（如：痛点解决 / 效率提升 / 对比测评 / 使用心得）。
  String angle;

  /// 语气风格（真诚种草 / 专业测评 / 故事化分享 / 干货教程）。
  String tone;

  /// 选定/生成的标题。
  String title;

  /// 推文正文（Markdown）。
  String content;

  /// 关联的项目工程目录（用于走读源码提炼特点）。为空表示未关联。
  String projectPath;

  /// 走读工程源码后提炼出的产品特点说明（Markdown），写作时注入。
  String projectBrief;

  /// AI 生成的候选标题。
  List<String> titleOptions;

  bool get hasProjectBrief => projectBrief.trim().isNotEmpty;

  final DateTime createdAt;
  DateTime updatedAt;

  bool get hasContent => content.trim().isNotEmpty;

  int get words => content.replaceAll(RegExp(r'\s'), '').length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'appName': appName,
    'appIntro': appIntro,
    'sellingPoints': sellingPoints,
    'audience': audience,
    'angle': angle,
    'tone': tone,
    'title': title,
    'content': content,
    'projectPath': projectPath,
    'projectBrief': projectBrief,
    'titleOptions': titleOptions,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory PromoDraft.fromJson(Map<String, dynamic> j) => PromoDraft(
    id: j['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
    appName: j['appName'] as String? ?? '未命名应用',
    appIntro: j['appIntro'] as String? ?? '',
    sellingPoints: j['sellingPoints'] as String? ?? '',
    audience: j['audience'] as String? ?? '',
    angle: j['angle'] as String? ?? '',
    tone: j['tone'] as String? ?? '真诚种草',
    title: j['title'] as String? ?? '',
    content: j['content'] as String? ?? '',
    projectPath: j['projectPath'] as String? ?? '',
    projectBrief: j['projectBrief'] as String? ?? '',
    titleOptions: ((j['titleOptions'] as List?) ?? [])
        .whereType<String>()
        .toList(),
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
  );
}

/// 「推广」写作服务：为指定应用生成知乎推广推文（标题候选 + 正文）。
///
/// 知乎调性：以真实体验/专业视角切入，开头有钩子引发共鸣，中间给干货与使用
/// 场景，自然植入产品而非硬广，结尾引导。全程走统一的 [ModelClient]（writing 通道）。
class PromoService extends ChangeNotifier {
  PromoService(this.settings, {this.project, MemoryService? memory}) {
    if (memory != null) {
      _runner = AgentRunner(model: ModelClient(settings), memory: memory);
    }
  }

  final SettingsService settings;

  /// 项目服务：用于列出可关联的工程，以及在其目录内走读源码。
  final ProjectService? project;

  /// 走读源码复用的统一 Agent 内核（agentic 检索：grep/glob/read）。
  AgentRunner? _runner;

  final List<PromoDraft> drafts = [];
  PromoDraft? current;

  bool busy = false;
  String stage = '';

  /// 是否正在走读源码（用于 UI 切换到走读日志视图）。
  bool walking = false;

  /// 走读源码的完整过程日志（实时追加，供 UI 展示）。
  final List<PromoLogEntry> walkLog = [];

  bool _cancel = false;
  File? _store;

  /// 可关联的工程目录列表（最新在前）。
  List<String> get projects => project?.projects ?? const [];

  /// 可选的切入角度预设（UI 快捷选择）。
  static const angles = ['痛点解决', '效率提升', '使用心得', '对比测评', '场景安利', '新手教程'];

  /// 可选的语气风格预设。
  static const tones = ['真诚种草', '专业测评', '故事化分享', '干货教程'];

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _store = File('${dir.path}\\promo_posts.json');
    if (await _store!.exists()) {
      try {
        final data = jsonDecode(await _store!.readAsString());
        if (data is List) {
          drafts
            ..clear()
            ..addAll(
              data.whereType<Map>().map(
                (e) => PromoDraft.fromJson(e.cast<String, dynamic>()),
              ),
            );
          drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        }
      } catch (_) {
        // 解析失败保持空列表，不写坏数据。
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 草稿管理
  // ---------------------------------------------------------------------------

  PromoDraft createDraft({
    required String appName,
    String appIntro = '',
    String audience = '',
  }) {
    final now = DateTime.now();
    final draft = PromoDraft(
      id: now.millisecondsSinceEpoch.toString(),
      appName: appName.trim().isEmpty ? '未命名应用' : appName.trim(),
      appIntro: appIntro.trim(),
      audience: audience.trim(),
      createdAt: now,
      updatedAt: now,
    );
    drafts.insert(0, draft);
    current = draft;
    notifyListeners();
    _persist();
    return draft;
  }

  void openDraft(PromoDraft draft) {
    current = draft;
    notifyListeners();
  }

  void closeDraft() {
    current = null;
    notifyListeners();
  }

  Future<void> deleteDraft(PromoDraft draft) async {
    drafts.remove(draft);
    if (current == draft) current = null;
    notifyListeners();
    await _persist();
  }

  Future<void> save() async {
    current?.updatedAt = DateTime.now();
    drafts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    notifyListeners();
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // 关联工程 + 走读源码提炼特点
  // ---------------------------------------------------------------------------

  /// 关联/切换工程；切到不同工程时清空已提炼的特点，避免张冠李戴。
  void selectProject(String? path) {
    final draft = current;
    if (draft == null) return;
    final next = (path ?? '').trim();
    if (draft.projectPath == next) return;
    draft.projectPath = next;
    draft.projectBrief = '';
    draft.updatedAt = DateTime.now();
    notifyListeners();
    _persist();
  }

  /// 走读关联工程的源码，提炼出用于写作的真实产品特点（projectBrief）。
  /// 复用统一 Agent 内核，用 grep/glob/read 实际阅读代码，不臆造功能。
  Future<void> analyzeProject() async {
    final draft = current;
    if (draft == null || busy) return;
    final path = draft.projectPath.trim();
    if (path.isEmpty) {
      stage = '请先选择要走读的工程';
      notifyListeners();
      return;
    }
    if (_runner == null) {
      stage = '走读能力不可用（未接入 Agent 内核）';
      notifyListeners();
      return;
    }
    final dir = Directory(path);
    if (!await dir.exists()) {
      stage = '工程目录不存在：$path';
      notifyListeners();
      return;
    }
    walking = true;
    walkLog.clear();
    _begin('正在走读工程源码…');
    try {
      final reporter = AgentReporter(
        onStatus: (m) {
          final t = m.trim();
          if (t.isEmpty) return;
          stage = _clip(t, 80);
          _log('status', t);
        },
        onAssistantText: (full) {
          final t = full.trim();
          if (t.isNotEmpty) _log('thought', _clip(t, 400));
        },
        onToolStart: (id, tool, title) {
          final t = title.trim().isEmpty ? tool : title.trim();
          stage = _clip(t, 80);
          _log('tool', t);
        },
        onToolEnd: (id, isError, result) {
          _log('result',
              isError ? '失败：${_clip(result.trim(), 200)}' : _oneLine(result));
        },
      );
      final result = await _runner!.run(
        dir: dir,
        systemPrompt: _walkSystem,
        initialMessages: [Msg.user(_walkTask(draft))],
        recallQuery: '为写推广文走读工程特点',
        reporter: reporter,
        isCancelled: () => _cancel,
        enableMemory: false,
        extractMemory: false,
        maxTurns: 40,
        maxDepth: 2,
      );
      final brief = result.lastText.trim();
      if (brief.isEmpty) throw Exception('未能从源码提炼出特点');
      draft.projectBrief = brief;
      if (draft.appName.trim().isEmpty || draft.appName == '未命名应用') {
        draft.appName = p.basename(path);
      }
      draft.updatedAt = DateTime.now();
      _log('status', brief.isEmpty ? '未提炼到特点' : '已提炼工程特点');
      stage = _cancel ? '已停止' : '已走读源码并提炼特点';
      await _persist();
    } catch (e) {
      _log('status', '走读失败：$e');
      stage = _cancel ? '已停止' : '走读失败：$e';
    } finally {
      walking = false;
      _end();
      await _persist();
    }
  }

  void _log(String kind, String text) {
    walkLog.add(PromoLogEntry(kind, text));
    notifyListeners();
  }

  /// 把（可能多行/很长的）工具结果压成一行摘要，便于日志展示。
  static String _oneLine(String s) {
    final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '完成';
    return _clip(flat, 160);
  }

  static const _walkSystem = '''
你是资深产品分析师 + 内容营销专家。你正在阅读一个真实软件工程的源码，目标是为撰写「知乎推广推文」提炼接地气、准确、有说服力的产品特点。

工作方式（agentic 检索，边读边定位）：
- 先看 README / pubspec.yaml / package.json 等工程说明与依赖，判断技术栈与产品定位；
- 用 glob 找入口与主要目录，用 grep 按关键词/符号定位功能，用 read_file 精读关键文件（入口、路由/导航、核心服务层、主要 UI 页面）；
- 命中后精读对应区间，不要逐个文件整读；严禁臆造源码中不存在的功能、数据或指标。

最终只输出一份用于写推广文的产品说明（Markdown），不要再调用工具、不要输出走读过程。''';

  String _walkTask(PromoDraft draft) => '''
请走读当前工程的源码，为撰写这个应用的知乎推广推文提炼真实、具体的产品特点。
应用名称（可能不准，以源码为准）：${draft.appName}
${draft.appIntro.trim().isEmpty ? '' : '已有简介：${draft.appIntro.trim()}\n'}
请最终按下面结构输出 Markdown（每一点都必须基于你在源码里看到的真实实现）：
## 一句话定位
## 目标用户
## 核心功能（分点，每点说明实际能做什么、对应哪个模块/能力）
## 技术亮点 / 差异化
## 典型使用场景
## 可写进推文的真实细节与卖点''';

  // ---------------------------------------------------------------------------
  // ① 生成候选标题
  // ---------------------------------------------------------------------------

  Future<void> generateTitles() async {
    final draft = current;
    if (draft == null || busy) return;
    if (draft.appName.trim().isEmpty) {
      stage = '请先填写应用名称';
      notifyListeners();
      return;
    }
    _begin('正在拟定知乎标题…');
    try {
      final reply = await _chat([
        {
          'role': 'system',
          'content':
              '你是资深知乎创作者与内容营销专家，擅长写出高点击、不标题党但有钩子的知乎标题。只输出 JSON，不要解释。',
        },
        {'role': 'user', 'content': _titlePrompt(draft)},
      ], jsonMode: true);
      final j = _parseJson(reply);
      final raw = (j['titles'] as List?) ?? [];
      final titles = raw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (titles.isEmpty) throw Exception('模型未返回标题');
      draft.titleOptions = titles;
      // 若还没有选定标题，默认用第一个。
      if (draft.title.trim().isEmpty) draft.title = titles.first;
      draft.updatedAt = DateTime.now();
      stage = '已生成 ${titles.length} 个候选标题';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '生成标题失败：$e';
    } finally {
      _end();
    }
  }

  void selectTitle(String title) {
    final draft = current;
    if (draft == null) return;
    draft.title = title;
    draft.updatedAt = DateTime.now();
    notifyListeners();
    _persist();
  }

  // ---------------------------------------------------------------------------
  // ② 生成推文正文（流式）
  // ---------------------------------------------------------------------------

  Future<void> generatePost() async {
    final draft = current;
    if (draft == null || busy) return;
    if (draft.appName.trim().isEmpty) {
      stage = '请先填写应用名称';
      notifyListeners();
      return;
    }
    _begin('正在撰写知乎推文…');
    try {
      draft.content = '';
      notifyListeners();
      var acc = '';
      await for (final delta in _streamChat([
        {
          'role': 'system',
          'content':
              '你是资深知乎创作者与内容营销高手，擅长写高赞的种草/推荐长文。'
                  '直接输出推文正文的 Markdown，不要输出解释，不要代码围栏，不要重复标题。',
        },
        {'role': 'user', 'content': _postPrompt(draft)},
      ])) {
        if (_cancel) break;
        acc += delta;
        draft.content = acc;
        notifyListeners();
      }
      draft.content = acc.trim();
      draft.updatedAt = DateTime.now();
      stage = _cancel ? '已停止' : '知乎推文已生成';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '生成推文失败：$e';
    } finally {
      _end();
      await _persist();
    }
  }

  void cancel() {
    if (!busy) return;
    _cancel = true;
    stage = '正在停止…';
    notifyListeners();
  }

  /// 导出为 Markdown 到知识库「4-书稿/推广」目录，返回文件路径。
  Future<String> export() async {
    final draft = current;
    if (draft == null) throw StateError('未打开推广稿');
    final dir = Directory(p.join(settings.vaultPath, '4-书稿', '推广'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, '${_sanitize(draft.title.isEmpty ? draft.appName : draft.title)}.md'));
    final buf = StringBuffer()
      ..writeln('# ${draft.title.isEmpty ? draft.appName : draft.title}')
      ..writeln()
      ..writeln('> 平台：知乎 · 应用：${draft.appName}')
      ..writeln()
      ..writeln(draft.content.trim());
    await file.writeAsString(buf.toString());
    return file.path;
  }

  // ---------------------------------------------------------------------------
  // 提示词
  // ---------------------------------------------------------------------------

  String _appBlock(PromoDraft draft) {
    final buf = StringBuffer()
      ..writeln('应用名称：${draft.appName}')
      ..writeln('应用简介与核心功能：${draft.appIntro.isEmpty ? '（未填写，请结合下方走读要点/应用名称合理归纳，不要编造不存在的功能）' : draft.appIntro}')
      ..writeln('卖点/亮点：${draft.sellingPoints.isEmpty ? '（未填写，请从简介与走读要点中提炼）' : draft.sellingPoints}')
      ..writeln('目标读者：${draft.audience.isEmpty ? '（未指定）' : draft.audience}')
      ..writeln('切入角度：${draft.angle.isEmpty ? '（自选最合适的角度）' : draft.angle}')
      ..write('语气风格：${draft.tone}');
    if (draft.hasProjectBrief) {
      buf
        ..writeln()
        ..writeln()
        ..writeln('【工程源码走读要点（基于真实代码提炼，务必据此写作，让内容接地气、准确，不要臆造）】')
        ..write(_clip(draft.projectBrief.trim(), 6000));
    }
    return buf.toString();
  }

  String _titlePrompt(PromoDraft draft) => '''
为下面这个应用写一组适合「知乎」的推广文标题。
${_appBlock(draft)}

要求：
- 给出 6 个候选标题，风格贴合知乎：有场景感或钩子、能激发点击，但不要虚假夸大、不要标题党。
- 可用知乎常见形式：提问式（如“有哪些……”“……是一种怎样的体验”）、经验分享式、对比式、清单式等，风格多样。
- 标题简洁，控制在 30 字以内。

严格输出 JSON：
{"titles":["标题1","标题2","标题3","标题4","标题5","标题6"]}''';

  String _postPrompt(PromoDraft draft) {
    final titleLine = draft.title.trim().isEmpty
        ? '（未指定标题，请自拟一个合适的标题作为正文第一行的一级标题）'
        : draft.title.trim();
    return '''
请为下面这个应用写一篇可直接发布在「知乎」的推广推文。
${_appBlock(draft)}

拟用标题：$titleLine

知乎推文写作要求：
- 以真实体验或专业视角切入，开头用一个能引发目标读者共鸣的场景或痛点做钩子，不要一上来就硬广。
- 中间提供有价值的干货和具体使用场景，把应用的功能与卖点自然融入“我是怎么解决问题的”叙述里。
- 语言口语化、有个人色彩、真诚可信，符合知乎社区调性；适当用小标题、分点、加粗提升可读性。
- 结尾自然地引导读者去了解/试用该应用（如点明适合什么样的人、在哪里可以获取），不要生硬叫卖。
- 若提供了「工程源码走读要点」，务必据此描述真实功能与细节，让推文接地气、可信，避免空泛套话；不得编造走读要点里没有的功能。
- 篇幅约 800-1500 字。不得编造不存在的具体数据、评分、用户数或功能。
- 只输出推文正文的 Markdown（若未指定标题，第一行用 `# 标题` 给出标题），不要输出任何额外解释。''';
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  void _begin(String message) {
    busy = true;
    _cancel = false;
    stage = message;
    notifyListeners();
  }

  void _end() {
    busy = false;
    _cancel = false;
    notifyListeners();
  }

  Future<void> _persist() async {
    if (_store == null) return;
    try {
      await _store!.writeAsString(
        jsonEncode(drafts.map((d) => d.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<String> _chat(
    List<Map<String, dynamic>> messages, {
    bool jsonMode = false,
  }) async {
    final content = await ModelClient(settings, role: ModelRole.writing)
        .complete(
          messages: messages,
          jsonMode: jsonMode,
          isCancelled: () => _cancel,
          timeout: const Duration(minutes: 3),
        );
    if (content.isEmpty) throw Exception('模型未返回内容');
    return content;
  }

  Stream<String> _streamChat(List<Map<String, dynamic>> messages) {
    final controller = StreamController<String>();
    () async {
      try {
        await ModelClient(settings, role: ModelRole.writing).stream(
          messages: messages,
          onTextDelta: (delta) {
            if (!controller.isClosed) controller.add(delta);
          },
          isCancelled: () => _cancel,
          timeout: const Duration(minutes: 6),
        );
      } catch (e) {
        if (!controller.isClosed) controller.addError(e);
      } finally {
        await controller.close();
      }
    }();
    return controller.stream;
  }

  Map<String, dynamic> _parseJson(String reply) {
    final start = reply.indexOf('{');
    final end = reply.lastIndexOf('}');
    if (start < 0 || end <= start) throw Exception('模型未返回 JSON');
    return jsonDecode(reply.substring(start, end + 1)) as Map<String, dynamic>;
  }

  static String _clip(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);

  static String _sanitize(String value) {
    var out = value.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    if (out.length > 80) out = out.substring(0, 80).trim();
    return out.isEmpty ? '知乎推文' : out;
  }
}
