import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import '../util/text_util.dart';
import 'agent/model_client.dart';
import 'file_library_service.dart';
import 'knowledge_service.dart';
import 'library_service.dart';
import 'media_downloader.dart';
import 'settings_service.dart';
import 'topic_service.dart';

/// 「知识库自学习」的配置。持久化为应用数据目录下的 `self_learning.json`。
class SelfLearningConfig {
  SelfLearningConfig({
    this.enabled = false,
    List<String>? topics,
    this.intervalMinutes = 120,
    this.autonomousExpand = false,
    this.mediaEnabled = true,
    this.saveMediaFiles = false,
    this.maxTopicsPerCycle = 2,
    this.maxMediaPerTopic = 3,
  }) : topics = topics ?? [];

  /// 是否处于自学习开启状态（开启后关闭窗口仍在后台持续学习）。
  bool enabled;

  /// 用户配置的固定学习主题列表。
  List<String> topics;

  /// 轮询间隔（分钟）：每隔该时长跑一轮自学习。
  int intervalMinutes;

  /// 是否允许 AI 结合知识体系短板自主扩展子主题。
  bool autonomousExpand;

  /// 是否采集媒体字幕（yt-dlp 抓取平台字幕转文字入库）。
  bool mediaEnabled;

  /// 是否额外把媒体文件本体下载进文件库（默认关闭，避免占满磁盘）。
  bool saveMediaFiles;

  /// 每轮最多研究的主题数。
  int maxTopicsPerCycle;

  /// 每个主题每轮最多采集的媒体条数。
  int maxMediaPerTopic;

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'topics': topics,
        'intervalMinutes': intervalMinutes,
        'autonomousExpand': autonomousExpand,
        'mediaEnabled': mediaEnabled,
        'saveMediaFiles': saveMediaFiles,
        'maxTopicsPerCycle': maxTopicsPerCycle,
        'maxMediaPerTopic': maxMediaPerTopic,
      };

  factory SelfLearningConfig.fromJson(Map<String, dynamic> j) =>
      SelfLearningConfig(
        enabled: j['enabled'] as bool? ?? false,
        topics: (j['topics'] as List?)?.map((e) => e.toString()).toList() ?? [],
        intervalMinutes: (j['intervalMinutes'] as num?)?.toInt() ?? 120,
        autonomousExpand: j['autonomousExpand'] as bool? ?? false,
        mediaEnabled: j['mediaEnabled'] as bool? ?? true,
        saveMediaFiles: j['saveMediaFiles'] as bool? ?? false,
        maxTopicsPerCycle: (j['maxTopicsPerCycle'] as num?)?.toInt() ?? 2,
        maxMediaPerTopic: (j['maxMediaPerTopic'] as num?)?.toInt() ?? 3,
      );

  SelfLearningConfig copy() => SelfLearningConfig.fromJson(toJson());
}

/// 知识库自学习引擎：按配置的主题定时驱动一轮「研究 → 媒体采集 → 整理」，
/// 把新知识写入本地知识库并做去重/关联/综述整理。
///
/// 设计上完全复用现有基础设施：文本研究走 [TopicFetchService.researchForAgent]，
/// 媒体采集走 [MediaDownloader]，所有 LLM 调用走 [ModelClient]（research 角色）。
/// 窗口最小化到托盘后进程不退出，[Timer] 继续驱动循环，实现「始终在线自学习」。
class SelfLearningService extends ChangeNotifier {
  SelfLearningService(
    this.settings,
    this.library,
    this.fileLibrary,
    this.topic,
  );

  final SettingsService settings;
  final LibraryService library;
  final FileLibraryService fileLibrary;
  final TopicFetchService topic;

  SelfLearningConfig config = SelfLearningConfig();

  File? _store;
  Timer? _timer;

  /// 是否正在跑一轮（防止定时器重入）。
  bool running = false;

  /// 当前正在学习的主题（UI 展示）。
  String currentTopic = '';

  /// 已完成的轮次数。
  int cyclesCompleted = 0;

