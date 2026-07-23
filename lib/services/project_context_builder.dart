import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../util/text_util.dart';
import 'agent/model_client.dart';
import 'agent/tools/fs_helper.dart';
import 'code_index_service.dart';
import 'project_doc_store.dart';
import 'ripgrep.dart';
import 'settings_service.dart';

/// 为「主题研究挂接工程」构建两类上下文：
/// - [buildPack]：研究启动前的工程上下文包（目录结构 + README + 已生成文档 + 主题相关源码摘录），
///   注入研究规划与报告综合，让检索服务于改进/对照这些工程；
/// - [contrastAgainstProjects]：外部深研之后的「对照工程」轮——用大模型据研究角度与外部线索
///   规划本地检索意图，在工程内 grep 回读代码，再归纳出「现状能力/差距/可借鉴点/建议改动面」。
///
/// 全程只读工程文件，不修改，也不改变 `ProjectService.current`。
class ProjectContextBuilder {
  ProjectContextBuilder(this.settings);

  final SettingsService settings;

  final ProjectDocStore _docStore = ProjectDocStore();
  bool _docStoreReady = false;

  static const _readmeNames = [
    'README.md', 'readme.md', 'Readme.md', 'README', 'README.txt',
    'readme.txt', 'README.rst',
  ];
  static const _maxTopicFilesPerProject = 6;
  static const _perFileClip = 2200;
  static const _readmeClip = 3000;
  static const _docClip = 4000;
  static const _maxNameCandidates = 60;
  static const _maxContentScans = 200;
  static const _maxFileBytesToRead = 160 * 1024;

  // 对照工程轮的检索规模上限。
  static const _maxIntents = 12;
  static const _maxHitsPerProject = 60;
  static const _stopwords = {
    '研究', '方案', '设计', '实现', '系统', '方法', '技术', '如何', '一个', '进行',
    'the', 'and', 'for', 'with', 'how', 'what', 'design', 'system', 'method',
    'using', 'based', 'a', 'an', 'of', 'to', 'in', 'on',
  };

  Future<void> _ensureDocStore() async {
    if (_docStoreReady) return;
    await _docStore.init();
    _docStoreReady = true;
  }

  // ---------------- 上下文包 ----------------

  Future<String> buildPack(
    List<String> paths,
    String topic, {
    void Function(String line)? log,
  }) async {
    if (paths.isEmpty) return '';
    await _ensureDocStore();
    final buf = StringBuffer();
    for (final path in paths) {
      final dir = Directory(path);
      if (!dir.existsSync()) continue;
      final name = p.basename(path);
      log?.call('  读取工程「$name」结构、文档与相关源码…');
      buf
        ..writeln('### 工程：$name')
        ..writeln('路径：$path');

      try {
        final rg = await Ripgrep.instance.exePath();
        final overview = await compute(CodeIndexService.overviewFor, (path, rg));
        if (overview.trim().isNotEmpty) {
          buf
            ..writeln('【目录结构】')
            ..writeln(overview.trim());
        }
      } catch (_) {}

      final readme = _readReadme(dir);
      if (readme != null && readme.trim().isNotEmpty) {
        buf
          ..writeln('【README 摘录】')
          ..writeln(_clip(readme, _readmeClip));
      }

      try {
        final rec = await _docStore.load(path);
        final doc = rec.overviewMarkdown.trim().isNotEmpty
            ? rec.overviewMarkdown
            : rec.analysis;
        if (doc.trim().isNotEmpty) {
          buf
            ..writeln('【已生成的项目文档摘录】')
            ..writeln(_clip(doc, _docClip));
        }
      } catch (_) {}

      final excerpts = await _topicExcerpts(dir, topic);
      if (excerpts.isNotEmpty) {
        buf.writeln('【与主题相关的源码摘录】');
        for (final e in excerpts) {
          buf
            ..writeln('— ${e.$1} —')
            ..writeln(e.$2);
        }
      }
      buf.writeln();
    }
    return buf.toString().trim();
  }

  String? _readReadme(Directory dir) {
    for (final n in _readmeNames) {
      final f = File(p.join(dir.path, n));
      if (f.existsSync()) {
        try {
          return f.readAsStringSync();
        } catch (_) {}
      }
    }
    return null;
  }

