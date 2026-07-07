import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:path/path.dart' as p;

import '../services/project_doc_service.dart';
import '../services/project_doc_store.dart';

/// 「项目概览」弹窗：
/// - 展示由文档撰写过程提炼的「系统功能分类 → 子分类」树，每个节点可编写/重写
///   详细设计文档，并在线阅读或下载 Word；
/// - 展示批量生成的标准文档清单，支持在线阅读、下载 Word、修订、以及继续新写未生成项。
class ProjectOverviewDialog extends StatefulWidget {
  const ProjectOverviewDialog({
    super.key,
    required this.service,
    required this.projectPath,
  });

  final ProjectDocService service;
  final String projectPath;

  @override
  State<ProjectOverviewDialog> createState() => _ProjectOverviewDialogState();
}

class _ProjectOverviewDialogState extends State<ProjectOverviewDialog> {
  ProjectDocRecord? _rec;
  bool _loading = true;
  final Set<String> _expanded = {};

  ProjectDocService get svc => widget.service;
  String get path => widget.projectPath;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rec = await svc.loadRecord(path);
    if (!mounted) return;
    setState(() {
      _rec = rec;
      _loading = false;
      // 默认展开所有一级节点。
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

  Future<void> _genNode(FuncNode node, {bool rewrite = false}) async {
    var instruction = '';
    if (rewrite) {
      final r = await _promptInstruction('重写《${node.title}》详细设计',
          '可填写额外要求（留空则按默认重新生成）：');
      if (r == null) return;
      instruction = r;
    }
    await _run(() => svc.generateNodeDoc(
          projectPath: path,
          nodeId: node.id,
          instruction: instruction,
        ));
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
          projectPath: path,
          categoryId: cat.id,
          instruction: instruction,
        ));
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

  void _readOnline(String title, String markdown) {
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
                  child: MarkdownBody(data: markdown, selectable: true),
                ),
              ),
            ],
          ),
        ),
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
      fileName: suggestName.endsWith('.docx') ? suggestName : '$suggestName.docx',
      type: FileType.custom,
      allowedExtensions: ['docx'],
    );
    if (dest == null) return;
    final finalPath = dest.toLowerCase().endsWith('.docx') ? dest : '$dest.docx';
    try {
      await src.copy(finalPath);
      _toast('已保存：$finalPath');
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 720),
        child: ListenableBuilder(
          listenable: svc,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                const Divider(height: 1, color: Color(0xFFECECEE)),
                if (svc.detailBusy) _busyBar(),
                Flexible(child: _body()),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header() {
    final name = p.basename(path);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 10, 12),
      child: Row(
        children: [
          const Icon(Icons.account_tree_outlined,
              size: 18, color: Color(0xFF0D9488)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('项目概览 · $name',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF9B9B9F))),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _busyBar() {
    return Container(
      color: const Color(0xFFEAF6F4),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
            child: Text(
              svc.detailPhase.isEmpty ? '处理中…' : svc.detailPhase,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12.5, color: Color(0xFF0D6C64)),
            ),
          ),
          if (svc.detailChars > 0)
            Text('${svc.detailChars} 字',
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF0D6C64))),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: CircularProgressIndicator(color: Color(0xFF0D9488)),
        ),
      );
    }
    final rec = _rec!;
    if (rec.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Text(
            '该项目还没有文档撰写记录。\n请先在项目列表点击「根据工程生成项目文档」完整生成一次，\n之后即可在此查看功能树与文档、继续新写与修订。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Color(0xFF8B8B93), height: 1.6),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      children: [
        _sectionTitle('系统功能', Icons.account_tree_outlined,
            '点击节点可编写更详细的设计文档，并在线阅读或下载 Word'),
        const SizedBox(height: 6),
        if (rec.functionTree.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('（未提炼到功能树，可重新生成文档以生成）',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF9B9B9F))),
          )
        else
          for (final n in rec.functionTree) ..._treeRows(n, 0),
        const SizedBox(height: 18),
        _sectionTitle('项目文档', Icons.description_outlined,
            '已生成的可在线阅读/下载/修订；未生成的可继续新写'),
        const SizedBox(height: 6),
        for (final cat in ProjectDocService.categories) _docRow(rec, cat),
      ],
    );
  }

  Widget _sectionTitle(String title, IconData icon, String hint) {
    return Row(
      children: [
        Icon(icon, size: 16, color: const Color(0xFF0D9488)),
        const SizedBox(width: 6),
        Text(title,
            style: const TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w700)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFFA0A0A5))),
        ),
      ],
    );
  }

  List<Widget> _treeRows(FuncNode node, int depth) {
    final rows = <Widget>[];
    final hasChildren = node.children.isNotEmpty;
    final open = _expanded.contains(node.id);
    final busyThis = svc.detailBusy && svc.detailTargetId == node.id;
    rows.add(
      Padding(
        padding: EdgeInsets.only(left: depth * 18.0, top: 3, bottom: 3),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
          decoration: BoxDecoration(
            color: depth == 0 ? const Color(0xFFF7F7F8) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFECECEE)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
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
                  size: hasChildren ? 18 : 8,
                  color: const Color(0xFF8A8A92),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(node.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12.8,
                                  fontWeight: depth == 0
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  color: const Color(0xFF2B2B2E))),
                        ),
                        if (node.hasDetail) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.check_circle,
                              size: 12, color: Color(0xFF0D9488)),
                        ],
                      ],
                    ),
                    if (node.desc.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(node.desc,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF9B9B9F))),
                      ),
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
              else if (node.hasDetail) ...[
                _miniBtn('阅读', Icons.menu_book_outlined,
                    () => _readOnline('${node.title} · 详细设计', node.detailMarkdown)),
                _miniBtn('Word', Icons.download_outlined,
                    () => _downloadWord(node.detailDocxPath, '${node.title} 详细设计')),
                _miniBtn('重写', Icons.refresh,
                    () => _genNode(node, rewrite: true)),
              ] else
                _miniBtn('编写详细设计', Icons.edit_note, () => _genNode(node),
                    primary: true),
            ],
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

  Widget _docRow(ProjectDocRecord rec, ProjectDocCategory cat) {
    final doc = rec.docFor(cat.id);
    final has = doc != null && doc.markdown.trim().isNotEmpty;
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
            _miniBtn('阅读', Icons.menu_book_outlined,
                () => _readOnline(cat.name, doc.markdown)),
            _miniBtn('Word', Icons.download_outlined,
                () => _downloadWord(doc.docxPath, cat.fileBase)),
            _miniBtn('修订', Icons.edit_outlined,
                () => _writeCategory(cat, revise: true)),
          ] else
            _miniBtn('继续新写', Icons.edit_note,
                () => _writeCategory(cat, revise: false),
                primary: true),
        ],
      ),
    );
  }

  Widget _miniBtn(String label, IconData icon, VoidCallback onTap,
      {bool primary = false}) {
    final disabled = svc.detailBusy || svc.generating;
    final color =
        primary ? const Color(0xFF0D9488) : const Color(0xFF6B6B70);
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
}
