import 'dart:io';

import 'package:path/path.dart' as p;

import '../../ripgrep.dart';

/// 递归遍历 [base] 下的所有文件，遵守 `.gitignore` 并跳过隐藏/二进制/噪声目录。
///
/// 基于捆绑的 ripgrep（`rg --files`）实现：`rg` 会自当前目录向上查找 `.gitignore`
/// 与 `.git`，因此从子目录开始搜索时规则依然正确，[ignoreRoot] 仅为兼容旧签名保留。
Stream<File> walkFiles(
  Directory base, {
  bool Function()? isCancelled,
  Directory? ignoreRoot,
}) async* {
  final basePath = base.path;
  await for (final rel in Ripgrep.instance.listFiles(
    basePath,
    isCancelled: isCancelled,
  )) {
    yield File(p.join(basePath, rel));
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
