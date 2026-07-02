import 'dart:convert';
import 'dart:io';

/// 一条技能（SOP）的头信息：从文件 frontmatter 解析，不含正文。
/// 对应 GenericAgent 分层记忆的 L3（Task Skills / SOPs）。
class SkillHeader {
  SkillHeader({
    required this.filename,
    required this.path,
    required this.name,
    required this.description,
    required this.hits,
    required this.mtimeMs,
  });

  final String filename;
  final String path;

  /// 技能名（短标题）。
  final String name;

  /// 一句话适用场景（选择器据此判断是否召回）。
  final String description;

  /// 命中次数（被召回并注入的次数）。
  final int hits;

  final int mtimeMs;
}

/// 技能库（L3）：每条技能一个 `.md`（frontmatter + SOP 正文），
/// `SKILLS.md` 为一行一条的索引。沿用 MemoryStore 的「文件 + 索引」模式，
/// 但独立成库：技能不是"事实记忆"，而是**可复用的执行路径**。
///
/// 设计（对照 GenericAgent）：
/// - 沉淀：任务成功后由 SkillCrystallizer 固化执行路径写入本库；
/// - 召回：任务开始前按任务描述选出最相关的 1-2 条 SOP 注入；
/// - 进化：同类任务再次沉淀时更新已有技能（update），命中数持续累积。
class SkillStore {
  SkillStore(this.dir);

  /// 技能目录（`{appSupport}/memory/skills`）。
  final String dir;

  static const _scanHeadLines = 30;

  String get _indexPath => '$dir${Platform.pathSeparator}SKILLS.md';

  Future<void> ensureDir() async {
    final d = Directory(dir);
    if (!await d.exists()) await d.create(recursive: true);
  }

