import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../tool.dart';

/// 在工程目录下执行 shell 命令，捕获 stdout/stderr。
class BashTool extends AgentTool {
  @override
  String get name => 'bash';

  @override
  String get description =>
      '在工程根目录下执行 shell 命令（Windows 用 cmd，其它平台用 bash）。'
      '用于安装依赖、运行脚本、跑测试等。命令的工作目录固定为工程根目录。'
      '默认超时 180 秒，可用 timeout 覆盖（毫秒）。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'command': {'type': 'string', 'description': '要执行的命令'},
          'timeout': {'type': 'integer', 'description': '超时毫秒，默认 180000'},
          'description': {'type': 'string', 'description': '该命令用途的一句话说明'},
        },
        'required': ['command'],
      };

  @override
  String? validate(Map<String, dynamic> input) {
    final cmd = input['command'];
    if (cmd is! String || cmd.trim().isEmpty) return 'command 不能为空';
    return null;
  }

  @override
  String describeCall(Map<String, dynamic> input) =>
      '执行：${input['command']}';

  @override
  Future<ToolResult> call(Map<String, dynamic> input, ToolContext ctx) async {
    final command = input['command'].toString();
    final timeoutMs = (input['timeout'] as num?)?.toInt() ?? 180000;

    final List<String> exec;
    if (Platform.isWindows) {
      exec = ['cmd', '/c', command];
    } else {
      exec = ['bash', '-lc', command];
    }

    Process proc;
    try {
      proc = await Process.start(
        exec.first,
        exec.sublist(1),
        workingDirectory: ctx.root,
        runInShell: false,
      );
    } catch (e) {
      return ToolResult.error('无法启动命令：$e');
    }

    final out = StringBuffer();
    const decoder = Utf8Decoder(allowMalformed: true);
    final stdoutDone =
        proc.stdout.transform(decoder).forEach(out.write);
    final stderrDone =
        proc.stderr.transform(decoder).forEach(out.write);

    var killed = false;
    var timedOut = false;
    final timeoutTimer = Timer(Duration(milliseconds: timeoutMs), () {
      timedOut = true;
      proc.kill(ProcessSignal.sigkill);
    });
    final cancelPoll = Timer.periodic(const Duration(milliseconds: 300), (t) {
      if (ctx.isCancelled()) {
        killed = true;
        proc.kill(ProcessSignal.sigkill);
        t.cancel();
      }
    });

    final code = await proc.exitCode;
    timeoutTimer.cancel();
    cancelPoll.cancel();
    await stdoutDone;
    await stderrDone;

    var text = out.toString();
    const maxChars = 24000;
    if (text.length > maxChars) {
      final head = text.substring(0, maxChars ~/ 2);
      final tail = text.substring(text.length - maxChars ~/ 2);
      text = '$head\n…（输出过长已截断）…\n$tail';
    }

    if (killed) {
      return ToolResult.error('命令被用户取消。\n$text');
    }
    if (timedOut) {
      return ToolResult.error('命令超时（${timeoutMs}ms）已终止。\n$text');
    }
    final status = code == 0 ? '退出码 0（成功）' : '退出码 $code（失败）';
    final result = '$status\n$text';
    return ToolResult(result, isError: code != 0);
  }
}
