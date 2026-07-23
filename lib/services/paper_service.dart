import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import '../util/text_util.dart';
import 'agent/model_client.dart';
import 'project_doc_service.dart';
import 'project_service.dart';
import 'ripgrep.dart';
import 'settings_service.dart';

enum PaperFormat {
  markdown,
  latex;

  String get label => switch (this) {
    PaperFormat.markdown => 'Markdown',
    PaperFormat.latex => 'LaTeX',
  };

  String get extension => switch (this) {
    PaperFormat.markdown => 'md',
    PaperFormat.latex => 'tex',
  };

  static PaperFormat fromJson(String? value) => switch (value) {
    'latex' => PaperFormat.latex,
    _ => PaperFormat.markdown,
  };
}

/// 写稿 / 审校 / 导出的目标语种。
enum PaperLang {
  zh,
  en,
  both;

  bool get writeZh => this == PaperLang.zh || this == PaperLang.both;
  bool get writeEn => this == PaperLang.en || this == PaperLang.both;
}

/// 论文中的一张图（由 matplotlib 出图并保存高清 PNG，中英稿共用同一张图）。
class PaperFigure {
  PaperFigure({
    required this.id,
    required this.kind,
    required this.titleZh,
    required this.titleEn,
    this.captionZh = '',
    this.captionEn = '',
    this.pngPath = '',
    this.section = '',
  });

  final String id;

  /// flow / bar / grouped_bar / line / heatmap / confusion。
  final String kind;
  final String titleZh;
  final String titleEn;
  final String captionZh;
  final String captionEn;

  /// 生成的高清 PNG 原图绝对路径。
  String pngPath;

  /// 归属章节（用于把图插入对应章节）：methods / results / …。
  final String section;

  bool get hasImage => pngPath.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'titleZh': titleZh,
    'titleEn': titleEn,
    'captionZh': captionZh,
    'captionEn': captionEn,
    'pngPath': pngPath,
    'section': section,
  };

  factory PaperFigure.fromJson(Map<String, dynamic> json) => PaperFigure(
    id: json['id'] as String? ?? '',
    kind: json['kind'] as String? ?? 'bar',
    titleZh: json['titleZh'] as String? ?? '',
    titleEn: json['titleEn'] as String? ?? '',
    captionZh: json['captionZh'] as String? ?? '',
    captionEn: json['captionEn'] as String? ?? '',
    pngPath: json['pngPath'] as String? ?? '',
    section: json['section'] as String? ?? '',
  );
}

class PaperSection {
  PaperSection({
    required this.id,
    required this.zhTitle,
    required this.enTitle,
    this.brief = '',
    this.zh = '',
    this.en = '',
  });

  final String id;
  String zhTitle;
  String enTitle;
  String brief;
  String zh;
  String en;

  bool get hasContent => zh.trim().isNotEmpty || en.trim().isNotEmpty;

  int get words =>
      zh.replaceAll(RegExp(r'\s'), '').length +
      en.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'zhTitle': zhTitle,
    'enTitle': enTitle,
    'brief': brief,
    'zh': zh,
    'en': en,
  };

  factory PaperSection.fromJson(Map<String, dynamic> json) => PaperSection(
    id:
        json['id'] as String? ??
        DateTime.now().microsecondsSinceEpoch.toString(),
    zhTitle: json['zhTitle'] as String? ?? '',
    enTitle: json['enTitle'] as String? ?? '',
    brief: json['brief'] as String? ?? '',
    zh: json['zh'] as String? ?? '',
    en: json['en'] as String? ?? '',
  );
}

/// 关联的实验/代码工程（真实工程目录 + 对其的解读摘要）。
class LinkedProject {
  LinkedProject({required this.path, this.digest = ''});

  final String path;

  /// 对该工程的解读摘要（基于真实文件生成），注入方法/实验/相关工作写作。
  String digest;

  String get name => path.isEmpty ? '' : p.basename(path);
  bool get hasDigest => digest.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {'path': path, 'digest': digest};

  factory LinkedProject.fromJson(Map<String, dynamic> json) => LinkedProject(
    path: json['path'] as String? ?? '',
    digest: json['digest'] as String? ?? '',
  );
}

/// 一个由「与工程交互」推荐出的论文选题候选：中英文题目 + 相关信息（研究问题、
/// 创新点、可用的工程支撑、关键词），供用户选择后驱动结构生成与写稿。
class PaperTopicOption {
  PaperTopicOption({
    required this.titleZh,
    required this.titleEn,
    this.summary = '',
  });

  final String titleZh;
  final String titleEn;
  final String summary;

  Map<String, dynamic> toJson() => {
    'titleZh': titleZh,
    'titleEn': titleEn,
    'summary': summary,
  };

  factory PaperTopicOption.fromJson(Map<String, dynamic> json) =>
      PaperTopicOption(
        titleZh: json['titleZh'] as String? ?? '',
        titleEn: json['titleEn'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
      );
}

class PaperDraft {
  PaperDraft({
    required this.id,
    required this.titleZh,
    required this.titleEn,
    required this.format,
    required this.sourceResearchTitle,
    required this.sourceResearchPath,
    required this.sourceBody,
    required this.createdAt,
    required this.updatedAt,
    List<LinkedProject>? linkedProjects,
    List<PaperTopicOption>? topicOptions,
    this.topicBrief = '',
    this.factBaseline = '',
    this.reviewReport = '',
    this.reviewLang = '',
    List<PaperFigure>? figures,
    List<PaperSection>? sections,
  })  : linkedProjects = linkedProjects ?? [],
        topicOptions = topicOptions ?? [],
        figures = figures ?? [],
        sections = sections ?? [];

  final String id;
  String titleZh;
  String titleEn;
  PaperFormat format;
  String sourceResearchTitle;
  String sourceResearchPath;
  String sourceBody;
  final DateTime createdAt;
  DateTime updatedAt;
  List<PaperSection> sections;

  /// 关联的实验/代码工程（可多选），用于解读并把真实实现落地进论文。
  List<LinkedProject> linkedProjects;

  /// 最近一次「与工程交互」推荐出的选题候选（供用户选择）。
  List<PaperTopicOption> topicOptions;

  /// 用户选定选题后的「相关信息」（研究问题/创新点/工程支撑），指导结构生成与写作。
  String topicBrief;

  /// 统一的「研究设定 / 事实基线」（抽象、去标识、全篇自洽），写作前生成，供结构、
  /// 各章节、图表一致地引用，避免像工程解读、避免前后数据矛盾。
  String factBaseline;

  /// 最近一次审校生成的「多专家意见 + 汇总讨论 + 修订清单」（Markdown）。
  String reviewReport;

  /// 审校/润色针对的语种（zh / en）。
  String reviewLang;

  /// 论文配图（matplotlib 生成的高清图，中英稿共用）。
  List<PaperFigure> figures;

  bool get hasLinkedProject => linkedProjects.isNotEmpty;

  /// 所有关联工程的名字（用于顶栏/卡片展示）。
  String get linkedProjectNames =>
      linkedProjects.map((e) => e.name).where((e) => e.isNotEmpty).join('、');

  int get doneSections => sections.where((s) => s.hasContent).length;
  int get totalWords => sections.fold(0, (sum, section) => sum + section.words);

  Map<String, dynamic> toJson() => {
    'id': id,
    'titleZh': titleZh,
    'titleEn': titleEn,
    'format': format.name,
    'sourceResearchTitle': sourceResearchTitle,
    'sourceResearchPath': sourceResearchPath,
    'sourceBody': sourceBody,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'linkedProjects': linkedProjects.map((e) => e.toJson()).toList(),
    'topicOptions': topicOptions.map((e) => e.toJson()).toList(),
    'topicBrief': topicBrief,
    'factBaseline': factBaseline,
    'reviewReport': reviewReport,
    'reviewLang': reviewLang,
    'figures': figures.map((e) => e.toJson()).toList(),
    'sections': sections.map((section) => section.toJson()).toList(),
  };

