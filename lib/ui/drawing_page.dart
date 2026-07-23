import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/drawing_service.dart';
import 'responsive.dart';

const _accent = Color(0xFF2563EB);
const _sub = Color(0xFF6B6B70);
const _muted = Color(0xFF9B9B9F);

class DrawingPage extends StatefulWidget {
  const DrawingPage({super.key, required this.drawing});

  final DrawingService drawing;

  @override
  State<DrawingPage> createState() => _DrawingPageState();
}

class _DrawingPageState extends State<DrawingPage> {
  final _title = TextEditingController();
  final _prompt = TextEditingController();
  final _source = TextEditingController();

  String? _boundId;
  bool _editingSource = false;
  int _mobileTab = 0; // 0=配置，1=预览

  @override
  void dispose() {
    _title.dispose();
    _prompt.dispose();
    _source.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        width: 420,
      ),
    );
  }

  void _bind(DrawingDoc? doc) {
    if (doc == null || _boundId == doc.id) return;
    _boundId = doc.id;
    _title.text = doc.title;
    _prompt.text = doc.prompt;
    _source.text = doc.mermaid;
    _editingSource = false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.drawing,
      builder: (context, _) {
        final svc = widget.drawing;
        _bind(svc.current);
        // 生成/渲染完成后同步最新 Mermaid 到编辑框（非编辑态时）。
        if (svc.current != null && !_editingSource) {
          _source.text = svc.current!.mermaid;
        }
        return svc.current == null ? _buildShelf(svc) : _buildWorkspace(svc);
      },
    );
  }

  // ---------------------------------------------------------------- 货架

  Widget _buildShelf(DrawingService svc) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '画图',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => _newDrawing(svc),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1A1A1A),
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新建图'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '选择图种并（可选）关联一个或多个工程，第二大脑会读取真实代码结构，'
            '生成漂亮、完整的架构图（Mermaid，可编辑并渲染为高清图片）。',
            style: TextStyle(fontSize: 13, color: _sub),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: svc.docs.isEmpty
                ? const Center(
                    child: Text(
                      '还没有图，点击右上角「新建图」开始',
                      style: TextStyle(fontSize: 13, color: _muted),
                    ),
                  )
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 340,
                          mainAxisExtent: 168,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                    itemCount: svc.docs.length,
                    itemBuilder: (context, i) => _card(svc, svc.docs[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _card(DrawingService svc, DrawingDoc doc) {
    return Material(
      color: const Color(0xFFF7F7F8),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => svc.open(doc),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.account_tree_outlined,
                      size: 18, color: _accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      doc.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz, size: 18),
                    onSelected: (v) {
                      if (v == 'delete') _confirmDelete(svc, doc);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  doc.summary.isNotEmpty
                      ? doc.summary
                      : (doc.prompt.isEmpty ? '（暂无说明）' : doc.prompt),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.5, color: _sub),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _chip(doc.kind.label),
                  const SizedBox(width: 6),
                  if (doc.linkedProjects.isNotEmpty)
                    Flexible(
                      child: _chip('工程 ${doc.linkedProjects.length}',
                          soft: true),
                    ),
                  const Spacer(),
                  Icon(
                    doc.hasImage
                        ? Icons.image_outlined
                        : (doc.hasMermaid
                            ? Icons.code
                            : Icons.hourglass_empty),
                    size: 15,
                    color: _muted,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 工作区

  Widget _buildWorkspace(DrawingService svc) {
    final doc = svc.current!;
    if (context.isCompact) {
      return Column(
        children: [
          _topBar(svc, doc),
          _mobileTabBar(),
          Expanded(
            child: _mobileTab == 0
                ? _leftPanel(svc, doc)
                : _rightPanel(svc, doc),
          ),
        ],
      );
    }
    return Column(
      children: [
        _topBar(svc, doc),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 380, child: _leftPanel(svc, doc)),
              const VerticalDivider(width: 1),
              Expanded(child: _rightPanel(svc, doc)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _mobileTabBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFECECEE))),
      ),
      child: SegmentedButton<int>(
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: 0, label: Text('配置')),
          ButtonSegment(value: 1, label: Text('图')),
        ],
        selected: {_mobileTab},
        onSelectionChanged: (v) => setState(() => _mobileTab = v.first),
      ),
    );
  }

  Widget _topBar(DrawingService svc, DrawingDoc doc) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFECECEE))),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回图列表',
            onPressed: () {
              svc.close();
              _boundId = null;
            },
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              doc.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          if (svc.busy) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                svc.stage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: _sub),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => svc.cancel(),
              icon: const Icon(Icons.stop_circle_outlined, size: 16),
              label: const Text('停止'),
            ),
            const SizedBox(width: 8),
          ],
          FilledButton.icon(
            onPressed: svc.busy ? null : () => _generate(svc),
            style: FilledButton.styleFrom(backgroundColor: _accent),
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: Text(doc.hasMermaid ? '重新生成' : '生成图'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: (svc.busy || !doc.hasImage) ? null : () => _export(doc),
            icon: const Icon(Icons.ios_share, size: 16),
            label: const Text('导出图片'),
          ),
        ],
      ),
    );
  }

  Widget _leftPanel(DrawingService svc, DrawingDoc doc) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text('图信息', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        TextField(
          controller: _title,
          decoration: const InputDecoration(
            labelText: '标题',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) {
            doc.title = v;
            doc.updatedAt = DateTime.now();
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<DiagramKind>(
          initialValue: doc.kind,
          decoration: const InputDecoration(
            labelText: '图种',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final k in DiagramKind.values)
              DropdownMenuItem(value: k, child: Text(k.label)),
          ],
          onChanged: svc.busy
              ? null
              : (v) {
                  if (v != null) svc.setKind(v);
                },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _prompt,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: '需求 / 侧重点（可选）',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) {
            doc.prompt = v;
            doc.updatedAt = DateTime.now();
          },
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            const Text('关联工程', style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton.icon(
              onPressed: svc.busy ? null : () => _pickAndAdd(svc),
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('选择文件夹'),
            ),
          ],
        ),
        const Text(
          '可关联 1 个或多个工程组合；留空则按主题出通用图。',
          style: TextStyle(fontSize: 12, color: _muted),
        ),
        const SizedBox(height: 8),
        if (doc.linkedProjects.isEmpty)
          const Text('尚未关联工程',
              style: TextStyle(fontSize: 12.5, color: _muted))
        else
          for (final proj in doc.linkedProjects) _linkedRow(svc, proj),
        if (svc.recentProjects
            .where((p) => !doc.linkedProjects.any((e) => e.path == p))
            .isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('最近打开的工程',
              style: TextStyle(fontSize: 11.5, color: _muted)),
          const SizedBox(height: 4),
          for (final path in svc.recentProjects
              .where((p) => !doc.linkedProjects.any((e) => e.path == p)))
            _recentRow(svc, path),
        ],
      ],
    );
  }

  Widget _linkedRow(DrawingService svc, DrawingProjectRef proj) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 16, color: _accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(proj.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                Text(proj.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: _muted)),
              ],
            ),
          ),
          IconButton(
            tooltip: '移除',
            visualDensity: VisualDensity.compact,
            onPressed:
                svc.busy ? null : () => svc.removeLinkedProject(proj.path),
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _recentRow(DrawingService svc, String path) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 15, color: _muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: _sub)),
          ),
          TextButton(
            onPressed: svc.busy ? null : () => svc.addLinkedProject(path),
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  Widget _rightPanel(DrawingService svc, DrawingDoc doc) {
    return Container(
      color: const Color(0xFFFAFAFB),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 10, 12, 10),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xFFECECEE))),
            ),
            child: Row(
              children: [
                Text(
                  _editingSource ? 'Mermaid 源码' : '图预览',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (_editingSource)
                  OutlinedButton.icon(
                    onPressed: svc.busy ? null : () => _applySourceAndRender(svc),
                    icon: const Icon(Icons.refresh, size: 15),
                    label: const Text('渲染'),
                  ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () =>
                      setState(() => _editingSource = !_editingSource),
                  icon: Icon(_editingSource ? Icons.image_outlined : Icons.code,
                      size: 15),
                  label: Text(_editingSource ? '看图' : '编辑源码'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _editingSource
                ? _sourceEditor(doc)
                : _diagramView(svc, doc),
          ),
        ],
      ),
    );
  }

  Widget _diagramView(DrawingService svc, DrawingDoc doc) {
    if (doc.hasImage) {
      // 用内存图 + updatedAt 作 key，避免同名文件被图片缓存复用而不刷新。
      try {
        final bytes = File(doc.imagePath).readAsBytesSync();
        return InteractiveViewer(
          maxScale: 8,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Image.memory(
                bytes,
                key: ValueKey(
                    '${doc.id}-${doc.updatedAt.microsecondsSinceEpoch}'),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        );
      } catch (_) {}
    }
    if (doc.hasMermaid) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '未能渲染为图片（需本机安装 Edge/Chrome）。以下为图定义源码：',
              style: TextStyle(fontSize: 12, color: _muted),
            ),
            const SizedBox(height: 10),
            SelectableText(
              doc.mermaid,
              style: const TextStyle(fontSize: 12.5, fontFamily: 'Consolas'),
            ),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.account_tree_outlined, size: 40, color: _muted),
          const SizedBox(height: 12),
          Text(
            svc.busy ? svc.stage : '点击顶部「生成图」开始',
            style: const TextStyle(fontSize: 13, color: _muted),
          ),
        ],
      ),
    );
  }

  Widget _sourceEditor(DrawingDoc doc) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _source,
        expands: true,
        maxLines: null,
        minLines: null,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(fontSize: 13, height: 1.5, fontFamily: 'Consolas'),
        decoration: const InputDecoration(
          labelText: 'Mermaid 源码',
          alignLabelWithHint: true,
          border: OutlineInputBorder(),
        ),
        onChanged: (v) {
          doc.mermaid = v;
          doc.updatedAt = DateTime.now();
        },
      ),
    );
  }

  // -------------------------------------------------------------- 动作

  Future<void> _newDrawing(DrawingService svc) async {
    final title = TextEditingController();
    final prompt = TextEditingController();
    var kind = DiagramKind.system;
    final picked = <String>[];
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('新建图'),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: title,
                    decoration: const InputDecoration(labelText: '标题'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<DiagramKind>(
                    initialValue: kind,
                    decoration: const InputDecoration(labelText: '图种'),
                    items: [
                      for (final k in DiagramKind.values)
                        DropdownMenuItem(value: k, child: Text(k.label)),
                    ],
                    onChanged: (v) {
                      if (v != null) setLocal(() => kind = v);
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: prompt,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: '需求 / 侧重点（可选）',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Text('关联工程（可选，可多选）',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Text(
                        picked.isEmpty ? '未选择' : '已选 ${picked.length} 个',
                        style: const TextStyle(fontSize: 12, color: _sub),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Builder(builder: (_) {
                    final options = <String>{
                      ...svc.recentProjects,
                      ...picked,
                    }.toList();
                    if (options.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          '「项目」里暂无工程，可点下方按钮选择工程文件夹。',
                          style: TextStyle(fontSize: 12, color: _muted),
                        ),
                      );
                    }
                    return ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (final path in options)
                              CheckboxListTile(
                                value: picked.contains(path),
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(
                                  _baseName(path),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                                subtitle: Text(
                                  path,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 11, color: _muted),
                                ),
                                onChanged: (v) => setLocal(() {
                                  if (v == true) {
                                    if (!picked.contains(path)) {
                                      picked.add(path);
                                    }
                                  } else {
                                    picked.remove(path);
                                  }
                                }),
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final dir = await FilePicker.getDirectoryPath(
                          dialogTitle: '选择要关联的工程目录',
                        );
                        if (dir != null && !picked.contains(dir)) {
                          setLocal(() => picked.add(dir));
                        }
                      },
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: const Text('选择其他文件夹…'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (created == true && mounted) {
      final doc = svc.create(
        title: title.text,
        prompt: prompt.text,
        kind: kind,
        projectPaths: picked,
      );
      setState(() {
        _boundId = null;
        _bind(doc);
      });
    }
    title.dispose();
    prompt.dispose();
  }

  Future<void> _pickAndAdd(DrawingService svc) async {
    final dir =
        await FilePicker.getDirectoryPath(dialogTitle: '选择要关联的工程目录');
    if (dir != null) svc.addLinkedProject(dir);
  }

  Future<void> _generate(DrawingService svc) async {
    final doc = svc.current;
    if (doc == null) return;
    doc.title = _title.text.trim().isEmpty ? '未命名图' : _title.text.trim();
    doc.prompt = _prompt.text.trim();
    await svc.save();
    await svc.generate();
    if (svc.stage.startsWith('生成失败')) _toast(svc.stage);
  }

  Future<void> _applySourceAndRender(DrawingService svc) async {
    final doc = svc.current;
    if (doc == null) return;
    doc.mermaid = _source.text;
    await svc.rerender();
    if (!mounted) return;
    if (svc.stage.startsWith('渲染失败')) _toast(svc.stage);
    setState(() => _editingSource = false);
  }

  Future<void> _export(DrawingDoc doc) async {
    if (!doc.hasImage) return;
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择导出文件夹');
    if (dir == null) return;
    try {
      final safe = doc.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
      final name = '${safe.isEmpty ? '图' : safe}-${doc.kind.label}.png';
      final out = File('$dir${Platform.pathSeparator}$name');
      await File(doc.imagePath).copy(out.path);
      _toast('已导出：$name');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  Future<void> _confirmDelete(DrawingService svc, DrawingDoc doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除图'),
        content: Text('确定删除《${doc.title}》吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await svc.delete(doc);
  }

  static String _baseName(String path) {
    final parts =
        path.split(RegExp(r'[\\/]')).where((e) => e.trim().isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  Widget _chip(String text, {bool soft = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: soft ? const Color(0xFFEFF1F5) : const Color(0xFFE7EEFE),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: soft ? _sub : _accent,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
}
