import 'dart:convert';
import 'dart:io';

import 'memory_types.dart';

/// 一条记忆的「头信息」：从文件前若干行的 frontmatter 解析得到，不含正文。
/// 对应 Claude Code 的 memoryScan：只读文件头，避免把全文载入。
class MemoryHeader {
  MemoryHeader({
    required this.filename,
    required this.path,
    required this.name,
    required this.description,
    required this.type,
    required this.mtimeMs,
  });

  final String filename;
  final String path;
  final String name;
  final String description;
  final MemoryType type;

  /// 文件最后修改时间（毫秒），用于时间感知与排序。
  final int mtimeMs;
}

/// 结构化文件记忆库：每条记忆一个 `.md`（frontmatter + 正文），
/// `MEMORY.md` 为一行一条的索引（由文件头派生、写入时重建）。
///
/// 同一进程会有两个实例：全局库（`{appSupport}/memory`）与项目库
/// （`{appSupport}/project_data/{key}/memory`）。
class MemoryStore {
  MemoryStore(this.dir);

  /// 记忆目录（不含末尾分隔符）。
  final String dir;

  /// 索引读入 prompt 时的双截断上限（移植 memdir.ts 的 truncateEntrypointContent）。
  static const _maxIndexLines = 200;
  static const _maxIndexBytes = 25000;

  /// 文件头扫描时只读取前若干行（frontmatter 一定在最前面）。
  static const _scanHeadLines = 30;

  String get _indexPath => '$dir${Platform.pathSeparator}MEMORY.md';

  Future<void> ensureDir() async {
    final d = Directory(dir);
    if (!await d.exists()) await d.create(recursive: true);
  }

  /// 扫描目录下所有记忆文件的头信息，按 mtime 倒序（最新在前）。
  Future<List<MemoryHeader>> scanHeaders() async {
    final d = Directory(dir);
    if (!await d.exists()) return [];
    final headers = <MemoryHeader>[];
    await for (final entity in d.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.toLowerCase().endsWith('.md')) continue;
      if (name == 'MEMORY.md') continue;
      final header = await _readHeader(entity);
      if (header != null) headers.add(header);
    }
    headers.sort((a, b) => b.mtimeMs.compareTo(a.mtimeMs));
    return headers;
  }

  Future<MemoryHeader?> _readHeader(File file) async {
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
    final type = parseMemoryType(fm['type']);
    if (type == null) return null;
    final filename = file.uri.pathSegments.last;
    final stat = await file.stat();
    return MemoryHeader(
      filename: filename,
      path: file.path,
      name: (fm['name'] ?? filename).trim(),
      description: (fm['description'] ?? '').trim(),
      type: type,
      mtimeMs: stat.modified.millisecondsSinceEpoch,
    );
  }

  /// 解析 `---` 包裹的 YAML 风格 frontmatter（仅 key: value 单行）。
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

  /// 读取一条记忆的完整正文（含 frontmatter 之后的内容）。返回 null 表示不存在。
  Future<String?> readBody(String filename) async {
    final file = File('$dir${Platform.pathSeparator}$filename');
    if (!await file.exists()) return null;
    final raw = await file.readAsString();
    return _stripFrontmatter(raw);
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

  /// 写入/更新一条记忆。[filename] 为空时按 [name] 生成安全文件名。
  /// 写完后重建 `MEMORY.md` 索引。返回写入的文件名。
  Future<String> save({
    required String name,
    required String description,
    required MemoryType type,
    required String body,
    String? filename,
  }) async {
    await ensureDir();
    final fname = (filename != null && filename.trim().isNotEmpty)
        ? _ensureMdName(filename.trim())
        : await _uniqueName(name);
    final content = StringBuffer()
      ..writeln('---')
      ..writeln('name: ${_yamlValue(name)}')
      ..writeln('description: ${_yamlValue(description)}')
      ..writeln('type: ${type.id}')
      ..writeln('---')
      ..writeln()
      ..writeln(body.trim());
    await File('$dir${Platform.pathSeparator}$fname')
        .writeAsString(content.toString());
    await rebuildIndex();
    return fname;
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
    if (slug.isEmpty) slug = 'memory';
    if (slug.length > 40) slug = slug.substring(0, 40);
    var candidate = '$slug.md';
    var n = 1;
    while (await File('$dir${Platform.pathSeparator}$candidate').exists()) {
      candidate = '$slug-$n.md';
      n++;
    }
    return candidate;
  }

  /// 由当前所有记忆文件头重建 `MEMORY.md` 索引（一行一条）。
  Future<void> rebuildIndex() async {
    final headers = await scanHeaders();
    final buf = StringBuffer()
      ..writeln('# MEMORY')
      ..writeln('<!-- 自动生成的记忆索引：一行一条，正文按需加载，请勿手改。 -->')
      ..writeln();
    for (final h in headers) {
      buf.writeln(indexLine(h));
    }
    await File(_indexPath).writeAsString(buf.toString());
  }

  /// 单条索引行：`- [type] [name](file) — 描述`。
  String indexLine(MemoryHeader h) {
    final desc = h.description.isEmpty ? '' : ' — ${h.description}';
    return '- [${h.type.id}] [${h.name}](${h.filename})$desc';
  }

  /// 供选择器使用的清单：`- [type] file (N天前): 描述`。
  String formatManifest(List<MemoryHeader> headers) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final buf = StringBuffer();
    for (final h in headers) {
      final days = ((now - h.mtimeMs) / 86400000).floor();
      final age = days <= 0 ? '今天' : '$days天前';
      buf.writeln('- [${h.type.id}] ${h.filename} ($age): ${h.description}');
    }
    return buf.toString().trimRight();
  }

  /// 读出索引正文并按「行 + 字节」双截断，附超限警告（进 system prompt 用）。
  Future<String> indexForPrompt() async {
    final headers = await scanHeaders();
    if (headers.isEmpty) return '';
    final lines = headers.map(indexLine).toList();
    return _truncate(lines);
  }

  String _truncate(List<String> lines) {
    final notes = <String>[];
    var kept = lines;
    if (kept.length > _maxIndexLines) {
      kept = kept.sublist(0, _maxIndexLines);
      notes.add(
          '（记忆条目超过 $_maxIndexLines 行，已截断，仅显示最新的部分）');
    }
    var text = kept.join('\n');
    if (utf8.encode(text).length > _maxIndexBytes) {
      while (kept.isNotEmpty &&
          utf8.encode(kept.join('\n')).length > _maxIndexBytes) {
        kept.removeLast();
      }
      text = kept.join('\n');
      notes.add('（记忆索引超过 $_maxIndexBytes 字节，已截断）');
    }
    if (notes.isNotEmpty) {
      text = '$text\n${notes.join('\n')}';
    }
    return text;
  }
}
