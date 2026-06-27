import 'dart:io';

import '../tool.dart';
import 'fs_helper.dart';

/// 创建或覆写文件（自动创建父目录）。
class WriteTool extends AgentTool {
  @override
  String get name => 'write_file';

  @override
  String get description =>
      '创建新文件或覆写已有文件的全部内容。父目录会被自动创建。'
      'file_path 可为相对工程根的路径或绝对路径。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'file_path': {'type': 'string', 'description': '目标文件路径'},
          'content': {'type': 'string', 'description': '完整文件内容'},
        },
        'required': ['file_path', 'content'],
      };

  @override
  List<String> affectedPaths(Map<String, dynamic> input) =>
      [input['file_path']?.toString() ?? ''];

  @override
  String? validate(Map<String, dynamic> input) {
    if (input['content'] is! String) return 'content 必须为字符串';
    return null;
  }

  @override
  String describeCall(Map<String, dynamic> input) => '写入 ${input['file_path']}';

  @override
  Future<ToolResult> call(Map<String, dynamic> input, ToolContext ctx) async {
    final path = resolvePath(ctx.root, input['file_path'].toString());
    final content = input['content'].toString();
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      final existed = await file.exists();
      await file.writeAsString(content);
      final action = existed ? '已覆写' : '已创建';
      return ToolResult('$action：$path（${content.length} 字符）');
    } catch (e) {
      return ToolResult.error('写入失败：$e');
    }
  }
}