  /// 按主题关键词在工程内挑选最相关的源码片段。
  /// 先用文件名命中（便宜、不读盘），再对有限文件读内容计分，控制读盘规模。
  Future<List<(String, String)>> _topicExcerpts(
    Directory dir,
    String topic,
  ) async {
    final keywords = _keywords(topic);
    if (keywords.isEmpty) return const [];

    final nameHits = <File>[];
    final others = <File>[];
    try {
      await for (final f in walkFiles(dir, ignoreRoot: dir)) {
        final rel = p.relative(f.path, from: dir.path).toLowerCase();
        final matched = keywords.any((k) => rel.contains(k));
        if (matched) {
          if (nameHits.length < _maxNameCandidates) nameHits.add(f);
        } else if (others.length < _maxContentScans) {
          others.add(f);
        }
        if (nameHits.length >= _maxNameCandidates &&
            others.length >= _maxContentScans) {
          break;
        }
      }
    } catch (_) {}

    final scored = <(double, String, String)>[];
    Future<void> consider(File f, {required bool nameHit}) async {
      String text;
      try {
        final stat = f.statSync();
        if (stat.size > _maxFileBytesToRead) return;
        text = await f.readAsString();
      } catch (_) {
        return;
      }
      final lower = text.toLowerCase();
      var contentHits = 0;
      for (final k in keywords) {
        final idx = lower.indexOf(k);
        if (idx >= 0) contentHits++;
      }
      final score = (nameHit ? 3.0 : 0.0) + contentHits.toDouble();
      if (score <= 0) return;
      final rel = p.relative(f.path, from: dir.path).replaceAll('\\', '/');
      scored.add((score, rel, _snippet(text, lower, keywords)));
    }

    for (final f in nameHits) {
      await consider(f, nameHit: true);
    }
    if (scored.length < _maxTopicFilesPerProject) {
      for (final f in others) {
        await consider(f, nameHit: false);
      }
    }

    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return [
      for (final s in scored.take(_maxTopicFilesPerProject)) (s.$2, s.$3),
    ];
  }

