import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models.dart';
import '../util/text_util.dart';
import 'agent/memory/memory_service.dart';
import 'agent/model_client.dart';
import 'project_context_builder.dart';
import 'web_reader.dart';
import 'file_library_service.dart';
import 'library_service.dart';
import 'playwright_service.dart';
import 'platform_capabilities.dart';
import 'settings_service.dart';
import 'source_adapters.dart';
import 'zotero_service.dart';

/// 图谱「缺失补全」仍使用该轻量结构传入待补全的文件标题。
class TopicDoc {
  TopicDoc({
    required this.standardNo,
    required this.title,
    required this.category,
    required this.year,
  });

  final String standardNo;
  final String title;
  final String category;
  final String year;
}

class _PlanItem {
  _PlanItem(this.source, this.query);
  final SourceId source;
  final String query;
}

class _ResearchSeed {
  _ResearchSeed(this.source, this.query, this.reason);
  final SourceId source;
  final String query;
  final String reason;
}

class _ResearchPlan {
  _ResearchPlan({
    required this.category,
    required this.title,
    required this.angles,
    required this.items,
    required this.profiles,
  });

  final String category;
  final String title;
  final List<String> angles;
  final List<_PlanItem> items;
  final List<ResearchSourceProfile> profiles;
}

class _ResearchRound {
  _ResearchRound({
    required this.index,
    required this.items,
    required this.findings,
    required this.nextSeeds,
    this.gaps = const [],
    this.gateNote = '',
  });

  final int index;
  final List<_PlanItem> items;
  final List<SourceResult> findings;
  final List<_ResearchSeed> nextSeeds;
  final List<String> gaps;
  final String gateNote;
  String? notePath;
}

class _CoverageGate {
  _CoverageGate({
    required this.coverageScore,
    required this.shouldContinue,
    required this.gaps,
    required this.nextSeeds,
    required this.note,
  });

  final double coverageScore;
  final bool shouldContinue;
  final List<String> gaps;
  final List<_ResearchSeed> nextSeeds;
  final String note;
}

class _ResearchInsight {
  _ResearchInsight({required this.terms, required this.reason});
  final List<String> terms;
  final String reason;
}

/// 检索规划前对用户问题的「深度解读」：还原真实意图、核心研究对象、需回答的关键
/// 子问题与忠于原问题的检索关键词，用来约束后续规划，避免检索漂移到泛化近似主题。
class _TopicInterpretation {
  _TopicInterpretation({
    required this.intent,
    required this.entities,
    required this.subQuestions,
    required this.keywords,
    required this.constraints,
  });

  const _TopicInterpretation.empty()
    : intent = '',
      entities = const [],
      subQuestions = const [],
      keywords = const [],
      constraints = '';

  /// 一句话概括用户真正想要什么。
  final String intent;

  /// 问题中出现的具体研究对象/实体（检索必须原样带上）。
  final List<String> entities;

  /// 为回答该问题必须搞清楚的关键子问题。
  final List<String> subQuestions;

  /// 忠于原问题、保留实体名的检索关键词。
  final List<String> keywords;

  /// 地域/时间/市场/口径等必须遵守的约束。
  final String constraints;

  bool get isEmpty =>
      intent.isEmpty &&
      entities.isEmpty &&
      subQuestions.isEmpty &&
      keywords.isEmpty;

  /// 供检索规划 prompt 注入的解读说明块。
  String toPlanningBlock() {
    final buf = StringBuffer();
    if (intent.isNotEmpty) buf.writeln('- 真实意图：$intent');
    if (entities.isNotEmpty) {
      buf.writeln('- 核心研究对象（检索词必须原样带上，禁止替换为同类泛称）：${entities.join('、')}');
    }
    if (subQuestions.isNotEmpty) {
      buf.writeln('- 需回答的关键子问题：${subQuestions.join('；')}');
    }
    if (keywords.isNotEmpty) {
      buf.writeln('- 忠于原问题的检索关键词：${keywords.join('、')}');
    }
    if (constraints.isNotEmpty) {
      buf.writeln('- 必须遵守的约束（地域/时间/市场/口径）：$constraints');
    }
    return buf.toString().trimRight();
  }
}

class _ValuedSource {
  _ValuedSource({
    required this.result,
    required this.score,
    required this.reason,
    required this.highValue,
  });

  final SourceResult result;
  final double score;
  final String reason;
  final bool highValue;
}

class _CollectedResearch {
  _CollectedResearch({
    required this.downloaded,
    required this.excerpts,
    required this.textNotes,
    required this.zoteroSaved,
    required this.cnkiRefs,
  });

  final List<(SourceResult, String)> downloaded;
  final List<(SourceResult, String)> excerpts;
  final List<String> textNotes;
  final int zoteroSaved;
  final int cnkiRefs;
}

class _BrowserEvidenceAnalysis {
  _BrowserEvidenceAnalysis({required this.relevant, required this.note});

  final bool relevant;
  final String note;
}

/// 主题研究开始前的「澄清」结果：模型对研究主题的理解，以及需向用户确认的问题。
class TopicClarification {
  TopicClarification({required this.understanding, required this.questions});

  final String understanding;
  final List<ClarifyQuestion> questions;

  /// 是否需要先与用户确认（存在歧义或可深入的待澄清点）。
  bool get needsInput => questions.isNotEmpty;
}

/// 单个澄清问题：除了问题文本，还带上一组可选项，降低用户输入成本。
/// 界面会自动在选项末尾提供「其他/自己输入」框，因此选项里不要再写“其他”。
class ClarifyQuestion {
  ClarifyQuestion({required this.prompt, required this.options});

  final String prompt;
  final List<String> options;
}

/// 主题研究服务：像研究 agent 一样「拆解问题 → 多源检索（论文/代码/网页）→
/// 下载关键资料 → 综合成研究报告」。
class TopicFetchService extends ChangeNotifier {
  TopicFetchService(
    this.settings,
    this.library,
    this.fileLibrary,
    this.zotero,
    this.playwright,
    this.memory,
  );

  final SettingsService settings;
  final LibraryService library;
  final FileLibraryService fileLibrary;
  final ZoteroService zotero;
  final PlaywrightService playwright;

  /// 全局用户记忆：研究综合时据用户画像调整视角与侧重。
  final MemoryService memory;

  bool running = false;
  final List<String> logs = [];

  /// 历史研究记录（最新在前）。
  List<ResearchRecord> history = [];

  /// 当前正在查看的历史记录（为空表示在做/查看新研究）。
  ResearchRecord? viewing;

  File? _store;
  String? _pendingReportPath;

  // 供 Agent 的 deep_research 工具复用主题研究流程：
  // _logSink 把进度转发给工具调用方；_lastReport 暂存最近一次综合出的报告正文。
  void Function(String line)? _logSink;
  String? _lastReport;

  // 为 true 时，本次 run() 结束不向主题研究历史登记记录（用于"项目内研究"，
  // 研究会话归项目所有，但报告仍照常存入知识库）。
  bool _suppressHistory = false;

  /// 本次研究挂接的本地工程绝对路径（用于结合工程代码/文档辅助研究）。
  List<String> _activeProjectPaths = const [];

  /// 「挂接工程」上下文构建器（懒创建，仅依赖 settings，不改 ProjectService.current）。
  late final ProjectContextBuilder _projectContext =
      ProjectContextBuilder(settings);

  /// 最近一次研究产出的报告笔记路径（供调用方关联，如项目会话）。
  String? get lastReportPath => _pendingReportPath;

  /// 研究完成后回调，参数为研究报告笔记的文件路径（用于自动跳转查看）。
  void Function(String reportNotePath)? onResearchComplete;

  /// 浏览研究遇到登录页时由 UI 弹窗收集临时凭据。
  /// 回调返回 null 表示用户跳过该网站；账号密码不会写入日志、笔记或设置。
  LoginCredentialProvider? onLoginRequired;

  final Map<String, BrowserResearchResult> _browserReadsByUrl = {};
  final Map<String, String> _browserNotesByUrl = {};

  /// 本次研究中「读图分析」模型是否已被判定为不支持图片输入。
  /// 一旦某次调用因模型只接受纯文本而报错，就置为 true，
  /// 后续网页证据分析直接跳过截图、改用纯文本，避免反复触发同样的错误。
  bool _visionUnsupported = false;

  /// 已经在「直接读取主题内网址」阶段用 Jina/README 读过的网址，
  /// 后续收集流程据此跳过，避免对同一网址重复抓取。
  final Set<String> _directReadUrls = {};

  // 共享的网页正文读取器（Jina Reader），与 Agent 的 read_url 工具同源。
  final WebReader _webReader = WebReader();

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _store = File(p.join(dir.path, 'research.json'));
    if (await _store!.exists()) {
      try {
        final list = jsonDecode(await _store!.readAsString()) as List;
        history = list
            .map((e) => ResearchRecord.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        history = [];
      }
    }
  }

  Future<void> _persist() async {
    if (_store == null) return;
    await _store!.writeAsString(
      jsonEncode(history.map((r) => r.toJson()).toList()),
    );
  }

  /// 查看一条历史研究记录。
  void openRecord(ResearchRecord record) {
    viewing = record;
    notifyListeners();
  }

  /// 开始新研究前清除历史查看态。
  void startNew() {
    viewing = null;
    logs.clear();
    notifyListeners();
  }

  Future<void> deleteRecord(ResearchRecord record) async {
    history.remove(record);
    if (viewing == record) viewing = null;
    notifyListeners();
    await _persist();
  }

  static const _maxResultsPerQuery = 15;
  static const _maxDownloads = 8;
  static const _maxFindingsForSynthesis = 40;
  static const _maxResearchRounds = 3;
  static const _maxQueriesPerRound = 8;
  static const _maxHighValueSources = 12;

  static final Map<SourceId, SourceAdapter> _registry = {
    SourceId.arxiv: ArxivAdapter(),
    SourceId.openalex: OpenAlexAdapter(),
    SourceId.europepmc: EuropePmcAdapter(),
    SourceId.cnki: CnkiAdapter(),
    SourceId.github: GitHubAdapter(),
    SourceId.gutenberg: GutenbergAdapter(),
    SourceId.commons: CommonsAdapter(),
    SourceId.web: HeadlessWebAdapter(),
  };

  void _log(String msg) {
    logs.add(msg);
    _logSink?.call(msg); // 若由 Agent 工具发起，则同步把进度回传给工具调用方。
    notifyListeners();
  }

  bool get _browserResearchModelReady =>
      settings.experimentProvider != 'deepseek' &&
      settings.providerReady(settings.experimentProvider);

  /// 开始研究前的「审题/澄清」：识别歧义（如同名概念）、对比维度与研究深度，
  /// 返回模型的理解与需向用户确认的问题，以便研究方向准确、深入。
  Future<TopicClarification> clarify(String topic) async {
    final prompt =
        '''
用户想做主题研究：「$topic」

在开始检索与调研前，请先审题，判断这个研究主题是否存在歧义或值得先与用户确认之处，以便研究方向准确、深入。重点关注：
- **歧义词 / 同名概念**：主题里是否存在可能指向多个完全不同事物的词。例如某个名字既可能是某科学实验、也可能是某 AI 开源项目 / 智能体框架 / 人名 / 产品等——若有，请把不同的可能解释列出来，让用户选择究竟指哪一个。
- **对比类主题**：要对比的双方各自具体指什么、在哪个层面对比（架构 / 性能 / 用法 / 设计理念等）。
- **研究范围与深度**：希望聚焦哪些方面、面向什么目的、要研究到多深。

请提出 1-4 个最关键的澄清问题（中文，具体、好回答），并为每个问题给出 3-6 个具体、有取舍价值的选项，方便用户直接勾选；只有当主题已非常明确、毫无歧义且无需细化时才不提问。

严格输出 JSON（不要 Markdown、不要多余文字）：
{"understanding":"你目前对该研究主题的理解（一两句）","questions":[{"prompt":"需要向用户确认的问题","options":["选项A","选项B","选项C"]}]}

要求：
- 每题给 3-6 个具体选项，用户可多选。
- **每个选项必须是一个单一、具体的答案，绝不能是一句问句，也不能在一个选项里塞进两种待选方向。**
- **严禁在单个选项内出现“还是 / 或者 / 或 / A还是B / ？”这类把多个候选并列的写法。** 如果某个点存在“A 还是 B”这种二选一的歧义，必须把它拆成一个独立的 question，并把 A、B 分别作为该 question 下的两个独立选项，让用户勾选其一。
- 选项之间应尽量互斥、可区分，勾选任意一个都能明确锁定一个方向；不要让不同选项互相包含或语义重叠。
- 不要把“其他/自己输入”写进 options，界面会自动提供最后的自定义输入框。
- 选项必须具体、能帮助锁定研究方向与深度，不能写成“都可以”。

示例（错误 vs 正确）：
- 错误：{"prompt":"请明确细节","options":["‘归档’是指按印章类型自动分文件，还是指按印章位置分文件？"]}
- 正确：{"prompt":"“归档”具体指哪种处理方式？","options":["按印章类型自动分文件","按印章位置分文件"]}
''';
    final content = await _chat(
      [
        {
          'role': 'system',
          'content': '你是严谨的研究规划专家，开始研究前先澄清需求，避免南辕北辙。只输出 JSON。',
        },
        {'role': 'user', 'content': prompt},
      ],
      jsonMode: true,
      useExperimentModel: settings.playwrightBrowserResearchEnabled,
    );
    final parsed = _parseJsonObject(content);
    if (parsed == null) {
      return TopicClarification(understanding: '', questions: const []);
    }
    final understanding = (parsed['understanding'] as String? ?? '').trim();
    final questions = <ClarifyQuestion>[];
    for (final q in (parsed['questions'] as List? ?? [])) {
      // 兼容两种格式：新格式是 {prompt, options}；老格式只是一句问题字符串。
      if (q is Map) {
        final p = (q['prompt'] as String? ?? '').trim();
        if (p.isEmpty) continue;
        final options = [
          for (final o in (q['options'] as List? ?? []))
            if (o != null && o.toString().trim().isNotEmpty) o.toString().trim(),
        ];
        questions.add(ClarifyQuestion(prompt: p, options: options));
      } else if (q is String && q.trim().isNotEmpty) {
        questions.add(ClarifyQuestion(prompt: q.trim(), options: const []));
      }
    }
    return TopicClarification(
      understanding: understanding,
      questions: questions,
    );
  }

