import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models.dart';
import '../services/ai_client.dart';
import '../services/graph_service.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/topic_service.dart';
import 'library_page.dart' show statusColor;

class GraphPage extends StatefulWidget {
  const GraphPage({
    super.key,
    required this.library,
    required this.settings,
    required this.topicService,
    required this.onOpenNote,
    required this.onOpenTopic,
  });

  final LibraryService library;
  final SettingsService settings;
  final TopicFetchService topicService;
  final void Function(StandardNote) onOpenNote;
  final VoidCallback onOpenTopic;

  @override
  State<GraphPage> createState() => _GraphPageState();
}

class _GraphPageState extends State<GraphPage>
    with SingleTickerProviderStateMixin {
  GraphData? _graph;
  List<Offset> _pos = [];
  List<Offset> _vel = [];
  late final Ticker _ticker;
  double _alpha = 1;
  int _paintVersion = 0;

  double _scale = 1;
  Offset _camera = Offset.zero;
  Size _canvasSize = Size.zero;

  int? _hover;
  int? _selected;
  int? _dragIndex;
  bool _didPan = false;
  int? _popup;
  Offset _doubleTapPos = Offset.zero;

  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  String _query = '';

  late final AiClient _ai = AiClient(widget.settings);
  bool _aiLoading = false;
  String? _aiText;
  List<TopicDoc> _missing = [];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    widget.library.addListener(_onLibraryChanged);
    _buildGraph();
  }

  @override
  void dispose() {
    widget.library.removeListener(_onLibraryChanged);
    _ticker.dispose();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onLibraryChanged() {
    if (!mounted) return;
    _buildGraph(preserve: true);
  }

  void _buildGraph({bool preserve = false}) {
    final signature = GraphBuilder.signatureOf(widget.library.notes);
    if (preserve && _graph?.signature == signature) {
      return;
    }
    final oldGraph = _graph;
    final oldPos = <String, Offset>{};
    if (preserve && oldGraph != null) {
      for (var i = 0; i < oldGraph.nodes.length; i++) {
        oldPos[oldGraph.nodes[i].id] = _pos[i];
      }
    }
    final selectedId = _selected != null && oldGraph != null
        ? oldGraph.nodes[_selected!].id
        : null;

    final graph = GraphBuilder.buildResult(widget.library.notes);
    final rnd = math.Random(7);
    final pos = <Offset>[];
    final vel = <Offset>[];
    for (final n in graph.nodes) {
      pos.add(
        oldPos[n.id] ??
            Offset(
              (rnd.nextDouble() - 0.5) * 700,
              (rnd.nextDouble() - 0.5) * 700,
            ),
      );
      vel.add(Offset.zero);
    }
    setState(() {
      _graph = graph;
      _pos = pos;
      _vel = vel;
      _hover = null;
      _dragIndex = null;
      _popup = null;
      _selected = selectedId == null ? null : graph.indexOf(selectedId);
      _alpha = graph.nodes.length > 180 ? 0.55 : 1;
      _paintVersion++;
    });
    _wake();
  }

  void _wake([double alpha = 1]) {
    _alpha = math.max(_alpha, alpha);
    if (!_ticker.isActive) _ticker.start();
  }

  void _tick(Duration _) {
    final graph = _graph;
    if (graph == null || graph.nodes.isEmpty) {
      _ticker.stop();
      return;
    }
    _simulate(graph);
    if (_alpha < 0.02 && _dragIndex == null) _ticker.stop();
    setState(() => _paintVersion++);
  }

  void _simulate(GraphData graph) {
    final n = graph.nodes.length;
    const repulsion = 26000.0;
    const damping = 0.82;
    const gravity = 0.012;
    final pairStep = n > 260 ? 3 : (n > 160 ? 2 : 1);

    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j += pairStep) {
        var delta = _pos[j] - _pos[i];
        var d = delta.distance;
        if (d < 1) {
          delta = Offset(math.Random(i * 31 + j).nextDouble() - .5, .5);
          d = 1;
        }
        final f = math.min(repulsion / (d * d), 18.0) * _alpha;
        final dir = delta / d;
        _vel[i] -= dir * f;
        _vel[j] += dir * f;
      }
    }
    for (final e in graph.edges) {
      final rest = switch (e.type) {
        GraphEdgeType.reference => 140.0,
        GraphEdgeType.category => 190.0,
        GraphEdgeType.tag => 160.0,
      };
      var delta = _pos[e.b] - _pos[e.a];
      final d = math.max(delta.distance, 1.0);
      final f = (d - rest) * 0.025 * _alpha;
      final dir = delta / d;
      _vel[e.a] += dir * f;
      _vel[e.b] -= dir * f;
    }
    for (var i = 0; i < n; i++) {
      if (i == _dragIndex) {
        _vel[i] = Offset.zero;
        continue;
      }
      _vel[i] -= _pos[i] * gravity * _alpha;
      _vel[i] *= damping;
      _pos[i] += _vel[i];
    }
    _alpha *= n > 160 ? 0.965 : 0.99;
  }

  // ---------- 坐标变换与命中 ----------

  Offset get _center => Offset(_canvasSize.width / 2, _canvasSize.height / 2);

  Offset _toScreen(Offset world) => world * _scale + _camera + _center;

  Offset _toWorld(Offset screen) => (screen - _center - _camera) / _scale;

  double _drawRadius(GraphNode node) {
    final base = switch (node.type) {
      GraphNodeType.category => 16.0,
      GraphNodeType.tag => 7.0,
      GraphNodeType.note => (6.0 + node.degree * 1.1).clamp(6.0, 15.0),
    };
    return (base * _scale).clamp(3.0, 42.0);
  }

  int? _hitTest(Offset screenPos) {
    final graph = _graph;
    if (graph == null) return null;
    for (var i = graph.nodes.length - 1; i >= 0; i--) {
      final p = _toScreen(_pos[i]);
      if ((p - screenPos).distance <= _drawRadius(graph.nodes[i]) + 5) {
        return i;
      }
    }
    return null;
  }

  void _centerOn(int index) {
    _camera = -_pos[index] * _scale;
  }

  void _selectNode(int? index, {bool center = false}) {
    setState(() {
      if (_selected != index) {
        _aiText = null;
        _aiLoading = false;
        _missing = [];
      }
      _selected = index;
      if (index != null && center) _centerOn(index);
    });
  }

  /// 双击节点：放大进入该节点的关联层，并弹出简介悬浮窗。
  void _enterNode(int index) {
    setState(() {
      if (_selected != index) {
        _aiText = null;
        _aiLoading = false;
        _missing = [];
      }
      _selected = index;
      _popup = index;
      if (_scale < 1.6) _scale = 1.6;
      _centerOn(index);
    });
    _wake(0.2);
  }

  // ---------- 手势 ----------

  void _onScroll(PointerScrollEvent event) {
    final worldBefore = _toWorld(event.localPosition);
    final factor = math.exp(-event.scrollDelta.dy * 0.0012);
    setState(() {
      _scale = (_scale * factor).clamp(0.25, 4.0);
      _camera = event.localPosition - _center - worldBefore * _scale;
      _paintVersion++;
    });
  }

  void _onPanStart(DragStartDetails d) {
    _didPan = false;
    _dragIndex = _hitTest(d.localPosition);
    if (_dragIndex != null) _wake(0.35);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    _didPan = true;
    setState(() {
      if (_dragIndex != null) {
        _pos[_dragIndex!] = _toWorld(d.localPosition);
        _paintVersion++;
        _wake(0.3);
      } else {
        _camera += d.delta;
        _paintVersion++;
      }
    });
  }

  void _onPanEnd(DragEndDetails d) {
    if (_dragIndex != null && !_didPan) _selectNode(_dragIndex);
    _dragIndex = null;
    _wake(0.25);
  }

  void _onTapUp(TapUpDetails d) {
    _selectNode(_hitTest(d.localPosition));
  }

  void _onHover(PointerHoverEvent e) {
    final hit = _hitTest(e.localPosition);
    if (hit != _hover) setState(() => _hover = hit);
  }

  // ---------- 搜索 ----------

  Set<int> _matchedIndices() {
    final graph = _graph;
    final q = _query.trim().toLowerCase();
    if (graph == null || q.isEmpty) return {};
    final result = <int>{};
    for (var i = 0; i < graph.nodes.length; i++) {
      if (graph.searchIndexByNode[i].contains(q)) result.add(i);
    }
    return result;
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _query = value);
    });
  }

  // ---------- AI 推理 ----------

  Future<void> _runAi() async {
    final graph = _graph;
    final index = _selected;
    if (graph == null || index == null || _aiLoading) return;
    final node = graph.nodes[index];
    setState(() {
      _aiLoading = true;
      _aiText = null;
      _missing = [];
    });
    try {
      final neighbors = graph.neighborDetail(index);
      final rel = StringBuffer();
      for (final (n, type) in neighbors) {
        final t = switch (type) {
          GraphEdgeType.reference => '内容关联',
          GraphEdgeType.category => '所属类别',
          GraphEdgeType.tag => '共同主题',
        };
        final no = n.note?.standardNo ?? '';
        rel.writeln('- [$t] ${no.isEmpty ? '' : '$no '}${n.label}');
      }
      final note = node.note;
      final subject = note == null
          ? '「${node.label}」（${node.type == GraphNodeType.category ? '类别' : '主题标签'}节点）'
          : '${note.standardNo}《${note.fullTitle}》';
      final snippet = note == null
          ? ''
          : '\n该笔记内容节选：\n${note.body.length > 2500 ? note.body.substring(0, 2500) : note.body}\n';
      final catalog = widget.library.notes
          .map(
            (n) =>
                '- ${n.standardNo.isEmpty ? '' : '${n.standardNo} '}${n.fullTitle}',
          )
          .join('\n');
      final prompt =
          '''
我的档案标准知识图谱中，当前选中节点为：$subject
$snippet
它在图谱中的直接关联如下：
$rel
知识库现有全部文件目录：
$catalog

请基于以上信息进行推理分析，输出 Markdown（不超过 500 字）：

## 关系解读
（说明这些关联为什么存在、各自扮演什么角色）

## 推理与发现
（挖掘潜在的深层关联、标准间的分工/演进/互补关系，可指出图谱上没有但逻辑上应有的联系）

## 延伸学习
（给出 2-4 条延伸方向：值得继续补充的文件或值得深入的问题）

最后，对比知识库目录，找出与当前节点密切相关、但知识库尚未收录的 0-4 份真实存在的标准/规范文件，在回答末尾追加一个代码块（没有则输出空数组）：
```missing
[{"标准号":"DA/T 1—2000","题名":"档案工作基本术语","类别":"档案行业标准","年份":"2000"}]
```
''';
      var text = await _ai.complete(
        system: '你是中国档案管理领域的标准研究专家，擅长梳理标准体系之间的关系。回答精炼、有洞察，用中文。',
        user: prompt,
      );
      final missing = _parseMissing(text);
      text = text.replaceAll(RegExp(r'```missing[\s\S]*?```'), '').trim();
      if (mounted && _selected == index) {
        setState(() {
          _aiText = text;
          _missing = missing;
        });
      }
    } catch (e) {
      if (mounted && _selected == index) setState(() => _aiText = '推理失败：$e');
    } finally {
      if (mounted) setState(() => _aiLoading = false);
    }
  }

  List<TopicDoc> _parseMissing(String text) {
    final m = RegExp(r'```missing\s*([\s\S]*?)```').firstMatch(text);
    if (m == null) return [];
    try {
      final raw = m.group(1)!.trim();
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return [
        for (final item in list)
          if (item is Map && (item['题名'] as String?)?.isNotEmpty == true)
            TopicDoc(
              standardNo: (item['标准号'] as String? ?? '').trim(),
              title: (item['题名'] as String).trim(),
              category: (item['类别'] as String? ?? '其他').trim(),
              year: (item['年份'] as String? ?? '').trim(),
            ),
      ];
    } catch (_) {
      return [];
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final graph = _graph;
    if (widget.library.loading || graph == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (graph.nodes.isEmpty) {
      return const Center(
        child: Text(
          '知识库为空，先去「知识库」扫描或「主题获取」添加文件',
          style: TextStyle(color: Color(0xFF9B9B9F)),
        ),
      );
    }
    final matched = _matchedIndices();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildCanvas(graph, matched)),
        if (_selected != null) ...[
          VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
          SizedBox(width: 360, child: _buildPanel(graph, _selected!)),
        ],
      ],
    );
  }

  Widget _buildCanvas(GraphData graph, Set<int> matched) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          children: [
            Positioned.fill(
              child: Listener(
                onPointerSignal: (e) {
                  if (e is PointerScrollEvent) _onScroll(e);
                },
                child: MouseRegion(
                  onHover: _onHover,
                  cursor: _hover != null
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: _onPanStart,
                    onPanUpdate: _onPanUpdate,
                    onPanEnd: _onPanEnd,
                    onTapUp: _onTapUp,
                    onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
                    onDoubleTap: () {
                      final hit = _hitTest(_doubleTapPos);
                      if (hit != null) _enterNode(hit);
                    },
                    child: CustomPaint(
                      painter: _GraphPainter(
                        graph: graph,
                        positions: _pos,
                        toScreen: _toScreen,
                        radiusOf: _drawRadius,
                        hover: _hover,
                        selected: _selected,
                        matched: matched,
                        searching: _query.trim().isNotEmpty,
                        scale: _scale,
                        version: _paintVersion,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              top: 14,
              child: _buildSearchBox(graph, matched),
            ),
            if (_popup != null && _popup! < graph.nodes.length)
              Positioned(
                left: 16,
                bottom: 40,
                child: _buildPopup(graph, _popup!),
              ),
            Positioned(
              right: 16,
              bottom: 12,
              child: Text(
                '${graph.nodes.length} 节点 · ${graph.edges.length} 连接    滚轮缩放 · 拖拽平移/移动节点 · 点击查看',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Color(0xFFB9B9BD),
                ),
              ),
            ),
            Positioned(left: 16, bottom: 12, child: _buildLegend()),
          ],
        );
      },
    );
  }

  Widget _buildSearchBox(GraphData graph, Set<int> matched) {
    final q = _query.trim();
    final results = q.isEmpty
        ? const <int>[]
        : (matched.toList()
                ..sort((a, b) => graph.nodes[b].degree - graph.nodes[a].degree))
              .take(8)
              .toList();
    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE3E3E6)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _searchController,
            style: const TextStyle(fontSize: 13.5),
            decoration: const InputDecoration(
              hintText: '搜索图谱：标准号、题名、内容…',
              prefixIcon: Icon(Icons.search, size: 18),
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
            onChanged: _onSearchChanged,
          ),
          if (q.isNotEmpty) ...[
            const Divider(height: 1, color: Color(0xFFECECEE)),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text(
                '${matched.length} 个匹配节点',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Color(0xFF9B9B9F),
                ),
              ),
            ),
            for (final i in results)
              InkWell(
                onTap: () {
                  _selectNode(i, center: true);
                  // 关闭搜索结果列表，避免遮挡图谱
                  _searchController.clear();
                  setState(() => _query = '');
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _GraphPainter.nodeColor(graph.nodes[i]),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          graph.nodes[i].note?.standardNo.isNotEmpty == true
                              ? '${graph.nodes[i].note!.standardNo}  ${graph.nodes[i].label}'
                              : graph.nodes[i].label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  String _sectionSnippet(StandardNote note, String heading, {int max = 150}) {
    final m = RegExp(
      '^## $heading\\s*\\n([\\s\\S]*?)(?=^## |\\Z)',
      multiLine: true,
    ).firstMatch(note.body);
    var text = (m?.group(1) ?? '')
        .replaceAll(RegExp(r'\[\[[^\]]*\]\]'), '')
        .replaceAll(RegExp(r'[#>*`]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.length > max) text = '${text.substring(0, max)}…';
    return text;
  }

  /// 双击节点弹出的简介悬浮窗。
  Widget _buildPopup(GraphData graph, int index) {
    final node = graph.nodes[index];
    final note = node.note;
    final neighbors = graph.neighborsOf(index);
    final snippet = note == null
        ? '包含 ${neighbors.length} 个相关节点'
        : _sectionSnippet(note, '适用范围');
    return Container(
      width: 330,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE3E3E6)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: _GraphPainter.nodeColor(node),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _popup = null),
              ),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(
              [
                if (note.standardNo.isNotEmpty) note.standardNo,
                note.category,
                if (note.year.isNotEmpty) '${note.year} 年',
                note.status,
              ].join(' · '),
              style: const TextStyle(fontSize: 12, color: Color(0xFF9B9B9F)),
            ),
          ],
          if (snippet.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              snippet,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: Color(0xFF49494D),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '${neighbors.length} 个关联',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9B9B9F)),
              ),
              const Spacer(),
              if (note != null)
                FilledButton.tonal(
                  onPressed: () => widget.onOpenNote(note),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('打开笔记', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegend() {
    Widget item(Color color, String label) => Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF9B9B9F)),
          ),
        ],
      ),
    );
    return Row(
      children: [
        item(const Color(0xFF14B8A6), '国家标准'),
        item(const Color(0xFFF59E0B), '行业标准'),
        item(const Color(0xFF8B5CF6), '地方标准'),
        item(const Color(0xFF1A1A1A), '类别'),
        item(const Color(0xFF9B9B9F), '主题'),
      ],
    );
  }

  Widget _buildPanel(GraphData graph, int index) {
    final node = graph.nodes[index];
    final note = node.note;
    final neighbors = graph.neighborDetail(index)
      ..sort((a, b) => a.$2.index - b.$2.index);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  node.label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => _selectNode(null),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            children: [
              if (note != null) ...[
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (note.standardNo.isNotEmpty)
                      Text(
                        note.standardNo,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF6B6B70),
                        ),
                      ),
                    Text(
                      note.category,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Color(0xFF6B6B70),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: statusColor(note.status),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          note.status,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF9B9B9F),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => widget.onOpenNote(note),
                      icon: const Icon(Icons.menu_book_outlined, size: 15),
                      label: const Text(
                        '打开笔记',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _aiLoading ? null : _runAi,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1A1A1A),
                      ),
                      icon: _aiLoading
                          ? const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.auto_awesome, size: 15),
                      label: Text(
                        _aiLoading ? '推理中…' : 'AI 推理与延伸',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Text(
                        node.type == GraphNodeType.category ? '类别节点' : '主题节点',
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF6B6B70),
                        ),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _aiLoading ? null : _runAi,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1A1A1A),
                        ),
                        icon: _aiLoading
                            ? const SizedBox(
                                width: 13,
                                height: 13,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.auto_awesome, size: 15),
                        label: Text(
                          _aiLoading ? '推理中…' : 'AI 推理与延伸',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              Text(
                '关联（${neighbors.length}）',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              for (final (n, type) in neighbors)
                InkWell(
                  onTap: () {
                    final i = graph.indexOf(n.id);
                    if (i != null) _selectNode(i, center: true);
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _GraphPainter.nodeColor(n),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            n.note?.standardNo.isNotEmpty == true
                                ? '${n.note!.standardNo}  ${n.label}'
                                : n.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                        Text(
                          switch (type) {
                            GraphEdgeType.reference => '关联',
                            GraphEdgeType.category => '类别',
                            GraphEdgeType.tag => '主题',
                          },
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFFB9B9BD),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_aiLoading || _aiText != null) ...[
                const SizedBox(height: 18),
                const Divider(height: 1, color: Color(0xFFECECEE)),
                const SizedBox(height: 14),
                if (_aiLoading)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        '正在基于图谱推理…',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF9B9B9F),
                        ),
                      ),
                    ),
                  )
                else
                  MarkdownBody(
                    data: _aiText!,
                    styleSheet: MarkdownStyleSheet(
                      p: const TextStyle(fontSize: 13, height: 1.65),
                      h2: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      listBullet: const TextStyle(fontSize: 13, height: 1.65),
                    ),
                  ),
                if (_missing.isNotEmpty) _buildMissingCard(),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// AI 检测到知识库缺失内容时的补全提示卡片。
  Widget _buildMissingCard() {
    final running = widget.topicService.running;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FBF9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFB9E8E0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.lightbulb_outline, size: 16, color: Color(0xFF0D9488)),
              SizedBox(width: 6),
              Text(
                '发现知识库缺失内容',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0F766E),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final d in _missing)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '· ${d.standardNo.isEmpty ? '' : '${d.standardNo} '}${d.title}',
                style: const TextStyle(fontSize: 12.5, height: 1.5),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              FilledButton.icon(
                onPressed: running
                    ? null
                    : () {
                        final graph = _graph;
                        final label = _selected != null && graph != null
                            ? graph.nodes[_selected!].label
                            : '图谱推理';
                        widget.topicService.fetchDocs(label, _missing);
                        widget.onOpenTopic();
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0D9488),
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.download_outlined, size: 14),
                label: Text(
                  running ? '补全中…' : '自动补全到知识库',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _missing = []),
                child: const Text('忽略', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.graph,
    required this.positions,
    required this.toScreen,
    required this.radiusOf,
    required this.hover,
    required this.selected,
    required this.matched,
    required this.searching,
    required this.scale,
    required this.version,
  });

  final GraphData graph;
  final List<Offset> positions;
  final Offset Function(Offset) toScreen;
  final double Function(GraphNode) radiusOf;
  final int? hover;
  final int? selected;
  final Set<int> matched;
  final bool searching;
  final double scale;
  final int version;

  static Color nodeColor(GraphNode n) {
    switch (n.type) {
      case GraphNodeType.category:
        return const Color(0xFF1A1A1A);
      case GraphNodeType.tag:
        return const Color(0xFF9B9B9F);
      case GraphNodeType.note:
        final c = n.note!.category;
        if (c.contains('国家')) return const Color(0xFF14B8A6);
        if (c.contains('行业')) return const Color(0xFFF59E0B);
        if (c.contains('地方')) return const Color(0xFF8B5CF6);
        return const Color(0xFF64748B);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final viewport = Offset.zero & size;
    final paddedViewport = viewport.inflate(100);

    final focusIndex = hover ?? selected;
    Set<int>? focusSet;
    if (focusIndex != null) {
      focusSet = graph.neighborsOf(focusIndex)..add(focusIndex);
    }

    double nodeOpacity(int i) {
      if (searching) {
        if (matched.contains(i)) return 1;
        return focusSet != null && focusSet.contains(i) ? 0.6 : 0.12;
      }
      if (focusSet != null) return focusSet.contains(i) ? 1 : 0.18;
      return 1;
    }

    // 边
    for (final e in graph.edges) {
      final p1 = toScreen(positions[e.a]);
      final p2 = toScreen(positions[e.b]);
      if (!paddedViewport.contains(p1) && !paddedViewport.contains(p2)) {
        continue;
      }
      final isFocusEdge =
          focusIndex != null && (e.a == focusIndex || e.b == focusIndex);
      var opacity = 0.45;
      if (searching) {
        opacity = matched.contains(e.a) && matched.contains(e.b) ? 0.5 : 0.06;
      }
      if (focusSet != null) opacity = isFocusEdge ? 0.85 : 0.06;
      final color = switch (e.type) {
        GraphEdgeType.reference => const Color(0xFF14B8A6),
        GraphEdgeType.category => const Color(0xFFD2D2D6),
        GraphEdgeType.tag => const Color(0xFFD9CFEA),
      };
      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = color.withValues(alpha: opacity)
          ..strokeWidth = e.type == GraphEdgeType.reference
              ? (isFocusEdge ? 2.2 : 1.4)
              : (isFocusEdge ? 1.6 : 1.0),
      );
    }

    // 节点
    for (var i = 0; i < graph.nodes.length; i++) {
      final node = graph.nodes[i];
      final p = toScreen(positions[i]);
      final r = radiusOf(node);
      if (!paddedViewport.contains(p)) continue;
      final opacity = nodeOpacity(i);
      final color = nodeColor(node);

      if (i == selected || i == hover) {
        canvas.drawCircle(
          p,
          r + 6,
          Paint()..color = color.withValues(alpha: 0.18),
        );
      }
      if (searching && matched.contains(i)) {
        canvas.drawCircle(
          p,
          r + 4,
          Paint()..color = color.withValues(alpha: 0.25),
        );
      }
      canvas.drawCircle(
        p,
        r,
        Paint()..color = color.withValues(alpha: opacity),
      );
      if (node.type == GraphNodeType.note) {
        canvas.drawCircle(
          p,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = Colors.white.withValues(alpha: opacity * 0.9),
        );
      }
    }

    // 标签文字
    for (var i = 0; i < graph.nodes.length; i++) {
      final node = graph.nodes[i];
      final r = radiusOf(node);
      final emphasized =
          i == hover ||
          i == selected ||
          (searching && matched.contains(i)) ||
          node.type == GraphNodeType.category;
      if (!emphasized && scale < 0.75) continue;
      if (!emphasized && r < 6) continue;
      final opacity = nodeOpacity(i);
      if (opacity < 0.3 && !emphasized) continue;
      final p = toScreen(positions[i]);
      if (!paddedViewport.contains(p)) continue;

      var label = node.label;
      if (label.length > 14 && !emphasized) {
        label = '${label.substring(0, 13)}…';
      }
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontSize: emphasized ? 12 : 10.5,
            fontWeight: node.type == GraphNodeType.category || i == selected
                ? FontWeight.w600
                : FontWeight.w400,
            color: const Color(
              0xFF49494D,
            ).withValues(alpha: opacity.clamp(0.35, 1.0)),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 180);
      // 文字描白边提升可读性
      final bg = Paint()..color = Colors.white.withValues(alpha: 0.72);
      final rect = Rect.fromLTWH(
        p.dx - tp.width / 2 - 2,
        p.dy + r + 2,
        tp.width + 4,
        tp.height + 2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        bg,
      );
      tp.paint(canvas, Offset(p.dx - tp.width / 2, p.dy + r + 3));
    }
  }

  @override
  bool shouldRepaint(covariant _GraphPainter oldDelegate) =>
      oldDelegate.graph != graph ||
      oldDelegate.version != version ||
      oldDelegate.hover != hover ||
      oldDelegate.selected != selected ||
      oldDelegate.searching != searching ||
      oldDelegate.scale != scale ||
      oldDelegate.matched != matched;
}