  /// 扫描所有技能头信息，按命中次数降序、再按 mtime 降序。
  Future<List<SkillHeader>> scanHeaders() async {
    final d = Directory(dir);
    if (!await d.exists()) return [];
    final headers = <SkillHeader>[];
    await for (final entity in d.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.toLowerCase().endsWith('.md')) continue;
      if (name == 'SKILLS.md') continue;
      final header = await _readHeader(entity);
      if (header != null) headers.add(header);
    }
    headers.sort((a, b) {
      final byHits = b.hits.compareTo(a.hits);
      return byHits != 0 ? byHits : b.mtimeMs.compareTo(a.mtimeMs);
    });
    return headers;
  }

  Future<SkillHeader?> _readHeader(File file) async {
    final lines = <String>[];
    try {
      final stream = file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in stream) {
        lines.add(line);
        if (lines.length >= _scanHeadLines) break;
      }
    } catch (_) {
      return null;
    }
    final fm = _parseFrontmatter(lines);
    final name = (fm['name'] ?? '').trim();
    if (name.isEmpty) return null;
    final stat = await file.stat();
    return SkillHeader(
      filename: file.uri.pathSegments.last,
      path: file.path,
      name: name,
      description: (fm['description'] ?? '').trim(),
      hits: int.tryParse(fm['hits'] ?? '') ?? 0,
      mtimeMs: stat.modified.millisecondsSinceEpoch,
    );
  }

  Map<String, String> _parseFrontmatter(List<String> lines) {
    final out = <String, String>{};
    if (lines.isEmpty || lines.first.trim() != '---') return out;
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim() == '---') break;
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).trim();
      var value = line.substring(idx + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      out[key] = value;
    }
    return out;
  }

  /// 读取一条技能的 SOP 正文（去掉 frontmatter）。
  Future<String?> readBody(String filename) async {
    final file = File('$dir${Platform.pathSeparator}$filename');
    if (!await file.exists()) return null;
    return _stripFrontmatter(await file.readAsString());
  }

  String _stripFrontmatter(String raw) {
    final lines = const LineSplitter().convert(raw);
    if (lines.isEmpty || lines.first.trim() != '---') return raw.trim();
    var end = -1;
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        end = i;
        break;
      }
    }
    if (end < 0) return raw.trim();
    return lines.sublist(end + 1).join('\n').trim();
  }

  /// 写入/更新一条技能。[filename] 非空表示更新已有技能（保留其命中数）。
  /// 返回写入的文件名。
  Future<String> save({
    required String name,
    required String description,
    required String body,
    String? filename,
  }) async {
    await ensureDir();
    var hits = 0;
    String fname;
    if (filename != null && filename.trim().isNotEmpty) {
      fname = _ensureMdName(filename.trim());
      // 更新时保留旧命中数，让"常用技能"排序不被重置。
      final old = await _readHeader(File('$dir${Platform.pathSeparator}$fname'));
      hits = old?.hits ?? 0;
    } else {
      fname = await _uniqueName(name);
    }
    await _write(fname, name: name, description: description, hits: hits, body: body);
    await rebuildIndex();
    return fname;
  }

  Future<void> _write(
    String fname, {
    required String name,
    required String description,
    required int hits,
    required String body,
  }) async {
    final content = StringBuffer()
      ..writeln('---')
      ..writeln('name: ${_yamlValue(name)}')
      ..writeln('description: ${_yamlValue(description)}')
      ..writeln('hits: $hits')
      ..writeln('---')
      ..writeln()
      ..writeln(body.trim());
    await File('$dir${Platform.pathSeparator}$fname')
        .writeAsString(content.toString());
  }

  /// 记录一次命中（召回并注入后调用），hits+1。
  Future<void> recordHit(String filename) async {
    final file = File('$dir${Platform.pathSeparator}$filename');
    if (!await file.exists()) return;
    final header = await _readHeader(file);
    if (header == null) return;
    final body = _stripFrontmatter(await file.readAsString());
    await _write(
      filename,
      name: header.name,
      description: header.description,
      hits: header.hits + 1,
      body: body,
    );
    await rebuildIndex();
  }

  /// 删除一条技能并重建索引。
  Future<void> delete(String filename) async {
    final file = File('$dir${Platform.pathSeparator}$filename');
    if (await file.exists()) await file.delete();
    await rebuildIndex();
  }

  String _ensureMdName(String name) =>
      name.toLowerCase().endsWith('.md') ? name : '$name.md';

  String _yamlValue(String v) {
    final oneLine = v.replaceAll('\n', ' ').trim();
    if (oneLine.contains(':') || oneLine.contains('#')) {
      return '"${oneLine.replaceAll('"', r'\"')}"';
    }
    return oneLine;
  }

  Future<String> _uniqueName(String title) async {
    var slug = title
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\u4e00-\u9fa5]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) slug = 'skill';
    if (slug.length > 40) slug = slug.substring(0, 40);
    var candidate = '$slug.md';
    var n = 1;
    while (await File('$dir${Platform.pathSeparator}$candidate').exists()) {
      candidate = '$slug-$n.md';
      n++;
    }
    return candidate;
  }

  /// 重建 `SKILLS.md` 索引（一行一条）。
  Future<void> rebuildIndex() async {
    final headers = await scanHeaders();
    final buf = StringBuffer()
      ..writeln('# SKILLS')
      ..writeln('<!-- 自动生成的技能索引：任务成功后自动沉淀，请勿手改。 -->')
      ..writeln();
    for (final h in headers) {
      buf.writeln('- [${h.name}](${h.filename}) ×${h.hits} — ${h.description}');
    }
    await File(_indexPath).writeAsString(buf.toString());
  }

  /// 供选择器使用的清单：`- file (命中N次, M天前): 描述`。
  String formatManifest(List<SkillHeader> headers) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final buf = StringBuffer();
    for (final h in headers) {
      final days = ((now - h.mtimeMs) / 86400000).floor();
      final age = days <= 0 ? '今天' : '$days天前';
      buf.writeln('- ${h.filename} (命中${h.hits}次, $age): ${h.description}');
    }
    return buf.toString().trimRight();
  }
}