  Future<void> run(
    String topic, {
    String clarification = '',
    List<String> projectPaths = const [],
  }) async {
    if (running) return;
    running = true;
    viewing = null;
    _pendingReportPath = null;
    _lastReport = null;
    _activeProjectPaths = List.of(projectPaths);
    _browserReadsByUrl.clear();
    _browserNotesByUrl.clear();
    _directReadUrls.clear();
    _visionUnsupported = false;
    var researchTitle = topic;
    logs.clear();
    notifyListeners();
    try {
      // 有挂接工程时，先构建工程上下文包，注入研究规划与最终报告综合。
      var projectPack = '';
      if (_activeProjectPaths.isNotEmpty) {
        _log('①′ 读取挂接工程上下文（结构 / 文档 / 相关源码）…');
        try {
          projectPack = await _projectContext.buildPack(
            _activeProjectPaths,
            topic,
            log: _log,
          );
        } catch (e) {
          _log('  读取工程上下文失败（不影响后续研究）：$e');
        }
      }

      _log('① 深度解读研究问题并拆解调研角度…');
      if (clarification.trim().isNotEmpty) {
        _log('  已结合你的补充说明确定研究方向。');
      }
      final interpretation = await _interpretTopic(topic, clarification);
      if (!interpretation.isEmpty) {
        if (interpretation.intent.isNotEmpty) {
          _log('  问题解读：${interpretation.intent}');
        }
        if (interpretation.entities.isNotEmpty) {
          _log('  研究对象：${interpretation.entities.join('、')}');
        }
        if (interpretation.constraints.isNotEmpty) {
          _log('  研究约束：${interpretation.constraints}');
        }
        if (interpretation.subQuestions.isNotEmpty) {
          _log('  关键子问题：');
          for (final q in interpretation.subQuestions) {
            _log('    - $q');
          }
        }
      }
      if (projectPack.isNotEmpty) {
        _log('  已结合挂接工程的现状规划检索方向。');
      }
      final plan = await _planResearch(
        topic,
        clarification,
        projectPack: projectPack,
        interpretation: interpretation,
      );
      final category = plan.category;
      researchTitle = plan.title;
      final angles = plan.angles;
      final items = plan.items;
      if (items.isEmpty) {
        _log('未能规划出可用来源，请换一种表述试试。');
        return;
      }
      _log('  研究标题：$researchTitle');
      if (plan.profiles.isNotEmpty) {
        _log('  来源画像：${plan.profiles.map((p) => p.label).join('、')}');
      }
      if (angles.isNotEmpty) {
        _log('  调研角度：');
        for (final a in angles) {
          _log('    - $a');
        }
      }
      _log('  检索计划：');
      for (final it in items) {
        _log('    · ${it.source.label}：「${it.query}」');
      }

      final zoteroOn =
          PlatformCapabilities.supportsZotero &&
          zotero.enabled &&
          await zotero.ping();
      final pwReady =
          PlatformCapabilities.supportsPlaywright && await playwright.ready();
      if (pwReady) {
        _log('  （Playwright 已就绪：网页将渲染抓取并可存为 PDF）');
      }
      final hasWebSearch = items.any((i) => i.source == SourceId.web);
      if (pwReady &&
          hasWebSearch &&
          settings.playwrightBrowserResearchEnabled) {
        if (!_browserResearchModelReady) {
          _log('浏览研究模式需要先在设置里选择并配置一个实验/项目大模型。');
          _log('默认 DeepSeek 不作为 Playwright 浏览研究模型使用，请在设置页切换到支持视觉的大模型。');
          return;
        }
        _log('  （浏览研究模式已启用：网页阅读将使用实验/项目大模型 ${settings.experimentModel}）');
      }

      _log('② 深研循环：多轮发散检索与图谱式扩展…');
      final findings = <SourceResult>[];
      final seenUrls = <String>{};
      if (zoteroOn) {
        _log('  我的 Zotero 文库 ← 「$topic」');
        final mine = await zotero.search(topic);
        for (final r in mine) {
          if (seenUrls.add(r.url)) findings.add(r);
        }
        _log('    命中已有文献 ${mine.length} 条（优先复用，不重复下载）。');
      } else if (PlatformCapabilities.supportsZotero && zotero.enabled) {
        _log('  Zotero 未运行或未开放本地通信，跳过文库检索。');
      }

      // 借鉴 Agent-Reach：用户常以「解读 https://… 」给定要研究的页面，
      // 应直接打开读取其正文（GitHub 走 README，其余走 Jina Reader），
      // 而不是把含网址的长句丢给搜索引擎——那正是检索结果极差的根源之一。
      // 这些是最贴题的种子资料，直接并入线索与已研读摘录。
      final directExcerpts = await _readTopicUrls(
        topic,
        clarification,
        category,
        researchTitle,
        pwReady,
      );
      for (final e in directExcerpts) {
        if (seenUrls.add(e.$1.url)) findings.add(e.$1);
      }

      final rounds = await _deepResearchLoop(
        topic: topic,
        researchTitle: researchTitle,
        category: category,
        angles: angles,
        initialItems: items,
        profiles: plan.profiles,
        pwReady: pwReady,
      );
      final roundNotePaths = <String>[];
      for (final round in rounds) {
        if (round.notePath != null) roundNotePaths.add(round.notePath!);
        for (final r in round.findings) {
          if (seenUrls.add(r.url)) findings.add(r);
        }
      }
      if (findings.isEmpty) {
        _log('未检索到任何结果，请换个表述或更具体的关键词。');
        return;
      }
      _log('  共收集到 ${findings.length} 条线索。');

      _log('③ 价值排序：筛选高价值资料与待研读对象…');
      final valued = _scoreSources(topic, angles, findings);
      final highValue = valued.where((v) => v.highValue).toList();
      if (highValue.isNotEmpty) {
        _log('  高价值候选 ${highValue.length} 条：');
        for (final v in highValue.take(8)) {
          _log('    ★ ${v.result.title}（${v.result.source.label}，${v.reason}）');
        }
      }

      _log('④ 收集资料、逐份保存并记笔记…');
      final collected = await _collectAndReadSources(
        topic: topic,
        researchTitle: researchTitle,
        category: category,
        valued: valued,
        pwReady: pwReady,
        zoteroOn: zoteroOn,
      );

      // 有挂接工程时，按外部线索回读本地代码，产出「对照工程」分析并注入报告。
      var projectContrast = '';
      if (_activeProjectPaths.isNotEmpty) {
        _log('④′ 对照工程：按外部线索回读本地代码…');
        try {
          final digest = _buildExternalDigest(highValue, collected.excerpts);
          projectContrast = await _projectContext.contrastAgainstProjects(
            _activeProjectPaths,
            topic,
            angles,
            digest,
            log: _log,
          );
        } catch (e) {
          _log('  对照工程失败（不影响报告主体）：$e');
        }
      }

      _log('⑤ 研读资料、综合分析并撰写研究报告…');
      if (collected.excerpts.isNotEmpty) {
        _log('  已研读 ${collected.excerpts.length} 份资料正文，开始提炼设计思想…');
      }
      final report = await _synthesize(
        topic,
        angles,
        valued.map((v) => v.result).toList(),
        [...directExcerpts, ...collected.excerpts],
        clarification,
        highValue,
        projectPack,
        projectContrast,
      );
      _lastReport = report; // 暂存正文，供 deep_research 工具取回。
      final notePath = await _saveReport(
        researchTitle,
        topic,
        category,
        report,
        valued.map((v) => v.result).toList(),
        collected.downloaded,
        highValue,
        roundNotePaths,
      );

      _log('重新扫描知识库…');
      await Future.wait([library.reload(), fileLibrary.reload()]);

      if (collected.textNotes.isNotEmpty) {
        _log('⑥ 为每份文档生成 AI 笔记…');
        for (final path in collected.textNotes) {
          final note = library.notes
              .where((n) => n.filePath == path)
              .firstOrNull;
          if (note == null) continue;
          try {
            await library.generateNote(note);
            _log('  已记笔记：${note.fullTitle}');
          } catch (e) {
            _log('  笔记生成失败（${note.fullTitle}）：$e');
          }
        }
      }

      _pendingReportPath = notePath;
      _log('完成！研究报告：${p.basename(notePath)}');
      _log(
        '（保存 ${collected.downloaded.length} 份资料，登记知网引用 ${collected.cnkiRefs} 条，标记高价值 ${highValue.length} 条）',
      );
      if (zoteroOn) _log('（已登记 ${collected.zoteroSaved} 条文献到 Zotero）');
      onResearchComplete?.call(notePath);
    } catch (e) {
      _log('处理失败：$e');
    } finally {
      running = false;
      // 项目内研究不登记主题研究历史（_suppressHistory），但报告已存知识库。
      if (!_suppressHistory) {
        history.insert(
          0,
          ResearchRecord(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            topic: researchTitle,
            createdAt: DateTime.now(),
            logs: List.of(logs),
            reportPath: _pendingReportPath,
            projectPaths: List.of(_activeProjectPaths),
          ),
        );
        await _persist();
      }
      _activeProjectPaths = const [];
      notifyListeners();
    }
  }

  /// 把外部高价值线索 + 已研读摘录压成一段简短摘要，供「对照工程」轮参考。
  String _buildExternalDigest(
    List<_ValuedSource> highValue,
    List<(SourceResult, String)> excerpts,
  ) {
    final buf = StringBuffer();
    if (highValue.isNotEmpty) {
      buf.writeln('高价值资料：');
      for (final v in highValue.take(8)) {
        buf.writeln(
          '- ${v.result.title}（${v.result.source.label}）：${v.reason}',
        );
      }
    }
    if (excerpts.isNotEmpty) {
      buf.writeln('已研读要点：');
      for (final e in excerpts.take(4)) {
        buf.writeln('- ${e.$1.title}：${_clipForPrompt(e.$2, 300)}');
      }
    }
    return buf.toString().trim();
  }

  /// 供 Agent（如「计划」执行器）调用的无界面主题研究：
  /// 复用现有 [run] 整条流程（报告同样会存入知识库），把进度通过 [log] 回传，
  /// 并返回综合出的报告正文。执行期间临时摘除 UI 跳转回调，避免打扰界面。
  Future<String> researchForAgent(
    String topic, {
    String clarification = '',
    List<String> projectPaths = const [],
    void Function(String line)? log,
    bool recordInHistory = true,
  }) async {
    if (running) {
      throw StateError('已有主题研究正在进行，请稍后再试');
    }
    final savedCallback = onResearchComplete;
    onResearchComplete = null; // 由 Agent 发起时不联动界面跳转。
    _logSink = log;
    _suppressHistory = !recordInHistory;
    try {
      await run(topic, clarification: clarification, projectPaths: projectPaths);
    } finally {
      _logSink = null;
      _suppressHistory = false;
      onResearchComplete = savedCallback;
    }
    final report = _lastReport;
    if (report == null || report.trim().isEmpty) {
      throw StateError('未能产出研究报告，请换一种表述再试');
    }
    return report;
  }

  /// 图谱缺失补全：把每个待补文件名作为检索词下载补全。
  Future<void> fetchDocs(String label, List<TopicDoc> docs) async {
    if (running || docs.isEmpty) return;
    running = true;
    logs.clear();
    notifyListeners();
    try {
      _log('开始补全「$label」相关的 ${docs.length} 项内容…');
      final pwReady =
          PlatformCapabilities.supportsPlaywright && await playwright.ready();
      var ok = 0;
      for (final d in docs) {
        final items = <_PlanItem>[
          _PlanItem(SourceId.openalex, d.title),
          if (pwReady) _PlanItem(SourceId.web, d.title),
        ];
        final results = await _searchAll(items, pwReady: pwReady);
        final r = results.where((x) => x.downloadable).firstOrNull;
        if (r == null) {
          _log('  未找到：${d.title}');
          continue;
        }
        _log('  下载：${r.title}');
        final bytes = await _download(r.url, r.ext);
        if (bytes == null) {
          _log('    无效，跳过。');
          continue;
        }
        final relPath = await fileLibrary.saveDownloaded(
          '${_sanitize(r.title)}.${r.ext}',
          bytes,
        );
        await _simpleNote(r, label, relPath, research: label);
        ok++;
        _log('    已保存：$relPath');
      }
      if (ok > 0) {
        await Future.wait([library.reload(), fileLibrary.reload()]);
      }
      _log('完成！本次补全 $ok 份。');
    } catch (e) {
      _log('处理失败：$e');
    } finally {
      running = false;
      notifyListeners();
    }
  }

