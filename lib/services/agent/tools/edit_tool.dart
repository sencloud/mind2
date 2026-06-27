import 'dart:io';

import '../tool.dart';
import 'fs_helper.dart';

/// 以字符串替换方式编辑文件。
class EditTool extends AgentTool {
  @override
  String get name => 'edit_file';

  @override
  String get description =>
      '通过精确字符串替换编辑已有文件。默认要求 old_string 在文件中唯一；'
      '若要替换全部匹配，设 replace_all=true。需保留原有缩进与空白。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'file_path': {'type': 'string', 'description': '要编辑的文件路径'},
          'old_string': {'type': 'string', 'description': '被替换的原文（含足够上下文以保证唯一）'},
          'new_string': {'type': 'string', 'description': '替换后的新文本'},
          'replace_all': {'type': 'boolean', 'description': '是否替换全部匹配，默认 false'},
        },
        'required': ['file_path', 'old_string', 'new_string'],
      };

  @override
  List<String> affectedPaths(Map<String, dynamic> input) =>
      [input['file_path']?.toString() ?? ''];

  @override
  String? validate(Map<String, dynamic> input) {
    if (input['old_string'] is! String || input['new_string'] is! String) {
      return 'old_string / new_string 必须为字符串';
    }
    if ((input['old_string'] as String) == (input['new_string'] as String)) {
      return 'old_string 与 new_string 不能相同';
    }
    return null;
  }

  @override
  String describeCall(Map<String, dynamic> input) => '编辑 ${input['file_path']}';

  @override
  Future<ToolResult> call(Map<String, dynamic> input, ToolContext ctx) async {
    final path = resolvePath(ctx.root, input['file_path'].toString());
    final file = File(path);
    if (!await file.exists()) return ToolResult.error('文件不存在：$path');
    final oldS = input['old_string'].toString();
    final newS = input['new_string'].toString();
    final replaceAll = input['replace_all'] == true;
    final text = await file.readAsString();
    final count = oldS.isEmpty ? 0 : oldS.allMatches(text).length;
    if (count == 0) {
      return ToolResult.error('未找到 old_string，无法替换。');
    }
    if (count > 1 && !replaceAll) {
      return ToolResult.error('old_string 匹配到 $count 处，请补充上下文使其唯一，或设 replace_all=true。');
    }
    final updated =
        replaceAll ? text.replaceAll(oldS, newS) : text.replaceFirst(oldS, newS);
    await file.writeAsString(updated);
    return ToolResult('已编辑：$path（替换 ${replaceAll ? count : 1} 处）');
  }
}
