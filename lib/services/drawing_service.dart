import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/text_util.dart';
import 'agent/model_client.dart';
import 'document_service.dart';
import 'project_context_builder.dart';
import 'project_service.dart';
import 'settings_service.dart';

/// 画图可选的图种。每种对应一套 Mermaid 生成侧重点。
enum DiagramKind {
  system,
  layered,
  deployment,
  dataflow,
  module,
  sequence,
  flow;

  String get label => switch (this) {
    DiagramKind.system => '系统架构图',
    DiagramKind.layered => '分层架构图',
    DiagramKind.deployment => '部署架构图',
    DiagramKind.dataflow => '数据流图',
    DiagramKind.module => '模块依赖图',
    DiagramKind.sequence => '时序图',
    DiagramKind.flow => '业务流程图',
  };

  /// 给模型的画法侧重点说明。
  String get guide => switch (this) {
    DiagramKind.system =>
      '系统架构图：用 flowchart TB，配合 subgraph 按「接入层 / 应用层 / 服务层 / 数据层 / 基础设施」等维度分层，'
          '清晰体现各子系统、核心模块及其调用/依赖方向，边上标注协议或数据（如 HTTP、gRPC、事件）。',
    DiagramKind.layered =>
      '分层架构图：用 flowchart TB，自上而下划分表现层、业务逻辑层、领域/服务层、数据访问层、基础设施层，'
          '每层用 subgraph 包裹，层与层之间用箭头表达依赖方向。',
    DiagramKind.deployment =>
      '部署架构图：用 flowchart LR/TB，以节点/容器/服务器/中间件为单位（客户端、网关、应用节点、缓存、数据库、消息队列、对象存储等），'
          '用 subgraph 表示可用区/集群/网络边界，边上标注端口或协议。',
    DiagramKind.dataflow =>
      '数据流图：用 flowchart LR，从数据来源 → 采集/接入 → 处理/计算 → 存储 → 消费/输出，'
          '节点表示处理过程，边表示数据流动并标注数据内容。',
    DiagramKind.module =>
      '模块依赖图：用 flowchart LR，以工程真实的包/目录/核心模块为节点，箭头表示依赖方向，用 subgraph 聚合同类模块。',
    DiagramKind.sequence =>
      '时序图：用 sequenceDiagram，选择系统最核心的一条端到端调用链，列出关键参与者（participant），'
          '按时间顺序展开同步/异步消息、返回与关键分支（alt/opt）。',
    DiagramKind.flow =>
      '业务流程图：用 flowchart TB，从触发开始，经关键处理步骤与判定分支（菱形），到结束，覆盖主流程与重要异常分支。',
  };

  static DiagramKind fromName(String? name) => DiagramKind.values.firstWhere(
    (e) => e.name == name,
    orElse: () => DiagramKind.system,
  );
}

/// 画图关联的工程（真实工程目录）。
class DrawingProjectRef {
  DrawingProjectRef({required this.path});

  final String path;

  String get name => path.isEmpty ? '' : p.basename(path);

  Map<String, dynamic> toJson() => {'path': path};

  factory DrawingProjectRef.fromJson(Map<String, dynamic> json) =>
      DrawingProjectRef(path: json['path'] as String? ?? '');
}

/// 一张图：主题需求 + 关联工程 + 图种 + Mermaid 源码 + 渲染 PNG。
class DrawingDoc {
  DrawingDoc({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.prompt = '',
    this.kind = DiagramKind.system,
    List<DrawingProjectRef>? linkedProjects,
    this.mermaid = '',
    this.imagePath = '',
    this.summary = '',
  }) : linkedProjects = linkedProjects ?? [];

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;

  /// 画图需求 / 补充说明（可选，指导重点与取舍）。
  String prompt;

  DiagramKind kind;

  /// 关联的工程（可 1 个或多个组合），用于据真实代码结构出图。
  List<DrawingProjectRef> linkedProjects;

  /// 生成/编辑后的 Mermaid 源码。
  String mermaid;

  /// 渲染出的 PNG 绝对路径（可能为空，表示未渲染或渲染失败）。
  String imagePath;

  /// 对该图的一句话说明（模型给出）。
  String summary;