  /// 把一条检索结果登记进 Zotero（带 PDF 时上传附件）。
  Future<bool> _saveToZotero(
    String topic,
    SourceResult r,
    Uint8List? pdf,
  ) async {
    final itemType = switch (r.source) {
      SourceId.github => 'computerProgram',
      SourceId.web => 'webpage',
      SourceId.cnki => 'journalArticle',
      SourceId.gutenberg => 'book',
      SourceId.commons => 'artwork',
      _ => 'journalArticle',
    };
    final landing = r.landingUrl ?? '';
    final doi = landing.contains('doi.org/')
        ? landing.split('doi.org/').last.trim()
        : '';
    return zotero.saveItem(
      itemType: itemType,
      title: r.title,
      authors: r.authors,
      year: r.year,
      doi: doi,
      abstract: r.summary,
      url: landing.isNotEmpty ? landing : r.url,
      tags: ['主题研究', topic],
      pdfBytes: pdf,
      pdfFileName: pdf != null ? '${_sanitize(r.title)}.pdf' : null,
    );
  }

  // ---------- 解读 ----------

  /// 开始检索规划前，先用 LLM 深度「解读」用户问题：逐字还原他真正想知道什么，
  /// 锁定问题中的具体对象/实体、期望的结论类型与地域口径，并给出忠于原问题的检索
  /// 关键词。解读结果注入后续规划，避免规划脱离本意、检索到与问题无关的泛化资料。
  Future<_TopicInterpretation> _interpretTopic(
    String topic,
    String clarification,
  ) async {
    final clarifyBlock = clarification.trim().isEmpty
        ? ''
        : '\n用户已就该主题补充说明（务必据此锁定意图）：\n${clarification.trim()}\n';
    final prompt =
        '''
请深度解读用户的研究问题，还原他真正想知道什么，而不要把它替换成一个更宽泛的近似主题。

用户的研究问题：
「$topic」
$clarifyBlock
请逐字理解这句话，特别注意：
- 问题里出现的**具体对象/实体**（如具体的公司、股票、产品、人物、地点、时间范围等）必须原样保留，检索时也要带上它们，绝不能丢掉或替换成同类的泛称。
- 用户真正想得到的**结果/结论类型**（例如“找出买卖时机”“对比优劣”“给出可落地方案”），检索必须服务于这个目标，而不是只找该领域的背景综述。
- 如果问题隐含了地域/市场/口径（如中国 A 股、国内），检索关键词与站点必须匹配，绝不能错配到无关地区的来源。

严格输出 JSON（不要 Markdown、不要多余文字）：
{
  "intent":"一句话概括用户真正想要什么，要具体并包含关键对象",
  "entities":["问题中出现的具体研究对象/实体，原样列出"],
  "subQuestions":["为回答该问题必须搞清楚的关键子问题"],
  "keywords":["忠于原问题的检索关键词，保留实体名，中英文按需给出"],
  "constraints":"地域/时间/市场/口径等必须遵守的约束，没有就留空字符串"
}
''';
    final content = await _chat(
      [
        {
          'role': 'system',
          'content':
              '你是严谨的研究审题专家，只忠实还原用户问题的真实意图与对象，绝不把问题替换成泛化的近似主题。只输出 JSON。',
        },
        {'role': 'user', 'content': prompt},
      ],
      jsonMode: true,
      useExperimentModel: settings.playwrightBrowserResearchEnabled,
    );
    final parsed = _parseJsonObject(content);
    if (parsed == null) return const _TopicInterpretation.empty();
    List<String> list(Object? v) => [
      for (final e in (v as List? ?? []))
        if (e != null && e.toString().trim().isNotEmpty) e.toString().trim(),
    ];
    return _TopicInterpretation(
      intent: (parsed['intent'] as String? ?? '').trim(),
      entities: list(parsed['entities']),
      subQuestions: list(parsed['subQuestions']),
      keywords: list(parsed['keywords']),
      constraints: (parsed['constraints'] as String? ?? '').trim(),
    );
  }

  // ---------- 规划 ----------

  Future<_ResearchPlan> _planResearch(
    String topic,
    String clarification, {
    String projectPack = '',
    _TopicInterpretation interpretation = const _TopicInterpretation.empty(),
  }) async {
    final sourceDesc = SourceId.values
        .where((s) => s != SourceId.zotero) // Zotero 由系统自动检索，不交给 AI 规划
        .where(
          (s) => s != SourceId.web || PlatformCapabilities.supportsPlaywright,
        )
        .map((s) => '- ${s.id}：${s.desc}')
        .join('\n');
    final profileDesc = researchSourceProfiles
        .map(
          (p) =>
              '- ${p.id}：${p.label}。${p.description} 推荐来源：${p.preferredSources.map((s) => s.id).join(', ')}；站点模板：${p.siteQueries.take(4).join('；')}',
        )
        .join('\n');
    final existing = library.notes
        .map((n) => n.category.trim())
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList();
    final existingDesc = existing.isEmpty
        ? '（暂无）'
        : existing.map((c) => '「$c」').join('、');
    final interpretBlock = interpretation.isEmpty
        ? ''
        : '\n【问题解读】以下是对该研究问题的深度解读，检索方向必须严格服务于它——'
              '尤其要在检索词中原样保留“核心研究对象”，不得漂移到泛化的近似主题，也不得错配地域/市场：\n'
              '${interpretation.toPlanningBlock()}\n';
    final clarifyBlock = clarification.trim().isEmpty
        ? ''
        : '\n用户已就该主题做了如下澄清/补充（务必据此确定研究方向与检索词，避免理解偏差，例如同名概念要锁定到用户所指的那一个）：\n${clarification.trim()}\n';
    final projectBlock = projectPack.trim().isEmpty
        ? ''
        : '\n用户挂接了以下本地工程，本次研究的目的是结合这些工程做改进/落地对照。'
            '请让检索方向服务于「这些工程还缺什么、可借鉴什么、如何落地」：\n${_clipForPrompt(projectPack, 6000)}\n';
    final prompt =
        '''
你是一名研究规划专家。用户想研究以下问题：
「$topic」
$interpretBlock$clarifyBlock$projectBlock
可用的检索来源（只能从中选择）：
$sourceDesc

内置研究方向 profile（必须先选择 1-2 个最匹配的 profile，再基于它们选来源和站点）：
$profileDesc

知识库中已有的分类：$existingDesc

请像做文献与技术调研那样：
1. 把这个研究问题拆解成 2-4 个关键调研角度（中文短句）；
2. 为本次研究拟定一个简练精准的中文标题：不超过16个字，不要加“【研究】”等前缀，优先用名词短语概括研究目标；
3. 先选择 1-2 个 profile，再只从这些 profile 的推荐来源和站点集合中给出最优检索词，覆盖上述角度。
   - 学术来源(arxiv/openalex/europepmc/gutenberg)检索词用英文关键词；
   - 中文学术论文、中文期刊、硕博论文、国内研究现状必须选 cnki，检索词用中文；cnki 只登记引用线索，全文由用户手动下载；
   - github 检索词用英文（研究“如何实现/工程方案”时必选）；
   - web 检索词应尽量使用 profile 中的 site: 限定站点，不要只给泛化关键词；
4. 确定归类名（不超过10字）：**若本主题与上面某个已有分类属于同一主题领域，必须直接复用那个已有分类名（一字不差），以实现自动归并**；只有确实不属于任何已有分类时才新建。例如“书页图像矫正”和“书页弯曲矫正”属于同一主题，应归并到同一个分类。

严格输出 JSON，不要输出任何其他文字：
{"title":"简练研究标题","category":"归类名","profiles":["ai_cs_engineering"],"angles":["角度1","角度2"],"queries":[{"source":"arxiv","query":"keywords"},{"source":"web","query":"keywords site:example.com"}]}
''';
    final content = await _chat(
      [
        {'role': 'system', 'content': '你是跨领域研究规划专家，只输出 JSON。'},
        {'role': 'user', 'content': prompt},
      ],
      jsonMode: true,
      useExperimentModel: settings.playwrightBrowserResearchEnabled,
    );

    final parsed = _parseJsonObject(content);
    if (parsed == null) {
      return _ResearchPlan(
        category: '其他',
        title: _cleanResearchTitle(topic),
        angles: const [],
        items: const [],
        profiles: const [],
      );
    }
    final title = _cleanResearchTitle(
      (parsed['title'] as String? ?? topic).trim(),
    );
    final category = (parsed['category'] as String? ?? '其他').trim();
    final angles = [
      for (final a in (parsed['angles'] as List? ?? []))
        if (a is String && a.trim().isNotEmpty) a.trim(),
    ];
    final profiles = [
      for (final p in (parsed['profiles'] as List? ?? []))
        if (p is String && researchProfileFromString(p) != null)
          researchProfileFromString(p)!,
    ];
    final effectiveProfiles = profiles.isEmpty
        ? _inferProfiles(topic, angles)
        : profiles.take(2).toList();
    final allowedSources = effectiveProfiles.isEmpty
        ? SourceId.values.where((s) => s != SourceId.zotero).toSet()
        : effectiveProfiles.expand((p) => p.preferredSources).toSet();
    final items = <_PlanItem>[];
    for (final q in (parsed['queries'] as List? ?? [])) {
      if (q is! Map) continue;
      final src = sourceFromString('${q['source'] ?? ''}');
      final query = (q['query'] as String? ?? '').trim();
      if (src == null || query.isEmpty) continue;
      if (src == SourceId.zotero) continue; // Zotero 不走规划检索
      if (!allowedSources.contains(src)) continue;
      if (src == SourceId.web && !PlatformCapabilities.supportsPlaywright) {
        continue;
      }
      items.add(_PlanItem(src, query));
    }
    // 种子检索词优先采用「问题解读」得到的忠于原问题、保留实体名的关键词，
    // 避免机械抽词把具体研究对象丢掉、退化成泛化查询。
    final coreQuery = _coreQuery(topic, angles, interpretation);
    items.addAll(_profileSeedItems(coreQuery, effectiveProfiles));
    if (_looksChinese(topic) && !items.any((e) => e.source == SourceId.cnki)) {
      // 用短关键词而不是整段主题作为知网检索词（整段含网址的长句会让知网/搜索返回噪声）。
      items.insert(0, _PlanItem(SourceId.cnki, coreQuery));
    }
    return _ResearchPlan(
      category: category.isEmpty ? '其他' : category,
      title: title,
      angles: angles,
      items: _dedupePlanItems(items).take(_maxQueriesPerRound).toList(),
      profiles: effectiveProfiles,
    );
  }

  List<ResearchSourceProfile> _inferProfiles(
    String topic,
    List<String> angles,
  ) {
    final text = '$topic ${angles.join(' ')}'.toLowerCase();
    final out = <ResearchSourceProfile>[];
    void add(String id) {
      final p = researchProfileFromString(id);
      if (p != null && !out.contains(p)) out.add(p);
    }

    if (_looksChinese(text)) add('chinese_academic');
    if (RegExp(
      r'ai|llm|agent|算法|模型|工程|代码|实现|computer|vision|nlp',
    ).hasMatch(text)) {
      add('ai_cs_engineering');
    }
    if (RegExp(r'政策|标准|规范|监管|行业报告|国家|政府|standard|policy').hasMatch(text)) {
      add('policy_standards');
    }
    if (RegExp(r'医学|临床|疾病|药物|治疗|生物|medical|clinical|drug').hasMatch(text)) {
      add('biomedicine');
    }
    if (RegExp(r'金融|经济|公司|市场|股票|gdp|finance|econom').hasMatch(text)) {
      add('finance_economy');
    }
    if (RegExp(r'法律|法规|司法|法院|判例|law|legal').hasMatch(text)) {
      add('law_regulation');
    }
    if (RegExp(r'安全|漏洞|攻击|cve|owasp|security').hasMatch(text)) {
      add('code_security');
    }
    if (RegExp(r'书|文学|历史|哲学|人文|book|history').hasMatch(text)) {
      add('books_humanities');
    }
    if (out.isEmpty) add('ai_cs_engineering');
    return out.take(2).toList();
  }

  List<_PlanItem> _profileSeedItems(
    String query,
    List<ResearchSourceProfile> profiles,
  ) {
    final out = <_PlanItem>[];
    for (final profile in profiles) {
      for (final source in profile.preferredSources.take(3)) {
        if (source == SourceId.zotero || source == SourceId.web) continue;
        if (_queryLooksUsableForSource(query, source)) {
          out.add(_PlanItem(source, query));
        }
      }
      if (PlatformCapabilities.supportsPlaywright) {
        for (final template in profile.siteQueries.take(4)) {
          out.add(
            _PlanItem(SourceId.web, template.replaceAll('{query}', query)),
          );
        }
      }
    }
    return out;
  }

