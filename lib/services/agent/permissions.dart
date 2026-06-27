import 'tool.dart';
import 'tools/bash_tool.dart';
import 'tools/fs_helper.dart';

/// 权限判定结果。
class PermissionResult {
  PermissionResult.allow()
      : allowed = true,
        reason = '';
  PermissionResult.deny(this.reason) : allowed = false;

  final bool allowed;
  final String reason;
}

/// 权限策略：把读写限定在工程目录内，并拦截灾难性命令。全程无人值守自动放行其余操作。
class Permissions {
  Permissions(this.root);

  final String root;

  /// 明显具有破坏性的系统级命令模式（best-effort）。
  static final List<RegExp> _dangerous = [
    RegExp(r'\brm\s+(-[a-z]*\s+)*(-[rf]{1,2})\s+(/|~|/\*|\$HOME)(\s|$)'),
    RegExp(r'\brm\s+-[a-z]*r[a-z]*f|\brm\s+-[a-z]*f[a-z]*r', caseSensitive: false),
    RegExp(r'\bmkfs\b', caseSensitive: false),
    RegExp(r'\bdd\s+if='),
    RegExp(r'>\s*/dev/sd[a-z]'),
    RegExp(r':\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:'), // fork bomb
    RegExp(r'\bformat\s+[a-zA-Z]:', caseSensitive: false),
    RegExp(r'\b(shutdown|reboot)\b', caseSensitive: false),
    RegExp(r'\bdel\s+/[a-z]*\s+[a-zA-Z]:\\', caseSensitive: false),
    RegExp(r'\br(d|mdir)\s+/s', caseSensitive: false),
    RegExp(r'\bdiskpart\b', caseSensitive: false),
  ];

  PermissionResult check(AgentTool tool, Map<String, dynamic> input) {
    if (tool is BashTool) {
      final cmd = (input['command'] ?? '').toString();
      for (final re in _dangerous) {
        if (re.hasMatch(cmd)) {
          return PermissionResult.deny('该命令被安全策略拦截（疑似破坏性系统操作）：$cmd');
        }
      }
      return PermissionResult.allow();
    }

    // 文件类工具：所有受影响路径必须在工程目录内。
    for (final raw in tool.affectedPaths(input)) {
      if (raw.trim().isEmpty) continue;
      final abs = resolvePath(root, raw);
      if (!isInside(root, abs)) {
        return PermissionResult.deny('禁止访问工程目录之外的路径：$abs');
      }
    }
    return PermissionResult.allow();
  }
}
