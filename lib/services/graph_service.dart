import '../models.dart';
import '../util/text_util.dart';

enum GraphNodeType { note, category, tag }

enum GraphEdgeType { reference, category, tag }

class GraphNode {
  GraphNode({
    required this.id,
    required this.label,
    required this.type,
    this.note,
  });

  final String id;
  final String label;
  final GraphNodeType type;
  final StandardNote? note;

  /// 连接度，用于决定节点大小。
  int degree = 0;
}

class GraphEdge {
  GraphEdge(this.a, this.b, this.type);

  /// 节点在 nodes 列表中的下标。
  final int a;
  final int b;
  final GraphEdgeType type;
}

class GraphData {
  GraphData(
    this.nodes,
    this.edges,
    this._indexById, {
    required this.signature,
    required this.refDegreeByPath,
    required this.searchIndexByNode,
  }) : _neighborsByIndex = _buildNeighbors(nodes.length, edges),
       _neighborDetailsByIndex = _buildNeighborDetails(nodes.length, edges);

  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final Map<String, int> _indexById;
  final String signature;
  final Map<String, int> refDegreeByPath;
  final List<String> searchIndexByNode;
  final List<Set<int>> _neighborsByIndex;
  final List<List<(int, GraphEdgeType)>> _neighborDetailsByIndex;

  int? indexOf(String id) => _indexById[id];

  /// 与某节点直接相连的节点下标集合。
  Set<int> neighborsOf(int index) {
    if (index < 0 || index >= _neighborsByIndex.length) return {};
    return Set<int>.of(_neighborsByIndex[index]);
  }

  List<(GraphNode, GraphEdgeType)> neighborDetail(int index) {
    if (index < 0 || index >= _neighborDetailsByIndex.length) return [];
    return [
      for (final (neighbor, type) in _neighborDetailsByIndex[index])
        (nodes[neighbor], type),
    ];
  }

  static List<Set<int>> _buildNeighbors(int count, List<GraphEdge> edges) {
    final result = [for (var i = 0; i < count; i++) <int>{}];
    for (final e in edges) {
      result[e.a].add(e.b);
      result[e.b].add(e.a);
    }
    return result;
  }

  static List<List<(int, GraphEdgeType)>> _buildNeighborDetails(
    int count,
    List<GraphEdge> edges,
  ) {
    final result = [for (var i = 0; i < count; i++) <(int, GraphEdgeType)>[]];
    for (final e in edges) {
      result[e.a].add((e.b, e.type));
      result[e.b].add((e.a, e.type));
    }
    return result;
  }
}

class _PreparedNote {
  _PreparedNote({
    required this.note,
    required this.body,
    required this.baseNo,
    required this.title,
  });

  final StandardNote note;
  final String body;
  final String? baseNo;
  final String title;
}

class GraphBuilder {
  static GraphData? _cached;
  static ({String signature, Map<String, int> refDegree})? _cachedRefDegree;

  /// 规范化文本用于匹配：去空格、全角破折号统一。
  static String _norm(String s) =>
      s.replaceAll(RegExp(r'\s'), '').replaceAll('－', '—').toLowerCase();

  /// 标准号的"基号"（去掉年份），如 GB/T 18894—2016 -> gb/t18894
  static String? baseNo(String standardNo) {
    final n = _norm(standardNo);
    if (n.isEmpty) return null;
    final dash = n.indexOf('—');
    return dash > 0 ? n.substring(0, dash) : n;
  }

  /// 判断 from 的正文是否提及 to（标准号或题名）。
  static bool mentions(StandardNote from, StandardNote to) {
    if (from.filePath == to.filePath) return false;
    final body = _norm(from.body);
    final no = baseNo(to.standardNo);
    if (no != null && no.length >= 4 && body.contains(no)) return true;
    final title = _norm(to.fullTitle);
    if (title.length >= 6 && body.contains(title)) return true;
    return false;
  }

  /// 找出引用了 target 的所有笔记（反向链接）。
  static List<StandardNote> backlinks(
    List<StandardNote> all,
    StandardNote target,
  ) => [
    for (final n in all)
      if (mentions(n, target)) n,
  ];

  static String signatureOf(List<StandardNote> notes) {
    final parts = [
      for (final n in notes)
        '${n.filePath}|${n.modified.millisecondsSinceEpoch}|${n.body.length}|${n.fullTitle}|${n.standardNo}|${n.category}|${n.tags.join(',')}|${n.status}|${n.attachmentRelPath ?? ''}',
    ]..sort();
    return parts.join('\n');
  }

  static GraphData build(List<StandardNote> notes) => buildResult(notes);

  static GraphData? cachedResult(List<StandardNote> notes) {
    final signature = signatureOf(notes);
    final cached = _cached;
    return cached != null && cached.signature == signature ? cached : null;
  }