  List<_PlanItem> _dedupePlanItems(Iterable<_PlanItem> items) {
    final seen = <String>{};
    final out = <_PlanItem>[];
    for (final item in items) {
      final query = _compactQuery(item.query);
      if (query.isEmpty) continue;
      if (!_queryLooksUsableForSource(query, item.source)) continue;
      if (item.source == SourceId.web && _isBlockedWebSearchQuery(query)) {
        continue;
      }
      final key = '${item.source.name}\u0000${query.toLowerCase()}';
      if (seen.add(key)) out.add(_PlanItem(item.source, query));
    }
    return out;
  }

  String _compactQuery(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// 构造用于种子检索的核心短查询：优先使用「问题解读」还原出的、忠于原问题且
  /// 保留实体名的关键词（例如具体股票/公司名），确保 site: 模板与单关键词发散都
  /// 围绕用户真正关心的对象，而不是被机械抽词漂移成泛化查询。解读缺失时退回
  /// [_searchKeywords] 的关键词抽取。
  String _coreQuery(
    String topic,
    List<String> angles,
    _TopicInterpretation interpretation,
  ) {
    if (interpretation.keywords.isNotEmpty) {
      final picked = <String>[];
      var len = 0;
      for (final k in interpretation.keywords) {
        final t = k.replaceAll(RegExp(r'https?://\S+'), ' ').trim();
        if (t.isEmpty || picked.contains(t)) continue;
        picked.add(t);
        len += t.length + 1;
        if (picked.length >= 6 || len >= 60) break;
      }
      if (picked.isNotEmpty) return picked.join(' ');
    }
    return _searchKeywords(topic, angles);
  }

  /// 构造用于网页/站点检索的「短关键词查询」。
  /// 先剥离 URL，再只取主题里的少量核心关键词（按词频/长度排序、最多 6 个/约 48 字）。
  /// 这是搜索结果极差的另一根源的修复点：把整段含网址的长句丢给搜索引擎只会得到噪声，
  /// site: 模板也必须套在这种短查询上才有意义。
  String _searchKeywords(String topic, List<String> angles) {
    final noUrl = '$topic ${angles.join(' ')}'.replaceAll(
      RegExp(r'https?://\S+'),
      ' ',
    );
    final picked = <String>[];
    var len = 0;
    for (final t in _keywordTerms([noUrl])) {
      if (picked.contains(t)) continue;
      picked.add(t);
      len += t.length + 1;
      if (picked.length >= 6 || len >= 48) break;
    }
    final out = picked.join(' ').trim();
    return out.isEmpty ? _compactQuery(noUrl) : out;
  }

  // ---------- 检索 ----------

  Future<List<SourceResult>> _searchAll(
    List<_PlanItem> items, {
    bool pwReady = false,
  }) async {
    final out = <SourceResult>[];
    final seen = <String>{};
    for (final item in items) {
      _log('  ${item.source.label} ← 「${item.query}」');
      try {
        final List<SourceResult> results;
        if (item.source == SourceId.web) {
          if (!pwReady) {
            _log('    Playwright 未就绪，跳过网页检索。请先在设置中安装并启用 Playwright。');
            results = const [];
          } else if (settings.playwrightBrowserResearchEnabled) {
            results = await _searchWebWithBrowserResearch(item.query);
          } else {
            // 网页检索只使用 Playwright。失败时记录诊断，不切换到其他执行路径。
            results = await playwright.search(
              item.query,
              limit: _maxResultsPerQuery,
            );
            if (results.isEmpty && playwright.lastSearchDiag.isNotEmpty) {
              _log('    诊断：${playwright.lastSearchDiag}');
            }
          }
        } else {
          results = await _registry[item.source]!.search(
            item.query,
            limit: _maxResultsPerQuery,
          );
        }
        for (final r in results) {
          if (seen.add(r.url)) out.add(r);
        }
        _log('    返回 ${results.length} 条。');
      } catch (e) {
        _log('    检索出错：$e');
      }
    }
    return out;
  }

  Future<List<SourceResult>> _searchWebWithBrowserResearch(String query) async {
    if (!_browserResearchModelReady) {
      throw Exception('浏览研究需要配置非 DeepSeek 的实验/项目大模型。');
    }
    _log('    启动浏览研究：搜索、打开网页并滚动阅读。');
    final reads = await playwright.searchAndRead(
      query,
      limit: 6,
      onLoginRequired: onLoginRequired,
    );
    if (reads.isEmpty && playwright.lastSearchDiag.isNotEmpty) {
      _log('    诊断：${playwright.lastSearchDiag}');
    }
    final out = <SourceResult>[];
    for (final read in reads) {
      if (read.source.ext == 'pdf') {
        out.add(read.source);
        continue;
      }
      if (read.visibleText.isEmpty && read.excerpt.isEmpty) continue;
      final analysis = await _analyzeBrowserEvidence(query, read);
      if (!analysis.relevant) {
        _log('    跳过低相关网页：${read.source.title}');
        continue;
      }
      final summary = analysis.note.isNotEmpty ? analysis.note : read.excerpt;
      final result = SourceResult(
        title: read.source.title,
        url: read.source.url,
        source: SourceId.web,
        ext: read.source.ext,
        summary: summary,
        landingUrl: read.source.landingUrl,
      );
      _browserReadsByUrl[result.url] = read;
      _browserNotesByUrl[result.url] = summary;
      out.add(result);
    }
    return out;
  }

  Future<_BrowserEvidenceAnalysis> _analyzeBrowserEvidence(
    String query,
    BrowserResearchResult read,
  ) async {
    final prompt =
        '''
研究查询：「$query」

请阅读下面的网页证据，并判断它是否值得进入主题研究材料库。

页面标题：${read.source.title}
页面链接：${read.source.url}
阅读路径：${read.readingPath}

可见正文：
${read.visibleText.isEmpty ? read.excerpt : read.visibleText}

严格输出 JSON：
{"relevance":true,"note":"用中文写 3-6 句可靠摘录，说明页面和研究问题的关系。不要编造页面没有的信息。"}
''';
    const system =
        '你是网页研究助手。你会结合页面文字和截图判断相关性，只基于证据做摘要。只输出 JSON。';
    // 页面截图需要视觉能力：走专门的「读图分析」模型通道。
    // 若该模型不支持图片，则退化为纯文本分析（可见正文已足够判断相关性）。
    final withImage = read.screenshotBase64.isNotEmpty && !_visionUnsupported;

    Future<String> ask({required bool image}) {
      final userContent = image
          ? <Map<String, dynamic>>[
              {'type': 'text', 'text': prompt},
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/jpeg;base64,${read.screenshotBase64}',
                },
              },
            ]
          : prompt;
      return _chat(
        [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': userContent},
        ],
        jsonMode: true,
        role: ModelRole.vision,
      );
    }

