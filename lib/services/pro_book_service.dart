import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models.dart';
import 'agent/memory/memory_selector.dart';
import 'agent/memory/memory_store.dart';
import 'agent/memory/memory_types.dart';
import 'agent/model_client.dart';
import 'file_library_service.dart';
import 'latex_pdf.dart';
import 'library_service.dart';
import 'settings_service.dart';
import 'web_reader.dart';

/// 专业书籍面向的行业。决定提示词里的术语、结构和合规重点。
enum ProIndustry {
  tech,
  archive;

  String get label => switch (this) {
    ProIndustry.tech => '科技',
    ProIndustry.archive => '档案',
  };

  static ProIndustry fromName(String? v) =>
      v == 'archive' ? ProIndustry.archive : ProIndustry.tech;

  /// 行业写作要点：注入大纲/成文提示词，让内容贴合该行业的最佳实践。
  String get guidance => switch (this) {
    ProIndustry.tech =>
      '面向科技/技术类专业书：重视基本原理、系统架构、关键实现、工程实践、'
          '真实案例、常见坑与最佳实践、前沿趋势。术语要准确，必要处给出示例或步骤。',
    ProIndustry.archive =>
      '面向档案行业专业书：必须紧扣国家标准（如 GB/T）、行业标准（如 DA/T）'
          '与法律法规；覆盖档案业务全流程（收集、整理、鉴定、保管、利用、销毁）；'
          '强调合规、规范流程、实务操作与典型案例。引用标准/法规时务必准确，不得编造条款编号。',
  };
}

/// 书籍类型定位。影响写作语气与组织方式。
enum ProBookType {
  textbook,
  standard,
  handbook,
  monograph;

  String get label => switch (this) {
    ProBookType.textbook => '教材',
    ProBookType.standard => '标准解读',
    ProBookType.handbook => '实务手册',
    ProBookType.monograph => '理论专著',
  };

  static ProBookType fromName(String? v) => switch (v) {
    'standard' => ProBookType.standard,
    'handbook' => ProBookType.handbook,
    'monograph' => ProBookType.monograph,
    _ => ProBookType.textbook,
  };

  String get guidance => switch (this) {
    ProBookType.textbook => '教材：系统、循序渐进，每章可含学习目标、小结、思考题。',
    ProBookType.standard => '标准解读：逐条解读条款、给出对照与实施要点，引用要精确。',
    ProBookType.handbook => '实务手册：以可操作步骤、清单、模板为主，强调“怎么做”。',
    ProBookType.monograph => '理论专著：强调学理深度、文献综述与严谨论证。',
  };
}

/// 关键术语：用于全书术语一致性（审校阶段对照使用）。
class ProTerm {
  ProTerm({required this.term, this.definition = ''});

  String term;
  String definition;

  Map<String, dynamic> toJson() => {'term': term, 'definition': definition};

  factory ProTerm.fromJson(Map<String, dynamic> j) => ProTerm(
    term: j['term'] as String? ?? '',
    definition: j['definition'] as String? ?? '',
  );
}

/// 参考资料状态：原文是否已拿到、是否已由 AI 解读。
enum ProRefStatus {
  pending,
  fetched,
  digested;

  String get label => switch (this) {
    ProRefStatus.pending => '待获取',
    ProRefStatus.fetched => '已入库',
    ProRefStatus.digested => '已解读',
  };

  static ProRefStatus fromName(String? v) => switch (v) {
    'fetched' => ProRefStatus.fetched,
    'digested' => ProRefStatus.digested,
    _ => ProRefStatus.pending,
  };
}

/// 参考资料/引用。source 标明来源：知识库 / 网页 / 上传 / 手动。
class ProReference {
  ProReference({
    required this.id,
    required this.title,
    this.source = '手动',
    this.note = '',
    this.url = '',
    this.enabled = true,
    this.chapterId = '',
    this.filePath = '',
    this.digest = '',
    this.status = ProRefStatus.pending,
  });

  final String id;
  String title;

  /// 来源类型：知识库 / 网页 / 上传 / 手动。
  String source;
  String note;
  String url;
  bool enabled;

  /// 关联的章 id（空 = 全书通用），实现"按写作模块分组"。
  String chapterId;

  /// 原文文件的绝对路径或相对知识库根的路径（入库/上传后回填）。
  String filePath;

  /// AI 解读：适用范围、核心要点、可引用的关键条款（成文时注入）。
  String digest;

  ProRefStatus status;

  bool get hasFile => filePath.trim().isNotEmpty;
  bool get hasDigest => digest.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'source': source,
    'note': note,
    'url': url,
    'enabled': enabled,
    'chapterId': chapterId,
    'filePath': filePath,
    'digest': digest,
    'status': status.name,
  };

  factory ProReference.fromJson(Map<String, dynamic> j) => ProReference(
    id: j['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
    title: j['title'] as String? ?? '',
    source: j['source'] as String? ?? '手动',
    note: j['note'] as String? ?? '',
    url: j['url'] as String? ?? '',
    enabled: j['enabled'] as bool? ?? true,
    chapterId: j['chapterId'] as String? ?? '',
    filePath: j['filePath'] as String? ?? '',
    digest: j['digest'] as String? ?? '',
    status: ProRefStatus.fromName(j['status'] as String?),
  );
}

/// 小节（二级目录）：标题 + 写作要点 + 正文。
class ProSection {
  ProSection({
    required this.id,
    required this.title,
    this.brief = '',
    this.content = '',
    this.recap = '',
  });

  final String id;
  String title;

  /// 本节写作要点（来自大纲，指导成文）。
  String brief;
  String content;

  /// 本节写完后的纪要（约 120 字），供后续节滚动上下文防重复。
  String recap;

  bool get hasContent => content.trim().isNotEmpty;

  /// 中文按非空白字符近似字数。
  int get words => content.replaceAll(RegExp(r'\s'), '').length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'brief': brief,
    'content': content,
    'recap': recap,
  };

  factory ProSection.fromJson(Map<String, dynamic> j) => ProSection(
    id: j['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
    title: j['title'] as String? ?? '',
    brief: j['brief'] as String? ?? '',
    content: j['content'] as String? ?? '',
    recap: j['recap'] as String? ?? '',
  );
}

/// 章（一级目录）：标题 + 概述 + 多个小节。
class ProChapter {
  ProChapter({
    required this.id,
    required this.title,
    this.brief = '',
    List<ProSection>? sections,
  }) : sections = sections ?? [];

  final String id;
  String title;
  String brief;
  List<ProSection> sections;

