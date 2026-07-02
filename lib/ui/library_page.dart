import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../services/agent/agent_event.dart';
import '../services/experiment_service.dart';
import '../services/file_library_service.dart';
import '../services/graph_service.dart';
import '../services/library_service.dart';
import '../services/paper_service.dart';
import '../services/platform_capabilities.dart';
import 'preview/file_preview.dart';

const statusOptions = ['未读', '在读', '已读'];

/// 左侧树的浏览方式：按分类、按研究主题、按真实文件夹层级。
enum _TreeMode { category, research, folder }

/// 文件夹模式用的目录节点：保存子目录、本层笔记与文件。
class _FolderNode {
  _FolderNode(this.name);

  final String name;
  final Map<String, _FolderNode> dirs = {};
  final List<StandardNote> notes = [];
  final List<LibraryFile> files = [];

  /// 该目录（含所有子目录）下的笔记 + 文件总数，用于显示徽标。
  int get count {
    var c = notes.length + files.length;
    for (final d in dirs.values) {
      c += d.count;
    }
    return c;
  }
}

Color statusColor(String status) => switch (status) {
  '在读' => const Color(0xFFF59E0B),
  '已读' => const Color(0xFF22C55E),
  _ => const Color(0xFF9B9B9F),
};

/// 助手文本切片：普通内容或 `<think>` 思考内容。
class _TextSeg {
  _TextSeg(this.text, this.isThink, this.closed);

  final String text;
  final bool isThink;

  /// 思考块是否已闭合（`</think>` 已出现）；流式生成中未闭合时为 false。
  final bool closed;
}

class _ContinueResearchRequest {
  _ContinueResearchRequest({required this.topic, required this.clarification});