  factory PaperDraft.fromJson(Map<String, dynamic> json) => PaperDraft(
    id: json['id'] as String,
    titleZh: json['titleZh'] as String? ?? '未命名论文',
    titleEn: json['titleEn'] as String? ?? '',
    format: PaperFormat.fromJson(json['format'] as String?),
    sourceResearchTitle: json['sourceResearchTitle'] as String? ?? '',
    sourceResearchPath: json['sourceResearchPath'] as String? ?? '',
    sourceBody: json['sourceBody'] as String? ?? '',
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
    linkedProjects: ((json['linkedProjects'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => LinkedProject.fromJson(e.cast<String, dynamic>()))
        .toList(),
    topicOptions: ((json['topicOptions'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => PaperTopicOption.fromJson(e.cast<String, dynamic>()))
        .toList(),
    topicBrief: json['topicBrief'] as String? ?? '',
    factBaseline: json['factBaseline'] as String? ?? '',
    reviewReport: json['reviewReport'] as String? ?? '',
    reviewLang: json['reviewLang'] as String? ?? '',
    figures: ((json['figures'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => PaperFigure.fromJson(e.cast<String, dynamic>()))
        .toList(),
    sections: ((json['sections'] as List?) ?? [])
        .whereType<Map>()
        .map(
          (section) => PaperSection.fromJson(section.cast<String, dynamic>()),
        )
        .toList(),
  );
}

class PaperService extends ChangeNotifier {
  PaperService(this.settings, {this.project, this.docs});

  final SettingsService settings;

  /// 项目服务（桌面端），用于「关联工程」时列出最近打开的工程；移动端为空。
  final ProjectService? project;

  /// 项目文档/对话服务，用于「推荐选题」时复用多轮 Agent 深挖工程代码。
  final ProjectDocService? docs;

  /// 最近打开过的工程路径（供关联工程时快速选择）。
  List<String> get recentProjects => project?.projects ?? const [];

  final List<PaperDraft> papers = [];
  PaperDraft? current;
  PaperSection? activeSection;
  bool busy = false;
  String stage = '';

  /// 运行过程的实时进度日志（如 Agent 的每一步检索），供 UI 展示，避免"卡住无反馈"。
  final List<String> progressLog = [];

  bool _cancel = false;
  File? _store;

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _store = File('${dir.path}\\papers.json');
    if (await _store!.exists()) {
      final data = jsonDecode(await _store!.readAsString());
      if (data is List) {
        papers
          ..clear()
          ..addAll(
            data.whereType<Map>().map(
              (e) => PaperDraft.fromJson(e.cast<String, dynamic>()),
            ),
          );
        papers.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      }
    }
  }

  PaperDraft createBlank({PaperFormat format = PaperFormat.markdown}) {
    final now = DateTime.now();
    final draft = PaperDraft(
      id: now.microsecondsSinceEpoch.toString(),
      titleZh: '未命名论文',
      titleEn: 'Untitled Paper',
      format: format,
      sourceResearchTitle: '',
      sourceResearchPath: '',
      sourceBody: '',
      createdAt: now,
      updatedAt: now,
      sections: _emptySections(),
    );
    papers.insert(0, draft);
    current = draft;
    activeSection = draft.sections.firstOrNull;
    notifyListeners();
    _persist();
    return draft;
  }

  PaperDraft createFromResearch(StandardNote note, PaperFormat format) {
    final now = DateTime.now();
    final draft = PaperDraft(
      id: now.microsecondsSinceEpoch.toString(),
      titleZh: '论文草稿：${_stripResearchPrefix(note.fullTitle)}',
      titleEn: '',
      format: format,
      sourceResearchTitle: note.fullTitle,
      sourceResearchPath: note.filePath,
      sourceBody: note.body,
      createdAt: now,
      updatedAt: now,
      sections: _emptySections(),
    );
    papers.insert(0, draft);
    current = draft;
    activeSection = draft.sections.firstOrNull;
    notifyListeners();
    _persist();
    return draft;
  }

  void openPaper(PaperDraft draft) {
    current = draft;
    activeSection = draft.sections.firstOrNull;
    notifyListeners();
  }

  void closePaper() {
    current = null;
    activeSection = null;
    notifyListeners();
  }

  void openSection(PaperSection? section) {
    activeSection = section;
    notifyListeners();
  }

  Future<void> deletePaper(PaperDraft draft) async {
    papers.remove(draft);
    if (current == draft) {
      current = null;
      activeSection = null;
    }
    notifyListeners();
    await _persist();
  }

  Future<void> saveDraft() async {
    final draft = current;
    if (draft == null) return;
    draft.updatedAt = DateTime.now();
    papers.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    notifyListeners();
    await _persist();
  }

  /// 「选择论文主题」：与关联工程交互（先补齐解读），综合工程实现与来源研究，
  /// 生成若干可投稿的候选选题（中英题目 + 相关信息），写入 draft.topicOptions。
  Future<void> recommendTopics([PaperDraft? target]) async {
    final draft = target ?? current;
    if (draft == null || busy) return;
    if (!draft.hasLinkedProject && draft.sourceBody.trim().isEmpty) {
      stage = '请先关联工程或从研究报告创建，才能推荐选题';
      notifyListeners();
      return;
    }
    _begin('正在与工程交互、生成推荐选题…');
    try {
      final options = await _planTopics(draft);
      if (_cancel) return;
      draft.topicOptions = options;
      draft.updatedAt = DateTime.now();
      stage = options.isEmpty ? '未能生成候选选题' : '已生成 ${options.length} 个候选选题，请选择';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '推荐选题失败：$e';
    } finally {
      _end();
    }
  }

  /// 选定一个候选选题：写入中英文题目，并把「相关信息」作为后续结构生成/写作的约束。
  Future<void> selectTopic(PaperTopicOption option, [PaperDraft? target]) async {
    final draft = target ?? current;
    if (draft == null) return;
    if (option.titleZh.trim().isNotEmpty) draft.titleZh = option.titleZh.trim();
    if (option.titleEn.trim().isNotEmpty) draft.titleEn = option.titleEn.trim();
    draft.topicBrief = option.summary.trim();
    draft.updatedAt = DateTime.now();
    notifyListeners();
    await _persist();
  }

  Future<List<PaperTopicOption>> _planTopics(PaperDraft draft) async {
    // 用多轮 Agent（与「项目概览对话」同一套）在工程内 grep/glob/read 深挖，
    // 得到分方向、有深度的富文本分析，再据此结构化出候选选题。
    final explorations = StringBuffer();
    final extraBrief = [
      if (draft.topicBrief.trim().isNotEmpty) draft.topicBrief.trim(),
      if (draft.sourceResearchTitle.trim().isNotEmpty)
        '来源研究报告：${draft.sourceResearchTitle.trim()}',
    ].join('\n');
    if (docs != null) {
      for (final proj in draft.linkedProjects) {
        if (_cancel) break;
        stage = '正在让智能体深入检索工程：${proj.name}…';
        notifyListeners();
        try {
          final text = await docs!.exploreForTopics(
            proj.path,
            extraBrief: extraBrief,
            onProgress: (line) => _pushProgress('[${proj.name}] $line'),
            isCancelled: () => _cancel,
          );
          if (text.trim().isNotEmpty) {
            explorations
              ..writeln('## 工程「${proj.name}」的深挖分析')
              ..writeln(text.trim())
              ..writeln();
          }
        } catch (e) {
          explorations.writeln('（工程「${proj.name}」检索失败：$e）');
        }
      }
    }
    final exploreBlock = explorations.toString().trim();
    if (_cancel) return draft.topicOptions;
    stage = '正在综合检索结果，拟定分方向的候选选题…';
    notifyListeners();
    final reply = await _chat([
      {
        'role': 'system',
        'content':
            '你是资深 SCI 期刊选题顾问。你依据「智能体对工程的深挖分析」提炼可投稿、'
            '有明确研究问题与创新点的论文选题。论文要高于并抽象于具体工程：题目与摘要'
            '中不得出现文件名/函数名/类名/库版本等实现痕迹。只输出 JSON，不要解释。',
      },
      {
        'role': 'user',
        'content':
            '''
请基于下面「智能体对关联工程的深挖分析」（及可选的来源研究报告），为可投稿的 SCI 论文推荐 5-8 个候选选题，
要求**覆盖多个不同研究方向、有深度有广度**，而非都挤在一个方向。
要求：
- 题目抽象、学术、可投稿，体现清晰的研究问题与创新点；论文高于具体工程，**不要出现文件名/函数名/类名/库版本等实现痕迹**；
- 尽量覆盖不同视角（问题层面 / 方法层面 / 理论层面 / 应用层面等）；
- 给出中文题目与英文题目；
- summary 用中文写清四点：研究问题、核心创新点、方法/技术要点（抽象表述）、建议关键词。

严格输出 JSON：
{"topics":[{"titleZh":"...","titleEn":"...","summary":"研究问题：… 创新点：… 方法要点：… 关键词：…"}]}

智能体对关联工程的深挖分析：
${exploreBlock.isEmpty ? '（无）' : clip(exploreBlock, 16000)}

来源研究报告标题：${draft.sourceResearchTitle.isEmpty ? '（无）' : draft.sourceResearchTitle}
来源研究报告正文：
${draft.sourceBody.trim().isEmpty ? '（无）' : clip(draft.sourceBody, 6000)}
''',
      },
    ], jsonMode: true);
    final obj = ModelClient.parseJsonObject(reply);
    final out = <PaperTopicOption>[];
    for (final raw in ((obj['topics'] as List?) ?? []).whereType<Map>()) {
      final zh = (raw['titleZh'] ?? '').toString().trim();
      final en = (raw['titleEn'] ?? '').toString().trim();
      if (zh.isEmpty && en.isEmpty) continue;
      out.add(
        PaperTopicOption(
          titleZh: zh,
          titleEn: en,
          summary: (raw['summary'] ?? '').toString().trim(),
        ),
      );
    }
    return out;
  }

  Future<void> generateTitleAndOutline([PaperDraft? target]) async {
    final draft = target ?? current;
    if (draft == null || busy) return;
    _begin('正在拟定 SCI 论文题目与结构…');
    try {
      await _ensureDigests(draft);
      if (_cancel) return;
      await _ensureBaseline(draft);
      if (_cancel) return;
      await _planPaper(draft);
      stage = '题目与结构已生成';
    } catch (e) {
      stage = _cancel ? '已停止' : '生成论文结构失败：$e';
    } finally {
      _end();
    }
  }

  /// 按所选语种写稿（中文 / 英文 / 双语）。写作前会先确保「统一研究基线」已建立，
  /// 使全篇抽象、去标识、数据自洽；不再把工程实现细节直接写进正文。
  Future<void> writeDraft(PaperLang lang, [PaperDraft? target]) async {
    final draft = target ?? current;
    if (draft == null || busy) return;
    _begin('正在准备论文写作…');
    try {
      await _ensureDigests(draft);
      if (_cancel) return;
      await _ensureBaseline(draft);
      if (_cancel) return;
      if (draft.sections.isEmpty || draft.titleEn.trim().isEmpty) {
        await _planPaper(draft);
      }
      if (_cancel) return;
      final total = draft.sections.length;
      final langLabel = switch (lang) {
        PaperLang.zh => '中文稿',
        PaperLang.en => '英文稿',
        PaperLang.both => '双语稿',
      };
      for (var i = 0; i < draft.sections.length; i++) {
        if (_cancel) break;
        final section = draft.sections[i];
        activeSection = section;
        if (lang.writeZh) {
          section.zh = '';
          stage = '正在写中文稿：${section.zhTitle}（${i + 1}/$total）…';
          notifyListeners();
          section.zh = await _streamSection(draft, section, english: false);
          if (_cancel) break;
        }
        if (lang.writeEn) {
          section.en = '';
          stage = '正在写英文稿：${section.enTitle}（${i + 1}/$total）…';
          notifyListeners();
          section.en = await _streamSection(draft, section, english: true);
          if (_cancel) break;
        }
        draft.updatedAt = DateTime.now();
        await _persist();
      }
      stage = _cancel ? '已停止' : '论文$langLabel已完成';
    } catch (e) {
      stage = _cancel ? '已停止' : '论文写作失败：$e';
    } finally {
      _end();
      await _persist();
    }
  }

  /// 生成「统一研究设定 / 事实基线」：把（可选的）工程解读上升为抽象、去标识、
  /// 全篇自洽的研究设定，作为结构/写作/图表的唯一事实来源。若已存在则跳过。
  Future<void> _ensureBaseline(PaperDraft draft) async {
    if (draft.factBaseline.trim().isNotEmpty) return;
    stage = '正在确立统一的研究设定与事实基线…';
    notifyListeners();
    draft.factBaseline = await _buildBaseline(draft);
    await _persist();
  }

  /// 手动（重新）确立研究基线。
  Future<void> buildBaseline([PaperDraft? target]) async {
    final draft = target ?? current;
    if (draft == null || busy) return;
    _begin('正在确立统一的研究设定与事实基线…');
    try {
      await _ensureDigests(draft);
      if (_cancel) return;
      draft.factBaseline = await _buildBaseline(draft);
      draft.updatedAt = DateTime.now();
      stage = '研究设定与事实基线已确立';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '确立研究基线失败：$e';
    } finally {
      _end();
    }
  }

  /// 参与审校的固定 5 位专家（名称 + 关注点）。
  static const List<(String, String)> _reviewExperts = [
    ('方法学专家', '研究问题是否清晰、方法是否严谨、创新点是否成立、逻辑链条是否完整'),
    ('领域专家', '相关工作覆盖是否充分、学术定位是否准确、贡献的领域价值与新意'),
    ('实验与统计审稿人', '实验设计与评测协议是否合理、指标是否恰当、数据是否自洽、结论是否被证据支撑'),
    ('写作与语言编辑', '结构与逻辑、表达与术语一致性、学术规范、可读性、图表与引用规范'),
    ('主编终审', '整体是否达到期刊发表标准、创新性与完整性、修改取舍与优先级'),
  ];

  /// 审校：5 位专家分别审阅当前语种全文，汇总讨论后形成按章节、按优先级的修订清单，
  /// 写入 draft.reviewReport（供用户查看并确认后再润色）。
  Future<void> reviewPaper(PaperLang lang, [PaperDraft? target]) async {
    final draft = target ?? current;
    if (draft == null || busy) return;
    final english = lang == PaperLang.en;
    final paperText = _fullPaperText(draft, english: english);
    if (paperText.trim().isEmpty) {
      stage = '请先写出${english ? '英文稿' : '中文稿'}再审校';
      notifyListeners();
      return;
    }
    _begin('正在组织专家审校…');
    try {
      final title = english ? draft.titleEn : draft.titleZh;
      final opinions = <String>[];
      for (final (name, focus) in _reviewExperts) {
        if (_cancel) break;
        stage = '专家审校中：$name…';
        notifyListeners();
        final op = await _chat([
          {
            'role': 'system',
            'content':
                '你是一位「$name」，正在为 SCI 期刊评审一篇论文，关注点：$focus。'
                '请聚焦要点、务实犀利，用中文输出你的审校意见（无论稿件语种）。',
          },
          {
            'role': 'user',
            'content':
                '''
请审校下面这篇论文，指出具体问题并给出可操作的修改建议（分条列出，标注涉及章节）。
请特别检查：
- 是否像“工程解读/项目报告”而非学术论文；是否残留具体工程实现痕迹（文件名/函数/库版本/机器型号/“本工程”等）；
- 数据、实验设定与结论是否前后自洽、有无夸大或矛盾；
- 是否达到期刊发表水准（创新性、严谨性、完整性、规范性）。
仅输出你的审校意见。

论文题目：$title

论文全文：
$paperText
''',
          },
        ]);
        opinions.add('### $name\n\n${op.trim()}');
      }
      if (_cancel) return;
      stage = '正在汇总专家意见、形成修订清单…';
      notifyListeners();
      final consolidated = await _chat([
        {
          'role': 'system',
          'content': '你是期刊主编，负责整合多位专家的审校意见。用中文输出 Markdown，务实、可执行。',
        },
        {
          'role': 'user',
          'content':
              '''
下面是 5 位专家对同一篇论文的审校意见。请：
1）简要汇总各专家意见，指出共识与分歧；
2）形成一份**按章节组织、按优先级排序、可执行**的修订清单（每条写清：涉及章节 + 具体修改动作）。

专家意见：
${opinions.join('\n\n')}
''',
        },
      ]);
      if (_cancel) return;
      final report = StringBuffer()
        ..writeln('# 审校意见（${english ? '英文稿' : '中文稿'}）')
        ..writeln()
        ..writeln('## 专家意见')
        ..writeln()
        ..writeln(opinions.join('\n\n'))
        ..writeln()
        ..writeln('## 汇总讨论与修订清单')
        ..writeln()
        ..writeln(consolidated.trim());
      draft.reviewReport = report.toString();
      draft.reviewLang = english ? 'en' : 'zh';
      draft.updatedAt = DateTime.now();
      stage = '审校完成，请查看意见并确认润色';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '审校失败：$e';
    } finally {
      _end();
    }
  }

  /// 润色主笔人：依据审校修订清单与研究基线，逐节修订当前语种稿件。
  Future<void> applyPolish(PaperLang lang, [PaperDraft? target]) async {
    final draft = target ?? current;
    if (draft == null || busy) return;
    if (draft.reviewReport.trim().isEmpty) {
      stage = '请先执行「审校」，再进行润色';
      notifyListeners();
      return;
    }
    final english = lang == PaperLang.en;
    _begin('润色主笔人正在据审校意见修订…');
    try {
      final total = draft.sections.length;
      final syntax = draft.format == PaperFormat.latex ? 'LaTeX 片段' : 'Markdown';
      for (var i = 0; i < draft.sections.length; i++) {
        if (_cancel) break;
        final section = draft.sections[i];
        final current = english ? section.en : section.zh;
        if (current.trim().isEmpty) continue;
        activeSection = section;
        stage = '润色：${english ? section.enTitle : section.zhTitle}（${i + 1}/$total）…';
        notifyListeners();
        final polished = await _chat([
          {
            'role': 'system',
            'content':
                '你是资深论文润色主笔人。你依据审校修订清单与研究设定基线，对论文逐节修订，'
                '使其达到 SCI 期刊发表水准：学术、抽象、去除一切具体工程实现痕迹，数据与结论与基线一致、'
                '前后不矛盾、不夸大。保持$syntax格式，不要重复本节标题，只输出修订后的本节正文。',
          },
          {
            'role': 'user',
            'content':
                '''
请根据「修订清单」与「研究设定基线」，修订并润色下面这一节，落实其中与本节相关的意见。

修订清单（审校意见）：
${clip(draft.reviewReport, 6000)}

统一研究设定 / 事实基线：
${draft.factBaseline.trim().isEmpty ? '（无）' : clip(draft.factBaseline, 4000)}

本节标题：${english ? section.enTitle : section.zhTitle}

本节当前内容：
$current

只输出修订后的本节正文（不含标题）。
''',
          },
        ]);
        if (_cancel) break;
        final cleaned = polished.trim();
        if (cleaned.isNotEmpty) {
          if (english) {
            section.en = cleaned;
          } else {
            section.zh = cleaned;
          }
          draft.updatedAt = DateTime.now();
          await _persist();
        }
      }
      stage = _cancel ? '已停止' : '润色完成';
    } catch (e) {
      stage = _cancel ? '已停止' : '润色失败：$e';
    } finally {
      _end();
      await _persist();
    }
  }

  /// 拼出当前语种的论文全文（标题 + 各节），用于审校/图表分析，按预算裁剪。
  String _fullPaperText(PaperDraft draft, {required bool english}) {
    final buf = StringBuffer();
    for (final section in draft.sections) {
      final title = english ? section.enTitle : section.zhTitle;
      final body = (english ? section.en : section.zh).trim();
      if (body.isEmpty) continue;
      buf
        ..writeln('## $title')
        ..writeln()
        ..writeln(clip(body, 3200))
        ..writeln();
    }
    return buf.toString().trim();
  }

  Future<String> _buildBaseline(PaperDraft draft) async {
    final projectBlock = _combinedProjectDigest(draft, 12000);
    final reply = await _chat([
      {
        'role': 'system',
        'content':
            '你是资深 SCI 论文的科研设计顾问。你的任务是把（可能来自具体工程的）素材，'
            '抽象、升华为一个可支撑高质量学术论文的「研究设定」。论文必须高于并独立于任何具体工程实现：'
            '严禁保留任何实现痕迹（文件名/路径、函数名/类名、库及版本号、CPU/机器型号、“本工程/本项目”等）。'
            '所有数据与设定必须自洽、可发表、不夸大。只输出所要求的 Markdown，不要解释。',
      },
      {
        'role': 'user',
        'content':
            '''
请依据下面的素材，产出一份「统一研究设定 / 事实基线」。它是全篇论文（结构、各章节、图表）唯一的事实来源，
必须抽象、去标识、前后自洽。请严格按以下小节输出（Markdown）：

## 研究问题与目标
（用通用学术语言描述要解决的科学/技术问题与目标，不含任何具体工程标识）

## 方法/框架的抽象
（把方法上升为通用的原理、模型、流程或框架；用通用术语命名各阶段/模块，不出现代码符号）

## 实验与数据设定
（明确：数据集的规模与构成、评测协议、实验环境的抽象描述；并**明确本研究结果的口径**：
是“已完成的实验结果”还是“拟进行/示例性设定”，全篇必须与此口径一致，不得自相矛盾）

## 可报告的量化结果
（给出一组自洽、合理、可全篇统一引用的关键指标数值；若上面口径为“拟进行”，此处以“预期/示例”标注）

## 术语表（中/英）
（统一全篇使用的关键术语中英文对照）

## 去标识清单
（明确列出本篇写作中禁止出现的具体标识类型示例，供各章节自检）

素材——关联工程解读（仅供你抽象提炼，严禁把其中的实现细节直接写进论文）：
${projectBlock.isEmpty ? '（无）' : projectBlock}

选定选题的相关信息：
${draft.topicBrief.trim().isEmpty ? '（无）' : clip(draft.topicBrief, 2000)}

来源研究报告标题：${draft.sourceResearchTitle.isEmpty ? '（无）' : draft.sourceResearchTitle}
来源研究报告正文：
${draft.sourceBody.trim().isEmpty ? '（无）' : clip(draft.sourceBody, 8000)}
''',
      },
    ]);
    return reply.trim();
  }

  /// 追加一个关联工程（去重）。不影响其它工程已有的解读摘要。
  Future<void> addLinkedProject(String path) async {
    final draft = current;
    if (draft == null) return;
    final normalized = path.trim();
    if (normalized.isEmpty) return;
    if (draft.linkedProjects.any((e) => e.path == normalized)) return;
    draft.linkedProjects.add(LinkedProject(path: normalized));
    draft.updatedAt = DateTime.now();
    notifyListeners();
    await _persist();
  }

  /// 移除一个关联工程。
  Future<void> removeLinkedProject(String path) async {
    final draft = current;
    if (draft == null) return;
    draft.linkedProjects.removeWhere((e) => e.path == path);
    draft.updatedAt = DateTime.now();
    notifyListeners();
    await _persist();
  }

  /// 解读关联工程：读取工程内真实文件（README、依赖清单、训练/模型/实验/配置等
  /// 源码），调用模型提炼方法与实验设置的真实摘要，缓存到各工程的 digest，供各章节
  /// 写作直接引用、真实落地到论文。[onlyPath] 为空时解读全部（缺解读的优先）。
  Future<void> interpretProjects({String? onlyPath}) async {
    final draft = current;
    if (draft == null || busy) return;
    if (!draft.hasLinkedProject) {
      stage = '尚未关联工程';
      notifyListeners();
      return;
    }
    _begin('正在解读关联工程…');
    try {
      final targets = onlyPath == null
          ? draft.linkedProjects
          : draft.linkedProjects.where((e) => e.path == onlyPath).toList();
      for (final proj in targets) {
        if (_cancel) break;
        stage = '正在解读工程：${proj.name}…';
        notifyListeners();
        proj.digest = await _buildProjectDigest(draft, proj.path);
        draft.updatedAt = DateTime.now();
        await _persist();
      }
      stage = _cancel ? '已停止' : '工程解读完成';
    } catch (e) {
      stage = _cancel ? '已停止' : '解读工程失败：$e';
    } finally {
      _end();
    }
  }

  /// 为所有尚未解读的关联工程补齐 digest（供写稿/选题/结构生成前调用）。
  /// 不自行 _begin/_end，交由调用方管理 busy 状态。
  Future<void> _ensureDigests(PaperDraft draft) async {
    for (final proj in draft.linkedProjects) {
      if (_cancel) break;
      if (proj.hasDigest) continue;
      stage = '正在解读关联工程：${proj.name}…';
      notifyListeners();
      proj.digest = await _buildProjectDigest(draft, proj.path);
      await _persist();
    }
  }

  Future<String> _buildProjectDigest(PaperDraft draft, String projectPath) async {
    final dir = Directory(projectPath);
    if (!await dir.exists()) {
      throw Exception('工程目录不存在：$projectPath');
    }
    final rg = await Ripgrep.instance.exePath();
    final context = await compute(_collectProjectContext, (projectPath, rg));
    if (context.trim().isEmpty) throw Exception('工程内未找到可解读的文件');
    final reply = await _chat([
      {
        'role': 'system',
        'content':
            '你是严谨的科研工程分析专家。你只依据给定的真实工程文件内容做客观解读，'
            '不臆测、不编造；工程中没有体现的信息一律如实标注“工程中未体现”。',
      },
      {'role': 'user', 'content': _projectDigestPrompt(draft, context)},
    ]);
    return reply.trim();
  }

  String _projectDigestPrompt(PaperDraft draft, String context) => '''
下面是论文关联「实验工程」中的真实文件内容（含文件路径）。请据此客观解读该工程，
产出结构化中文「工程解读」，供论文的方法、实验设置、相关工作等章节直接引用。
要求真实、具体、可核对，严禁编造工程中不存在的内容；工程未体现的信息请写“工程中未体现”。

论文题目：${draft.titleZh}

请按如下小节输出（Markdown 小标题）：
## 工程概述与目标
## 实现的方法/模型/算法（列出真实的模块、类、函数、关键实现思路与流程）
## 实验设置（数据集与来源、数据预处理、模型与超参数配置、训练与优化设置、评价指标、运行环境与依赖版本）
## 关键结果或产出（若代码/配置/日志中有则如实提取，否则写“工程中未体现”）
## 目录结构要点

工程文件内容如下：
$context
''';

  /// 在后台 isolate 遍历实验工程，收集用于解读的关键文件内容（含路径）。
  /// 优先文档与依赖清单、配置，再按文件名关键词挑选训练/模型/实验类源码，
  /// 控制总字数预算，避免超出模型上下文。
  static String _collectProjectContext((String, String) msg) {
    final rootPath = msg.$1;
    final rgExe = msg.$2;
    const srcExts = {
      '.py', '.dart', '.js', '.ts', '.tsx', '.jsx', '.java', '.kt', '.go',
      '.rs', '.cpp', '.c', '.h', '.hpp', '.cc', '.m', '.scala', '.cs', '.rb',
      '.lua', '.jl', '.ipynb',
    };
    const manifestNames = {
      'requirements.txt', 'pyproject.toml', 'setup.py', 'setup.cfg',
      'environment.yml', 'environment.yaml', 'package.json', 'pubspec.yaml',
      'cargo.toml', 'go.mod', 'pom.xml', 'build.gradle', 'makefile',
      'dockerfile',
    };
    const keywords = [
      'train', 'model', 'net', 'experiment', 'exp', 'eval', 'evaluat',
      'metric', 'dataset', 'data', 'main', 'run', 'config', 'args', 'loss',
      'optim', 'pipeline', 'benchmark', 'infer', 'predict',
    ];
    final docs = <File>[];
    final manifests = <File>[];
    final configs = <File>[];
    final scored = <(int, File)>[];

    for (final rel in Ripgrep.listFilesSync(rgExe, rootPath)) {
      final depth = '/'.allMatches(rel).length;
      if (depth > 4) continue;
      final name = p.basename(rel);
      final lower = name.toLowerCase();
      final ext = p.extension(lower);
      final file = File(p.join(rootPath, rel));
      if (lower.startsWith('readme') || (ext == '.md' && depth <= 1)) {
        docs.add(file);
      } else if (manifestNames.contains(lower)) {
        manifests.add(file);
      } else if (['.yaml', '.yml', '.toml', '.ini', '.cfg'].contains(ext) ||
          (ext == '.json' && depth <= 2)) {
        configs.add(file);
      } else if (srcExts.contains(ext)) {
        var score = depth <= 1 ? 1 : 0;
        for (final k in keywords) {
          if (lower.contains(k)) score += 2;
        }
        scored.add((score, file));
      }
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));

    final buf = StringBuffer();
    var budget = 60000;
    String relOf(File f) =>
        p.relative(f.path, from: rootPath).replaceAll('\\', '/');
    void addFile(File f, int cap) {
      if (budget <= 0) return;
      String content;
      try {
        content = f.readAsStringSync();
      } catch (_) {
        return;
      }
      if (content.trim().isEmpty) return;
      if (content.length > cap) content = '${content.substring(0, cap)}\n…（内容截断）';
      buf
        ..writeln('### 文件：${relOf(f)}')
        ..writeln(content)
        ..writeln();
      budget -= content.length;
    }

    for (final f in docs) {
      addFile(f, 8000);
    }
    for (final f in manifests) {
      addFile(f, 4000);
    }
    for (final f in configs.take(15)) {
      addFile(f, 3000);
    }
    final manyFiles = scored.length > 25;
    for (final (score, f) in scored) {
      if (budget <= 0) break;
      if (manyFiles && score <= 0) continue; // 文件多时只取与实验相关的
      addFile(f, 5000);
    }
    return buf.toString();
  }

  void cancel() {
    if (!busy) return;
    _cancel = true;
    stage = '正在停止…';
    notifyListeners();
  }

  /// 导出 PDF（按语种）：Markdown 论文走 pandoc 管线（表格/公式/标题排版更规范），
  /// LaTeX 论文仍走 xelatex。图表会作为高清图嵌入。
  Future<List<String>> exportPdf(PaperLang lang) async {
    final draft = current;
    if (draft == null) throw StateError('未打开论文');
    _begin('正在导出 PDF…');
    try {
      final dir = Directory(p.join(settings.vaultPath, '4-书稿', '论文'));
      await dir.create(recursive: true);
      final baseName = sanitizeFileName(draft.titleZh, fallback: '未命名论文');
      final outputs = <String>[];
      if (lang.writeZh) {
        stage = '正在导出中文 PDF…';
        notifyListeners();
        outputs.add(await _exportOnePdf(
          draft,
          english: false,
          output: File(p.join(dir.path, '$baseName-中文稿.pdf')),
          jobName: 'paper_zh',
        ));
      }
      if (lang.writeEn) {
        stage = '正在导出英文 PDF…';
        notifyListeners();
        outputs.add(await _exportOnePdf(
          draft,
          english: true,
          output: File(p.join(dir.path, '$baseName-英文稿.pdf')),
          jobName: 'paper_en',
        ));
      }
      await _openExportDirectory(dir.path);
      stage = '已导出 ${outputs.length} 个 PDF';
      return outputs;
    } finally {
      _end();
    }
  }

  Future<String> _exportOnePdf(
    PaperDraft draft, {
    required bool english,
    required File output,
    required String jobName,
  }) async {
    if (draft.format == PaperFormat.markdown) {
      await _pandocPdf(
        markdown: _cleanMarkdownDoc(draft, english: english, forExport: true),
        output: output,
        jobName: jobName,
        english: english,
      );
    } else {
      await _compileLatexPdf(
        tex: english
            ? _renderEnglishLatexDocument(draft)
            : _renderChineseLatexDocument(draft),
        output: output,
        jobName: jobName,
      );
    }
    return output.path;
  }

  /// 导出 Markdown：中文稿、英文稿各一份 .md（含图表引用），写入导出目录并打开。
  Future<List<String>> exportMarkdown() async {
    final draft = current;
    if (draft == null) throw StateError('未打开论文');
    final dir = Directory(p.join(settings.vaultPath, '4-书稿', '论文'));
    await dir.create(recursive: true);
    final baseName = sanitizeFileName(draft.titleZh, fallback: '未命名论文');
    final zhFile = File(p.join(dir.path, '$baseName-中文稿.md'));
    final enFile = File(p.join(dir.path, '$baseName-英文稿.md'));
    await zhFile.writeAsString(
      _cleanMarkdownDoc(draft, english: false, forExport: true),
    );
    await enFile.writeAsString(
      _cleanMarkdownDoc(draft, english: true, forExport: true),
    );
    await _openExportDirectory(dir.path);
    return [zhFile.path, enFile.path];
  }

  /// 生成干净的单语言 Markdown 文档：标题 + 各节（去除重复标题）+ 归属该节的图表。
  /// [forExport] 为 true 时用绝对路径嵌入图片，供 pandoc / md 导出。
  String _cleanMarkdownDoc(
    PaperDraft draft, {
    required bool english,
    required bool forExport,
  }) {
    final buf = StringBuffer()
      ..writeln('# ${english ? draft.titleEn : draft.titleZh}')
      ..writeln();
    final emitted = <String>{};
    for (final section in draft.sections) {
      final title = english ? section.enTitle : section.zhTitle;
      final rawBody = (english ? section.en : section.zh).trim();
      final body = _dedupeSectionHeading(rawBody, section);
      buf
        ..writeln('## $title')
        ..writeln()
        ..writeln(body.isEmpty ? (english ? '(To be written)' : '（待撰写）') : body)
        ..writeln();
      final kind = _sectionKind(section);
      if (kind.isNotEmpty) {
        for (final fig in draft.figures.where(
          (f) => f.hasImage && f.section == kind,
        )) {
          buf
            ..writeln(_figureMarkdown(fig, english: english, absolute: forExport))
            ..writeln();
          emitted.add(fig.id);
        }
      }
    }
    // 未归属到任何章节的图，统一附在文末。
    final leftover =
        draft.figures.where((f) => f.hasImage && !emitted.contains(f.id));
    for (final fig in leftover) {
      buf
        ..writeln(_figureMarkdown(fig, english: english, absolute: forExport))
        ..writeln();
    }
    return buf.toString();
  }

  /// 单张图的 Markdown（图片 + 图题）。[absolute] 决定图片路径用绝对路径。
  String _figureMarkdown(
    PaperFigure fig, {
    required bool english,
    required bool absolute,
  }) {
    final title = english ? fig.titleEn : fig.titleZh;
    final caption = english ? fig.captionEn : fig.captionZh;
    final label = title.isEmpty ? fig.id : title;
    final src = absolute
        ? fig.pngPath.replaceAll('\\', '/')
        : Uri.file(fig.pngPath).toString();
    final full = caption.trim().isEmpty ? label : '$label：$caption';
    return '![$full]($src)';
  }

  /// 去掉章节正文开头重复的标题行（Markdown 标题或纯文本标题），避免 PDF 中标题重复。
  static String _dedupeSectionHeading(String body, PaperSection section) {
    if (body.trim().isEmpty) return body;
    final lines = body.replaceAll('\r\n', '\n').split('\n');
    var start = 0;
    while (start < lines.length) {
      final line = lines[start].trim();
      if (line.isEmpty) {
        start++;
        continue;
      }
      final headingText = RegExp(r'^#{1,6}\s+(.+)$').firstMatch(line)?.group(1) ??
          line;
      final norm = _stripSectionNumber(headingText).trim();
      final zh = _stripSectionNumber(section.zhTitle).trim();
      final en = _stripSectionNumber(section.enTitle).trim();
      final isHeading = line.startsWith('#');
      final matches = norm == zh ||
          norm.toLowerCase() == en.toLowerCase() ||
          (isHeading && (norm.contains(zh) || (en.isNotEmpty &&
              norm.toLowerCase().contains(en.toLowerCase()))));
      // 仅当该行本身是标题行、或纯粹等于本节标题时才剥离。
      if (isHeading && matches) {
        start++;
        continue;
      }
      if (!isHeading && (norm == zh || norm.toLowerCase() == en.toLowerCase())) {
        start++;
        continue;
      }
      break;
    }
    return lines.sublist(start).join('\n').trim();
  }

  String renderPreview(PaperDraft draft, {bool english = false}) {
    if (draft.format == PaperFormat.latex) {
      return _renderLatex(draft, english: english);
    }
    return _renderMarkdown(draft, english: english);
  }

  Future<void> _planPaper(PaperDraft draft) async {
    stage = '正在拟定 SCI 论文题目与章节结构…';
    notifyListeners();
    final hasChosenTitle = draft.titleZh.trim().isNotEmpty &&
        draft.titleZh.trim() != '未命名论文' &&
        !draft.titleZh.startsWith('论文草稿：');
    final titleRule = hasChosenTitle
        ? '- 用户已选定题目，请沿用（可仅做措辞润色）：中文「${draft.titleZh}」；英文「${draft.titleEn}」。'
        : '- 题目应具体、学术、可投稿，避免泛泛而谈。';
    final reply = await _chat([
      {
        'role': 'system',
        'content':
            '你是资深 SCI 期刊论文编辑。你依据「统一研究设定/事实基线」规划一篇抽象、'
            '高于任何具体工程实现的标准学术论文结构。只输出 JSON，不要解释。',
      },
      {
        'role': 'user',
        'content':
            '''
请依据下面的「统一研究设定/事实基线」，拟定适合 SCI 期刊论文的中文题目、英文题目，并规划论文结构。

要求：
$titleRule
- 论文须高于并独立于任何具体工程：结构与各节要点用通用学术语言，不出现文件名/函数/库版本/机器型号/“本工程”等实现痕迹。
- sections 必须覆盖标准 SCI 论文套路：摘要、关键词、引言、相关工作、方法或框架、实验或评价、结果、讨论、结论、参考文献。
- 每个 section 给出 zhTitle、enTitle、brief（brief 用中文写清本节要点，须与研究基线一致、不夸大、不矛盾）。

严格输出 JSON：
{"titleZh":"...","titleEn":"...","sections":[{"zhTitle":"摘要","enTitle":"Abstract","brief":"本节写作要点"}]}

统一研究设定 / 事实基线：
${draft.factBaseline.trim().isEmpty ? '（无）' : clip(draft.factBaseline, 9000)}
''',
      },
    ], jsonMode: true);
    final plan = ModelClient.parseJsonObject(reply);
    draft.titleZh = (plan['titleZh'] ?? draft.titleZh).toString().trim();
    draft.titleEn = (plan['titleEn'] ?? draft.titleEn).toString().trim();
    final rawSections = (plan['sections'] as List?) ?? [];
    if (draft.titleZh.isEmpty || draft.titleEn.isEmpty || rawSections.isEmpty) {
      throw Exception('模型未返回完整论文题目或结构');
    }
    final sections = <PaperSection>[];
    var i = 0;
    for (final raw in rawSections.whereType<Map>()) {
      i++;
      final zhTitle = (raw['zhTitle'] ?? '').toString().trim();
      final enTitle = (raw['enTitle'] ?? '').toString().trim();
      if (zhTitle.isEmpty || enTitle.isEmpty) continue;
      sections.add(
        PaperSection(
          id: '${DateTime.now().microsecondsSinceEpoch}_$i',
          zhTitle: zhTitle,
          enTitle: enTitle,
          brief: (raw['brief'] ?? '').toString().trim(),
        ),
      );
    }
    if (sections.isEmpty) throw Exception('模型未返回可用章节');
    draft.sections = sections;
    activeSection = sections.first;
    draft.updatedAt = DateTime.now();
    notifyListeners();
    await _persist();
  }

  Future<String> _streamSection(
    PaperDraft draft,
    PaperSection section, {
    required bool english,
  }) async {
    final messages = [
      {
        'role': 'system',
        'content': english ? _englishSystem(draft) : _chineseSystem(draft),
      },
      {
        'role': 'user',
        'content': _sectionPrompt(draft, section, english: english),
      },
    ];
    // 长流式响应常被服务端/中间代理中途断开（Connection closed while receiving
    // data）。用 ModelClient.streamWithRetry 做有限次数断线重试：每次重试前清空
    // 本节已生成内容后整节重写，避免任何一次断线就让整篇写作失败。
    final baseStage = stage;
    var acc = '';
    void write(String text) {
      if (english) {
        section.en = text;
      } else {
        section.zh = text;
      }
    }

    final turn = await ModelClient(settings, role: ModelRole.writing)
        .streamWithRetry(
      messages: messages,
      onTextDelta: (delta) {
        acc += delta;
        write(acc);
        notifyListeners();
      },
      isCancelled: () => _cancel,
      idleTimeout: const Duration(seconds: 90),
      onAttempt: (attempt) {
        acc = '';
        write('');
        stage = '$baseStage 网络中断，正在重试（${attempt - 1}/3）…';
        notifyListeners();
      },
    );
    if (_cancel) return english ? section.en.trim() : section.zh.trim();
    return turn.content.trim();
  }

  String _chineseSystem(PaperDraft draft) {
    final syntax = draft.format == PaperFormat.latex ? 'LaTeX 片段' : 'Markdown';
    return '你是严谨的中文 SCI 论文写作助手。论文必须高于并独立于任何具体工程实现：'
        '严禁出现具体文件名/路径、函数名/类名、库及版本号、CPU/机器型号、“本工程/本项目/工程迭代”等实现痕迹，'
        '把实现细节上升为通用方法与原理。所有数据、设定、结论必须与给定的「研究设定基线」完全一致，前后不矛盾、不夸大。'
        '直接输出本节中文$syntax正文，不要解释，不要输出代码围栏，不要重复本节标题。';
  }

  String _englishSystem(PaperDraft draft) {
    final syntax = draft.format == PaperFormat.latex
        ? 'LaTeX fragment'
        : 'Markdown';
    return 'You are a rigorous SCI journal paper writing assistant. The paper must stay abstract and '
        'independent of any concrete engineering implementation: never mention concrete file names/paths, '
        'function/class names, library or version numbers, CPU/machine models, or phrases like "this project". '
        'Elevate implementation details into general methods and principles. All data, settings, and conclusions '
        'must stay fully consistent with the given research baseline, without contradiction or exaggeration. '
        'Output only the English $syntax content for the requested section. Do not explain, do not wrap it in code '
        'fences, and do not repeat the section title.';
  }

  /// 把所有关联工程的解读拼成一段（每工程以 `## 工程：{name}` 分隔），总量封顶。
  String _combinedProjectDigest(PaperDraft draft, int maxTotal) {
    final withDigest =
        draft.linkedProjects.where((e) => e.hasDigest).toList();
    if (withDigest.isEmpty) return '';
    final perProject = (maxTotal / withDigest.length).floor().clamp(1200, maxTotal);
    final buf = StringBuffer();
    for (final proj in withDigest) {
      buf
        ..writeln('## 工程：${proj.name}')
        ..writeln(clip(proj.digest, perProject))
        ..writeln();
    }
    return buf.toString().trim();
  }

  String _sectionPrompt(
    PaperDraft draft,
    PaperSection section, {
    required bool english,
  }) {
    final outline = draft.sections
        .map((s) => '- ${english ? s.enTitle : s.zhTitle}: ${s.brief}')
        .join('\n');
    final formatHint = draft.format == PaperFormat.latex
        ? (english
              ? 'Use valid LaTeX syntax. Do not include \\documentclass, \\begin{document}, or \\end{document}.'
              : '使用合法 LaTeX 语法。不要包含 \\documentclass、\\begin{document} 或 \\end{document}。')
        : (english
              ? 'Use clean Markdown suitable for journal manuscript preview.'
              : '使用清晰 Markdown，适合期刊论文稿件预览。');
    final baselineBlock = draft.factBaseline.trim().isEmpty
        ? ''
        : '''

统一研究设定 / 事实基线（全篇唯一事实来源，本节所有数据、设定、结论必须与之一致）：
${clip(draft.factBaseline, 9000)}
''';
    final figureBlock = _figurePromptHint(draft, section, english: english);
    return '''
论文题目：
${english ? draft.titleEn : draft.titleZh}

论文整体结构：
$outline

当前要写的部分：
${english ? section.enTitle : section.zhTitle}

本节要点：
${section.brief}
$baselineBlock$figureBlock
要求：
- 按标准 SCI 期刊论文写作套路组织内容，强调研究问题、方法、发现和学术贡献；语言学术、抽象、凝练。
- 论文高于并独立于任何具体工程实现：严禁出现文件名/路径、函数/类名、库及版本号、CPU/机器型号、“本工程/本项目”等；把实现细节上升为通用方法与原理。
- 所有数据、实验设定、结论必须严格依据上面的「统一研究设定/事实基线」，前后自洽、不夸大、不臆造，不与其它章节矛盾。
- 不要重复输出本节标题；$formatHint
- 只输出当前部分正文。''';
  }

  /// 若某图归属当前章节，则提示模型在正文合适位置引用（如“如图1所示”）。
  String _figurePromptHint(
    PaperDraft draft,
    PaperSection section, {
    required bool english,
  }) {
    final secKey = _sectionKind(section);
    final related = draft.figures
        .where((f) => f.hasImage && f.section == secKey)
        .toList();
    if (related.isEmpty) return '';
    final names = related
        .map((f) => english ? f.titleEn : f.titleZh)
        .where((e) => e.trim().isNotEmpty)
        .join(english ? ', ' : '、');
    if (names.isEmpty) return '';
    return english
        ? '\n本节配有图：$names。请在正文合适处自然引用这些图（如 "as shown in Fig. X"），但不要自己插入图片语法。\n'
        : '\n本节配有图：$names。请在正文合适处自然引用这些图（如“如图X所示”），但不要自己插入图片语法。\n';
  }

  /// 把章节归类到 methods / results / … 便于图表挂接。
  static String _sectionKind(PaperSection section) {
    final id = section.id.toLowerCase();
    final en = section.enTitle.toLowerCase();
    final zh = section.zhTitle;
    if (id.contains('method') || en.contains('method') ||
        en.contains('framework') || zh.contains('方法') || zh.contains('框架')) {
      return 'methods';
    }
    if (id.contains('result') || en.contains('result') ||
        id.contains('experiment') || en.contains('experiment') ||
        en.contains('evaluation') || zh.contains('结果') || zh.contains('实验')) {
      return 'results';
    }
    return '';
  }

  List<PaperSection> _emptySections() => [
    PaperSection(id: 'abstract', zhTitle: '摘要', enTitle: 'Abstract'),
    PaperSection(id: 'keywords', zhTitle: '关键词', enTitle: 'Keywords'),
    PaperSection(id: 'introduction', zhTitle: '引言', enTitle: 'Introduction'),
    PaperSection(id: 'related_work', zhTitle: '相关工作', enTitle: 'Related Work'),
    PaperSection(id: 'methods', zhTitle: '方法', enTitle: 'Methods'),
    PaperSection(
      id: 'experiments',
      zhTitle: '实验与评价',
      enTitle: 'Experiments and Evaluation',
    ),
    PaperSection(id: 'results', zhTitle: '结果', enTitle: 'Results'),
    PaperSection(id: 'discussion', zhTitle: '讨论', enTitle: 'Discussion'),
    PaperSection(id: 'conclusion', zhTitle: '结论', enTitle: 'Conclusion'),
    PaperSection(id: 'references', zhTitle: '参考文献', enTitle: 'References'),
  ];

  String _renderMarkdown(PaperDraft draft, {bool english = false}) {
    final buf = StringBuffer()
      ..writeln('# ${english ? draft.titleEn : draft.titleZh}')
      ..writeln();
    for (final section in draft.sections) {
      final title = english ? section.enTitle : section.zhTitle;
      final body = english ? section.en : section.zh;
      buf
        ..writeln('## $title')
        ..writeln()
        ..writeln(body.trim().isEmpty ? '（待撰写）' : body.trim())
        ..writeln();
      final kind = _sectionKind(section);
      if (kind.isNotEmpty) {
        for (final fig in draft.figures.where(
          (f) => f.hasImage && f.section == kind,
        )) {
          final t = english ? fig.titleEn : fig.titleZh;
          final c = english ? fig.captionEn : fig.captionZh;
          buf
            ..writeln('> 🖼 ${t.isEmpty ? fig.id : t}${c.trim().isEmpty ? '' : '：$c'}')
            ..writeln();
        }
      }
    }
    if (!english) {
      buf
        ..writeln('---')
        ..writeln()
        ..writeln(
          '# ${draft.titleEn.isEmpty ? 'English Draft' : draft.titleEn}',
        )
        ..writeln();
      for (final section in draft.sections) {
        buf
          ..writeln('## ${section.enTitle}')
          ..writeln()
          ..writeln(
            section.en.trim().isEmpty ? '(To be written)' : section.en.trim(),
          )
          ..writeln();
      }
    }
    return buf.toString();
  }

  String _renderEnglishLatexDocument(PaperDraft draft) {
    final title = draft.titleEn.trim().isEmpty ? draft.titleZh : draft.titleEn;
    final buf = StringBuffer()
      ..writeln(r'\documentclass[12pt,a4paper]{article}')
      ..writeln(r'\usepackage[margin=1in]{geometry}')
      ..writeln(r'\usepackage{fontspec}')
      ..writeln(r'\usepackage{xeCJK}')
      ..writeln(r'\usepackage{setspace}')
      ..writeln(r'\usepackage{indentfirst}')
      ..writeln(r'\usepackage{amsmath,amssymb}')
      ..writeln(r'\usepackage{booktabs,longtable,array}')
      ..writeln(r'\usepackage[table]{xcolor}')
      ..writeln(r'\usepackage{graphicx}')
      ..writeln(r'\usepackage{caption}')
      ..writeln(r'\usepackage[hidelinks]{hyperref}')
      ..writeln(r'\setmainfont{Times New Roman}')
      ..writeln(r'\setCJKmainfont{SimHei}')
      ..writeln(r'\providecommand{\citet}[2][]{\cite{#2}}')
      ..writeln(r'\providecommand{\citep}[2][]{\cite{#2}}')
      ..writeln(r'\providecommand{\textcite}[2][]{\cite{#2}}')
      ..writeln(r'\providecommand{\parencite}[2][]{\cite{#2}}')
      ..writeln(r'\providecommand{\autocite}[2][]{\cite{#2}}')
      ..writeln(r'\providecommand{\citeauthor}[2][]{#2}')
      ..writeln(r'\providecommand{\citeyear}[2][]{n.d.}')
      ..writeln(_latexAlgorithmDefinitions())
      ..writeln(r'\doublespacing')
      ..writeln(r'\setlength{\parindent}{0.5in}')
      ..writeln(r'\setlength{\parskip}{0pt}')
      ..writeln('\\title{${_latexText(title)}}')
      ..writeln(r'\author{}')
      ..writeln(r'\date{}')
      ..writeln(r'\begin{document}')
      ..writeln(r'\maketitle')
      ..writeln();
    var sectionNo = 0;
    for (final section in draft.sections) {
      final sectionTitle = section.enTitle.trim().isEmpty
          ? section.zhTitle.trim()
          : section.enTitle.trim();
      final text = _sectionLatexBlocks(
        section.en,
        sectionTitle: sectionTitle,
        english: true,
      );
      if (_isAbstract(section)) {
        buf
          ..writeln(r'\begin{abstract}')
          ..writeln(text.isEmpty ? 'To be written.' : text)
          ..writeln(r'\end{abstract}')
          ..writeln();
      } else if (_isKeywords(section)) {
        final keywords = _cleanKeywords(_plainForLatex(section.en));
        buf
          ..writeln(
            '\\noindent\\textbf{Keywords:} ${_latexText(keywords.isEmpty ? 'To be written.' : keywords)}',
          )
          ..writeln();
      } else if (_isReferences(section)) {
        buf
          ..writeln(r'\section*{References}')
          ..writeln(text.isEmpty ? 'To be written.' : text)
          ..writeln();
      } else {
        sectionNo++;
        buf
          ..writeln(
            '\\section{${_latexText(_stripSectionNumber(sectionTitle, sectionNo))}}',
          )
          ..writeln(text.isEmpty ? 'To be written.' : text)
          ..writeln();
      }
    }
    buf
      ..writeln(r'\end{document}')
      ..writeln();
    return buf.toString();
  }

  String _renderChineseLatexDocument(PaperDraft draft) {
    final title = draft.titleZh.trim().isEmpty ? '未命名论文' : draft.titleZh;
    final buf = StringBuffer()
      ..writeln(r'\documentclass[12pt,a4paper]{ctexart}')
      ..writeln(r'\usepackage[margin=1in]{geometry}')
      ..writeln(r'\usepackage{fontspec}')
      ..writeln(r'\usepackage{setspace}')
      ..writeln(r'\usepackage{indentfirst}')
      ..writeln(r'\usepackage{amsmath,amssymb}')
      ..writeln(r'\usepackage{booktabs,longtable,array}')
      ..writeln(r'\usepackage[table]{xcolor}')
      ..writeln(r'\usepackage{graphicx}')
      ..writeln(r'\usepackage{caption}')
      ..writeln(r'\usepackage[hidelinks]{hyperref}')
      ..writeln(r'\setmainfont{Times New Roman}')
      ..writeln(r'\setCJKmainfont{SimSun}')
      ..writeln(r'\setCJKsansfont{SimHei}')
      ..writeln(r'\providecommand{\citet}[2][]{\cite{#2}}')
      ..writeln(r'\providecommand{\citep}[2][]{\cite{#2}}')
      ..writeln(r'\providecommand{\textcite}[2][]{\cite{#2}}')
      ..writeln(r'\providecommand{\parencite}[2][]{\cite{#2}}')
      ..writeln(r'\providecommand{\autocite}[2][]{\cite{#2}}')
      ..writeln(r'\providecommand{\citeauthor}[2][]{#2}')
      ..writeln(r'\providecommand{\citeyear}[2][]{n.d.}')
      ..writeln(_latexAlgorithmDefinitions())
      ..writeln(r'\onehalfspacing')
      ..writeln(r'\setlength{\parindent}{2em}')
      ..writeln(r'\setlength{\parskip}{0pt}')
      ..writeln('\\title{${_latexText(title)}}')
      ..writeln(r'\author{}')
      ..writeln(r'\date{}')
      ..writeln(r'\begin{document}')
      ..writeln(r'\maketitle')
      ..writeln();
    for (final section in draft.sections) {
      final sectionTitle = section.zhTitle.trim().isEmpty
          ? '未命名章节'
          : section.zhTitle.trim();
      final text = _sectionLatexBlocks(
        section.zh,
        sectionTitle: sectionTitle,
        english: false,
      );
      if (_isAbstract(section)) {
        buf
          ..writeln(r'\section*{摘要}')
          ..writeln(text.isEmpty ? '待撰写。' : text)
          ..writeln();
      } else if (_isKeywords(section)) {
        final keywords = _cleanKeywords(_plainForLatex(section.zh));
        buf
          ..writeln(
            '\\noindent\\textbf{关键词：}${_latexText(keywords.isEmpty ? '待撰写。' : keywords)}',
          )
          ..writeln();
      } else if (_isReferences(section)) {
        buf
          ..writeln(r'\section*{参考文献}')
          ..writeln(text.isEmpty ? '待撰写。' : text)
          ..writeln();
      } else {
        buf
          ..writeln(
            '\\section{${_latexText(_stripSectionNumber(sectionTitle))}}',
          )
          ..writeln(text.isEmpty ? '待撰写。' : text)
          ..writeln();
      }
    }
    buf
      ..writeln(r'\end{document}')
      ..writeln();
    return buf.toString();
  }

  Future<void> _compileLatexPdf({
    required String tex,
    required File output,
    required String jobName,
    bool tolerant = false,
  }) async {
    final compiler = await _resolveXelatex();
    final temp = await getTemporaryDirectory();
    final buildDir = Directory(
      p.join(
        temp.path,
        'mind_latex_export_${DateTime.now().microsecondsSinceEpoch}_$jobName',
      ),
    );
    await buildDir.create(recursive: true);
    final texFile = File(p.join(buildDir.path, '$jobName.tex'));
    await texFile.writeAsString(tex);
    final built = File(p.join(buildDir.path, '$jobName.pdf'));
    ProcessResult? lastResult;
    for (var i = 0; i < 2; i++) {
      lastResult = await Process.run(
        compiler,
        [
          '-interaction=nonstopmode',
          // 容错模式下不加 -halt-on-error：让 xelatex 跳过个别错误继续排版，
          // 最终仍能产出 best-effort 的 PDF；严格模式遇错即停以暴露语法问题。
          if (!tolerant) '-halt-on-error',
          '-file-line-error',
          '-output-directory',
          buildDir.path,
          texFile.path,
        ],
        workingDirectory: buildDir.path,
        runInShell: compiler == 'xelatex',
      );
      // 严格模式：任一遍非零退出即失败。容错模式：只看最终是否产出 PDF。
      if (!tolerant && lastResult.exitCode != 0) {
        final logFile = File(p.join(buildDir.path, '$jobName.log'));
        throw Exception(
          'LaTeX 编译失败：${await _latexFailureMessage(lastResult, logFile)}',
        );
      }
    }
    if (!await built.exists()) {
      if (tolerant) {
        final logFile = File(p.join(buildDir.path, '$jobName.log'));
        throw Exception(
          'LaTeX 未能生成 PDF：${await _latexFailureMessage(lastResult!, logFile)}',
        );
      }
      throw Exception('LaTeX 未生成 PDF：${built.path}');
    }
    await output.parent.create(recursive: true);
    await built.copy(output.path);
  }

  // ---------------------------------------------------------------------------
  // pandoc：Markdown → PDF（表格 / 公式 / 标题排版更规范，支持嵌入图片）
  // ---------------------------------------------------------------------------

  Future<void> _pandocPdf({
    required String markdown,
    required File output,
    required String jobName,
    required bool english,
  }) async {
    final pandoc = await _resolvePandoc();
    final xelatex = await _resolveXelatex();
    final temp = await getTemporaryDirectory();
    final buildDir = Directory(
      p.join(
        temp.path,
        'mind_pandoc_${DateTime.now().microsecondsSinceEpoch}_$jobName',
      ),
    );
    await buildDir.create(recursive: true);
    final mdFile = File(p.join(buildDir.path, '$jobName.md'));
    await mdFile.writeAsString(markdown);
    final pdfPath = p.join(buildDir.path, '$jobName.pdf');
    final args = <String>[
      mdFile.path,
      '-o', pdfPath,
      '--pdf-engine=$xelatex',
      '-V', 'geometry:margin=1in',
      '-V', 'linkcolor:blue',
      '-V', 'mainfont=Times New Roman',
      // 中文用宋体（正文）/ 黑体（无衬线），英文稿也带上 CJK 字体以防中英混排。
      '-V', 'CJKmainfont=SimSun',
      '--variable', 'fontsize=12pt',
      '--resource-path', buildDir.path,
    ];
    final result = await Process.run(
      pandoc,
      args,
      workingDirectory: buildDir.path,
      runInShell: pandoc == 'pandoc',
    );
    final built = File(pdfPath);
    if (!await built.exists()) {
      final err = '${result.stdout}\n${result.stderr}'.trim();
      throw Exception('pandoc 生成 PDF 失败：${clip(err, 1800)}');
    }
    await output.parent.create(recursive: true);
    await built.copy(output.path);
  }

  Future<String> _resolvePandoc() async {
    try {
      final r = await Process.run('pandoc', ['--version'], runInShell: true);
      if (r.exitCode == 0) return 'pandoc';
    } catch (_) {}
    final env = Platform.environment;
    final candidates = <String>[
      if ((env['LOCALAPPDATA'] ?? '').isNotEmpty)
        p.join(env['LOCALAPPDATA']!, 'Pandoc', 'pandoc.exe'),
      if ((env['ProgramFiles'] ?? '').isNotEmpty)
        p.join(env['ProgramFiles']!, 'Pandoc', 'pandoc.exe'),
      if ((env['ProgramFiles(x86)'] ?? '').isNotEmpty)
        p.join(env['ProgramFiles(x86)']!, 'Pandoc', 'pandoc.exe'),
    ];
    for (final path in candidates) {
      if (await File(path).exists()) return path;
    }
    throw Exception(
      '未检测到 pandoc。Markdown 论文的 PDF 导出依赖 pandoc，请安装后重试：\n'
      'winget install --id JohnMacFarlane.Pandoc\n'
      '（或到 https://pandoc.org/installing.html 下载安装，安装后重启应用）。',
    );
  }

  // ---------------------------------------------------------------------------
  // 图表：由模型据正文产出图谱，交给 matplotlib 出高清 PNG 并保存原图
  // ---------------------------------------------------------------------------

  /// 生成论文配图：结合全文与研究基线产出图谱（方法框架流程图 + 结果图），
  /// 调用本机 matplotlib 出 300 DPI 高清 PNG，保存到知识库并嵌入论文。
  Future<void> generateFigures(PaperLang lang, [PaperDraft? target]) async {
    final draft = target ?? current;
    if (draft == null || busy) return;
    final english = lang == PaperLang.en;
    final paperText = _fullPaperText(draft, english: english);
    if (paperText.trim().isEmpty && draft.factBaseline.trim().isEmpty) {
      stage = '请先写出稿件或确立研究基线，再生成图表';
      notifyListeners();
      return;
    }
    _begin('正在规划论文图表…');
    try {
      final python = await _resolvePython();
      final specs = await _planFigures(draft, english: english);
      if (_cancel) return;
      if (specs.isEmpty) {
        stage = '模型未产出可用的图表';
        return;
      }
      stage = '正在用 matplotlib 渲染高清图…';
      notifyListeners();
      final outDir = Directory(
        p.join(settings.vaultPath, '4-书稿', '论文', 'figures', draft.id),
      );
      await outDir.create(recursive: true);
      final temp = await getTemporaryDirectory();
      final buildDir = Directory(
        p.join(temp.path, 'mind_figs_${DateTime.now().microsecondsSinceEpoch}'),
      );
      await buildDir.create(recursive: true);
      final specFile = File(p.join(buildDir.path, 'figures.json'));
      await specFile.writeAsString(jsonEncode({'figures': specs}));
      final scriptFile = File(p.join(buildDir.path, 'render.py'));
      await scriptFile.writeAsString(_pythonFigureScript);
      final result = await Process.run(
        python.first,
        [...python.skip(1), scriptFile.path, specFile.path, outDir.path],
        runInShell: true,
      );
      if (result.exitCode != 0) {
        throw Exception(
          '图表渲染失败（请确认已安装 matplotlib）：'
          '${clip('${result.stdout}\n${result.stderr}'.trim(), 1200)}',
        );
      }
      final figures = <PaperFigure>[];
      for (final spec in specs) {
        final id = (spec['id'] ?? '').toString();
        if (id.isEmpty) continue;
        final png = File(p.join(outDir.path, '$id.png'));
        figures.add(
          PaperFigure(
            id: id,
            kind: (spec['kind'] ?? 'bar').toString(),
            titleZh: (spec['titleZh'] ?? '').toString(),
            titleEn: (spec['titleEn'] ?? '').toString(),
            captionZh: (spec['captionZh'] ?? '').toString(),
            captionEn: (spec['captionEn'] ?? '').toString(),
            section: (spec['section'] ?? '').toString(),
            pngPath: await png.exists() ? png.path : '',
          ),
        );
      }
      draft.figures = figures.where((f) => f.hasImage).toList();
      draft.updatedAt = DateTime.now();
      final ok = draft.figures.length;
      stage = ok == 0 ? '未成功生成图表' : '已生成 $ok 张高清图并保存原图 PNG';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '生成图表失败：$e';
    } finally {
      _end();
    }
  }

  Future<List<Map<String, dynamic>>> _planFigures(
    PaperDraft draft, {
    required bool english,
  }) async {
    final reply = await _chat([
      {
        'role': 'system',
        'content':
            '你是科研论文的图表设计专家。你依据论文正文与研究基线设计专业、抽象的插图，'
            '所有标签必须抽象（不得出现文件名/函数/库/机器型号等实现痕迹），且图中数据必须与正文一致。'
            '只输出 JSON，不要解释。',
      },
      {
        'role': 'user',
        'content':
            '''
请为下面这篇论文设计 2-4 张专业配图，供 matplotlib 渲染。要求：
- 必须包含 1 张“方法框架/流程图”（kind=flow，section=methods）；
- 其余为结果图（section=results），数据取自论文正文表格/数值，须与正文完全一致；
- 所有文字标签抽象、学术化，不出现任何具体工程实现痕迹。

各 figure 字段规范（按 kind 提供对应数据）：
- 通用：id（如 fig1）、kind、section（methods/results）、titleZh、titleEn、captionZh、captionEn
- kind=flow：nodes（字符串数组，流程节点，用通用术语）、edges（如 [[0,1],[1,2]]）
- kind=bar：categories（字符串数组）、series（[{"name":"","values":[数值]}]，单序列即可）、ylabel
- kind=grouped_bar：categories、series（多个 {"name","values"}）、ylabel
- kind=line：x（数组）、series（[{"name","values"}]）、xlabel、ylabel
- kind=heatmap 或 confusion：xlabels、ylabels、matrix（二维数值数组）

严格输出 JSON：{"figures":[ {...}, {...} ]}

统一研究设定 / 事实基线：
${draft.factBaseline.trim().isEmpty ? '（无）' : clip(draft.factBaseline, 4000)}

论文正文：
${paperText(draft, english)}
''',
      },
    ], jsonMode: true);
    final obj = ModelClient.parseJsonObject(reply);
    final list = <Map<String, dynamic>>[];
    for (final raw in ((obj['figures'] as List?) ?? []).whereType<Map>()) {
      list.add(raw.cast<String, dynamic>());
    }
    return list;
  }

  String paperText(PaperDraft draft, bool english) =>
      clip(_fullPaperText(draft, english: english), 12000);

  Future<List<String>> _resolvePython() async {
    for (final cmd in [
      ['python'],
      ['py', '-3'],
      ['python3'],
    ]) {
      try {
        final r = await Process.run(
          cmd.first,
          [...cmd.skip(1), '--version'],
          runInShell: true,
        );
        if (r.exitCode == 0) return cmd;
      } catch (_) {}
    }
    throw Exception('未检测到 Python。生成图表依赖本机 Python + matplotlib，请安装后重试。');
  }

  static const String _pythonFigureScript = r'''
import sys, json, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
import numpy as np

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False
DPI = 300


def _save(fig, path):
    fig.savefig(path, dpi=DPI, bbox_inches="tight")
    plt.close(fig)


def draw_flow(spec, path):
    nodes = spec.get("nodes", [])
    edges = spec.get("edges", [])
    n = len(nodes)
    if n == 0:
        return
    fig, ax = plt.subplots(figsize=(6.2, max(2.2, n * 1.15)))
    ax.axis("off")
    ys = []
    h = 0.72
    for i, label in enumerate(nodes):
        y = n - i
        ys.append(y)
        box = FancyBboxPatch((0.5, y - h / 2), 3.0, h,
                             boxstyle="round,pad=0.12",
                             fc="#E8F1FF", ec="#2B6CB0", lw=1.6)
        ax.add_patch(box)
        ax.text(2.0, y, label, ha="center", va="center", fontsize=11)
    if not edges:
        edges = [[i, i + 1] for i in range(n - 1)]
    for e in edges:
        a, b = int(e[0]), int(e[1])
        if 0 <= a < n and 0 <= b < n:
            arr = FancyArrowPatch((2.0, ys[a] - h / 2), (2.0, ys[b] + h / 2),
                                  arrowstyle="-|>", mutation_scale=16,
                                  lw=1.5, color="#2B6CB0")
            ax.add_patch(arr)
    ax.set_xlim(0, 4)
    ax.set_ylim(0.2, n + 0.9)
    _save(fig, path)


def draw_bar(spec, path):
    cats = spec.get("categories", [])
    series = spec.get("series", [])
    if not series and "values" in spec:
        series = [{"name": "", "values": spec["values"]}]
    fig, ax = plt.subplots(figsize=(6.4, 4.2))
    x = np.arange(len(cats))
    palette = ["#4C78A8", "#F58518", "#54A24B", "#E45756", "#72B7B2"]
    if len(series) <= 1:
        vals = series[0]["values"] if series else []
        ax.bar(x, vals, color=palette[0], width=0.6)
        for xi, v in zip(x, vals):
            ax.text(xi, v, str(v), ha="center", va="bottom", fontsize=9)
    else:
        w = 0.8 / len(series)
        for i, s in enumerate(series):
            ax.bar(x + i * w - 0.4 + w / 2, s["values"], w,
                   label=s.get("name", ""), color=palette[i % len(palette)])
        ax.legend()
    ax.set_xticks(x)
    ax.set_xticklabels(cats)
    if spec.get("ylabel"):
        ax.set_ylabel(spec["ylabel"])
    if spec.get("titleZh"):
        ax.set_title(spec["titleZh"])
    ax.grid(axis="y", ls="--", alpha=0.4)
    _save(fig, path)


def draw_line(spec, path):
    x = spec.get("x", [])
    fig, ax = plt.subplots(figsize=(6.4, 4.2))
    for s in spec.get("series", []):
        ax.plot(x, s["values"], marker="o", lw=1.8, label=s.get("name", ""))
    if spec.get("series"):
        ax.legend()
    ax.set_xlabel(spec.get("xlabel", ""))
    ax.set_ylabel(spec.get("ylabel", ""))
    if spec.get("titleZh"):
        ax.set_title(spec["titleZh"])
    ax.grid(ls="--", alpha=0.4)
    _save(fig, path)


def draw_heatmap(spec, path):
    m = np.array(spec.get("matrix", []), dtype=float)
    if m.size == 0:
        return
    xl = spec.get("xlabels", [])
    yl = spec.get("ylabels", [])
    fig, ax = plt.subplots(figsize=(5.4, 4.4))
    im = ax.imshow(m, cmap="Blues")
    if xl:
        ax.set_xticks(range(len(xl)))
        ax.set_xticklabels(xl)
    if yl:
        ax.set_yticks(range(len(yl)))
        ax.set_yticklabels(yl)
    mx = m.max() if m.size else 1
    for i in range(m.shape[0]):
        for j in range(m.shape[1]):
            v = m[i, j]
            txt = str(int(v)) if float(v).is_integer() else str(round(v, 2))
            ax.text(j, i, txt, ha="center", va="center",
                    color="white" if v > mx / 2 else "black")
    if spec.get("titleZh"):
        ax.set_title(spec["titleZh"])
    fig.colorbar(im)
    _save(fig, path)


def main():
    specs_path, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    with open(specs_path, encoding="utf-8") as f:
        data = json.load(f)
    for spec in data.get("figures", []):
        kind = spec.get("kind", "bar")
        fid = spec.get("id", "fig")
        path = os.path.join(outdir, fid + ".png")
        try:
            if kind == "flow":
                draw_flow(spec, path)
            elif kind in ("heatmap", "confusion"):
                draw_heatmap(spec, path)
            elif kind == "line":
                draw_line(spec, path)
            else:
                draw_bar(spec, path)
            print("OK", fid)
        except Exception as e:
            print("ERR", fid, str(e))


main()
''';

  Future<String> _latexFailureMessage(
    ProcessResult result,
    File logFile,
  ) async {
    final log = await logFile.exists() ? await logFile.readAsString() : '';
    final source = log.trim().isEmpty
        ? '${result.stdout}\n${result.stderr}'
        : log;
    final lines = source.split(RegExp(r'\r?\n'));
    final interesting = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final isError =
          line.startsWith('!') ||
          RegExp(r'\.tex:\d+:').hasMatch(line) ||
          RegExp(r'^l\.\d+').hasMatch(line) ||
          line.contains('Undefined control sequence') ||
          line.contains('Missing \$ inserted') ||
          line.contains('LaTeX Error') ||
          line.contains('Fatal error') ||
          line.contains('Emergency stop');
      if (!isError) continue;
      final start = i - 1 < 0 ? 0 : i - 1;
      final end = i + 4 > lines.length ? lines.length : i + 4;
      interesting.add(lines.sublist(start, end).join('\n'));
      if (interesting.length >= 3) break;
    }
    final message = interesting.isEmpty ? source : interesting.join('\n\n');
    return clip(message, 1800);
  }

  Future<String> _resolveXelatex() async {
    final result = await Process.run('xelatex', [
      '--version',
    ], runInShell: true);
    if (result.exitCode != 0) {
      final paths = _candidateXelatexPaths();
      for (final path in paths) {
        if (await File(path).exists()) return path;
      }
      throw Exception(
        '未检测到 xelatex。已检查 PATH 和 MiKTeX/TeX Live 常见安装目录，请将 MiKTeX 的 miktex\\bin\\x64 目录加入 PATH 后再导出。',
      );
    }
    return 'xelatex';
  }

  List<String> _candidateXelatexPaths() {
    final env = Platform.environment;
    final candidates = <String>[
      if ((env['LOCALAPPDATA'] ?? '').isNotEmpty)
        p.join(
          env['LOCALAPPDATA']!,
          'Programs',
          'MiKTeX',
          'miktex',
          'bin',
          'x64',
          'xelatex.exe',
        ),
      if ((env['LOCALAPPDATA'] ?? '').isNotEmpty)
        p.join(
          env['LOCALAPPDATA']!,
          'Programs',
          'MiKTeX 2.9',
          'miktex',
          'bin',
          'x64',
          'xelatex.exe',
        ),
      if ((env['ProgramFiles'] ?? '').isNotEmpty)
        p.join(
          env['ProgramFiles']!,
          'MiKTeX',
          'miktex',
          'bin',
          'x64',
          'xelatex.exe',
        ),
      if ((env['ProgramFiles'] ?? '').isNotEmpty)
        p.join(
          env['ProgramFiles']!,
          'MiKTeX 2.9',
          'miktex',
          'bin',
          'x64',
          'xelatex.exe',
        ),
      if ((env['ProgramFiles(x86)'] ?? '').isNotEmpty)
        p.join(
          env['ProgramFiles(x86)']!,
          'MiKTeX',
          'miktex',
          'bin',
          'xelatex.exe',
        ),
      if ((env['ProgramFiles(x86)'] ?? '').isNotEmpty)
        p.join(
          env['ProgramFiles(x86)']!,
          'MiKTeX 2.9',
          'miktex',
          'bin',
          'xelatex.exe',
        ),
      for (final year in ['2026', '2025', '2024'])
        p.join('C:\\', 'texlive', year, 'bin', 'windows', 'xelatex.exe'),
    ];
    return candidates;
  }

  String _sectionLatexBlocks(
    String value, {
    required String sectionTitle,
    required bool english,
  }) {
    final text = _stripSectionLead(
      _stripCodeFences(_normalizeLatexGlyphs(value)),
      sectionTitle,
    ).trim();
    if (text.isEmpty) return '';

    final buf = StringBuffer();
    final paragraph = <String>[];
    String? listEnv;
    var inLatexEnvironment = false;
    var inDisplayMath = false;

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      buf
        ..writeln(_latexInline(paragraph.join(' ')))
        ..writeln();
      paragraph.clear();
    }

    void closeList() {
      if (listEnv == null) return;
      buf
        ..writeln('\\end{$listEnv}')
        ..writeln();
      listEnv = null;
    }

    void openList(String env) {
      if (listEnv == env) return;
      closeList();
      buf.writeln('\\begin{$env}');
      listEnv = env;
    }

    for (final rawLine in text.replaceAll('\r\n', '\n').split('\n')) {
      final line = rawLine.trim();
      if (inDisplayMath) {
        if (line.isEmpty) continue;
        if (line == r'\]') {
          buf
            ..writeln(r'\end{equation*}')
            ..writeln();
          inDisplayMath = false;
        } else {
          buf.writeln(line);
        }
        continue;
      }
      if (line.isEmpty || _isDiscardedLatexLine(line)) {
        flushParagraph();
        closeList();
        continue;
      }

      if (line == r'\[') {
        flushParagraph();
        closeList();
        inDisplayMath = true;
        buf.writeln(r'\begin{equation*}');
        continue;
      }
      if (line == r'\]') {
        continue;
      }

      if (line.startsWith(r'\begin{')) {
        flushParagraph();
        closeList();
        inLatexEnvironment = true;
        buf.writeln(_latexEnvironmentLine(line));
        continue;
      }
      if (line.startsWith(r'\end{')) {
        flushParagraph();
        closeList();
        buf
          ..writeln(line)
          ..writeln();
        inLatexEnvironment = false;
        continue;
      }
      if (inLatexEnvironment) {
        flushParagraph();
        closeList();
        buf.writeln(_latexEnvironmentLine(line));
        continue;
      }

      final heading = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(line);
      if (heading != null) {
        flushParagraph();
        closeList();
        final level = heading.group(1)!.length;
        final title = _latexText(heading.group(2)!.trim());
        final command = level <= 2 ? 'subsection' : 'subsubsection';
        buf
          ..writeln('\\$command*{$title}')
          ..writeln();
        continue;
      }

      final latexHeading = RegExp(
        r'^\\(?:sub)*section\*?\{(.+)\}$',
      ).firstMatch(line);
      if (latexHeading != null) {
        flushParagraph();
        closeList();
        final headingTitle = latexHeading.group(1)!.trim();
        if (_sameSectionTitle(headingTitle, sectionTitle)) continue;
        buf
          ..writeln('\\subsection*{${_latexText(headingTitle)}}')
          ..writeln();
        continue;
      }

      final bullet = RegExp(r'^[-*+]\s+(.+)$').firstMatch(line);
      if (bullet != null) {
        flushParagraph();
        openList('itemize');
        buf.writeln(r'\item ' + _latexInline(bullet.group(1)!.trim()));
        continue;
      }

      final numbered = RegExp(r'^\d+[.)、]\s+(.+)$').firstMatch(line);
      if (numbered != null) {
        flushParagraph();
        openList('enumerate');
        buf.writeln(r'\item ' + _latexInline(numbered.group(1)!.trim()));
        continue;
      }

      closeList();
      paragraph.add(_stripInlineMarkdown(line));
      flushParagraph();
    }

    flushParagraph();
    closeList();
    return buf.toString().trim();
  }

  static String _latexInline(String value) {
    return _escapeLatexKeepingMath(_stripInlineMarkdown(value));
  }

  /// 转义纯文本里的 LaTeX 特殊字符，但原样保留行内/行间公式（`$...$`、`\(...\)`、
  /// `\[...\]`）以及已有的 LaTeX 命令与其 {} / [] 参数。避免把 Markdown 正文里的
  /// `_`、`%`、`&`、`#` 等直接送进 LaTeX 造成 “Missing $ inserted” 等编译错误。
  static final RegExp _latexCommandPrefix = RegExp(r'\\[a-zA-Z]+\*?');

  /// 修复 LLM 在 Markdown 里常写出的残缺行内公式：给后面没有参数的上/下标符号
  /// （`^`、`_`）补一个空组 `{}`，并去掉公式末尾孤立的反斜杠，避免 xelatex 报
  /// “Missing { inserted” 或未闭合命令而中断整篇编译。
  static String _sanitizeMathBody(String math) {
    var m = math;
    // `^` / `_` 后面紧跟空白、闭合括号或到结尾（即缺少上/下标参数）时补 `{}`；
    // 不动 `^\alpha`、`x^2`、`x^{...}` 这类本就合法的写法。
    m = m.replaceAllMapped(
      RegExp(r'[_^](?=\s|\)|\]|$)'),
      (match) => '${match.group(0)}{}',
    );
    // 去掉结尾孤立的反斜杠（非合法命令的残留）。
    m = m.replaceFirst(RegExp(r'\\+\s*$'), '');
    return m;
  }

  static String _escapeLatexKeepingMath(String s) {
    final buf = StringBuffer();
    var i = 0;
    while (i < s.length) {
      final ch = s[i];
      // 行内公式 $...$（成对才视为公式，孤立的 $ 走转义分支）。
      if (ch == r'$') {
        final end = s.indexOf(r'$', i + 1);
        if (end > i) {
          buf.write('\$${_sanitizeMathBody(s.substring(i + 1, end))}\$');
          i = end + 1;
          continue;
        }
      }
      if (ch == '\\' && i + 1 < s.length) {
        final next = s[i + 1];
        // \( ... \) 与 \[ ... \] 公式，原样保留（并修复残缺的上下标）。
        if (next == '(' || next == '[') {
          final close = next == '(' ? r'\)' : r'\]';
          final end = s.indexOf(close, i + 2);
          if (end > i) {
            final open = s.substring(i, i + 2);
            buf.write('$open${_sanitizeMathBody(s.substring(i + 2, end))}$close');
            i = end + 2;
            continue;
          }
        }
        // \command 及其紧跟的 {...} / [...] 参数（含嵌套）原样保留。
        final cmd = _latexCommandPrefix.matchAsPrefix(s, i);
        if (cmd != null) {
          buf.write(cmd.group(0));
          var j = cmd.end;
          while (j < s.length && (s[j] == '{' || s[j] == '[')) {
            final open = s[j];
            final closeCh = open == '{' ? '}' : ']';
            var depth = 0;
            final start = j;
            while (j < s.length) {
              if (s[j] == open) {
                depth++;
              } else if (s[j] == closeCh) {
                depth--;
                if (depth == 0) {
                  j++;
                  break;
                }
              }
              j++;
            }
            buf.write(s.substring(start, j));
          }
          i = j;
          continue;
        }
        // \ 后跟非字母（如 \\、\%、\_、\&、\$ 等）：两字符原样保留。
        buf.write(s.substring(i, i + 2));
        i += 2;
        continue;
      }
      buf.write(switch (ch) {
        '{' => r'\{',
        '}' => r'\}',
        '&' => r'\&',
        '%' => r'\%',
        '#' => r'\#',
        '_' => r'\_',
        r'$' => r'\$',
        '~' => r'\textasciitilde{}',
        '^' => r'\textasciicircum{}',
        '\\' => r'\textbackslash{}',
        _ => ch,
      });
      i++;
    }
    return buf.toString();
  }

  static String _latexEnvironmentLine(String line) {
    final include = RegExp(
      r'\\includegraphics(?:\[[^\]]*\])?\{([^}]+)\}',
    ).firstMatch(line);
    if (include == null) return line;
    final name = _latexText(include.group(1) ?? 'figure');
    return r'\fbox{\parbox{0.85\linewidth}{\centering Figure placeholder: ' +
        name +
        r'}}';
  }

  static String _latexAlgorithmDefinitions() => r'''
\newenvironment{algorithm}[1][]{\begin{figure}[htbp]\small}{\end{figure}}
\newenvironment{algorithmic}[1][]{\begin{enumerate}}{\end{enumerate}}
\providecommand{\Require}{\item[\textbf{Require:}]}
\providecommand{\Ensure}{\item[\textbf{Ensure:}]}
\providecommand{\State}{\item}
\providecommand{\For}[1]{\item \textbf{for} #1}
\providecommand{\ForAll}[1]{\item \textbf{for all} #1}
\providecommand{\EndFor}{}
\providecommand{\If}[1]{\item \textbf{if} #1}
\providecommand{\Else}{\item \textbf{else}}
\providecommand{\EndIf}{}
\providecommand{\While}[1]{\item \textbf{while} #1}
\providecommand{\EndWhile}{}
\providecommand{\Procedure}[2]{\item \textbf{procedure} #1(#2)}
\providecommand{\EndProcedure}{}
\providecommand{\Return}{\item[\textbf{return}]}
\providecommand{\Comment}[1]{\hfill$\triangleright$ #1}
''';

  static bool _sameSectionTitle(String left, String right) {
    String normalize(String value) =>
        _stripSectionNumber(value).replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalize(left).toLowerCase() == normalize(right).toLowerCase();
  }

  static String _stripCodeFences(String value) => value
      .replaceAll(RegExp(r'```[a-zA-Z0-9_-]*\s*'), '')
      .replaceAll('```', '');

  static String _stripInlineMarkdown(String value) {
    var text = value;
    text = text.replaceAllMapped(
      RegExp(r'!\[([^\]]*)\]\([^)]+\)'),
      (match) => match.group(1) ?? '',
    );
    text = text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]+\)'),
      (match) => match.group(1) ?? '',
    );
    text = text.replaceAllMapped(
      RegExp(r'\*\*([^*]+)\*\*'),
      (match) => match.group(1) ?? '',
    );
    text = text.replaceAllMapped(
      RegExp(r'\*([^*]+)\*'),
      (match) => match.group(1) ?? '',
    );
    text = text.replaceAllMapped(
      RegExp(r'`([^`]+)`'),
      (match) => match.group(1) ?? '',
    );
    return text.replaceAll(RegExp(r'<[^>]+>'), '').trim();
  }

