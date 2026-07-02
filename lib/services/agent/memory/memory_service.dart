import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../model_client.dart';
import '../../settings_service.dart';
import 'memory_extractor.dart';
import 'memory_injector.dart';
import 'memory_selector.dart';
import 'memory_store.dart';
import 'memory_types.dart';
import 'session_archive.dart';
import 'skill_crystallizer.dart';
import 'skill_store.dart';

/// 一次回忆的结果：要注入会话的文本，以及本次浮现的记忆路径（用于去重）。
class MemoryRecall {
  MemoryRecall({required this.injection, required this.surfacedPaths});

  final String injection;
  final Set<String> surfacedPaths;

  bool get isEmpty => injection.trim().isEmpty;
}

/// 一次技能召回的结果：注入文本 + 命中的技能名（用于 UI 展示）。
class SkillRecall {
  SkillRecall({required this.injection, required this.names});

  final String injection;
  final List<String> names;

  bool get isEmpty => injection.trim().isEmpty;
}

/// 记忆系统的统一入口：持有全局库、小模型通道、选择器与抽取器。
///
/// - 全局库 `{appSupport}/memory`：user/feedback，跨功能（聊天/研究/项目/实验）共享。
/// - 项目库：调用方按各自数据目录传入 `projectStore(dir)`。
/// - 写入路由：user/feedback → 全局库；project/reference → 项目库。
class MemoryService {
  MemoryService(this.settings);

  final SettingsService settings;

  late final ModelClient _small = ModelClient(settings, small: true);
  late final MemorySelector _selector = MemorySelector(_small);
  late final MemoryExtractor _extractor = MemoryExtractor(_small);
  late final SkillCrystallizer _crystallizer = SkillCrystallizer(_small);

  MemoryStore? _global;
  SkillStore? _skills;
  SessionArchive? _archive;
  String _baseDir = '';

  Future<void> init() async {
    final base = await getApplicationSupportDirectory();
    _baseDir = base.path;
    final sep = Platform.pathSeparator;
    _global = MemoryStore('${base.path}${sep}memory');
    await _global!.ensureDir();
    // L3 技能库与 L4 会话归档（GenericAgent 分层记忆）。
    _skills = SkillStore('${base.path}${sep}memory${sep}skills');
    await _skills!.ensureDir();
    _archive = SessionArchive('${base.path}${sep}memory${sep}archive');
    await _archive!.ensureDir();
  }

  /// 全局库（关于用户本人）。
  MemoryStore get global => _global!;

  /// 技能库（L3：可复用执行路径 SOP）。
  SkillStore get skills => _skills!;

  /// 会话归档（L4：历史任务记录）。
  SessionArchive get archive => _archive!;

  /// 为某个数据目录创建项目库实例（不缓存，按需创建）。
  MemoryStore projectStore(String memoryDir) => MemoryStore(memoryDir);

  // ---------------------------------------------------------------------------
  // 静态指令层（CLAUDE.md/AGENTS.md 类）：全局规则 + 项目 AGENTS.md（叠加非覆盖）。
  // ---------------------------------------------------------------------------

  Future<String> staticInstructions(Directory projectDir) async {
    final buf = StringBuffer();
    final globalRules =
        File('$_baseDir${Platform.pathSeparator}AGENTS.md');
    if (await globalRules.exists()) {
      final t = (await globalRules.readAsString()).trim();
      if (t.isNotEmpty) {
        buf
          ..writeln('# 全局规则（用户级 AGENTS.md）')
          ..writeln(t)
          ..writeln();
      }
    }
    final projRules =
        File('${projectDir.path}${Platform.pathSeparator}AGENTS.md');
    if (await projRules.exists()) {
      final t = (await projRules.readAsString()).trim();
      if (t.isNotEmpty) {
        buf
          ..writeln('# 项目说明（AGENTS.md）')
          ..writeln(t)
          ..writeln();
      }
    }
    return buf.toString().trimRight();
  }

  // ---------------------------------------------------------------------------
  // 索引常驻：组装进 system prompt 的记忆索引块（全局 + 项目）。
  // ---------------------------------------------------------------------------

  Future<String> instructions({MemoryStore? project}) async {
    final g = await global.indexForPrompt();
    final p = project != null ? await project.indexForPrompt() : '';
    return MemoryPrompts.systemBlock(globalIndex: g, projectIndex: p);
  }

  // ---------------------------------------------------------------------------
  // 回忆：小模型从全局/项目索引里选 top-N，注入正文（含老化警告）。
  // ---------------------------------------------------------------------------