  bool get hasImage =>
      imagePath.trim().isNotEmpty && File(imagePath).existsSync();
  bool get hasMermaid => mermaid.trim().isNotEmpty;
  String get linkedNames =>
      linkedProjects.map((e) => e.name).where((e) => e.isNotEmpty).join('、');

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'prompt': prompt,
    'kind': kind.name,
    'linkedProjects': linkedProjects.map((e) => e.toJson()).toList(),
    'mermaid': mermaid,
    'imagePath': imagePath,
    'summary': summary,
  };

  factory DrawingDoc.fromJson(Map<String, dynamic> json) => DrawingDoc(
    id: json['id'] as String,
    title: json['title'] as String? ?? '未命名图',
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
    prompt: json['prompt'] as String? ?? '',
    kind: DiagramKind.fromName(json['kind'] as String?),
    linkedProjects: ((json['linkedProjects'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => DrawingProjectRef.fromJson(e.cast<String, dynamic>()))
        .toList(),
    mermaid: json['mermaid'] as String? ?? '',
    imagePath: json['imagePath'] as String? ?? '',
    summary: json['summary'] as String? ?? '',
  );
}

/// 「画图」业务：据关联工程（真实代码结构）用大模型产出漂亮、完整的架构图
/// （Mermaid），再本地渲染成高清 PNG。
class DrawingService extends ChangeNotifier {
  DrawingService(this.settings, {this.project, required this.document});

  final SettingsService settings;

  /// 项目服务（桌面端），用于列出最近打开的工程供快速关联；移动端为空。
  final ProjectService? project;

  /// 复用文档服务的 Mermaid → PNG 渲染管线（本机无头浏览器）。
  final DocumentService document;

  List<String> get recentProjects => project?.projects ?? const [];

  final List<DrawingDoc> docs = [];
  DrawingDoc? current;
  bool busy = false;
  String stage = '';

  /// 关联工程上下文注入 prompt 的总长度上限，避免超出模型上下文。
  static const _maxContextChars = 60000;

  bool _cancel = false;
  File? _store;
  Directory? _assetDir;

  late final ProjectContextBuilder _ctx = ProjectContextBuilder(settings);

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _store = File(p.join(dir.path, 'drawings.json'));
    _assetDir = Directory(p.join(dir.path, 'drawing_assets'));
    try {
      await _assetDir!.create(recursive: true);
    } catch (_) {}
    if (await _store!.exists()) {
      try {
        final data = jsonDecode(await _store!.readAsString());
        if (data is List) {
          docs
            ..clear()
            ..addAll(
              data.whereType<Map>().map(
                (e) => DrawingDoc.fromJson(e.cast<String, dynamic>()),
              ),
            );
          docs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        }
      } catch (_) {}
    }
  }

  DrawingDoc create({
    String title = '',
    String prompt = '',
    DiagramKind kind = DiagramKind.system,
    List<String> projectPaths = const [],
  }) {
    final now = DateTime.now();
    final doc = DrawingDoc(
      id: now.microsecondsSinceEpoch.toString(),
      title: title.trim().isEmpty ? '未命名图' : title.trim(),
      createdAt: now,
      updatedAt: now,
      prompt: prompt.trim(),
      kind: kind,
      linkedProjects: [
        for (final path in projectPaths.toSet()) DrawingProjectRef(path: path),
      ],
    );
    docs.insert(0, doc);
    current = doc;
    notifyListeners();
    _persist();
    return doc;
  }

  void open(DrawingDoc doc) {
    current = doc;
    notifyListeners();
  }

  void close() {
    current = null;
    notifyListeners();
  }

  Future<void> delete(DrawingDoc doc) async {
    docs.remove(doc);
    if (current == doc) current = null;
    if (doc.imagePath.isNotEmpty) {
      try {
        final f = File(doc.imagePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    notifyListeners();
    await _persist();
  }

  Future<void> save() async {
    final doc = current;
    if (doc == null) return;
    doc.updatedAt = DateTime.now();
    docs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    notifyListeners();
    await _persist();
  }

  void addLinkedProject(String path) {
    final doc = current;
    if (doc == null) return;
    final normalized = path.trim();
    if (normalized.isEmpty) return;
    if (doc.linkedProjects.any((e) => e.path == normalized)) return;
    doc.linkedProjects.add(DrawingProjectRef(path: normalized));
    doc.updatedAt = DateTime.now();
    notifyListeners();
    _persist();
  }

  void removeLinkedProject(String path) {
    final doc = current;
    if (doc == null) return;
    doc.linkedProjects.removeWhere((e) => e.path == path);
    doc.updatedAt = DateTime.now();
    notifyListeners();
    _persist();
  }

  void setKind(DiagramKind kind) {
    final doc = current;
    if (doc == null) return;
    doc.kind = kind;
    doc.updatedAt = DateTime.now();
    notifyListeners();
    _persist();
  }

  /// 生成图：据关联工程真实代码结构 + 需求，用大模型产出漂亮完整的 Mermaid，
  /// 再渲染成 PNG。无关联工程时，仅据主题/需求出图。
  Future<void> generate([DrawingDoc? target]) async {
    final doc = target ?? current;
    if (doc == null || busy) return;
    _begin('正在准备…');
    try {
      final paths = doc.linkedProjects
          .map((e) => e.path)
          .where((e) => e.trim().isNotEmpty)
          .toList();
      var context = '';
      if (paths.isNotEmpty) {
        stage = '正在读取工程结构与代码…';
        notifyListeners();
        context = await _ctx.buildPack(
          paths,
          doc.prompt.isEmpty ? doc.title : doc.prompt,
          log: (line) {
            stage = line.trim();
            notifyListeners();
          },
        );
      }
      if (_cancel) return;
      stage = '正在设计${doc.kind.label}…';
      notifyListeners();
      final result = await _designDiagram(doc, context);
      if (_cancel) return;
      doc.mermaid = result.$1;
      if (result.$2.trim().isNotEmpty) doc.summary = result.$2.trim();
      doc.updatedAt = DateTime.now();
      notifyListeners();
      await _persist();

      stage = '正在渲染高清图…';
      notifyListeners();
      await _render(doc);
      stage = doc.hasImage ? '已生成${doc.kind.label}' : '已生成图定义（未能渲染为图片，可查看/编辑源码）';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '生成失败：$e';
    } finally {
      if (_cancel) stage = '已停止';
      _end();
    }
  }

  /// 停止正在进行的生成（仅对大模型设计阶段有效；渲染阶段无法中断）。
  void cancel() {
    if (!busy) return;
    _cancel = true;
    stage = '正在停止…';
    notifyListeners();
  }

  /// 用当前 Mermaid 源码重新渲染 PNG（用于手动编辑源码后刷新）。
  Future<void> rerender([DrawingDoc? target]) async {
    final doc = target ?? current;
    if (doc == null || busy) return;
    if (!doc.hasMermaid) {
      stage = '暂无图定义可渲染';
      notifyListeners();
      return;
    }
    _begin('正在渲染高清图…');
    try {
      await _render(doc);
      stage = doc.hasImage ? '已渲染' : '渲染失败：请检查 Mermaid 源码或本机浏览器（Edge/Chrome）';
      await _persist();
    } catch (e) {
      stage = '渲染失败：$e';
    } finally {
      _end();
    }
  }

  Future<void> _render(DrawingDoc doc) async {
    final png = await document.renderMermaidPng(doc.mermaid);
    if (png == null) {
      doc.imagePath = '';
      return;
    }
    final dir = _assetDir;
    if (dir == null) return;
    final out = File(p.join(dir.path, '${doc.id}.png'));
    await out.writeAsBytes(png, flush: true);
    doc.imagePath = out.path;
    doc.updatedAt = DateTime.now();
  }

  Future<(String, String)> _designDiagram(DrawingDoc doc, String context) async {
    final reply = await ModelClient(settings, role: ModelRole.writing).complete(
      system:
          '你是资深软件架构师与图形设计专家。你依据给定的真实工程信息与需求，产出一张既专业又美观、'
          '结构完整的架构图（Mermaid）。你严格使用合法 Mermaid 语法，不臆造工程中不存在的模块。'
          '只输出一个 JSON 对象，不要解释、不要代码围栏。',
      user: _designPrompt(doc, context),
      jsonMode: true,
      isCancelled: () => _cancel,
    );
    final obj = ModelClient.parseJsonObject(reply);
    var mermaid = (obj['mermaid'] ?? '').toString();
    mermaid = _cleanMermaid(mermaid);
    if (mermaid.trim().isEmpty) throw Exception('模型未返回有效的 Mermaid 图定义');
    final summary = (obj['summary'] ?? '').toString();
    return (mermaid, summary);
  }

  String _designPrompt(DrawingDoc doc, String context) {
    final ctxBlock = context.trim().isEmpty
        ? '（未关联工程，请依据主题与需求，产出一张合理、通用且完整的图）'
        : _clip(context, _maxContextChars);
    final needBlock = doc.prompt.trim().isEmpty
        ? ''
        : '\n【额外需求 / 侧重点】\n${doc.prompt.trim()}\n';
    return '''
请为主题「${doc.title}」设计一张 **${doc.kind.label}**，用 Mermaid 表达。

绘制要求（${doc.kind.label}）：
${doc.kind.guide}
$needBlock
【出图质量要求——务必做到漂亮、完整、专业】
- 结构完整：覆盖该图应有的关键要素与关系，不遗漏主干；节点数量控制在 12~30 个之间，既充实又不杂乱。
- 分组清晰：用 subgraph 对同类要素分组，组名用中文、有业务含义；相关联的模块就近摆放，减少连线交叉。
- 连线达意：箭头方向表达真实的依赖/调用/数据流向；关键连线用 `|"文字"|` 标注协议或数据，避免无意义的连线。
- 美观配色：用 classDef 定义 5~7 组语义化配色（柔和、对比清晰、专业，如接入=蓝、应用=青、服务=绿、数据=橙、基础设施=灰）。
- 可读排版：显式指定方向（TB 或 LR）；显示文字用中文、简洁。

Mermaid 语法纪律（必须严格遵守，否则会渲染失败）：
- 第一行是图类型与方向，如 `flowchart TB`。
- 所有 **节点 id 和 subgraph id 只用英文字母/数字、无空格、无中文**；中文只出现在“显示标签”里。
- **每个节点标签一律用英文双引号包裹**：如 `A["用户交互层"]`、圆柱体 `DB[("关系数据库<br/>MySQL")]`；标签内换行只用 `<br/>`（且必须在引号内）。
- **样式一律用行末的 `class` 语句成组应用，禁止使用行内 `:::` 写法**：即 `class 节点id1,节点id2 类名;`。
- subgraph 写法：`subgraph sgId["中文标题"]` … 内容 … `end`。
- 不要 click 语句、不要除 `<br/>` 外的 HTML 标签、不要 emoji。

请严格参照下面这段**可正确渲染**的写法风格（仅示意结构，请用真实内容替换）：
flowchart TB
  subgraph ui["用户交互层"]
    Web["Web 浏览器/SPA"]
    Desktop["桌面客户端"]
  end
  subgraph data["数据存储层"]
    DB[("关系数据库<br/>MySQL/SQLite")]
  end
  Web -->|"HTTP REST"| DB
  Desktop -->|"HTTP REST"| DB
  classDef uiCls fill:#e3f2fd,stroke:#1565c0,stroke-width:2px,color:#0d47a1;
  classDef dataCls fill:#f3e5f5,stroke:#6a1b9a,stroke-width:2px,color:#4a148c;
  class Web,Desktop uiCls;
  class DB dataCls;

只输出一个 JSON 对象（无围栏、无多余文字）：
{"mermaid":"<完整 mermaid 源码>","summary":"<一句话说明这张图画了什么>"}

【工程信息（真实、供你据实出图）】
$ctxBlock
''';
  }

  /// 去掉模型可能残留的 ```mermaid 围栏。
  static String _cleanMermaid(String raw) {
    var s = raw.trim();
    final fence = RegExp(r'^```(?:mermaid)?\s*([\s\S]*?)\s*```$').firstMatch(s);
    if (fence != null) s = fence.group(1)!.trim();
    return s;
  }

  static String _clip(String s, int max) =>
      clip(s, max, suffix: '\n…（内容过长已截断）');

  void _begin(String message) {
    busy = true;
    _cancel = false;
    stage = message;
    notifyListeners();
  }

  void _end() {
    busy = false;
    notifyListeners();
  }

  Future<void> _persist() async {
    if (_store == null) return;
    try {
      await _store!.writeAsString(
        jsonEncode(docs.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }
}
