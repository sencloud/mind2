import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'code_index_service.dart';
import 'project_service.dart';
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
    List<PaperSection>? sections,
  })  : linkedProjects = linkedProjects ?? [],
        topicOptions = topicOptions ?? [],
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
    sections: ((json['sections'] as List?) ?? [])
        .whereType<Map>()
        .map(
          (section) => PaperSection.fromJson(section.cast<String, dynamic>()),
        )
        .toList(),
  );
}

class PaperService extends ChangeNotifier {
  PaperService(this.settings, {this.project});

  final SettingsService settings;

  /// 项目服务（桌面端），用于「关联工程」时列出最近打开的工程；移动端为空。
  final ProjectService? project;

  /// 最近打开过的工程路径（供关联工程时快速选择）。
  List<String> get recentProjects => project?.projects ?? const [];

  final List<PaperDraft> papers = [];
  PaperDraft? current;
  PaperSection? activeSection;
  bool busy = false;
  String stage = '';

  bool _cancel = false;
  File? _store;
  http.Client? _client;

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
      await _ensureDigests(draft);
      if (_cancel) return;
      stage = '正在综合工程与研究，拟定候选选题…';
      notifyListeners();
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
    final projectBlock = _combinedProjectDigest(draft, 12000);
    final reply = await _chat([
      {
        'role': 'system',
        'content':
            '你是资深 SCI 期刊选题顾问。你结合真实工程实现与研究报告，给出可投稿、'
            '有明确创新点、且能被工程真实支撑的论文选题。只输出 JSON，不要解释。',
      },
      {
        'role': 'user',
        'content':
            '''
请结合下面的「关联工程真实解读」与「来源研究报告」（可能为空），为一篇可投稿的 SCI 期刊论文推荐 4-6 个候选选题（题目）。
要求：
- 每个选题必须能被关联工程的真实实现支撑（方法/实验/数据），突出创新点与研究问题，避免泛泛而谈；
- 给出具体、学术、可投稿的中文题目与英文题目；
- summary 用中文写清四点：研究问题、核心创新点、可用的工程支撑（对应到工程里的模块/方法/实验）、建议关键词。

严格输出 JSON：
{"topics":[{"titleZh":"...","titleEn":"...","summary":"研究问题：… 创新点：… 工程支撑：… 关键词：…"}]}

关联工程真实解读：
${projectBlock.isEmpty ? '（无）' : projectBlock}

来源研究报告标题：${draft.sourceResearchTitle.isEmpty ? '（无）' : draft.sourceResearchTitle}
来源研究报告正文：
${draft.sourceBody.trim().isEmpty ? '（无）' : _clip(draft.sourceBody, 8000)}
''',
      },
    ], jsonMode: true);
    final obj = _parseJson(reply);
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
      await _planPaper(draft);
      stage = '题目与结构已生成';
    } catch (e) {
      stage = _cancel ? '已停止' : '生成论文结构失败：$e';
    } finally {
      _end();
    }
  }

  Future<void> writeBilingualDraft([PaperDraft? target]) async {
    final draft = target ?? current;
    if (draft == null || busy) return;
    _begin('正在准备论文写作…');
    try {
      if (draft.sections.isEmpty || draft.titleEn.trim().isEmpty) {
        await _planPaper(draft);
      }
      if (_cancel) return;
      // 关联了工程但尚未解读：先逐个解读，确保方法/实验设置能引用真实实现。
      await _ensureDigests(draft);
      if (_cancel) return;
      final total = draft.sections.length;
      for (var i = 0; i < draft.sections.length; i++) {
        if (_cancel) break;
        final section = draft.sections[i];
        activeSection = section;
        section.zh = '';
        section.en = '';
        stage = '正在写中文稿：${section.zhTitle}（${i + 1}/$total）…';
        notifyListeners();
        section.zh = await _streamSection(draft, section, english: false);
        if (_cancel) break;
        stage = '正在写英文稿：${section.enTitle}（${i + 1}/$total）…';
        notifyListeners();
        section.en = await _streamSection(draft, section, english: true);
        draft.updatedAt = DateTime.now();
        await _persist();
      }
      stage = _cancel ? '已停止' : '论文双语草稿已完成';
    } catch (e) {
      stage = _cancel ? '已停止' : '论文写作失败：$e';
    } finally {
      _end();
      await _persist();
    }
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
    final context = await compute(_collectProjectContext, projectPath);
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
  static String _collectProjectContext(String rootPath) {
    const ignore = CodeIndexService.ignoreDirs;
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

    void walk(Directory dir, int depth) {
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final e in entries) {
        final name = p.basename(e.path);
        final lower = name.toLowerCase();
        if (e is Directory) {
          if (ignore.contains(name) || name.startsWith('.')) continue;
          if (depth < 4) walk(e, depth + 1);
        } else if (e is File) {
          final ext = p.extension(lower);
          if (lower.startsWith('readme') || (ext == '.md' && depth <= 1)) {
            docs.add(e);
          } else if (manifestNames.contains(lower)) {
            manifests.add(e);
          } else if (['.yaml', '.yml', '.toml', '.ini', '.cfg'].contains(ext) ||
              (ext == '.json' && depth <= 2)) {
            configs.add(e);
          } else if (srcExts.contains(ext)) {
            var score = depth <= 1 ? 1 : 0;
            for (final k in keywords) {
              if (lower.contains(k)) score += 2;
            }
            scored.add((score, e));
          }
        }
      }
    }

    walk(Directory(rootPath), 0);
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
    try {
      _client?.close();
    } catch (_) {}
    notifyListeners();
  }

  Future<List<String>> export() async {
    final draft = current;
    if (draft == null) throw StateError('未打开论文');
    final dir = Directory(p.join(settings.vaultPath, '4-书稿', '论文'));
    await dir.create(recursive: true);
    final baseName = _sanitize(draft.titleZh);
    final enFile = File(p.join(dir.path, '$baseName-英文稿.pdf'));
    final zhFile = File(p.join(dir.path, '$baseName-中文稿.pdf'));
    await _compileLatexPdf(
      tex: _renderEnglishLatexDocument(draft),
      output: enFile,
      jobName: 'paper_en',
    );
    await _compileLatexPdf(
      tex: _renderChineseLatexDocument(draft),
      output: zhFile,
      jobName: 'paper_zh',
    );
    await _openExportDirectory(dir.path);
    return [enFile.path, zhFile.path];
  }

  /// 导出 Markdown：中文稿、英文稿各一份 .md，写入导出目录并打开。
  Future<List<String>> exportMarkdown() async {
    final draft = current;
    if (draft == null) throw StateError('未打开论文');
    final dir = Directory(p.join(settings.vaultPath, '4-书稿', '论文'));
    await dir.create(recursive: true);
    final baseName = _sanitize(draft.titleZh);
    final zhFile = File(p.join(dir.path, '$baseName-中文稿.md'));
    final enFile = File(p.join(dir.path, '$baseName-英文稿.md'));
    await zhFile.writeAsString(_markdownDoc(draft, english: false));
    await enFile.writeAsString(_markdownDoc(draft, english: true));
    await _openExportDirectory(dir.path);
    return [zhFile.path, enFile.path];
  }

  /// 生成单语言 Markdown 文档（题目 + 各章节正文），用于导出。
  String _markdownDoc(PaperDraft draft, {required bool english}) {
    final buf = StringBuffer()
      ..writeln('# ${english ? draft.titleEn : draft.titleZh}')
      ..writeln();
    for (final section in draft.sections) {
      final title = english ? section.enTitle : section.zhTitle;
      final body = (english ? section.en : section.zh).trim();
      buf
        ..writeln('## $title')
        ..writeln()
        ..writeln(body.isEmpty ? (english ? '(To be written)' : '（待撰写）') : body)
        ..writeln();
    }
    return buf.toString();
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
    final projectBlock = _combinedProjectDigest(draft, 10000);
    final hasChosenTitle = draft.titleZh.trim().isNotEmpty &&
        draft.titleZh.trim() != '未命名论文' &&
        !draft.titleZh.startsWith('论文草稿：');
    final titleRule = hasChosenTitle
        ? '- 用户已选定题目，请沿用（可仅做措辞润色）：中文「${draft.titleZh}」；英文「${draft.titleEn}」。'
        : '- 题目应具体、学术、可投稿，避免泛泛而谈。';
    final reply = await _chat([
      {
        'role': 'system',
        'content': '你是资深 SCI 期刊论文编辑，擅长结合真实工程实现与研究报告规划标准期刊论文。只输出 JSON，不要解释。',
      },
      {
        'role': 'user',
        'content':
            '''
请结合下面的材料，拟定一个适合 SCI 期刊论文的中文题目、英文题目，并规划论文结构。

要求：
$titleRule
- 结构与各节写作要点要贴合关联工程的真实实现（方法、实验设置、结果应可由工程支撑），不要空泛。
- sections 必须覆盖标准 SCI 论文套路：摘要、关键词、引言、相关工作、方法或框架、实验或评价、结果、讨论、结论、参考文献。
- 每个 section 给出 zhTitle、enTitle、brief（brief 用中文写清本节要点，并尽量点到可用的工程支撑）。

严格输出 JSON：
{"titleZh":"...","titleEn":"...","sections":[{"zhTitle":"摘要","enTitle":"Abstract","brief":"本节写作要点"}]}
${draft.topicBrief.trim().isEmpty ? '' : '\n选定选题的相关信息（研究问题/创新点/工程支撑/关键词）：\n${_clip(draft.topicBrief, 2000)}\n'}
关联工程真实解读：
${projectBlock.isEmpty ? '（无）' : projectBlock}

研究报告标题：${draft.sourceResearchTitle.isEmpty ? '（无）' : draft.sourceResearchTitle}

研究报告正文：
${draft.sourceBody.trim().isEmpty ? '（无）' : _clip(draft.sourceBody, 14000)}
''',
      },
    ], jsonMode: true);
    final plan = _parseJson(reply);
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
    // data）。这里对「网络中断」做有限次数重试：清空本节已生成内容后整节重写，
    // 避免任何一次断线就让整篇写作失败。用户主动停止或非网络类错误不重试。
    const maxAttempts = 3;
    Object? lastError;
    final baseStage = stage;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (_cancel) break;
      var acc = '';
      try {
        await for (final delta in _streamChat(messages)) {
          if (_cancel) break;
          acc += delta;
          if (english) {
            section.en = acc;
          } else {
            section.zh = acc;
          }
          notifyListeners();
        }
        return acc.trim();
      } catch (e) {
        lastError = e;
        if (_cancel || !_isTransientNetworkError(e)) rethrow;
        if (english) {
          section.en = '';
        } else {
          section.zh = '';
        }
        stage = '$baseStage 网络中断，正在重试（$attempt/$maxAttempts）…';
        notifyListeners();
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
    if (_cancel) return english ? section.en.trim() : section.zh.trim();
    throw Exception('本节连续 $maxAttempts 次因网络中断写作失败：$lastError');
  }

  /// 判断是否为可重试的瞬时网络错误（连接被断开 / 超时等），而非模型/参数错误。
  static bool _isTransientNetworkError(Object e) {
    if (e is SocketException || e is TimeoutException) return true;
    if (e is http.ClientException) return true;
    final s = e.toString().toLowerCase();
    return s.contains('connection closed') ||
        s.contains('connection reset') ||
        s.contains('connection terminated') ||
        s.contains('connection refused') ||
        s.contains('broken pipe') ||
        s.contains('timed out') ||
        s.contains('timeout') ||
        s.contains('httpexception') ||
        s.contains('clientexception');
  }

  String _chineseSystem(PaperDraft draft) {
    final syntax = draft.format == PaperFormat.latex ? 'LaTeX 片段' : 'Markdown';
    return '你是严谨的中文 SCI 论文写作助手。直接输出本节中文$syntax正文，不要解释，不要输出代码围栏。';
  }

  String _englishSystem(PaperDraft draft) {
    final syntax = draft.format == PaperFormat.latex
        ? 'LaTeX fragment'
        : 'Markdown';
    return 'You are a rigorous SCI journal paper writing assistant. Output only the English $syntax content for the requested section. Do not explain and do not wrap it in code fences.';
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
        ..writeln(_clip(proj.digest, perProject))
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
    final combinedDigest = _combinedProjectDigest(draft, 9000);
    final hasDigest = combinedDigest.trim().isNotEmpty;
    final projectBlock = !hasDigest
        ? ''
        : '''

关联工程的真实解读（基于工程真实文件生成，务必据此写作，尤其是方法、实验设置、相关工作、结果等章节）：
$combinedDigest
''';
    // 有真实工程解读时，要求据此落地真实实现与实验配置；否则沿用审慎表述。
    final evidenceRule = hasDigest
        ? '- 方法、实验设置、结果等内容必须依据上面「关联工程的真实解读」如实撰写，'
              '引用真实的模块/算法、数据集、超参数、评价指标、运行环境等；'
              '严禁编造工程中不存在的数据、配置或结论；工程未体现处如实说明。'
        : '- 不编造真实实验数据或不存在的引用；若来源报告缺少数据，用审慎表述说明需要后续实证验证。';
    return '''
论文题目：
${english ? draft.titleEn : draft.titleZh}

论文整体结构：
$outline

当前要写的部分：
${english ? section.enTitle : section.zhTitle}

本节要点：
${section.brief}

来源研究报告：
${_clip(draft.sourceBody, 16000)}
$projectBlock
要求：
- 按标准 SCI 期刊论文写作套路组织内容，强调研究问题、方法、发现和学术贡献。
$evidenceRule
- $formatHint
- 只输出当前部分正文。''';
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
    for (var i = 0; i < 2; i++) {
      final result = await Process.run(
        compiler,
        [
          '-interaction=nonstopmode',
          '-halt-on-error',
          '-file-line-error',
          '-output-directory',
          buildDir.path,
          texFile.path,
        ],
        workingDirectory: buildDir.path,
        runInShell: compiler == 'xelatex',
      );
      if (result.exitCode != 0) {
        final logFile = File(p.join(buildDir.path, '$jobName.log'));
        throw Exception(
          'LaTeX 编译失败：${await _latexFailureMessage(result, logFile)}',
        );
      }
    }
    final built = File(p.join(buildDir.path, '$jobName.pdf'));
    if (!await built.exists()) {
      throw Exception('LaTeX 未生成 PDF：${built.path}');
    }
    await output.parent.create(recursive: true);
    await built.copy(output.path);
  }

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
    return _clip(message, 1800);
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
    final text = _stripInlineMarkdown(value);
    final hasLatex = RegExp(r'\\[a-zA-Z]+|\\[()\[\]]|\$[^$]+\$').hasMatch(text);
    if (hasLatex) return text;
    return _latexText(text);
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
    await _store!.writeAsString(
      jsonEncode(papers.map((paper) => paper.toJson()).toList()),
    );
  }

  Future<String> _chat(
    List<Map<String, String>> messages, {
    bool jsonMode = false,
  }) async {
    // 论文写作类一次性调用走 writing 角色通道（默认仍是 DeepSeek，可在设置里改）。
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
          if (jsonMode) 'response_format': {'type': 'json_object'},
          'messages': messages,
        }),
      );
      if (resp.statusCode != 200) {
        throw Exception(
          'HTTP ${resp.statusCode} ${utf8.decode(resp.bodyBytes)}',
        );
      }
      final json =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final content =
          (json['choices']?[0]?['message']?['content'] as String?)?.trim() ??
          '';
      if (content.isEmpty) throw Exception('模型未返回内容');
      return content;
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  Stream<String> _streamChat(List<Map<String, String>> messages) async* {
    // 论文各节正文生成走 writing 角色通道。
    const role = ModelRole.writing;
    final request = http.Request(
      'POST',
      Uri.parse('${settings.roleBaseUrl(role)}/chat/completions'),
    );
    request.headers['Authorization'] = 'Bearer ${settings.roleApiKey(role)}';
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode({
      'model': settings.roleModel(role),
      'messages': messages,
      'stream': true,
    });

    final client = _client = http.Client();
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw Exception('HTTP ${response.statusCode} $body');
      }
      var buffer = '';
      // 空闲超时：若长时间没有新数据流入，判定连接假死并抛出，由上层重试。
      await for (final chunk in response.stream
          .transform(utf8.decoder)
          .timeout(const Duration(seconds: 90))) {
        if (_cancel) return;
        buffer += chunk;
        while (true) {
          final newline = buffer.indexOf('\n');
          if (newline < 0) break;
          final line = buffer.substring(0, newline).trim();
          buffer = buffer.substring(newline + 1);
          if (!line.startsWith('data:')) continue;
          final data = line.substring(5).trim();
          if (data.isEmpty) continue;
          if (data == '[DONE]') return;
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            final content =
                json['choices']?[0]?['delta']?['content'] as String?;
            if (content != null && content.isNotEmpty) yield content;
          } catch (_) {
            // 忽略无法解析的流式片段。
          }
        }
      }
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
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
    return out.isEmpty ? '未命名论文' : out;
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
