import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'gitignore.dart';
import 'ripgrep.dart';

/// 工程文件扫描服务（对齐 Claude Code 的做法：**不预建语义/向量索引**）。
///
/// 代码定位完全交给 Agent 用 grep / glob / read 按需检索（agentic search），
/// 不再做切块、向量化与相似度检索。本服务只负责两件轻量的事：
/// - 扫描工程内的代码文件清单（含 mtime），用于"本轮改动了哪些文件"的对比；
/// - 给 Agent 生成一份顶层工程概览（目录树 + 文件数）作为初始认知。
///
/// 扫描时按 `.gitignore`（含嵌套）排除，并跳过常见依赖/构建目录；不设文件数上限。
class CodeIndexService extends ChangeNotifier {
  /// 扫描与遍历时跳过的目录（依赖/构建产物/IDE 等噪声）。
  static const ignoreDirs = {
    '.git', '.hg', '.svn', 'node_modules', 'build', 'dist', 'out', 'target',
    '.dart_tool', '.idea', '.vscode', '.gradle', 'bin', 'obj', 'Pods',
    '.next', '.nuxt', 'coverage', 'venv', '.venv', 'env', '__pycache__',
    '.pub-cache', 'vendor', '.cache', '.expo', 'DerivedData',
  };

  static const _codeExts = {
    '.dart', '.py', '.js', '.jsx', '.ts', '.tsx', '.java', '.kt', '.go',
    '.rs', '.c', '.h', '.cc', '.cpp', '.hpp', '.cxx', '.cs', '.rb', '.php',
    '.swift', '.m', '.mm', '.scala', '.sh', '.bash', '.ps1', '.sql', '.r',
    '.lua', '.vue', '.svelte', '.html', '.css', '.scss', '.less',
    '.json', '.yaml', '.yml', '.toml', '.ini', '.xml', '.gradle', '.cmake',
    '.md', '.txt', '.proto', '.graphql', '.tf',
  };

  Directory? _root;
  bool scanning = false;
  int _fileCount = 0;

  /// 是否已绑定工程。
  bool get bound => _root != null;

  /// 最近一次扫描到的代码文件数。
  int get fileCount => _fileCount;

  /// 切换当前工程并扫描一次文件清单。
  Future<void> bind(Directory projectRoot) async {
    _root = projectRoot;
    _fileCount = 0;
    notifyListeners();
    await rescan();
  }

  void unbind() {
    _root = null;
    _fileCount = 0;
    scanning = false;
    notifyListeners();
  }

  /// 重新扫描工程文件。
  /// 关键：遍历放到后台 isolate（compute）执行，避免在 UI 线程做几千次
  /// listSync/statSync 阻塞导致「打开项目卡顿」。
  Future<void> rescan() async {
    final root = _root;
    if (root == null) return;
    scanning = true;
    notifyListeners();
    try {
      final rg = await Ripgrep.instance.exePath();
      _fileCount = (await compute(_scan, (root.path, rg))).length;
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  /// 扫描工程代码文件，返回 rel -> mtime(ms)，供调用方比对"本轮改动了哪些文件"。
  /// 同样在后台 isolate 执行，不阻塞 UI。
  Future<Map<String, int>> snapshotMtimes() async {
    final root = _root;
    if (root == null) return const {};
    final rg = await Ripgrep.instance.exePath();
    return compute(_scan, (root.path, rg));
  }

  /// 顶层目录树（最多两层）+ 文件统计，作为 Agent 的初始工程概览。
  String overview() => _buildOverview(_root?.path, _fileCount);

  /// 对任意工程根路径构建概览（独立于当前绑定的工程）。会现场扫描一次文件数，
  /// 供「主题研究挂接工程」等按路径读取上下文的场景复用。
  /// [msg] 为 (工程根路径, rg 可执行文件路径)，以便在后台 isolate 内执行 rg。
  static String overviewFor((String, String) msg) =>
      _buildOverview(msg.$1, _scan(msg).length);

  /// 顶层目录树（最多两层）+ 文件统计的纯函数实现。
  static String _buildOverview(String? rootPath, int fileCount) {
    if (rootPath == null) return '';
    final root = Directory(rootPath);
    final buf = StringBuffer();
    buf.writeln('工程顶层结构：');
    try {
      final entries = root.listSync(followLinks: false)
        ..sort((a, b) {
          final ad = a is Directory ? 0 : 1;
          final bd = b is Directory ? 0 : 1;
          if (ad != bd) return ad - bd;
          return p.basename(a.path).compareTo(p.basename(b.path));
        });
      var shown = 0;
      final gi = GitIgnoreMatcher.load(root);
      for (final e in entries) {
        final name = p.basename(e.path);
        if (e is Directory) {
          if (ignoreDirs.contains(name)) continue;
          if (gi.isIgnored(name, isDir: true)) continue;
          buf.writeln('  $name/');
          try {
            final sub = e.listSync(followLinks: false).take(12);
            for (final s in sub) {
              final sn = p.basename(s.path);
              final rel = '$name/$sn';
              if (s is Directory) {
                if (ignoreDirs.contains(sn)) continue;
                if (gi.isIgnored(rel, isDir: true)) continue;
              } else if (gi.isIgnored(rel, isDir: false)) {
                continue;
              }
              buf.writeln('    $sn${s is Directory ? '/' : ''}');
            }
          } catch (_) {}
        } else {
          if (gi.isIgnored(name, isDir: false)) continue;
          buf.writeln('  $name');
        }
        if (++shown >= 40) {
          buf.writeln('  …');
          break;
        }
      }
    } catch (_) {}
    if (fileCount > 0) {
      buf.writeln('\n工程共约 $fileCount 个代码文件。'
          '定位代码请用 grep（按内容/符号）与 glob（按文件名）检索，'
          '命中后用 read_file 精读对应区间，**不要逐个文件整读**。');
    }
    return buf.toString();
  }

  /// 实际遍历逻辑（静态、纯函数）：接收 (工程根路径, rg 可执行文件路径)，
  /// 用 ripgrep 列出遵守 .gitignore 的文件，再筛出代码文件并取 mtime。
  /// 设计成静态方法是为了能被 compute 丢到后台 isolate 执行，主 UI 线程保持流畅。
  static Map<String, int> _scan((String, String) msg) {
    final rootPath = msg.$1;
    final rgExe = msg.$2;
    final out = <String, int>{};
    for (final rel in Ripgrep.listFilesSync(rgExe, rootPath)) {
      final ext = p.extension(rel).toLowerCase();
      if (!_codeExts.contains(ext)) continue;
      FileStat st;
      try {
        st = File(p.join(rootPath, rel)).statSync();
      } catch (_) {
        continue;
      }
      if (st.size == 0) continue;
      out[rel] = st.modified.millisecondsSinceEpoch;
    }
    return out;
  }
}
