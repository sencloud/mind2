import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import 'agent/model_client.dart';
import 'settings_service.dart';

class LibraryService extends ChangeNotifier {
  LibraryService(this.settings);

  final SettingsService settings;

  List<StandardNote> notes = [];
  bool loading = false;
  String? error;

  /// 知识库尚未初始化：配置的笔记目录不存在，需要用户确认路径并初始化。
  bool notInitialized = false;

  final Set<String> _generating = {};
  final Set<String> _generatingPpt = {};
  bool batchRunning = false;
  int batchDone = 0;
  int batchTotal = 0;

  bool isGenerating(StandardNote note) => _generating.contains(note.filePath);
  bool isGeneratingPpt(StandardNote note) =>
      _generatingPpt.contains(note.filePath);

  String get notesDir => p.join(settings.vaultPath, '2-标准笔记');

  List<String> get categories {
    final set = <String>{};
    for (final n in notes) {
      set.add(n.category);
    }
    final list = set.toList()..sort();
    return list;
  }

  Future<void> reload() async {
    loading = true;
    error = null;
    notInitialized = false;
    notifyListeners();

    final result = <StandardNote>[];
    Object? lastParseError;
    try {
      final dir = Directory(notesDir);
      if (!await dir.exists()) {
        notInitialized = true;
      } else {
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File && entity.path.toLowerCase().endsWith('.md')) {
            try {
              result.add(_parse(entity));
            } catch (e) {
              lastParseError = e;
            }
          }
        }
        if (result.isEmpty && lastParseError != null) {
          error = '笔记解析失败：$lastParseError';
        }
      }
    } catch (e) {
      error = '扫描失败：$e';
    }

    result.sort((a, b) {
      final c = a.category.compareTo(b.category);
      return c != 0 ? c : a.fileName.compareTo(b.fileName);
    });
    notes = result;
    loading = false;
    notifyListeners();
  }

  /// 首次进入时初始化知识库：在配置的路径下创建标准笔记目录与文件库目录，
  /// 完成后重新扫描。
  Future<void> initialize() async {
    await Directory(notesDir).create(recursive: true);
    await Directory(
      p.join(settings.vaultPath, '3-文件库'),
    ).create(recursive: true);
    await reload();
  }

  static final _attachmentRe = RegExp(
    r'\[\[([^\]\|]+\.(?:pdf|docx?|xlsx?|html?))(?:\|[^\]]*)?\]\]',
    caseSensitive: false,
  );

  StandardNote _parse(File file) {
    final raw = file.readAsStringSync();
    var frontmatterRaw = '';
    var body = raw;
    final meta = <String, String>{};
    final tags = <String>[];

    if (raw.startsWith('---')) {
      final end = raw.indexOf('\n---', 3);
      if (end > 0) {
        final closeEnd = raw.indexOf('\n', end + 1);
        frontmatterRaw = raw.substring(0, closeEnd < 0 ? raw.length : closeEnd);
        body = closeEnd < 0 ? '' : raw.substring(closeEnd + 1);

        String? currentListKey;
        for (final line in frontmatterRaw.split('\n')) {
          final trimmed = line.trim();
          if (trimmed == '---' || trimmed.isEmpty) continue;
          if (line.startsWith('  - ') || line.startsWith('- ')) {
            if (currentListKey == 'tags') tags.add(trimmed.substring(2).trim());
            continue;
          }
          final idx = line.indexOf(':');
          if (idx <= 0) continue;
          final key = line.substring(0, idx).trim();
          var value = line.substring(idx + 1).trim();
          if (value.isEmpty) {
            currentListKey = key;
            continue;
          }
          currentListKey = null;
          if (value.length >= 2 &&
              value.startsWith('"') &&
              value.endsWith('"')) {
            value = value.substring(1, value.length - 1);
          }
          meta[key] = value;
        }
      }
    }

    final fileName = p.basename(file.path).replaceAll(RegExp(r'\.md$'), '');
    final category = meta['类别'] ?? p.basename(file.parent.path);
    final attachment = _attachmentRe.firstMatch(body)?.group(1);

    return StandardNote(
      filePath: file.path,
      fileName: fileName,
      frontmatterRaw: frontmatterRaw,
      standardNo: meta['标准号'] ?? '',
      fullTitle: meta['题名'] ?? fileName,
      category: category,
      year: meta['年份'] ?? '',
      status: meta['状态'] ?? '未读',
      tags: tags,
      body: body,
      attachmentRelPath: attachment,
      modified: file.statSync().modified,
      research: meta['研究'] ?? '',
    );
  }

  Future<void> setStatus(StandardNote note, String status) async {
    final file = File(note.filePath);
    final raw = await file.readAsString();
    String updated;
    if (RegExp(r'^状态:.*$', multiLine: true).hasMatch(raw)) {
      updated = raw.replaceFirst(
        RegExp(r'^状态:.*$', multiLine: true),
        '状态: $status',
      );
    } else if (raw.startsWith('---')) {
      updated = raw.replaceFirst('---\n', '---\n状态: $status\n');
    } else {
      updated = '---\n状态: $status\n---\n$raw';
    }
    await file.writeAsString(updated);
    note.status = status;
    note.frontmatterRaw = note.frontmatterRaw.replaceFirst(
      RegExp(r'^状态:.*$', multiLine: true),
      '状态: $status',
    );
    notifyListeners();
  }

  Future<void> saveBody(StandardNote note, String newBody) async {
    final file = File(note.filePath);
    final content = note.frontmatterRaw.isEmpty
        ? newBody
        : '${note.frontmatterRaw}\n$newBody';
    await file.writeAsString(content);
    note.body = newBody;
    note.modified = DateTime.now();
    notifyListeners();
  }

  String? resolveAttachment(StandardNote note) {
    final rel = note.attachmentRelPath;
    if (rel == null) return null;
    return p.joinAll([settings.vaultPath, ...rel.split(RegExp(r'[\\/]'))]);
  }

  /// 判断笔记正文是否为空模板（各小节标题下没有内容）。
  bool needsGeneration(StandardNote note) {
    var rest = note.body
        .replaceAll(_attachmentRe, '')
        .replaceAll(RegExp(r'^#{1,6}\s.*$', multiLine: true), '')
        .replaceAll(RegExp(r'\[\[[^\]]*\]\]'), '');
    return rest.trim().isEmpty;
  }

  Future<void> generateNote(StandardNote note) async {
    if (isGenerating(note)) return;
    _generating.add(note.filePath);
    notifyListeners();
    try {
      final generated = await _requestGeneration(note);
      final newBody = _mergeGenerated(note.body, generated);
      await saveBody(note, newBody);
    } finally {
      _generating.remove(note.filePath);
      notifyListeners();
    }
  }

  Future<String> generateResearchPpt(StandardNote note) async {
    if (!note.isResearchReport) {
      throw Exception('只有主题研究报告可以生成 PPT');
    }
    if (isGeneratingPpt(note)) {
      throw Exception('PPT 正在生成中');
    }
    _generatingPpt.add(note.filePath);
    notifyListeners();
    try {
      return await _requestPpt(note);
    } finally {
      _generatingPpt.remove(note.filePath);
      notifyListeners();
    }
  }

  Future<String> exportResearchPdf(StandardNote note) async {
    if (!note.isResearchReport) {
      throw Exception('只有主题研究报告可以导出 PDF');
    }
    final html = _resolveResearchHtml(note);
    if (html == null || !await html.exists()) {
      throw Exception('未找到主题研究 HTML 报告，请先重新生成主题研究报告');
    }
    final outDir = Directory(p.join(settings.vaultPath, '3-文件库', '文档'));
    await outDir.create(recursive: true);
    final out = File(
      _uniquePath(p.join(outDir.path, '${_safeFileName(note.fullTitle)}.pdf')),
    );
    await _printHtmlToPdf(html, out);
    return p.relative(out.path, from: settings.vaultPath);
  }

  /// 依次为所有空白笔记生成内容，返回失败数量。
  Future<int> generateAllEmpty() async {
    if (batchRunning) return 0;
    final targets = notes.where(needsGeneration).toList();
    batchRunning = true;
    batchDone = 0;
    batchTotal = targets.length;
    notifyListeners();
    var failed = 0;
    try {
      for (final note in targets) {
        try {
          await generateNote(note);
        } catch (_) {
          failed++;
        }
        batchDone++;
        notifyListeners();
      }
    } finally {
      batchRunning = false;
      notifyListeners();
    }
    return failed;
  }

  Future<String> _requestGeneration(StandardNote note) async {
    final catalog = StringBuffer();
    for (final n in notes) {
      if (n.filePath == note.filePath) continue;
      final no = n.standardNo.isEmpty ? '' : '${n.standardNo} ';
      catalog.writeln('- $no${n.fullTitle}');
    }
    final title = note.standardNo.isEmpty
        ? '《${note.fullTitle}》'
        : '${note.standardNo}《${note.fullTitle}》';
    final prompt = StringBuffer()
      ..writeln(
        '请为文件 $title（类别：${note.category}'
        '${note.year.isEmpty ? '' : '，${note.year} 年发布'}）撰写一份学习笔记。',
      )
      ..writeln()
      ..writeln('严格按以下 Markdown 结构输出，不要输出任何其他内容（不要代码块包裹、不要标题以外的章节）：')
      ..writeln()
      ..writeln('## 适用范围')
      ..writeln()
      ..writeln(
        '（2-4 句话说明该文件规定/阐述了什么、适用于哪些对象和场景；'
        '若不是标准类文件，则说明其定位与适用对象）',
      )
      ..writeln()
      ..writeln('## 核心要点')
      ..writeln()
      ..writeln('（用带层级的无序列表归纳 5-10 条最重要的规定、要求或观点，引用概念要准确）')
      ..writeln()
      ..writeln('## 相关标准')
      ..writeln()
      ..writeln(
        '（列出 3-6 个与之关系最密切的标准或权威文件，给出编号和名称，并用一句话说明关联。'
        '优先从下面的知识库目录中选择）',
      )
      ..writeln()
      ..writeln('知识库目录：')
      ..write(catalog);

    var content =
        (await ModelClient(settings, role: ModelRole.writing).complete(
      messages: [
        {
          'role': 'system',
          'content':
              '你是一名资深的跨领域文献研究专家，熟悉中国的标准体系、政策文件与行业报告。'
              '回答必须基于你对该文件的真实了解，准确、专业、面向学习场景；'
              '若对个别细节不确定，宁可概括也不要编造具体条款号。始终用中文。',
        },
        {'role': 'user', 'content': prompt.toString()},
      ],
    ))
            .trim();
    if (content.isEmpty) throw Exception('模型未返回内容');
    content = content
        .replaceFirst(RegExp(r'^```(?:markdown)?\s*'), '')
        .replaceFirst(RegExp(r'\s*```$'), '')
        .trim();
    return content;
  }

  Future<String> _requestPpt(StandardNote note) async {
    final related =
        notes
            .where(
              (n) =>
                  n.filePath != note.filePath &&
                  note.research.isNotEmpty &&
                  n.research == note.research,
            )
            .toList()
          ..sort((a, b) => a.fullTitle.compareTo(b.fullTitle));
    final refs = StringBuffer();
    for (final n in related.take(12)) {
      refs
        ..writeln('### ${n.fullTitle}')
        ..writeln(
          '类别：${n.category}；来源：${n.frontmatterRaw.contains('来源:') ? _metaLine(n.frontmatterRaw, '来源') : '未知'}',
        )
        ..writeln(_clipForPrompt(n.body, 1200))
        ..writeln();
    }
    final prompt =
        '''
你正在使用 GitHub 上的 AgentSkill：html-ppt-skill（lewislulu/html-ppt-skill）的规则来制作静态 HTML PPT。
目标：把下面的主题研究报告转成一份专业、可直接演示的 HTML deck。

必须遵守：
1. 只输出完整 HTML 文件源码，不要 Markdown 代码块，不要解释文字。
2. 单文件自包含：CSS 和 JS 都写在 HTML 内，不依赖本地外部文件；可以使用系统字体。
3. 参考 html-ppt-skill 的 authoring rules：一页一个 .slide；使用 token 化 CSS 变量；支持键盘 ←/→/Space 翻页；支持进度条；每页包含隐藏的 .notes 演讲提示。
4. 风格使用 academic-paper / corporate-clean / editorial-serif 的融合：正式、克制、适合研究报告汇报。
5. 页数 8-12 页，结构建议：封面、研究问题、关键结论、方法/来源、核心发现、方案/框架、风险与局限、行动建议、参考来源、结束页。
6. 幻灯片上只放给观众看的内容；演讲提示必须放进 <aside class="notes">。
7. 不要编造报告之外的事实；若资料不足，表达为“待进一步验证”。

研究标题：${note.fullTitle}
研究分类：${note.category}
研究主题：${note.research}

研究报告正文：
${_clipForPrompt(note.body, 18000)}

关联参考资料摘要：
${refs.isEmpty ? '（无）' : refs.toString()}
''';
    var content =
        (await ModelClient(settings, role: ModelRole.writing).complete(
      messages: [
        {
          'role': 'system',
          'content':
              '你是资深信息架构师和演示文稿设计师。'
              '你熟悉 html-ppt-skill 的静态 HTML deck 规范，输出必须是可直接保存打开的完整 HTML。',
        },
        {'role': 'user', 'content': prompt},
      ],
    ))
            .trim();
    content = content
        .replaceFirst(RegExp(r'^```(?:html)?\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'\s*```$'), '')
        .trim();
    final lower = content.toLowerCase();
    if (!lower.contains('<html') || !lower.contains('</html>')) {
      throw Exception('模型未返回有效 HTML');
    }
    return content;
  }

  static String _clipForPrompt(String text, int maxLen) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= maxLen) return clean;
    return '${clean.substring(0, maxLen)}…';
  }

  static String _metaLine(String frontmatter, String key) {
    final match = RegExp(
      '^$key:\\s*(.+)\$',
      multiLine: true,
    ).firstMatch(frontmatter);
    return match?.group(1)?.replaceAll('"', '').trim() ?? '未知';
  }

  File? _resolveResearchHtml(StandardNote note) {
    String clean(String value) => value.replaceAll('"', '').trim();
    final report = RegExp(
      r'^报告:\s*(.+)$',
      multiLine: true,
    ).firstMatch(note.frontmatterRaw)?.group(1);
    final rel = report == null || clean(report).isEmpty
        ? _attachmentRe
              .allMatches(note.body)
              .map((m) => m.group(1) ?? '')
              .firstWhere(
                (v) =>
                    v.toLowerCase().endsWith('.html') ||
                    v.toLowerCase().endsWith('.htm'),
                orElse: () => '',
              )
        : clean(report);
    if (rel.isEmpty) return null;
    return File(
      p.joinAll([settings.vaultPath, ...rel.split(RegExp(r'[\\/]'))]),
    );
  }

  static const _browserCandidates = [
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
  ];

  static String? _browserPath() {
    if (!Platform.isWindows) return null;
    for (final path in _browserCandidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  static Future<void> _printHtmlToPdf(File html, File out) async {
    final browser = _browserPath();
    if (browser == null) throw Exception('未找到 Edge 或 Chrome，无法导出 PDF');
    final tmp = await Directory.systemTemp.createTemp('mind_research_pdf_');
    try {
      final result = await Process.run(
        browser,
        [
          '--headless=new',
          '--disable-gpu',
          '--no-sandbox',
          '--user-data-dir=${tmp.path}',
          '--print-to-pdf=${out.path}',
          '--print-to-pdf-no-header',
          '--no-pdf-header-footer',
          html.uri.toString(),
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 60));
      if (result.exitCode != 0 || !await out.exists()) {
        throw Exception(
          'PDF 导出失败：${(result.stderr as String?)?.trim() ?? result.exitCode}',
        );
      }
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  static String _uniquePath(String path) {
    if (!File(path).existsSync()) return path;
    final dir = p.dirname(path);
    final base = p.basenameWithoutExtension(path);
    final ext = p.extension(path);
    var i = 1;
    while (true) {
      final candidate = p.join(dir, '$base ($i)$ext');
      if (!File(candidate).existsSync()) return candidate;
      i++;
    }
  }

  static String _safeFileName(String value) {
    var out = value.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    if (out.length > 80) out = out.substring(0, 80).trim();
    return out.isEmpty ? '主题研究报告' : out;
  }

  /// 为文件库中尚未建立笔记的文档创建标准笔记：AI 按文件名归入分类，
  /// 笔记带附件链接、正文为空模板（后续由批量生成补全内容）。返回新建数量。
  Future<int> indexLibraryDocuments(List<LibraryFile> docs) async {
    final pending = <LibraryFile>[];
    for (final f in docs) {
      final rel = p
          .relative(f.path, from: settings.vaultPath)
          .replaceAll('\\', '/');
      final title = p.basenameWithoutExtension(f.name).trim();
      final exists = notes.any(
        (n) =>
            n.fullTitle.trim() == title ||
            n.body.contains(rel) ||
            n.attachmentRelPath?.replaceAll('\\', '/') == rel,
      );
      if (!exists) pending.add(f);
    }
    if (pending.isEmpty) return 0;

    var created = 0;
    // 分批让 AI 归类，避免单次提示词过长。
    const batchSize = 40;
    for (var i = 0; i < pending.length; i += batchSize) {
      final end = i + batchSize > pending.length
          ? pending.length
          : i + batchSize;
      final batch = pending.sublist(i, end);
      final mapping = await _classifyTitles(
        batch.map((f) => p.basenameWithoutExtension(f.name).trim()).toList(),
      );
      for (final f in batch) {
        final title = p.basenameWithoutExtension(f.name).trim();
        final category = mapping[title];
        if (category == null || category.isEmpty) continue;
        await _writeFileNote(f, title, category);
        created++;
      }
    }
    if (created > 0) await reload();
    return created;
  }

  Future<Map<String, String>> _classifyTitles(List<String> titles) async {
    final existing = categories;
    final prompt =
        '''
下面是知识库文件库中的文档文件名（每行一个）：
${titles.map((t) => '- $t').join('\n')}

知识库已有分类：${existing.isEmpty ? '（暂无）' : existing.join('、')}

请为每份文档指定一个分类：优先从已有分类中选择语义匹配的；确实没有合适的才给出一个简短的新分类名（2-6 个字的主题词，不要用“其他”“未分类”这类含糊名称）。
严格输出 JSON，不要输出其他文字，键为文档文件名（原样保留）、值为分类名：
{"文件名A":"分类","文件名B":"分类"}
''';
    final content = await _chatRaw([
      {'role': 'system', 'content': '你是知识管理专家，只输出 JSON。'},
      {'role': 'user', 'content': prompt},
    ], jsonMode: true);
    final start = content.indexOf('{');
    final end = content.lastIndexOf('}');
    if (start < 0 || end <= start) throw Exception('模型未返回有效的分类结果');
    final parsed = jsonDecode(content.substring(start, end + 1)) as Map;
    final out = <String, String>{};
    parsed.forEach((k, v) {
      out[k.toString().trim()] = v.toString().trim();
    });
    return out;
  }

  Future<void> _writeFileNote(
    LibraryFile f,
    String title,
    String category,
  ) async {
    final cat = _safeFileName(category);
    final dir = Directory(p.join(notesDir, cat));
    await dir.create(recursive: true);
    final rel = p
        .relative(f.path, from: settings.vaultPath)
        .replaceAll('\\', '/');
    final content =
        '''
---
题名: "${title.replaceAll('"', '')}"
类别: $cat
来源: 文件库
状态: 未读
tags:
  - $cat
---

## 原文

[[$rel|打开原文]]

## 适用范围

## 核心要点

## 相关标准

## 我的笔记
''';
    final file = File(
      _uniquePath(p.join(dir.path, '${_safeFileName(title)}.md')),
    );
    await file.writeAsString(content);
  }

  /// 合并相同主题的分类：用 AI 将语义相同的分类归并到一个规范名下，
  /// 把对应笔记文件移动到规范分类目录并改写 frontmatter。返回移动的笔记数。
  Future<int> consolidateCategories() async {
    final cats = categories;
    if (cats.length < 2) return 0;
    final mapping = await _clusterCategories(cats);
    if (mapping.isEmpty) return 0;
    var moved = 0;
    for (final n in List.of(notes)) {
      final canon = mapping[n.category];
      if (canon == null || canon.isEmpty || canon == n.category) continue;
      if (await _moveNoteToCategory(n, canon)) moved++;
    }
    return moved;
  }

  Future<Map<String, String>> _clusterCategories(List<String> cats) async {
    final prompt =
        '''
下面是知识库中已有的分类名（每行一个）：
${cats.map((c) => '- $c').join('\n')}

请把**语义上属于同一主题领域**的分类归并为一组，并为每组选一个最合适的规范分类名（必须从该组已有名字中挑一个，不要新造名字）。
注意：只合并确实是同一主题的（例如“书页图像矫正”和“书页弯曲矫正”应合并）；明显不同主题（如“国家标准”与“书页矫正”）绝不能合并。
严格输出 JSON，不要输出其他文字，键为原分类名、值为其规范分类名：
{"原分类A":"规范名","原分类B":"规范名"}
''';
    try {
      final content = await _chatRaw([
        {'role': 'system', 'content': '你是知识管理专家，只输出 JSON。'},
        {'role': 'user', 'content': prompt},
      ], jsonMode: true);
      final start = content.indexOf('{');
      final end = content.lastIndexOf('}');
      if (start < 0 || end <= start) return {};
      final parsed = jsonDecode(content.substring(start, end + 1)) as Map;
      final out = <String, String>{};
      parsed.forEach((k, v) {
        final from = k.toString();
        final to = v.toString().trim();
        // 规范名必须是已有分类，避免 AI 造新词导致错误归并。
        if (cats.contains(from) && cats.contains(to)) out[from] = to;
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<bool> _moveNoteToCategory(StandardNote note, String canon) async {
    try {
      final src = File(note.filePath);
      if (!await src.exists()) return false;
      var raw = await src.readAsString();
      if (RegExp(r'^类别:.*$', multiLine: true).hasMatch(raw)) {
        raw = raw.replaceFirst(
          RegExp(r'^类别:.*$', multiLine: true),
          '类别: $canon',
        );
      } else if (raw.startsWith('---')) {
        raw = raw.replaceFirst('---\n', '---\n类别: $canon\n');
      }
      final destDir = Directory(p.join(notesDir, canon));
      await destDir.create(recursive: true);
      var dest = p.join(destDir.path, '${note.fileName}.md');
      if (dest != note.filePath && File(dest).existsSync()) {
        var i = 1;
        while (File(
          p.join(destDir.path, '${note.fileName} ($i).md'),
        ).existsSync()) {
          i++;
        }
        dest = p.join(destDir.path, '${note.fileName} ($i).md');
      }
      await File(dest).writeAsString(raw);
      if (dest != note.filePath) await src.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 去重：同一分类下题名相同的笔记只保留正文最充实的一篇，其余删除。返回删除数。
  Future<int> dedupNotes() async {
    final groups = <String, List<StandardNote>>{};
    for (final n in notes) {
      final key = '${n.category}\u0000${n.fullTitle.trim().toLowerCase()}';
      groups.putIfAbsent(key, () => []).add(n);
    }
    var removed = 0;
    for (final group in groups.values) {
      if (group.length < 2) continue;
      group.sort(
        (a, b) => b.body.trim().length.compareTo(a.body.trim().length),
      );
      for (final dup in group.skip(1)) {
        try {
          final f = File(dup.filePath);
          if (await f.exists()) {
            await f.delete();
            removed++;
          }
        } catch (_) {}
      }
    }
    return removed;
  }

  Future<String> _chatRaw(
    List<Map<String, String>> messages, {
    bool jsonMode = false,
  }) {
    // 分类合并属于廉价小任务，走 small 通道。
    return ModelClient(settings, role: ModelRole.small).complete(
      messages: messages.map((m) => Map<String, dynamic>.from(m)).toList(),
      jsonMode: jsonMode,
      timeout: const Duration(minutes: 2),
    );
  }

  /// 保留原文链接与「我的笔记」内容，替换中间的生成部分。
  String _mergeGenerated(String oldBody, String generated) {
    String sectionOf(String heading) {
      final match = RegExp(
        '^## $heading\\s*\\n([\\s\\S]*?)(?=^## |\\Z)',
        multiLine: true,
      ).firstMatch(oldBody);
      return match?.group(1)?.trim() ?? '';
    }

    final original = sectionOf('原文');
    final myNotes = sectionOf('我的笔记');

    final buffer = StringBuffer();
    if (original.isNotEmpty) {
      buffer
        ..writeln('## 原文')
        ..writeln()
        ..writeln(original)
        ..writeln();
    }
    buffer
      ..writeln(generated)
      ..writeln()
      ..writeln('## 我的笔记');
    if (myNotes.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(myNotes);
    }
    return buffer.toString().trimRight();
  }
}
