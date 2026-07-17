import 'dart:io';

import 'package:path/path.dart' as p;

/// 解析并匹配 `.gitignore` 规则（含嵌套），用于工程扫描与文件遍历。
///
/// 规则语义对齐 git：后写覆盖先写；`!` 否定；目录规则以 `/` 结尾；
/// 含 `/` 的模式相对该 `.gitignore` 所在目录锚定。
class GitIgnoreMatcher {
  GitIgnoreMatcher._(this._layers);

  final List<_GitIgnoreLayer> _layers;

  /// 从 [root] 加载根目录 `.gitignore`（若存在）。
  factory GitIgnoreMatcher.load(Directory root) {
    final layers = <_GitIgnoreLayer>[];
    final f = File(p.join(root.path, '.gitignore'));
    if (f.existsSync()) {
      try {
        layers.add(_GitIgnoreLayer.parse('', f.readAsStringSync()));
      } catch (_) {}
    }
    return GitIgnoreMatcher._(layers);
  }

  /// 进入 [relDir]（相对工程根、`/` 分隔、无首尾 `/`）时加载该目录的 `.gitignore`。
  /// 返回带新层的 matcher（原实例不变）。
  GitIgnoreMatcher descend(Directory absDir, String relDir) {
    final f = File(p.join(absDir.path, '.gitignore'));
    if (!f.existsSync()) return this;
    try {
      final next = List<_GitIgnoreLayer>.of(_layers)
        ..add(_GitIgnoreLayer.parse(relDir, f.readAsStringSync()));
      return GitIgnoreMatcher._(next);
    } catch (_) {
      return this;
    }
  }

  /// [relPath] 相对工程根、`/` 分隔；[isDir] 表示是否为目录。
  bool isIgnored(String relPath, {required bool isDir}) {
    if (relPath.isEmpty) return false;
    final norm = relPath.replaceAll('\\', '/');
    bool? ignored;
    for (final layer in _layers) {
      final m = layer.match(norm, isDir: isDir);
      if (m != null) ignored = m;
    }
    return ignored ?? false;
  }
}

class _GitIgnoreLayer {
  _GitIgnoreLayer(this.baseDir, this.rules);

  /// 该层 `.gitignore` 相对工程根的目录（空串表示根）。
  final String baseDir;
  final List<_GitIgnoreRule> rules;

  factory _GitIgnoreLayer.parse(String baseDir, String content) {
    final rules = <_GitIgnoreRule>[];
    for (var line in content.split('\n')) {
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      if (line.isEmpty || line.startsWith('#')) continue;
      var negate = false;
      if (line.startsWith('!')) {
        negate = true;
        line = line.substring(1);
      }
      if (line.isEmpty) continue;
      // 未转义的尾部空格忽略
      while (line.endsWith(' ') && !line.endsWith('\\ ')) {
        line = line.substring(0, line.length - 1);
      }
      line = line.replaceAll('\\ ', ' ');
      var dirOnly = false;
      if (line.endsWith('/')) {
        dirOnly = true;
        line = line.substring(0, line.length - 1);
      }
      if (line.isEmpty) continue;
      var anchored = line.contains('/');
      if (line.startsWith('/')) {
        anchored = true;
        line = line.substring(1);
      }
      rules.add(_GitIgnoreRule(
        negate: negate,
        dirOnly: dirOnly,
        anchored: anchored,
        pattern: line,
      ));
    }
    return _GitIgnoreLayer(baseDir, rules);
  }

  /// 返回 `true`/`false` 表示命中忽略/否定；`null` 表示本层未命中。
  bool? match(String relPath, {required bool isDir}) {
    final local = _relativeToBase(relPath);
    if (local == null) return null;
    bool? hit;
    for (final r in rules) {
      if (r.matches(local, isDir: isDir)) hit = !r.negate;
    }
    return hit;
  }

  /// 将工程相对路径转为相对本层 base 的路径；不在本层下则 null。
  String? _relativeToBase(String relPath) {
    if (baseDir.isEmpty) return relPath;
    if (relPath == baseDir) return '';
    final prefix = '$baseDir/';
    if (relPath.startsWith(prefix)) return relPath.substring(prefix.length);
    return null;
  }
}

class _GitIgnoreRule {
  _GitIgnoreRule({
    required this.negate,
    required this.dirOnly,
    required this.anchored,
    required this.pattern,
  }) : _re = _compile(pattern, anchored: anchored);

  final bool negate;
  final bool dirOnly;
  final bool anchored;
  final String pattern;
  final RegExp _re;

  bool matches(String localPath, {required bool isDir}) {
    if (localPath.isEmpty) return false;
    if (dirOnly && !isDir) {
      // `build/` 不直接匹配文件；遍历时父目录已被跳过。
      return false;
    }
    if (anchored) {
      return _re.hasMatch(localPath);
    }
    // 未锚定：匹配任意层级的路径段
    if (_re.hasMatch(localPath)) return true;
    final parts = localPath.split('/');
    for (var i = 0; i < parts.length; i++) {
      final suffix = parts.sublist(i).join('/');
      if (_re.hasMatch(suffix)) return true;
    }
    return false;
  }

  static RegExp _compile(String pattern, {required bool anchored}) {
    final sb = StringBuffer();
    sb.write('^');
    for (var i = 0; i < pattern.length; i++) {
      final c = pattern[i];
      if (c == '*') {
        if (i + 1 < pattern.length && pattern[i + 1] == '*') {
          i++;
          if (i + 1 < pattern.length && pattern[i + 1] == '/') {
            i++;
            sb.write('(?:.*/)?');
          } else {
            sb.write('.*');
          }
        } else {
          sb.write('[^/]*');
        }
      } else if (c == '?') {
        sb.write('[^/]');
      } else if (c == '/') {
        sb.write('/');
      } else if (r'.+()[]{}^$|\ '.contains(c)) {
        sb.write('\\$c');
      } else {
        sb.write(c);
      }
    }
    sb.write(r'$');
    return RegExp(sb.toString(), caseSensitive: !Platform.isWindows);
  }
}