  Future<MemoryRecall> recall({
    required String query,
    MemoryStore? project,
    Set<String> alreadySurfaced = const {},
    List<String> recentTools = const [],
  }) async {
    final selected = <MemoryHeader>[];

    final gHeaders = await global.scanHeaders();
    if (gHeaders.isNotEmpty) {
      selected.addAll(await _selector.select(
        query: query,
        headers: gHeaders,
        manifest: global.formatManifest(gHeaders),
        alreadySurfaced: alreadySurfaced,
        recentTools: recentTools,
        maxResults: 3,
      ));
    }

    if (project != null) {
      final pHeaders = await project.scanHeaders();
      if (pHeaders.isNotEmpty) {
        selected.addAll(await _selector.select(
          query: query,
          headers: pHeaders,
          manifest: project.formatManifest(pHeaders),
          alreadySurfaced: alreadySurfaced,
          recentTools: recentTools,
          maxResults: 5,
        ));
      }
    }

    final injection = await MemoryInjector.build(selected);
    return MemoryRecall(
      injection: injection,
      surfacedPaths: selected.map((h) => h.path).toSet(),
    );
  }

  // ---------------------------------------------------------------------------
  // 写入：后台抽取并按范围路由（user/feedback→全局；project/reference→项目）。
  // ---------------------------------------------------------------------------

  /// 返回写入的记忆条数。
  Future<int> extract({
    required String transcript,
    MemoryStore? project,
  }) async {
    if (transcript.trim().isEmpty) return 0;
    final gHeaders = await global.scanHeaders();
    final pHeaders = project != null ? await project.scanHeaders() : const [];

    final items = await _extractor.extract(
      transcript: transcript,
      globalManifest: global.formatManifest(gHeaders),
      projectManifest:
          project != null ? project.formatManifest(pHeaders.cast()) : '',
    );

    var n = 0;
    for (final it in items) {
      final isGlobal = it.type.isGlobal;
      // 没有项目库时，项目类记忆无处安放，丢弃（不静默兜底到全局库）。
      if (!isGlobal && project == null) continue;
      final store = isGlobal ? global : project!;
      await store.save(
        name: it.name,
        description: it.description,
        type: it.type,
        body: it.body,
        filename: it.update,
      );
      n++;
    }
    return n;
  }

  /// 把一段已有文本直接存为一条记忆（用于"关联研究并入记忆系统"等场景）。
  Future<void> remember({
    required MemoryStore store,
    required MemoryType type,
    required String name,
    required String description,
    required String body,
  }) async {
    await store.save(
      name: name,
      description: description,
      type: type,
      body: body,
    );
  }

  // ---------------------------------------------------------------------------
  // L3 技能：召回（任务前）+ 沉淀（任务成功后）。
  // ---------------------------------------------------------------------------

  static const _skillSelectionSystem = '''
你是技能选择器。下面给你一份技能清单（每行：文件名 (命中次数, 时间): 适用场景）
和当前的任务描述。技能是过去成功完成同类任务时沉淀的 SOP（标准流程）。
只选出**适用场景确实覆盖当前任务**的技能，最多 2 条。

严苛标准：
- 不确定是否同类任务，就**不要选**。宁缺毋滥。
- 只能从清单里给出的文件名中选，不得编造。

只输出 JSON：{"files":["a.md"]}。没有适用的就返回 {"files":[]}。''';

  /// 任务开始前召回适用技能：小模型从 SKILLS.md 索引里选最多 2 条，
  /// 注入 SOP 正文并累加命中次数。
  Future<SkillRecall> recallSkills({required String query}) async {
    final headers = await skills.scanHeaders();
    if (headers.isEmpty || query.trim().isEmpty) {
      return SkillRecall(injection: '', names: const []);
    }
    final user = StringBuffer()
      ..writeln('技能清单：')
      ..writeln(skills.formatManifest(headers))
      ..writeln()
      ..writeln('当前任务：')
      ..writeln(query.trim())
      ..writeln()
      ..writeln('请选出适用的不超过 2 条，只输出 JSON。');
    List<String> chosen;
    try {
      final turn = await _small.stream(
        messages: [
          {'role': 'system', 'content': _skillSelectionSystem},
          {'role': 'user', 'content': user.toString()},
        ],
        jsonMode: true,
      );
      chosen = _parseFileList(turn.content);
    } catch (_) {
      return SkillRecall(injection: '', names: const []);
    }
    if (chosen.isEmpty) return SkillRecall(injection: '', names: const []);

    final byName = {for (final h in headers) h.filename: h};
    final buf = StringBuffer()
      ..writeln('<system-reminder>')
      ..writeln('以下是过去成功完成同类任务时沉淀的技能 SOP。'
          '优先按 SOP 执行；与现实不符时以现实为准，自行探索。')
      ..writeln();
    final names = <String>[];
    for (final f in chosen.take(2)) {
      // 模型可能省略 .md 后缀，与 MemorySelector 一致做一次兜底匹配。
      final h = byName[f] ?? byName[_ensureMd(f)];
      if (h == null) continue;
      final body = await skills.readBody(h.filename);
      if (body == null || body.trim().isEmpty) continue;
      names.add(h.name);
      buf
        ..writeln('### 技能：${h.name}（已成功复用 ${h.hits} 次）')
        ..writeln(body.trim())
        ..writeln();
      await skills.recordHit(h.filename);
    }
    buf.write('</system-reminder>');
    if (names.isEmpty) return SkillRecall(injection: '', names: const []);
    return SkillRecall(injection: buf.toString(), names: names);
  }

