import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:xml/xml.dart';

import '../util/text_util.dart';
import 'agent/model_client.dart';
import 'headless_browser.dart';
import 'settings_service.dart';

/// 已渲染的图（Mermaid → PNG），用于嵌入 docx。cx/cy 为显示尺寸（EMU）。
class _DiagramImage {
  _DiagramImage({required this.png, required this.cx, required this.cy});
  final List<int> png;
  final int cx;
  final int cy;
}

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

enum DocumentExportFormat { word, pdf, excel }

class DocumentDraft {
  DocumentDraft({
    required this.id,
    required this.title,
    required this.topic,
    required this.templateId,
    this.expectedPages = 3,
    this.templateName = '',
    this.templateText = '',
    this.spreadsheet = false,
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

  /// 是否为「多工作表 Excel」文档：上传 xlsx 模板时置为 true。
  /// 为 true 时按工作表组织生成内容，并可导出 .xlsx。
  bool spreadsheet;
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
    'spreadsheet': spreadsheet,
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
    spreadsheet: json['spreadsheet'] as bool? ?? false,
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

  /// 解析一个 docx / xlsx 模板文件，返回其纯文本结构（供外部按结构参考生成）。
  Future<String> extractTemplateText(String path) async {
    final file = File(path);
    if (!await file.exists()) throw Exception('模板文件不存在：$path');
    final ext = p.extension(path).toLowerCase();
    if (ext == '.docx') return _readDocxText(file);
    if (ext == '.xlsx') return _readXlsxTemplate(file);
    throw Exception('模板仅支持 docx 与 xlsx 格式');
  }

  /// 把一份 Markdown 正文按中文公文/正式文档样式写成 .docx 文件。
  /// 供项目文档生成等外部流程复用同一套排版管线。
  Future<void> writeMarkdownToDocx({
    required String title,
    required String markdown,
    required File out,
  }) async {
    final now = DateTime.now();
    final draft = DocumentDraft(
      id: 'export',
      title: title,
      topic: title,
      templateId: templates.first.id,
      content: markdown,
      createdAt: now,
      updatedAt: now,
    );
    // 项目技术文档使用常规「技术文档」排版（宋体正文/黑体标题、1.5 倍行距、
    // 自动生成 Word 目录），并把 Mermaid 图渲染为图片嵌入，而非公文仿宋体。
    await _writeStyledDocx(draft, out, official: false);
  }

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

  /// 导入模板文件。支持 docx 与 xlsx（Excel 可含多个工作表）。
  /// 解析出的文本存入 templateText，生成文档时作为结构/栏目参考。
  Future<void> importTemplate(String path) async {
    final draft = current;
    if (draft == null) throw StateError('未打开文档');
    final file = File(path);
    if (!await file.exists()) throw Exception('模板文件不存在：$path');
    final ext = p.extension(path).toLowerCase();
    final String text;
    if (ext == '.docx') {
      text = await _readDocxText(file);
    } else if (ext == '.xlsx') {
      text = await _readXlsxTemplate(file);
    } else {
      throw Exception('模板仅支持 docx 与 xlsx 格式');
    }
    if (text.trim().isEmpty) throw Exception('未从模板中解析到内容');
    draft.templateName = p.basename(path);
    draft.templateText = text;
    // 上传 Excel 模板即进入「多工作表」模式：按 sheet 生成、可导出 xlsx。
    draft.spreadsheet = ext == '.xlsx';
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
    if (formats.contains(DocumentExportFormat.excel)) {
      final xlsx = File(p.join(dir.path, '$base.xlsx'));
      await _writeXlsx(draft, xlsx);
      exported.add(xlsx);
    }
  }

  Future<void> generate() async {
    final draft = current;
    if (draft == null || busy) return;
    busy = true;
    stage = '正在生成文档…';
    notifyListeners();
    try {
      // 多工作表 Excel 文档与普通文稿用不同的提示词。
      final reply = await _chat(
        draft.spreadsheet
            ? _spreadsheetMessages(draft)
            : _documentMessages(draft),
      );
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

  /// 继续完善：只针对 [instruction] 指出的地方补充/细化，其余已有内容原样保留。
  /// 模型返回完整的更新后正文，替换 draft.content。
  Future<void> refine(String instruction) async {
    final draft = current;
    if (draft == null || busy) return;
    if (draft.content.trim().isEmpty) {
      stage = '请先生成文档，再继续完善';
      notifyListeners();
      return;
    }
    if (instruction.trim().isEmpty) return;
    busy = true;
    stage = '正在继续完善…';
    notifyListeners();
    try {
      final reply = await _chat(
        draft.spreadsheet
            ? _refineSpreadsheetMessages(draft, instruction)
            : _refineDocumentMessages(draft, instruction),
      );
      final next = reply.trim();
      if (next.isEmpty) throw Exception('模型未返回内容');
      draft.content = next;
      draft.updatedAt = DateTime.now();
      stage = '完善完成';
      await _persist();
    } catch (e) {
      stage = '完善失败：$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  List<Map<String, String>> _refineDocumentMessages(
    DocumentDraft draft,
    String instruction,
  ) {
    return [
      {
        'role': 'system',
        'content': '你是严谨的中文文档写作专家。只输出更新后的文档正文，不解释。',
      },
      {
        'role': 'user',
        'content':
            '''
下面是这份文档的现有正文。请只针对我指出的地方进行补充和完善，其它已有内容必须原样保留，不要改写、删减或调整顺序。

需要继续完善的地方：
$instruction

${draft.references.isEmpty ? '' : '可参考的资料：\n${_formatReferences(draft.references)}\n'}
现有正文：
${draft.content}

输出要求：
- 输出完整的更新后正文（含未改动的部分），使用 Markdown。
- 只在我指出的地方做补充/细化；其余部分逐字保留，不要改动。
- 不编造具体单位名称、真实文号、金额等敏感事实，需补充处用【待补充：...】标注。
''',
      },
    ];
  }

  List<Map<String, String>> _refineSpreadsheetMessages(
    DocumentDraft draft,
    String instruction,
  ) {
    return [
      {
        'role': 'system',
        'content':
            '你是严谨的中文需求/数据文档专家。只输出更新后的、按工作表组织的内容，不解释。',
      },
      {
        'role': 'user',
        'content':
            '''
下面是这份「多工作表 Excel」文档的现有内容（用「## 工作表：名称」分节 + Markdown 表格）。
请只针对我指出的地方补充/完善，其它工作表与已有行必须原样保留。

需要继续完善的地方：
$instruction

${draft.references.isEmpty ? '' : '可参考的资料：\n${_formatReferences(draft.references)}\n'}
现有内容：
${draft.content}

输出要求：
- 保持「## 工作表：名称」+ Markdown 表格 的格式。
- 只在我指出的工作表/内容上做补充或细化；其余工作表与已有行逐字保留，不要改动。
- 输出完整的更新后内容，除工作表标题与表格外不要输出其它说明文字。
- 不编造敏感信息，需补充处用【待补充：...】标注。
''',
      },
    ];
  }

  List<Map<String, String>> _documentMessages(DocumentDraft draft) {
    final template = templateOf(draft.templateId);
    return [
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

${draft.templateText.trim().isEmpty ? '' : '用户上传的模板（docx 或 Excel）解析内容如下，请严格参考其结构、栏目和格式层级（Excel 模板含多个工作表，已用「## 工作表：名称」分隔，请按各工作表的栏目逐一组织内容）：\n${clip(draft.templateText, 12000)}\n'}
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
    ];
  }

  /// 多工作表 Excel 文档的提示词：要求模型按「## 工作表：名称 + Markdown 表格」组织内容，
  /// 便于后续按 sheet 解析并导出为 .xlsx。
  List<Map<String, String>> _spreadsheetMessages(DocumentDraft draft) {
    final template = templateOf(draft.templateId);
    return [
      {
        'role': 'system',
        'content':
            '你是严谨的中文需求/数据文档专家，擅长把内容组织成多工作表的 Excel 表格。'
                '严格按要求的格式输出，不要输出任何额外说明。',
      },
      {
        'role': 'user',
        'content':
            '''
请根据主题，按「多工作表 Excel」的形式准备内容。

文档类型：${template.category} / ${template.name}
主题：${draft.topic}

内容要求（用于把握每个工作表该填什么）：
${template.requirements}

${draft.templateText.trim().isEmpty ? '' : '用户上传的 Excel 模板已解析如下（用「## 工作表：名称」分隔各工作表，并列出其列名/栏目），请严格沿用这些工作表名与列名：\n${clip(draft.templateText, 12000)}\n'}
${draft.references.isEmpty ? '' : '参考资料如下，请优先依据这些资料填写：\n${_formatReferences(draft.references)}\n'}
输出格式（务必严格遵守，便于导出为 Excel）：
- 每个工作表用一个二级标题表示：`## 工作表：<工作表名称>`
- 紧接着用一个 Markdown 表格表示该工作表内容：第一行是表头（列名），其后每行一条数据。
- 工作表名与列名尽量沿用上传模板里的设定。
- 单元格内容简洁、准确；不编造单位名称、真实文号、金额等敏感信息，需用户补充处用【待补充：...】标注。
- 除了「## 工作表：」标题行和 Markdown 表格外，不要输出任何其它说明文字。
''',
      },
    ];
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

  /// 读取 xlsx 模板：按真实工作表名输出多 sheet 结构，供模型按表结构生成。
  /// 与参考文档的 _readXlsxText 不同——这里用工作表真名（如「功能清单」），
  /// 因为模板的栏目/表名是生成时要遵循的关键结构信息。
  Future<String> _readXlsxTemplate(File file) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    final sharedStrings = _xlsxSharedStrings(archive);
    final sheets = _xlsxSheetTargets(archive);
    if (sheets.isEmpty) throw Exception('不是有效的 xlsx 文件：缺少工作表');

    final buf = StringBuffer();
    for (final sheet in sheets) {
      final f = archive.findFile(sheet.path);
      if (f == null) continue;
      final xml = XmlDocument.parse(utf8.decode(f.content));
      buf.writeln('## 工作表：${sheet.name}');
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
            .join(' | ');
        if (line.isNotEmpty) buf.writeln('- $line');
        if (buf.length >= 30000) break;
      }
      buf.writeln();
      if (buf.length >= 30000) break;
    }
    final out = buf.toString().trim();
    return out.length > 30000 ? out.substring(0, 30000) : out;
  }

  /// 解析工作簿，返回按显示顺序排列的工作表（真名 + worksheet 路径）。
  List<({String name, String path})> _xlsxSheetTargets(Archive archive) {
    final wb = archive.findFile('xl/workbook.xml');
    final rels = archive.findFile('xl/_rels/workbook.xml.rels');
    if (wb == null || rels == null) return const [];
    // 先建立 rId → 目标路径 的映射。
    final relMap = <String, String>{};
    for (final r in XmlDocument.parse(
      utf8.decode(rels.content),
    ).descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'Relationship',
    )) {
      final id = r.getAttribute('Id');
      final target = r.getAttribute('Target');
      if (id != null && target != null) relMap[id] = target;
    }
    // 再按 workbook.xml 里 <sheet> 的顺序取真名，经 r:id 找到对应文件。
    final out = <({String name, String path})>[];
    for (final s in XmlDocument.parse(
      utf8.decode(wb.content),
    ).descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'sheet',
    )) {
      final name = s.getAttribute('name') ?? '工作表';
      final rid = s.attributes
          .firstWhere(
            (a) => a.name.local == 'id',
            orElse: () => XmlAttribute(XmlName('id'), ''),
          )
          .value;
      final target = relMap[rid];
      if (target == null) continue;
      final path = target.startsWith('/')
          ? target.substring(1)
          : 'xl/$target';
      out.add((name: name, path: path));
    }
    return out;
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

  Future<void> _writeStyledDocx(
    DocumentDraft draft,
    File out, {
    bool official = true,
  }) async {
    var markdown = draft.content;
    // 技术文档：去掉模型手写的「目录」章节，改由 Word 目录域自动生成。
    if (!official) markdown = _stripManualToc(markdown);
    // 提取 Mermaid 代码块并渲染成图片（渲染失败则回退为等宽代码块展示源码）。
    final images = <_DiagramImage>[];
    markdown = await _extractAndRenderDiagrams(markdown, images);
    final hasImages = images.isNotEmpty;

    final archive = Archive();
    archive.addFile(
      ArchiveFile.string(
        '[Content_Types].xml',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
${hasImages ? '  <Default Extension="png" ContentType="image/png"/>\n' : ''}  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
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
    final imgRels = StringBuffer();
    for (var i = 0; i < images.length; i++) {
      imgRels.write(
        '<Relationship Id="rIdImg${i + 1}" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
        'Target="media/image${i + 1}.png"/>',
      );
    }
    archive.addFile(
      ArchiveFile.string(
        'word/_rels/document.xml.rels',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$imgRels</Relationships>''',
      ),
    );
    archive.addFile(
      ArchiveFile.string('word/styles.xml', _docxStyles(official)),
    );
    archive.addFile(
      ArchiveFile.string(
        'word/document.xml',
        _docxDocumentXml(draft, markdown, official, images),
      ),
    );
    for (var i = 0; i < images.length; i++) {
      archive.addFile(
        ArchiveFile.bytes('word/media/image${i + 1}.png', images[i].png),
      );
    }
    final bytes = ZipEncoder().encode(archive);
    await out.writeAsBytes(bytes);
  }

  // ---------------------------------------------------------------------------
  // Mermaid 图渲染：无头 Edge/Chrome 渲染 → PNG 截图 → 裁掉白边 → 嵌入 docx
  // ---------------------------------------------------------------------------

  /// 抽取 ```mermaid 代码块，逐个渲染成 PNG。成功的用占位符 `@@DIAGRAM{n}@@`
  /// 段落替换（后续渲染成内嵌图片）；失败的回退成普通代码块以等宽展示源码。
  Future<String> _extractAndRenderDiagrams(
    String markdown,
    List<_DiagramImage> images,
  ) async {
    final re = RegExp(r'```mermaid[ \t]*\r?\n([\s\S]*?)```', multiLine: true);
    final matches = re.allMatches(markdown).toList();
    if (matches.isEmpty) return markdown;
    final buf = StringBuffer();
    var last = 0;
    for (final m in matches) {
      buf.write(markdown.substring(last, m.start));
      last = m.end;
      final code = (m.group(1) ?? '').trim();
      if (code.isEmpty) continue;
      final im = await _renderMermaidToPng(code);
      if (im != null) {
        images.add(im);
        buf.write('\n\n@@DIAGRAM${images.length - 1}@@\n\n');
      } else {
        buf.write('\n\n```\n$code\n```\n\n');
      }
    }
    buf.write(markdown.substring(last));
    return buf.toString();
  }

  /// 公开包装：把一段 Mermaid 代码渲染为 PNG 字节（失败返回 null）。
  /// 供「项目概览」架构图等场景复用统一的无头浏览器高清渲染管线。
  Future<Uint8List?> renderMermaidPng(String code) async {
    final im = await _renderMermaidToPng(code);
    if (im == null) return null;
    return Uint8List.fromList(im.png);
  }

  Future<_DiagramImage?> _renderMermaidToPng(String code) async {
    final shot = await HeadlessBrowser.capturePng(_mermaidHtml(code));
    if (shot == null) return null;
    final decoded = img.decodePng(shot);
    if (decoded == null) return null;
    final cropped = _autoCropWhite(decoded);
    final bytes = img.encodePng(cropped);
    // 截图用了 pngScale 倍设备像素，故每逻辑像素 = 9525/scale EMU；再限制最大显示宽度。
    const emuPerPx = 9525 ~/ HeadlessBrowser.pngScale;
    var cx = cropped.width * emuPerPx;
    var cy = cropped.height * emuPerPx;
    const maxCx = 5400000; // 约 5.9 英寸，适配 A4 正文宽度
    if (cx > maxCx) {
      cy = (cy * maxCx / cx).round();
      cx = maxCx;
    }
    if (cx <= 0 || cy <= 0) return null;
    return _DiagramImage(png: bytes, cx: cx, cy: cy);
  }

  static String _mermaidHtml(String code) {
    final safe = const HtmlEscape(HtmlEscapeMode.element).convert(code);
    // useMaxWidth:false + width/height:auto 让 SVG 按内容自然尺寸渲染，不被容器压缩；
    // 配合 4x 设备像素倍率输出高清 PNG。geometricPrecision 让文字与线条更锐利。
    return '''<!doctype html><html><head><meta charset="utf-8">
<style>*{margin:0}html,body{background:#fff}
body{display:inline-block;padding:16px}
.mermaid{font-family:"Microsoft YaHei","SimSun",sans-serif;text-rendering:geometricPrecision}
.mermaid svg{width:auto!important;max-width:none!important;height:auto!important;shape-rendering:geometricPrecision}</style>
<script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
</head><body><pre class="mermaid">$safe</pre>
<script>mermaid.initialize({startOnLoad:true,securityLevel:"loose",
flowchart:{useMaxWidth:false,htmlLabels:true},
sequence:{useMaxWidth:false},gantt:{useMaxWidth:false},
er:{useMaxWidth:false},class:{useMaxWidth:false},state:{useMaxWidth:false}});</script>
</body></html>''';
  }

  /// 裁掉截图四周的白边，只保留图形本身（留少量边距）。
  static img.Image _autoCropWhite(img.Image src) {
    var minX = src.width, minY = src.height, maxX = 0, maxY = 0;
    var found = false;
    for (var y = 0; y < src.height; y++) {
      for (var x = 0; x < src.width; x++) {
        final px = src.getPixel(x, y);
        if (px.r < 245 || px.g < 245 || px.b < 245) {
          found = true;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (!found) return src;
    const margin = 20;
    minX = (minX - margin).clamp(0, src.width - 1);
    minY = (minY - margin).clamp(0, src.height - 1);
    maxX = (maxX + margin).clamp(0, src.width - 1);
    maxY = (maxY + margin).clamp(0, src.height - 1);
    return img.copyCrop(
      src,
      x: minX,
      y: minY,
      width: maxX - minX + 1,
      height: maxY - minY + 1,
    );
  }

  /// 去掉模型手写的「目录」章节（含其后目录项，直到下一个标题）。
  static String _stripManualToc(String markdown) {
    final lines = markdown.replaceAll('\r\n', '\n').split('\n');
    final out = <String>[];
    var skipping = false;
    for (final line in lines) {
      final h = RegExp(r'^(#{1,6})\s*(.+?)\s*$').firstMatch(line);
      if (h != null) {
        final title = h.group(2)!.replaceAll(RegExp(r'\s'), '');
        if (title == '目录' || title == '目錄' || title.toLowerCase() == 'contents') {
          skipping = true;
          continue;
        }
        if (skipping) skipping = false; // 下一个标题即目录结束
      }
      if (skipping) continue;
      out.add(line);
    }
    return out.join('\n');
  }

  // ---------------------------------------------------------------------------
  // 导出 Excel：把按「## 工作表：名称 + Markdown 表格」组织的正文写成 .xlsx
  // ---------------------------------------------------------------------------

  Future<void> _writeXlsx(DocumentDraft draft, File out) async {
    final sheets = parseSheets(draft.content);
    if (sheets.isEmpty) {
      throw Exception('未识别到工作表结构，无法导出 Excel（内容需以「## 工作表：名称」分节）');
    }
    final used = <String>{};
    final named = [
      for (final s in sheets) (name: _safeSheetName(s.name, used), rows: s.rows),
    ];

    final archive = Archive();
    final ctOverrides = StringBuffer();
    final sheetsXml = StringBuffer();
    final relsXml = StringBuffer();
    for (var i = 0; i < named.length; i++) {
      final id = i + 1;
      ctOverrides.write(
        '<Override PartName="/xl/worksheets/sheet$id.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
      );
      sheetsXml.write(
        '<sheet name="${_xmlAttr(named[i].name)}" sheetId="$id" r:id="rId$id"/>',
      );
      relsXml.write(
        '<Relationship Id="rId$id" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
        'Target="worksheets/sheet$id.xml"/>',
      );
    }

    archive.addFile(
      ArchiveFile.string(
        '[Content_Types].xml',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
$ctOverrides
</Types>''',
      ),
    );
    archive.addFile(
      ArchiveFile.string(
        '_rels/.rels',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>''',
      ),
    );
    archive.addFile(
      ArchiveFile.string(
        'xl/workbook.xml',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>$sheetsXml</sheets>
</workbook>''',
      ),
    );
    archive.addFile(
      ArchiveFile.string(
        'xl/_rels/workbook.xml.rels',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$relsXml</Relationships>''',
      ),
    );
    for (var i = 0; i < named.length; i++) {
      archive.addFile(
        ArchiveFile.string(
          'xl/worksheets/sheet${i + 1}.xml',
          _sheetXml(named[i].rows),
        ),
      );
    }
    final bytes = ZipEncoder().encode(archive);
    await out.writeAsBytes(bytes);
  }

  static String _sheetXml(List<List<String>> rows) {
    final buf = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>',
      );
    for (var r = 0; r < rows.length; r++) {
      buf.write('<row r="${r + 1}">');
      for (var c = 0; c < rows[r].length; c++) {
        final ref = '${_colLetter(c)}${r + 1}';
        final text = const HtmlEscape().convert(rows[r][c]);
        buf.write(
          '<c r="$ref" t="inlineStr"><is><t xml:space="preserve">$text</t></is></c>',
        );
      }
      buf.write('</row>');
    }
    buf.write('</sheetData></worksheet>');
    return buf.toString();
  }

  /// 把正文按「## 工作表：名称」分节，每节下的 Markdown 表格解析成行/列。
  /// 公开给 UI 做分 sheet 预览，也用于导出 xlsx。
  static List<({String name, List<List<String>> rows})> parseSheets(
    String content,
  ) {
    final sheets = <({String name, List<List<String>> rows})>[];
    String? name;
    var rows = <List<String>>[];
    void flush() {
      final n = name;
      if (n != null) sheets.add((name: n, rows: rows));
      rows = <List<String>>[];
    }

    for (final raw in content.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trim();
      final head = RegExp(r'^#{1,6}\s*工作表[:：]\s*(.+)$').firstMatch(line);
      if (head != null) {
        flush();
        name = head.group(1)!.trim();
        continue;
      }
      if (name == null || line.isEmpty) continue;
      if (line.startsWith('|')) {
        var t = line;
        if (t.startsWith('|')) t = t.substring(1);
        if (t.endsWith('|')) t = t.substring(0, t.length - 1);
        final cells = t.split('|').map((e) => e.trim()).toList();
        // 跳过 |---| 分隔行。
        if (cells.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c))) continue;
        rows.add(cells.map(_stripMd).toList());
      } else {
        // 非表格的说明行也保留为单格一行，避免丢内容。
        rows.add([_stripMd(line)]);
      }
    }
    flush();
    return sheets;
  }

  /// 去掉单元格文本里的常见 Markdown 标记，得到纯文本。
  static String _stripMd(String s) => s
      .replaceAll(RegExp(r'^[-*+]\s+'), '')
      .replaceAll(RegExp(r'^#{1,6}\s*'), '')
      .replaceAll('**', '')
      .replaceAll('`', '')
      .trim();

  /// Excel 工作表名限制：≤31 字符、不含 : \ / ? * [ ]，且需唯一。
  static String _safeSheetName(String raw, Set<String> used) {
    var n = raw.replaceAll(RegExp(r'[:\\/?*\[\]]'), ' ').trim();
    if (n.isEmpty) n = '工作表';
    if (n.length > 31) n = n.substring(0, 31);
    var unique = n;
    var i = 1;
    while (used.contains(unique)) {
      final suffix = '_${i++}';
      unique = n.length + suffix.length > 31
          ? n.substring(0, 31 - suffix.length) + suffix
          : n + suffix;
    }
    used.add(unique);
    return unique;
  }

  /// 列序号转字母：0→A, 25→Z, 26→AA …
  static String _colLetter(int index) {
    var i = index;
    var s = '';
    while (true) {
      s = String.fromCharCode(65 + (i % 26)) + s;
      i = i ~/ 26 - 1;
      if (i < 0) break;
    }
    return s;
  }

  static String _xmlAttr(String s) =>
      const HtmlEscape(HtmlEscapeMode.attribute).convert(s);

  Future<void> _printHtmlToPdf(File html, File out) =>
      HeadlessBrowser.printPdf(html, out);

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

  /// 正式文档生成：统一走 [ModelClient] 的 writing 角色通道。
  Future<String> _chat(List<Map<String, String>> messages) {
    return ModelClient(settings, role: ModelRole.writing)
        .complete(messages: messages);
  }

  static String _formatReferences(List<ReferenceDocument> refs) {
    final buf = StringBuffer();
    for (var i = 0; i < refs.length; i++) {
      final ref = refs[i];
      buf
        ..writeln('【参考资料 ${i + 1}：${ref.name}】')
        ..writeln(clip(ref.text, 6000))
        ..writeln();
    }
    return clip(buf.toString(), 18000);
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

  static String _docxStyles(bool official) {
    if (official) {
      return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
    <w:name w:val="Normal"/>
    <w:pPr><w:spacing w:after="0" w:line="560" w:lineRule="exact"/><w:ind w:firstLine="640"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="FangSong" w:eastAsia="FangSong" w:hAnsi="FangSong"/><w:sz w:val="32"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:pPr><w:jc w:val="center"/><w:spacing w:after="560" w:line="640" w:lineRule="exact"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="44"/><w:rFonts w:ascii="SimSun" w:eastAsia="SimSun" w:hAnsi="SimSun"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="0"/><w:spacing w:after="0" w:line="560" w:lineRule="exact"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:rFonts w:ascii="SimHei" w:eastAsia="SimHei" w:hAnsi="SimHei"/><w:sz w:val="32"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="1"/><w:spacing w:after="0" w:line="560" w:lineRule="exact"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:b/><w:rFonts w:ascii="KaiTi" w:eastAsia="KaiTi" w:hAnsi="KaiTi"/><w:sz w:val="32"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="2"/><w:spacing w:after="0" w:line="560" w:lineRule="exact"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:b/><w:rFonts w:ascii="FangSong" w:eastAsia="FangSong" w:hAnsi="FangSong"/><w:sz w:val="32"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="560" w:lineRule="exact"/><w:ind w:left="640" w:firstLine="0"/></w:pPr></w:style>
</w:styles>''';
    }
    // 技术文档样式：正文宋体小四(12pt)、1.5 倍行距；各级标题黑体加粗，
    // 并设 outlineLvl 供 Word 目录域识别。
    return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
    <w:name w:val="Normal"/>
    <w:pPr><w:spacing w:after="0" w:line="360" w:lineRule="auto"/><w:ind w:firstLine="480"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Times New Roman" w:eastAsia="SimSun" w:hAnsi="Times New Roman"/><w:sz w:val="24"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:pPr><w:jc w:val="center"/><w:spacing w:after="360" w:line="440" w:lineRule="auto"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:rFonts w:ascii="Arial" w:eastAsia="SimHei" w:hAnsi="Arial"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="0"/><w:spacing w:before="240" w:after="120" w:line="360" w:lineRule="auto"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:b/><w:rFonts w:ascii="Arial" w:eastAsia="SimHei" w:hAnsi="Arial"/><w:sz w:val="30"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="1"/><w:spacing w:before="200" w:after="100" w:line="360" w:lineRule="auto"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:b/><w:rFonts w:ascii="Arial" w:eastAsia="SimHei" w:hAnsi="Arial"/><w:sz w:val="26"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="2"/><w:spacing w:before="160" w:after="80" w:line="360" w:lineRule="auto"/><w:ind w:firstLine="0"/></w:pPr><w:rPr><w:b/><w:rFonts w:ascii="Arial" w:eastAsia="SimHei" w:hAnsi="Arial"/><w:sz w:val="24"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="360" w:lineRule="auto"/><w:ind w:left="480" w:firstLine="0"/></w:pPr></w:style>
</w:styles>''';
  }

  static String _docxDocumentXml(
    DocumentDraft draft,
    String markdown,
    bool official,
    List<_DiagramImage> images,
  ) {
    final nodes = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
    ).parseLines(markdown.split('\n'));
    final buf = StringBuffer()
      ..write(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>',
      );

    var titleWritten = false;
    for (final node in nodes) {
      if (!titleWritten && node is md.Element) {
        final text = _nodeText(node).trim();
        if (node.tag == 'h1' || _isOfficialTitleText(text, draft)) {
          buf.write(_docxTitleParagraph(text, official: official));
          titleWritten = true;
          // 技术文档：标题后自动插入 Word 目录域。
          if (!official) buf.write(_docxTocField());
          continue;
        }
        if (draft.title.trim().isNotEmpty) {
          buf.write(_docxTitleParagraph(draft.title.trim(), official: official));
          titleWritten = true;
          if (!official) buf.write(_docxTocField());
        }
      }
      buf.write(_docxBlock(node, official: official, images: images));
    }
    buf.write(
      '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="2098" w:right="1474" w:bottom="1984" w:left="1587"/></w:sectPr></w:body></w:document>',
    );
    return buf.toString();
  }

  /// 真实的 Word 目录域：标题居中「目 录」+ TOC 字段（打开后按 F9 / 右键更新）。
  static String _docxTocField() {
    return '<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:after="240" w:line="360" w:lineRule="auto"/><w:ind w:firstLine="0"/></w:pPr>'
        '<w:r><w:rPr><w:b/><w:rFonts w:ascii="Arial" w:eastAsia="SimHei" w:hAnsi="Arial"/><w:sz w:val="30"/></w:rPr><w:t>目　录</w:t></w:r></w:p>'
        '<w:p><w:pPr><w:spacing w:line="360" w:lineRule="auto"/><w:ind w:firstLine="0"/></w:pPr>'
        '<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
        '<w:r><w:instrText xml:space="preserve"> TOC \\o "1-3" \\h \\z \\u </w:instrText></w:r>'
        '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
        '<w:r><w:rPr><w:rFonts w:ascii="Times New Roman" w:eastAsia="SimSun" w:hAnsi="Times New Roman"/><w:sz w:val="24"/></w:rPr><w:t>（生成后在 Word 中右键“更新域”或按 F9 生成目录）</w:t></w:r>'
        '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'
        '<w:p><w:pPr><w:spacing w:after="0"/><w:ind w:firstLine="0"/></w:pPr><w:r><w:br w:type="page"/></w:r></w:p>';
  }

  static String _docxBlock(
    md.Node node, {
    required bool official,
    required List<_DiagramImage> images,
  }) {
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
      final dm = RegExp(r'^@@DIAGRAM(\d+)@@$').firstMatch(text.trim());
      if (dm != null) {
        final idx = int.parse(dm.group(1)!);
        return (idx >= 0 && idx < images.length)
            ? _docxImageParagraph(images[idx], idx)
            : '';
      }
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
      return _docxPreformatted(_nodeText(node));
    }
    if (tag == 'ul' || tag == 'ol') {
      return _docxList(node, ordered: tag == 'ol', official: official);
    }
    if (tag == 'table') return _docxTable(node, official: official);
    return node.children
            ?.map(
              (child) =>
                  _docxBlock(child, official: official, images: images),
            )
            .join() ??
        '';
  }

  /// 内嵌图片段落（居中显示已渲染的图）。
  static String _docxImageParagraph(_DiagramImage im, int index) {
    final rid = 'rIdImg${index + 1}';
    final id = 100 + index;
    return '<w:p><w:pPr><w:jc w:val="center"/><w:spacing w:before="120" w:after="120" w:line="240" w:lineRule="auto"/><w:ind w:firstLine="0"/></w:pPr>'
        '<w:r><w:drawing>'
        '<wp:inline distT="0" distB="0" distL="0" distR="0" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">'
        '<wp:extent cx="${im.cx}" cy="${im.cy}"/>'
        '<wp:effectExtent l="0" t="0" r="0" b="0"/>'
        '<wp:docPr id="$id" name="diagram$index"/>'
        '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
        '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:nvPicPr><pic:cNvPr id="$id" name="diagram$index.png"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="$rid" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="${im.cx}" cy="${im.cy}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
        '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>';
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
    final bodyFirstLine = official ? 640 : 480;
    final effectiveFirstLine = firstLine ?? (style == null ? bodyFirstLine : 0);
    final indentXml = indent == null && effectiveFirstLine == 0
        ? ''
        : '<w:ind${indent == null ? '' : ' w:left="$indent"'} w:firstLine="$effectiveFirstLine"/>';
    final computedAfter = after == 160 ? 0 : after;
    final line = official ? '560' : '360';
    final lineRule = official ? 'exact' : 'auto';
    final spacingXml =
        '<w:spacing w:after="$computedAfter" w:line="$line" w:lineRule="$lineRule"/>';
    final bodyRunPr = official
        ? '<w:rPr><w:rFonts w:ascii="FangSong" w:eastAsia="FangSong" w:hAnsi="FangSong"/><w:sz w:val="32"/></w:rPr>'
        : '<w:rPr><w:rFonts w:ascii="Times New Roman" w:eastAsia="SimSun" w:hAnsi="Times New Roman"/><w:sz w:val="24"/></w:rPr>';
    final runPr =
        _runPrForStyle(style, official) ?? (style == null ? bodyRunPr : '');
    return '<w:p><w:pPr>$styleXml$spacingXml$indentXml</w:pPr><w:r>$runPr<w:t xml:space="preserve">$safe</w:t></w:r></w:p>';
  }

  /// 预格式化块（代码 / JSON / ASCII 框图）：用等宽字体、保留每一行并用
  /// `<w:br/>` 换行，避免多行被挤成一行；CJK 用 NSimSun 等宽以让框线对齐。
  static String _docxPreformatted(String text) {
    final lines = text.replaceAll('\r\n', '\n').replaceAll('\t', '    ').split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    while (lines.isNotEmpty && lines.first.trim().isEmpty) {
      lines.removeAt(0);
    }
    if (lines.isEmpty) return '';
    const rpr =
        '<w:rPr><w:rFonts w:ascii="Consolas" w:eastAsia="NSimSun" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="20"/></w:rPr>';
    final runs = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) runs.write('<w:r>$rpr<w:br/></w:r>');
      final safe = const HtmlEscape().convert(lines[i]);
      runs.write('<w:r>$rpr<w:t xml:space="preserve">$safe</w:t></w:r>');
    }
    return '<w:p><w:pPr>'
        '<w:spacing w:before="60" w:after="120" w:line="240" w:lineRule="auto"/>'
        '<w:ind w:left="240" w:firstLine="0"/>'
        '<w:shd w:val="clear" w:color="auto" w:fill="F5F5F5"/>'
        '</w:pPr>$runs</w:p>';
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

  static String? _runPrForStyle(String? style, bool official) {
    if (official) return _officialRunPrForStyle(style);
    // 技术文档：标题黑体加粗、正文/列表宋体。
    switch (style) {
      case 'Heading1':
        return '<w:rPr><w:b/><w:rFonts w:ascii="Arial" w:eastAsia="SimHei" w:hAnsi="Arial"/><w:sz w:val="30"/></w:rPr>';
      case 'Heading2':
        return '<w:rPr><w:b/><w:rFonts w:ascii="Arial" w:eastAsia="SimHei" w:hAnsi="Arial"/><w:sz w:val="26"/></w:rPr>';
      case 'Heading3':
        return '<w:rPr><w:b/><w:rFonts w:ascii="Arial" w:eastAsia="SimHei" w:hAnsi="Arial"/><w:sz w:val="24"/></w:rPr>';
      case 'ListParagraph':
        return '<w:rPr><w:rFonts w:ascii="Times New Roman" w:eastAsia="SimSun" w:hAnsi="Times New Roman"/><w:sz w:val="24"/></w:rPr>';
      default:
        return null;
    }
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
    final asciiFont = official ? 'SimSun' : 'Arial';
    final eaFont = official ? 'SimSun' : 'SimHei';
    final size = official ? 44 : 36;
    final line = official ? 640 : 440;
    final after = official ? 560 : 360;
    return '<w:p><w:pPr><w:pStyle w:val="Title"/><w:jc w:val="center"/><w:spacing w:after="$after" w:line="$line" w:lineRule="${official ? 'exact' : 'auto'}"/><w:ind w:firstLine="0"/></w:pPr><w:r><w:rPr><w:b/><w:rFonts w:ascii="$asciiFont" w:eastAsia="$eaFont" w:hAnsi="$asciiFont"/><w:sz w:val="$size"/></w:rPr><w:t xml:space="preserve">$safe</w:t></w:r></w:p>';
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
    // markdown 包会把文本（尤其代码/JSON）里的 " < > & 转义成 HTML 实体，
    // 这里取回真实字符；后续写入 XML 时再由 HtmlEscape 统一转义，避免出现
    // 字面的 &quot; / &lt; 等。
    if (node is md.Text) return _unescapeHtml(node.text);
    if (node is md.Element) {
      if (node.tag == 'br') return '\n';
      return (node.children ?? const <md.Node>[]).map(_nodeText).join();
    }
    return '';
  }

  /// 还原 markdown 解析产生的 HTML 实体为真实字符（& 放最后处理）。
  static String _unescapeHtml(String s) {
    if (!s.contains('&')) return s;
    return s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&#x2F;', '/')
        .replaceAll('&#47;', '/')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&');
  }

  static String _safeFileName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? '未命名文档' : clip(cleaned, 80);
  }

}
