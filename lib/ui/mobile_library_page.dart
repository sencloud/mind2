import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../services/file_library_service.dart';
import '../services/library_service.dart';

class MobileLibraryPage extends StatefulWidget {
  const MobileLibraryPage({
    super.key,
    required this.library,
    required this.fileLibrary,
    this.initialNote,
    this.onContinueResearch,
  });

  final LibraryService library;
  final FileLibraryService fileLibrary;
  final StandardNote? initialNote;
  final void Function(String topic, String clarification)? onContinueResearch;

  @override
  State<MobileLibraryPage> createState() => _MobileLibraryPageState();
}

class _MobileLibraryPageState extends State<MobileLibraryPage> {
  StandardNote? _selected;
  bool _byResearch = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialNote;
  }

  @override
  void didUpdateWidget(covariant MobileLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialNote != null &&
        widget.initialNote != oldWidget.initialNote) {
      _selected = widget.initialNote;
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _importFiles() async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;
    final paths = result.files.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) return;
    _toast('正在导入 ${paths.length} 个文件…');
    final ok = await widget.fileLibrary.importFiles(paths);
    await widget.library.reload();
    _toast('已导入 $ok 个文件');
  }

  Future<void> _openAttachment(StandardNote note) async {
    final path = widget.library.resolveAttachment(note);
    if (path == null) {
      _toast('这篇笔记没有关联原文附件');
      return;
    }
    final ok = await launchUrl(Uri.file(path));
    if (!ok) _toast('无法打开：$path');
  }

  Future<void> _generatePpt(StandardNote note) async {
    try {
      _toast('正在生成 PPT…');
      final html = await widget.library.generateResearchPpt(note);
      final relPath = await widget.fileLibrary.saveDownloaded(
        '${_fileSafe(note.fullTitle)}-PPT.html',
        Uint8List.fromList(utf8.encode(html)),
      );
      await widget.library.saveBody(
        note,
        _upsertExportLink(note.body, 'PPT', relPath),
      );
      final path = p.joinAll([
        widget.library.settings.vaultPath,
        ...relPath.split(RegExp(r'[\\/]')),
      ]);
      await launchUrl(Uri.file(path));
      _toast('已生成 PPT');
    } catch (e) {
      _toast('生成 PPT 失败：$e');
    }
  }

  Future<void> _exportResearchPdf(StandardNote note) async {
    try {
      _toast('正在由 HTML 导出 PDF…');
      final relPath = await widget.library.exportResearchPdf(note);
      await widget.library.saveBody(
        note,
        _upsertExportLink(note.body, 'PDF', relPath),
      );
      final path = p.joinAll([
        widget.library.settings.vaultPath,
        ...relPath.split(RegExp(r'[\\/]')),
      ]);
      await launchUrl(Uri.file(path));
      _toast('已导出 PDF');
    } catch (e) {
      _toast('导出 PDF 失败：$e');
    }
  }

  void _continueResearch(StandardNote note) {
    final topic = note.research.isNotEmpty ? note.research : note.fullTitle;
    final clarification =
        '''
用户正在 Android 端基于已有主题研究报告继续追问。请把当前报告作为背景材料继续挖掘、发散和总结新的思路。
当前报告：${note.fullTitle}
研究主题：${note.research}

当前报告正文摘要：
${_clip(note.body, 10000)}
''';
    widget.onContinueResearch?.call(topic, clarification);
  }

  Future<void> _handleLink(String? href) async {
    if (href == null || href.isEmpty) return;
    if (!href.startsWith('wiki:')) {
      final ok = await launchUrl(Uri.parse(href));
      if (!ok) _toast('无法打开：$href');
      return;
    }
    final target = Uri.decodeComponent(href.substring(5));
    final lower = target.toLowerCase();
    if (RegExp(r'\.(pdf|docx?|xlsx?|html?)$').hasMatch(lower)) {
      final path = p.joinAll([
        widget.library.settings.vaultPath,
        ...target.split(RegExp(r'[\\/]')),
      ]);
      final ok = await launchUrl(Uri.file(path));
      if (!ok) _toast('无法打开：$path');
      return;
    }
    final name = target.split('/').last;
    final matches = widget.library.notes.where((n) => n.fileName == name);
    if (matches.isNotEmpty) setState(() => _selected = matches.first);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.library, widget.fileLibrary]),
      builder: (context, _) {
        final lib = widget.library;
        if (lib.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (lib.notInitialized) return _buildInit();
        if (lib.error != null) return Center(child: Text(lib.error!));
        final selected = _selected;
        if (selected != null && lib.notes.contains(selected)) {
          return _buildDetail(selected);
        }
        return _buildList();
      },
    );
  }

  Widget _buildInit() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.menu_book_outlined,
              size: 44,
              color: Color(0xFF0D9488),
            ),
            const SizedBox(height: 12),
            const Text(
              '初始化本地知识库',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              widget.library.settings.vaultPath,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B6B70)),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: widget.library.initialize,
              child: const Text('创建知识库目录'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    final groups = _byResearch ? _researchGroups() : _categoryGroups();
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                const Text(
                  '知识库',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '导入文件',
                  onPressed: widget.fileLibrary.working ? null : _importFiles,
                  icon: const Icon(Icons.upload_file_outlined),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('分类')),
                ButtonSegment(value: true, label: Text('研究')),
              ],
              selected: {_byResearch},
              onSelectionChanged: (v) => setState(() => _byResearch = v.first),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: groups.isEmpty
                ? const Center(child: Text('暂无笔记'))
                : ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    children: [
                      for (final entry in groups.entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
                          child: Text(
                            '${entry.key} · ${entry.value.length}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF6B6B70),
                            ),
                          ),
                        ),
                        for (final note in _sortNotes(entry.value))
                          ListTile(
                            leading: Icon(
                              note.isResearchReport
                                  ? Icons.travel_explore_outlined
                                  : Icons.description_outlined,
                              color: note.isResearchReport
                                  ? const Color(0xFF0D9488)
                                  : null,
                            ),
                            title: Text(note.fullTitle, maxLines: 1),
                            subtitle: Text(
                              note.research.isNotEmpty
                                  ? note.research
                                  : note.category,
                              maxLines: 1,
                            ),
                            onTap: () => setState(() => _selected = note),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetail(StandardNote note) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => setState(() => _selected = null),
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: Text(
                    note.fullTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text(note.category)),
                if (note.research.isNotEmpty)
                  Chip(label: Text('研究：${note.research}')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (note.attachmentRelPath != null)
                  OutlinedButton.icon(
                    onPressed: () => _openAttachment(note),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('打开原文'),
                  ),
                if (note.isResearchReport) ...[
                  FilledButton.tonalIcon(
                    onPressed: () => _continueResearch(note),
                    icon: const Icon(Icons.travel_explore, size: 16),
                    label: const Text('继续研究'),
                  ),
                  PopupMenuButton<String>(
                    enabled: !widget.library.isGeneratingPpt(note),
                    tooltip: '导出研究结果',
                    onSelected: (value) {
                      if (value == 'ppt') {
                        _generatePpt(note);
                      } else if (value == 'pdf') {
                        _exportResearchPdf(note);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'ppt',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.slideshow_outlined),
                          title: Text('导出 PPT'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'pdf',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.picture_as_pdf_outlined),
                          title: Text('导出 PDF'),
                        ),
                      ),
                    ],
                    child: IgnorePointer(
                      child: FilledButton.tonalIcon(
                        onPressed: widget.library.isGeneratingPpt(note)
                            ? null
                            : () {},
                        icon: widget.library.isGeneratingPpt(note)
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.ios_share, size: 16),
                        label: Text(
                          widget.library.isGeneratingPpt(note) ? '导出中…' : '导出',
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 16),
          Expanded(
            child: Markdown(
              data: _markdownData(note),
              selectable: true,
              onTapLink: (text, href, title) => _handleLink(href),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            ),
          ),
        ],
      ),
    );
  }

  Map<String, List<StandardNote>> _categoryGroups() {
    final out = <String, List<StandardNote>>{};
    for (final n in widget.library.notes) {
      (out[n.category] ??= []).add(n);
    }
    return Map.fromEntries(
      out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  Map<String, List<StandardNote>> _researchGroups() {
    final out = <String, List<StandardNote>>{};
    for (final n in widget.library.notes) {
      if (n.research.trim().isEmpty) continue;
      (out[n.research] ??= []).add(n);
    }
    return Map.fromEntries(
      out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  List<StandardNote> _sortNotes(List<StandardNote> notes) {
    return [...notes]..sort((a, b) {
      if (a.isResearchReport != b.isResearchReport) {
        return a.isResearchReport ? -1 : 1;
      }
      return a.fullTitle.compareTo(b.fullTitle);
    });
  }

  String _markdownData(StandardNote note) => note.body
      .replaceAllMapped(
        RegExp(r'\[\[([^\]\|]+)\|([^\]]+)\]\]'),
        (m) => '[${m.group(2)}](wiki:${Uri.encodeComponent(m.group(1)!)})',
      )
      .replaceAllMapped(
        RegExp(r'\[\[([^\]]+)\]\]'),
        (m) => '[${m.group(1)}](wiki:${Uri.encodeComponent(m.group(1)!)})',
      );

  static String _upsertExportLink(String body, String label, String relPath) {
    final normalized = relPath.replaceAll('\\', '/');
    final line = '- [[$normalized|打开 $label]]';
    final sectionRe = RegExp(
      r'^## 导出\s*\n([\s\S]*?)(?=\n## |\z)',
      dotAll: true,
      multiLine: true,
    );
    final match = sectionRe.firstMatch(body);
    if (match == null) return '${body.trimRight()}\n\n## 导出\n\n$line\n';
    final old = match.group(1) ?? '';
    final linkRe = RegExp(
      r'^- \[\[[^\]]+\|打开 ' + RegExp.escape(label) + r'\]\]\s*$',
      multiLine: true,
    );
    final updated = linkRe.hasMatch(old)
        ? old.replaceFirst(linkRe, line)
        : '${old.trimRight()}\n$line\n';
    return body.replaceRange(match.start, match.end, '## 导出\n$updated');
  }

  static String _fileSafe(String s) {
    var out = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    if (out.length > 60) out = out.substring(0, 60).trim();
    return out.isEmpty ? '未命名' : out;
  }

  static String _clip(String s, int maxLen) {
    final clean = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= maxLen) return clean;
    return '${clean.substring(0, maxLen)}…';
  }
}