  static bool _isDiscardedLatexLine(String line) {
    if (_isDiscardedPdfLine(line)) return true;
    if (RegExp(r'^\d+(?:\.\d+)*$').hasMatch(line)) return true;
    if (RegExp(r'^\[?(?:htbp|H|t|b|p)\]?$').hasMatch(line)) return true;
    if (RegExp(r'^[lcr|]{2,}$').hasMatch(line)) return true;
    return false;
  }

  static String _latexText(String value) {
    final buf = StringBuffer();
    for (final rune in _normalizeLatexGlyphs(value).runes) {
      final char = String.fromCharCode(rune);
      buf.write(switch (char) {
        '\\' => r'\textbackslash{}',
        '{' => r'\{',
        '}' => r'\}',
        '&' => r'\&',
        '%' => r'\%',
        r'$' => r'\$',
        '#' => r'\#',
        '_' => r'\_',
        '~' => r'\textasciitilde{}',
        '^' => r'\textasciicircum{}',
        _ => char,
      });
    }
    return buf.toString();
  }

  static String _stripSectionNumber(String title, [int? number]) {
    var cleaned = title.trim();
    if (number != null) {
      cleaned = cleaned.replaceFirst(RegExp('^$number[.、]\\s*'), '');
    }
    return cleaned.replaceFirst(RegExp(r'^\d+(?:\.\d+)*[.、]?\s*'), '');
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
    } catch (_) {
      // 打开目录失败不影响 PDF 导出结果。
    }
  }

  String _renderLatex(PaperDraft draft, {bool english = false}) {
    final title = english ? draft.titleEn : draft.titleZh;
    final buf = StringBuffer()
      ..writeln(r'\documentclass[11pt]{article}')
      ..writeln(r'\usepackage[UTF8]{ctex}')
      ..writeln(r'\usepackage{geometry}')
      ..writeln(r'\geometry{a4paper, margin=1in}')
      ..writeln('\\title{${_escapeLatex(title)}}')
      ..writeln(r'\author{}')
      ..writeln(r'\date{}')
      ..writeln(r'\begin{document}')
      ..writeln(r'\maketitle')
      ..writeln();
    for (final section in draft.sections) {
      final sectionTitle = english ? section.enTitle : section.zhTitle;
      final body = english ? section.en : section.zh;
      buf
        ..writeln('\\section{${_escapeLatex(sectionTitle)}}')
        ..writeln(
          body.trim().isEmpty
              ? (english ? 'To be written.' : '待撰写。')
              : body.trim(),
        )
        ..writeln();
    }
    if (!english) {
      buf
        ..writeln(r'\clearpage')
        ..writeln(
          '\\title{${_escapeLatex(draft.titleEn.isEmpty ? 'English Draft' : draft.titleEn)}}',
        )
        ..writeln(r'\maketitle')
        ..writeln();
      for (final section in draft.sections) {
        buf
          ..writeln('\\section{${_escapeLatex(section.enTitle)}}')
          ..writeln(
            section.en.trim().isEmpty ? 'To be written.' : section.en.trim(),
          )
          ..writeln();
      }
    }
    buf.writeln(r'\end{document}');
    return buf.toString();
  }

  void _begin(String message) {
    busy = true;
    _cancel = false;
    stage = message;
    progressLog
      ..clear()
      ..add(message);
    notifyListeners();
  }

  /// 追加一行实时进度，同时让状态栏这一行持续变化（让用户看到"在动"）。
  void _pushProgress(String line) {
    final t = line.trim();
    if (t.isEmpty) return;
    progressLog.add(t);
    if (progressLog.length > 200) {
      progressLog.removeRange(0, progressLog.length - 200);
    }
    stage = t;
    notifyListeners();
  }

  void _end() {
    busy = false;
    _cancel = false;
    notifyListeners();
  }

  Future<void> _persist() async {
    if (_store == null) return;
    await _store!.writeAsString(
      jsonEncode(papers.map((paper) => paper.toJson()).toList()),
    );
  }

  /// 论文写作类一次性调用：统一走 [ModelClient] 的 writing 角色通道。
  Future<String> _chat(
    List<Map<String, String>> messages, {
    bool jsonMode = false,
  }) async {
    final content = await ModelClient(settings, role: ModelRole.writing)
        .complete(
      messages: messages,
      jsonMode: jsonMode,
      isCancelled: () => _cancel,
    );
    if (content.isEmpty) throw Exception('模型未返回内容');
    return content;
  }

  static String _stripResearchPrefix(String title) =>
      title.replaceFirst(RegExp(r'^【研究】\s*'), '').trim();

  static bool _isAbstract(PaperSection section) =>
      section.id.toLowerCase().contains('abstract') ||
      section.enTitle.toLowerCase().contains('abstract') ||
      section.zhTitle.contains('摘要');

  static bool _isKeywords(PaperSection section) {
    final en = section.enTitle.toLowerCase();
    return section.id.toLowerCase().contains('keyword') ||
        en.contains('keyword') ||
        section.zhTitle.contains('关键词');
  }

  static bool _isReferences(PaperSection section) {
    final en = section.enTitle.toLowerCase();
    return section.id.toLowerCase().contains('reference') ||
        en.contains('reference') ||
        section.zhTitle.contains('参考');
  }

  static String _plainForLatex(String value, {String sectionTitle = ''}) {
    var text = _normalizeLatexGlyphs(value)
        .replaceAll(RegExp(r'```[a-zA-Z0-9_-]*\s*'), '')
        .replaceAll('```', '')
        .replaceAllMapped(
          RegExp(r'!\[([^\]]*)\]\([^)]+\)'),
          (match) => match.group(1) ?? '',
        )
        .replaceAllMapped(
          RegExp(r'\[([^\]]+)\]\([^)]+\)'),
          (match) => match.group(1) ?? '',
        )
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'^\s*\|?[-: ]{3,}\|?[-|: ]*$', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*\|', multiLine: true), '')
        .replaceAll(RegExp(r'\|\s*$', multiLine: true), '')
        .replaceAll('|', ' ')
        .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*>\s+', multiLine: true), '')
        .replaceAllMapped(
          RegExp(r'\*\*([^*]+)\*\*'),
          (match) => match.group(1) ?? '',
        )
        .replaceAllMapped(
          RegExp(r'\*([^*]+)\*'),
          (match) => match.group(1) ?? '',
        )
        .replaceAllMapped(RegExp(r'`([^`]+)`'), (match) => match.group(1) ?? '')
        .replaceAllMapped(
          RegExp(r'\\section\{([^}]+)\}'),
          (match) => match.group(1) ?? '',
        )
        .replaceAllMapped(
          RegExp(r'\\subsection\{([^}]+)\}'),
          (match) => match.group(1) ?? '',
        )
        .replaceAllMapped(
          RegExp(r'\\subsubsection\{([^}]+)\}'),
          (match) => match.group(1) ?? '',
        )
        .replaceAllMapped(
          RegExp(r'\\paragraph\{([^}]+)\}'),
          (match) => match.group(1) ?? '',
        )
        .replaceAllMapped(
          RegExp(r'\\textbf\{([^}]+)\}'),
          (match) => match.group(1) ?? '',
        )
        .replaceAllMapped(
          RegExp(r'\\emph\{([^}]+)\}'),
          (match) => match.group(1) ?? '',
        )
        .replaceAllMapped(
          RegExp(r'\\textit\{([^}]+)\}'),
          (match) => match.group(1) ?? '',
        )
        .replaceAll(RegExp(r'\\item\s*'), '')
        .replaceAll(RegExp(r'\\cite[t|p]?\{[^}]+\}'), '')
        .replaceAll(RegExp(r'\\ref\{[^}]+\}'), '')
        .replaceAll(RegExp(r'\\label\{[^}]+\}'), '')
        .replaceAll(RegExp(r'\\begin\{[^}]+\}|\\end\{[^}]+\}'), '')
        .replaceAll(RegExp(r'\\[a-zA-Z]+\*?'), '')
        .replaceAll(RegExp(r'\${1,2}'), '')
        .replaceAll(RegExp(r'[{}]'), '')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
    text = _normalizeLatexGlyphs(text).trim();
    return sectionTitle.trim().isEmpty
        ? text
        : _stripSectionLead(text, sectionTitle);
  }

  static String _stripSectionLead(String value, String title) {
    var text = value.trim();
    final t = title.trim();
    if (t.isEmpty || text.isEmpty) return text;
    final escaped = RegExp.escape(t);
    text = text
        .replaceFirst(
          RegExp('^$escaped\\s*[:：]?\\s*', caseSensitive: false),
          '',
        )
        .replaceFirst(
          RegExp(
            '^\\d+(?:\\.\\d+)*\\s+$escaped\\s*[:：]?\\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return text;
  }

  static String _cleanKeywords(String value) {
    return _stripSectionLead(value, 'Keywords')
        .replaceFirst(RegExp(r'^关键词\s*[:：]?\s*'), '')
        .replaceAll(RegExp(r'\s*;\s*'), '; ')
        .replaceAll(RegExp(r'\s*,\s*'), ', ')
        .trim();
  }

  static bool _isDiscardedPdfLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return true;
    if (trimmed == '---' || trimmed == '***') return true;
    if (RegExp(r'^[-=]{4,}$').hasMatch(trimmed)) return true;
    if (RegExp(
      r'^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$',
    ).hasMatch(trimmed)) {
      return true;
    }
    return false;
  }

  static String _normalizeLatexGlyphs(String value) => value
      .replaceAll('\u2010', '-')
      .replaceAll('\u2011', '-')
      .replaceAll('\u2012', '-')
      .replaceAll('\u2013', '-')
      .replaceAll('\u2014', '--')
      .replaceAll('\u2015', '--')
      .replaceAll('\u2018', "'")
      .replaceAll('\u2019', "'")
      .replaceAll('\u201A', "'")
      .replaceAll('\u201B', "'")
      .replaceAll('\u201C', '"')
      .replaceAll('\u201D', '"')
      .replaceAll('\u201E', '"')
      .replaceAll('\u2026', '...')
      .replaceAll('\u00A0', ' ');

  static String _escapeLatex(String value) => value
      .replaceAll(r'\', r'\textbackslash{}')
      .replaceAll('&', r'\&')
      .replaceAll('%', r'\%')
      .replaceAll(r'$', r'\$')
      .replaceAll('#', r'\#')
      .replaceAll('_', r'\_')
      .replaceAll('{', r'\{')
      .replaceAll('}', r'\}')
      .replaceAll('~', r'\textasciitilde{}')
      .replaceAll('^', r'\textasciicircum{}');
}