  /// 取关键词首次命中附近的片段；无命中则取文件开头。
  String _snippet(String text, String lower, List<String> keywords) {
    var pos = -1;
    for (final k in keywords) {
      final idx = lower.indexOf(k);
      if (idx >= 0 && (pos < 0 || idx < pos)) pos = idx;
    }
    if (pos < 0) return _clip(text, _perFileClip);
    final start = (pos - _perFileClip ~/ 3).clamp(0, text.length);
    final end = (start + _perFileClip).clamp(0, text.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < text.length ? '…' : '';
    return '$prefix${text.substring(start, end)}$suffix';
  }

  // ---------------- 对照工程轮 ----------------

  Future<String> contrastAgainstProjects(
    List<String> paths,
    String topic,
    List<String> angles,
    String externalDigest, {
    void Function(String line)? log,
  }) async {
    if (paths.isEmpty) return '';
    final buf = StringBuffer();
    for (final path in paths) {
      final dir = Directory(path);
      if (!dir.existsSync()) continue;
      final name = p.basename(path);
      String overview = '';
      try {
        final rg = await Ripgrep.instance.exePath();
        overview = await compute(CodeIndexService.overviewFor, (path, rg));
      } catch (_) {}

      log?.call('  对照工程「$name」：规划本地检索意图…');
      final intents = await _planContrastQueries(
        topic,
        angles,
        externalDigest,
        name,
        overview,
      );

      log?.call('  对照工程「$name」：在工程内检索 ${intents.length} 项…');
      final hits = await _grepIntents(dir, intents);

      log?.call('  对照工程「$name」：归纳现状、差距与可借鉴点…');
      final contrast = await _writeContrast(
        topic,
        angles,
        externalDigest,
        name,
        overview,
        hits,
      );
      buf
        ..writeln('### 工程：$name')
        ..writeln(contrast.trim())
        ..writeln();
    }
    return buf.toString().trim();
  }

  Future<List<({String pattern, String glob})>> _planContrastQueries(
    String topic,
    List<String> angles,
    String externalDigest,
    String projectName,
    String overview,
  ) async {
    final prompt =
        '''
研究主题：「$topic」
${angles.isEmpty ? '' : '调研角度：${angles.join('；')}\n'}
本地工程「$projectName」的目录结构：
$overview

外部调研中发现的关键线索（用于判断该工程还缺什么、可借鉴什么）：
${_clip(externalDigest, 2500)}

请规划 5-$_maxIntents 条“在该工程源码内检索”的意图，用于定位与研究主题相关的现有实现、缺口或可改进点。
每条给出一个正则 pattern（匹配代码内容，用于 grep）和可选的 glob（限定文件，如 *.dart，不限定则留空）。
只输出 JSON：{"queries":[{"pattern":"关键词或正则","glob":"*.dart"},{"pattern":"...","glob":""}]}''';
    try {
      final content = await ModelClient(settings, role: ModelRole.research)
          .complete(
        system: '你是资深工程分析师，只输出 JSON。',
        user: prompt,
        jsonMode: true,
      );
      final obj = _parseJsonObject(content);
      final queries = obj?['queries'];
      final out = <({String pattern, String glob})>[];
      if (queries is List) {
        for (final q in queries) {
          if (q is! Map) continue;
          final pat = (q['pattern'] as String? ?? '').trim();
          if (pat.isEmpty) continue;
          final glob = (q['glob'] as String? ?? '').trim();
          out.add((pattern: pat, glob: glob));
          if (out.length >= _maxIntents) break;
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> _grepIntents(
    Directory dir,
    List<({String pattern, String glob})> intents,
  ) async {
    if (intents.isEmpty) return const [];
    final hits = <String>[];
    for (final intent in intents) {
      if (hits.length >= _maxHitsPerProject) break;
      RegExp re;
      try {
        re = RegExp(intent.pattern, caseSensitive: false);
      } catch (_) {
        continue;
      }
      final fileRe =
          intent.glob.isEmpty ? null : globToRegExp(intent.glob);
      try {
        await for (final f in walkFiles(dir, ignoreRoot: dir)) {
          if (hits.length >= _maxHitsPerProject) break;
          final rel = p.relative(f.path, from: dir.path).replaceAll('\\', '/');
          if (fileRe != null && !fileRe.hasMatch(p.basename(rel))) continue;
          String text;
          try {
            final stat = f.statSync();
            if (stat.size > _maxFileBytesToRead) continue;
            text = await f.readAsString();
          } catch (_) {
            continue;
          }
          final lines = text.split('\n');
          for (var i = 0; i < lines.length; i++) {
            if (!re.hasMatch(lines[i])) continue;
            hits.add('$rel:${i + 1}: ${lines[i].trim()}');
            break; // 每文件每意图取首个命中即可
          }
        }
      } catch (_) {}
    }
    return hits;
  }

  Future<String> _writeContrast(
    String topic,
    List<String> angles,
    String externalDigest,
    String projectName,
    String overview,
    List<String> hits,
  ) async {
    final hitsBlock = hits.isEmpty
        ? '（未在工程内检索到明显相关的实现，可据此判断为能力缺口）'
        : hits.take(_maxHitsPerProject).join('\n');
    final prompt =
        '''
研究主题：「$topic」
${angles.isEmpty ? '' : '调研角度：${angles.join('；')}\n'}
外部调研关键线索：
${_clip(externalDigest, 2500)}

本地工程「$projectName」目录结构：
$overview

在该工程内按检索意图命中的代码位置（file:line: 内容）：
$hitsBlock

请据此对该工程做一次“对照分析”，用中文 Markdown 输出，包含四个要点（用 `-` 列表，可引用上面的相对路径/文件名，但**不得臆造**不存在的路径或功能）：
- 已有能力：与研究主题相关、工程里已经实现的部分
- 主要差距：相比外部线索/前沿方案，工程还缺什么
- 可借鉴点：外部资料中哪些设计思想可直接迁移到该工程
- 建议改动面：落地时应改动/新增的模块或文件（尽量点到具体目录/文件）

只输出该工程的对照分析正文，不要代码块包裹。''';
    try {
      return await ModelClient(settings, role: ModelRole.research).complete(
        system: '你是资深工程分析师，基于给定证据做务实的对照分析，不臆造。',
        user: prompt,
      );
    } catch (e) {
      return '（对照分析生成失败：$e）';
    }
  }

  // ---------------- 工具 ----------------

  List<String> _keywords(String topic) {
    final raw = topic
        .toLowerCase()
        .split(RegExp(r'[^0-9a-z\u4e00-\u9fa5]+'))
        .where((s) => s.isNotEmpty)
        .where((s) => !_stopwords.contains(s))
        .where((s) => s.length >= 2 || _isCjk(s))
        .toList();
    final seen = <String>{};
    final out = <String>[];
    for (final k in raw) {
      if (seen.add(k)) out.add(k);
      if (out.length >= 12) break;
    }
    return out;
  }

  bool _isCjk(String s) => RegExp(r'[\u4e00-\u9fa5]').hasMatch(s);

  String _clip(String s, int max) => clip(s, max, suffix: '…');

  Map<String, dynamic>? _parseJsonObject(String content) {
    try {
      return ModelClient.parseJsonObject(content);
    } catch (_) {
      return null;
    }
  }
}
