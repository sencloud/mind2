import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 系统功能树的一个节点（功能分类 → 子分类），可挂载该节点的详细设计文档。
class FuncNode {
  FuncNode({
    required this.id,
    required this.title,
    this.desc = '',
    List<FuncNode>? children,
    this.detailMarkdown = '',
    this.detailDocxPath = '',
    this.detailUpdatedAt,
  }) : children = children ?? [];

  final String id;
  String title;
  String desc;
  List<FuncNode> children;

  /// 该节点的详细设计文档（Markdown 正文），为空表示尚未编写。
  String detailMarkdown;

  /// 该节点导出的 docx 绝对路径（可能为空）。
  String detailDocxPath;
  DateTime? detailUpdatedAt;

  bool get hasDetail => detailMarkdown.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'desc': desc,
        'children': children.map((c) => c.toJson()).toList(),
        'detailMarkdown': detailMarkdown,
        'detailDocxPath': detailDocxPath,
        'detailUpdatedAt': detailUpdatedAt?.toIso8601String(),
      };

  factory FuncNode.fromJson(Map<String, dynamic> j) => FuncNode(
        id: j['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
        title: j['title'] as String? ?? '',
        desc: j['desc'] as String? ?? '',
        children: ((j['children'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => FuncNode.fromJson(e.cast<String, dynamic>()))
            .toList(),
        detailMarkdown: j['detailMarkdown'] as String? ?? '',
        detailDocxPath: j['detailDocxPath'] as String? ?? '',
        detailUpdatedAt: DateTime.tryParse(j['detailUpdatedAt'] as String? ?? ''),
      );

  /// 在树中按 id 深度查找节点。
  FuncNode? find(String targetId) {
    if (id == targetId) return this;
    for (final c in children) {
      final hit = c.find(targetId);
      if (hit != null) return hit;
    }
    return null;
  }
}

/// 一份批量生成的项目文档（对应某个标准分类），记录正文与导出路径。
class GeneratedDoc {
  GeneratedDoc({
    required this.categoryId,
    required this.name,
    this.docxPath = '',
    this.markdown = '',
    this.updatedAt,
  });

  final String categoryId;
  String name;
  String docxPath;
  String markdown;
  DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
        'categoryId': categoryId,
        'name': name,
        'docxPath': docxPath,
        'markdown': markdown,
        'updatedAt': updatedAt?.toIso8601String(),
      };

  factory GeneratedDoc.fromJson(Map<String, dynamic> j) => GeneratedDoc(
        categoryId: j['categoryId'] as String? ?? '',
        name: j['name'] as String? ?? '',
        docxPath: j['docxPath'] as String? ?? '',
        markdown: j['markdown'] as String? ?? '',
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
      );
}

/// 架构图中的一个可点击节点：图中标签 → 工程内相对路径（文件或目录）。
class ArchNode {
  ArchNode({required this.label, this.path = ''});

  final String label;

  /// 工程内相对路径；为空表示模型推断（Inferred）、无法定位。
  final String path;

  Map<String, dynamic> toJson() => {'label': label, 'path': path};

  factory ArchNode.fromJson(Map<String, dynamic> j) => ArchNode(
        label: j['label'] as String? ?? '',
        path: j['path'] as String? ?? '',
      );
}

/// 一张架构图：kind（system/directory/flow）+ 作用域（下钻层级）+ Mermaid 源码
/// + 渲染 PNG + 节点映射。scope 为空表示整个工程（根层）。
class ArchDiagram {
  ArchDiagram({
    required this.kind,
    this.scopeLabel = '',
    this.scopePath = '',
    this.mermaid = '',
    this.imagePath = '',
    List<ArchNode>? nodes,
    this.updatedAt,
  }) : nodes = nodes ?? [];

  /// system=系统架构，directory=目录结构，flow=主流程。
  final String kind;

  /// 下钻作用域：节点显示名（如「后端API服务」）；空 = 根层（整个工程）。
  final String scopeLabel;

  /// 下钻作用域对应的工程内相对路径（可能为空，仅按名称聚焦）。
  final String scopePath;
  String mermaid;
  String imagePath;
  List<ArchNode> nodes;
  DateTime? updatedAt;

  /// 同 kind 下区分不同下钻层级的键。
  String get scopeKey => scopePath.isNotEmpty ? scopePath : scopeLabel;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'scopeLabel': scopeLabel,
        'scopePath': scopePath,
        'mermaid': mermaid,
        'imagePath': imagePath,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'updatedAt': updatedAt?.toIso8601String(),
      };

  factory ArchDiagram.fromJson(Map<String, dynamic> j) => ArchDiagram(
        kind: j['kind'] as String? ?? 'system',
        scopeLabel: j['scopeLabel'] as String? ?? '',
        scopePath: j['scopePath'] as String? ?? '',
        mermaid: j['mermaid'] as String? ?? '',
        imagePath: j['imagePath'] as String? ?? '',
        nodes: ((j['nodes'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => ArchNode.fromJson(e.cast<String, dynamic>()))
            .toList(),
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
      );
}

/// 一条「与项目对话」问答记录。
class QaItem {
  QaItem({required this.question, required this.answer, this.at});

  final String question;
  final String answer;
  final DateTime? at;

  Map<String, dynamic> toJson() => {
        'question': question,
        'answer': answer,
        'at': at?.toIso8601String(),
      };

  factory QaItem.fromJson(Map<String, dynamic> j) => QaItem(
        question: j['question'] as String? ?? '',
        answer: j['answer'] as String? ?? '',
        at: DateTime.tryParse(j['at'] as String? ?? ''),
      );
}

/// 一段「与项目对话」会话：包含多轮问答，可切换、导出、删除。
class QaSession {
  QaSession({
    required this.id,
    this.title = '新对话',
    List<QaItem>? items,
    this.createdAt,
    this.updatedAt,
  }) : items = items ?? [];

  final String id;
  String title;
  List<QaItem> items;
  DateTime? createdAt;
  DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'items': items.map((e) => e.toJson()).toList(),
        'createdAt': createdAt?.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
      };

  factory QaSession.fromJson(Map<String, dynamic> j) => QaSession(
        id: j['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        title: j['title'] as String? ?? '新对话',
        items: ((j['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => QaItem.fromJson(e.cast<String, dynamic>()))
            .toList(),
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
      );
}

/// 某个工程的「文档撰写」记录：工程分析、系统功能树、已生成文档。
class ProjectDocRecord {
  ProjectDocRecord({
    required this.projectPath,
    this.projectName = '',
    this.analysis = '',
    this.overviewMarkdown = '',
    this.depth = 'standard',
    List<FuncNode>? functionTree,
    List<GeneratedDoc>? docs,
    List<ArchDiagram>? diagrams,
    List<QaItem>? qaHistory,
    List<QaSession>? qaSessions,
    this.generatedAt,
  })  : functionTree = functionTree ?? [],
        docs = docs ?? [],
        diagrams = diagrams ?? [],
        qaHistory = qaHistory ?? [],
        qaSessions = qaSessions ?? [];

  final String projectPath;
  String projectName;

  /// 工程分析文本（供功能树/详细设计文档复用，避免重复深读代码）。
  String analysis;

  /// 结构化项目概览（13 段结构、证据标签、ref: 引用）。
  String overviewMarkdown;

  /// 分析深度：quick / standard / deep / audit。
  String depth;

  /// 系统功能分类 → 子分类 树。
  List<FuncNode> functionTree;

  /// 批量生成的标准文档清单。
  List<GeneratedDoc> docs;

  /// 交互式架构图（按 kind 各存一张）。
  List<ArchDiagram> diagrams;

  /// 「与项目对话」历史。
  /// 旧版单一问答列表（保留用于向后读取迁移到 qaSessions）。
  List<QaItem> qaHistory;

  /// 「与项目对话」多会话历史（最新在前）。
  List<QaSession> qaSessions;
  DateTime? generatedAt;

  bool get isEmpty =>
      analysis.trim().isEmpty && functionTree.isEmpty && docs.isEmpty;

  /// 按 kind + 作用域查图；scopeKey 空串表示根层。
  ArchDiagram? diagramFor(String kind, {String scopeKey = ''}) {
    for (final d in diagrams) {
      if (d.kind == kind && d.scopeKey == scopeKey) return d;
    }
    return null;
  }

  GeneratedDoc? docFor(String categoryId) {
    for (final d in docs) {
      if (d.categoryId == categoryId) return d;
    }
    return null;
  }

  QaSession? sessionFor(String id) {
    for (final s in qaSessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  FuncNode? findNode(String id) {
    for (final n in functionTree) {
      final hit = n.find(id);
      if (hit != null) return hit;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'projectPath': projectPath,
        'projectName': projectName,
        'analysis': analysis,
        'overviewMarkdown': overviewMarkdown,
        'depth': depth,
        'functionTree': functionTree.map((n) => n.toJson()).toList(),
        'docs': docs.map((d) => d.toJson()).toList(),
        'diagrams': diagrams.map((d) => d.toJson()).toList(),
        'qaSessions': qaSessions.map((s) => s.toJson()).toList(),
        'generatedAt': generatedAt?.toIso8601String(),
      };

  factory ProjectDocRecord.fromJson(Map<String, dynamic> j) => ProjectDocRecord(
        projectPath: j['projectPath'] as String? ?? '',
        projectName: j['projectName'] as String? ?? '',
        analysis: j['analysis'] as String? ?? '',
        overviewMarkdown: j['overviewMarkdown'] as String? ?? '',
        depth: j['depth'] as String? ?? 'standard',
        functionTree: ((j['functionTree'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => FuncNode.fromJson(e.cast<String, dynamic>()))
            .toList(),
        docs: ((j['docs'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => GeneratedDoc.fromJson(e.cast<String, dynamic>()))
            .toList(),
        diagrams: ((j['diagrams'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => ArchDiagram.fromJson(e.cast<String, dynamic>()))
            .toList(),
        qaHistory: ((j['qaHistory'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => QaItem.fromJson(e.cast<String, dynamic>()))
            .toList(),
        qaSessions: _readSessions(j),
        generatedAt: DateTime.tryParse(j['generatedAt'] as String? ?? ''),
      );

  /// 读取会话列表；若无新版会话但有旧版 qaHistory，则迁移为一个会话。
  static List<QaSession> _readSessions(Map<String, dynamic> j) {
    final raw = (j['qaSessions'] as List?) ?? const [];
    final sessions = raw
        .whereType<Map>()
        .map((e) => QaSession.fromJson(e.cast<String, dynamic>()))
        .toList();
    if (sessions.isNotEmpty) return sessions;
    final legacy = ((j['qaHistory'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => QaItem.fromJson(e.cast<String, dynamic>()))
        .toList();
    if (legacy.isEmpty) return [];
    return [
      QaSession(
        id: 'legacy_${DateTime.now().microsecondsSinceEpoch}',
        title: legacy.first.question.trim().isEmpty
            ? '历史对话'
            : legacy.first.question.trim(),
        items: legacy,
        createdAt: legacy.first.at,
        updatedAt: legacy.last.at,
      ),
    ];
  }
}

/// 按项目持久化「文档撰写」记录：每个工程一个 JSON 侧车文件，
/// 存放于 ApplicationSupport/project_docs/{清洗后的路径}.json。
class ProjectDocStore {
  Directory? _dir;

  Future<void> init() async {
    final base = await getApplicationSupportDirectory();
    _dir = Directory(p.join(base.path, 'project_docs'));
    try {
      await _dir!.create(recursive: true);
    } catch (_) {}
  }

  String _key(String projectPath) =>
      projectPath.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  File? _fileFor(String projectPath) {
    final dir = _dir;
    if (dir == null) return null;
    return File(p.join(dir.path, '${_key(projectPath)}.json'));
  }

  bool has(String projectPath) => _fileFor(projectPath)?.existsSync() ?? false;

  /// 该项目的附属资源文件路径（如架构图 PNG），位于 store 目录下。
  String? assetPath(String projectPath, String name) {
    final dir = _dir;
    if (dir == null) return null;
    return p.join(dir.path, '${_key(projectPath)}_$name');
  }

  Future<ProjectDocRecord> load(String projectPath) async {
    try {
      final f = _fileFor(projectPath);
      if (f != null && await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map) return ProjectDocRecord.fromJson(j.cast<String, dynamic>());
      }
    } catch (_) {}
    return ProjectDocRecord(projectPath: projectPath);
  }

  Future<void> save(ProjectDocRecord rec) async {
    final f = _fileFor(rec.projectPath);
    if (f == null) return;
    try {
      await f.writeAsString(jsonEncode(rec.toJson()));
    } catch (_) {}
  }
}
