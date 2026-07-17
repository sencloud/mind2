import 'dart:io';

import 'package:path/path.dart' as p;

import '../tool.dart';
import 'fs_helper.dart';

/// 在文件内容中按正则搜索（纯 Dart 实现，不依赖外部 ripgrep）。
class GrepTool extends AgentTool {
  static const _limit = 200;

  @override
  String get name => 'grep';

  @override
  String get description =>
      '在工程文件内容中按正则搜索。output_mode：content（匹配行，默认）、'
      'files_with_matches（只列文件）、count（每文件计数）。'
      'glob 可限定文件，如 "*.py"；path 为搜索目录，默认工程根。';

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'pattern': {'type': 'string', 'description': '正则表达式'},
          'path': {'type': 'string', 'description': '搜索目录，默认工程根'},
          'glob': {'type': 'string', 'description': '限定文件的 glob，如 *.py'},
          'output_mode': {
            'type': 'string',
            'enum': ['content', 'files_with_matches', 'count'],
            'description': '输出模式，默认 content',
          },
          'ignore_case': {'type': 'boolean', 'description': '忽略大小写，默认 false'},
        },
        'required': ['pattern'],
      };

  @override
  String describeCall(Map<String, dynamic> input) => 'grep ${input['pattern']}';

  @override
  Future<ToolResult> call(Map<String, dynamic> input, ToolContext ctx) async {
    final base = resolvePath(ctx.root, (input['path'] ?? '').toString());
    final dir = Directory(base);
    if (!await dir.exists()) return ToolResult.error('目录不存在：$base');
    RegExp re;
    try {
      re = RegExp(input['pattern'].toString(),
          caseSensitive: input['ignore_case'] != true);
    } catch (e) {
      return ToolResult.error('无效正则：$e');
    }
    final fileGlob = (input['glob'] ?? '').toString().trim();
    final fileRe = fileGlob.isEmpty ? null : globToRegExp(fileGlob);
    final mode = (input['output_mode'] ?? 'content').toString();

    final contentLines = <String>[];
    final fileHits = <String, int>{};
    var truncated = false;

    try {
      await for (final e in walkFiles(
        dir,
        isCancelled: ctx.isCancelled,
        ignoreRoot: Directory(ctx.root),
      )) {
        if (ctx.isCancelled()) break;
        final rel = p.relative(e.path, from: base).replaceAll('\\', '/');
        if (fileRe != null && !fileRe.hasMatch(p.basename(rel))) continue;
        String text;
        try {
          text = await e.readAsString();
        } catch (_) {
          continue; // 跳过二进制
        }
        final lines = text.split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (!re.hasMatch(lines[i])) continue;
          fileHits[rel] = (fileHits[rel] ?? 0) + 1;
          if (mode == 'content') {
            contentLines.add('$rel:${i + 1}:${lines[i]}');
            if (contentLines.length >= _limit) {
              truncated = true;
              break;
            }
          }
        }
        if (truncated) break;
      }
    } catch (e) {
      return ToolResult.error('搜索失败：$e');
    }

    if (fileHits.isEmpty) return ToolResult('无匹配。');
    final more = truncated ? '\n…（结果已截断）' : '';
    switch (mode) {
      case 'files_with_matches':
        return ToolResult(fileHits.keys.join('\n'));
      case 'count':
        return ToolResult(
            fileHits.entries.map((e) => '${e.value}\t${e.key}').join('\n'));
      default:
        return ToolResult('${contentLines.join('\n')}$more');
    }
  }
}