    String content;
    try {
      content = await ask(image: withImage);
    } catch (e) {
      // 模型只接受纯文本、不支持图片输入时：记录日志并自动跳过截图，
      // 本次改用纯文本分析，并标记后续网页也不再发送截图。
      if (withImage && _isImageUnsupportedError(e)) {
        _visionUnsupported = true;
        _log('    读图模型不支持图片输入，已跳过网页截图，改用纯文本分析。');
        content = await ask(image: false);
      } else {
        rethrow;
      }
    }
    final parsed = _parseJsonObject(content);
    if (parsed == null) {
      return _BrowserEvidenceAnalysis(relevant: true, note: read.excerpt);
    }
    return _BrowserEvidenceAnalysis(
      relevant: parsed['relevance'] != false,
      note: (parsed['note'] as String? ?? '').trim(),
    );
  }

  Future<List<_ResearchRound>> _deepResearchLoop({
    required String topic,
    required String researchTitle,
    required String category,
    required List<String> angles,
    required List<_PlanItem> initialItems,
    required List<ResearchSourceProfile> profiles,
    required bool pwReady,
  }) async {
    final rounds = <_ResearchRound>[];
    final seenQueries = <String>{};
    final seenUrls = <String>{};
    final allFindings = <SourceResult>[];
    var items = _dedupeItems([
      ...initialItems,
      ..._seedItems(
        topic,
        angles,
        initialItems,
      ).map((s) => _PlanItem(s.source, s.query)),
    ], seenQueries).take(_maxQueriesPerRound).toList();

    for (
      var roundNo = 1;
      roundNo <= _maxResearchRounds && items.isNotEmpty;
      roundNo++
    ) {
      _log('  第 $roundNo 轮：${roundNo == 1 ? '广度发散' : '关联扩展'}检索');
      for (final item in items) {
        _log('    · ${item.source.label}：「${item.query}」');
      }
      final results = await _searchAll(items, pwReady: pwReady);
      final fresh = <SourceResult>[];
      for (final r in results) {
        if (seenUrls.add(r.url)) fresh.add(r);
      }
      allFindings.addAll(fresh);
      _log('    本轮新增 ${fresh.length} 条线索。');

      final insights = _extractInsights(topic, angles, fresh);
      final gate = roundNo >= _maxResearchRounds
          ? _CoverageGate(
              coverageScore: 1,
              shouldContinue: false,
              gaps: const [],
              nextSeeds: const [],
              note: '已达到最大检索预算，停止补搜。',
            )
          : await _evaluateResearchCoverage(
              topic: topic,
              angles: angles,
              profiles: profiles,
              allFindings: allFindings,
              fresh: fresh,
              roundItems: items,
              insights: insights,
            );
      final round = _ResearchRound(
        index: roundNo,
        items: items,
        findings: fresh,
        nextSeeds: gate.nextSeeds,
        gaps: gate.gaps,
        gateNote: '覆盖度 ${gate.coverageScore.toStringAsFixed(2)}；${gate.note}',
      );
      round.notePath = await _saveRoundNote(
        category: category,
        researchTitle: researchTitle,
        round: round,
        insights: insights,
        profiles: profiles,
      );
      rounds.add(round);
      _log('    质量门：${round.gateNote}');
      if (!gate.shouldContinue || gate.nextSeeds.isEmpty) {
        _log('    停止扩展：${gate.note}');
        break;
      }

      items = _dedupeItems(
        gate.nextSeeds.map((s) => _PlanItem(s.source, s.query)),
        seenQueries,
      ).take(5).toList();
    }
    return rounds;
  }

  Future<_CoverageGate> _evaluateResearchCoverage({
    required String topic,
    required List<String> angles,
    required List<ResearchSourceProfile> profiles,
    required List<SourceResult> allFindings,
    required List<SourceResult> fresh,
    required List<_PlanItem> roundItems,
    required List<_ResearchInsight> insights,
  }) async {
    final scored = _scoreSources(topic, angles, allFindings);
    final highValue = scored.where((v) => v.highValue).take(8).toList();
    if (fresh.isEmpty && allFindings.length >= 4) {
      return _CoverageGate(
        coverageScore: 0.7,
        shouldContinue: false,
        gaps: const ['本轮没有新增有效线索'],
        nextSeeds: const [],
        note: '本轮无新增结果，继续检索大概率只会放大噪声。',
      );
    }

    final sourceText = StringBuffer();
    var i = 0;
    for (final v in scored.take(24)) {
      i++;
      sourceText
        ..writeln(
          '[$i][${v.result.source.id}] ${v.result.title}（${v.reason}，评分 ${v.score.toStringAsFixed(1)}）',
        )
        ..writeln('摘要：${_clipForPrompt(v.result.summary, 260)}')
        ..writeln('链接：${v.result.landingUrl ?? v.result.url}')
        ..writeln();
    }
    final profileText = profiles.isEmpty
        ? '未指定 profile'
        : profiles
              .map(
                (p) =>
                    '${p.id}=${p.label}，推荐来源 ${p.preferredSources.map((s) => s.id).join(", ")}，站点 ${p.siteQueries.take(5).join("；")}',
              )
              .join('\n');
    final queryText = roundItems
        .map((i) => '${i.source.id}: ${i.query}')
        .join('\n');
    final insightText = insights.expand((i) => i.terms).take(12).join('；');
    final prompt =
        '''
研究问题：「$topic」
调研角度：${angles.isEmpty ? '未显式拆分' : angles.join('；')}

本轮已执行查询：
$queryText

已选研究方向 profile：
$profileText

当前高价值候选与摘要：
$sourceText

规则抽取到的概念（只能作为参考，不能机械扩展）：$insightText

请判断当前材料是否足够支撑一份可靠研究报告。重点检查：
1. 调研角度是否都有材料覆盖；
2. 是否已有足够高价值来源，而不是只有泛网页；
3. 如果继续检索，必须说明具体缺口，并给出少量与缺口直接对应的查询。

严格输出 JSON：
{
  "coverageScore":0.0,
  "shouldContinue":true,
  "note":"为什么继续或停止",
  "gaps":["缺口1"],
  "nextQueries":[
    {"source":"web","query":"精确查询 site:example.com","reason":"对应哪个缺口","expectedEvidence":"希望找到什么证据"}
  ]
}
''';
    try {
      final content = await _chat(
        [
          {
            'role': 'system',
            'content': '你是深度研究质量门。你不会为了凑轮数继续搜索；只有发现具体缺口时才给下一轮查询。只输出 JSON。',
          },
          {'role': 'user', 'content': prompt},
        ],
        jsonMode: true,
        useExperimentModel: settings.playwrightBrowserResearchEnabled,
      );
      final parsed = _parseJsonObject(content);
      if (parsed == null) throw const FormatException('no json');
      final coverage = ((parsed['coverageScore'] as num?) ?? 0.0)
          .toDouble()
          .clamp(0.0, 1.0);
      final gaps = [
        for (final g in (parsed['gaps'] as List? ?? []))
          if (g is String && g.trim().isNotEmpty) g.trim(),
      ];
      final seeds = _nextSeedsFromCoverageJson(
        parsed['nextQueries'],
        topic,
        angles,
        profiles,
      );
      final enoughHighValue = highValue.length >= 4;
      final shouldContinue =
          parsed['shouldContinue'] == true &&
          seeds.isNotEmpty &&
          gaps.isNotEmpty &&
          !(coverage >= 0.75 && enoughHighValue);
      return _CoverageGate(
        coverageScore: coverage,
        shouldContinue: shouldContinue,
        gaps: gaps,
        nextSeeds: shouldContinue ? seeds : const [],
        note: (parsed['note'] as String? ?? '').trim().isEmpty
            ? (shouldContinue ? '发现明确缺口，继续补搜。' : '覆盖度已足够或缺少有效补搜方向。')
            : (parsed['note'] as String).trim(),
      );
    } catch (_) {
      return _CoverageGate(
        coverageScore: highValue.length >= 4 ? 0.75 : 0.45,
        shouldContinue: false,
        gaps: const ['质量门未返回可解析结果'],
        nextSeeds: const [],
        note: '质量门未给出可用查询，停止扩展，避免规则抽词继续放大噪声。',
      );
    }
  }

  List<_ResearchSeed> _nextSeedsFromCoverageJson(
    Object? raw,
    String topic,
    List<String> angles,
    List<ResearchSourceProfile> profiles,
  ) {
    if (raw is! List) return const [];
    final out = <_ResearchSeed>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final source = sourceFromString('${item['source'] ?? ''}');
      final query = _compactQuery('${item['query'] ?? ''}');
      if (source == null || source == SourceId.zotero || query.isEmpty) {
        continue;
      }
      if (!_profileAllowsSource(source, profiles)) continue;
      if (!_queryLooksUsableForSource(query, source)) continue;
      if (source == SourceId.web && _isBlockedWebSearchQuery(query)) continue;
      if (!_queryMatchesTopic(query, topic, angles)) continue;
      final reason = _compactQuery(
        '${item['reason'] ?? item['expectedEvidence'] ?? '缺口补搜'}',
      );
      out.add(_ResearchSeed(source, query, reason.isEmpty ? '缺口补搜' : reason));
      if (out.length >= 5) break;
    }
    return out;
  }

  bool _profileAllowsSource(
    SourceId source,
    List<ResearchSourceProfile> profiles,
  ) {
    if (profiles.isEmpty) return true;
    return profiles.any((p) => p.preferredSources.contains(source));
  }

  bool _queryMatchesTopic(String query, String topic, List<String> angles) {
    final lower = query.toLowerCase();
    final anchors = _anchorTerms(topic, angles);
    if (anchors.isEmpty) return true;
    if (anchors.any((a) => lower.contains(a))) return true;
    final topicTerms = _keywordTerms([
      topic,
    ]).map((t) => t.toLowerCase()).where((t) => t.length >= 2).take(6);
    return topicTerms.any((t) => lower.contains(t));
  }

  bool _isBlockedWebSearchQuery(String query) {
    final lower = query.toLowerCase();
    // 这些站点用搜索引擎 site: 查询在 Playwright 下常返回验证码、错误页或无链接。
    // 相关资料应通过 arXiv/OpenAlex/GitHub/CNKI 等结构化来源获取，而不是硬搜网页。
    const blockedSites = {
      'site:semanticscholar.org',
      'site:paperswithcode.com',
      'site:dl.acm.org',
      'site:ieeexplore.ieee.org',
      'site:scholar.google.com',
    };
    return blockedSites.any(lower.contains);
  }

  List<_ResearchSeed> _seedItems(
    String topic,
    List<String> angles,
    List<_PlanItem> initialItems,
  ) {
    final seeds = <_ResearchSeed>[];
    final sources = initialItems.map((i) => i.source).toSet();
    if (_looksChinese(topic)) {
      sources.add(SourceId.cnki);
      if (PlatformCapabilities.supportsPlaywright) {
        sources.add(SourceId.web);
      }
    }
    final terms = [
      ..._phraseTerms([topic, ...angles, ...initialItems.map((i) => i.query)]),
      ..._keywordTerms([
        topic,
        ...angles,
      ]).where((t) => _looksChinese(t) && _hasMeaningfulChineseQuery(t)),
    ];
    for (final source in sources) {
      if (source == SourceId.zotero) continue;
      for (final term in terms.take(6)) {
        if (_isMeaningfulSeedTerm(term) &&
            _queryLooksUsableForSource(term, source)) {
          seeds.add(_ResearchSeed(source, term, '单关键词发散'));
        }
      }
    }
    return seeds;
  }

  List<_ResearchInsight> _extractInsights(
    String topic,
    List<String> angles,
    List<SourceResult> findings,
  ) {
    final anchorTerms = _anchorTerms(topic, angles);
    final terms = _phraseTerms(
      findings
          .where((r) => _isRelevantFinding(r, anchorTerms))
          .take(20)
          .map((r) => '${r.title} ${r.summary}'),
    ).where((t) => _isMeaningfulExpansionTerm(t, anchorTerms)).toList();
    if (terms.isEmpty) return [];
    return [
      _ResearchInsight(
        terms: terms.take(10).toList(),
        reason: '从本轮标题、摘要和研究角度抽取的概念/实体',
      ),
    ];
  }

  List<_PlanItem> _dedupeItems(
    Iterable<_PlanItem> items,
    Set<String> seenQueries,
  ) {
    final out = <_PlanItem>[];
    for (final item in items) {
      final query = item.query.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (query.isEmpty) continue;
      final key = '${item.source.name}\u0000${query.toLowerCase()}';
      if (!seenQueries.add(key)) continue;
      out.add(_PlanItem(item.source, query));
    }
    return out;
  }

  List<String> _keywordTerms(Iterable<String> texts) {
    final counts = <String, int>{};
    void add(String term) {
      final clean = term
          .replaceAll(RegExp(r'[^\w\u4e00-\u9fa5\- ]'), ' ')
          .trim();
      if (clean.length < 2 || clean.length > 60) return;
      if (_stopTerms.contains(clean.toLowerCase())) return;
      counts[clean] = (counts[clean] ?? 0) + 1;
    }

    for (final text in texts) {
      for (final m in RegExp(r'[\u4e00-\u9fa5]{2,12}').allMatches(text)) {
        add(m.group(0)!);
      }
      for (final m in RegExp(r'[A-Za-z][A-Za-z0-9\-]{2,}').allMatches(text)) {
        add(m.group(0)!);
      }
    }
    final terms = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return b.key.length.compareTo(a.key.length);
      });
    return terms.map((e) => e.key).take(24).toList();
  }

  Set<String> _anchorTerms(String topic, List<String> angles) {
    return _keywordTerms([topic, ...angles])
        .map((t) => t.toLowerCase())
        .where((t) => t.length >= 3 && !_genericExpansionTerms.contains(t))
        .take(12)
        .toSet();
  }

  bool _isRelevantFinding(SourceResult result, Set<String> anchorTerms) {
    if (anchorTerms.isEmpty) return true;
    final text = '${result.title} ${result.summary}'.toLowerCase();
    var matches = 0;
    for (final term in anchorTerms) {
      if (text.contains(term)) matches++;
      if (matches >= 1) return true;
    }
    return false;
  }

  List<String> _phraseTerms(Iterable<String> texts) {
    final counts = <String, int>{};
    void add(String term) {
      final clean = term.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (clean.length < 4 || clean.length > 72) return;
      final lower = clean.toLowerCase();
      if (_genericExpansionTerms.contains(lower) ||
          _stopTerms.contains(lower)) {
        return;
      }
      counts[clean] = (counts[clean] ?? 0) + 1;
    }

    for (final text in texts) {
      for (final m in RegExp(r'[\u4e00-\u9fa5]{4,18}').allMatches(text)) {
        add(m.group(0)!);
      }
      for (final m in RegExp(
        r'[A-Za-z][A-Za-z0-9\-]+(?:\s+[A-Za-z][A-Za-z0-9\-]+){1,5}',
      ).allMatches(text)) {
        add(m.group(0)!);
      }
    }
    final terms = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return b.key.length.compareTo(a.key.length);
      });
    return terms.map((e) => e.key).take(16).toList();
  }

  bool _isMeaningfulExpansionTerm(String term, Set<String> anchorTerms) {
    final lower = term.toLowerCase().trim();
    if (lower.isEmpty) return false;
    if (_genericExpansionTerms.contains(lower) || _stopTerms.contains(lower)) {
      return false;
    }
    if (_looksChinese(term)) {
      if (!_hasMeaningfulChineseQuery(term)) return false;
      return anchorTerms.isEmpty || anchorTerms.any((a) => lower.contains(a));
    }
    final words = lower
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.length < 2) return false;
    if (words.every(_genericExpansionTerms.contains)) return false;
    return anchorTerms.isEmpty || anchorTerms.any((a) => lower.contains(a));
  }

  bool _isMeaningfulSeedTerm(String term) {
    final lower = term.toLowerCase().trim();
    if (_genericExpansionTerms.contains(lower) || _stopTerms.contains(lower)) {
      return false;
    }
    if (_looksChinese(term)) return _hasMeaningfulChineseQuery(term);
    return lower.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length >= 2;
  }

  bool _queryLooksUsableForSource(String query, SourceId source) {
    final hasChinese = _looksChinese(query);
    return switch (source) {
      SourceId.cnki =>
        hasChinese &&
            _hasMeaningfulChineseQuery(query) &&
            !_isGenericCnkiQuery(query),
      SourceId.web => true,
      SourceId.arxiv ||
      SourceId.openalex ||
      SourceId.europepmc ||
      SourceId.github => !hasChinese,
      _ => true,
    };
  }

  static bool _isGenericCnkiQuery(String query) {
    final normalized = query
        .replaceAll(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]+'), '')
        .toLowerCase();
    if (normalized.isEmpty) return true;
    const bad = {'知网检索', '综述研究', '引用手动下载', '手动下载', '打开链接', '机构权限', '中文学术线索'};
    return bad.contains(normalized);
  }

  static bool _hasMeaningfulChineseQuery(String query) {
    final chinese = RegExp(
      r'[\u4e00-\u9fa5]+',
    ).allMatches(query).map((m) => m.group(0)!).join();
    final meaningful = chinese.replaceAll(
      RegExp(r'(知网检索|综述|研究|引用|手动|下载|打开|链接|机构|权限|中文|学术|线索|方案|标准)'),
      '',
    );
    return meaningful.length >= 2;
  }

  static const _stopTerms = {
    'the',
    'and',
    'for',
    'with',
    'from',
    'this',
    'that',
    'not',
    'are',
    'can',
    'use',
    'using',
    'used',
    'config',
    'github',
    'survey',
    'implementation',
    '研究',
    '主题',
    '报告',
    '方法',
    '问题',
    '综述',
    '知网检索',
    '综述研究',
    '手动下载',
    '引用手动下载',
  };

  static const _genericExpansionTerms = {
    'data',
    'metadata',
    'language',
    'model',
    'models',
    'framework',
    'frameworks',
    'survey',
    'method',
    'methods',
    'system',
    'systems',
    'approach',
    'approaches',
    'analysis',
    'extraction',
    'implementation',
    'accuracy',
    'rule',
    'rules',
    'standard',
    'standards',
    'archive',
    'archives',
    'archival',
    'large',
    'learning',
  };

  static bool _looksChinese(String value) =>
      RegExp(r'[\u4e00-\u9fa5]').hasMatch(value);

  List<_ValuedSource> _scoreSources(
    String topic,
    List<String> angles,
    List<SourceResult> findings,
  ) {
    final terms = _keywordTerms([
      topic,
      ...angles,
    ]).map((t) => t.toLowerCase()).toList();
    double sourceWeight(SourceId source) => switch (source) {
      SourceId.cnki => 2.2,
      SourceId.openalex || SourceId.arxiv || SourceId.europepmc => 2.0,
      SourceId.github => 1.8,
      SourceId.web => 1.4,
      SourceId.zotero => 2.4,
      SourceId.gutenberg => 1.0,
      SourceId.commons => 0.8,
    };

    final scored = <_ValuedSource>[];
    for (final r in findings) {
      final text = '${r.title} ${r.summary}'.toLowerCase();
      var score = sourceWeight(r.source);
      var matches = 0;
      for (final term in terms) {
        if (term.length >= 2 && text.contains(term)) {
          matches++;
          score += term.length >= 5 ? 1.2 : 0.8;
        }
      }
      if (r.downloadable) score += 0.7;
      if (r.summary.trim().length > 80) score += 0.6;
      if (r.year.isNotEmpty) score += 0.3;
      if (_existsInLibrary(r.title)) score -= 1.4;
      final reason = [
        r.source.label,
        if (matches > 0) '匹配 $matches 个核心词',
        if (r.downloadable) '可直接研读',
        if (r.source == SourceId.cnki) '中文学术线索',
        if (r.source == SourceId.github) '工程实现参考',
      ].join('；');
      scored.add(
        _ValuedSource(
          result: r,
          score: score,
          reason: reason,
          highValue: false,
        ),
      );
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    final highUrls = scored
        .take(_maxHighValueSources)
        .map((v) => v.result.url)
        .toSet();
    return [
      for (final v in scored)
        _ValuedSource(
          result: v.result,
          score: v.score,
          reason: v.reason,
          highValue: highUrls.contains(v.result.url),
        ),
    ];
  }

  Future<_CollectedResearch> _collectAndReadSources({
    required String topic,
    required String researchTitle,
    required String category,
    required List<_ValuedSource> valued,
    required bool pwReady,
    required bool zoteroOn,
  }) async {
    final downloaded = <(SourceResult, String)>[];
    final excerpts = <(SourceResult, String)>[];
    final textNotes = <String>[];
    var zoteroSaved = 0;
    var cnkiRefs = 0;
    var ghRead = 0;

    for (final valuedSource in valued) {
      var r = valuedSource.result;
      final highValue = valuedSource.highValue;
      // 主题内网址已在前面用 Jina/README 直接读过并存档，跳过避免重复抓取。
      if (_directReadUrls.contains(r.url)) continue;
      if (r.source == SourceId.cnki) {
        if (cnkiRefs >= _maxDownloads || _existsInLibrary(r.title)) continue;
        if (pwReady) {
          _log('  用 Playwright 打开知网页面并读取可见信息：${r.title}');
          final read = await playwright.readPage(
            r.landingUrl ?? r.url,
            onLoginRequired: onLoginRequired,
          );
          if (read != null &&
              (read.visibleText.isNotEmpty || read.excerpt.isNotEmpty)) {
            final analysis = _browserResearchModelReady
                ? await _analyzeBrowserEvidence(topic, read)
                : _BrowserEvidenceAnalysis(
                    relevant: true,
                    note: read.excerpt.isNotEmpty
                        ? read.excerpt
                        : read.visibleText,
                  );
            final note = analysis.note.trim();
            if (note.isNotEmpty) {
              r = SourceResult(
                title: r.title,
                url: r.url,
                source: SourceId.cnki,
                year: r.year,
                authors: r.authors,
                ext: '',
                summary: note,
                landingUrl: r.landingUrl,
              );
              final clean = note.replaceAll(RegExp(r'\s+'), ' ').trim();
              excerpts.add((
                r,
                clean.length > 1800 ? '${clean.substring(0, 1800)}…' : clean,
              ));
              _log('    已读取知网可见摘要/页面信息。');
            }
          } else if (playwright.lastSearchDiag.isNotEmpty) {
            _log('    知网页面读取诊断：${playwright.lastSearchDiag}');
          }
        }
        _log('  登记知网引用（需手动下载）：${r.title}');
        await _referenceNote(
          r,
          category,
          research: researchTitle,
          highValue: highValue,
        );
        cnkiRefs++;
        if (zoteroOn && await _saveToZotero(topic, r, null)) zoteroSaved++;
        continue;
      }

      if (r.source == SourceId.github) {
        if (ghRead >= _maxDownloads || _existsInLibrary(r.title)) continue;
        _log('  阅读 GitHub 工程 README：${r.title}');
        final readme = await _fetchGithubReadme(r.title, r.url);
        if (readme == null || readme.trim().length < 50) {
          _log('    未取到 README，仅登记引用。');
          if (zoteroOn && await _saveToZotero(topic, r, null)) zoteroSaved++;
          continue;
        }
        final relPath = await fileLibrary.saveDownloaded(
          '${_sanitize(r.title)}-README.md',
          Uint8List.fromList(utf8.encode(readme)),
        );
        final notePath = await _fileNote(
          r,
          category,
          relPath,
          'text',
          research: researchTitle,
          highValue: highValue,
        );
        downloaded.add((r, relPath));
        textNotes.add(notePath);
        ghRead++;
        final clean = readme.replaceAll(RegExp(r'\s+'), ' ').trim();
        excerpts.add((
          r,
          clean.length > 2600 ? '${clean.substring(0, 2600)}…' : clean,
        ));
        _log('    已阅读并保存 README（${clean.length} 字）。');
        if (zoteroOn && await _saveToZotero(topic, r, null)) zoteroSaved++;
        continue;
      }

      if (!r.downloadable) continue;
      if (downloaded.length >= _maxDownloads || _existsInLibrary(r.title)) {
        continue;
      }
      if (r.ext == 'html') {
        final browserRead = _browserReadsByUrl[r.url];
        if (browserRead != null) {
          _log('  保存浏览研究已读网页：${r.title}');
          final noteText = _browserNotesByUrl[r.url] ?? browserRead.excerpt;
          final pageText = browserRead.visibleText.isNotEmpty
              ? browserRead.visibleText
              : browserRead.excerpt;
          final html =
              '''
<!doctype html>
<meta charset="utf-8">
<title>${_escapeHtml(r.title)}</title>
<h1>${_escapeHtml(r.title)}</h1>
<p><a href="${_escapeHtml(r.url)}">${_escapeHtml(r.url)}</a></p>
<h2>阅读路径</h2>
<p>${_escapeHtml(browserRead.readingPath)}</p>
<h2>页面摘录</h2>
<pre>${_escapeHtml(pageText)}</pre>
''';
          final relPath = await fileLibrary.saveDownloaded(
            '${_sanitize(r.title)}.html',
            Uint8List.fromList(utf8.encode(html)),
          );
          await _fileNote(
            r,
            category,
            relPath,
            'html',
            excerpt: [
              if (browserRead.readingPath.isNotEmpty)
                '阅读路径：${browserRead.readingPath}',
              if (noteText.isNotEmpty) noteText,
            ].join('\n\n'),
            research: researchTitle,
            highValue: highValue,
          );
          final clean = noteText.isNotEmpty ? noteText : pageText;
          if (clean.trim().isNotEmpty) {
            excerpts.add((
              r,
              clean.length > 2600 ? '${clean.substring(0, 2600)}…' : clean,
            ));
          }
          downloaded.add((r, relPath));
          _log('    已保存浏览阅读摘录与笔记。');
          if (zoteroOn && await _saveToZotero(topic, r, null)) zoteroSaved++;
          continue;
        }
        // 网页正文「首选」用 Jina Reader 抓取干净 Markdown（借鉴 Agent-Reach：r.jina.ai/URL）。
        // 拿到的是清洗后的正文而非一堆 HTML 标签——这是抓取质量提升最大的一步。
        // 仅当 Jina 拿不到正文时，才退回下面的 Playwright 渲染/阅读路径。
        final jinaText = await _readWithJina(r.url);
        if (jinaText != null) {
          _log('  用 Jina Reader 读取网页正文：${r.title}');
          final relPath = await fileLibrary.saveDownloaded(
            '${_sanitize(r.title)}.md',
            Uint8List.fromList(utf8.encode(jinaText)),
          );
          final notePath = await _fileNote(
            r,
            category,
            relPath,
            'text',
            research: researchTitle,
            highValue: highValue,
          );
          downloaded.add((r, relPath));
          textNotes.add(notePath);
          final clean = jinaText.replaceAll(RegExp(r'\s+'), ' ').trim();
          excerpts.add((
            r,
            clean.length > 2600 ? '${clean.substring(0, 2600)}…' : clean,
          ));
          _log('    已用 Jina Reader 读取正文（${clean.length} 字）。');
          if (zoteroOn && await _saveToZotero(topic, r, null)) zoteroSaved++;
          continue;
        }
        if (pwReady) {
          _log('  渲染网页并存为 PDF：${r.title}');
          final pdf = await playwright.pagePdf(r.url);
          if (pdf != null && _looksLikePdf(pdf)) {
            final relPath = await fileLibrary.saveDownloaded(
              '${_sanitize(r.title)}.pdf',
              pdf,
            );
            final notePath = await _fileNote(
              r,
              category,
              relPath,
              'text',
              research: researchTitle,
              highValue: highValue,
            );
            downloaded.add((r, relPath));
            textNotes.add(notePath);
            final body = await _pdfText(pdf);
            if (body.trim().isNotEmpty) {
              final clean = body.replaceAll(RegExp(r'\s+'), ' ').trim();
              excerpts.add((
                r,
                clean.length > 2600 ? '${clean.substring(0, 2600)}…' : clean,
              ));
              _log('    已研读正文（${clean.length} 字）。');
            }
            _log('    已保存网页 PDF 与笔记。');
            if (zoteroOn && await _saveToZotero(topic, r, pdf)) zoteroSaved++;
            continue;
          }
          _log('    渲染 PDF 失败，改用 Playwright 直接阅读页面。');
        }
        _log('  用 Playwright 阅读并保存网页：${r.title}');
        final read = pwReady
            ? await playwright.readPage(r.url, onLoginRequired: onLoginRequired)
            : null;
        if (read == null ||
            (read.visibleText.isEmpty && read.excerpt.trim().length < 80)) {
          if (playwright.lastSearchDiag.isNotEmpty) {
            _log('    Playwright 阅读诊断：${playwright.lastSearchDiag}');
          }
          _log('    Playwright 未读到有效正文，跳过。');
          continue;
        }
        final pageText = read.visibleText.isNotEmpty
            ? read.visibleText
            : read.excerpt;
        final relPath = await fileLibrary.saveDownloaded(
          '${_sanitize(r.title)}.html',
          Uint8List.fromList(
            utf8.encode('''
<!doctype html>
<meta charset="utf-8">
<title>${_escapeHtml(r.title)}</title>
<h1>${_escapeHtml(r.title)}</h1>
<p><a href="${_escapeHtml(r.url)}">${_escapeHtml(r.url)}</a></p>
<h2>阅读路径</h2>
<p>${_escapeHtml(read.readingPath)}</p>
<h2>页面摘录</h2>
<pre>${_escapeHtml(pageText)}</pre>
'''),
          ),
        );
        final ex = pageText.length > 2600
            ? '${pageText.substring(0, 2600)}…'
            : pageText;
        await _fileNote(
          r,
          category,
          relPath,
          'html',
          excerpt: ex,
          research: researchTitle,
          highValue: highValue,
        );
        if (ex.isNotEmpty) excerpts.add((r, ex));
        downloaded.add((r, relPath));
        _log('    已保存网页与笔记。');
        if (zoteroOn && await _saveToZotero(topic, r, null)) zoteroSaved++;
      } else {
        _log('  下载：${r.title}');
        var bytes = await _download(r.url, r.ext);
        if (bytes == null && pwReady && r.ext == 'pdf') {
          _log('    常规下载失败，改用 Playwright 抓取 PDF…');
          final pw = await playwright.downloadPdf(r.url);
          if (pw != null && _looksLikePdf(pw)) bytes = pw;
        }
        if (bytes == null) {
          _log('    无效或下载失败，跳过。');
          continue;
        }
        final relPath = await fileLibrary.saveDownloaded(
          '${_sanitize(r.title)}.${r.ext}',
          bytes,
        );
        final isText = _isTextDoc(relPath);
        final notePath = await _fileNote(
          r,
          category,
          relPath,
          isText ? 'text' : 'media',
          research: researchTitle,
          highValue: highValue,
        );
        downloaded.add((r, relPath));
        if (isText) textNotes.add(notePath);
        _log('    已保存：$relPath');
        String body = '';
        if (r.ext == 'pdf') {
          body = await _pdfText(bytes);
        } else if (r.ext == 'txt') {
          body = utf8.decode(bytes, allowMalformed: true);
        }
        if (body.trim().isNotEmpty) {
          final clean = body.replaceAll(RegExp(r'\s+'), ' ').trim();
          excerpts.add((
            r,
            clean.length > 2600 ? '${clean.substring(0, 2600)}…' : clean,
          ));
          _log('    已研读正文（${clean.length} 字）。');
        }
        if (zoteroOn &&
            await _saveToZotero(topic, r, r.ext == 'pdf' ? bytes : null)) {
          zoteroSaved++;
        }
      }
    }

    if (cnkiRefs > 0) {
      _log('    已登记知网引用 $cnkiRefs 条，可打开链接后按机构权限手动下载。');
    }
    return _CollectedResearch(
      downloaded: downloaded,
      excerpts: excerpts,
      textNotes: textNotes,
      zoteroSaved: zoteroSaved,
      cnkiRefs: cnkiRefs,
    );
  }

  // ---------- 综合 ----------

  Future<String> _synthesize(
    String topic,
    List<String> angles,
    List<SourceResult> findings,
    List<(SourceResult, String)> excerpts, [
    String clarification = '',
    List<_ValuedSource> highValue = const [],
    String projectPack = '',
    String projectContrast = '',
  ]) async {
    final buf = StringBuffer();
    var i = 0;
    for (final r in findings.take(_maxFindingsForSynthesis)) {
      i++;
      buf.writeln(
        '[$i][${r.source.label}] ${r.title}'
        '${r.year.isEmpty ? '' : '（${r.year}）'}',
      );
      if (r.summary.isNotEmpty) buf.writeln('    摘要：${r.summary}');
      if (r.landingUrl != null) buf.writeln('    链接：${r.landingUrl}');
    }

    // 已下载并研读的资料正文摘录（这是“真正读过的内容”，用于提炼设计思想）。
    final readBuf = StringBuffer();
    var j = 0;
    for (final e in excerpts.take(6)) {
      j++;
      readBuf
        ..writeln('〔资料$j〕${e.$1.title}')
        ..writeln(e.$2)
        ..writeln();
    }

    final highBuf = StringBuffer();
    var h = 0;
    for (final v in highValue.take(_maxHighValueSources)) {
      h++;
      final r = v.result;
      highBuf.writeln(
        '[$h][${r.source.label}] ${r.title}：${v.reason}，评分 ${v.score.toStringAsFixed(1)}',
      );
      highBuf.writeln('    链接：${r.landingUrl ?? r.url}');
    }

    final prompt =
        '''
研究问题：「$topic」
${clarification.trim().isEmpty ? '' : '用户澄清的研究意图（报告须紧扣此意图，尤其是同名概念要锁定到用户所指的对象）：\n${clarification.trim()}\n'}
${angles.isEmpty ? '' : '调研角度：${angles.join('；')}'}

下面有两部分材料：
A. 检索线索清单（论文/开源项目/网页的标题与摘要）：
$buf
${highBuf.isEmpty ? '' : '''
B. 系统在多轮检索中标记出的高价值资料候选（请在报告中单独说明其价值与用途）：
$highBuf'''}
${readBuf.isEmpty ? '' : '''
C. 我已经下载并通读的资料正文摘录（这是真实读过的内容，请重点基于它做深入分析与提炼）：
$readBuf'''}
${projectPack.trim().isEmpty ? '' : '''
D. 用户挂接的本地工程上下文（结构 / 文档 / 相关源码摘录），报告须落到"这些工程如何改进/落地"：
${_clipForPrompt(projectPack, 5000)}'''}
${projectContrast.trim().isEmpty ? '' : '''
E. 系统对挂接工程做的"对照分析"（基于外部线索回读本地代码得出的现状/差距/可借鉴点/建议改动面）：
$projectContrast'''}

请扮演资深研究员，产出一份**有深度、有自己思考**的研究报告，而不是简单罗列摘要。要求：
- 不要编造未出现的论文或项目；具体引用对应到上面的线索。
- 必须从“已通读的资料正文”中提炼出可迁移的关键设计思想/创新点，并指出它们能如何组合或改进。
- 对关键思路要做“方案尝试”式的推演：给出 2-3 条候选技术路线，分别说明其原理、前提假设、预期效果、风险，以及**如何验证**（用什么数据/指标/对照实验来检验）。
${projectPack.trim().isEmpty ? '' : '- 存在挂接工程时，"与挂接工程的对照"一节必须结合材料 D/E，指出各工程的现状能力、差距、可直接复用的模块与建议落地步骤；引用到的路径/模块必须来自材料，禁止臆造。\n'}
用中文输出 Markdown 报告，包含以下小节（二级标题 ##）：
## 研究问题与背景
## 关键概念与定义
## 主流方法与技术路线（横向对比优劣）
## 思路探索与方案尝试（2-3 条候选路线：原理 / 前提 / 预期 / 风险 / 验证方法）
## 从资料中提炼的设计思想（结合已通读正文，给出可迁移的关键原则与创新点，并说明如何借鉴组合）
${projectPack.trim().isEmpty ? '' : '## 与挂接工程的对照（各工程的现状能力 / 差距 / 可直接复用的模块 / 建议落地步骤）\n'}## 高价值资料与依据（列出最值得继续精读/手动下载/复现实验的资料，并解释价值）
## 代表性论文（标注年份）
## 开源实现与可参考项目（仓库名与链接）
## 推荐实现路径（分步骤、可落地，每步注明如何验证）
## 难点与待解决问题

只输出报告正文，不要代码块包裹。''';
    var sysMem = '';
    try {
      final recall = await memory.recall(
        query: clarification.trim().isEmpty
            ? topic
            : '$topic ${clarification.trim()}',
      );
      if (!recall.isEmpty) {
        sysMem =
            '\n\n以下是关于用户的长期记忆，请据此调整研究视角与侧重（是过去的快照，用前请核实）：\n${recall.injection}';
      }
    } catch (_) {
      // 记忆失败不影响研究主流程。
    }
    return _chat([
      {
        'role': 'system',
        'content':
            '你是资深技术研究员，擅长精读论文与源码，提炼可迁移的设计思想，并提出可验证的技术方案。始终用中文，重分析与推演而非罗列。$sysMem',
      },
      {'role': 'user', 'content': prompt},
    ], useExperimentModel: settings.playwrightBrowserResearchEnabled);
  }

  /// 抽取 PDF 正文文本（前若干页，截断到 maxChars）。整体加硬超时，
  /// 避免个别异常 PDF 导致 pdfium 长时间无响应而卡住整个研究流程。
  Future<String> _pdfText(
    Uint8List bytes, {
    int maxChars = 6000,
    int maxPages = 10,
  }) async {
    try {
      return await _extractPdf(
        bytes,
        maxChars,
        maxPages,
      ).timeout(const Duration(seconds: 30));
    } catch (_) {
      return '';
    }
  }

  Future<String> _extractPdf(
    Uint8List bytes,
    int maxChars,
    int maxPages,
  ) async {
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openData(bytes);
      final sb = StringBuffer();
      final count = doc.pages.length < maxPages ? doc.pages.length : maxPages;
      for (var i = 0; i < count; i++) {
        final t = await doc.pages[i].loadText();
        if (t != null && t.fullText.isNotEmpty) {
          sb.write(t.fullText);
          sb.write('\n');
        }
        if (sb.length >= maxChars) break;
      }
      final s = sb.toString();
      return s.length > maxChars ? s.substring(0, maxChars) : s;
    } catch (_) {
      return '';
    } finally {
      await doc?.dispose();
    }
  }

  Future<String> _saveReport(
    String title,
    String originalTopic,
    String category,
    String report,
    List<SourceResult> findings,
    List<(SourceResult, String)> downloaded,
    List<_ValuedSource> highValue,
    List<String> roundNotePaths,
  ) async {
    final dir = Directory(p.join(library.notesDir, _sanitize(category)));
    await dir.create(recursive: true);

    // 1) 先生成 HTML 报告页（带样式），保存进文件库。
    final htmlMd = StringBuffer()
      ..writeln('# $title')
      ..writeln()
      ..writeln(report.trim())
      ..writeln();
    if (downloaded.isNotEmpty) {
      htmlMd
        ..writeln('## 本地资料')
        ..writeln();
      for (final d in downloaded) {
        htmlMd.writeln('- ${d.$1.title}（${d.$2}）');
      }
      htmlMd.writeln();
    }
    if (highValue.isNotEmpty) {
      htmlMd
        ..writeln('## 高价值资料')
        ..writeln();
      for (final v in highValue) {
        final r = v.result;
        htmlMd.writeln(
          '- [${r.source.label}] [${r.title}](${r.landingUrl ?? r.url})：${v.reason}',
        );
      }
      htmlMd.writeln();
    }
    htmlMd
      ..writeln('## 参考来源')
      ..writeln();
    for (final r in findings) {
      final link = r.landingUrl ?? r.url;
      htmlMd.writeln('- [${r.source.label}] [${r.title}]($link)');
    }
    final htmlRel = await fileLibrary.saveDownloaded(
      '${_sanitize(title)}.html',
      Uint8List.fromList(utf8.encode(_renderHtml(title, htmlMd.toString()))),
    );

    // 2) 生成 Markdown 笔记，首链接指向 HTML 报告（即“打开原文”预览的对象）。
    final body = StringBuffer()
      ..writeln('## 研究报告')
      ..writeln()
      ..writeln('[[${htmlRel.replaceAll('\\', '/')}|打开 HTML 报告]]')
      ..writeln()
      ..writeln(report.trim())
      ..writeln();
    if (downloaded.isNotEmpty) {
      body
        ..writeln('## 本地资料')
        ..writeln();
      for (final d in downloaded) {
        body.writeln('- [[${d.$2.replaceAll('\\', '/')}|${d.$1.title}]]');
      }
      body.writeln();
    }
    if (roundNotePaths.isNotEmpty) {
      body
        ..writeln('## 研究过程笔记')
        ..writeln();
      for (final path in roundNotePaths) {
        final rel = p.relative(path, from: settings.vaultPath);
        body.writeln(
          '- [[${rel.replaceAll('\\', '/')}|${p.basenameWithoutExtension(path)}]]',
        );
      }
      body.writeln();
    }
    if (highValue.isNotEmpty) {
      body
        ..writeln('## 高价值资料')
        ..writeln();
      for (final v in highValue) {
        final r = v.result;
        body.writeln(
          '- [${r.source.label}] ${r.title}（${v.reason}）— ${r.landingUrl ?? r.url}',
        );
      }
      body.writeln();
    }
    body
      ..writeln('## 参考来源')
      ..writeln();
    for (final r in findings) {
      final link = r.landingUrl ?? r.url;
      body.writeln('- [${r.source.label}] ${r.title} — $link');
    }
    body
      ..writeln()
      ..writeln('## 我的笔记')
      ..writeln();

    final content =
        '''
---
题名: "${title.replaceAll('"', '')}"
类别: ${_sanitize(category)}
来源: 主题研究
研究: "${title.replaceAll('"', '')}"
研究问题: "${originalTopic.replaceAll('"', '')}"
报告: ${htmlRel.replaceAll('\\', '/')}
状态: 未读
tags:
  - 研究
  - $title
---

$body''';
    final file = File(p.join(dir.path, '${_sanitize(title)}.md'));
    await file.writeAsString(content);
    return file.path;
  }

  /// 将 Markdown 渲染成一份带样式、可独立打开的 HTML 报告页。
  String _renderHtml(String title, String markdown) {
    final inner = md.markdownToHtml(
      markdown,
      extensionSet: md.ExtensionSet.gitHubWeb,
    );
    final safeTitle = title.replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$safeTitle</title>
<style>
  :root { color-scheme: light; }
  body { margin: 0; background: #f4f5f7; color: #1f2328;
    font-family: "Microsoft YaHei UI", "Segoe UI", system-ui, sans-serif;
    line-height: 1.75; }
  .page { max-width: 860px; margin: 40px auto; background: #fff;
    border-radius: 14px; padding: 48px 56px;
    box-shadow: 0 8px 40px rgba(0,0,0,.06); }
  h1 { font-size: 28px; margin: 0 0 4px; }
  h2 { font-size: 20px; margin: 32px 0 12px; padding-bottom: 6px;
    border-bottom: 2px solid #0d948822; color: #0f766e; }
  h3 { font-size: 16px; margin: 22px 0 8px; }
  p, li { font-size: 15px; }
  a { color: #0d9488; text-decoration: none; }
  a:hover { text-decoration: underline; }
  ul { padding-left: 22px; }
  li { margin: 4px 0; }
  blockquote { margin: 12px 0; padding: 8px 16px; color: #57606a;
    border-left: 4px solid #d0d7de; background: #f6f8fa; border-radius: 4px; }
  code { background: #f0f1f3; padding: 1px 6px; border-radius: 4px;
    font-size: 13px; }
  hr { border: none; border-top: 1px solid #eaecef; margin: 28px 0; }
  .meta { color: #8b949e; font-size: 13px; margin-bottom: 24px; }
</style>
</head>
<body>
  <div class="page">
    <div class="meta">第二大脑 · 主题研究报告</div>
    $inner
  </div>
</body>
</html>''';
  }

  Future<void> _simpleNote(
    SourceResult r,
    String category,
    String relPath, {
    String research = '',
  }) => _fileNote(
    r,
    category,
    relPath,
    _isTextDoc(relPath) ? 'text' : 'media',
    research: research,
  );

  Future<String> _saveRoundNote({
    required String category,
    required String researchTitle,
    required _ResearchRound round,
    required List<_ResearchInsight> insights,
    required List<ResearchSourceProfile> profiles,
  }) async {
    final dir = Directory(p.join(library.notesDir, _sanitize(category)));
    await dir.create(recursive: true);
    final title = '${_sanitize(researchTitle)}-第${round.index}轮研究笔记';
    final queryText = round.items
        .map((i) => '- ${i.source.label}：${i.query}')
        .join('\n');
    final profileText = profiles.isEmpty
        ? '（未使用特定 profile）'
        : profiles
              .map((p) => '- ${p.label}（${p.id}）：${p.description}')
              .join('\n');
    final findingText = round.findings
        .take(30)
        .map((r) {
          final link = r.landingUrl ?? r.url;
          return '- [${r.source.label}] ${r.title}${r.year.isEmpty ? '' : '（${r.year}）'} — $link';
        })
        .join('\n');
    final insightText = insights.isEmpty
        ? '（本轮未抽取出新的稳定概念）'
        : insights
              .map((i) => '- ${i.reason}：${i.terms.take(12).join('、')}')
              .join('\n');
    final nextText = round.nextSeeds.isEmpty
        ? '（质量门判断无需继续，或没有新的高质量补搜查询）'
        : round.nextSeeds
              .take(_maxQueriesPerRound)
              .map((s) => '- ${s.source.label}：${s.query}（${s.reason}）')
              .join('\n');
    final gapText = round.gaps.isEmpty
        ? '（未发现必须补搜的明确缺口）'
        : round.gaps.map((g) => '- $g').join('\n');
    final content =
        '''
---
题名: "$title"
类别: ${_sanitize(category)}
来源: 主题研究过程
研究: "${researchTitle.replaceAll('"', '')}"
轮次: ${round.index}
状态: 未读
tags:
  - 研究过程
  - $researchTitle
---

## 本轮查询

$queryText

## 来源画像

$profileText

## 本轮新增线索

${findingText.isEmpty ? '（本轮未新增线索）' : findingText}

## 关联概念

$insightText

## 质量门判断

${round.gateNote.isEmpty ? '（未记录）' : round.gateNote}

## 当前缺口

$gapText

## 下一轮扩展方向

$nextText

## 我的笔记
''';
    final file = File(p.join(dir.path, '$title.md'));
    await file.writeAsString(content);
    return file.path;
  }

  Future<String> _referenceNote(
    SourceResult r,
    String category, {
    String research = '',
    bool highValue = false,
  }) async {
    final dir = Directory(p.join(library.notesDir, _sanitize(category)));
    await dir.create(recursive: true);
    final url = r.landingUrl ?? r.url;
    final meta = StringBuffer()
      ..writeln('题名: "${r.title.replaceAll('"', '')}"')
      ..writeln('类别: ${_sanitize(category)}')
      ..writeln('来源: ${r.source.label}')
      ..writeln('年份: "${r.year}"')
      ..writeln('状态: 待手动下载');
    if (highValue) meta.writeln('价值: 高');
    if (research.isNotEmpty) {
      meta.writeln('研究: "${research.replaceAll('"', '')}"');
    }
    if (r.authors.isNotEmpty) meta.writeln('作者: "${r.authors}"');
    final content =
        '''
---
${meta.toString().trimRight()}
tags:
  - ${_sanitize(category)}
  - ${r.source.label}${highValue ? '\n  - 高价值资料' : ''}${research.isEmpty ? '' : '\n  - $research'}
---

## 引用入口

[$url]($url)

${r.summary.isEmpty ? '' : '> ${r.summary.replaceAll('\n', ' ')}\n'}
## 手动下载

该条目来自 ${r.source.label}。请打开上方链接，按机构权限、账号权限或站点要求手动下载全文，再导入知识库。

## 我的笔记
''';
    final file = File(p.join(dir.path, '${_sanitize(r.title)}.md'));
    await file.writeAsString(content);
    return file.path;
  }

  /// 为单份资料创建笔记。noteKind: text(文档,留空待 AI 填) / html(网页,附摘录) / media(图片视频)。
  Future<String> _fileNote(
    SourceResult r,
    String category,
    String relPath,
    String noteKind, {
    String? excerpt,
    String research = '',
    bool highValue = false,
  }) async {
    final dir = Directory(p.join(library.notesDir, _sanitize(category)));
    await dir.create(recursive: true);
    final wiki = relPath.replaceAll('\\', '/');

    final body = StringBuffer()
      ..writeln('## 原文')
      ..writeln()
      ..writeln('[[$wiki|打开原文]]');
    if (r.landingUrl != null) {
      body
        ..writeln()
        ..writeln('来源页面：${r.landingUrl}');
    }
    if (r.summary.isNotEmpty) {
      body
        ..writeln()
        ..writeln('> ${r.summary.replaceAll('\n', ' ')}');
    }
    body.writeln();

    if (noteKind == 'text') {
      body
        ..writeln('## 适用范围')
        ..writeln()
        ..writeln('## 核心要点')
        ..writeln()
        ..writeln('## 相关标准')
        ..writeln();
    } else if (noteKind == 'html' && excerpt != null && excerpt.isNotEmpty) {
      body
        ..writeln('## 网页摘录')
        ..writeln()
        ..writeln(excerpt)
        ..writeln();
    }
    body.writeln('## 我的笔记');

    final meta = StringBuffer()
      ..writeln('题名: "${r.title.replaceAll('"', '')}"')
      ..writeln('类别: ${_sanitize(category)}')
      ..writeln('来源: ${r.source.label}')
      ..writeln('年份: "${r.year}"')
      ..writeln('状态: 未读');
    if (highValue) meta.writeln('价值: 高');
    if (research.isNotEmpty) {
      meta.writeln('研究: "${research.replaceAll('"', '')}"');
    }
    if (r.authors.isNotEmpty) meta.writeln('作者: "${r.authors}"');

    final content =
        '''
---
${meta.toString().trimRight()}
tags:
  - ${_sanitize(category)}
  - ${r.source.label}${highValue ? '\n  - 高价值资料' : ''}${research.isEmpty ? '' : '\n  - $research'}
---

$body''';
    final file = File(p.join(dir.path, '${_sanitize(r.title)}.md'));
    await file.writeAsString(content);
    return file.path;
  }

  bool _isTextDoc(String relPath) {
    final p = relPath.toLowerCase();
    return p.endsWith('.pdf') ||
        p.endsWith('.txt') ||
        p.endsWith('.epub') ||
        p.endsWith('.doc') ||
        p.endsWith('.docx');
  }

  static String _escapeHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  static String _clipForPrompt(String s, int max) =>
      clip(s.replaceAll(RegExp(r'\s+'), ' ').trim(), max, suffix: '…');

  // ---------- 下载与校验 ----------

  bool _existsInLibrary(String title) {
    final t = title.trim();
    return library.notes.any((n) => n.fullTitle == t);
  }

  /// 抓取 GitHub 仓库的 README 原文，用于真正“阅读”该开源工程。
  /// [fullName] 形如 `owner/repo`；[url] 为仓库主页，作备用解析。
  Future<String?> _fetchGithubReadme(String fullName, String url) async {
    var repo = fullName.trim();
    if (!RegExp(r'^[^/]+/[^/]+$').hasMatch(repo)) {
      // 从主页 URL 解析 owner/repo。
      final m = RegExp(r'github\.com/([^/]+/[^/#?]+)').firstMatch(url);
      if (m == null) return null;
      repo = m.group(1)!;
    }
    try {
      final resp = await http
          .get(
            Uri.parse('https://api.github.com/repos/$repo/readme'),
            headers: {
              'User-Agent': SourceAdapter.userAgent,
              'Accept': 'application/vnd.github.raw+json',
            },
          )
          .timeout(const Duration(seconds: 25));
      if (resp.statusCode != 200) return null;
      final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
      // 若返回的是 JSON（base64 编码），解码 content 字段。
      if (text.trimLeft().startsWith('{')) {
        final data = jsonDecode(text) as Map;
        final content = data['content'] as String?;
        if (content == null) return null;
        return utf8.decode(
          base64.decode(content.replaceAll('\n', '')),
          allowMalformed: true,
        );
      }
      return text;
    } catch (_) {
      return null;
    }
  }

  /// 用 Jina Reader 读取任意网页，返回清洗后的 Markdown 正文。
  /// 借鉴 Agent-Reach 的 web 渠道：把目标 URL 前缀上 https://r.jina.ai/ 即可，
  /// 免 API Key、免本地浏览器，返回的是去掉导航/广告/脚本后的正文。
  /// 拿不到正文（非 200 或内容过短）时返回 null，由调用方决定是否退回 Playwright。
  // 网页正文读取已统一到共享的 [WebReader]（见 lib/services/web_reader.dart），
  // 这里仅做薄封装，便于本文件内部沿用原方法名。
  Future<String?> _readWithJina(String url) => _webReader.readMarkdown(url);

  /// 从 Jina/Markdown 文本里取标题（委托共享 WebReader）。
  String? _titleFromMarkdown(String text) => _webReader.titleFromMarkdown(text);

  /// 直接读取用户写在研究主题/澄清里的网址（借鉴 Agent-Reach：URL 用 Jina Reader 读干净正文）。
  /// GitHub 仓库优先走 README API；其余网页走 Jina Reader，失败再退回 Playwright。
  /// 把每个网址存为研读资料 + 笔记，并登记进 _directReadUrls 以免后续重复抓取；
  /// 返回 (来源, 正文摘录) 列表，作为最贴题的种子资料并入综合分析。
  Future<List<(SourceResult, String)>> _readTopicUrls(
    String topic,
    String clarification,
    String category,
    String researchTitle,
    bool pwReady,
  ) async {
    final urls = RegExp(r'https?://[^\s，,）)】\]"]+')
        .allMatches('$topic\n$clarification')
        .map((m) => m.group(0)!.trim())
        .toSet();
    if (urls.isEmpty) return const [];
    _log('  主题中包含 ${urls.length} 个网址，直接读取其正文（Jina Reader / GitHub）：');
    final out = <(SourceResult, String)>[];
    for (final url in urls) {
      if (out.length >= 4) break;
      try {
        // GitHub 仓库优先用 README（正文更结构化）；其余网页用 Jina Reader。
        final ghm = RegExp(r'github\.com/([^/]+/[^/#?]+)').firstMatch(url);
        String? body;
        String title;
        SourceId src;
        if (ghm != null) {
          final repo = ghm.group(1)!.replaceAll(RegExp(r'\.git$'), '');
          body = await _fetchGithubReadme(repo, url);
          title = repo;
          src = SourceId.github;
        } else {
          body = await _readWithJina(url);
          title = _titleFromMarkdown(body ?? '') ?? Uri.parse(url).host;
          src = SourceId.web;
        }
        // 拿不到正文则退回 Playwright（用户已选：Jina 为首选，失败再退回）。
        if ((body == null || body.trim().length < 50) && pwReady) {
          final read = await playwright.readPage(
            url,
            onLoginRequired: onLoginRequired,
          );
          if (read != null) {
            body = read.visibleText.isNotEmpty
                ? read.visibleText
                : read.excerpt;
          }
        }
        if (body == null || body.trim().length < 50) {
          _log('    读取失败：$url');
          continue;
        }
        final relPath = await fileLibrary.saveDownloaded(
          '${_sanitize(title)}.md',
          Uint8List.fromList(utf8.encode(body)),
        );
        final r = SourceResult(
          title: title,
          url: url,
          source: src,
          ext: '',
          summary: '用户在研究主题中直接指定的网址，已读取正文。',
          landingUrl: url,
        );
        await _fileNote(
          r,
          category,
          relPath,
          'text',
          research: researchTitle,
          highValue: true,
        );
        _directReadUrls.add(url);
        final clean = body.replaceAll(RegExp(r'\s+'), ' ').trim();
        out.add((
          r,
          clean.length > 2600 ? '${clean.substring(0, 2600)}…' : clean,
        ));
        _log('    已读取并保存：$title（${clean.length} 字）');
      } catch (e) {
        _log('    读取出错：$url（$e）');
      }
    }
    return out;
  }

  Future<Uint8List?> _download(String url, String ext) async {
    try {
      final resp = await http
          .get(
            Uri.parse(url),
            headers: {'User-Agent': SourceAdapter.userAgent, 'Accept': '*/*'},
          )
          .timeout(const Duration(seconds: 40));
      if (resp.statusCode != 200) return null;
      final bytes = resp.bodyBytes;
      if (bytes.length < 1024) return null;
      if (ext == 'pdf') return _looksLikePdf(bytes) ? bytes : null;
      if (_looksLikeHtml(bytes)) return null;
      return bytes;
    } catch (_) {
      return null;
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

  static bool _looksLikeHtml(Uint8List bytes) {
    final head = String.fromCharCodes(
      bytes.take(256).where((b) => b != 0x20 && b != 0x0a && b != 0x0d),
    ).toLowerCase();
    return head.startsWith('<!doctype') || head.startsWith('<html');
  }

  static String _sanitize(String s) => sanitizeFileName(s);

  static String _cleanResearchTitle(String s) {
    var out = s
        .replaceAll(RegExp(r'^【研究】'), '')
        .replaceAll(RegExp(r'^研究[:：\s]*'), '')
        .trim();
    if (out.length > 24) out = out.substring(0, 24).trim();
    return out.isEmpty ? '未命名研究' : out;
  }

  /// 宽松解析模型返回的 JSON 对象：大模型经常输出带 ```json 代码围栏、
  /// 或对象/数组末尾多一个逗号的非法 JSON，Dart 的严格 jsonDecode 会直接抛
  /// FormatException。这里先剥离围栏、截取最外层 {...}、去掉尾随逗号再解析；
  /// 解析不出对象时返回 null，由调用方决定默认行为。
  Map<String, dynamic>? _parseJsonObject(String raw) {
    try {
      return ModelClient.parseJsonObject(raw);
    } catch (_) {
      return null;
    }
  }

  /// 判断异常是否为「模型不支持图片输入」：这类模型只接受纯文本 content，
  /// 收到 image_url 时供应商会返回类似 `messages.content.type 参数非法，
  /// 取值范围 ['text']` 的 400 错误。命中后应跳过截图、改用纯文本，而非中断研究。
  bool _isImageUnsupportedError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('content.type') ||
        s.contains("['text']") ||
        s.contains('image_url') ||
        (s.contains('400') && s.contains('image'));
  }

  Future<String> _chat(
    List<Map<String, dynamic>> messages, {
    bool jsonMode = false,
    bool useExperimentModel = false,
    ModelRole? role,
  }) async {
    // 统一走 ModelClient：浏览研究用 agent（实验）通道，读图/截图判断用
    // vision 通道，其余研究规划/综合用 research 通道（默认 DeepSeek，可在设置里改）。
    // 显式传入的 [role] 优先级最高。
    role ??= useExperimentModel ? ModelRole.agent : ModelRole.research;
    final content = await ModelClient(
      settings,
      role: role,
    ).complete(messages: messages, jsonMode: jsonMode);
    if (content.isEmpty) throw Exception('模型未返回内容');
    return content;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
