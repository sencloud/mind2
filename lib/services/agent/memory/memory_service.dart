import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../model_client.dart';
import '../../settings_service.dart';
import 'memory_extractor.dart';
import 'memory_injector.dart';
import 'memory_selector.dart';
import 'memory_store.dart';
import 'memory_types.dart';

/// 一次回忆的结果：要注入会话的文本，以及本次浮现的记忆路径（用于去重）。
class MemoryRecall {
  MemoryRecall({required this.injection, required this.surfacedPaths});

  final String injection;
  final Set<String> surfacedPaths;

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

  MemoryStore? _global;
  String _baseDir = '';

  Future<void> init() async {
    final base = await getApplicationSupportDirectory();
    _baseDir = base.path;
    _global = MemoryStore('${base.path}${Platform.pathSeparator}memory');
    await _global!.ensureDir();
  }

  /// 全局库（关于用户本人）。
  MemoryStore get global => _global!;

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
}