  final String topic;
  final String clarification;
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.library,
    required this.fileLibrary,
    required this.experiment,
    this.initialNote,
    this.onContinueResearch,
    this.onConvertResearchToPaper,
    this.onOpenAsProject,
  });

  final LibraryService library;
  final FileLibraryService fileLibrary;
  final ExperimentService experiment;
  final StandardNote? initialNote;
  final void Function(String topic, String clarification)? onContinueResearch;
  final void Function(StandardNote note, PaperFormat format)?
  onConvertResearchToPaper;

  /// 以「项目」形式打开实验工程，切换到项目页继续工程化开发。
  /// 传出工程路径与来源研究（路径、标题），用于建立关联并注入开发记忆。
  final void Function(
    String projectPath,
    String researchPath,
    String researchTitle,
  )?
  onOpenAsProject;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  StandardNote? _selected;
  LibraryFile? _selectedFile;
  bool _editing = false;
  bool _backlinksExpanded = false;
  String _selectionText = '';
  int _detailTab = 0; // 研究笔记详情：0=报告，1=实验
  LibraryFile? _previewFile; // 「打开原文」侧滑预览的文件
  final Set<String> _expanded = {};
  final Set<FileKind> _expandedKinds = {};
  final Set<int> _expandedSteps = {}; // 实验面板里展开了输出的工具步骤
  final Map<String, bool> _expandedThinks = {}; // 「思考过程」块的展开状态（按 事件-片段 索引）
  _TreeMode _treeMode = _TreeMode.category; // 左侧树的浏览方式：分类 / 研究 / 文件夹
  final Set<String> _expandedFolders = {}; // 文件夹模式下展开的目录（按相对路径 key）
  String _query = ''; // 顶部搜索框的关键词；非空时左侧改为显示搜索结果
  final _searchController = TextEditingController();
  final _expScroll = ScrollController();
  final _editController = TextEditingController();
  final _myNoteController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selected = widget.initialNote;
    final cat = widget.initialNote?.category;
    if (cat != null) _expanded.add(cat);
  }

  @override
  void dispose() {
    _expScroll.dispose();
    _editController.dispose();
    _myNoteController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _select(StandardNote note) {
    setState(() {
      _selected = note;
      _selectedFile = null;
      _editing = false;
      _backlinksExpanded = false;
      _selectionText = '';
      _detailTab = 0;
      _previewFile = null;
      // 只保留当前选中笔记所属分组展开，其余全部折叠。
      _expanded
        ..clear()
        ..add(
          _treeMode == _TreeMode.research && note.research.isNotEmpty
              ? note.research
              : note.category,
        );
      _expandedKinds.clear();
      _myNoteController.clear();
    });
    // 打开即自动从「未读」变为「在读」，「已读」由用户手动标记
    if (note.status == '未读') {
      widget.library.setStatus(note, '在读');
    }
  }

  void _selectFile(LibraryFile file) {
    setState(() {
      _selectedFile = file;
      _selected = null;
      _editing = false;
      _previewFile = null;
      // 只保留当前选中文件所属类型展开，其余全部折叠。
      _expanded.clear();
      _expandedKinds
        ..clear()
        ..add(file.kind);
    });
  }

  Future<void> _openAttachment(StandardNote note) async {
    final path = widget.library.resolveAttachment(note);
    if (path == null) {
      _toast('这篇笔记没有关联原文附件');
      return;
    }
    final file = File(path);
    if (!await file.exists()) {
      _toast('原文文件不存在：$path');
      return;
    }
    final stat = await file.stat();
    final name = p.basename(path);
    if (!mounted) return;
    setState(() {
      _previewFile = LibraryFile(
        path: path,
        name: name,
        kind: _kindForName(name),
        size: stat.size,
        modified: stat.modified,
      );
    });
  }

  void _closePreview() => setState(() => _previewFile = null);

  FileKind _kindForName(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    const img = {'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'ico'};
    const vid = {'mp4', 'mkv', 'mov', 'avi', 'wmv', 'flv', 'webm', 'm4v'};
    if (img.contains(ext)) return FileKind.image;
    if (vid.contains(ext)) return FileKind.video;
    return FileKind.document;
  }

  /// 将 Obsidian 双链转为可点击的 Markdown 链接。
  String _markdownData(StandardNote note) => note.body
      .replaceAllMapped(
        RegExp(r'\[\[([^\]\|]+)\|([^\]]+)\]\]'),
        (m) => '[${m.group(2)}](wiki:${Uri.encodeComponent(m.group(1)!)})',
      )
      .replaceAllMapped(
        RegExp(r'\[\[([^\]]+)\]\]'),
        (m) => '[${m.group(1)}](wiki:${Uri.encodeComponent(m.group(1)!)})',
      );

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
    final matches = widget.library.notes
        .where((n) => n.fileName == name)
        .toList();
    if (matches.isNotEmpty) {
      _select(matches.first);
    } else {
      _toast('知识库中找不到：$name');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        width: 400,
      ),
    );
  }

  Future<void> _generateNote(StandardNote note) async {
    try {
      await widget.library.generateNote(note);
      _toast('已生成《${note.fullTitle}》的笔记');
    } catch (e) {
      _toast('生成失败：$e');
    }
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
      _toast('已生成 PPT：${p.basename(relPath)}');
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
      _toast('已导出 PDF：${p.basename(relPath)}');
    } catch (e) {
      _toast('导出 PDF 失败：$e');
    }
  }

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

  static String _clipContext(String s, int maxLen) {
    final clean = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= maxLen) return clean;
    return '${clean.substring(0, maxLen)}…';
  }

  /// 弹出文本编辑框，返回用户确认的文本（取消返回 null）。
  Future<String?> _promptText({
    required String title,
    required String label,
    required String initial,
    String? helper,
    String confirm = '确定',
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (helper != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    helper,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF6B6B70),
                    ),
                  ),
                ),
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 2,
                maxLines: 6,
                style: const TextStyle(fontSize: 13.5, height: 1.5),
                decoration: InputDecoration(
                  labelText: label,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(confirm),
          ),
        ],
      ),
    );
  }

  /// 针对选中文字（或整体主题）继续展开一轮新的深入研究。
  Future<void> _continueResearch(StandardNote note) async {
    final request = await _promptContinueResearch(note);
    if (request == null || request.topic.isEmpty) return;
    widget.onContinueResearch?.call(request.topic, request.clarification);
  }

  Future<void> _convertResearchToPaper(StandardNote note) async {
    final format = await showDialog<PaperFormat>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('将研究转为论文'),
        content: const Text('请选择论文写作格式。系统会进入写作空间，并同时起草中文稿和英文稿。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, PaperFormat.markdown),
            child: const Text('Markdown'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, PaperFormat.latex),
            child: const Text('LaTeX'),
          ),
        ],
      ),
    );
    if (format == null) return;
    widget.onConvertResearchToPaper?.call(note, format);
  }

  Future<_ContinueResearchRequest?> _promptContinueResearch(StandardNote note) {
    final selected = _selectionText.trim();
    final hasSelection = selected.isNotEmpty;
    final baseTitle = note.research.isNotEmpty
        ? note.research
        : note.fullTitle.replaceFirst('【研究】', '');
    final controller = TextEditingController(
      text: hasSelection ? _clipContext(selected, 900) : baseTitle,
    );
    var includeContext = true;
    return showDialog<_ContinueResearchRequest>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('继续深入研究'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasSelection
                      ? '将围绕你选中的片段继续深挖，也可以编辑下方问题。'
                      : '默认基于当前报告继续探索，你可以在下方输入新的追问方向。',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF6B6B70),
                  ),
                ),
                const SizedBox(height: 10),
                FilterChip(
                  selected: includeContext,
                  avatar: Icon(
                    hasSelection
                        ? Icons.format_quote_outlined
                        : Icons.article_outlined,
                    size: 15,
                  ),
                  label: Text(hasSelection ? '引用选中片段' : '引用本文'),
                  onSelected: (v) => setDialogState(() => includeContext = v),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: controller,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 7,
                  style: const TextStyle(fontSize: 13.5, height: 1.5),
                  decoration: const InputDecoration(
                    labelText: '追问方向 / 研究问题',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final topic = controller.text.trim();
                if (topic.isEmpty) return;
                Navigator.pop(
                  ctx,
                  _ContinueResearchRequest(
                    topic: topic,
                    clarification: includeContext
                        ? _continueResearchContext(note, selected)
                        : '',
                  ),
                );
              },
              child: const Text('开始研究'),
            ),
          ],
        ),
      ),
    );
  }

  String _continueResearchContext(StandardNote note, String selected) {
    if (selected.trim().isNotEmpty) {
      return '''
用户正在基于已有主题研究报告继续深入研究。
当前报告：${note.fullTitle}
用户选中的报告片段如下，请把它作为本轮研究的重点上下文，围绕其中的问题、概念、方案或判断继续检索、发散和总结：
${_clipContext(selected, 5000)}
''';
    }
    return '''
用户正在基于已有主题研究报告继续追问。请把当前报告作为本轮研究的背景材料，继续挖掘、发散和总结新的思路，不要重复原报告已完成的基础介绍。
当前报告：${note.fullTitle}
研究主题：${note.research}

当前报告正文摘要：
${_clipContext(note.body, 12000)}
''';
  }

  /// 让第二大脑在用户指定的工程目录下自行编写实验来验证/解决问题。
  /// 实验严格基于该研究报告的正文，且动手前先审题——若有疑问会先向用户确认。
  Future<void> _doExperiment(StandardNote note) async {
    final base = _selectionText.isNotEmpty
        ? _selectionText
        : note.fullTitle.replaceFirst('【研究】', '');
    final objective = await _promptText(
      title: '做实验',
      label: '实验目标 / 要解决的问题',
      initial: base,
      helper:
          '实验将严格围绕本篇研究报告展开。稍后第二大脑会先审题，'
          '若对目标有疑问会先向你确认，再选择工程目录动手写可运行的实验代码。',
      confirm: '下一步：审题',
    );
    if (objective == null || objective.isEmpty) return;

    // 报告正文作为实验的核心上下文（选中文字优先；否则用整篇报告）。
    final reportContent = _selectionText.isNotEmpty
        ? _selectionText
        : note.body;

    // 审题/澄清：有疑问先问用户，避免做出与报告无关的实验。
    String clarifyQa = '';
    try {
      _toast('正在理解报告与实验目标…');
      final c = await widget.experiment.clarify(
        objective: objective,
        reportContent: reportContent,
      );
      if (!mounted) return;
      if (c.needsInput) {
        final answers = await _askClarifications(c);
        if (answers == null) return; // 用户取消，不开始实验
        clarifyQa = answers;
      }
    } catch (e) {
      _toast('审题失败，已取消（请稍后重试）：$e');
      return;
    }

    final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择放置实验工程的文件夹');
    if (dir == null) return;
    if (!mounted) return;
    setState(() => _detailTab = 1);
    _toast('第二大脑开始动手做实验（写代码→运行→修复）…');
    try {
      final created = await widget.experiment.run(
        objective: objective,
        projectPath: dir,
        context: _experimentContext(reportContent, clarifyQa),
        memoryKey: note.filePath,
      );
      await launchUrl(Uri.file(created));
      _toast('实验已结束，工程：$created');
    } catch (e) {
      _toast('实验生成失败：$e');
    }
    if (mounted) setState(() {});
  }

  /// 组装实验上下文：以研究报告全文为核心，附上已与用户确认的关键信息。
  String _experimentContext(String reportContent, String clarifyQa) {
    final buf = StringBuffer()
      ..writeln('【研究报告全文（本次实验必须紧扣此报告，不得偏离）】')
      ..writeln(reportContent.trim());
    if (clarifyQa.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【动手前已与用户确认的关键信息】')
        ..writeln(clarifyQa.trim());
    }
    return buf.toString();
  }

  /// 弹出澄清问题对话框，收集用户答复并返回 Q/A 文本；用户取消返回 null。
  Future<String?> _askClarifications(ExperimentClarification c) {
    final controllers = [
      for (var i = 0; i < c.questions.length; i++) TextEditingController(),
    ];
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('开始前，请先确认几个问题'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (c.understanding.isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FBF9),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFB9E8E0)),
                    ),
                    child: Text(
                      '我的理解：${c.understanding}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: Color(0xFF0F766E),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                const Text(
                  '为确保实验紧扣报告内容，请补充以下信息（可酌情留空）：',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFF6B6B70)),
                ),
                const SizedBox(height: 12),
                for (var i = 0; i < c.questions.length; i++) ...[
                  Text(
                    '${i + 1}. ${c.questions[i]}',
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: controllers[i],
                    minLines: 1,
                    maxLines: 4,
                    style: const TextStyle(fontSize: 13.5, height: 1.5),
                    decoration: const InputDecoration(
                      hintText: '你的答复…',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final buf = StringBuffer();
              for (var i = 0; i < c.questions.length; i++) {
                final a = controllers[i].text.trim();
                buf
                  ..writeln('问：${c.questions[i]}')
                  ..writeln('答：${a.isEmpty ? '（用户未填写）' : a}')
                  ..writeln();
              }
              Navigator.pop(ctx, buf.toString());
            },
            child: const Text('确认并选择工程目录'),
          ),
        ],
      ),
    );
  }

  /// 继续做实验：直接复用记忆中的工程目录，无需再次选目录。
  Future<void> _continueExperiment(StandardNote note) async {
    final dir = widget.experiment.projectFor(note.filePath);
    if (dir == null) {
      _toast('未找到该实验工程，请重新「做实验」');
      return;
    }
    final instruction = await _promptText(
      title: '继续做实验',
      label: '接下来要做什么（留空＝根据记忆自动分析并继续完善）',
      initial: _selectionText,
      helper: '将基于工程「$dir」的记忆与现有代码继续迭代。',
      confirm: '继续',
    );
    if (instruction == null) return; // 取消；留空则自动继续
    if (!mounted) return;
    setState(() => _detailTab = 1);
    _toast('正在读取记忆与现有代码，继续推进实验…');
    try {
      final reportContent = _selectionText.isNotEmpty
          ? _selectionText
          : note.body;
      final task = instruction.trim().isEmpty
          ? '根据已有记忆与现有代码，自动分析当前状态并继续完善实验，修复未解决的问题、推进到下一步。'
          : instruction;
      final updated = await widget.experiment.continueRun(
        instruction: task,
        projectPath: dir,
        context: _experimentContext(reportContent, ''),
        memoryKey: note.filePath,
      );
      await launchUrl(Uri.file(updated));
      _toast('实验工程已更新：$updated');
    } catch (e) {
      _toast('继续做实验失败：$e');
    }
    if (mounted) setState(() {});
  }

  /// 把实验工程作为「项目」打开，切换到项目页继续工程化开发。
  void _openAsProject(StandardNote note) {
    final dir = widget.experiment.projectFor(note.filePath);
    if (dir == null) {
      _toast('未找到该实验工程，请重新「做实验」');
      return;
    }
    if (widget.onOpenAsProject == null) {
      _toast('无法打开项目');
      return;
    }
    widget.onOpenAsProject!(dir, note.filePath, note.fullTitle);
  }

  /// 重新扫描：合并相同主题、去重资料，再为空白笔记自动生成内容。
  Future<void> _rescan() async {
    await widget.library.reload();

    _toast('正在合并相同主题、去重资料…');
    final merged = await widget.library.consolidateCategories();
    if (merged > 0) await widget.library.reload();
    final removedNotes = await widget.library.dedupNotes();
    if (removedNotes > 0) await widget.library.reload();
    final removedFiles = await widget.fileLibrary.dedup();
    if (merged > 0 || removedNotes > 0 || removedFiles > 0) {
      _toast('已合并 $merged 篇到同主题、去重 ${removedNotes + removedFiles} 项重复资料');
    }

    final count = widget.library.notes
        .where(widget.library.needsGeneration)
        .length;
    if (count == 0) {
      _toast('扫描完成，没有需要生成的空白笔记');
      return;
    }
    _toast('开始为 $count 篇空白笔记生成内容…');
    final failed = await widget.library.generateAllEmpty();
    _toast(failed == 0 ? '已自动生成 $count 篇笔记' : '生成完成，$failed 篇失败');
  }

  Future<void> _importFiles() async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;
    final paths = result.files.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) return;
    _toast('正在导入并自动归类 ${paths.length} 个文件…');
    final ok = await widget.fileLibrary.importFiles(paths);
    _toast('已导入 $ok 个文件并按类型归类');
  }

  Future<void> _scanFolder() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: '选择要整理的文件夹（其中文件将按类型移动到文件库）',
    );
    if (dir == null) return;
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('扫描整理文件夹'),
        content: Text('将把以下文件夹中的所有文件，按类型移动到知识库的「文件库」中：\n\n$dir'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始整理'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    _toast('正在扫描整理…');
    final ok = await widget.fileLibrary.importFromDirectory(dir);
    _toast('已整理 $ok 个文件并按类型归类');
  }

  static String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Widget _buildFileDetail(LibraryFile file) {
    final m = file.modified;
    final stamp =
        '${m.year}-${m.month.toString().padLeft(2, '0')}-${m.day.toString().padLeft(2, '0')} '
        '${m.hour.toString().padLeft(2, '0')}:${m.minute.toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _kindIcon(file.kind),
                    size: 20,
                    color: const Color(0xFF6B6B70),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      file.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 14,
                children: [
                  Text(
                    file.kind.label,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF6B6B70),
                    ),
                  ),
                  Text(
                    _humanSize(file.size),
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF6B6B70),
                    ),
                  ),
                  Text(
                    stamp,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF6B6B70),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => _openFile(file),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('打开'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _revealFile(file),
                    icon: const Icon(Icons.folder_open_outlined, size: 16),
                    label: const Text('在文件夹中显示'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _confirmDeleteFile(file),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('删除'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFB91C1C),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: Theme.of(context).dividerColor),
            ],
          ),
        ),
        Expanded(
          child: FilePreview(
            file: file,
            placeholder: Center(child: _filePlaceholder(file)),
          ),
        ),
      ],
    );
  }

  Widget _filePlaceholder(LibraryFile file) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(_kindIcon(file.kind), size: 64, color: const Color(0xFFCDCDD2)),
        const SizedBox(height: 12),
        const Text(
          '点击「打开」用系统默认程序查看',
          style: TextStyle(fontSize: 13, color: Color(0xFF9B9B9F)),
        ),
      ],
    );
  }

  Future<void> _openFile(LibraryFile file) async {
    final ok = await launchUrl(Uri.file(file.path));
    if (!ok) _toast('无法打开：${file.path}');
  }

  Future<void> _revealFile(LibraryFile file) async {
    final dir = p.dirname(file.path);
    await launchUrl(Uri.file(dir));
  }

  Future<void> _confirmDeleteFile(LibraryFile file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件'),
        content: Text('确定要从知识库中删除「${file.name}」吗？此操作将从磁盘移除该文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB91C1C),
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.fileLibrary.deleteFile(file);
    setState(() => _selectedFile = null);
    _toast('已删除');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.library,
        widget.fileLibrary,
        widget.experiment,
      ]),
      builder: (context, _) {
        final lib = widget.library;
        if (lib.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (lib.notInitialized) {
          return _VaultInitView(library: lib);
        }
        if (lib.error != null) {
          return Center(child: Text(lib.error!));
        }
        if (_selected != null && !lib.notes.contains(_selected)) {
          _selected = null;
        }
        if (_selectedFile != null &&
            !widget.fileLibrary.files.any(
              (f) => f.path == _selectedFile!.path,
            )) {
          _selectedFile = null;
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 300, child: _buildTree(lib)),
            VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
            Expanded(child: _buildMainArea()),
          ],
        );
      },
    );
  }

  Widget _buildMainPanel() {
    if (_selectedFile != null) return _buildFileDetail(_selectedFile!);
    if (_selected != null) return _buildDetail(_selected!);
    return const Center(
      child: Text('选择一份标准或文件查看详情', style: TextStyle(color: Color(0xFF9B9B9F))),
    );
  }

  /// 主区域 + 「打开原文」侧滑预览面板。
  Widget _buildMainArea() {
    final showing = _previewFile != null;
    return Stack(
      children: [
        Positioned.fill(child: _buildMainPanel()),
        // 半透明遮罩，点击关闭
        IgnorePointer(
          ignoring: !showing,
          child: AnimatedOpacity(
            opacity: showing ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: GestureDetector(
              onTap: _closePreview,
              child: Container(color: Colors.black.withValues(alpha: 0.22)),
            ),
          ),
        ),
        // 右侧滑出的预览面板
        Align(
          alignment: Alignment.centerRight,
          child: FractionallySizedBox(
            widthFactor: 0.66,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              offset: showing ? Offset.zero : const Offset(1, 0),
              child: showing
                  ? _buildPreviewPanel(_previewFile!)
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewPanel(LibraryFile file) {
    return Material(
      elevation: 12,
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _kindIcon(file.kind),
                  size: 18,
                  color: const Color(0xFF6B6B70),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '用系统程序打开',
                  onPressed: () => _openFile(file),
                  icon: const Icon(Icons.open_in_new, size: 18),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: _closePreview,
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          Expanded(
            child: FilePreview(
              file: file,
              placeholder: Center(child: _filePlaceholder(file)),
            ),
          ),
        ],
      ),
    );
  }

  /// 树状目录：分类为父节点，可折叠；笔记为子节点。文件库按类型分组在末尾。
  Widget _buildTree(LibraryService lib) {
    final fileLib = widget.fileLibrary;
    final researchGroups = _researchGroups(lib.notes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchBox(),
        _buildTreeModeSwitch(researchGroups.length),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            // 顶部搜索框非空时，跨笔记/文件按名称过滤，忽略当前浏览模式。
            children: _query.trim().isNotEmpty
                ? _buildSearchResults(lib, fileLib)
                : _buildTreeBody(lib, fileLib, researchGroups),
          ),
        ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: lib.batchRunning ? null : _rescan,
                  icon: lib.batchRunning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 16),
                  label: Text(
                    lib.batchRunning
                        ? '生成 ${lib.batchDone}/${lib.batchTotal}'
                        : '重新扫描',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: fileLib.working ? null : _importFiles,
                  icon: const Icon(Icons.upload_file_outlined, size: 15),
                  label: const Text('导入文件', style: TextStyle(fontSize: 12.5)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: fileLib.working ? null : _scanFolder,
                  icon: fileLib.working
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.create_new_folder_outlined, size: 15),
                  label: Text(
                    fileLib.working
                        ? '${fileLib.workingDone}/${fileLib.workingTotal}'
                        : '扫描整理',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '${lib.notes.length} 份笔记 · ${fileLib.files.length} 个文件',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF9B9B9F)),
          ),
        ),
      ],
    );
  }

  /// 顶部搜索框：跨「笔记 + 文件」按名称/标题/编号过滤。
  Widget _buildSearchBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      child: TextField(
        controller: _searchController,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: '搜索笔记 / 文件…',
          hintStyle: const TextStyle(fontSize: 13, color: Color(0xFFA8A8AC)),
          prefixIcon: const Icon(Icons.search, size: 18),
          prefixIconConstraints: const BoxConstraints(minWidth: 34),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 9),
          filled: true,
          fillColor: const Color(0xFFF5F5F6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: (v) => setState(() => _query = v),
      ),
    );
  }

  /// 搜索结果：扁平列出匹配的笔记与文件（忽略当前浏览模式）。
  List<Widget> _buildSearchResults(
    LibraryService lib,
    FileLibraryService fileLib,
  ) {
    final q = _query.trim().toLowerCase();
    final notes =
        lib.notes
            .where(
              (n) =>
                  n.fullTitle.toLowerCase().contains(q) ||
                  n.standardNo.toLowerCase().contains(q) ||
                  n.category.toLowerCase().contains(q),
            )
            .toList()
          ..sort((a, b) => a.fullTitle.compareTo(b.fullTitle));
    final files =
        fileLib.files.where((f) => f.name.toLowerCase().contains(q)).toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    if (notes.isEmpty && files.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.fromLTRB(12, 16, 12, 8),
          child: Text(
            '没有匹配的笔记或文件',
            style: TextStyle(fontSize: 12.5, color: Color(0xFF9B9B9F)),
          ),
        ),
      ];
    }
    return [
      if (notes.isNotEmpty) _buildSectionLabel('笔记 · ${notes.length}'),
      for (final n in notes) _buildTreeNote(n, left: 14),
      if (files.isNotEmpty) _buildSectionLabel('文件 · ${files.length}'),
      for (final f in files) _buildTreeFile(f, left: 14),
    ];
  }

  /// 小节标题（灰色小字）。
  Widget _buildSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 8, 4),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: Color(0xFF9B9B9F),
        ),
      ),
    );
  }

  /// 按当前浏览模式构建左侧树的内容。
  List<Widget> _buildTreeBody(
    LibraryService lib,
    FileLibraryService fileLib,
    Map<String, List<StandardNote>> researchGroups,
  ) {
    // 文件库（按类型）区块：分类 / 研究 模式末尾追加，文件夹模式已含在树里。
    List<Widget> fileSection() => [
      _buildFileSectionHeader(),
      for (final k in fileLib.nonEmptyKinds) ...[
        _buildTreeKind(k, fileLib.filesOf(k).length),
        if (_expandedKinds.contains(k))
          for (final f in fileLib.filesOf(k)) _buildTreeFile(f),
      ],
    ];

    switch (_treeMode) {
      case _TreeMode.folder:
        return _buildFolderTree(lib, fileLib);
      case _TreeMode.research:
        return [
          if (researchGroups.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 16, 12, 8),
              child: Text(
                '暂无主题研究产物',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF9B9B9F)),
              ),
            )
          else
            for (final e in researchGroups.entries) ...[
              _buildTreeResearch(e.key, e.value.length),
              if (_expanded.contains(e.key))
                for (final n in _sortResearchNotes(e.value))
                  _buildTreeNote(n, left: 33),
            ],
          ...fileSection(),
        ];
      case _TreeMode.category:
        return [
          for (final c in lib.categories) ...[
            _buildTreeCategory(
              c,
              lib.notes.where((n) => n.category == c).length,
            ),
            if (_expanded.contains(c))
              for (final n in lib.notes.where((n) => n.category == c))
                _buildTreeNote(n),
          ],
          ...fileSection(),
        ];
    }
  }

  /// 文件夹模式：按知识库里**真实的目录层级**构建一棵树（笔记 + 文件），
  /// 这样「政策法规 → 国标 / 地标」这类分层分级就能原样展示，方便查找浏览。
  List<Widget> _buildFolderTree(LibraryService lib, FileLibraryService fileLib) {
    final vault = lib.settings.vaultPath;
    final root = _FolderNode('');

    void add(String absPath, {StandardNote? note, LibraryFile? file}) {
      final rel = p.relative(absPath, from: vault);
      final segs = rel
          .split(RegExp(r'[\\/]'))
          .where((s) => s.isNotEmpty)
          .toList();
      var cur = root;
      // 除最后一段（文件名）外，逐级建立 / 复用目录节点。
      for (var i = 0; i < segs.length - 1; i++) {
        cur = cur.dirs.putIfAbsent(segs[i], () => _FolderNode(segs[i]));
      }
      if (note != null) cur.notes.add(note);
      if (file != null) cur.files.add(file);
    }

    for (final n in lib.notes) {
      add(n.filePath, note: n);
    }
    for (final f in fileLib.files) {
      add(f.path, file: f);
    }

    if (root.dirs.isEmpty && root.notes.isEmpty && root.files.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.fromLTRB(12, 16, 12, 8),
          child: Text(
            '知识库为空',
            style: TextStyle(fontSize: 12.5, color: Color(0xFF9B9B9F)),
          ),
        ),
      ];
    }
    return _folderRows(root, '', 0);
  }

  /// 递归把文件夹节点展开成有序的行（目录在前、笔记其次、文件最后）。
  List<Widget> _folderRows(_FolderNode node, String path, int depth) {
    final rows = <Widget>[];
    final names = node.dirs.keys.toList()..sort();
    for (final name in names) {
      final child = node.dirs[name]!;
      final childPath = '$path/$name';
      final expanded = _expandedFolders.contains(childPath);
      rows.add(_buildTreeFolder(name, childPath, expanded, depth, child.count));
      if (expanded) rows.addAll(_folderRows(child, childPath, depth + 1));
    }
    final notes = [...node.notes]
      ..sort((a, b) => a.fullTitle.compareTo(b.fullTitle));
    for (final n in notes) {
      rows.add(_buildTreeNote(n, left: _indent(depth + 1)));
    }
    final files = [...node.files]..sort((a, b) => a.name.compareTo(b.name));
    for (final f in files) {
      rows.add(_buildTreeFile(f, left: _indent(depth + 1)));
    }
    return rows;
  }

  /// 按层级深度计算左缩进。
  double _indent(int depth) => 12 + depth * 16;

  Widget _buildTreeFolder(
    String name,
    String pathKey,
    bool expanded,
    int depth,
    int count,
  ) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() {
          expanded
              ? _expandedFolders.remove(pathKey)
              : _expandedFolders.add(pathKey);
        }),
        child: Padding(
          padding: EdgeInsets.fromLTRB(_indent(depth), 7, 8, 7),
          child: Row(
            children: [
              AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: const Icon(
                  Icons.chevron_right,
                  size: 17,
                  color: Color(0xFF6B6B70),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                expanded ? Icons.folder_open : Icons.folder_outlined,
                size: 15,
                color: const Color(0xFF6B6B70),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '$count',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9B9B9F)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Map<String, List<StandardNote>> _researchGroups(List<StandardNote> notes) {
    final groups = <String, List<StandardNote>>{};
    for (final n in notes) {
      final key = n.research.trim();
      if (key.isEmpty) continue;
      (groups[key] ??= []).add(n);
    }
    final entries = groups.entries.toList()
      ..sort(
        (a, b) => _latestModified(b.value).compareTo(_latestModified(a.value)),
      );
    return Map.fromEntries(entries);
  }

  DateTime _latestModified(List<StandardNote> notes) {
    var latest = notes.first.modified;
    for (final n in notes.skip(1)) {
      if (n.modified.isAfter(latest)) latest = n.modified;
    }
    return latest;
  }

  List<StandardNote> _sortResearchNotes(List<StandardNote> notes) {
    final sorted = [...notes];
    sorted.sort((a, b) {
      if (a.isResearchReport != b.isResearchReport) {
        return a.isResearchReport ? -1 : 1;
      }
      return a.fullTitle.compareTo(b.fullTitle);
    });
    return sorted;
  }

  Widget _buildTreeModeSwitch(int researchCount) {
    Widget item(_TreeMode mode, String label, IconData icon) {
      final selected = _treeMode == mode;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() {
            _treeMode = mode;
            _expanded.clear();
            // 切到分类/研究时，把当前选中项所属分组展开；文件夹模式不动。
            final note = _selected;
            if (note != null && mode != _TreeMode.folder) {
              final key = mode == _TreeMode.research && note.research.isNotEmpty
                  ? note.research
                  : note.category;
              _expanded.add(key);
            }
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF1A1A1A) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: selected ? Colors.white : const Color(0xFF6B6B70),
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : const Color(0xFF6B6B70),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F1F3),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                item(_TreeMode.category, '分类', Icons.folder_outlined),
                item(_TreeMode.research, '研究', Icons.travel_explore_outlined),
                item(_TreeMode.folder, '文件夹', Icons.account_tree_outlined),
              ],
            ),
          ),
          if (_treeMode == _TreeMode.research)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '$researchCount 个研究主题',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Color(0xFF9B9B9F),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFileSectionHeader() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(12, 14, 8, 4),
      child: Text(
        '文件库',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: Color(0xFF9B9B9F),
        ),
      ),
    );
  }

  Widget _buildTreeKind(FileKind kind, int count) {
    final expanded = _expandedKinds.contains(kind);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() {
          expanded ? _expandedKinds.remove(kind) : _expandedKinds.add(kind);
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: const Icon(
                  Icons.chevron_right,
                  size: 17,
                  color: Color(0xFF6B6B70),
                ),
              ),
              const SizedBox(width: 2),
              Icon(_kindIcon(kind), size: 15, color: const Color(0xFF6B6B70)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  kind.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '$count',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9B9B9F)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTreeFile(LibraryFile file, {double left = 33}) {
    final selected = file.path == _selectedFile?.path;
    return Material(
      color: selected ? const Color(0xFFF1F1F3) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _selectFile(file),
        child: Tooltip(
          message: file.name,
          waitDuration: const Duration(milliseconds: 600),
          child: Padding(
            padding: EdgeInsets.fromLTRB(left, 6.5, 8, 6.5),
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }

  static IconData _kindIcon(FileKind kind) => switch (kind) {
    FileKind.video => Icons.movie_outlined,
    FileKind.image => Icons.image_outlined,
    FileKind.document => Icons.description_outlined,
    FileKind.photo => Icons.photo_camera_outlined,
    FileKind.other => Icons.insert_drive_file_outlined,
  };

  Widget _buildTreeCategory(String category, int count) {
    final expanded = _expanded.contains(category);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() {
          expanded ? _expanded.remove(category) : _expanded.add(category);
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: const Icon(
                  Icons.chevron_right,
                  size: 17,
                  color: Color(0xFF6B6B70),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '$count',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9B9B9F)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTreeResearch(String research, int count) {
    final expanded = _expanded.contains(research);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() {
          expanded ? _expanded.remove(research) : _expanded.add(research);
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 150),
                child: const Icon(
                  Icons.chevron_right,
                  size: 17,
                  color: Color(0xFF6B6B70),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.travel_explore_outlined,
                size: 15,
                color: Color(0xFF0D9488),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  research,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '$count',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9B9B9F)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTreeNote(StandardNote n, {double left = 29}) {
    final selected = n == _selected;
    return Material(
      color: selected ? const Color(0xFFF1F1F3) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _select(n),
        child: Tooltip(
          message: n.standardNo.isEmpty
              ? n.fullTitle
              : '${n.standardNo}  ${n.fullTitle}',
          waitDuration: const Duration(milliseconds: 600),
          child: Padding(
            padding: EdgeInsets.fromLTRB(left, 6.5, 8, 6.5),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: statusColor(n.status),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    n.fullTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (n.attachmentRelPath == null) ...[
                  const SizedBox(width: 6),
                  const _NoOriginalTag(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetail(StandardNote note) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                note.fullTitle,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 14,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (note.standardNo.isNotEmpty)
                    Text(
                      note.standardNo,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF6B6B70),
                      ),
                    ),
                  Text(
                    note.category,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF6B6B70),
                    ),
                  ),
                  if (note.year.isNotEmpty)
                    Text(
                      '${note.year} 年',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF6B6B70),
                      ),
                    ),
                  if (note.attachmentRelPath == null) const _NoOriginalTag(),
                  if (note.research.isNotEmpty) _ResearchTag(note.research),
                  DropdownButton<String>(
                    value: statusOptions.contains(note.status)
                        ? note.status
                        : statusOptions.first,
                    underline: const SizedBox.shrink(),
                    style: TextStyle(
                      fontSize: 13,
                      color: statusColor(note.status),
                    ),
                    items: [
                      for (final s in statusOptions)
                        DropdownMenuItem(value: s, child: Text(s)),
                    ],
                    onChanged: (v) {
                      if (v != null) widget.library.setStatus(note, v);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (note.isResearchReport) ...[
                    FilledButton.tonalIcon(
                      onPressed: () => _continueResearch(note),
                      icon: const Icon(Icons.travel_explore, size: 16),
                      label: const Text('继续深入研究'),
                    ),
                    FilledButton.icon(
                      onPressed: () => _convertResearchToPaper(note),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF0D9488),
                      ),
                      icon: const Icon(Icons.article_outlined, size: 16),
                      label: const Text('将研究转为论文'),
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
                            subtitle: Text('生成可演示的 HTML PPT'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'pdf',
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.picture_as_pdf_outlined),
                            title: Text('导出 PDF'),
                            subtitle: Text('由 HTML 报告打印为 PDF'),
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
                            widget.library.isGeneratingPpt(note)
                                ? '导出中…'
                                : '导出',
                          ),
                        ),
                      ),
                    ),
                    if (PlatformCapabilities.supportsExperiment)
                      if (widget.experiment.projectFor(note.filePath) == null)
                        FilledButton.icon(
                          onPressed: () => _doExperiment(note),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF0D9488),
                          ),
                          icon: const Icon(Icons.science_outlined, size: 16),
                          label: const Text('做实验'),
                        )
                      else ...[
                        FilledButton.icon(
                          onPressed: () => _continueExperiment(note),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF0D9488),
                          ),
                          icon: const Icon(Icons.replay, size: 16),
                          label: const Text('继续做实验'),
                        ),
                        if (PlatformCapabilities.supportsProjectDev)
                          OutlinedButton.icon(
                            onPressed: () => _openAsProject(note),
                            icon: const Icon(
                              Icons.drive_file_move_outlined,
                              size: 16,
                            ),
                            label: const Text('以项目形式打开'),
                          ),
                      ],
                  ] else ...[
                    FilledButton.tonalIcon(
                      onPressed: () => _openAttachment(note),
                      icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
                      label: const Text('打开原文'),
                    ),
                    FilledButton.icon(
                      onPressed: widget.library.isGenerating(note)
                          ? null
                          : () => _generateNote(note),
                      icon: widget.library.isGenerating(note)
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome, size: 16),
                      label: Text(
                        widget.library.isGenerating(note) ? '生成中…' : 'AI 生成笔记',
                      ),
                    ),
                  ],
                  if (!note.isResearchReport)
                    OutlinedButton.icon(
                      onPressed: () {
                        if (_editing) {
                          widget.library.saveBody(note, _editController.text);
                          setState(() => _editing = false);
                          _toast('已保存');
                        } else {
                          _editController.text = note.body;
                          setState(() => _editing = true);
                        }
                      },
                      icon: Icon(
                        _editing ? Icons.save_outlined : Icons.edit_outlined,
                        size: 16,
                      ),
                      label: Text(_editing ? '保存' : '编辑'),
                    ),
                  if (!note.isResearchReport && _editing)
                    TextButton(
                      onPressed: () => setState(() => _editing = false),
                      child: const Text('取消'),
                    ),
                ],
              ),
              if (note.isResearchReport && !_editing && _detailTab == 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _selectionText.isEmpty
                        ? '提示：在下方正文中选中一段文字，可针对该内容继续深入研究'
                        : '已选中 ${_selectionText.length} 字，可对其继续深入研究',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF9B9B9F),
                    ),
                  ),
                ),
              if (note.isResearchReport &&
                  !_editing &&
                  PlatformCapabilities.supportsExperiment) ...[
                const SizedBox(height: 12),
                _buildDetailTabs(),
              ],
              const SizedBox(height: 12),
              Divider(height: 1, color: Theme.of(context).dividerColor),
            ],
          ),
        ),
        Expanded(
          child:
              note.isResearchReport &&
                  !_editing &&
                  PlatformCapabilities.supportsExperiment &&
                  _detailTab == 1
              ? _buildExperimentPanel()
              : _editing
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: TextField(
                    controller: _editController,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      fontSize: 13.5,
                      height: 1.6,
                      fontFamily: 'Consolas',
                    ),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
                )
              : Markdown(
                  data: _markdownData(note),
                  padding: const EdgeInsets.all(24),
                  selectable: true,
                  onSelectionChanged: (text, selection, cause) {
                    final sel =
                        (text != null &&
                            selection.isValid &&
                            !selection.isCollapsed)
                        ? text.substring(selection.start, selection.end).trim()
                        : '';
                    if (sel != _selectionText) {
                      setState(() => _selectionText = sel);
                    }
                  },
                  onTapLink: (text, href, title) => _handleLink(href),
                  styleSheet: MarkdownStyleSheet(
                    p: const TextStyle(fontSize: 14, height: 1.7),
                    h2: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    a: const TextStyle(
                      color: Color(0xFF0D9488),
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
        ),
        if (!_editing && _detailTab == 0) _buildMyNoteComposer(note),
        if (!_editing && _detailTab == 0) _buildBacklinks(note),
      ],
    );
  }

  /// 研究笔记详情的「报告 / 实验」小切换。
  Widget _buildDetailTabs() {
    Widget tab(int i, IconData icon, String label) {
      final on = _detailTab == i;
      return GestureDetector(
        onTap: () => setState(() => _detailTab = i),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: on ? const Color(0xFF1A1A1A) : const Color(0xFFF1F1F3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: on ? Colors.white : const Color(0xFF6B6B70),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: on ? Colors.white : const Color(0xFF6B6B70),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        tab(0, Icons.article_outlined, '报告'),
        const SizedBox(width: 8),
        tab(1, Icons.science_outlined, '实验'),
      ],
    );
  }

  /// 「实验」区：像 Cursor 的 agent 面板那样，以结构化卡片展示运行过程。
  Widget _buildExperimentPanel() {
    return ListenableBuilder(
      listenable: widget.experiment,
      builder: (context, _) {
        final exp = widget.experiment;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_expScroll.hasClients) {
            _expScroll.jumpTo(_expScroll.position.maxScrollExtent);
          }
        });
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Row(
                children: [
                  if (exp.running)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF0D9488),
                      ),
                    )
                  else
                    const Icon(
                      Icons.smart_toy_outlined,
                      size: 16,
                      color: Color(0xFF6B6B70),
                    ),
                  const SizedBox(width: 8),
                  Text(
                    exp.running ? '实验进行中…' : '实验 Agent',
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (exp.running)
                    OutlinedButton.icon(
                      onPressed: exp.cancel,
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: const Color(0xFFD9534F),
                      ),
                      icon: const Icon(Icons.stop_circle_outlined, size: 15),
                      label: const Text('停止'),
                    ),
                  const Spacer(),
                  const Text(
                    '记忆存于工程 MEMORY.md',
                    style: TextStyle(fontSize: 11, color: Color(0xFFA0A0A5)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: exp.events.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          '点击上方「做实验」或「继续做实验」开始，\nAgent 的思考与每一步操作会实时显示在这里。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF8B8B93),
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _expScroll,
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      itemCount: exp.events.length,
                      itemBuilder: (context, i) =>
                          _buildEventItem(exp.events[i], i),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEventItem(AgentEvent e, int index) {
    switch (e.kind) {
      case AgentEventKind.status:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.circle, size: 5, color: Color(0xFFC4C4CC)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  e.text,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF8A8A92),
                  ),
                ),
              ),
            ],
          ),
        );
      case AgentEventKind.assistant:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2, right: 8),
                child: Icon(
                  Icons.auto_awesome,
                  size: 14,
                  color: Color(0xFF0D9488),
                ),
              ),
              Expanded(child: _buildAssistantContent(e.text, index)),
            ],
          ),
        );
      case AgentEventKind.tool:
        return _buildToolCard(e, index);
      case AgentEventKind.changes:
      case AgentEventKind.user:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: _md(e.text),
        );
    }
  }

  /// 助手文本渲染：把 `<think>…</think>`（如 MiniMax 的思考过程）拆出来，
  /// 折叠显示为灰色、小一号的字；其余内容按 Markdown 正常渲染。
  Widget _buildAssistantContent(String text, int index) {
    final segs = _splitThink(text);
    if (segs.length == 1 && !segs.first.isThink) {
      return _md(segs.first.text);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < segs.length; i++)
          if (segs[i].isThink)
            _buildThinkBlock(segs[i].text, '$index-$i', segs[i].closed)
          else if (segs[i].text.trim().isNotEmpty)
            _md(segs[i].text),
      ],
    );
  }

  /// 折叠式「思考过程」块：默认在流式生成中展开、完成后收起，用户点击可切换。
  Widget _buildThinkBlock(String text, String key, bool closed) {
    final expanded = _expandedThinks[key] ?? !closed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expandedThinks[key] = !expanded),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.psychology_outlined,
                    size: 13,
                    color: Color(0xFFA0A0A8),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    closed ? '思考过程' : '思考中…',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFFA0A0A8),
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 15,
                    color: const Color(0xFFA0A0A8),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Container(
              margin: const EdgeInsets.only(top: 2, bottom: 2, left: 2),
              padding: const EdgeInsets.only(left: 8),
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: Color(0xFFE2E2E8), width: 2),
                ),
              ),
              child: MarkdownBody(
                data: text.trim(),
                selectable: true,
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(
                    fontSize: 11.5,
                    height: 1.55,
                    color: Color(0xFF9A9AA2),
                  ),
                  listBullet: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF9A9AA2),
                  ),
                  code: const TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'Consolas',
                    color: Color(0xFF8A8A92),
                    backgroundColor: Color(0xFFF1F1F4),
                  ),
                  strong: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF85858E),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _md(String data) => MarkdownBody(
    data: data,
    selectable: true,
    styleSheet: MarkdownStyleSheet(
      p: const TextStyle(fontSize: 13, height: 1.6, color: Color(0xFF374151)),
      h1: const TextStyle(
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w700,
        color: Color(0xFF1F2937),
      ),
      h2: const TextStyle(
        fontSize: 15,
        height: 1.5,
        fontWeight: FontWeight.w700,
        color: Color(0xFF1F2937),
      ),
      h3: const TextStyle(
        fontSize: 13.5,
        height: 1.5,
        fontWeight: FontWeight.w600,
        color: Color(0xFF1F2937),
      ),
      code: const TextStyle(
        fontSize: 12,
        fontFamily: 'Consolas',
        backgroundColor: Color(0xFFEFF1F4),
      ),
      tableHead: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      tableBody: const TextStyle(fontSize: 12, height: 1.4),
      tableBorder: TableBorder.all(color: const Color(0xFFE0E2E6), width: 1),
      a: const TextStyle(color: Color(0xFF0D9488)),
      blockquote: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
    ),
  );

  /// 把含 `<think>` 标签的文本切成有序片段（普通 / 思考）。
  List<_TextSeg> _splitThink(String input) {
    final segs = <_TextSeg>[];
    var i = 0;
    while (i < input.length) {
      final open = input.indexOf('<think>', i);
      if (open < 0) {
        segs.add(_TextSeg(input.substring(i), false, true));
        break;
      }
      if (open > i) segs.add(_TextSeg(input.substring(i, open), false, true));
      final close = input.indexOf('</think>', open + 7);
      if (close < 0) {
        segs.add(_TextSeg(input.substring(open + 7), true, false));
        break;
      }
      segs.add(_TextSeg(input.substring(open + 7, close), true, true));
      i = close + 8;
    }
    return segs.isEmpty ? [_TextSeg('', false, true)] : segs;
  }

  Widget _buildToolCard(AgentEvent e, int index) {
    final expanded = _expandedSteps.contains(index);
    final hasDetail = e.detail.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE6E8EC)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: hasDetail
                  ? () => setState(
                      () => expanded
                          ? _expandedSteps.remove(index)
                          : _expandedSteps.add(index),
                    )
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Icon(
                      _toolIcon(e.tool),
                      size: 15,
                      color: const Color(0xFF0D9488),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        e.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF374151),
                          fontFamily: 'Consolas',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _stepStatusIcon(e.status),
                    if (hasDetail)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(
                          expanded ? Icons.expand_less : Icons.expand_more,
                          size: 16,
                          color: const Color(0xFFAEAEB6),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (expanded && hasDetail)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F2F5),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFE6E8EC)),
                ),
                child: SelectableText(
                  e.detail.length > 6000
                      ? '${e.detail.substring(0, 6000)}\n…（输出过长已截断）'
                      : e.detail,
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    fontFamily: 'Consolas',
                    color: Color(0xFF4B5563),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _stepStatusIcon(StepStatus s) {
    switch (s) {
      case StepStatus.running:
        return const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            color: Color(0xFF0D9488),
          ),
        );
      case StepStatus.done:
        return const Icon(
          Icons.check_circle,
          size: 14,
          color: Color(0xFF16A34A),
        );
      case StepStatus.error:
        return const Icon(
          Icons.error_outline,
          size: 14,
          color: Color(0xFFDC2626),
        );
    }
  }

  IconData _toolIcon(String tool) => switch (tool) {
    'read_file' => Icons.description_outlined,
    'write_file' => Icons.note_add_outlined,
    'edit_file' => Icons.edit_outlined,
    'bash' => Icons.terminal,
    'glob' => Icons.folder_open_outlined,
    'grep' => Icons.search,
    'tool_search' => Icons.travel_explore,
    'task' => Icons.account_tree_outlined,
    'skill' => Icons.auto_awesome,
    'update_working_checkpoint' => Icons.push_pin_outlined,
    _ => Icons.build_outlined,
  };

  /// 快速添加「我的笔记」。
  Widget _buildMyNoteComposer(StandardNote note) {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Icon(Icons.edit_note, size: 18, color: Color(0xFF9B9B9F)),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _myNoteController,
              minLines: 1,
              maxLines: 4,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(
                hintText: '添加我的笔记…',
                hintStyle: TextStyle(color: Color(0xFFA8A8AC), fontSize: 13),
                isDense: true,
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _appendMyNote(note),
            ),
          ),
          IconButton(
            tooltip: '保存到「我的笔记」',
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.check_circle_outline,
              size: 20,
              color: Color(0xFF0D9488),
            ),
            onPressed: () => _appendMyNote(note),
          ),
        ],
      ),
    );
  }

  Future<void> _appendMyNote(StandardNote note) async {
    final text = _myNoteController.text.trim();
    if (text.isEmpty) return;
    final now = DateTime.now();
    final stamp =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final entry = '- **$stamp** $text';

    var body = note.body;
    final heading = RegExp(r'^## 我的笔记\s*$', multiLine: true);
    final m = heading.firstMatch(body);
    if (m == null) {
      body = '${body.trimRight()}\n\n## 我的笔记\n\n$entry\n';
    } else {
      final nextHeading = RegExp(
        r'^## ',
        multiLine: true,
      ).allMatches(body).where((x) => x.start > m.end).toList();
      final insertAt = nextHeading.isEmpty
          ? body.length
          : nextHeading.first.start;
      final before = body.substring(0, insertAt).trimRight();
      final after = body.substring(insertAt);
      body = '$before\n\n$entry\n\n$after'.trimRight();
    }
    await widget.library.saveBody(note, body);
    _myNoteController.clear();
    _toast('已添加到「我的笔记」');
  }

  /// 反向链接：引用了当前标准的其他笔记。默认收起，只显示前几条。
  Widget _buildBacklinks(StandardNote note) {
    final backlinks = GraphBuilder.backlinks(widget.library.notes, note);
    if (backlinks.isEmpty) return const SizedBox.shrink();
    const collapsedCount = 3;
    final collapsed = !_backlinksExpanded && backlinks.length > collapsedCount;
    final visible = collapsed
        ? backlinks.take(collapsedCount).toList()
        : backlinks;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '反向链接 · ${backlinks.length} 篇笔记引用了本标准',
            style: const TextStyle(fontSize: 12, color: Color(0xFF9B9B9F)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final b in visible)
                ActionChip(
                  label: Text(
                    b.standardNo.isEmpty
                        ? b.fullTitle
                        : '${b.standardNo} ${b.fullTitle}',
                    style: const TextStyle(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _select(b),
                ),
              if (backlinks.length > collapsedCount)
                ActionChip(
                  label: Text(
                    collapsed ? '展开全部 (${backlinks.length})' : '收起',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF0D9488),
                    ),
                  ),
                  side: const BorderSide(color: Color(0xFFB9E8E0)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      setState(() => _backlinksExpanded = !_backlinksExpanded),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 知识库首次进入引导：确认本地路径并一键初始化目录结构。
class _VaultInitView extends StatefulWidget {
  const _VaultInitView({required this.library});

  final LibraryService library;

  @override
  State<_VaultInitView> createState() => _VaultInitViewState();
}

class _VaultInitViewState extends State<_VaultInitView> {
  late final TextEditingController _pathCtrl = TextEditingController(
    text: widget.library.settings.vaultPath,
  );
  bool _busy = false;

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDir() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择知识库所在的文件夹');
    if (dir != null) setState(() => _pathCtrl.text = dir);
  }

  Future<void> _initialize() async {
    final path = _pathCtrl.text.trim();
    if (path.isEmpty) return;
    setState(() => _busy = true);
    await widget.library.settings.update(vaultPath: path);
    await widget.library.initialize();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.auto_stories_outlined,
                size: 48,
                color: Color(0xFF0D9488),
              ),
              const SizedBox(height: 16),
              const Text(
                '初始化知识库',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '当前知识库还没有建立。请确认下面的本地文件夹路径，'
                '点击「初始化」后将在该位置创建标准笔记与文件库目录。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: Color(0xFF6B6B70),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                '知识库路径',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pathCtrl,
                      enabled: !_busy,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickDir,
                    icon: const Icon(Icons.folder_open_outlined, size: 16),
                    label: const Text('浏览'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _initialize,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0D9488),
                  ),
                  icon: _busy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.check_circle_outline, size: 18),
                  label: Text(_busy ? '正在初始化…' : '初始化知识库'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「无原文」标识。
class _NoOriginalTag extends StatelessWidget {
  const _NoOriginalTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '无原文',
        style: TextStyle(fontSize: 10.5, color: Color(0xFFB45309)),
      ),
    );
  }
}

/// 研究归属标识：标明该笔记属于哪个主题研究。
class _ResearchTag extends StatelessWidget {
  const _ResearchTag(this.research);

  final String research;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FBF9),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFB9E8E0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.travel_explore, size: 12, color: Color(0xFF0D9488)),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              '研究：$research',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF0D7A70)),
            ),
          ),
        ],
      ),
    );
  }
}
