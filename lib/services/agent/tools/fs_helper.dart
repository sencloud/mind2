import 'dart:io';

import 'package:path/path.dart' as p;

/// 遍历工程时跳过的目录（依赖 / 构建产物 / IDE 噪声），
/// 对齐 Claude Code 所用 ripgrep 默认忽略这些目录的行为。
const ignoredWalkDirs = {
  '.git', '.hg', '.svn', 'node_modules', 'build', 'dist', 'out', 'target',
  '.dart_tool', '.idea', '.vscode', '.gradle', 'bin', 'obj', 'Pods',
  '.next', '.nuxt', 'coverage', 'venv', '.venv', 'env', '__pycache__',
  '.pub-cache', 'vendor', '.cache', '.expo', 'DerivedData',
};

/// 递归遍历 [base] 下的所有文件，自动跳过忽略目录与隐藏目录（以 . 开头）。
/// 供 grep / glob 复用，避免被 node_modules、build 等噪声淹没。
Stream<File> walkFiles(Directory base, {bool Function()? isCancelled}) async* {
  final stack = <Directory>[base];
  while (stack.isNotEmpty) {
    if (isCancelled?.call() ?? false) return;
    final dir = stack.removeLast();
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final e in entries) {
      final name = p.basename(e.path);
      if (e is Directory) {
        if (ignoredWalkDirs.contains(name) || name.startsWith('.')) continue;
        stack.add(e);
      } else if (e is File) {
        yield e;
      }
    }
  }
}

/// 把工具入参里的路径解析为绝对路径（相对路径相对工程根）。
String resolvePath(String root, String input) {
  final s = input.trim();
  if (s.isEmpty) return p.normalize(root);
  final base = p.isAbsolute(s) ? s : p.join(root, s);
  return p.normalize(base);
}

/// 判断绝对路径 [abs] 是否位于 [root] 之内（含 root 本身）。
bool isInside(String root, String abs) {
  final r = p.normalize(root);
  final a = p.normalize(abs);
  return p.equals(r, a) || p.isWithin(r, a);
}

/// glob 模式转为正则（支持 ** / * / ?），匹配以 / 统一分隔的相对路径。
RegExp globToRegExp(String pattern) {
  final norm = pattern.replaceAll('\\', '/');
  final sb = StringBuffer('^');
  for (var i = 0; i < norm.length; i++) {
    final c = norm[i];
    if (c == '*') {
      if (i + 1 < norm.length && norm[i + 1] == '*') {
        // ** 匹配任意层级（含 /）
        sb.write('.*');
        i++;
        if (i + 1 < norm.length && norm[i + 1] == '/') i++;
      } else {
        sb.write('[^/]*');
      }
    } else if (c == '?') {
      sb.write('[^/]');
    } else if ('.+()[]{}^\$|'.contains(c)) {
      sb.write('\\$c');
    } else {
      sb.write(c);
    }
  }
  sb.write(r'$');
  return RegExp(sb.toString());
}
