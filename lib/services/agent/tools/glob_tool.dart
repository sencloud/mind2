import 'dart:io';

import 'package:path/path.dart' as p;

import '../tool.dart';
import 'fs_helper.dart';

/// 按 glob 模式查找文件。
class GlobTool extends AgentTool {
  static const _limit = 200;

  @override
  String get name => 'glob';

  @override
  String get description =>
      '按 glob 模式查找文件，返回匹配的相对路径列表。支持 ** / * / ?。'
      '例如 "**/*.py"、"src/*.dart"。path 为搜索起点目录，默认工程根。';

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'pattern': {'type': 'string', 'description': 'glob 模式，如 **/*.py'},
          'path': {'type': 'string', 'description': '搜索起点目录，默认工程根'},
        },
        'required': ['pattern'],
      };

  @override
  String describeCall(Map<String, dynamic> input) => 'glob ${input['pattern']}';

  @override
  Future<ToolResult> call(Map<String, dynamic> input, ToolContext ctx) async {
    final base =
        resolvePath(ctx.root, (input['path'] ?? '').toString());
    final dir = Directory(base);
    if (!await dir.exists()) return ToolResult.error('目录不存在：$base');
    final re = globToRegExp(input['pattern'].toString());
    final matches = <String>[];
    var truncated = false;
    try {
      await for (final e in walkFiles(dir, isCancelled: ctx.isCancelled)) {
        if (ctx.isCancelled()) break;
        final rel = p.relative(e.path, from: base).replaceAll('\\', '/');
        if (re.hasMatch(rel)) {
          matches.add(rel);
          if (matches.length >= _limit) {
            truncated = true;
            break;
          }
        }
      }
    } catch (e) {
      return ToolResult.error('查找失败：$e');
    }
    if (matches.isEmpty) return ToolResult('未找到匹配文件。');
    final more = truncated ? '\n…（结果超过 $_limit 条已截断）' : '';
    return ToolResult('${matches.join('\n')}$more');
  }
}
