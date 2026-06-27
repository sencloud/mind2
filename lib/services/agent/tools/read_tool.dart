import 'dart:io';

import '../tool.dart';
import 'fs_helper.dart';

/// 读取文本文件内容（带行号），支持 offset/limit 分段。
class ReadTool extends AgentTool {
  @override
  String get name => 'read_file';

  @override
  String get description =>
      '读取工程内某个文本文件的内容，返回带行号的文本。可用 offset/limit 读取大文件的某一段。'
      'file_path 可为相对工程根的路径或绝对路径。';

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'file_path': {'type': 'string', 'description': '要读取的文件路径'},
          'offset': {'type': 'integer', 'description': '起始行（从 1 开始），可选'},
          'limit': {'type': 'integer', 'description': '最多读取的行数，可选'},
        },
        'required': ['file_path'],
      };

  @override
  List<String> affectedPaths(Map<String, dynamic> input) =>
      [input['file_path']?.toString() ?? ''];

  @override
  String describeCall(Map<String, dynamic> input) => '读取 ${input['file_path']}';

  @override
  Future<ToolResult> call(Map<String, dynamic> input, ToolContext ctx) async {
    final path = resolvePath(ctx.root, input['file_path'].toString());
    final file = File(path);
    if (!await file.exists()) {
      return ToolResult.error('文件不存在：$path');
    }
    String text;
    try {
      text = await file.readAsString();
    } catch (e) {
      return ToolResult.error('无法以文本读取（可能为二进制）：$e');
    }
    final lines = text.split('\n');
    final offset = (input['offset'] as num?)?.toInt() ?? 1;
    final limit = (input['limit'] as num?)?.toInt() ?? lines.length;
    final start = (offset - 1).clamp(0, lines.length);
    final end = (start + limit).clamp(0, lines.length);
    final sb = StringBuffer();
    for (var i = start; i < end; i++) {
      sb.writeln('${(i + 1).toString().padLeft(6)}|${lines[i]}');
    }
    if (sb.isEmpty) return ToolResult('（文件为空或所选区间无内容）');
    final more = end < lines.length ? '\n…（还有 ${lines.length - end} 行未显示）' : '';
    return ToolResult(sb.toString() + more);
  }
}
