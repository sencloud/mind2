import 'dart:convert';
import 'dart:io';

import '../model_client.dart';

/// 一条会话归档的头信息。
class ArchiveHeader {
  ArchiveHeader({
    required this.filename,
    required this.path,
    required this.name,
    required this.description,
    required this.mtimeMs,
  });

  final String filename;
  final String path;
  final String name;
  final String description;
  final int mtimeMs;
}

/// 会话归档（L4）：每次 Agent 会话结束后，用小模型提炼一条简短记录
/// （任务、关键决策、结果、涉及文件）落盘，`ARCHIVE.md` 为索引。
/// 用于长程回忆（"上次那个任务是怎么做的"），召回优先级最低。
class SessionArchive {
  SessionArchive(this.dir);

  /// 归档目录（`{appSupport}/memory/archive`）。
  final String dir;

  static const _scanHeadLines = 20;

  /// 归档条数上限：超过后删最旧的，避免无限增长。
  static const _maxEntries = 300;

  String get _indexPath => '$dir${Platform.pathSeparator}ARCHIVE.md';

  static const _distillSystem = '''
你是会话归档器。一个 AI Agent 刚结束一次任务会话，把它提炼成一条**简短**的归档记录，
供未来回忆"当时那个任务怎么做的"。控制在 200 字以内，突出：
- 任务是什么、最终结果如何（成功/失败/中止及原因）；
- 关键决策或做法（1-3 条）；
- 涉及的关键文件/命令（如有）。

只输出 JSON：
{"name":"<=12字任务短名","description":"一句话概括（任务+结果）","body":"归档正文(Markdown,<=200字)"}''';

  Future<void> ensureDir() async {
    final d = Directory(dir);
    if (!await d.exists()) await d.create(recursive: true);
  }

  /// 用小模型提炼并落盘一条归档。失败静默（归档不影响主流程）。
  Future<void> record({
    required ModelClient small,
    required String task,
    required String transcript,
    required String outcome,
  }) async {
    if (transcript.trim().isEmpty) return;
    final user = StringBuffer()
      ..writeln('【任务】')
      ..writeln(_clip(task, 800))
      ..writeln()
      ..writeln('【结果】$outcome')
      ..writeln()
      ..writeln('【执行转写】')
      ..writeln(_clip(transcript, 9000));
    final turn = await small.stream(
      messages: [
        {'role': 'system', 'content': _distillSystem},
        {'role': 'user', 'content': user.toString()},
      ],
      jsonMode: true,
    );
    Map<String, dynamic>? obj;
    try {
      final raw = turn.content;
      final start = raw.indexOf('{');
      final end = raw.lastIndexOf('}');
      if (start < 0 || end <= start) return;
      obj = jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final name = (obj['name'] ?? '').toString().trim();
    final description = (obj['description'] ?? '').toString().trim();
    final body = (obj['body'] ?? '').toString().trim();
    if (name.isEmpty || body.isEmpty) return;
    await save(name: name, description: description, body: body);
  }

  /// 直接写入一条归档（文件名带时间戳，天然唯一且可排序）。
  Future<void> save({
    required String name,
    required String description,
    required String body,
  }) async {
    await ensureDir();
    final ts = DateTime.now();
    final stamp =
        '${ts.year}${_two(ts.month)}${_two(ts.day)}-${_two(ts.hour)}${_two(ts.minute)}${_two(ts.second)}';
    // 秒级时间戳可能撞名（如计划模块并发跑多个待办同秒结束），追加序号保证唯一。
    var fname = 'session-$stamp.md';
    var n = 1;
    while (await File('$dir${Platform.pathSeparator}$fname').exists()) {
      fname = 'session-$stamp-$n.md';
      n++;
    }
    final content = StringBuffer()
      ..writeln('---')
      ..writeln('name: ${_yamlValue(name)}')
      ..writeln('description: ${_yamlValue(description)}')
      ..writeln('---')
      ..writeln()
      ..writeln(body.trim());
    await File('$dir${Platform.pathSeparator}$fname')
        .writeAsString(content.toString());
    await _prune();
    await rebuildIndex();
  }

  /// 超过上限时删除最旧的归档。
  Future<void> _prune() async {
    final headers = await scanHeaders();
    if (headers.length <= _maxEntries) return;
    for (final h in headers.sublist(_maxEntries)) {
      try {
        await File(h.path).delete();
      } catch (_) {}
    }
  }

  /// 扫描全部归档头信息（最新在前）。
  Future<List<ArchiveHeader>> scanHeaders() async {
    final d = Directory(dir);
    if (!await d.exists()) return [];
    final headers = <ArchiveHeader>[];
    await for (final entity in d.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.toLowerCase().endsWith('.md')) continue;
      if (name == 'ARCHIVE.md') continue;
      final h = await _readHeader(entity);
      if (h != null) headers.add(h);
    }
    headers.sort((a, b) => b.mtimeMs.compareTo(a.mtimeMs));
    return headers;
  }

  Future<ArchiveHeader?> _readHeader(File file) async {
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
    return ArchiveHeader(
      filename: file.uri.pathSegments.last,
      path: file.path,
      name: name,
      description: (fm['description'] ?? '').trim(),
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

  /// 读取一条归档正文。
  Future<String?> readBody(String filename) async {
    final file = File('$dir${Platform.pathSeparator}$filename');
    if (!await file.exists()) return null;
    final raw = await file.readAsString();
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

  Future<void> rebuildIndex() async {
    final headers = await scanHeaders();
    final buf = StringBuffer()
      ..writeln('# ARCHIVE')
      ..writeln('<!-- 自动生成的会话归档索引，请勿手改。 -->')
      ..writeln();
    for (final h in headers) {
      buf.writeln('- [${h.name}](${h.filename}) — ${h.description}');
    }
    await File(_indexPath).writeAsString(buf.toString());
  }

  /// 供选择器使用的清单（只取最近 [limit] 条，归档量大时控制 token）。
  String formatManifest(List<ArchiveHeader> headers, {int limit = 60}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final buf = StringBuffer();
    for (final h in headers.take(limit)) {
      final days = ((now - h.mtimeMs) / 86400000).floor();
      final age = days <= 0 ? '今天' : '$days天前';
      buf.writeln('- ${h.filename} ($age): ${h.description}');
    }
    return buf.toString().trimRight();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  String _yamlValue(String v) {
    final oneLine = v.replaceAll('\n', ' ').trim();
    if (oneLine.contains(':') || oneLine.contains('#')) {
      return '"${oneLine.replaceAll('"', r'\"')}"';
    }
    return oneLine;
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}\n…（已截断）';
}