  DateTime? lastRunAt;
  DateTime? nextRunAt;

  final List<String> _logs = [];
  List<String> get logs => List.unmodifiable(_logs);

  static const _maxLogs = 400;

  // ---------------------------------------------------------------------------
  // 生命周期与持久化
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _store = File(p.join(dir.path, 'self_learning.json'));
    if (await _store!.exists()) {
      try {
        config = SelfLearningConfig.fromJson(
          jsonDecode(await _store!.readAsString()) as Map<String, dynamic>,
        );
      } catch (_) {
        config = SelfLearningConfig();
      }
    }
    if (config.enabled && config.topics.isNotEmpty) {
      _schedule();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _persist() async {
    if (_store == null) return;
    await _store!.writeAsString(jsonEncode(config.toJson()));
  }

  // ---------------------------------------------------------------------------
  // 对外控制
  // ---------------------------------------------------------------------------

  /// 保存配置（不改变启停状态）。
  Future<void> saveConfig(SelfLearningConfig next) async {
    config = next;
    await _persist();
    if (config.enabled) _schedule();
    notifyListeners();
  }

  /// 开启自学习：立即跑一轮并按间隔循环。
  Future<void> start() async {
    config.enabled = true;
    await _persist();
    _schedule();
    notifyListeners();
    unawaited(_runCycleGuarded());
  }

  /// 停止自学习。
  Future<void> stop() async {
    config.enabled = false;
    _timer?.cancel();
    _timer = null;
    nextRunAt = null;
    await _persist();
    notifyListeners();
  }

  /// 手动立即跑一轮（不改变启停状态）。
  Future<void> runNow() => _runCycleGuarded();

  void _schedule() {
    _timer?.cancel();
    final interval = Duration(minutes: config.intervalMinutes.clamp(5, 24 * 60));
    _timer = Timer.periodic(interval, (_) => _runCycleGuarded());
    nextRunAt = DateTime.now().add(interval);
  }

  // ---------------------------------------------------------------------------
  // 自学习主循环
  // ---------------------------------------------------------------------------

  Future<void> _runCycleGuarded() async {
    if (running) return;
    running = true;
    notifyListeners();
    try {
      await _runCycle();
    } catch (e) {
      _log('本轮自学习出错：$e');
    } finally {
      running = false;
      currentTopic = '';
      cyclesCompleted++;
      lastRunAt = DateTime.now();
      if (config.enabled) {
        nextRunAt = DateTime.now().add(
          Duration(minutes: config.intervalMinutes.clamp(5, 24 * 60)),
        );
      }
      notifyListeners();
    }
  }

  Future<void> _runCycle() async {
    _log('=== 开始第 ${cyclesCompleted + 1} 轮自学习 ===');
    final topics = await _selectTopics();
    if (topics.isEmpty) {
      _log('没有可学习的主题，本轮结束。');
      return;
    }
    _log('本轮主题：${topics.join('、')}');

    final beforePaths = library.notes.map((n) => n.filePath).toSet();

    for (final t in topics) {
      currentTopic = t;
      notifyListeners();
      await _learnTopic(t);
    }

    _log('整理知识库…');
    await _organize(topics, beforePaths);
    _log('=== 本轮自学习完成 ===');
  }

  /// 选出本轮要学习的主题：固定列表轮换；开启自主扩展时叠加 AI 提出的子主题。
  Future<List<String>> _selectTopics() async {
    final base = config.topics
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    final picked = <String>[];

    // 固定主题按轮次轮换，保证长期均匀覆盖每个主题。
    if (base.isNotEmpty) {
      final start = cyclesCompleted % base.length;
      for (var i = 0; i < base.length && picked.length < config.maxTopicsPerCycle; i++) {
        picked.add(base[(start + i) % base.length]);
      }
    }

    if (config.autonomousExpand) {
      try {
        final expanded = await _proposeSubtopics(base);
        for (final t in expanded) {
          if (picked.length >= config.maxTopicsPerCycle) break;
          if (!picked.contains(t)) picked.add(t);
        }
      } catch (e) {
        _log('自主扩展子主题失败：$e');
      }
    }

    return picked.take(config.maxTopicsPerCycle.clamp(1, 10)).toList();
  }

  /// 结合已有主题与知识体系短板，让 AI 提出值得深入的新子主题。
  Future<List<String>> _proposeSubtopics(List<String> base) async {
    final overview = KnowledgeAnalyzer.analyze(library.notes);
    final weak = overview.weaknesses.take(6).map((d) => d.name).toList();
    final cats = library.categories.take(30).toList();
    final prompt = StringBuffer()
      ..writeln('我在做知识库自学习。请基于以下信息，提出值得下一步深入学习的具体子主题。')
      ..writeln()
      ..writeln('当前关注方向：${base.isEmpty ? '（未设定）' : base.join('、')}')
      ..writeln('知识体系薄弱领域：${weak.isEmpty ? '（无）' : weak.join('、')}')
      ..writeln('已有分类：${cats.isEmpty ? '（无）' : cats.join('、')}')
      ..writeln()
      ..writeln('要求：给出 ${config.maxTopicsPerCycle} 个既贴合当前方向、又能补齐薄弱环节的具体子主题，'
          '避免与已有分类重复宽泛；每个主题是一个可检索的研究问题。')
      ..writeln('只输出 JSON：{"topics":["子主题1","子主题2"]}');
    final obj = await ModelClient(settings, role: ModelRole.research).completeJson(
      system: '你是知识管理与学习规划专家，只输出 JSON。',
      user: prompt.toString(),
    );
    final list = obj['topics'];
    if (list is! List) return const [];
    return list
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// 学习单个主题：先做文本深度研究，再采集媒体字幕。
  Future<void> _learnTopic(String t) async {
    _log('▶ 研究主题：$t');
    try {
      await topic.researchForAgent(
        t,
        recordInHistory: false,
        log: (line) => _log('  $line'),
      );
      _log('  研究报告已入库。');
    } on StateError catch (e) {
      // 用户正在手动研究时 TopicFetchService 忙，跳过本主题的文本研究。
      _log('  跳过文本研究：$e');
    } catch (e) {
      _log('  文本研究失败：$e');
    }

    if (config.mediaEnabled) {
      await _collectMedia(t);
    }
  }

  /// 采集主题相关视频的字幕并转文字入库（字幕优先，不做语音转录）。
  Future<void> _collectMedia(String t) async {
    if (!MediaDownloader.instance.available) {
      _log('  当前平台不支持媒体采集，跳过。');
      return;
    }
    _log('  采集媒体字幕…');
    final hits = await MediaDownloader.instance.searchSubtitles(
      t,
      limit: config.maxMediaPerTopic,
    );
    if (hits.isEmpty) {
      _log('  未找到可用媒体字幕。');
      return;
    }
    final destDir = Directory(
      p.join(fileLibrary.rootDir, config.saveMediaFiles ? '视频' : '文档'),
    );
    for (final hit in hits) {
      if (hit.hasSubtitle) {
        await _writeMediaNote(t, hit);
        _log('  ✓ 字幕入库：${clip(hit.title, 40, suffix: '…')}');
      } else {
        _log('  ⤫ 无字幕（不转录）：${clip(hit.title, 40, suffix: '…')}');
      }
      if (config.saveMediaFiles) {
        final file = await MediaDownloader.instance.download(hit.url, destDir);
        if (file != null) _log('  ⬇ 媒体入库：${p.basename(file)}');
      }
    }
    await fileLibrary.reload();
  }

  Future<void> _writeMediaNote(String topicName, MediaHit hit) async {
    final cat = sanitizeFileName(topicName, fallback: '自学习');
    final dir = Directory(p.join(library.notesDir, cat));
    await dir.create(recursive: true);
    final mins = hit.durationSec > 0 ? '${(hit.durationSec / 60).round()} 分钟' : '未知时长';
    final content = '''
---
题名: "${hit.title.replaceAll('"', '')}"
类别: $cat
来源: 自学习·视频字幕
研究: "${topicName.replaceAll('"', '')}"
链接: ${hit.url}
时长: $mins
状态: 未读
tags:
  - 自学习
  - 视频字幕
  - $topicName
---

## 来源

[${hit.title}](${hit.url})（$mins）

## 字幕正文

${hit.subtitleText}
''';
    final file = File(
      _uniquePath(p.join(dir.path, '${sanitizeFileName(hit.title)}.md')),
    );
    await file.writeAsString(content);
  }

  // ---------------------------------------------------------------------------
  // 整理：去重 / 合并 / 关联 / 综述 / 体系概览
  // ---------------------------------------------------------------------------

  Future<void> _organize(List<String> topics, Set<String> beforePaths) async {
    await library.reload();
    final newNotes =
        library.notes.where((n) => !beforePaths.contains(n.filePath)).toList();

    try {
      final removed = await library.dedupNotes();
      if (removed > 0) _log('  去重：删除 $removed 篇重复笔记。');
    } catch (e) {
      _log('  去重失败：$e');
    }

    try {
      final moved = await library.consolidateCategories();
      if (moved > 0) _log('  合并分类：移动 $moved 篇笔记。');
    } catch (e) {
      _log('  合并分类失败：$e');
    }

    await library.reload();

    // 为本轮新笔记补充关联（wikilink + 标签建议）。
    final refreshed = library.notes
        .where((n) => newNotes.any((x) => x.filePath == n.filePath))
        .toList();
    for (final note in refreshed) {
      try {
        await _enrichLinks(note);
      } catch (_) {}
    }

    // 更新每个主题的综述与全库体系概览。
    for (final t in topics) {
      try {
        await _updateTopicSynthesis(t);
      } catch (e) {
        _log('  更新「$t」综述失败：$e');
      }
    }
    try {
      await _updateOverview();
    } catch (e) {
      _log('  更新体系概览失败：$e');
    }

    await library.reload();
  }

  /// 为一篇笔记挑选最相关的已有笔记，追加「## 关联」小节（[[wikilink]]）。
  Future<void> _enrichLinks(StandardNote note) async {
    final title = note.fullTitle;
    final body = note.body;
    if (body.contains('## 关联')) return; // 已关联过，避免重复。
    final candidates = library.notes
        .where((n) => n.fullTitle != title)
        .map((n) => n.fullTitle)
        .take(120)
        .toList();
    if (candidates.isEmpty) return;
    final obj = await ModelClient(settings, role: ModelRole.small).completeJson(
      system: '你是知识管理专家，只输出 JSON。',
      user: '当前笔记题名：「$title」\n'
          '正文摘要：${clip(body.replaceAll(RegExp(r'\s+'), ' '), 800, suffix: '…')}\n\n'
          '从下面的候选笔记里挑出与当前笔记**主题最相关**的最多 5 篇（必须原样使用候选题名，不相关就返回空数组）：\n'
          '${candidates.map((c) => '- $c').join('\n')}\n\n'
          '只输出 JSON：{"related":["题名1","题名2"]}',
    );
    final rel = (obj['related'] as List?)
            ?.map((e) => e.toString().trim())
            .where((s) => candidates.contains(s))
            .toList() ??
        const [];
    if (rel.isEmpty) return;
    final section = StringBuffer()
      ..writeln()
      ..writeln('## 关联')
      ..writeln();
    for (final r in rel) {
      section.writeln('- [[$r]]');
    }
    await library.saveBody(note, '${body.trimRight()}\n${section.toString()}');
  }

  /// 生成/更新某主题的综述笔记：汇总该主题下已有笔记的要点。
  Future<void> _updateTopicSynthesis(String topicName) async {
    final related = library.notes
        .where((n) =>
            n.research == topicName ||
            n.category == sanitizeFileName(topicName, fallback: '自学习') ||
            n.tags.contains(topicName))
        .toList();
    if (related.isEmpty) return;
    final digest = StringBuffer();
    for (final n in related.take(20)) {
      digest
        ..writeln('### ${n.fullTitle}')
        ..writeln(clip(n.body.replaceAll(RegExp(r'\s+'), ' ').trim(), 900,
            suffix: '…'))
        ..writeln();
    }
    final report = await ModelClient(settings, role: ModelRole.research).complete(
      system: '你是学科综述专家。基于给定的笔记摘要，写一份条理清晰、准确、不编造的中文主题综述。',
      user: '主题：「$topicName」\n\n'
          '以下是该主题下已有笔记的摘要，请综合成一份结构化综述（含：概述、关键要点、'
          '不同来源的共识与分歧、尚待补充的空白），用 Markdown，不要代码块包裹：\n\n'
          '${digest.toString()}',
    );
    if (report.trim().isEmpty) return;
    final cat = sanitizeFileName(topicName, fallback: '自学习');
    final dir = Directory(p.join(library.notesDir, cat));
    await dir.create(recursive: true);
    final content = '''
---
题名: "【综述】${topicName.replaceAll('"', '')}"
类别: $cat
来源: 自学习·综述
研究: "${topicName.replaceAll('"', '')}"
状态: 未读
tags:
  - 自学习
  - 综述
  - $topicName
---

$report
''';
    final file = File(p.join(dir.path, '【综述】${sanitizeFileName(topicName)}.md'));
    await file.writeAsString(content);
    _log('  综述已更新：$topicName');
  }

  /// 生成/更新全库「知识体系概览」笔记。
  Future<void> _updateOverview() async {
    final ov = KnowledgeAnalyzer.analyze(library.notes);
    if (ov.isEmpty) return;
    final domainLines = ov.domains
        .take(20)
        .map((d) => '- ${d.name}：${d.total} 篇，掌握度 ${(d.mastery * 100).round()}%')
        .join('\n');
    final buf = StringBuffer()
      ..writeln('# 知识体系概览（自学习）')
      ..writeln()
      ..writeln('_更新时间：${DateTime.now()}_')
      ..writeln()
      ..writeln('- 笔记总数：${ov.totalNotes}（已读 ${ov.read} / 在读 ${ov.reading} / 未读 ${ov.unread}）')
      ..writeln('- 整体掌握度：${(ov.masteryRatio * 100).round()}%')
      ..writeln('- 孤立笔记（无关联）：${ov.isolated} 篇')
      ..writeln()
      ..writeln('## 领域分布')
      ..writeln()
      ..writeln(domainLines)
      ..writeln()
      ..writeln('## 长处')
      ..writeln()
      ..writeln(ov.strengths.take(5).map((d) => '- ${d.name}').join('\n'))
      ..writeln()
      ..writeln('## 短板（自学习将优先补齐）')
      ..writeln()
      ..writeln(ov.weaknesses.take(8).map((d) => '- ${d.name}').join('\n'));
    final dir = Directory(p.join(library.notesDir, '知识体系'));
    await dir.create(recursive: true);
    final content = '''
---
题名: "知识体系概览（自学习）"
类别: 知识体系
来源: 自学习·概览
状态: 未读
tags:
  - 自学习
  - 体系概览
---

${buf.toString()}
''';
    final file = File(p.join(dir.path, '知识体系概览（自学习）.md'));
    await file.writeAsString(content);
    _log('  体系概览已更新。');
  }

  // ---------------------------------------------------------------------------
  // 日志
  // ---------------------------------------------------------------------------

  void _log(String line) {
    final ts = DateTime.now();
    final hh = ts.hour.toString().padLeft(2, '0');
    final mm = ts.minute.toString().padLeft(2, '0');
    final ss = ts.second.toString().padLeft(2, '0');
    _logs.add('[$hh:$mm:$ss] $line');
    if (_logs.length > _maxLogs) {
      _logs.removeRange(0, _logs.length - _maxLogs);
    }
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
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
}
