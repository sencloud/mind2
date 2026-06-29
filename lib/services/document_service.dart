import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:xml/xml.dart';

import 'settings_service.dart';

class DocumentTemplate {
  const DocumentTemplate({
    required this.id,
    required this.name,
    required this.category,
    required this.description,
    required this.requirements,
  });

  final String id;
  final String name;
  final String category;
  final String description;
  final String requirements;
}

class ReferenceDocument {
  ReferenceDocument({
    required this.name,
    required this.path,
    required this.text,
  });

  final String name;
  final String path;
  final String text;

  Map<String, dynamic> toJson() => {'name': name, 'path': path, 'text': text};

  factory ReferenceDocument.fromJson(Map<String, dynamic> json) =>
      ReferenceDocument(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        text: json['text'] as String? ?? '',
      );
}

enum DocumentExportFormat { word, pdf }

class DocumentDraft {
  DocumentDraft({
    required this.id,
    required this.title,
    required this.topic,
    required this.templateId,
    this.expectedPages = 3,
    this.templateName = '',
    this.templateText = '',
    List<ReferenceDocument>? references,
    this.content = '',
    required this.createdAt,
    required this.updatedAt,
  }) : references = references ?? [];

  final String id;
  String title;
  String topic;
  String templateId;
  int expectedPages;
  String templateName;
  String templateText;
  List<ReferenceDocument> references;
  String content;
  final DateTime createdAt;
  DateTime updatedAt;

