import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../services/project_doc_service.dart';
import '../services/project_doc_store.dart';
import 'enter_to_send.dart';
import 'widgets/ref_markdown.dart';

/// 「项目概览」工作台：在主工作区内铺开（保留 App 一级导航），
/// 子级左导航切换五个区块：概览 / 架构图 / 功能树 / 文档库 / 对话。
class ProjectOverviewWorkspace extends StatefulWidget {
  const ProjectOverviewWorkspace({
    super.key,
    required this.service,
    required this.projectPath,
    required this.onBack,
  });

  final ProjectDocService service;
  final String projectPath;

  /// 返回项目列表 / 控制台。
  final VoidCallback onBack;

  @override
  State<ProjectOverviewWorkspace> createState() =>
      _ProjectOverviewWorkspaceState();
}

class _ProjectOverviewWorkspaceState extends State<ProjectOverviewWorkspace> {
  ProjectDocRecord? _rec;
  bool _loading = true;

  /// 0=概览 1=架构图 2=功能树 3=文档库 4=对话。
  int _tab = 0;
  final Set<String> _expanded = {};
  String _depth = 'standard';
  String _archKind = 'system';

  /// 架构图下钻栈：空 = 根层（整个工程）；点节点入栈、面包屑出栈。
  final List<ArchNode> _archStack = [];

  /// 功能树右侧 Wiki 页当前选中的节点 id。
  String? _selectedNodeId;

  final _qaInput = TextEditingController();
  final _qaScroll = ScrollController();

  /// 当前选中的对话会话 id；null = 新对话（尚未产生第一条问答）。
  String? _qaSessionId;

  ProjectDocService get svc => widget.service;
  String get path => widget.projectPath;

