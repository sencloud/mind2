import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// 系统无头浏览器（Edge / Chrome）统一封装。
///
/// 全工程唯一的无头浏览器入口：浏览器探测、**高清截图（PNG）**、HTML→PDF、
/// 渲染 DOM 都收敛到这里。新增「生成高清图 / 导出 PDF / 抓取渲染后页面」的
/// 功能一律复用本类，不要再各自写候选路径与 `Process.run` 参数。
class HeadlessBrowser {
  HeadlessBrowser._();

  static const _candidates = [
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
  ];

  /// 高清截图默认设备像素倍率：3x，兼顾清晰度与解码/内存开销的稳定性。
  static const pngScale = 3;

  /// 高清截图默认视口逻辑尺寸：足够宽以容纳宽幅架构图，避免被裁剪。
  /// 实际输出像素 = 视口尺寸 × [pngScale]，多余白边由调用方按需裁掉。
  static const pngViewportW = 3200;
  static const pngViewportH = 2200;

  /// 系统 Edge/Chrome 可执行文件路径，找不到返回 null。
  static String? path() {
    for (final path in _candidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// 本机是否具备无头浏览器能力。
  static bool get available => path() != null;

  /// 把一段自包含 HTML 渲染成**高清 PNG** 字节（失败返回 null）。
  ///
  /// [scale] 为设备像素倍率，[viewportW]/[viewportH] 为逻辑视口尺寸；返回的是
  /// 原始截图 PNG（含白边），是否裁边由调用方决定。
  static Future<Uint8List?> capturePng(
    String html, {
    int scale = pngScale,
    int viewportW = pngViewportW,
    int viewportH = pngViewportH,
    int virtualTimeBudgetMs = 15000,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final browser = path();
    if (browser == null) return null;
    final tmp = await Directory.systemTemp.createTemp('mind_hb_shot_');
    try {
      final htmlFile = File(p.join(tmp.path, 'page.html'));
      await htmlFile.writeAsString(html, encoding: utf8);
      final png = File(p.join(tmp.path, 'out.png'));
      await Process.run(
        browser,
        [
          '--headless=new',
          '--disable-gpu',
          '--no-sandbox',
          '--hide-scrollbars',
          '--user-data-dir=${p.join(tmp.path, 'ud')}',
          '--screenshot=${png.path}',
          '--window-size=$viewportW,$viewportH',
          '--force-device-scale-factor=$scale',
          '--default-background-color=FFFFFFFF',
          '--virtual-time-budget=$virtualTimeBudgetMs',
          '--run-all-compositor-stages-before-draw',
          htmlFile.uri.toString(),
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
      // `--headless=new` 会在启动进程返回后才异步写完截图文件，
      // 故不能立即判断 exists，需轮询等待文件出现且大小稳定。
      if (!await _awaitOutputFile(png)) return null;
      return await png.readAsBytes();
    } catch (_) {
      return null;
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 把已落盘的 HTML 文件打印成 PDF（写入 [out]）。失败抛异常。
  ///
  /// 传入 [File] 而非字符串，是为了让 HTML 内引用的相对资源（图片等）保持可用。
  static Future<void> printPdf(
    File html,
    File out, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final browser = path();
    if (browser == null) throw Exception('未找到 Edge 或 Chrome，无法导出 PDF');
    final tmp = await Directory.systemTemp.createTemp('mind_hb_pdf_');
    try {
      final result = await Process.run(
        browser,
        [
          '--headless=new',
          '--disable-gpu',
          '--no-sandbox',
          '--user-data-dir=${tmp.path}',
          '--print-to-pdf=${out.path}',
          '--print-to-pdf-no-header',
          '--no-pdf-header-footer',
          html.uri.toString(),
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
      // 同截图：`--headless=new` 异步落盘，需轮询等待 PDF 文件写完。
      if (!await _awaitOutputFile(out)) {
        throw Exception(
          'PDF 导出失败：${(result.stderr as String?)?.trim() ?? result.exitCode}',
        );
      }
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 轮询等待无头浏览器异步写出的输出文件（截图/PDF）：直到文件存在、
  /// 非空且大小连续两次采样保持稳定（写完），或超时。
  static Future<bool> _awaitOutputFile(
    File f, {
    Duration timeout = const Duration(seconds: 25),
    Duration interval = const Duration(milliseconds: 150),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var lastSize = -1;
    var stable = 0;
    while (DateTime.now().isBefore(deadline)) {
      if (await f.exists()) {
        final size = await f.length();
        if (size > 0 && size == lastSize) {
          if (++stable >= 2) return true;
        } else {
          stable = 0;
        }
        lastSize = size;
      }
      await Future.delayed(interval);
    }
    return await f.exists() && await f.length() > 0;
  }

  /// 渲染页面并返回最终 DOM HTML（找不到浏览器或失败返回 null）。
  static Future<String?> renderDom(
    String url, {
    int virtualTimeBudgetMs = 12000,
    Duration timeout = const Duration(seconds: 50),
  }) async {
    final browser = path();
    if (browser == null) return null;
    final tmp = Directory.systemTemp.createTempSync('mind_hb_dom_');
    try {
      final result = await Process.run(
        browser,
        [
          '--headless=new',
          '--disable-gpu',
          '--no-sandbox',
          '--disable-dev-shm-usage',
          '--user-data-dir=${tmp.path}',
          '--virtual-time-budget=$virtualTimeBudgetMs',
          '--run-all-compositor-stages-before-draw',
          '--dump-dom',
          url,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
      final out = result.stdout as String? ?? '';
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
