import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 统一封装 ripgrep(`rg`)：优先使用随应用捆绑的二进制（首次从 assets 释放到应用
/// 支持目录并赋予可执行权限），其次回退到系统 PATH 上的 `rg`。
///
/// 用它替代自研的 Dart 文件遍历/正则搜索：`rg` 原生遵守 `.gitignore`、跳过隐藏与
/// 二进制文件、支持多编码，且速度远超逐文件读取的实现。
///
/// 注意：二进制解析用到 rootBundle / path_provider，只能在主 isolate 完成；需要在
/// 后台 isolate（compute）里跑 `rg` 时，请先在主 isolate 调用 [exePath] 拿到路径，
/// 再把该路径传入 isolate，isolate 内只用该路径执行 [Process]。
class Ripgrep {
  Ripgrep._();
  static final Ripgrep instance = Ripgrep._();

  /// 宽容的 UTF‑8 编解码：匹配行/文件名可能含非 UTF‑8 字节（如 GBK），
  /// 用替换字符兜住而不是抛异常导致整次搜索失败。
  static const _lenientUtf8 = Utf8Codec(allowMalformed: true);

  String? _exe;
  Future<String>? _resolving;

  /// 解析并缓存 rg 可执行文件路径（幂等）。解析失败不缓存，允许后续重试。
  Future<String> exePath() {
    final cached = _exe;
    if (cached != null) return Future.value(cached);
    return _resolving ??= _resolve().then(
      (value) {
        _exe = value;
        _resolving = null;
        return value;
      },
      onError: (Object e, StackTrace st) {
        _resolving = null;
        throw e;
      },
    );
  }

  Future<String> _resolve() async {
    final bundled = await _extractBundled();
    if (bundled != null) return bundled;
    if (await _works('rg', shell: Platform.isWindows)) return 'rg';
    throw Exception('未找到 ripgrep(rg)：捆绑二进制释放失败且系统 PATH 上也没有 rg。');
  }

  Future<bool> _works(String exe, {bool shell = false}) async {
    try {
      final r = await Process.run(exe, const ['--version'], runInShell: shell);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 依平台候选的捆绑资源（macOS 先 arm64 再 x64）。
  List<String> _assetCandidates() {
    if (Platform.isWindows) return const ['assets/bin/windows/rg.exe'];
    if (Platform.isLinux) return const ['assets/bin/linux/rg'];
    if (Platform.isMacOS) {
      return const ['assets/bin/macos/rg', 'assets/bin/macos/rg-x64'];
    }
    return const [];
  }

  Future<String?> _extractBundled() async {
    final candidates = _assetCandidates();
    if (candidates.isEmpty) return null;
    Directory support;
    try {
      support = await getApplicationSupportDirectory();
    } catch (_) {
      return null;
    }
    final binDir = Directory(p.join(support.path, 'bin'));
    final exeName = Platform.isWindows ? 'rg.exe' : 'rg';
    final out = File(p.join(binDir.path, exeName));
    for (final asset in candidates) {
      try {
        final data = await rootBundle.load(asset);
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        await binDir.create(recursive: true);
        // 仅在缺失或大小不一致时重写，避免每次启动都写盘。
        if (!await out.exists() || (await out.length()) != bytes.length) {
          await out.writeAsBytes(bytes, flush: true);
          if (!Platform.isWindows) {
            await Process.run('chmod', ['+x', out.path]);
          }
        }
        if (await _works(out.path)) return out.path;
      } catch (_) {
        // 尝试下一个候选（如 macOS 架构不匹配）。
      }
    }
    return null;
  }

  /// 运行 rg 并返回结果。exitCode：0 有匹配、1 无匹配、>1 出错。
  Future<ProcessResult> run(
    List<String> args, {
    String? workingDirectory,
  }) async {
    final exe = await exePath();
    return Process.run(
      exe,
      args,
      workingDirectory: workingDirectory,
      stdoutEncoding: _lenientUtf8,
      stderrEncoding: _lenientUtf8,
    );
  }

  /// 依赖/构建/IDE 等噪声目录：即使工程没有 .gitignore 也强制跳过（与旧行为一致）。
  static const noiseDirs = [
    '.git', '.hg', '.svn', 'node_modules', 'build', 'dist', 'out', 'target',
    '.dart_tool', '.idea', '.vscode', '.gradle', 'bin', 'obj', 'Pods',
    '.next', '.nuxt', 'coverage', 'venv', '.venv', 'env', '__pycache__',
    '.pub-cache', 'vendor', '.cache', '.expo', 'DerivedData',
  ];

  /// 生成排除噪声目录的 `-g !dir` 参数序列。
  static List<String> noiseExcludeArgs() => [
        for (final d in noiseDirs) ...['-g', '!$d'],
      ];

  /// 同步列出 [dir] 下的文件相对路径（遵守 .gitignore、跳过隐藏/二进制/噪声目录）。
  ///
  /// 供后台 isolate（compute）内使用：需在主 isolate 先通过 [exePath] 解析出
  /// [rgExe] 再传入，isolate 内只用该路径同步执行，避免依赖插件通道。
  static List<String> listFilesSync(
    String rgExe,
    String dir, {
    List<String> globs = const [],
    bool excludeNoise = true,
  }) {
    final args = <String>[
      '--files',
      '--path-separator', '/',
      if (excludeNoise) ...noiseExcludeArgs(),
      for (final g in globs) ...['-g', g],
    ];
    ProcessResult r;
    try {
      r = Process.runSync(
        rgExe,
        args,
        workingDirectory: dir,
        stdoutEncoding: _lenientUtf8,
      );
    } catch (_) {
      return const [];
    }
    if (r.exitCode > 1) return const [];
    final out = const LineSplitter()
        .convert(r.stdout.toString())
        .map(_normalizeRel)
        .where((s) => s.isNotEmpty)
        .toList();
    // rg 并行遍历输出顺序不确定；排序以保证「先截断再处理」的调用方结果可复现。
    out.sort();
    return out;
  }

  /// 流式列出 [dir] 下（遵守 .gitignore、跳过隐藏/二进制/噪声目录）的文件相对路径。
  /// [globs] 为可选的 `-g` 过滤；命中 [isCancelled] 时提前结束并杀掉进程。
  Stream<String> listFiles(
    String dir, {
    List<String> globs = const [],
    bool excludeNoise = true,
    bool Function()? isCancelled,
  }) async* {
    final exe = await exePath();
    final args = <String>[
      '--files',
      '--path-separator', '/',
      if (excludeNoise) ...noiseExcludeArgs(),
      for (final g in globs) ...['-g', g],
    ];
    final proc = await Process.start(exe, args, workingDirectory: dir);
    unawaited(proc.stderr.drain<void>());
    try {
      await for (final line in proc.stdout
          .transform(_lenientUtf8.decoder)
          .transform(const LineSplitter())) {
        if (isCancelled?.call() ?? false) break;
        final rel = _normalizeRel(line);
        if (rel.isNotEmpty) yield rel;
      }
    } finally {
      proc.kill();
    }
  }

  /// 去掉 rg 输出路径可能的 `./` 前缀，并统一分隔符为 `/`。
  static String _normalizeRel(String line) {
    var s = line.trim().replaceAll('\\', '/');
    if (s.startsWith('./')) s = s.substring(2);
    return s;
  }
}
