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

/// 某个工程的「文档撰写」记录：工程分析、系统功能树、已生成文档。
class ProjectDocRecord {
  ProjectDocRecord({
    required this.projectPath,
    this.projectName = '',
    this.analysis = '',
    List<FuncNode>? functionTree,
    List<GeneratedDoc>? docs,
    this.generatedAt,
  })  : functionTree = functionTree ?? [],
        docs = docs ?? [];

  final String projectPath;
  String projectName;

  /// 工程分析文本（供功能树/详细设计文档复用，避免重复深读代码）。
  String analysis;

  /// 系统功能分类 → 子分类 树。
  List<FuncNode> functionTree;

  /// 批量生成的标准文档清单。
  List<GeneratedDoc> docs;
  DateTime? generatedAt;

  bool get isEmpty =>
      analysis.trim().isEmpty && functionTree.isEmpty && docs.isEmpty;

  GeneratedDoc? docFor(String categoryId) {
    for (final d in docs) {
      if (d.categoryId == categoryId) return d;
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
        'functionTree': functionTree.map((n) => n.toJson()).toList(),
        'docs': docs.map((d) => d.toJson()).toList(),
        'generatedAt': generatedAt?.toIso8601String(),
      };

  factory ProjectDocRecord.fromJson(Map<String, dynamic> j) => ProjectDocRecord(
        projectPath: j['projectPath'] as String? ?? '',
        projectName: j['projectName'] as String? ?? '',
        analysis: j['analysis'] as String? ?? '',
        functionTree: ((j['functionTree'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => FuncNode.fromJson(e.cast<String, dynamic>()))
            .toList(),
        docs: ((j['docs'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => GeneratedDoc.fromJson(e.cast<String, dynamic>()))
            .toList(),
        generatedAt: DateTime.tryParse(j['generatedAt'] as String? ?? ''),
      );
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