  static Map<String, int> referenceDegreeByPath(List<StandardNote> notes) {
    final signature = signatureOf(notes);
    final cachedGraph = _cached;
    if (cachedGraph != null && cachedGraph.signature == signature) {
      return cachedGraph.refDegreeByPath;
    }
    final cachedRef = _cachedRefDegree;
    if (cachedRef != null && cachedRef.signature == signature) {
      return cachedRef.refDegree;
    }
    final prepared = [
      for (final n in notes)
        _PreparedNote(
          note: n,
          body: _norm(n.body),
          baseNo: baseNo(n.standardNo),
          title: _norm(n.fullTitle),
        ),
    ];
    final refDegree = <String, int>{};
    for (var i = 0; i < notes.length; i++) {
      for (var j = 0; j < notes.length; j++) {
        if (i == j) continue;
        if (_mentionsPrepared(prepared[i], prepared[j])) {
          final from = notes[i].filePath;
          final to = notes[j].filePath;
          refDegree[from] = (refDegree[from] ?? 0) + 1;
          refDegree[to] = (refDegree[to] ?? 0) + 1;
        }
      }
    }
    _cachedRefDegree = (signature: signature, refDegree: refDegree);
    return refDegree;
  }

  static GraphData buildResult(List<StandardNote> notes) {
    final signature = signatureOf(notes);
    final cached = _cached;
    if (cached != null && cached.signature == signature) return cached;

    final nodes = <GraphNode>[];
    final indexById = <String, int>{};
    final prepared = [
      for (final n in notes)
        _PreparedNote(
          note: n,
          body: _norm(n.body),
          baseNo: baseNo(n.standardNo),
          title: _norm(n.fullTitle),
        ),
    ];

    int addNode(GraphNode node) {
      final existing = indexById[node.id];
      if (existing != null) return existing;
      nodes.add(node);
      indexById[node.id] = nodes.length - 1;
      return nodes.length - 1;
    }

    for (final n in notes) {
      addNode(
        GraphNode(
          id: n.filePath,
          label: n.fullTitle,
          type: GraphNodeType.note,
          note: n,
        ),
      );
    }

    final edges = <GraphEdge>[];
    final seen = <String>{};
    final refDegree = <String, int>{};
    void addEdge(int a, int b, GraphEdgeType type) {
      if (a == b) return;
      final key = a < b ? '$a-$b-${type.name}' : '$b-$a-${type.name}';
      if (!seen.add(key)) return;
      edges.add(GraphEdge(a, b, type));
      nodes[a].degree++;
      nodes[b].degree++;
      if (type == GraphEdgeType.reference) {
        final an = nodes[a].note;
        final bn = nodes[b].note;
        if (an != null) {
          refDegree[an.filePath] = (refDegree[an.filePath] ?? 0) + 1;
        }
        if (bn != null) {
          refDegree[bn.filePath] = (refDegree[bn.filePath] ?? 0) + 1;
        }
      }
    }

    // 笔记之间的引用关系
    for (var i = 0; i < notes.length; i++) {
      for (var j = 0; j < notes.length; j++) {
        if (i == j) continue;
        if (_mentionsPrepared(prepared[i], prepared[j])) {
          addEdge(i, j, GraphEdgeType.reference);
        }
      }
    }

    // 类别节点
    for (final n in notes) {
      final catId = 'cat:${n.category}';
      final catIndex = addNode(
        GraphNode(id: catId, label: n.category, type: GraphNodeType.category),
      );
      addEdge(indexById[n.filePath]!, catIndex, GraphEdgeType.category);
    }

    // 标签节点（排除类别名与通用标签，且至少被 2 篇笔记使用）
    final tagCount = <String, int>{};
    final categories = notes.map((n) => n.category).toSet();
    for (final n in notes) {
      for (final t in n.tags) {
        if (t == '档案标准' || categories.contains(t)) continue;
        tagCount[t] = (tagCount[t] ?? 0) + 1;
      }
    }
    for (final n in notes) {
      for (final t in n.tags) {
        if ((tagCount[t] ?? 0) < 2) continue;
        final tagIndex = addNode(
          GraphNode(id: 'tag:$t', label: t, type: GraphNodeType.tag),
        );
        addEdge(indexById[n.filePath]!, tagIndex, GraphEdgeType.tag);
      }
    }

    final searchIndex = [
      for (final node in nodes)
        if (node.note == null)
          node.label.toLowerCase()
        else
          '${node.note!.fullTitle} ${node.note!.standardNo} ${node.note!.tags.join(' ')} ${clip(node.note!.body, 12000)}'
              .toLowerCase(),
    ];

    final result = GraphData(
      nodes,
      edges,
      indexById,
      signature: signature,
      refDegreeByPath: refDegree,
      searchIndexByNode: searchIndex,
    );
    _cachedRefDegree = (signature: signature, refDegree: refDegree);
    return _cached = result;
  }

  static bool _mentionsPrepared(_PreparedNote from, _PreparedNote to) {
    if (from.note.filePath == to.note.filePath) return false;
    final no = to.baseNo;
    if (no != null && no.length >= 4 && from.body.contains(no)) return true;
    if (to.title.length >= 6 && from.body.contains(to.title)) return true;
    return false;
  }

}