  int get words => sections.fold(0, (s, e) => s + e.words);
  int get doneSections => sections.where((e) => e.hasContent).length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'brief': brief,
    'sections': sections.map((e) => e.toJson()).toList(),
  };

  factory ProChapter.fromJson(Map<String, dynamic> j) => ProChapter(
    id: j['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
    title: j['title'] as String? ?? '',
    brief: j['brief'] as String? ?? '',
    sections: ((j['sections'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => ProSection.fromJson(e.cast<String, dynamic>()))
        .toList(),
  );
}

/// 一本专业书：立项信息 + 多级大纲 + 资料库 + 术语表 + 审校结论。
class ProBook {
  ProBook({
    required this.id,
    required this.title,
    required this.industry,
    required this.bookType,
    this.audience = '',
    this.topic = '',
    this.readerPositioning = '',
    this.valueProposition = '',
    this.reviewNotes = '',
    this.referenceName = '',
    this.referenceMaterial = '',
    this.bookState = '',
    List<ProChapter>? chapters,
    List<ProReference>? references,
    List<ProTerm>? glossary,
    required this.createdAt,
    required this.updatedAt,
  }) : chapters = chapters ?? [],
       references = references ?? [],
       glossary = glossary ?? [];

  final String id;
  String title;
  ProIndustry industry;
  ProBookType bookType;
  String audience;

  // —— 立项 ——
  String topic; // 选题
  String readerPositioning; // 读者定位
  String valueProposition; // 核心价值主张

  // —— 立项参考资料（用户上传的 PDF，结合书名做解读分析）——
  String referenceName; // 上传文件名
  String referenceMaterial; // 抽取出的正文文本（截断保存）

  bool get hasReference => referenceMaterial.trim().isNotEmpty;

  // —— 大纲 / 资料 / 术语 / 审校 ——
  List<ProChapter> chapters;
  List<ProReference> references;
  List<ProTerm> glossary;
  String reviewNotes;

  /// 写作台账（滚动摘要）：已覆盖的主题、术语口径、已引用的标准/资料、
  /// 与后文的衔接点。每写完一节更新，写下一节时注入，保证全书上下文连贯。
  String bookState;

  final DateTime createdAt;
  DateTime updatedAt;

  int get totalSections => chapters.fold(0, (s, c) => s + c.sections.length);
  int get doneSections => chapters.fold(0, (s, c) => s + c.doneSections);
  int get totalWords => chapters.fold(0, (s, c) => s + c.words);
  bool get hasKickoff =>
      readerPositioning.trim().isNotEmpty || valueProposition.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'industry': industry.name,
    'bookType': bookType.name,
    'audience': audience,
    'topic': topic,
    'readerPositioning': readerPositioning,
    'valueProposition': valueProposition,
    'reviewNotes': reviewNotes,
    'referenceName': referenceName,
    'referenceMaterial': referenceMaterial,
    'bookState': bookState,
    'chapters': chapters.map((c) => c.toJson()).toList(),
    'references': references.map((r) => r.toJson()).toList(),
    'glossary': glossary.map((g) => g.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ProBook.fromJson(Map<String, dynamic> j) => ProBook(
    id: j['id'] as String,
    title: j['title'] as String? ?? '未命名',
    industry: ProIndustry.fromName(j['industry'] as String?),
    bookType: ProBookType.fromName(j['bookType'] as String?),
    audience: j['audience'] as String? ?? '',
    topic: j['topic'] as String? ?? '',
    readerPositioning: j['readerPositioning'] as String? ?? '',
    valueProposition: j['valueProposition'] as String? ?? '',
    reviewNotes: j['reviewNotes'] as String? ?? '',
    referenceName: j['referenceName'] as String? ?? '',
    referenceMaterial: j['referenceMaterial'] as String? ?? '',
    bookState: j['bookState'] as String? ?? '',
    chapters: ((j['chapters'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => ProChapter.fromJson(e.cast<String, dynamic>()))
        .toList(),
    references: ((j['references'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => ProReference.fromJson(e.cast<String, dynamic>()))
        .toList(),
    glossary: ((j['glossary'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => ProTerm.fromJson(e.cast<String, dynamic>()))
        .toList(),
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
  );
}

/// 待补充的图/表占位符（用于「图表待补」面板快速定位）。
class ProPlaceholder {
  ProPlaceholder({
    required this.isFigure,
    required this.description,
    required this.chapter,
    required this.section,
  });

  final bool isFigure; // true=图，false=表
  final String description;
  final ProChapter chapter;
  final ProSection section;
}

/// 「专业书籍」写作服务：把非虚构专业书拆成可控流水线——
/// ① 立项(选题/读者定位/核心价值) → ② 结构化大纲(章→小节) →
/// ③ 资料/标准检索与引用管理 → ④ 逐节成文(携带立项+资料+术语做上下文) →
/// ⑤ 审校(术语一致性/准确性) → ⑥ 导出 Markdown。
///
/// 按「科技 / 档案」行业套用不同提示词，保证内容贴合行业最佳实践。
class ProBookService extends ChangeNotifier {
  ProBookService(this.settings, {this.library, this.fileLibrary});

  final SettingsService settings;

  /// 知识库（标准笔记）：资料建议时匹配已有笔记。可为空（如移动端未接线）。
  final LibraryService? library;

  /// 文件库：下载的原文入库归类。可为空。
  final FileLibraryService? fileLibrary;

  final List<ProBook> books = [];
  ProBook? current;
  ProSection? activeSection;

  bool busy = false;
  String stage = '';

  bool _cancel = false;
  File? _store;
  String _baseDir = '';
  Directory? _imageDir; // 补充图表生成/上传的图片存放目录
  http.Client? _client;

  final WebReader _webReader = WebReader();

  /// 小模型通道：记忆召回选择、纪要归纳等廉价任务。
  late final ModelClient _small = ModelClient(settings, role: ModelRole.small);
  late final MemorySelector _selector = MemorySelector(_small);

  /// 每本书一个「知识记忆库」（已确立的标准条款/术语/关键事实），
  /// 落在应用数据目录，不污染知识库。
  MemoryStore _canon(ProBook book) =>
      MemoryStore(p.join(_baseDir, 'pro_book_data', book.id, 'memory'));

  /// 每本书的上传参考文件目录（模拟样题、系统截图等）。
  Directory _refsDir(ProBook book) =>
      Directory(p.join(_baseDir, 'pro_book_data', book.id, 'refs'));

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _baseDir = dir.path;
    _store = File('${dir.path}\\pro_books.json');
    if (await _store!.exists()) {
      try {
        final data = jsonDecode(await _store!.readAsString());
        if (data is List) {
          books
            ..clear()
            ..addAll(
              data.whereType<Map>().map(
                (e) => ProBook.fromJson(e.cast<String, dynamic>()),
              ),
            );
          books.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        }
      } catch (_) {
        // 解析失败保持空列表，不写坏数据。
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 书架管理
  // ---------------------------------------------------------------------------

  ProBook createBook({
    required String title,
    required ProIndustry industry,
    required ProBookType bookType,
    String audience = '',
    String topic = '',
  }) {
    final now = DateTime.now();
    final book = ProBook(
      id: now.millisecondsSinceEpoch.toString(),
      title: title.trim().isEmpty ? '未命名' : title.trim(),
      industry: industry,
      bookType: bookType,
      audience: audience.trim(),
      topic: topic.trim(),
      createdAt: now,
      updatedAt: now,
    );
    books.insert(0, book);
    current = book;
    activeSection = null;
    notifyListeners();
    _persist();
    return book;
  }

  void openBook(ProBook book) {
    current = book;
    activeSection = book.chapters.firstOrNull?.sections.firstOrNull;
    notifyListeners();
  }

  void closeBook() {
    current = null;
    activeSection = null;
    notifyListeners();
  }

  void openSection(ProSection? section) {
    activeSection = section;
    notifyListeners();
  }

  // 占位符识别：成文时模型按固定格式预留 `> 【待补充图/表】描述`。
  static final _figRe = RegExp(r'【待补充图】\s*(.*)');
  static final _tabRe = RegExp(r'【待补充表】\s*(.*)');

  /// 扫描全书所有图/表占位符，供「图表待补」面板定位。
  List<ProPlaceholder> placeholders() {
    final book = current;
    final out = <ProPlaceholder>[];
    if (book == null) return out;
    for (final c in book.chapters) {
      for (final s in c.sections) {
        for (final line in s.content.split('\n')) {
          final f = _figRe.firstMatch(line);
          if (f != null) {
            out.add(ProPlaceholder(
              isFigure: true,
              description: f.group(1)!.trim(),
              chapter: c,
              section: s,
            ));
            continue;
          }
          final t = _tabRe.firstMatch(line);
          if (t != null) {
            out.add(ProPlaceholder(
              isFigure: false,
              description: t.group(1)!.trim(),
              chapter: c,
              section: s,
            ));
          }
        }
      }
    }
    return out;
  }

  int get figureCount => placeholders().where((e) => e.isFigure).length;
  int get tableCount => placeholders().where((e) => !e.isFigure).length;

  Future<void> deleteBook(ProBook book) async {
    books.remove(book);
    if (current == book) {
      current = null;
      activeSection = null;
    }
    notifyListeners();
    await _persist();
    // 一并清理该书的记忆库与上传参考文件目录。
    try {
      final dir = Directory(p.join(_baseDir, 'pro_book_data', book.id));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> save() async {
    current?.updatedAt = DateTime.now();
    books.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    notifyListeners();
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // ① 立项：AI 建议读者定位 + 核心价值主张（可结合上传的 PDF 参考资料）
  // ---------------------------------------------------------------------------

  /// 上传一份 PDF 作为立项参考资料：抽取正文文本，结合书名做解读分析。
  Future<void> attachReference(String path) async {
    final book = current;
    if (book == null || busy) return;
    _begin('正在解析 PDF…');
    try {
      final bytes = await File(path).readAsBytes();
      final text = await _pdfText(bytes);
      if (text.trim().isEmpty) {
        stage = '未能从 PDF 中提取到文字（可能是扫描件）';
        return;
      }
      book.referenceName = p.basename(path);
      book.referenceMaterial = text;
      book.updatedAt = DateTime.now();
      stage = '已上传参考资料：${book.referenceName}';
      await _persist();
    } catch (e) {
      stage = 'PDF 解析失败：$e';
    } finally {
      _end();
    }
  }

  /// 移除已上传的立项参考资料。
  void clearReference() {
    final book = current;
    if (book == null) return;
    book.referenceName = '';
    book.referenceMaterial = '';
    book.updatedAt = DateTime.now();
    notifyListeners();
    _persist();
  }

  Future<void> generateKickoff() async {
    final book = current;
    if (book == null || busy) return;
    _begin('正在分析选题、读者定位与核心价值…');
    try {
      // 若上传了参考资料，作为重要依据注入提示词，让模型结合书名解读。
      final refBlock = book.hasReference
          ? '''
用户上传了一份参考资料（文件：${book.referenceName}）。请务必结合书名仔细解读这份资料，
据此判断本书应覆盖的范围、读者层次与差异化价值（例如它可能是考试大纲、同类书目录或行业标准）：
---
${book.referenceMaterial}
---
'''
          : '';
      final reply = await _chat([
        {
          'role': 'system',
          'content': '你是资深专业图书策划编辑。只输出 JSON，不要解释。',
        },
        {
          'role': 'user',
          'content':
              '''
为一本「${book.industry.label}」行业的专业书做立项分析。
${book.industry.guidance}
书籍类型：${book.bookType.label}（${book.bookType.guidance}）
书名：${book.title}
选题：${book.topic.isEmpty ? '（未填写，请据书名推断）' : book.topic}
目标读者补充：${book.audience.isEmpty ? '（未填写）' : book.audience}
$refBlock
请给出：
- topic：精炼的选题（这本书要解决的核心问题，一两句话）。若用户已填写选题，在其基础上凝练；否则据书名${book.hasReference ? '与上传资料' : ''}拟定。
- readerPositioning：精准的读者定位（是谁、什么水平、读它解决什么问题）。
- valueProposition：本书的核心价值主张（读者读完能获得什么、与同类书的差异）。
${book.hasReference ? '- 充分利用上传资料里的具体信息（如考点、章节、标准条目），让结论更贴合。' : ''}

严格输出 JSON：
{"topic":"...","readerPositioning":"...","valueProposition":"..."}
''',
        },
      ], jsonMode: true);
      final j = _parseJson(reply);
      // 选题：模型未给则保留用户原有的，避免清空。
      final topic = (j['topic'] ?? '').toString().trim();
      if (topic.isNotEmpty) book.topic = topic;
      book.readerPositioning = (j['readerPositioning'] ?? '').toString().trim();
      book.valueProposition = (j['valueProposition'] ?? '').toString().trim();
      book.updatedAt = DateTime.now();
      stage = '立项分析已生成';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '立项分析失败：$e';
    } finally {
      _end();
    }
  }

  /// 抽取 PDF 正文文本（前若干页，截断保存）。扫描件可能取不到文字。
  Future<String> _pdfText(
    Uint8List bytes, {
    int maxChars = 14000,
    int maxPages = 30,
  }) async {
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openData(
        bytes,
      ).timeout(const Duration(seconds: 25));
      final sb = StringBuffer();
      final count = doc.pages.length < maxPages ? doc.pages.length : maxPages;
      for (var i = 0; i < count; i++) {
        final text = await doc.pages[i].loadText();
        final fullText = text?.fullText.trim();
        if (fullText != null && fullText.isNotEmpty) {
          sb
            ..writeln(fullText)
            ..writeln();
        }
        if (sb.length >= maxChars) break;
      }
      return _clip(sb.toString().trim(), maxChars);
    } finally {
      await doc?.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // ② 大纲：生成章 → 小节的多级目录
  // ---------------------------------------------------------------------------

  Future<void> generateOutline() async {
    final book = current;
    if (book == null || busy) return;
    _begin('正在生成结构化大纲（章 → 小节）…');
    try {
      final reply = await _chat([
        {
          'role': 'system',
          'content': '你是资深专业图书作者。规划清晰、循序渐进的多级目录。只输出 JSON，不要解释。',
        },
        {
          'role': 'user',
          'content':
              '''
为下面这本「${book.industry.label}」行业专业书规划多级目录（章 → 小节）。
${book.industry.guidance}
书籍类型：${book.bookType.label}（${book.bookType.guidance}）
书名：${book.title}
选题：${book.topic}
读者定位：${book.readerPositioning}
核心价值：${book.valueProposition}

要求：
- 章节循序渐进、逻辑自洽，覆盖该主题的核心知识体系。
- 一般 6-12 章，每章 2-5 个小节。
- 每个小节给出 brief（本节写作要点，一句话）。

严格输出 JSON：
{"chapters":[{"title":"第1章 标题","brief":"本章概述","sections":[{"title":"1.1 小节标题","brief":"写作要点"}]}]}
''',
        },
      ], jsonMode: true);
      final j = _parseJson(reply);
      final rawChapters = (j['chapters'] as List?) ?? [];
      if (rawChapters.isEmpty) throw Exception('模型未返回章节');
      final chapters = <ProChapter>[];
      var ci = 0;
      for (final rc in rawChapters.whereType<Map>()) {
        ci++;
        final title = (rc['title'] ?? '').toString().trim();
        if (title.isEmpty) continue;
        final sections = <ProSection>[];
        var si = 0;
        for (final rs in ((rc['sections'] as List?) ?? []).whereType<Map>()) {
          si++;
          final st = (rs['title'] ?? '').toString().trim();
          if (st.isEmpty) continue;
          sections.add(
            ProSection(
              id: '${DateTime.now().microsecondsSinceEpoch}_${ci}_$si',
              title: st,
              brief: (rs['brief'] ?? '').toString().trim(),
            ),
          );
        }
        chapters.add(
          ProChapter(
            id: '${DateTime.now().microsecondsSinceEpoch}_$ci',
            title: title,
            brief: (rc['brief'] ?? '').toString().trim(),
            sections: sections,
          ),
        );
      }
      if (chapters.isEmpty) throw Exception('模型未返回可用章节');
      book.chapters = chapters;
      activeSection = chapters.firstOrNull?.sections.firstOrNull;
      book.updatedAt = DateTime.now();
      stage = '大纲已生成';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '生成大纲失败：$e';
    } finally {
      _end();
    }
  }

  // ---------------------------------------------------------------------------
  // ③ 资料 / 标准：AI 建议参考资料与引用；用户可手动增删
  // ---------------------------------------------------------------------------

  Future<void> suggestReferences() async {
    final book = current;
    if (book == null || busy) return;
    _begin('正在梳理应参考的资料 / 标准 / 法规…');
    try {
      final chapterList = book.chapters.isEmpty
          ? '（暂无大纲）'
          : book.chapters.map((c) => '- ${c.title}').join('\n');
      final reply = await _chat([
        {
          'role': 'system',
          'content': '你是严谨的专业图书资料编辑。只输出 JSON，不要编造不存在的标准编号。',
        },
        {
          'role': 'user',
          'content':
              '''
为下面这本「${book.industry.label}」行业专业书梳理应参考的资料清单。
${book.industry.guidance}
书名：${book.title}
选题：${book.topic}
核心价值：${book.valueProposition}
大纲：
${_outlineText(book)}

要求：
- 列出 6-12 条最关键的参考资料。
- ${book.industry == ProIndustry.archive ? '优先列出相关国家标准(GB/T)、行业标准(DA/T)与法律法规；不确定的编号留空或注明“待核实”，绝不可编造。' : '优先列出权威著作、标准规范、经典论文与官方文档。'}
- source 字段取值只能是：知识库 / 网页 / 手动。建议优先“网页”或“知识库”。
- note 写清这条资料对应支撑哪部分内容。
- chapter 字段：从下面章标题中选出这条资料主要支撑的一章（原样抄写标题）；若支撑全书则留空字符串。
章标题列表：
$chapterList

严格输出 JSON：
{"references":[{"title":"资料名称","source":"网页","note":"用途说明","url":"","chapter":""}]}
''',
        },
      ], jsonMode: true);
      final j = _parseJson(reply);
      final raw = (j['references'] as List?) ?? [];
      var added = 0;
      final newRefs = <ProReference>[];
      for (final r in raw.whereType<Map>()) {
        final title = (r['title'] ?? '').toString().trim();
        if (title.isEmpty) continue;
        // 跳过与已有资料同名的建议，避免反复点击时堆积重复条目。
        if (book.references.any((e) => e.title.trim() == title)) continue;
        final ref = ProReference(
          id: '${DateTime.now().microsecondsSinceEpoch}_$added',
          title: title,
          source: _normalizeSource((r['source'] ?? '手动').toString()),
          note: (r['note'] ?? '').toString().trim(),
          url: (r['url'] ?? '').toString().trim(),
          chapterId: _chapterIdByTitle(book, (r['chapter'] ?? '').toString()),
        );
        book.references.add(ref);
        newRefs.add(ref);
        added++;
      }
      // 自动匹配知识库：命中的资料直接关联原文，免下载。
      var matched = 0;
      for (final ref in newRefs) {
        if (_matchLibrary(ref)) matched++;
      }
      book.updatedAt = DateTime.now();
      stage = added == 0
          ? '未获得资料建议'
          : '已补充 $added 条参考资料建议${matched > 0 ? '（$matched 条在知识库中找到原文）' : ''}';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '资料建议失败：$e';
    } finally {
      _end();
    }
  }

  /// 按章标题找章 id；找不到返回空（全书通用）。
  String _chapterIdByTitle(ProBook book, String title) {
    final t = title.replaceAll(RegExp(r'\s'), '');
    if (t.isEmpty) return '';
    for (final c in book.chapters) {
      final ct = c.title.replaceAll(RegExp(r'\s'), '');
      if (ct == t || ct.contains(t) || t.contains(ct)) return c.id;
    }
    return '';
  }

  /// 在知识库（标准笔记 + 文件库）中按标题模糊匹配这条资料的原文。
  /// 命中则回填 filePath / source / status，返回 true。
  bool _matchLibrary(ProReference ref) {
    if (ref.hasFile) return true;
    final key = _matchKey(ref.title);
    if (key.isEmpty) return false;
    // 先找文件库里的原文文件（可全文解读）。
    for (final f in fileLibrary?.files ?? const <LibraryFile>[]) {
      final name = _matchKey(p.basenameWithoutExtension(f.name));
      if (name.isEmpty) continue;
      if (name.contains(key) || key.contains(name)) {
        ref.filePath = f.path;
        ref.source = '知识库';
        ref.status = ProRefStatus.fetched;
        return true;
      }
    }
    // 再找标准笔记：笔记正文本身可作为解读来源。
    for (final n in library?.notes ?? const <StandardNote>[]) {
      final t = _matchKey(n.fullTitle);
      if (t.isEmpty) continue;
      if (t.contains(key) || key.contains(t)) {
        ref.filePath = n.filePath;
        ref.source = '知识库';
        ref.status = ProRefStatus.fetched;
        return true;
      }
    }
    return false;
  }

  /// 匹配用的规范化键：去空白与标点，保留中英文与数字（标准编号可对上）。
  static String _matchKey(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\u4e00-\u9fa5]'), '')
      .trim();

  /// 获取一条资料的原文：先匹配知识库；有 url 的下载入文件库。
  /// 成功返回 true 并回填 filePath / status。
  Future<bool> fetchReference(ProReference ref) async {
    if (ref.hasFile) return true;
    if (_matchLibrary(ref)) {
      notifyListeners();
      await _persist();
      return true;
    }
    final url = ref.url.trim();
    if (url.isEmpty) return false;
    final fl = fileLibrary;
    if (fl == null) return false;
    // PDF 直链优先按字节下载；其余网页走 Jina Reader 转 Markdown 保存。
    if (url.toLowerCase().contains('.pdf')) {
      final bytes = await _downloadBytes(url);
      if (bytes != null && _looksLikePdf(bytes)) {
        final rel = await fl.saveDownloaded('${_sanitize(ref.title)}.pdf', bytes);
        ref.filePath = p.join(settings.vaultPath, rel);
        ref.status = ProRefStatus.fetched;
        notifyListeners();
        await _persist();
        return true;
      }
    }
    final md = await _webReader.readMarkdown(url);
    if (md == null || md.trim().isEmpty) return false;
    final rel = await fl.saveDownloaded(
      '${_sanitize(ref.title)}.md',
      Uint8List.fromList(utf8.encode(md)),
    );
    ref.filePath = p.join(settings.vaultPath, rel);
    ref.status = ProRefStatus.fetched;
    notifyListeners();
    await _persist();
    return true;
  }

  Future<Uint8List?> _downloadBytes(String url) async {
    final client = _client = http.Client();
    try {
      final resp = await client
          .get(
            Uri.parse(url),
            headers: {'User-Agent': WebReader.userAgent, 'Accept': '*/*'},
          )
          .timeout(const Duration(seconds: 40));
      if (resp.statusCode != 200) return null;
      return resp.bodyBytes.length < 1024 ? null : resp.bodyBytes;
    } catch (_) {
      return null;
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  static bool _looksLikePdf(Uint8List bytes) {
    final limit = bytes.length < 1024 ? bytes.length - 3 : 1024;
    for (var i = 0; i < limit; i++) {
      if (bytes[i] == 0x25 &&
          bytes[i + 1] == 0x50 &&
          bytes[i + 2] == 0x44 &&
          bytes[i + 3] == 0x46) {
        return true;
      }
    }
    return false;
  }

  static const _refImageExt = {'jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'};

  static bool _isImagePath(String path) =>
      _refImageExt.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

  /// 把 filePath 解析为绝对路径（下载入库时存的是相对知识库根的路径）。
  String _resolveRefPath(ProReference ref) {
    final fp = ref.filePath.trim();
    if (fp.isEmpty) return '';
    if (p.isAbsolute(fp)) return fp;
    return p.joinAll([settings.vaultPath, ...fp.split(RegExp(r'[\\/]'))]);
  }

  /// 解读一条已有原文的资料：抽取正文（图片走 vision 读图），
  /// 生成「适用范围 / 核心要点 / 可引用条款」解读，供成文注入。
  Future<void> digestReference(ProReference ref) async {
    final book = current;
    if (book == null) return;
    final path = _resolveRefPath(ref);
    if (path.isEmpty || !await File(path).exists()) {
      throw Exception('原文文件不存在，请先获取原文');
    }
    final digestUser =
        '''
这是为专业书《${book.title}》（${book.industry.label}行业，${book.bookType.label}）收集的参考资料。
资料名称：${ref.title}
用途说明：${ref.note.isEmpty ? '（未填写）' : ref.note}

请解读这份资料，输出简洁的 Markdown（总长不超过 600 字），结构：
## 适用范围
（这份资料规定/阐述了什么、适用于什么场景，2-3 句）
## 核心要点
（列出写书时最可能引用的 4-8 条关键内容；标准类资料给出准确的条款要点与编号；样题类归纳题型与考点；截图类描述界面与操作流程）
## 引用口径
（写作引用它时应使用的准确名称/编号/版本，避免误引）

只依据资料本身，不要编造。''';
    String digest;
    if (_isImagePath(path)) {
      final bytes = await File(path).readAsBytes();
      final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
      final mime = ext == 'png' ? 'image/png' : 'image/jpeg';
      digest = await _chat([
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': digestUser},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:$mime;base64,${base64Encode(bytes)}'},
            },
          ],
        },
      ], role: ModelRole.vision);
    } else {
      final text = await _refText(path);
      if (text.trim().isEmpty) {
        throw Exception('未能从原文中提取到文字（可能是扫描件或不支持的格式）');
      }
      digest = await _chat([
        {'role': 'system', 'content': '你是严谨的专业资料解读编辑。只输出 Markdown 正文，不要解释。'},
        {'role': 'user', 'content': '$digestUser\n\n资料正文：\n${_clip(text, 14000)}'},
      ]);
    }
    if (digest.trim().isEmpty) throw Exception('模型未返回解读');
    ref.digest = digest.trim();
    ref.status = ProRefStatus.digested;
    book.updatedAt = DateTime.now();
    notifyListeners();
    await _persist();
  }

  /// 从资料原文文件中抽取文本。支持 pdf / md / txt / html。
  Future<String> _refText(String path) async {
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    if (ext == 'pdf') {
      return _pdfText(await File(path).readAsBytes());
    }
    if (const {'md', 'markdown', 'txt', 'json', 'csv'}.contains(ext)) {
      return File(path).readAsString();
    }
    if (const {'html', 'htm'}.contains(ext)) {
      final raw = await File(path).readAsString();
      // 粗略去标签取正文。
      return raw
          .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '')
          .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    return '';
  }

  /// 批量：对所有启用的资料，逐条获取原文并解读。
  Future<void> fetchAndDigestAll() async {
    final book = current;
    if (book == null || busy) return;
    final targets = book.references
        .where((r) => r.enabled && r.title.trim().isNotEmpty)
        .toList();
    if (targets.isEmpty) {
      stage = '没有可处理的资料';
      notifyListeners();
      return;
    }
    _begin('正在获取并解读资料…');
    try {
      var fetched = 0, digested = 0, failed = 0;
      for (var i = 0; i < targets.length; i++) {
        if (_cancel) break;
        final ref = targets[i];
        stage = '（${i + 1}/${targets.length}）${ref.title}';
        notifyListeners();
        try {
          if (!ref.hasFile) {
            if (await fetchReference(ref)) fetched++;
          }
          if (ref.hasFile && !ref.hasDigest) {
            await digestReference(ref);
            digested++;
          }
          if (!ref.hasFile) failed++;
        } catch (_) {
          failed++;
        }
      }
      stage = _cancel
          ? '已停止'
          : '完成：新获取 $fetched 份原文，解读 $digested 份'
              '${failed > 0 ? '，$failed 份未能获取（可编辑补充链接后重试）' : ''}';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '获取解读失败：$e';
    } finally {
      _end();
    }
  }

  /// 单条「获取原文 + 解读」，供资料行上的按钮调用。
  Future<void> fetchAndDigestOne(ProReference ref) async {
    if (current == null || busy) return;
    _begin('正在处理：${ref.title}…');
    try {
      if (!ref.hasFile && !await fetchReference(ref)) {
        stage = '未能获取原文：请在知识库引入该资料，或编辑资料补充链接';
        return;
      }
      await digestReference(ref);
      stage = '已解读：${ref.title}';
    } catch (e) {
      stage = _cancel ? '已停止' : '解读失败：$e';
    } finally {
      _end();
    }
  }

  /// 分模块上传参考文件（模拟样题、系统截图等）：
  /// 复制到本书私有 refs 目录，登记为「上传」资料并自动解读。
  Future<void> uploadReferenceFiles(
    List<String> paths, {
    String chapterId = '',
  }) async {
    final book = current;
    if (book == null || busy || paths.isEmpty) return;
    _begin('正在导入参考文件…');
    try {
      final dir = _refsDir(book);
      await dir.create(recursive: true);
      final added = <ProReference>[];
      for (final src in paths) {
        final name = p.basename(src);
        var dest = p.join(dir.path, name);
        if (await File(dest).exists()) {
          dest = p.join(
            dir.path,
            '${p.basenameWithoutExtension(name)}'
            '_${DateTime.now().millisecondsSinceEpoch}${p.extension(name)}',
          );
        }
        await File(src).copy(dest);
        final ref = ProReference(
          id: '${DateTime.now().microsecondsSinceEpoch}_${added.length}',
          title: p.basenameWithoutExtension(name),
          source: '上传',
          chapterId: chapterId,
          filePath: dest,
          status: ProRefStatus.fetched,
        );
        book.references.add(ref);
        added.add(ref);
      }
      book.updatedAt = DateTime.now();
      notifyListeners();
      await _persist();
      // 逐份解读（失败不阻断其余文件）。
      var digested = 0;
      for (var i = 0; i < added.length; i++) {
        if (_cancel) break;
        stage = '正在解读（${i + 1}/${added.length}）：${added[i].title}…';
        notifyListeners();
        try {
          await digestReference(added[i]);
          digested++;
        } catch (_) {}
      }
      stage = _cancel
          ? '已停止'
          : '已上传 ${added.length} 份参考，解读 $digested 份';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '导入参考文件失败：$e';
    } finally {
      _end();
    }
  }

  void addReference({
    String title = '',
    String source = '手动',
    String chapterId = '',
  }) {
    final book = current;
    if (book == null) return;
    book.references.add(
      ProReference(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: title,
        source: _normalizeSource(source),
        chapterId: chapterId,
      ),
    );
    book.updatedAt = DateTime.now();
    notifyListeners();
    _persist();
  }

  void removeReference(ProReference ref) {
    current?.references.remove(ref);
    current?.updatedAt = DateTime.now();
    // 上传到本书私有目录的文件一并删除。
    if (ref.source == '上传' && ref.filePath.isNotEmpty) {
      try {
        File(ref.filePath).deleteSync();
      } catch (_) {}
    }
    notifyListeners();
    _persist();
  }

  void toggleReference(ProReference ref, bool enabled) {
    ref.enabled = enabled;
    current?.updatedAt = DateTime.now();
    notifyListeners();
    _persist();
  }

  void setReferenceChapter(ProReference ref, String chapterId) {
    ref.chapterId = chapterId;
    current?.updatedAt = DateTime.now();
    notifyListeners();
    _persist();
  }

  // ---------------------------------------------------------------------------
  // ④ 成文：逐节生成正文（携带立项 + 资料 + 术语 + 大纲做上下文）
  // ---------------------------------------------------------------------------

  Future<void> writeAll() async {
    final book = current;
    if (book == null || busy) return;
    if (book.chapters.isEmpty) {
      stage = '请先生成大纲';
      notifyListeners();
      return;
    }
    _begin('正在准备逐节写作…');
    try {
      final total = book.totalSections;
      var done = 0;
      for (final chapter in book.chapters) {
        for (final section in chapter.sections) {
          if (_cancel) break;
          done++;
          activeSection = section;
          section.content = '';
          stage = '正在写：${section.title}（$done/$total）…';
          notifyListeners();
          section.content = await _streamSection(book, chapter, section);
          book.updatedAt = DateTime.now();
          await _persist();
          if (section.hasContent && !_cancel) {
            await _consolidate(book, chapter, section);
          }
        }
        if (_cancel) break;
      }
      stage = _cancel ? '已停止' : '全书初稿已完成';
    } catch (e) {
      stage = _cancel ? '已停止' : '写作失败：$e';
    } finally {
      _end();
      await _persist();
    }
  }

  Future<void> writeSection(ProSection section) async {
    final book = current;
    if (book == null || busy) return;
    final chapter = _chapterOf(section);
    if (chapter == null) return;
    _begin('正在写：${section.title}…');
    try {
      activeSection = section;
      section.content = '';
      section.content = await _streamSection(book, chapter, section);
      book.updatedAt = DateTime.now();
      await _persist();
      if (section.hasContent && !_cancel) {
        await _consolidate(book, chapter, section);
      }
      stage = _cancel ? '已停止' : '本节已完成';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '写作失败：$e';
    } finally {
      _end();
    }
  }

  Future<String> _streamSection(
    ProBook book,
    ProChapter chapter,
    ProSection section,
  ) async {
    // 写前从本书知识记忆库召回与本节相关的已确立事实（标准条款/术语/口径）。
    final canon = await _recallCanon(book, chapter, section);
    var acc = '';
    await for (final delta in _streamChat([
      {
        'role': 'system',
        'content':
            '你是资深「${book.industry.label}」行业专业作者，正在写一本${book.bookType.label}。'
                '直接输出本小节的 Markdown 正文，不要解释、不要代码围栏、不要重复小节标题。',
      },
      {
        'role': 'user',
        'content': _sectionPrompt(book, chapter, section, canon),
      },
    ])) {
      if (_cancel) break;
      acc += delta;
      section.content = acc;
      notifyListeners();
    }
    return acc.trim();
  }

  /// 全书按大纲顺序展开的小节列表（滚动上下文用）。
  static List<ProSection> _flatSections(ProBook book) => [
    for (final c in book.chapters) ...c.sections,
  ];

  /// 当前节之前最近几节的纪要（防重复、保证承接）。
  String _recentRecaps(ProBook book, ProSection section, {int take = 3}) {
    final flat = _flatSections(book);
    final idx = flat.indexOf(section);
    if (idx <= 0) return '';
    final buf = <String>[];
    for (var i = idx - 1; i >= 0 && buf.length < take; i--) {
      final s = flat[i];
      if (s.recap.trim().isEmpty) continue;
      buf.insert(0, '- ${s.title}：${s.recap.trim()}');
    }
    return buf.join('\n');
  }

  /// 上一个已写小节的结尾片段（自然衔接、避免换口气）。
  String _prevSectionTail(ProBook book, ProSection section, {int chars = 600}) {
    final flat = _flatSections(book);
    final idx = flat.indexOf(section);
    for (var i = idx - 1; i >= 0; i--) {
      final content = flat[i].content.trim();
      if (content.isEmpty) continue;
      return content.length <= chars
          ? content
          : content.substring(content.length - chars);
    }
    return '';
  }

  /// 本章可用的参考资料：已解读的注入 digest 全文，未解读的仅列名称。
  String _sectionRefsBlock(ProBook book, ProChapter chapter) {
    final refs = book.references
        .where(
          (r) =>
              r.enabled &&
              r.title.trim().isNotEmpty &&
              (r.chapterId.isEmpty || r.chapterId == chapter.id),
        )
        .toList();
    if (refs.isEmpty) return '（暂无登记资料）';
    final buf = StringBuffer();
    for (final r in refs.where((e) => e.hasDigest)) {
      buf
        ..writeln('### ${r.title}（${r.source}${r.note.isEmpty ? '' : '｜${r.note}'}）')
        ..writeln(_clip(r.digest.trim(), 1600))
        ..writeln();
    }
    final undigested = refs.where((e) => !e.hasDigest).toList();
    if (undigested.isNotEmpty) {
      buf
        ..writeln('（下列资料尚未解读，只知其名，引用需谨慎、不得虚构其内容）')
        ..writeln(
          undigested.map((r) => '- [${r.source}] ${r.title}｜${r.note}').join('\n'),
        );
    }
    return buf.toString().trim();
  }

  String _sectionPrompt(
    ProBook book,
    ProChapter chapter,
    ProSection section,
    String canon,
  ) {
    final glossary = book.glossary.isEmpty
        ? '（暂无术语表）'
        : book.glossary.map((t) => '- ${t.term}：${t.definition}').join('\n');
    final recaps = _recentRecaps(book, section);
    final prevTail = _prevSectionTail(book, section);
    final refsBlock = _sectionRefsBlock(book, chapter);
    return '''
你正在为《${book.title}》写「${section.title}」这一小节。

== 全书定位 ==
${book.industry.guidance}
书籍类型：${book.bookType.label}（${book.bookType.guidance}）
读者定位：${book.readerPositioning}
核心价值：${book.valueProposition}

== 写作台账（已写内容概况，避免重复、保持口径一致）==
${book.bookState.trim().isEmpty ? '（本节是全书最早写的内容之一）' : book.bookState.trim()}

== 最近几节纪要 ==
${recaps.isEmpty ? '（无）' : recaps}

== 上一节结尾（衔接参考）==
${prevTail.isEmpty ? '（无）' : prevTail}

== 与本节相关的已确立事实（须保持一致，不得矛盾）==
${canon.isEmpty ? '（无）' : canon}

== 本章可用参考资料解读 ==
$refsBlock

== 所在章与本节 ==
所在章：${chapter.title}（${chapter.brief}）
当前要写的小节：${section.title}
本节写作要点：${section.brief}

== 应保持一致的关键术语 ==
$glossary

要求：
- 内容专业、准确、可读，符合该行业规范与最佳实践。
- 引用标准、法规、文献时，只使用上面「参考资料解读」和「已确立事实」中给出的准确名称、编号与条款；未出现过的编号一律不得编造，可用「相关标准」等泛称。
- 不要重复前文已充分展开的内容；需要呼应时用一句话带过并写"（详见前文相关章节）"。
- 与全书风格一致；术语用法与上面的术语表保持一致。
- 凡是用图或表能让读者更易理解之处（如流程、结构、对比、参数、分类），**必须预留占位符**，单独成行，格式严格如下（不要伪造图片或编造数据）：
  - 图：`> 【待补充图】图题与应展示内容的说明`
  - 表：`> 【待补充表】表题与应包含的列/内容说明`
- 只输出本小节正文，使用清晰的 Markdown。''';
  }

  // ---------------------------------------------------------------------------
  // 写作连贯记忆（参照小说模块：常驻台账 + 结构化知识库 + 小模型按需召回）
  // ---------------------------------------------------------------------------

  /// 写本节前，用小模型从「知识记忆库」挑出与本节相关的已确立事实。
  Future<String> _recallCanon(
    ProBook book,
    ProChapter chapter,
    ProSection section,
  ) async {
    try {
      final store = _canon(book);
      final headers = await store.scanHeaders();
      if (headers.isEmpty) return '';
      final query = '${chapter.title} ${section.title}。${section.brief}';
      final selected = await _selector.select(
        query: query,
        headers: headers,
        manifest: store.formatManifest(headers),
        maxResults: 8,
      );
      if (selected.isEmpty) return '';
      final buf = StringBuffer();
      for (final h in selected) {
        final body = await store.readBody(h.filename);
        if (body == null || body.trim().isEmpty) continue;
        buf.writeln('- ${h.name}：${body.trim()}');
      }
      return buf.toString().trim();
    } catch (_) {
      // 召回失败不阻断写作。
      return '';
    }
  }

  /// 写完一节后：归纳本节纪要 → 更新写作台账 → 沉淀关键事实入记忆库。
  Future<void> _consolidate(
    ProBook book,
    ProChapter chapter,
    ProSection section,
  ) async {
    try {
      stage = '归纳本节纪要…';
      notifyListeners();
      final recap = await _chat([
        {'role': 'system', 'content': '你负责为专业书稿做连贯性归档。只输出简洁中文，不要解释。'},
        {
          'role': 'user',
          'content':
              '用120字以内客观概述本节写了什么（覆盖的主题、引用的标准/资料、'
              '给出的关键结论或方法），供后续小节避免重复、保持衔接。只输出概述：\n\n${section.content}',
        },
      ], role: ModelRole.small);
      if (recap.trim().isNotEmpty) section.recap = recap.trim();

      stage = '更新写作台账…';
      notifyListeners();
      final state = await _chat([
        {
          'role': 'system',
          'content': '你在维护一本专业书的"写作台账"，用于保证后续小节口径一致、不重复、不遗漏。',
        },
        {'role': 'user', 'content': _stateUpdatePrompt(book, chapter, section)},
      ]);
      if (state.trim().isNotEmpty) book.bookState = state.trim();

      stage = '沉淀关键事实到记忆库…';
      notifyListeners();
      await _extractCanon(book, section);

      book.updatedAt = DateTime.now();
      await _persist();
    } catch (e) {
      // 连贯性归档失败不影响已写正文。
      stage = '连贯性归档失败（不影响正文）：$e';
      notifyListeners();
    }
  }

  String _stateUpdatePrompt(
    ProBook book,
    ProChapter chapter,
    ProSection section,
  ) =>
      '''
已有写作台账（截至上一节）：
${book.bookState.trim().isEmpty ? '(空，全书刚开始写)' : book.bookState.trim()}

刚完成的小节「${chapter.title} / ${section.title}」纪要：
${section.recap.isEmpty ? section.brief : section.recap}

请输出更新后的写作台账（合并新信息、删除冗余，控制在约 1200 字内），用以下结构：
## 已覆盖的主题与深度
## 术语与表述口径（全书统一用法）
## 已引用的标准 / 法规 / 资料（准确名称与编号）
## 尚未展开、后文需要衔接的点
只输出台账正文，不要解释。''';

  /// 从本节抽取「后文需保持一致」的关键事实（标准条款、定义、数据、口径），
  /// 去重后写入本书知识记忆库。
  Future<void> _extractCanon(ProBook book, ProSection section) async {
    final store = _canon(book);
    final headers = await store.scanHeaders();
    final manifest = store.formatManifest(headers);
    final reply = await _chat([
      {
        'role': 'system',
        'content': '你负责从专业书稿中抽取需长期保持一致的"关键事实"，建立全书知识底账。只输出 JSON。',
      },
      {
        'role': 'user',
        'content':
            '''
从本节正文中抽取「后续小节必须保持一致」的关键事实（引用的标准/法规的准确名称与编号、术语定义、关键数据与参数、流程步骤的固定表述、易错点）。

去重：下面是已有事实清单，若只是重复或补充已有项，请用 update 指向其文件名，不要新建近似项：
${manifest.isEmpty ? '(空)' : manifest}

严格输出 JSON：
{"facts":[{"type":"project|reference","name":"<=10字短标题","description":"一句话索引","body":"具体内容","update":"可选,要更新的文件名"}]}
（type：project=定义/口径/数据等事实，reference=标准/法规/资料的引用信息；没有可记的就 {"facts":[]}）

本节正文：
${_clip(section.content, 8000)}''',
      },
    ], jsonMode: true, role: ModelRole.small);
    final m = _parseJson(reply);
    final facts = (m['facts'] as List?) ?? [];
    for (final f in facts.whereType<Map>()) {
      final name = (f['name'] ?? '').toString().trim();
      final body = (f['body'] ?? '').toString().trim();
      if (name.isEmpty || body.isEmpty) continue;
      final type = parseMemoryType(f['type']?.toString()) ?? MemoryType.project;
      final update = (f['update'] ?? '').toString().trim();
      await store.save(
        name: name,
        description: (f['description'] ?? '').toString().trim(),
        type: type,
        body: body,
        filename: update.isEmpty ? null : update,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // ⑤ 审校：术语一致性 + 准确性检查（生成术语表与审校结论）
  // ---------------------------------------------------------------------------

  Future<void> review() async {
    final book = current;
    if (book == null || busy) return;
    if (book.doneSections == 0) {
      stage = '请先生成正文再审校';
      notifyListeners();
      return;
    }
    _begin('正在审校：术语一致性与内容准确性…');
    try {
      final figs = figureCount;
      final tabs = tableCount;
      final reply = await _chat([
        {
          'role': 'system',
          'content': '你是严谨的专业图书审校。只输出 JSON，不要编造标准条款。',
        },
        {
          'role': 'user',
          'content':
              '''
请审校下面这本「${book.industry.label}」行业专业书的初稿。
${book.industry.guidance}

本书初稿目前包含：图占位 $figs 个、表占位 $tabs 个。

请完成两件事：
1. glossary：提炼全书应统一的关键术语及简明定义。
2. reviewNotes：指出术语不一致、表述不准确、与行业规范/标准不符之处，并给出修改建议（Markdown，分条列出）。
   - ${figs == 0 ? '【重要】全书没有任何图，必须明确指出"全书缺少配图"，并建议在哪些章节补充什么图。' : '检查图是否够用、是否还有该配图却没配的地方。'}
   - ${tabs == 0 ? '【重要】全书没有任何表，必须明确指出"全书缺少表格"，并建议在哪些章节补充什么表。' : '检查表是否够用、是否还有该用表呈现却没用的地方。'}

严格输出 JSON：
{"glossary":[{"term":"术语","definition":"定义"}],"reviewNotes":"## 审校意见\\n- ..."}

书稿正文：
${_clip(_bookBody(book), 18000)}
''',
        },
      ], jsonMode: true);
      final j = _parseJson(reply);
      final rawGlossary = (j['glossary'] as List?) ?? [];
      if (rawGlossary.isNotEmpty) {
        book.glossary = rawGlossary
            .whereType<Map>()
            .map((e) => ProTerm.fromJson(e.cast<String, dynamic>()))
            .where((t) => t.term.trim().isNotEmpty)
            .toList();
      }
      book.reviewNotes = (j['reviewNotes'] ?? '').toString().trim();
      book.updatedAt = DateTime.now();
      stage = '审校完成';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '审校失败：$e';
    } finally {
      _end();
    }
  }

  // ---------------------------------------------------------------------------
  // ⑥ 修订：根据审校意见，逐节自动修订正文（落实术语统一/准确性/补图表）
  // ---------------------------------------------------------------------------

  Future<void> revise() async {
    final book = current;
    if (book == null || busy) return;
    if (book.reviewNotes.trim().isEmpty) {
      stage = '请先审校，再自动修订';
      notifyListeners();
      return;
    }
    if (book.doneSections == 0) {
      stage = '没有可修订的正文';
      notifyListeners();
      return;
    }
    _begin('正在根据审校意见自动修订…');
    try {
      final total = book.doneSections;
      var done = 0;
      for (final chapter in book.chapters) {
        for (final section in chapter.sections) {
          if (!section.hasContent) continue;
          if (_cancel) break;
          done++;
          activeSection = section;
          stage = '正在修订：${section.title}（$done/$total）…';
          notifyListeners();
          // 修订失败/返回空时，保留原文，避免把内容改没了。
          final original = section.content;
          final revised = await _reviseSection(book, chapter, section);
          if (revised.trim().isEmpty) section.content = original;
          book.updatedAt = DateTime.now();
          await _persist();
        }
        if (_cancel) break;
      }
      stage = _cancel ? '已停止' : '已根据审校意见完成修订';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '修订失败：$e';
    } finally {
      _end();
      await _persist();
    }
  }

  Future<String> _reviseSection(
    ProBook book,
    ProChapter chapter,
    ProSection section,
  ) async {
    var acc = '';
    await for (final delta in _streamChat([
      {
        'role': 'system',
        'content':
            '你是资深「${book.industry.label}」行业专业图书编辑，正在按审校意见修订一本${book.bookType.label}。'
                '直接输出修订后的本小节 Markdown 正文，不要解释、不要代码围栏、不要重复小节标题。',
      },
      {'role': 'user', 'content': _revisePrompt(book, chapter, section)},
    ])) {
      if (_cancel) break;
      acc += delta;
      section.content = acc; // 实时回显修订过程
      notifyListeners();
    }
    return acc.trim();
  }

  String _revisePrompt(ProBook book, ProChapter chapter, ProSection section) {
    final glossary = book.glossary.isEmpty
        ? '（无）'
        : book.glossary.map((t) => '- ${t.term}：${t.definition}').join('\n');
    return '''
请根据审校意见，修订下面这本「${book.industry.label}」行业${book.bookType.label}的某一小节。
${book.industry.guidance}
书名：${book.title}
所在章：${chapter.title}
当前小节：${section.title}

全书审校意见（据此修订，只处理与本节相关的问题）：
${book.reviewNotes}

应统一的术语表：
$glossary

本节当前正文：
${section.content}

要求：
- 落实审校意见：修正术语不一致、不准确表述、与行业规范/标准不符之处。
- 若审校建议本节补图/表而当前没有，按固定格式补上占位符（独占一行）：
  - 图：`> 【待补充图】图题与说明`
  - 表：`> 【待补充表】表题与说明`
- 保持本节主旨与结构，不要大幅删减；不得编造数据或标准编号。
- 直接输出修订后的完整本节 Markdown 正文，不要解释。''';
  }

  // ---------------------------------------------------------------------------
  // 补充图表：把某个「待补充图/表」占位符替换成真实内容
  //   - 表：AI 按上下文生成 Markdown 表格
  //   - 图（AI 图表代码）：AI 生成 Mermaid，再用 mermaid.ink 渲染成 PNG
  //   - 图（AI 文生图）：调用设置里的图像模型 /images/generations
  //   - 图（上传）：拷贝本地图片到图片目录
  // 替换后正文里是标准 Markdown（表格 / `![](本地路径)`），预览与 PDF 都能显示。
  // ---------------------------------------------------------------------------

  /// 表：AI 依据本节上下文生成一个 Markdown 表格，替换该占位符。
  Future<void> fillTable(ProPlaceholder ph) async {
    if (current == null || busy) return;
    _begin('正在生成表格…');
    try {
      final reply = await _chat([
        {
          'role': 'system',
          'content': '你是严谨的专业图书编辑。只输出一个标准 Markdown 表格，不要标题、解释或代码围栏。',
        },
        {'role': 'user', 'content': _tablePrompt(current!, ph)},
      ]);
      final table = _extractTable(reply);
      if (table.isEmpty) {
        stage = '未能生成有效表格，请重试';
        return;
      }
      await _replacePlaceholder(ph, table);
      stage = '表格已生成';
    } catch (e) {
      stage = '生成表格失败：$e';
    } finally {
      _end();
    }
  }

  /// 图（AI 图表代码）：AI 生成 Mermaid 代码，经 mermaid.ink 渲染成 PNG 后插入。
  Future<void> fillDiagram(ProPlaceholder ph) async {
    if (current == null || busy) return;
    _begin('正在生成图表代码并渲染…');
    try {
      final reply = await _chat([
        {
          'role': 'system',
          'content': '你是图示专家。只输出 Mermaid 代码本身，第一行是图类型声明，不要解释、不要代码围栏。',
        },
        {'role': 'user', 'content': _diagramPrompt(current!, ph)},
      ]);
      final code = _extractMermaid(reply);
      if (code.isEmpty) {
        stage = '未能生成图表代码，请重试';
        return;
      }
      final bytes = await _renderMermaid(code);
      final path = await _saveImage(bytes, 'png');
      await _replacePlaceholder(ph, _imageMarkdown(ph.description, path));
      stage = '图表已渲染';
    } catch (e) {
      stage = '图表渲染失败：$e';
    } finally {
      _end();
    }
  }

  /// 图（AI 文生图）：调用设置里的图像模型生成插图后插入。需先在设置里配置图像模型。
  Future<void> fillTextToImage(ProPlaceholder ph) async {
    if (current == null || busy) return;
    if (!settings.imageGenReady) {
      stage = '请先在「设置 → 图像模型」里配置文生图接口';
      notifyListeners();
      return;
    }
    _begin('正在用 AI 生成插图…');
    try {
      final bytes = await _generateImage(_imagePrompt(current!, ph));
      final path = await _saveImage(bytes, 'png');
      await _replacePlaceholder(ph, _imageMarkdown(ph.description, path));
      stage = '插图已生成';
    } catch (e) {
      stage = '文生图失败：$e';
    } finally {
      _end();
    }
  }

  /// 图（上传）：把用户选中的本地图片拷贝进图片目录后插入。
  Future<void> fillUploadImage(ProPlaceholder ph, String sourcePath) async {
    if (current == null || busy) return;
    _begin('正在导入图片…');
    try {
      final bytes = await File(sourcePath).readAsBytes();
      final ext = p.extension(sourcePath).replaceFirst('.', '').toLowerCase();
      final path = await _saveImage(bytes, ext.isEmpty ? 'png' : ext);
      await _replacePlaceholder(ph, _imageMarkdown(ph.description, path));
      stage = '图片已插入';
    } catch (e) {
      stage = '导入图片失败：$e';
    } finally {
      _end();
    }
  }

  /// 用生成好的 Markdown 片段，替换该占位符所在的那一行（按类型+描述精确匹配）。
  Future<void> _replacePlaceholder(ProPlaceholder ph, String replacement) async {
    final section = ph.section;
    final lines = section.content.replaceAll('\r\n', '\n').split('\n');
    final re = ph.isFigure ? _figRe : _tabRe;
    for (var i = 0; i < lines.length; i++) {
      final m = re.firstMatch(lines[i]);
      if (m != null && m.group(1)!.trim() == ph.description) {
        lines[i] = replacement;
        section.content = lines.join('\n');
        current?.updatedAt = DateTime.now();
        await _persist();
        notifyListeners();
        return;
      }
    }
    throw Exception('未找到对应占位符（可能正文已改动），请刷新后重试');
  }

  /// 图片目录：放在应用数据目录下，与 pro_books.json 同级，随书长期保存。
  Future<Directory> _imagesDir() async {
    if (_imageDir != null) return _imageDir!;
    final dir = await getApplicationSupportDirectory();
    final d = Directory(p.join(dir.path, 'pro_book_images'));
    await d.create(recursive: true);
    return _imageDir = d;
  }

  Future<String> _saveImage(Uint8List bytes, String ext) async {
    final dir = await _imagesDir();
    final name =
        '${current!.id}_${DateTime.now().microsecondsSinceEpoch}.$ext';
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// 用 mermaid.ink 把 Mermaid 代码渲染成 PNG（URL-safe base64 编码代码）。
  Future<Uint8List> _renderMermaid(String code) async {
    final b64 = base64Url.encode(utf8.encode(code)).replaceAll('=', '');
    final url = 'https://mermaid.ink/img/$b64?type=png&bgColor=white';
    final client = _client = http.Client();
    try {
      final resp = await client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 40));
      if (resp.statusCode != 200) {
        throw Exception('mermaid.ink 渲染失败 HTTP ${resp.statusCode}');
      }
      return resp.bodyBytes;
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  /// 调用 OpenAI 兼容的图像生成接口，返回 PNG 字节。
  Future<Uint8List> _generateImage(String prompt) async {
    final client = _client = http.Client();
    try {
      final resp = await client
          .post(
            Uri.parse('${settings.imageBaseUrl}/images/generations'),
            headers: {
              'Authorization': 'Bearer ${settings.imageApiKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': settings.imageModel,
              'prompt': prompt,
              'n': 1,
              'size': '1024x1024',
              'response_format': 'b64_json',
            }),
          )
          .timeout(const Duration(seconds: 120));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode} ${utf8.decode(resp.bodyBytes)}');
      }
      final j = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final data = (j['data'] as List?)?.firstOrNull;
      if (data is! Map) throw Exception('图像接口未返回数据');
      // 兼容两种标准返回：b64_json（内联）或 url（需再下载）。
      final b64 = data['b64_json'] as String?;
      if (b64 != null && b64.isNotEmpty) return base64Decode(b64);
      final url = data['url'] as String?;
      if (url != null && url.isNotEmpty) {
        final img = await client
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 60));
        if (img.statusCode != 200) {
          throw Exception('下载生成图片失败 HTTP ${img.statusCode}');
        }
        return img.bodyBytes;
      }
      throw Exception('图像接口未返回 b64_json 或 url');
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  String _tablePrompt(ProBook book, ProPlaceholder ph) => '''
为下面这本「${book.industry.label}」行业${book.bookType.label}补一个表格。
书名：${book.title}
所在章节：${ph.chapter.title} / ${ph.section.title}
表格应表达：${ph.description}
本节正文（供参考，务必与正文一致，不得编造数据或标准编号）：
${_clip(ph.section.content, 4000)}

只输出一个标准 Markdown 表格（含表头行与 |---| 分隔行），不要标题、不要解释、不要代码围栏。''';

  String _diagramPrompt(ProBook book, ProPlaceholder ph) => '''
为下面这本「${book.industry.label}」行业${book.bookType.label}画一张示意图（Mermaid 语法）。
书名：${book.title}
所在章节：${ph.chapter.title} / ${ph.section.title}
图应表达：${ph.description}
本节正文（供参考）：
${_clip(ph.section.content, 3000)}

要求：
- 选最合适的 Mermaid 图类型（flowchart / sequenceDiagram / classDiagram / graph 等）。
- 节点文字用简体中文，简洁准确，不要编造内容。
- 只输出 Mermaid 代码本身，第一行就是图类型声明，不要代码围栏、不要解释。''';

  String _imagePrompt(ProBook book, ProPlaceholder ph) => '''
专业图书插图，用于「${book.industry.label}」行业${book.bookType.label}《${book.title}》。
图题：${ph.description}
风格：简洁、专业、清晰的示意插画，浅色背景，适合书籍印刷；不要包含任何文字或水印。''';

  static String _extractTable(String reply) {
    var s = reply.trim();
    s = s.replaceAll(RegExp(r'```[a-zA-Z]*'), '').trim();
    final lines = s.split('\n').where((l) => l.contains('|')).toList();
    return lines.join('\n').trim();
  }

  static String _extractMermaid(String reply) {
    var s = reply.trim();
    final fence = RegExp(r'```(?:mermaid)?\s*([\s\S]*?)```').firstMatch(s);
    if (fence != null) s = fence.group(1)!.trim();
    return s.trim();
  }

  /// 图片 alt 文本：去掉会破坏 Markdown 链接语法的字符。
  static String _altText(String s) =>
      s.replaceAll(RegExp(r'[\[\]()\n]'), ' ').trim();

  /// 生成插入正文的图片 Markdown。用 file:// URI，预览与 PDF 都能稳定解析路径。
  static String _imageMarkdown(String desc, String path) =>
      '![${_altText(desc)}](${Uri.file(path)})';

  // ---------------------------------------------------------------------------
  // ⑥ 导出为 Markdown（写入知识库根下「4-书稿/专业书籍」目录）
  // ---------------------------------------------------------------------------

  /// 导出：按出书规范用 LaTeX(ctexbook) 排版生成 PDF（同时保留一份 Markdown）。
  /// 返回 PDF 路径。需要本机已安装 xelatex（MiKTeX / TeX Live）。
  Future<String> export() async {
    final book = current;
    if (book == null) throw StateError('未打开书籍');
    final dir = Directory(p.join(settings.vaultPath, '4-书稿', '专业书籍'));
    await dir.create(recursive: true);
    final base = _sanitize(book.title);
    // 先写 Markdown（便于快速查看 / 二次编辑）。
    await File(p.join(dir.path, '$base.md')).writeAsString(_renderMarkdown(book));
    // 再编译 PDF（出书排版）。
    final pdf = File(p.join(dir.path, '$base.pdf'));
    await compileLatexPdf(
      tex: _renderLatexDocument(book),
      output: pdf,
      jobName: 'pro_book',
    );
    await openExportDirectory(dir.path);
    return pdf.path;
  }

  String _renderMarkdown(ProBook book) {
    final buf = StringBuffer()
      ..writeln('# ${book.title}')
      ..writeln()
      ..writeln('- 行业：${book.industry.label}')
      ..writeln('- 类型：${book.bookType.label}');
    if (book.audience.isNotEmpty) buf.writeln('- 目标读者：${book.audience}');
    if (book.readerPositioning.isNotEmpty) {
      buf.writeln('- 读者定位：${book.readerPositioning}');
    }
    if (book.valueProposition.isNotEmpty) {
      buf.writeln('- 核心价值：${book.valueProposition}');
    }
    buf
      ..writeln(
        '- 进度：约 ${book.totalWords} 字 · ${book.doneSections}/${book.totalSections} 节',
      )
      ..writeln();
    for (final chapter in book.chapters) {
      buf
        ..writeln('## ${chapter.title}')
        ..writeln();
      for (final section in chapter.sections) {
        buf
          ..writeln('### ${section.title}')
          ..writeln()
          ..writeln(section.content.trim().isEmpty ? '（待撰写）' : section.content.trim())
          ..writeln();
      }
    }
    if (book.references.isNotEmpty) {
      buf
        ..writeln('## 参考资料')
        ..writeln();
      for (final r in book.references.where((e) => e.title.isNotEmpty)) {
        buf.writeln('- [${r.source}] ${r.title}${r.url.isEmpty ? '' : '（${r.url}）'}');
      }
      buf.writeln();
    }
    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // LaTeX 排版：ctexbook（章/节自动编号 + 目录），正文 Markdown 转 LaTeX。
  // ---------------------------------------------------------------------------

  String _renderLatexDocument(ProBook book) {
    final buf = StringBuffer()
      ..writeln(r'\documentclass[11pt,a4paper]{ctexbook}')
      ..writeln(r'\usepackage{geometry}')
      ..writeln(r'\geometry{margin=2.5cm}')
      ..writeln(r'\usepackage{graphicx}')
      ..writeln(r'\usepackage{enumitem}')
      ..writeln(r'\usepackage[hidelinks]{hyperref}')
      ..writeln(r'\linespread{1.4}')
      ..writeln('\\title{${_tex(book.title)}}')
      ..writeln(r'\author{}')
      ..writeln(r'\date{}')
      ..writeln(r'\begin{document}')
      ..writeln(r'\maketitle')
      ..writeln(r'\tableofcontents')
      ..writeln();
    for (final chapter in book.chapters) {
      buf
        ..writeln('\\chapter{${_tex(_stripNum(chapter.title))}}')
        ..writeln();
      for (final section in chapter.sections) {
        buf
          ..writeln('\\section{${_tex(_stripNum(section.title))}}')
          ..writeln();
        final body = _contentToLatex(section.content, section.title);
        buf
          ..writeln(body.isEmpty ? '（待撰写）' : body)
          ..writeln();
      }
    }
    if (book.references.any((r) => r.title.isNotEmpty)) {
      buf
        ..writeln(r'\chapter*{参考资料}')
        ..writeln(r'\addcontentsline{toc}{chapter}{参考资料}')
        ..writeln(r'\begin{itemize}');
      for (final r in book.references.where((e) => e.title.isNotEmpty)) {
        buf.writeln('\\item [${_tex(r.source)}] ${_tex(r.title)}');
      }
      buf.writeln(r'\end{itemize}');
    }
    buf.writeln(r'\end{document}');
    return buf.toString();
  }

  /// 把一节的 Markdown 正文转成 LaTeX 片段。图/表占位符渲染成带框提示块。
  String _contentToLatex(String content, String sectionTitle) {
    final buf = StringBuffer();
    final para = <String>[];
    String? list; // 'itemize' | 'enumerate'
    void flushPara() {
      if (para.isEmpty) return;
      buf
        ..writeln(_inlineToLatex(para.join('')))
        ..writeln();
      para.clear();
    }

    void closeList() {
      if (list == null) return;
      buf.writeln('\\end{$list}');
      list = null;
    }

    final lines = content.replaceAll('\r\n', '\n').split('\n');
    for (var idx = 0; idx < lines.length; idx++) {
      final line = lines[idx].trim();
      if (line.isEmpty) {
        flushPara();
        closeList();
        continue;
      }
      // 图片 ![alt](path)：居中插入。
      final img = RegExp(r'^!\[(.*?)\]\((.+?)\)\s*$').firstMatch(line);
      if (img != null) {
        flushPara();
        closeList();
        buf.writeln(_imageToLatex(img.group(2)!.trim()));
        continue;
      }
      // Markdown 表格：连续的 | 开头行组成一个表格块。
      if (line.startsWith('|')) {
        flushPara();
        closeList();
        final block = <String>[];
        var j = idx;
        while (j < lines.length && lines[j].trim().startsWith('|')) {
          block.add(lines[j].trim());
          j++;
        }
        final table = _tableToLatex(block);
        if (table.isNotEmpty) buf.writeln(table);
        idx = j - 1;
        continue;
      }
      final fig = RegExp(r'^>\s*【待补充图】\s*(.*)').firstMatch(line);
      if (fig != null) {
        flushPara();
        closeList();
        buf.writeln(_placeholderBox('图', fig.group(1)!.trim()));
        continue;
      }
      final tab = RegExp(r'^>\s*【待补充表】\s*(.*)').firstMatch(line);
      if (tab != null) {
        flushPara();
        closeList();
        buf.writeln(_placeholderBox('表', tab.group(1)!.trim()));
        continue;
      }
      final heading = RegExp(r'^(#{1,6})\s+(.*)').firstMatch(line);
      if (heading != null) {
        flushPara();
        closeList();
        final title = heading.group(2)!.trim();
        // 跳过与本节标题重复的开头 ## 标题（模型常重复一遍）。
        if (_norm(title) == _norm(sectionTitle)) continue;
        final cmd = heading.group(1)!.length <= 2
            ? 'subsection'
            : 'subsubsection';
        buf
          ..writeln('\\$cmd{${_tex(_stripNum(title))}}')
          ..writeln();
        continue;
      }
      final quote = RegExp(r'^>\s+(.*)').firstMatch(line);
      if (quote != null) {
        flushPara();
        closeList();
        buf
          ..writeln(r'\begin{quote}')
          ..writeln(_inlineToLatex(quote.group(1)!.trim()))
          ..writeln(r'\end{quote}');
        continue;
      }
      final bullet = RegExp(r'^[-*+]\s+(.*)').firstMatch(line);
      if (bullet != null) {
        flushPara();
        if (list != 'itemize') {
          closeList();
          buf.writeln(r'\begin{itemize}');
          list = 'itemize';
        }
        buf.writeln('\\item ${_inlineToLatex(bullet.group(1)!.trim())}');
        continue;
      }
      final numbered = RegExp(r'^\d+[.)、]\s+(.*)').firstMatch(line);
      if (numbered != null) {
        flushPara();
        if (list != 'enumerate') {
          closeList();
          buf.writeln(r'\begin{enumerate}');
          list = 'enumerate';
        }
        buf.writeln('\\item ${_inlineToLatex(numbered.group(1)!.trim())}');
        continue;
      }
      closeList();
      para.add(line);
    }
    flushPara();
    closeList();
    return buf.toString().trim();
  }

  String _placeholderBox(String kind, String desc) =>
      '\\begin{center}\\fbox{\\parbox{0.9\\linewidth}{\\centering 【待补充$kind】 ${_tex(desc)}}}\\end{center}';

  /// 图片转 LaTeX：居中、限制最大尺寸、保持比例。
  /// 正文里图片以 file:// URI 保存，这里还原成本地路径并用正斜杠（xelatex 友好）。
  String _imageToLatex(String src) {
    var path = src;
    final uri = Uri.tryParse(src);
    if (uri != null && uri.scheme == 'file') {
      path = uri.toFilePath(windows: Platform.isWindows);
    }
    final fixed = path.replaceAll(r'\', '/');
    return '\\begin{center}\\includegraphics[width=0.85\\linewidth,'
        'height=0.45\\textheight,keepaspectratio]{$fixed}\\end{center}';
  }

  /// Markdown 表格块转 LaTeX tabular（首行作表头加粗，跳过 |---| 分隔行）。
  String _tableToLatex(List<String> rows) {
    final cells = <List<String>>[];
    for (final r in rows) {
      var t = r.trim();
      if (t.startsWith('|')) t = t.substring(1);
      if (t.endsWith('|')) t = t.substring(0, t.length - 1);
      final parts = t.split('|').map((e) => e.trim()).toList();
      // 分隔行（仅由 - : 组成）跳过。
      if (parts.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c))) continue;
      cells.add(parts);
    }
    if (cells.isEmpty) return '';
    final cols = cells.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    final colSpec = List.filled(cols, 'l').join('|');
    final sb = StringBuffer()
      ..writeln(r'\begin{center}')
      ..writeln('\\begin{tabular}{|$colSpec|}')
      ..writeln(r'\hline');
    for (var i = 0; i < cells.length; i++) {
      final row = List<String>.from(cells[i]);
      while (row.length < cols) {
        row.add('');
      }
      final rendered = row
          .map((c) => i == 0
              ? '\\textbf{${_inlineToLatex(c)}}'
              : _inlineToLatex(c))
          .join(' & ');
      sb
        ..writeln('$rendered \\\\')
        ..writeln(r'\hline');
    }
    sb
      ..writeln(r'\end{tabular}')
      ..writeln(r'\end{center}');
    return sb.toString();
  }

  String _inlineToLatex(String s) {
    var t = _tex(s);
    // 加粗 **x** → \textbf{x}；行内代码 `x` → \texttt{x}。
    t = t.replaceAllMapped(
      RegExp(r'\*\*(.+?)\*\*'),
      (m) => '\\textbf{${m.group(1)}}',
    );
    t = t.replaceAllMapped(
      RegExp(r'`(.+?)`'),
      (m) => '\\texttt{${m.group(1)}}',
    );
    return t;
  }

  /// 转义 LaTeX 特殊字符（在加粗/代码替换之前调用，* 与 ` 不转义以便后续处理）。
  static String _tex(String s) {
    final b = StringBuffer();
    for (final r in s.runes) {
      final c = String.fromCharCode(r);
      b.write(switch (c) {
        '\\' => r'\textbackslash{}',
        '&' => r'\&',
        '%' => r'\%',
        r'$' => r'\$',
        '#' => r'\#',
        '_' => r'\_',
        '{' => r'\{',
        '}' => r'\}',
        '~' => r'\textasciitilde{}',
        '^' => r'\textasciicircum{}',
        _ => c,
      });
    }
    return b.toString();
  }

  static String _norm(String s) => s.replaceAll(RegExp(r'\s'), '');

  /// 去掉标题开头的编号（如「第1章」「1.1」），交给 LaTeX 自动编号。
  static String _stripNum(String s) => s
      .trim()
      .replaceFirst(RegExp(r'^第\s*[0-9一二三四五六七八九十百零]+\s*[章篇节]\s*'), '')
      .replaceFirst(RegExp(r'^\d+(?:\.\d+)*[、.\s]+'), '')
      .trim();

  void cancel() {
    if (!busy) return;
    _cancel = true;
    stage = '正在停止…';
    try {
      _client?.close();
    } catch (_) {}
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  ProChapter? _chapterOf(ProSection section) {
    for (final c in current?.chapters ?? const <ProChapter>[]) {
      if (c.sections.contains(section)) return c;
    }
    return null;
  }

  String _outlineText(ProBook book) {
    final buf = StringBuffer();
    for (final c in book.chapters) {
      buf.writeln('${c.title}：${c.brief}');
      for (final s in c.sections) {
        buf.writeln('  - ${s.title}：${s.brief}');
      }
    }
    return buf.toString().trim();
  }

  String _bookBody(ProBook book) {
    final buf = StringBuffer();
    for (final c in book.chapters) {
      buf.writeln('# ${c.title}');
      for (final s in c.sections) {
        buf
          ..writeln('## ${s.title}')
          ..writeln(s.content.trim());
      }
    }
    return buf.toString().trim();
  }

  static String _normalizeSource(String s) {
    final v = s.trim();
    if (v.contains('知识库')) return '知识库';
    if (v.contains('上传')) return '上传';
    if (v.contains('网')) return '网页';
    return '手动';
  }

  void _begin(String message) {
    busy = true;
    _cancel = false;
    stage = message;
    notifyListeners();
  }

  void _end() {
    busy = false;
    _cancel = false;
    _client = null;
    notifyListeners();
  }

  Future<void> _persist() async {
    if (_store == null) return;
    try {
      await _store!.writeAsString(
        jsonEncode(books.map((b) => b.toJson()).toList()),
      );
    } catch (_) {}
  }

  /// 统一走 [ModelClient]（超时/取消/SSE 解析集中管理）。默认写作通道，
  /// 廉价任务可传 [role] = small，读图传 vision。
  Future<String> _chat(
    List<Map<String, dynamic>> messages, {
    bool jsonMode = false,
    ModelRole role = ModelRole.writing,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final content = await ModelClient(settings, role: role).complete(
      messages: messages,
      jsonMode: jsonMode,
      isCancelled: () => _cancel,
      timeout: timeout,
    );
    if (content.isEmpty) throw Exception('模型未返回内容');
    return content;
  }

  Stream<String> _streamChat(List<Map<String, dynamic>> messages) {
    final controller = StreamController<String>();
    () async {
      try {
        await ModelClient(settings, role: ModelRole.writing).stream(
          messages: messages,
          onTextDelta: (delta) {
            if (!controller.isClosed) controller.add(delta);
          },
          isCancelled: () => _cancel,
          timeout: const Duration(minutes: 10),
        );
      } catch (e) {
        if (!controller.isClosed) controller.addError(e);
      } finally {
        await controller.close();
      }
    }();
    return controller.stream;
  }

  Map<String, dynamic> _parseJson(String reply) {
    final start = reply.indexOf('{');
    final end = reply.lastIndexOf('}');
    if (start < 0 || end <= start) throw Exception('模型未返回 JSON');
    return jsonDecode(reply.substring(start, end + 1)) as Map<String, dynamic>;
  }

  static String _clip(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);

  static String _sanitize(String value) {
    var out = value.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    if (out.length > 80) out = out.substring(0, 80).trim();
    return out.isEmpty ? '未命名书稿' : out;
  }
}
