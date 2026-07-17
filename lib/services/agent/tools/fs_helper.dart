import 'dart:io';

import 'package:path/path.dart' as p;

import '../../gitignore.dart';

/// 遍历工程时跳过的目录（依赖 / 构建产物 / IDE 噪声），
/// 对齐 Claude Code 所用 ripgrep 默认忽略这些目录的行为。
const ignoredWalkDirs = {
  '.git', '.hg', '.svn', 'node_modules', 'build', 'dist', 'out', 'target',
  '.dart_tool', '.idea', '.vscode', '.gradle', 'bin', 'obj', 'Pods',
  '.next', '.nuxt', 'coverage', 'venv', '.venv', 'env', '__pycache__',
  '.pub-cache', 'vendor', '.cache', '.expo', 'DerivedData',
};

/// 递归遍历 [base] 下的所有文件，跳过忽略目录，并尊重工程根的 `.gitignore`。
///
/// [ignoreRoot] 为解析 `.gitignore` 的工程根，默认与 [base] 相同；
/// 当从子目录开始搜索时应传入真正的工程根，以便规则路径正确。
Stream<File> walkFiles(
  Directory base, {
  bool Function()? isCancelled,
  Directory? ignoreRoot,
}) async* {
  final root = ignoreRoot ?? base;
  final rootPath = p.normalize(root.path);
  final startRel = _relOf(base.path, rootPath);
  final startGi = _loadIgnoreChain(root, startRel);

  final stack = <({Directory dir, String rel, GitIgnoreMatcher gi})>[
    (dir: base, rel: startRel, gi: startGi),
  ];

  while (stack.isNotEmpty) {
    if (isCancelled?.call() ?? false) return;
    final cur = stack.removeLast();
    // startGi 已含当前目录及祖先的规则；子目录再 descend 叠加
    final localGi = cur.gi;

    List<FileSystemEntity> entries;
    try {
      entries = cur.dir.listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final e in entries) {
      final name = p.basename(e.path);
      final rel = cur.rel.isEmpty ? name : '${cur.rel}/$name';
      if (e is Directory) {
        if (ignoredWalkDirs.contains(name)) continue;
        if (localGi.isIgnored(rel, isDir: true)) continue;
        stack.add((dir: e, rel: rel, gi: localGi.descend(e, rel)));
      } else if (e is File) {
        if (localGi.isIgnored(rel, isDir: false)) continue;
        yield e;
      }
    }
  }
}

String _relOf(String abs, String rootPath) {
  final n = p.normalize(abs);
  if (p.equals(n, rootPath)) return '';
  return p.relative(n, from: rootPath).replaceAll('\\', '/');
}

/// 加载工程根到 [relDir] 路径上所有 `.gitignore`（含根与自身）。
GitIgnoreMatcher _loadIgnoreChain(Directory root, String relDir) {
  var gi = GitIgnoreMatcher.load(root);
  if (relDir.isEmpty) return gi;
  final parts = relDir.split('/');
  var acc = '';
  for (final part in parts) {
    acc = acc.isEmpty ? part : '$acc/$part';
    gi = gi.descend(Directory(p.join(root.path, p.joinAll(acc.split('/')))), acc);
  }
  return gi;
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