  int get words => content.replaceAll(RegExp(r'\s'), '').length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'topic': topic,
    'templateId': templateId,
    'expectedPages': expectedPages,
    'templateName': templateName,
    'templateText': templateText,
    'references': references.map((r) => r.toJson()).toList(),
    'content': content,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory DocumentDraft.fromJson(Map<String, dynamic> json) => DocumentDraft(
    id:
        json['id'] as String? ??
        DateTime.now().microsecondsSinceEpoch.toString(),
    title: json['title'] as String? ?? '未命名文档',
    topic: json['topic'] as String? ?? '',
    templateId: json['templateId'] as String? ?? 'official_notice',
    expectedPages: (json['expectedPages'] as num?)?.toInt() ?? 3,
    templateName: json['templateName'] as String? ?? '',
    templateText: json['templateText'] as String? ?? '',
    references: ((json['references'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => ReferenceDocument.fromJson(e.cast<String, dynamic>()))
        .toList(),
    content: json['content'] as String? ?? '',
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
  );
}

class DocumentService extends ChangeNotifier {
  DocumentService(this.settings);

  final SettingsService settings;

  static const templates = <DocumentTemplate>[
    DocumentTemplate(
      id: 'official_notice',
      name: '通知',
      category: '公文类',
      description: '用于发布、传达要求有关单位办理或周知的事项。',
      requirements:
          '严格按照党政机关公文处理工作条例与 GB/T 9704-2012 党政机关公文格式组织。应包含标题、主送机关、正文、落款、成文日期。标题用“发文机关+事由+文种”或“事由+文种”，正文按缘由、事项、要求展开，语言庄重、准确、简明。',
    ),
    DocumentTemplate(
      id: 'official_request',
      name: '请示',
      category: '公文类',
      description: '用于向上级机关请求指示、批准。',
      requirements:
          '严格按照党政机关公文处理工作条例与 GB/T 9704-2012 党政机关公文格式组织。坚持一文一事，结尾使用“妥否，请批示”等规范表述，正文应写明背景依据、请示事项、理由和具体请求。',
    ),
    DocumentTemplate(
      id: 'official_report',
      name: '报告',
      category: '公文类',
      description: '用于向上级汇报工作、反映情况、回复询问。',
      requirements:
          '严格按照党政机关公文处理工作条例与 GB/T 9704-2012 党政机关公文格式组织。不得夹带请示事项，正文应包括工作背景、主要情况、成效问题、下一步安排。',
    ),
    DocumentTemplate(
      id: 'official_letter',
      name: '函',
      category: '公文类',
      description: '用于不相隶属机关之间商洽工作、询问和答复问题。',
      requirements:
          '严格按照党政机关公文处理工作条例与 GB/T 9704-2012 党政机关公文格式组织。语气平实得体，事项明确，结尾可使用“特此函达”“盼复”等规范表述。',
    ),
    DocumentTemplate(
      id: 'official_minutes',
      name: '会议纪要',
      category: '公文类',
      description: '用于记载会议主要情况和议定事项。',
      requirements:
          '按照纪要类公文规范编写，突出会议时间、地点、主持人、参会范围、议题、议定事项和责任分工。表述应客观、简明，不写流水账。',
    ),
    DocumentTemplate(
      id: 'prd',
      name: '产品需求文档 PRD',
      category: '需求类',
      description: '用于产品功能设计、研发评审和交付验收。',
      requirements:
          '按主流 PRD 结构编写：背景目标、用户角色、业务流程、功能范围、详细需求、交互说明、数据规则、权限规则、非功能需求、验收标准、风险与依赖。',
    ),
    DocumentTemplate(
      id: 'tech_requirement',
      name: '技术需求说明书',
      category: '需求类',
      description: '用于描述系统建设或技术改造的功能与技术要求。',
      requirements:
          '按技术需求文档结构编写：建设背景、总体目标、业务范围、功能需求、接口需求、数据需求、性能安全要求、部署运维要求、验收指标。',
    ),
    DocumentTemplate(
      id: 'project_proposal',
      name: '项目申报书',
      category: '申报书类',
      description: '用于项目立项、专项资金、课题或平台建设申报。',
      requirements:
          '按申报书主流结构编写：项目名称、申报单位、建设背景、必要性可行性、建设目标、主要内容、技术路线、实施计划、经费概算、预期成果、风险控制。',
    ),
    DocumentTemplate(
      id: 'research_application',
      name: '课题申报书',
      category: '申报书类',
      description: '用于科研课题、软科学研究、规划研究等申报。',
      requirements:
          '按课题申报书结构编写：研究背景与意义、国内外现状、研究目标、研究内容、重点难点、创新点、研究方法、进度安排、成果形式、团队基础。',
    ),
    DocumentTemplate(
      id: 'feasibility',
      name: '可行性研究报告',
      category: '申报书类',
      description: '用于项目论证、投资决策和立项评审。',
      requirements: '按可研报告结构编写：项目概况、建设必要性、需求分析、建设方案、技术方案、投资估算、效益分析、风险分析、结论建议。',
    ),
    DocumentTemplate(
      id: 'work_summary',
      name: '工作总结',
      category: '通用类',
      description: '用于阶段性复盘、年度总结、专项工作汇报。',
      requirements: '按总结类文档结构编写：基本情况、主要做法、成效亮点、问题不足、经验启示、下一步计划。语言务实，避免空泛口号。',
    ),
    DocumentTemplate(
      id: 'system_policy',
      name: '制度办法',
      category: '制度类',
      description: '用于内部管理制度、办法、细则、流程规范。',
      requirements: '按制度文件结构编写：总则、职责分工、管理要求、流程规范、监督检查、附则。条款清晰，权责明确，避免含糊表述。',
    ),
  ];

  final List<DocumentDraft> documents = [];
  DocumentDraft? current;
  bool busy = false;
  String stage = '';

  File? _store;
  http.Client? _client;

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _store = File(p.join(dir.path, 'documents.json'));
    if (await _store!.exists()) {
      try {
        final data = jsonDecode(await _store!.readAsString());
        if (data is List) {
          documents
            ..clear()
            ..addAll(
              data.whereType<Map>().map(
                (e) => DocumentDraft.fromJson(e.cast<String, dynamic>()),
              ),
            );
        }
      } catch (_) {
        documents.clear();
      }
    }
  }

  DocumentTemplate templateOf(String id) =>
      templates.firstWhere((t) => t.id == id, orElse: () => templates.first);

  Future<DocumentDraft> create({
    required String title,
    required String topic,
    required String templateId,
    int expectedPages = 3,
  }) async {
    final template = templateOf(templateId);
    final now = DateTime.now();
    final draft = DocumentDraft(
      id: now.microsecondsSinceEpoch.toString(),
      title: title.trim().isEmpty ? topic.trim() : title.trim(),
      topic: topic.trim(),
      templateId: template.id,
      expectedPages: expectedPages < 1 ? 1 : expectedPages,
      templateName: template.name,
      createdAt: now,
      updatedAt: now,
    );
    documents.insert(0, draft);
    current = draft;
    notifyListeners();
    await _persist();
    return draft;
  }

  void open(DocumentDraft draft) {
    current = draft;
    notifyListeners();
  }

  void close() {
    current = null;
    notifyListeners();
  }

  Future<void> delete(DocumentDraft draft) async {
    documents.removeWhere((d) => d.id == draft.id);
    if (current?.id == draft.id) current = null;
    notifyListeners();
    await _persist();
  }

  Future<void> save() async {
    current?.updatedAt = DateTime.now();
    await _persist();
    notifyListeners();
  }

  Future<void> importDocxTemplate(String path) async {
    final draft = current;
    if (draft == null) throw StateError('未打开文档');
    final file = File(path);
    if (!await file.exists()) throw Exception('模板文件不存在：$path');
    final text = await _readDocxText(file);
    if (text.trim().isEmpty) throw Exception('未从 docx 模板中解析到正文内容');
    draft.templateName = p.basename(path);
    draft.templateText = text;
    draft.updatedAt = DateTime.now();
    notifyListeners();
    await _persist();
  }

  Future<void> importReferenceDocuments(List<String> paths) async {
    final draft = current;
    if (draft == null) throw StateError('未打开文档');
    final imported = <ReferenceDocument>[];
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) throw Exception('参考文档不存在：$path');
      final text = await _readReferenceText(file);
      if (text.trim().isEmpty) throw Exception('未从参考文档中解析到正文内容：$path');
      imported.add(
        ReferenceDocument(name: p.basename(path), path: path, text: text),
      );
    }
    if (imported.isEmpty) return;
    for (final ref in imported) {
      draft.references.removeWhere((r) => r.path == ref.path);
      draft.references.add(ref);
    }
    draft.updatedAt = DateTime.now();
    notifyListeners();
    await _persist();
  }

  Future<void> removeReference(String path) async {
    final draft = current;
    if (draft == null) return;
    draft.references.removeWhere((r) => r.path == path);
    draft.updatedAt = DateTime.now();
    notifyListeners();
    await _persist();
  }

  Future<List<File>> exportCurrent({
    required String outputDir,
    required Set<DocumentExportFormat> formats,
    required bool htmlPipeline,
  }) async {
    final draft = current;
    if (draft == null) throw StateError('未打开文档');
    if (draft.content.trim().isEmpty) throw Exception('正文为空，请先生成文档');
    if (formats.isEmpty) throw Exception('请选择导出格式');
    final dir = Directory(outputDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    busy = true;
    stage = '正在导出文档…';
    notifyListeners();
    try {
      final base = _safeFileName(
        draft.title.trim().isEmpty ? '未命名文档' : draft.title,
      );
      final exported = <File>[];
      final html = htmlPipeline
          ? _renderHtmlDocument(draft)
          : _renderPlainHtml(draft);
      final htmlFile = File(p.join(dir.path, '$base.html'));
      if (htmlPipeline) {
        await htmlFile.writeAsString(html, encoding: utf8);
        exported.add(htmlFile);
      } else {
        final tmpDir = await Directory.systemTemp.createTemp(
          'mind_doc_export_',
        );
        try {
          final tmpHtml = File(p.join(tmpDir.path, '$base.html'));
          await tmpHtml.writeAsString(html, encoding: utf8);
          await _exportFormats(
            draft,
            formats,
            dir,
            base,
            tmpHtml,
            html,
            exported,
          );
        } finally {
          try {
            await tmpDir.delete(recursive: true);
          } catch (_) {}
        }
        stage = '导出完成';
        await _openExportDirectory(dir.path);
        return exported;
      }

      await _exportFormats(draft, formats, dir, base, htmlFile, html, exported);
      stage = '导出完成';
      await _openExportDirectory(dir.path);
      return exported;
    } catch (e) {
      stage = '导出失败：$e';
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _exportFormats(
    DocumentDraft draft,
    Set<DocumentExportFormat> formats,
    Directory dir,
    String base,
    File htmlFile,
    String html,
    List<File> exported,
  ) async {
    if (formats.contains(DocumentExportFormat.word)) {
      final word = File(p.join(dir.path, '$base.docx'));
      await _writeStyledDocx(draft, word);
      exported.add(word);
    }
    if (formats.contains(DocumentExportFormat.pdf)) {
      final pdf = File(p.join(dir.path, '$base.pdf'));
      await _printHtmlToPdf(htmlFile, pdf);
      exported.add(pdf);
    }
  }

  Future<void> generate() async {
    final draft = current;
    if (draft == null || busy) return;
    final template = templateOf(draft.templateId);
    busy = true;
    stage = '正在生成文档…';
    notifyListeners();
    try {
      final reply = await _chat([
        {
          'role': 'system',
          'content':
              '你是严谨的中文文档写作专家，熟悉党政机关公文、产品需求、项目申报、制度文件和研究报告写作。只输出文档正文，不解释。',
        },
        {
          'role': 'user',
          'content':
              '''
请根据主题撰写一份完整文档。

文档类型：${template.category} / ${template.name}
主题：${draft.topic}
预计篇幅：约 ${draft.expectedPages} 页

内置写作要求：
${template.requirements}

${draft.templateText.trim().isEmpty ? '' : '用户上传的 docx 模板解析内容如下，请严格参考其结构、栏目、语气和格式层级：\n${_clip(draft.templateText, 12000)}\n'}
${draft.references.isEmpty ? '' : '参考资料如下，请优先依据这些资料进行事实陈述、问题分析、数据口径和论证组织：\n${_formatReferences(draft.references)}\n'}
输出要求：
- 使用中文。
- 使用 Markdown 表达标题层级、条款、表格和列表，方便编辑。
- 公文类必须符合国家公文处理与格式规范的写法，标题、主送机关、正文、落款、日期等要素齐备。
- 篇幅控制在约 ${draft.expectedPages} 页，内容密度与正式文档相匹配。
- 不编造具体单位名称、真实文号、联系人、金额等敏感事实；确需用户补充处用【待补充：...】标注。
- 内容要可直接作为正式初稿继续修改。
''',
        },
      ]);
      draft.content = reply.trim();
      draft.updatedAt = DateTime.now();
      stage = '生成完成';
      await _persist();
    } catch (e) {
      stage = '生成失败：$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<String> _readDocxText(File file) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    final document = archive.findFile('word/document.xml');
    if (document == null) throw Exception('不是有效的 docx 文件：缺少 word/document.xml');
    final xml = XmlDocument.parse(utf8.decode(document.content));
    final paragraphs = <String>[];
    for (final pNode in xml.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'p',
    )) {
      final text = pNode.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 't')
          .map((e) => e.innerText)
          .join()
          .trim();
      if (text.isNotEmpty) paragraphs.add(text);
    }
    return paragraphs.join('\n');
  }

  Future<String> _readReferenceText(File file) async {
    final ext = p.extension(file.path).toLowerCase();
    if (ext == '.docx') return _readDocxText(file);
    if (ext == '.pdf') return _readPdfText(file);
    if (ext == '.xlsx') return _readXlsxText(file);
    if (ext == '.txt' || ext == '.md' || ext == '.markdown') {
      return file.readAsString();
    }
    throw Exception('暂不支持的参考文档格式：$ext');
  }

  Future<String> _readPdfText(File file) async {
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openData(
        await file.readAsBytes(),
      ).timeout(const Duration(seconds: 20));
      final sb = StringBuffer();
      final count = doc.pages.length < 20 ? doc.pages.length : 20;
      for (var i = 0; i < count; i++) {
        final text = await doc.pages[i].loadText();
        final fullText = text?.fullText.trim();
        if (fullText != null && fullText.isNotEmpty) {
          sb
            ..writeln('--- PDF 第 ${i + 1} 页 ---')
            ..writeln(fullText)
            ..writeln();
        }
        if (sb.length >= 30000) break;
      }
      final out = sb.toString().trim();
      return out.length > 30000 ? out.substring(0, 30000) : out;
    } finally {
      await doc?.dispose();
    }
  }

  Future<String> _readXlsxText(File file) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    final sharedStrings = _xlsxSharedStrings(archive);
    final sheets =
        archive.files
            .where(
              (f) => RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name),
            )
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    if (sheets.isEmpty) throw Exception('不是有效的 xlsx 文件：缺少工作表');

    final buf = StringBuffer();
    for (var i = 0; i < sheets.length; i++) {
      final sheet = sheets[i];
      final xml = XmlDocument.parse(utf8.decode(sheet.content));
      buf.writeln('--- Excel 工作表 ${i + 1} ---');
      for (final row in xml.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'row',
      )) {
        final values = <String>[];
        for (final cell in row.children.whereType<XmlElement>().where(
          (e) => e.name.local == 'c',
        )) {
          values.add(_xlsxCellText(cell, sharedStrings));
        }
        final line = values
            .map((v) => v.trim())
            .where((v) => v.isNotEmpty)
            .join('\t');
        if (line.isNotEmpty) buf.writeln(line);
        if (buf.length >= 30000) break;
      }
      buf.writeln();
      if (buf.length >= 30000) break;
    }
    final out = buf.toString().trim();
    return out.length > 30000 ? out.substring(0, 30000) : out;
  }

  List<String> _xlsxSharedStrings(Archive archive) {
    final file = archive.findFile('xl/sharedStrings.xml');
    if (file == null) return const [];
    final xml = XmlDocument.parse(utf8.decode(file.content));
    return xml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'si')
        .map(
          (si) => si.descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == 't')
              .map((e) => e.innerText)
              .join(),
        )
        .toList();
  }

  String _xlsxCellText(XmlElement cell, List<String> sharedStrings) {
    final type = cell.getAttribute('t');
    if (type == 'inlineStr') {
      return cell.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 't')
          .map((e) => e.innerText)
          .join();
    }
    final value = cell.descendants
        .whereType<XmlElement>()
        .firstWhere(
          (e) => e.name.local == 'v',
          orElse: () => XmlElement(XmlName('v')),
        )
        .innerText;
    if (type == 's') {
      final index = int.tryParse(value);
      if (index != null && index >= 0 && index < sharedStrings.length) {
        return sharedStrings[index];
      }
    }
    return value;
  }

  Future<void> _writeStyledDocx(DocumentDraft draft, File out) async {
    final archive = Archive();
    archive.addFile(
      ArchiveFile.string(
        '[Content_Types].xml',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
</Types>''',
      ),
    );
    archive.addFile(
      ArchiveFile.string(
        '_rels/.rels',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''',
      ),
    );
    archive.addFile(
      ArchiveFile.string(
        'word/_rels/document.xml.rels',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>''',
      ),
    );
    archive.addFile(ArchiveFile.string('word/styles.xml', _docxStyles()));
    archive.addFile(
      ArchiveFile.string('word/document.xml', _docxDocumentXml(draft)),
    );
    final bytes = ZipEncoder().encode(archive);
    await out.writeAsBytes(bytes);
  }

  Future<void> _printHtmlToPdf(File html, File out) async {
    final browser = _browserPath();
    if (browser == null) {
      throw Exception('未找到 Edge 或 Chrome，无法导出 PDF');
    }
    final tmp = await Directory.systemTemp.createTemp('mind_doc_pdf_');
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

  Future<void> _openExportDirectory(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [path]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [path]);
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    if (_store == null) return;
    await _store!.writeAsString(
      jsonEncode(documents.map((d) => d.toJson()).toList()),
    );
  }

  Future<String> _chat(List<Map<String, String>> messages) async {
    // 正式文档生成走 writing 角色通道（默认仍是 DeepSeek，可在设置里改）。
    const role = ModelRole.writing;
    final client = _client = http.Client();
    try {
      final resp = await client.post(
        Uri.parse('${settings.roleBaseUrl(role)}/chat/completions'),
        headers: {
          'Authorization': 'Bearer ${settings.roleApiKey(role)}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': settings.roleModel(role),
          'stream': false,
          'messages': messages,
        }),
      );
      if (resp.statusCode != 200) {
        throw Exception(
          'HTTP ${resp.statusCode} ${utf8.decode(resp.bodyBytes)}',
        );
      }
      final json = jsonDecode(utf8.decode(resp.bodyBytes));
      return (json['choices']?[0]?['message']?['content'] as String?) ?? '';
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  static String _clip(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);

  static String _formatReferences(List<ReferenceDocument> refs) {
    final buf = StringBuffer();
    for (var i = 0; i < refs.length; i++) {
      final ref = refs[i];
      buf
        ..writeln('【参考资料 ${i + 1}：${ref.name}】')
        ..writeln(_clip(ref.text, 6000))
        ..writeln();
    }
    return _clip(buf.toString(), 18000);
  }

  static String _renderHtmlDocument(DocumentDraft draft) {
    final body = md.markdownToHtml(
      draft.content,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );
    return _htmlShell(draft.title, body);
  }

  static String _renderPlainHtml(DocumentDraft draft) {
    final body = '<pre>${const HtmlEscape().convert(draft.content)}</pre>';
    return _htmlShell(draft.title, body);
  }

  static String _htmlShell(String title, String body) {
    final safeTitle = const HtmlEscape().convert(title);
    return '''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>$safeTitle</title>
<style>
${_officialHtmlCss()}
</style>
</head>
<body><main class="page"><h1>$safeTitle</h1>$body</main></body>
</html>''';
  }

  static String _officialHtmlCss() => '''
@page { size: A4; margin: 37mm 26mm 35mm 28mm; }
body { font-family: "FangSong"; color: #000; font-size: 16pt; line-height: 28pt; }
.page { width: 156mm; margin: 0 auto; }
h1 { font-family: "SimSun"; text-align: center; font-size: 22pt; font-weight: 700; line-height: 32pt; margin: 0 0 28pt; }
h2 { font-family: "SimHei"; font-size: 16pt; font-weight: 400; line-height: 28pt; margin: 0; }
h3 { font-family: "KaiTi"; font-size: 16pt; font-weight: 700; line-height: 28pt; margin: 0; }
h4, h5, h6 { font-family: "FangSong"; font-size: 16pt; font-weight: 700; line-height: 28pt; margin: 0; }
p { margin: 0; text-indent: 2em; line-height: 28pt; }
ul, ol { margin: 0 0 0 2em; padding: 0; }
li { margin: 0; line-height: 28pt; }
table { width: 100%; border-collapse: collapse; margin: 8pt 0; font-size: 16pt; line-height: 28pt; }
th, td { border: 1px solid #000; padding: 4pt 6pt; vertical-align: top; }
th { font-family: "SimHei"; font-weight: 400; text-align: center; }
blockquote { margin: 0; padding: 0 0 0 2em; color: #000; }
pre { white-space: pre-wrap; word-break: break-word; line-height: 28pt; font-family: "FangSong"; }
''';

  static String _docxStyles() =>
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
    <w:name w:val="Normal"/>
    <w:pPr><w:spacing w:after="0" w:line="560" w:lineRule="exact"/><w:ind w:firstLine="640"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="FangSong" w:eastAsia="FangSong" w:hAnsi="FangSong"/><w:sz w:val="32"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:pPr><w:jc w:val="center"/><w:spacing w:after="560" w:line="640" w:lineRule="exact"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="44"/><w:rFonts w:ascii="SimSun" w:eastAsia="SimSun" w:hAnsi="SimSun"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="560" w:lineRule="exact"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:rFonts w:ascii="SimHei" w:eastAsia="SimHei" w:hAnsi="SimHei"/><w:sz w:val="32"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="560" w:lineRule="exact"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:b/><w:rFonts w:ascii="KaiTi" w:eastAsia="KaiTi" w:hAnsi="KaiTi"/><w:sz w:val="32"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="560" w:lineRule="exact"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:b/><w:rFonts w:ascii="FangSong" w:eastAsia="FangSong" w:hAnsi="FangSong"/><w:sz w:val="32"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="560" w:lineRule="exact"/><w:ind w:left="640" w:firstLine="0"/></w:pPr></w:style>
</w:styles>''';

  static String _docxDocumentXml(DocumentDraft draft) {
    final nodes = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
    ).parseLines(draft.content.split('\n'));
    final buf = StringBuffer()
      ..write(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>',
      );
    const official = true;

    var titleWritten = false;
    for (final node in nodes) {
      if (!titleWritten && node is md.Element) {
        final text = _nodeText(node).trim();
        if (node.tag == 'h1' || _isOfficialTitleText(text, draft)) {
          buf.write(_docxTitleParagraph(text, official: true));
          titleWritten = true;
          continue;
        }
        if (draft.title.trim().isNotEmpty) {
          buf.write(_docxTitleParagraph(draft.title.trim(), official: true));
          titleWritten = true;
        }
      }
      buf.write(_docxBlock(node, official: official));
    }
    buf.write(
      '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="2098" w:right="1474" w:bottom="1984" w:left="1587"/></w:sectPr></w:body></w:document>',
    );
    return buf.toString();
  }

  static String _docxBlock(md.Node node, {required bool official}) {
    if (node is! md.Element) return '';
    final tag = node.tag;
    if (tag == 'h1') {
      return _docxTitleParagraph(_nodeText(node), official: official);
    }
    if (tag == 'h2') {
      return _docxParagraph(
        _nodeText(node),
        style: 'Heading1',
        official: official,
      );
    }
    if (tag == 'h3') {
      return _docxParagraph(
        _nodeText(node),
        style: 'Heading2',
        official: official,
      );
    }
    if (tag == 'h4' || tag == 'h5' || tag == 'h6') {
      return _docxParagraph(
        _nodeText(node),
        style: 'Heading3',
        official: official,
      );
    }
    if (tag == 'p') {
      final text = _nodeText(node);
      final style = official ? _officialHeadingStyleForText(text) : null;
      return _docxParagraph(
        text,
        style: style,
        firstLine: style == null ? null : 0,
        official: official,
      );
    }
    if (tag == 'blockquote') {
      return _docxParagraph(
        _nodeText(node),
        indent: official ? 640 : 420,
        firstLine: 0,
        official: official,
      );
    }
    if (tag == 'pre') {
      return _docxParagraph(
        _nodeText(node),
        indent: 0,
        firstLine: 0,
        official: official,
      );
    }
    if (tag == 'ul' || tag == 'ol') {
      return _docxList(node, ordered: tag == 'ol', official: official);
    }
    if (tag == 'table') return _docxTable(node, official: official);
    return node.children
            ?.map((child) => _docxBlock(child, official: official))
            .join() ??
        '';
  }

  static String _docxList(
    md.Element list, {
    required bool ordered,
    required bool official,
  }) {
    final buf = StringBuffer();
    var index = 1;
    for (final child in list.children ?? const <md.Node>[]) {
      if (child is! md.Element || child.tag != 'li') continue;
      final prefix = ordered ? '${index++}. ' : '• ';
      buf.write(
        _docxParagraph(
          '$prefix${_nodeText(child)}',
          style: 'ListParagraph',
          firstLine: 0,
          official: official,
        ),
      );
    }
    return buf.toString();
  }

  static String _docxTable(md.Element table, {required bool official}) {
    final rows = <List<String>>[];
    void collectRows(md.Node node) {
      if (node is md.Element && node.tag == 'tr') {
        rows.add(
          (node.children ?? const <md.Node>[])
              .whereType<md.Element>()
              .where((e) => e.tag == 'th' || e.tag == 'td')
              .map(_nodeText)
              .toList(),
        );
      } else if (node is md.Element) {
        for (final child in node.children ?? const <md.Node>[]) {
          collectRows(child);
        }
      }
    }

    collectRows(table);
    if (rows.isEmpty) return '';
    final cols = rows.fold<int>(
      0,
      (max, row) => row.length > max ? row.length : max,
    );
    final width = cols == 0 ? 9000 : 9000 ~/ cols;
    final buf = StringBuffer()
      ..write(
        '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders><w:top w:val="single" w:sz="4" w:color="D1D5DB"/><w:left w:val="single" w:sz="4" w:color="D1D5DB"/><w:bottom w:val="single" w:sz="4" w:color="D1D5DB"/><w:right w:val="single" w:sz="4" w:color="D1D5DB"/><w:insideH w:val="single" w:sz="4" w:color="D1D5DB"/><w:insideV w:val="single" w:sz="4" w:color="D1D5DB"/></w:tblBorders></w:tblPr>',
      );
    for (var r = 0; r < rows.length; r++) {
      buf.write('<w:tr>');
      for (final cell in rows[r]) {
        final shading = r == 0 ? '<w:shd w:fill="F3F4F6"/>' : '';
        buf.write(
          '<w:tc><w:tcPr><w:tcW w:w="$width" w:type="dxa"/>$shading</w:tcPr>${_docxParagraph(cell, firstLine: 0, after: official ? 0 : 80, official: official)}</w:tc>',
        );
      }
      buf.write('</w:tr>');
    }
    return '${buf.toString()}</w:tbl>${_docxParagraph('', after: official ? 0 : 120, official: official)}';
  }

  static String _docxParagraph(
    String text, {
    String? style,
    int? indent,
    int? firstLine,
    int after = 160,
    bool official = false,
  }) {
    final safe = const HtmlEscape().convert(text);
    final styleXml = style == null ? '' : '<w:pStyle w:val="$style"/>';
    final effectiveFirstLine = firstLine ?? (style == null ? 640 : 0);
    final indentXml = indent == null && effectiveFirstLine == 0
        ? ''
        : '<w:ind${indent == null ? '' : ' w:left="$indent"'} w:firstLine="$effectiveFirstLine"/>';
    final computedAfter = after == 160 ? 0 : after;
    final spacingXml =
        '<w:spacing w:after="$computedAfter" w:line="560" w:lineRule="exact"/>';
    final runPr =
        _officialRunPrForStyle(style) ??
        (style == null
            ? '<w:rPr><w:rFonts w:ascii="FangSong" w:eastAsia="FangSong" w:hAnsi="FangSong"/><w:sz w:val="32"/></w:rPr>'
            : '');
    return '<w:p><w:pPr>$styleXml$spacingXml$indentXml</w:pPr><w:r>$runPr<w:t xml:space="preserve">$safe</w:t></w:r></w:p>';
  }

  static String? _officialHeadingStyleForText(String text) {
    final value = text.trimLeft();
    if (RegExp(r'^[一二三四五六七八九十]+、').hasMatch(value)) {
      return 'Heading1';
    }
    if (RegExp(r'^[（(][一二三四五六七八九十]+[）)]').hasMatch(value) &&
        _looksLikeStandaloneHeading(value)) {
      return 'Heading2';
    }
    if (RegExp(r'^\d+[.．、]\s*[\u4e00-\u9fa5]').hasMatch(value) &&
        _looksLikeStandaloneHeading(value)) {
      return 'Heading3';
    }
    return null;
  }

  static bool _looksLikeStandaloneHeading(String value) {
    final text = value.trim();
    if (text.length > 18) return false;
    return !RegExp(r'[：:。；;，,]').hasMatch(text);
  }

  static String? _officialRunPrForStyle(String? style) {
    if (style == 'Heading1') {
      return '<w:rPr><w:rFonts w:ascii="SimHei" w:eastAsia="SimHei" w:hAnsi="SimHei"/><w:sz w:val="32"/></w:rPr>';
    }
    if (style == 'Heading2') {
      return '<w:rPr><w:b/><w:rFonts w:ascii="KaiTi" w:eastAsia="KaiTi" w:hAnsi="KaiTi"/><w:sz w:val="32"/></w:rPr>';
    }
    if (style == 'Heading3') {
      return '<w:rPr><w:b/><w:rFonts w:ascii="FangSong" w:eastAsia="FangSong" w:hAnsi="FangSong"/><w:sz w:val="32"/></w:rPr>';
    }
    if (style == 'ListParagraph') {
      return '<w:rPr><w:rFonts w:ascii="FangSong" w:eastAsia="FangSong" w:hAnsi="FangSong"/><w:sz w:val="32"/></w:rPr>';
    }
    return null;
  }

  static String _docxTitleParagraph(String text, {required bool official}) {
    final safe = const HtmlEscape().convert(text.trim());
    final font = official ? 'SimSun' : 'Microsoft YaHei';
    final size = official ? 44 : 32;
    final line = official ? 640 : 420;
    final after = official ? 560 : 360;
    return '<w:p><w:pPr><w:pStyle w:val="Title"/><w:jc w:val="center"/><w:spacing w:after="$after" w:line="$line" w:lineRule="${official ? 'exact' : 'auto'}"/><w:ind w:firstLine="0"/></w:pPr><w:r><w:rPr><w:b/><w:rFonts w:ascii="$font" w:eastAsia="$font" w:hAnsi="$font"/><w:sz w:val="$size"/></w:rPr><w:t xml:space="preserve">$safe</w:t></w:r></w:p>';
  }

  static bool _isOfficialTitleText(String text, DocumentDraft draft) {
    final value = text.trim();
    if (value.isEmpty || value.length > 80) return false;
    if (value.contains('：') || value.contains(':')) return false;
    if (_compact(value) == _compact(draft.title)) return true;
    final template = draft.templateName.trim();
    if (template.isNotEmpty && value.endsWith(template)) return true;
    return RegExp(r'(通知|请示|报告|函|会议纪要)$').hasMatch(value);
  }

  static String _compact(String value) =>
      value.replaceAll(RegExp(r'[\s#*_`《》“”"：:，,。.]'), '');

  static String _nodeText(md.Node node) {
    if (node is md.Text) return node.text;
    if (node is md.Element) {
      if (node.tag == 'br') return '\n';
      return (node.children ?? const <md.Node>[]).map(_nodeText).join();
    }
    return '';
  }

  static String _safeFileName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? '未命名文档' : _clip(cleaned, 80);
  }

  static const _candidateBrowsers = [
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
  ];

  static String? _browserPath() {
    for (final path in _candidateBrowsers) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }
}
