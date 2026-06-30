import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 共享的 LaTeX → PDF 编译工具（用 xelatex）。
/// 逻辑沿用论文模块里已验证可用的实现，独立成文件供多个模块复用。

/// 解析可用的 xelatex 命令；找不到时抛出带指引的异常。
Future<String> resolveXelatex() async {
  final result = await Process.run('xelatex', ['--version'], runInShell: true);
  if (result.exitCode != 0) {
    for (final path in _candidateXelatexPaths()) {
      if (await File(path).exists()) return path;
    }
    throw Exception(
      '未检测到 xelatex。已检查 PATH 和 MiKTeX/TeX Live 常见安装目录，'
      '请将 MiKTeX 的 miktex\\bin\\x64 目录加入 PATH 后再导出 PDF。',
    );
  }
  return 'xelatex';
}

/// 把 [tex] 源码编译成 PDF，写到 [output]。编译两遍以生成目录页码。
Future<void> compileLatexPdf({
  required String tex,
  required File output,
  required String jobName,
}) async {
  final compiler = await resolveXelatex();
  final temp = await getTemporaryDirectory();
  final buildDir = Directory(
    p.join(
      temp.path,
      'mind_latex_export_${DateTime.now().microsecondsSinceEpoch}_$jobName',
    ),
  );
  await buildDir.create(recursive: true);
  final texFile = File(p.join(buildDir.path, '$jobName.tex'));
  await texFile.writeAsString(tex);
  for (var i = 0; i < 2; i++) {
    final result = await Process.run(
      compiler,
      [
        '-interaction=nonstopmode',
        '-halt-on-error',
        '-file-line-error',
        '-output-directory',
        buildDir.path,
        texFile.path,
      ],
      workingDirectory: buildDir.path,
      runInShell: compiler == 'xelatex',
    );
    if (result.exitCode != 0) {
      final logFile = File(p.join(buildDir.path, '$jobName.log'));
      throw Exception('LaTeX 编译失败：${await _failureMessage(result, logFile)}');
    }
  }
  final built = File(p.join(buildDir.path, '$jobName.pdf'));
  if (!await built.exists()) {
    throw Exception('LaTeX 未生成 PDF：${built.path}');
  }
  await output.parent.create(recursive: true);
  await built.copy(output.path);
}

/// 在系统文件管理器中打开目录（失败不影响导出结果）。
Future<void> openExportDirectory(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [path]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [path]);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [path]);
    }
  } catch (_) {
    // 打开目录失败不影响 PDF 导出结果。
  }
}

Future<String> _failureMessage(ProcessResult result, File logFile) async {
  final log = await logFile.exists() ? await logFile.readAsString() : '';
  final source = log.trim().isEmpty
      ? '${result.stdout}\n${result.stderr}'
      : log;
  final lines = source.split(RegExp(r'\r?\n'));
  final interesting = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final isError =
        line.startsWith('!') ||
        RegExp(r'\.tex:\d+:').hasMatch(line) ||
        RegExp(r'^l\.\d+').hasMatch(line) ||
        line.contains('Undefined control sequence') ||
        line.contains('LaTeX Error') ||
        line.contains('Fatal error') ||
        line.contains('Emergency stop');
    if (!isError) continue;
    final start = i - 1 < 0 ? 0 : i - 1;
    final end = i + 4 > lines.length ? lines.length : i + 4;
    interesting.add(lines.sublist(start, end).join('\n'));
    if (interesting.length >= 3) break;
  }
  final message = interesting.isEmpty ? source : interesting.join('\n\n');
  return message.length <= 1800 ? message : message.substring(0, 1800);
}

List<String> _candidateXelatexPaths() {
  final env = Platform.environment;
  return <String>[
    if ((env['LOCALAPPDATA'] ?? '').isNotEmpty)
      p.join(env['LOCALAPPDATA']!, 'Programs', 'MiKTeX', 'miktex', 'bin', 'x64',
          'xelatex.exe'),
    if ((env['LOCALAPPDATA'] ?? '').isNotEmpty)
      p.join(env['LOCALAPPDATA']!, 'Programs', 'MiKTeX 2.9', 'miktex', 'bin',
          'x64', 'xelatex.exe'),
    if ((env['ProgramFiles'] ?? '').isNotEmpty)
      p.join(env['ProgramFiles']!, 'MiKTeX', 'miktex', 'bin', 'x64',
          'xelatex.exe'),
    if ((env['ProgramFiles'] ?? '').isNotEmpty)
      p.join(env['ProgramFiles']!, 'MiKTeX 2.9', 'miktex', 'bin', 'x64',
          'xelatex.exe'),
    if ((env['ProgramFiles(x86)'] ?? '').isNotEmpty)
      p.join(env['ProgramFiles(x86)']!, 'MiKTeX', 'miktex', 'bin',
          'xelatex.exe'),
    for (final year in ['2026', '2025', '2024'])
      p.join('C:\\', 'texlive', year, 'bin', 'windows', 'xelatex.exe'),
  ];
}