  /// 任务成功后沉淀技能：小模型判断执行路径是否值得固化为 SOP。
  /// 返回沉淀的技能名，null 表示本次不沉淀。
  Future<String?> crystallizeSkill({
    required String task,
    required String transcript,
  }) async {
    final headers = await skills.scanHeaders();
    final result = await _crystallizer.crystallize(
      task: task,
      transcript: transcript,
      skillsManifest: skills.formatManifest(headers),
    );
    if (result == null) return null;
    await skills.save(
      name: result.name,
      description: result.description,
      body: result.body,
      filename: result.update,
    );
    return result.name;
  }

  // ---------------------------------------------------------------------------
  // L4 会话归档：记录（任务后）+ 长程召回（L2/L3 无命中时兜底）。
  // ---------------------------------------------------------------------------

  /// 会话结束后归档一条简短记录（小模型提炼），失败静默。
  Future<void> archiveSession({
    required String task,
    required String transcript,
    required String outcome,
  }) async {
    await archive.record(
      small: _small,
      task: task,
      transcript: transcript,
      outcome: outcome,
    );
  }

  static const _archiveSelectionSystem = '''
你是归档选择器。下面给你一份历史任务归档清单（每行：文件名 (时间): 概括）
和当前的任务描述。只在当前任务**明显与某条历史任务相关**
（同一工程的延续、明确提到"上次/之前"的事）时选出它，最多 2 条。
不确定就不要选。只能从清单里选，不得编造。
只输出 JSON：{"files":["a.md"]}。没有相关的就返回 {"files":[]}。''';

  /// 长程回忆：从会话归档中选相关记录注入。返回空串表示无可注入。
  Future<String> recallArchive({required String query}) async {
    final headers = await archive.scanHeaders();
    if (headers.isEmpty || query.trim().isEmpty) return '';
    final user = StringBuffer()
      ..writeln('归档清单：')
      ..writeln(archive.formatManifest(headers))
      ..writeln()
      ..writeln('当前任务：')
      ..writeln(query.trim())
      ..writeln()
      ..writeln('请选出明显相关的不超过 2 条，只输出 JSON。');
    List<String> chosen;
    try {
      final turn = await _small.stream(
        messages: [
          {'role': 'system', 'content': _archiveSelectionSystem},
          {'role': 'user', 'content': user.toString()},
        ],
        jsonMode: true,
      );
      chosen = _parseFileList(turn.content);
    } catch (_) {
      return '';
    }
    if (chosen.isEmpty) return '';

    final byName = {for (final h in headers) h.filename: h};
    final buf = StringBuffer()
      ..writeln('<system-reminder>')
      ..writeln('以下是与当前任务可能相关的历史任务归档（仅供回忆参考）：')
      ..writeln();
    var any = false;
    for (final f in chosen.take(2)) {
      final h = byName[f] ?? byName[_ensureMd(f)];
      if (h == null) continue;
      final body = await archive.readBody(h.filename);
      if (body == null || body.trim().isEmpty) continue;
      any = true;
      buf
        ..writeln('### ${h.name}')
        ..writeln(body.trim())
        ..writeln();
    }
    buf.write('</system-reminder>');
    return any ? buf.toString() : '';
  }

  String _ensureMd(String f) => f.toLowerCase().endsWith('.md') ? f : '$f.md';

  List<String> _parseFileList(String raw) {
    try {
      final obj = jsonDecode(raw);
      if (obj is Map && obj['files'] is List) {
        return (obj['files'] as List)
            .whereType<String>()
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // 选择器无把握/解析失败时返回空，绝不臆造。
    }
    return [];
  }
}
