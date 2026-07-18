import 'dart:convert';
import 'dart:io';

import '../../ripgrep.dart';
import '../tool.dart';
import 'fs_helper.dart';

/// 在文件内容中按正则搜索（基于捆绑的 ripgrep，原生遵守 .gitignore、跳过二进制）。
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
    if (!await Directory(base).exists()) {
      return ToolResult.error('目录不存在：$base');
    }
    final pattern = input['pattern'].toString();
    final mode = (input['output_mode'] ?? 'content').toString();
    final glob = (input['glob'] ?? '').toString().trim();
    final ignoreCase = input['ignore_case'] == true;

    final args = <String>[
      '--color', 'never',
      '--path-separator', '/',
      ...Ripgrep.noiseExcludeArgs(),
      if (ignoreCase) '-i',
      if (glob.isNotEmpty) ...['-g', glob],
      switch (mode) {
        'files_with_matches' => '-l',
        'count' => '-c',
        _ => '-n',
      },
      if (mode == 'content') '--no-heading',
      '-e', pattern,
      '.',
    ];

    ProcessResult result;
    try {
      result = await Ripgrep.instance.run(args, workingDirectory: base);
    } catch (e) {
      return ToolResult.error('搜索失败：$e');
    }
    if (ctx.isCancelled()) return ToolResult('已取消。');
    // rg：0 有匹配、1 无匹配、>1 出错。
    if (result.exitCode == 1) return ToolResult('无匹配。');
    if (result.exitCode > 1) {
      return ToolResult.error('搜索失败：${result.stderr.toString().trim()}');
    }

    final lines = const LineSplitter()
        .convert(result.stdout.toString())
        .where((l) => l.trim().isNotEmpty)
        .map(_stripDotPrefix)
        .toList();
    if (lines.isEmpty) return ToolResult('无匹配。');

    switch (mode) {
      case 'files_with_matches':
        final shown = lines.take(_limit).toList();
        final more = lines.length > _limit ? '\n…（结果已截断）' : '';
        return ToolResult('${shown.join('\n')}$more');
      case 'count':
        // rg 输出 path:count，转成 count\tpath 与旧格式一致。
        final rows = lines.map((l) {
          final idx = l.lastIndexOf(':');
          if (idx <= 0) return l;
          return '${l.substring(idx + 1)}\t${l.substring(0, idx)}';
        });
        return ToolResult(rows.join('\n'));
      default:
        final shown = lines.take(_limit).toList();
        final more = lines.length > _limit ? '\n…（结果已截断）' : '';
        return ToolResult('${shown.join('\n')}$more');
    }
  }

  /// rg 以 `.` 为搜索根时会给路径加 `./` 前缀，去掉它。
  /// 注意：只裁剪行首前缀，绝不改动匹配到的代码内容（内容里可能含反斜杠/冒号）。
  static String _stripDotPrefix(String line) =>
      line.startsWith('./') ? line.substring(2) : line;
}