  static const _tabs = [
    (Icons.summarize_outlined, '概览'),
    (Icons.schema_outlined, '架构图'),
    (Icons.account_tree_outlined, '功能树'),
    (Icons.description_outlined, '文档库'),
    (Icons.forum_outlined, '对话'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _qaInput.dispose();
    _qaScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final rec = await svc.loadRecord(path);
    if (!mounted) return;
    setState(() {
      _rec = rec;
      _loading = false;
      _depth = rec.depth;
      for (final n in rec.functionTree) {
        _expanded.add(n.id);
      }
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      width: 460,
    ));
  }

  Future<void> _run(Future<ProjectDocRecord> Function() action) async {
    try {
      final rec = await action();
      if (!mounted) return;
      setState(() => _rec = rec);
    } catch (e) {
      _toast('$e');
    }
  }

  // --------------------------- 操作 ---------------------------

  Future<void> _buildOverview() =>
      _run(() => svc.buildOverview(projectPath: path, depth: _depth));

  /// 当前下钻作用域（栈顶）；null = 根层。
  ArchNode? get _archScope => _archStack.isEmpty ? null : _archStack.last;

  String get _archScopeKey {
    final s = _archScope;
    if (s == null) return '';
    return s.path.isNotEmpty ? s.path : s.label;
  }

  Future<void> _buildArch() => _run(() => svc.buildArchitecture(
        projectPath: path,
        kind: _archKind,
        scopeLabel: _archScope?.label ?? '',
        scopePath: _archScope?.path ?? '',
      ));

  /// 点击节点下钻一层：入栈并（若还没有该层的图）自动生成。
  Future<void> _drillInto(ArchNode n) async {
    if (svc.detailBusy || svc.generating) return;
    setState(() => _archStack.add(n));
    final has = _rec?.diagramFor(_archKind, scopeKey: _archScopeKey) != null;
    if (!has) await _buildArch();
  }

  Future<void> _genNode(FuncNode node, {bool rewrite = false}) async {
    var instruction = '';
    if (rewrite) {
      final r = await _promptInstruction(
          '重写《${node.title}》详细设计', '可填写额外要求（留空则按默认重新生成）：');
      if (r == null) return;
      instruction = r;
    }
    await _run(() => svc.generateNodeDoc(
        projectPath: path, nodeId: node.id, instruction: instruction));
  }

  Future<void> _writeCategory(ProjectDocCategory cat,
      {required bool revise}) async {
    var instruction = '';
    if (revise) {
      final r = await _promptInstruction('修订《${cat.name}》', '请填写修订要求：');
      if (r == null || r.trim().isEmpty) return;
      instruction = r;
    }
    await _run(() => svc.writeCategoryDoc(
        projectPath: path, categoryId: cat.id, instruction: instruction));
  }

  Future<void> _ask() async {
    final q = _qaInput.text.trim();
    if (q.isEmpty || svc.qaBusy) return;
    _qaInput.clear();
    setState(() {}); // 立即刷新输入框
    await _run(() =>
        svc.askProject(projectPath: path, question: q, sessionId: _qaSessionId));
    if (svc.lastQaSessionId != null) _qaSessionId = svc.lastQaSessionId;
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_qaScroll.hasClients) {
        _qaScroll.jumpTo(_qaScroll.position.maxScrollExtent);
      }
    });
  }

  void _newSession() {
    setState(() {
      _qaSessionId = null;
      _qaInput.clear();
    });
  }

  Future<void> _deleteSession(QaSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除对话', style: TextStyle(fontSize: 15)),
        content: Text('确定删除「${s.title}」这段对话？该操作不可撤销。',
            style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD64545)),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (_qaSessionId == s.id) _qaSessionId = null;
    await _run(() => svc.deleteQaSession(projectPath: path, sessionId: s.id));
  }

  Future<void> _exportSession(QaSession s) async {
    final rec = _rec;
    final title =
        (rec?.projectName.isNotEmpty ?? false) ? rec!.projectName : p.basename(path);
    final buf = StringBuffer()
      ..writeln('# 与项目对话 · $title')
      ..writeln()
      ..writeln('> 会话：${s.title}')
      ..writeln();
    for (final qa in s.items) {
      buf
        ..writeln('## 问：${qa.question}')
        ..writeln()
        ..writeln(qa.answer)
        ..writeln()
        ..writeln('---')
        ..writeln();
    }
    final safe = s.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    try {
      final out = await FilePicker.saveFile(
        dialogTitle: '导出对话为 Markdown',
        fileName: '对话_$safe.md',
        type: FileType.custom,
        allowedExtensions: const ['md'],
      );
      if (out == null) return;
      final path0 = out.toLowerCase().endsWith('.md') ? out : '$out.md';
      await File(path0).writeAsString(buf.toString());
      _toast('已导出：$path0');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  Future<String?> _promptInstruction(String title, String hint) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: c,
            autofocus: true,
            minLines: 2,
            maxLines: 6,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: hint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('确定')),
        ],
      ),
    );
  }

  Future<void> _downloadWord(String srcPath, String suggestName) async {
    final src = File(srcPath);
    if (srcPath.isEmpty || !await src.exists()) {
      _toast('Word 文件不存在，请重新生成');
      return;
    }
    final dest = await FilePicker.saveFile(
      dialogTitle: '保存 Word 文档',
      fileName:
          suggestName.endsWith('.docx') ? suggestName : '$suggestName.docx',
      type: FileType.custom,
      allowedExtensions: ['docx'],
    );
    if (dest == null) return;
    final finalPath =
        dest.toLowerCase().endsWith('.docx') ? dest : '$dest.docx';
    try {
      await src.copy(finalPath);
      _toast('已保存：$finalPath');
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  // --------------------------- 布局 ---------------------------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const SizedBox(height: 10),
            if (svc.detailBusy || svc.qaBusy) ...[
              _busyBar(),
              const SizedBox(height: 8),
            ],
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 168, child: _subNav()),
                  const SizedBox(width: 12),
                  Expanded(child: _content()),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _header() {
    final name = p.basename(path);
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: widget.onBack,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: const Color(0xFF6B6B70),
            ),
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('返回项目', style: TextStyle(fontSize: 12.5)),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.account_tree_outlined,
              size: 16, color: Color(0xFF7C3AED)),
          const SizedBox(width: 7),
          Expanded(
            child: Text('项目概览 · $name',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
          // 深度分级选择器。
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _depth,
              isDense: true,
              style: const TextStyle(fontSize: 12, color: Color(0xFF2B2B2E)),
              items: [
                for (final e in ProjectDocService.depthLabels.entries)
                  DropdownMenuItem(
                      value: e.key, child: Text('深度：${e.value}')),
              ],
              onChanged: (v) => setState(() => _depth = v ?? 'standard'),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: '在资源管理器中打开',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.open_in_new, size: 16),
            color: const Color(0xFF6B6B70),
            onPressed: () => launchUrl(Uri.file(path)),
          ),
        ],
      ),
    );
  }

  Widget _busyBar() {
    final label = svc.qaBusy
        ? '正在检索工程代码回答问题…'
        : (svc.detailPhase.isEmpty ? '处理中…' : svc.detailPhase);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF6F4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Color(0xFF0D9488)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12.5, color: Color(0xFF0D6C64))),
          ),
          if (svc.detailChars > 0)
            Text('${svc.detailChars} 字',
                style:
                    const TextStyle(fontSize: 11.5, color: Color(0xFF0D6C64))),
        ],
      ),
    );
  }

  Widget _subNav() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          for (var i = 0; i < _tabs.length; i++) _navItem(i),
          const Spacer(),
          if (_rec?.generatedAt != null)
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                '生成 ${_fmtDate(_rec!.generatedAt!)}',
                style:
                    const TextStyle(fontSize: 10.5, color: Color(0xFFA0A0A5)),
              ),
            ),
        ],
      ),
    );
  }

  static String _fmtDate(DateTime t) =>
      '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _navItem(int i) {
    final selected = _tab == i;
    final (icon, label) = _tabs[i];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: Material(
        color: selected ? const Color(0xFFEAF6F4) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _tab = i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(icon,
                    size: 15,
                    color: selected
                        ? const Color(0xFF0D9488)
                        : const Color(0xFF8A8A92)),
                const SizedBox(width: 8),
                Text(label,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected
                            ? const Color(0xFF0D9488)
                            : const Color(0xFF4B4B50))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel({required Widget child}) {
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: child,
    );
  }

  Widget _content() {
    if (_loading) {
      return _panel(
        child: const Center(
            child: CircularProgressIndicator(color: Color(0xFF0D9488))),
      );
    }
    final rec = _rec!;
    if (rec.isEmpty) {
      return _panel(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.description_outlined,
                  size: 40, color: Color(0xFFC4C4CC)),
              SizedBox(height: 12),
              Text(
                '该项目还没有文档撰写记录。\n请先在项目列表点击「根据工程生成项目文档」完整生成一次，\n之后即可在此查看概览、架构图、功能树，并继续新写、修订与对话。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13, color: Color(0xFF8B8B93), height: 1.7),
              ),
            ],
          ),
        ),
      );
    }
    return switch (_tab) {
      0 => _overviewTab(rec),
      1 => _archTab(rec),
      2 => _treeTab(rec),
      3 => _docsTab(rec),
      _ => _qaTab(rec),
    };
  }

  // --------------------------- ① 概览 ---------------------------

  Widget _overviewTab(ProjectDocRecord rec) {
    final busy = svc.detailBusy || svc.generating;
    if (rec.overviewMarkdown.trim().isEmpty) {
      return _panel(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.summarize_outlined,
                  size: 40, color: Color(0xFFC4C4CC)),
              const SizedBox(height: 12),
              const Text(
                '还没有结构化概览。\n将基于已有《工程分析》生成 13 节概览：架构、主流程、核心模块、\n风险（含 Observed / Inferred / Open 证据标注）等，文件引用可点击查看。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5, color: Color(0xFF8B8B93), height: 1.7),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: busy ? null : _buildOverview,
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0D9488)),
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: Text('生成概览（${ProjectDocService.depthLabels[_depth]}）'),
              ),
            ],
          ),
        ),
      );
    }
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 6),
            child: Row(
              children: [
                Text(
                  '结构化概览 · 深度：${ProjectDocService.depthLabels[rec.depth] ?? rec.depth}',
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF6B6B70)),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: busy ? null : _buildOverview,
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  icon: const Icon(Icons.refresh, size: 14),
                  label: Text(
                      '重新生成（${ProjectDocService.depthLabels[_depth]}）',
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFECECEE)),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: RefMarkdown(
                  data: rec.overviewMarkdown, projectPath: path),
            ),
          ),
        ],
      ),
    );
  }

  // --------------------------- ② 架构图 ---------------------------

  Widget _archTab(ProjectDocRecord rec) {
    final busy = svc.detailBusy || svc.generating;
    final diagram = rec.diagramFor(_archKind, scopeKey: _archScopeKey);
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
            child: Row(
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'system', label: Text('系统架构')),
                    ButtonSegment(value: 'directory', label: Text('目录结构')),
                    ButtonSegment(value: 'flow', label: Text('主流程')),
                  ],
                  selected: {_archKind},
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    textStyle: WidgetStateProperty.all(
                        const TextStyle(fontSize: 12)),
                  ),
                  onSelectionChanged: (s) =>
                      setState(() => _archKind = s.first),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: busy ? null : _buildArch,
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  icon: Icon(diagram == null ? Icons.auto_awesome : Icons.refresh,
                      size: 14),
                  label: Text(diagram == null ? '生成图' : '重新生成',
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          _archBreadcrumbs(),
          const Divider(height: 1, color: Color(0xFFECECEE)),
          Expanded(
            child: diagram == null
                ? Center(
                    child: Text(
                      busy ? '生成中…' : '还没有生成该图，点右上角「生成图」',
                      style: const TextStyle(
                          fontSize: 12.5, color: Color(0xFF9B9B9F)),
                    ),
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _diagramView(diagram)),
                      const VerticalDivider(
                          width: 1, color: Color(0xFFECECEE)),
                      SizedBox(width: 280, child: _nodeList(diagram)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 下钻层级面包屑：根 › 节点A › 节点B，点击任意一级回到该层。
  Widget _archBreadcrumbs() {
    final crumbs = <Widget>[
      _crumb(p.basename(path), _archStack.isEmpty,
          () => setState(_archStack.clear)),
    ];
    for (var i = 0; i < _archStack.length; i++) {
      final isLast = i == _archStack.length - 1;
      final upTo = i + 1;
      crumbs.add(const Padding(
        padding: EdgeInsets.symmetric(horizontal: 2),
        child: Icon(Icons.chevron_right, size: 14, color: Color(0xFFB0B0B6)),
      ));
      crumbs.add(_crumb(_archStack[i].label, isLast, () {
        setState(() => _archStack.removeRange(upTo, _archStack.length));
      }));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: crumbs),
      ),
    );
  }

  Widget _crumb(String label, bool current, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: current ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: current ? const Color(0xFFEAF6F4) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                color: current
                    ? const Color(0xFF0D9488)
                    : const Color(0xFF6B6B70))),
      ),
    );
  }

  Widget _diagramView(ArchDiagram d) {
    if (d.imagePath.isNotEmpty && File(d.imagePath).existsSync()) {
      return Container(
        color: Colors.white,
        padding: const EdgeInsets.all(16),
        child: InteractiveViewer(
          maxScale: 6,
          child: Center(
            child: Image.file(File(d.imagePath),
                fit: BoxFit.contain, filterQuality: FilterQuality.high),
          ),
        ),
      );
    }
    // 渲染失败时退化为 Mermaid 源码展示。
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        d.mermaid,
        style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
      ),
    );
  }

  Widget _nodeList(ArchDiagram d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Text('节点清单 · 点击下钻一层，点 ⟨⟩ 打开代码',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6B6B70))),
        ),
        Expanded(
          child: d.nodes.isEmpty
              ? const Center(
                  child: Text('（无节点映射）',
                      style:
                          TextStyle(fontSize: 12, color: Color(0xFFB0B0B6))))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  itemCount: d.nodes.length,
                  itemBuilder: (context, i) => _nodeTile(d.nodes[i]),
                ),
        ),
      ],
    );
  }

  Widget _nodeTile(ArchNode n) {
    final hasPath = n.path.isNotEmpty;
    final busy = svc.detailBusy || svc.generating;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: const Color(0xFFFAFAFB),
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          // 点击节点本体：下钻一层，继续查看该节点内部的架构/结构/流程。
          onTap: busy ? null : () => _drillInto(n),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(9, 4, 2, 4),
            child: Row(
              children: [
                const Icon(Icons.zoom_in,
                    size: 13, color: Color(0xFF7C3AED)),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(n.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11.8, fontWeight: FontWeight.w600)),
                      Text(hasPath ? n.path : '（推断，未定位到代码）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10.5,
                              color: hasPath
                                  ? const Color(0xFF0D9488)
                                  : const Color(0xFFA0A0A5))),
                    ],
                  ),
                ),
                // 打开代码位置：独立的图标按钮，不与下钻混用。
                IconButton(
                  tooltip: hasPath ? '打开代码位置：${n.path}' : '未定位到代码',
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.code,
                      size: 15,
                      color: hasPath
                          ? const Color(0xFF0D9488)
                          : const Color(0xFFD0D0D5)),
                  onPressed: hasPath ? () => _openNodePath(n.path) : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 打开架构图节点对应的路径：文件用查看器，目录用资源管理器。
  void _openNodePath(String rel) {
    final abs =
        p.normalize(p.join(path, rel.replaceAll('/', p.separator)));
    if (File(abs).existsSync()) {
      RefMarkdown.openFile(context, abs);
    } else if (Directory(abs).existsSync()) {
      launchUrl(Uri.file(abs));
    } else {
      _toast('未找到：$rel');
    }
  }

  // --------------------------- ③ 功能树 ---------------------------

  Widget _treeTab(ProjectDocRecord rec) {
    if (rec.functionTree.isEmpty) {
      return _panel(
        child: const Center(
          child: Text('（未提炼到功能树，可重新生成文档以生成）',
              style: TextStyle(fontSize: 12.5, color: Color(0xFF9B9B9F))),
        ),
      );
    }
    final selected =
        _selectedNodeId == null ? null : rec.findNode(_selectedNodeId!);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 280,
          child: _panel(
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                for (final n in rec.functionTree) ..._treeRows(n, 0),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _panel(
            child: selected == null
                ? const Center(
                    child: Text('点击左侧节点查看 / 编写该功能的详细设计',
                        style: TextStyle(
                            fontSize: 12.5, color: Color(0xFF9B9B9F))))
                : _nodeWiki(selected),
          ),
        ),
      ],
    );
  }

  List<Widget> _treeRows(FuncNode node, int depth) {
    final rows = <Widget>[];
    final hasChildren = node.children.isNotEmpty;
    final open = _expanded.contains(node.id);
    final selected = _selectedNodeId == node.id;
    rows.add(
      Padding(
        padding: EdgeInsets.only(left: depth * 14.0, bottom: 2),
        child: Material(
          color: selected ? const Color(0xFFEAF6F4) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: () => setState(() => _selectedNodeId = node.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              child: Row(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: hasChildren
                        ? () => setState(() {
                              if (open) {
                                _expanded.remove(node.id);
                              } else {
                                _expanded.add(node.id);
                              }
                            })
                        : null,
                    child: Icon(
                      hasChildren
                          ? (open
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_right)
                          : Icons.fiber_manual_record,
                      size: hasChildren ? 16 : 7,
                      color: const Color(0xFF8A8A92),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(node.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.3,
                            fontWeight: depth == 0
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: selected
                                ? const Color(0xFF0D9488)
                                : const Color(0xFF2B2B2E))),
                  ),
                  if (node.hasDetail)
                    const Icon(Icons.check_circle,
                        size: 11, color: Color(0xFF0D9488)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (hasChildren && open) {
      for (final c in node.children) {
        rows.addAll(_treeRows(c, depth + 1));
      }
    }
    return rows;
  }

  /// 右侧节点 Wiki 页：标题 + 操作 + 详细设计正文（或空态）。
  Widget _nodeWiki(FuncNode node) {
    final busy = svc.detailBusy || svc.generating;
    final busyThis = svc.detailBusy && svc.detailTargetId == node.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(node.title,
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w700)),
                    if (node.desc.trim().isNotEmpty)
                      Text(node.desc,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11.5, color: Color(0xFF9B9B9F))),
                  ],
                ),
              ),
              if (busyThis)
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFF0D9488)),
                )
              else if (node.hasDetail) ...[
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => _downloadWord(
                          node.detailDocxPath, '${node.title} 详细设计'),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  icon: const Icon(Icons.download_outlined, size: 14),
                  label:
                      const Text('Word', style: TextStyle(fontSize: 12)),
                ),
                TextButton.icon(
                  onPressed:
                      busy ? null : () => _genNode(node, rewrite: true),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('重写', style: TextStyle(fontSize: 12)),
                ),
              ] else
                FilledButton.icon(
                  onPressed: busy ? null : () => _genNode(node),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0D9488),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.edit_note, size: 15),
                  label: const Text('编写详细设计',
                      style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFECECEE)),
        Expanded(
          child: node.hasDetail
              ? SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                  child: RefMarkdown(
                      data: node.detailMarkdown, projectPath: path),
                )
              : Center(
                  child: Text(
                    busyThis ? '正在编写…' : '该节点还没有详细设计文档，点右上角「编写详细设计」',
                    style: const TextStyle(
                        fontSize: 12.5, color: Color(0xFF9B9B9F)),
                  ),
                ),
        ),
      ],
    );
  }

  // --------------------------- ④ 文档库 ---------------------------

  Widget _docsTab(ProjectDocRecord rec) {
    return _panel(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text('已生成的可在线阅读 / 下载 / 修订；未生成的可继续新写',
                style: TextStyle(fontSize: 11.5, color: Color(0xFFA0A0A5))),
          ),
          for (final cat in ProjectDocService.categories) _docRow(rec, cat),
        ],
      ),
    );
  }

  Widget _docRow(ProjectDocRecord rec, ProjectDocCategory cat) {
    final doc = rec.docFor(cat.id);
    final has = doc != null && doc.markdown.trim().isNotEmpty;
    final busy = svc.detailBusy || svc.generating;
    final busyThis = svc.detailBusy && svc.detailTargetId == cat.id;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Row(
        children: [
          Icon(
            has ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 14,
            color: has ? const Color(0xFF0D9488) : const Color(0xFFC4C4CC),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(cat.name,
                    style: const TextStyle(
                        fontSize: 12.8, fontWeight: FontWeight.w600)),
                Text(has ? '已生成' : cat.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        color: has
                            ? const Color(0xFF0D9488)
                            : const Color(0xFF9B9B9F))),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (busyThis)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFF0D9488)),
            )
          else if (has) ...[
            _miniBtn('阅读', Icons.menu_book_outlined, busy,
                () => _readDoc(cat.name, doc.markdown)),
            _miniBtn('Word', Icons.download_outlined, busy,
                () => _downloadWord(doc.docxPath, cat.fileBase)),
            _miniBtn('修订', Icons.edit_outlined, busy,
                () => _writeCategory(cat, revise: true)),
          ] else
            _miniBtn('继续新写', Icons.edit_note, busy,
                () => _writeCategory(cat, revise: false),
                primary: true),
        ],
      ),
    );
  }

  void _readDoc(String title, String markdown) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780, maxHeight: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
                child: Row(
                  children: [
                    const Icon(Icons.menu_book_outlined,
                        size: 18, color: Color(0xFF0D9488)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFFECECEE)),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                  child: RefMarkdown(data: markdown, projectPath: path),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniBtn(
      String label, IconData icon, bool disabled, VoidCallback onTap,
      {bool primary = false}) {
    final color = primary ? const Color(0xFF0D9488) : const Color(0xFF6B6B70);
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: TextButton.icon(
        onPressed: disabled ? null : onTap,
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          foregroundColor: color,
          minimumSize: const Size(0, 30),
        ),
        icon: Icon(icon, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 11.5)),
      ),
    );
  }

  // --------------------------- ⑤ 对话 ---------------------------

  Widget _qaTab(ProjectDocRecord rec) {
    final active = _qaSessionId == null ? null : rec.sessionFor(_qaSessionId!);
    return _panel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 200, child: _qaSessionList(rec, active)),
          const VerticalDivider(width: 1, color: Color(0xFFECECEE)),
          Expanded(child: _qaConversation(active)),
        ],
      ),
    );
  }

  Widget _qaSessionList(ProjectDocRecord rec, QaSession? active) {
    final sessions = [...rec.qaSessions]
      ..sort((a, b) => (b.updatedAt ?? b.createdAt ?? DateTime(0))
          .compareTo(a.updatedAt ?? a.createdAt ?? DateTime(0)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child: OutlinedButton.icon(
            onPressed: svc.qaBusy ? null : _newSession,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('新对话', style: TextStyle(fontSize: 12.5)),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF1A1A1A),
              side: const BorderSide(color: Color(0xFFD9D9DE)),
              padding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFFECECEE)),
        Expanded(
          child: sessions.isEmpty
              ? const Center(
                  child: Text('暂无对话',
                      style:
                          TextStyle(fontSize: 12, color: Color(0xFFA8A8AC))),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: sessions.length,
                  itemBuilder: (context, i) =>
                      _sessionTile(sessions[i], sessions[i].id == active?.id),
                ),
        ),
      ],
    );
  }

  Widget _sessionTile(QaSession s, bool selected) {
    return InkWell(
      onTap: () => setState(() => _qaSessionId = s.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        color: selected ? const Color(0xFFEFF4F3) : null,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.3,
                      color: const Color(0xFF2A2A2E),
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${s.items.length} 轮 · ${_fmtTime(s.updatedAt ?? s.createdAt)}',
                    style: const TextStyle(
                        fontSize: 10.5, color: Color(0xFFA0A0A6)),
                  ),
                ],
              ),
            ),
            InkWell(
              onTap: () => _deleteSession(s),
              borderRadius: BorderRadius.circular(4),
              child: const Padding(
                padding: EdgeInsets.all(3),
                child: Icon(Icons.delete_outline,
                    size: 15, color: Color(0xFFB0B0B6)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtTime(DateTime? t) {
    if (t == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  Widget _qaConversation(QaSession? active) {
    final items = active?.items ?? const <QaItem>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  active?.title ?? '新对话',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF2A2A2E)),
                ),
              ),
              TextButton.icon(
                onPressed: (active != null && items.isNotEmpty)
                    ? () => _exportSession(active)
                    : null,
                icon: const Icon(Icons.ios_share, size: 15),
                label: const Text('导出', style: TextStyle(fontSize: 12.5)),
                style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF1A1A1A)),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFECECEE)),
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      '就这个工程提问（如「登录鉴权是怎么实现的？」「数据存在哪些表里？」），\nAI 会检索真实代码后回答，答案中的文件引用可点击查看源码。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF8B8B93),
                          height: 1.7),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _qaScroll,
                  padding: const EdgeInsets.all(16),
                  itemCount: items.length,
                  itemBuilder: (context, i) => _qaBubble(items[i]),
                ),
        ),
        const Divider(height: 1, color: Color(0xFFECECEE)),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: EnterToSend(
                    enabled: !svc.qaBusy,
                    onSubmit: _ask,
                    child: TextField(
                      controller: _qaInput,
                      enabled: !svc.qaBusy,
                      minLines: 1,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      style: const TextStyle(fontSize: 13.5),
                      decoration: InputDecoration(
                        hintText: svc.qaBusy
                            ? '回答中…'
                            : '就这个工程提问；回车发送，Ctrl/Shift+回车换行',
                        hintStyle: const TextStyle(
                            color: Color(0xFFA8A8AC), fontSize: 12.5),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              const BorderSide(color: Color(0xFFD9D9DE)),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: svc.qaBusy ? null : _ask,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1A1A1A),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                  ),
                  child: svc.qaBusy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.arrow_upward, size: 18),
                ),
              ],
            ),
          ),
        ],
    );
  }

  Widget _qaBubble(QaItem qa) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFEAF6F4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(qa.question,
                  style: const TextStyle(fontSize: 13, height: 1.5)),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFAFAFB),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFECECEE)),
            ),
            child: RefMarkdown(data: qa.answer, projectPath: path),
          ),
        ],
      ),
    );
  }
}
