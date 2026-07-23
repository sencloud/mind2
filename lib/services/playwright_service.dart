import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/text_util.dart';
import 'settings_service.dart';
import 'source_adapters.dart';

/// 页面需要登录时传给 UI 的最小信息。
class LoginRequest {
  LoginRequest({
    required this.domain,
    required this.url,
    required this.title,
    required this.reason,
  });

  final String domain;
  final String url;
  final String title;
  final String reason;
}

/// 用户在弹窗中临时输入的凭据。
///
/// 该对象只在内存中传给当前 Playwright worker。不要写入日志、笔记或设置。
class LoginCredential {
  LoginCredential({required this.username, required this.password});

  final String username;
  final String password;
}

typedef LoginCredentialProvider =
    Future<LoginCredential?> Function(LoginRequest request);

/// Playwright 浏览研究读到的一页证据。
class BrowserResearchResult {
  BrowserResearchResult({
    required this.source,
    required this.excerpt,
    required this.visibleText,
    required this.readingPath,
    required this.screenshotBase64,
    required this.needsLogin,
  });

  final SourceResult source;
  final String excerpt;
  final String visibleText;
  final String readingPath;
  final String screenshotBase64;
  final bool needsLogin;

  factory BrowserResearchResult.fromJson(Map<String, dynamic> json) {
    final title = (json['title'] as String? ?? '').trim();
    final url = (json['url'] as String? ?? '').trim();
    final ext = (json['ext'] as String? ?? 'html').trim();
    final excerpt = (json['excerpt'] as String? ?? '').trim();
    return BrowserResearchResult(
      source: SourceResult(
        title: title.isEmpty ? url : title,
        url: url,
        source: SourceId.web,
        ext: ext.isEmpty ? 'html' : ext,
        summary: excerpt,
        landingUrl: url,
      ),
      excerpt: excerpt,
      visibleText: (json['visibleText'] as String? ?? '').trim(),
      readingPath: (json['readingPath'] as String? ?? '').trim(),
      screenshotBase64: (json['screenshotBase64'] as String? ?? '').trim(),
      needsLogin: json['needsLogin'] == true,
    );
  }
}

/// 通过 Node + Playwright 驱动 Chromium，更可靠地渲染政策/法规/标准等
/// JS 页面：抓取真实结果链接、把网页保存为 PDF、或直接下载 PDF。
///
/// 首次使用需在设置里点「安装 Playwright」（会在应用数据目录内执行
/// `npm install playwright` 与 `npx playwright install chromium`，需已安装 Node.js）。
class PlaywrightService extends ChangeNotifier {
  PlaywrightService(this.settings);

  final SettingsService settings;

  bool installing = false;
  final List<String> logs = [];

  Directory? _dir;
  bool _nodeChecked = false;
  bool _nodeOk = false;

  /// 最近一次网页检索的诊断信息（返回 0 条时由上层打印，用于定位原因）。
  String lastSearchDiag = '';

  /// 最近一次驱动进程启动失败的错误（超时 / 找不到 node 等）。
  String _lastDriverError = '';

  bool get enabled => settings.playwrightEnabled;

  void _log(String m) {
    logs.add(m);
    if (logs.length > 400) logs.removeRange(0, logs.length - 400);
    notifyListeners();
  }

  Future<Directory> _workDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'playwright'));
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  /// 持久浏览器资料目录。这里保存 cookie/session，以便同一网站登录后继续研究。
  /// 用户名和密码不写入该目录；凭据只会临时传给当前 worker。
  Future<Directory> _profileDir() async {
    final dir = Directory(p.join((await _workDir()).path, 'browser_profile'));
    await dir.create(recursive: true);
    return dir;
  }

  /// 清除网页登录态。用于用户想退出网站或移除持久 cookie/session 时。
  Future<void> clearBrowserState() async {
    final dir = await _profileDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);
    _log('已清除 Playwright 浏览研究的网页登录态。');
  }

  String get _node => Platform.isWindows ? 'node' : 'node';
  String get _npm => Platform.isWindows ? 'npm.cmd' : 'npm';
  String get _npx => Platform.isWindows ? 'npx.cmd' : 'npx';

  Future<bool> _hasNode() async {
    if (_nodeChecked) return _nodeOk;
    try {
      final r = await Process.run(_node, [
        '--version',
      ]).timeout(const Duration(seconds: 8));
      _nodeOk = r.exitCode == 0;
    } catch (_) {
      _nodeOk = false;
    }
    _nodeChecked = true;
    return _nodeOk;
  }

  /// 是否已具备运行条件：Node 可用且 playwright 已安装在工作目录。
  Future<bool> ready() async {
    if (!enabled) return false;
    if (!await _hasNode()) return false;
    final dir = await _workDir();
    final pkg = File(
      p.join(dir.path, 'node_modules', 'playwright', 'package.json'),
    );
    // 始终写入最新驱动脚本，保证旧安装也能用上更新后的 Bing 抓取逻辑。
    await _writeScript();
    return pkg.existsSync();
  }

  Future<void> _writeScript() async {
    final dir = await _workDir();
    await File(p.join(dir.path, 'package.json')).writeAsString(
      jsonEncode({
        'name': 'mind-playwright',
        'private': true,
        'version': '1.0.0',
        'dependencies': {'playwright': '^1.49.0'},
      }),
    );
    await File(p.join(dir.path, 'pw.js')).writeAsString(_driverJs);
  }

  /// 安装 Playwright 与 Chromium。需已安装 Node.js。
  Future<bool> install() async {
    if (installing) return false;
    installing = true;
    logs.clear();
    notifyListeners();
    try {
      if (!await _hasNode()) {
        _log('未检测到 Node.js，请先安装 Node.js（https://nodejs.org）后重试。');
        return false;
      }
      final dir = await _workDir();
      await _writeScript();
      _log('① 安装 playwright（npm install）…');
      final ok1 = await _stream(_npm, ['install', 'playwright'], dir.path);
      if (!ok1) {
        _log('npm install 失败。');
        return false;
      }
      _log('② 下载 Chromium（playwright install chromium）…');
      final ok2 = await _stream(_npx, [
        'playwright',
        'install',
        'chromium',
      ], dir.path);
      if (!ok2) {
        _log('Chromium 下载失败。');
        return false;
      }
      final ok = await ready();
      _log(ok ? '安装完成，Playwright 已就绪。' : '安装结束，但校验未通过。');
      return ok;
    } catch (e) {
      _log('安装出错：$e');
      return false;
    } finally {
      installing = false;
      notifyListeners();
    }
  }

  Future<bool> _stream(String exe, List<String> args, String cwd) async {
    try {
      final proc = await Process.start(
        exe,
        args,
        workingDirectory: cwd,
        runInShell: true,
      );
      // Windows 下 npm/npx 输出多为 GBK，用容错解码避免 FormatException 崩溃。
      const dec = Utf8Decoder(allowMalformed: true);
      proc.stdout.transform(dec).transform(const LineSplitter()).listen((l) {
        if (l.trim().isNotEmpty) _log(l.trim());
      });
      proc.stderr.transform(dec).transform(const LineSplitter()).listen((l) {
        if (l.trim().isNotEmpty) _log(l.trim());
      });
      final code = await proc.exitCode.timeout(const Duration(minutes: 10));
      return code == 0;
    } catch (e) {
      _log('执行失败：$e');
      return false;
    }
  }

  Future<ProcessResult?> _runDriver(
    List<String> args, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    _lastDriverError = '';
    try {
      final dir = await _workDir();
      const codec = Utf8Codec(allowMalformed: true);
      return await Process.run(
        _node,
        ['pw.js', ...args],
        workingDirectory: dir.path,
        stdoutEncoding: codec,
        stderrEncoding: codec,
      ).timeout(timeout);
    } on TimeoutException {
      _lastDriverError = '驱动执行超时（>${timeout.inSeconds}s）';
      return null;
    } catch (e) {
      _lastDriverError = '驱动进程启动失败：$e';
      return null;
    }
  }

  /// 用 Playwright 渲染搜索页并抽取真实结果链接（含 PDF 直链）。
  Future<List<SourceResult>> search(String query, {int limit = 15}) async {
    lastSearchDiag = '';
    final r = await _runDriver([
      'search',
      query,
      '$limit',
    ], timeout: const Duration(seconds: 150));
    if (r == null) {
      lastSearchDiag = _lastDriverError.isNotEmpty
          ? _lastDriverError
          : '驱动进程未返回（node/pw.js 未能执行）';
      return [];
    }
    final stderr = (r.stderr as String? ?? '').trim();
    if (r.exitCode != 0) {
      lastSearchDiag = 'pw.js 退出码 ${r.exitCode}；stderr: ${_clip(stderr)}';
      return [];
    }
    final stdout = (r.stdout as String? ?? '').trim();
    try {
      final list = jsonDecode(stdout);
      if (list is! List) {
        lastSearchDiag = 'stdout 非 JSON 数组：${_clip(stdout)}';
        return [];
      }
      final out = <SourceResult>[];
      for (final e in list) {
        if (e is! Map) continue;
        final title = (e['title'] as String? ?? '').trim();
        final url = (e['url'] as String? ?? '').trim();
        if (title.isEmpty || !url.startsWith('http')) continue;
        out.add(
          SourceResult(
            title: title,
            url: url,
            source: SourceId.web,
            ext: (e['ext'] as String? ?? 'html'),
            landingUrl: url,
          ),
        );
      }
      if (out.isEmpty) {
        // pw.js 在 0 结果时会把每页页面状态写到 stderr（DIAG 前缀）。
        lastSearchDiag = stderr.isNotEmpty
            ? _clip(stderr)
            : 'Bing 未返回有机结果（stdout=${_clip(stdout)}）';
      }
      return out;
    } catch (e) {
      lastSearchDiag =
          'JSON 解析失败：$e；stdout: ${_clip(stdout)}；stderr: ${_clip(stderr)}';
      return [];
    }
  }

  /// 像用户一样搜索、打开结果、滚动阅读，并在遇到登录页时向 UI 请求临时凭据。
  ///
  /// 这里使用 JSONL 与 Node worker 通信。worker 只接收当前弹窗输入的账号密码，
  /// 不会把凭据写入 stdout/stderr；Dart 侧也只记录站点状态，不记录用户名密码。
  Future<List<BrowserResearchResult>> searchAndRead(
    String query, {
    int limit = 6,
    LoginCredentialProvider? onLoginRequired,
  }) async {
    lastSearchDiag = '';
    _lastDriverError = '';
    final dir = await _workDir();
    final profile = await _profileDir();
    await _writeScript();
    final proc = await Process.start(
      _node,
      ['pw.js', 'research', query, '$limit', profile.path],
      workingDirectory: dir.path,
      runInShell: true,
    );
    final results = <BrowserResearchResult>[];
    final stderr = StringBuffer();
    final stdoutDone = Completer<void>();
    const codec = Utf8Codec(allowMalformed: true);

    proc.stderr.transform(codec.decoder).listen(stderr.write);
    proc.stdout
        .transform(codec.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) async {
            if (line.trim().isEmpty) return;
            Map<String, dynamic> event;
            try {
              event = jsonDecode(line) as Map<String, dynamic>;
            } catch (_) {
              lastSearchDiag = _clip(line);
              return;
            }
            final type = event['event'] as String? ?? '';
            if (type == 'login_required') {
              final request = LoginRequest(
                domain: (event['domain'] as String? ?? '').trim(),
                url: (event['url'] as String? ?? '').trim(),
                title: (event['title'] as String? ?? '').trim(),
                reason: (event['reason'] as String? ?? '页面需要登录后继续阅读').trim(),
              );
              final credential = onLoginRequired == null
                  ? null
                  : await onLoginRequired(request);
              final response = {
                'id': event['id'],
                'skip': credential == null,
                if (credential != null) 'username': credential.username,
                if (credential != null) 'password': credential.password,
              };
              proc.stdin.writeln(jsonEncode(response));
            } else if (type == 'result') {
              final items = event['items'];
              if (items is List) {
                for (final item in items) {
                  if (item is Map<String, dynamic>) {
                    final r = BrowserResearchResult.fromJson(item);
                    if (r.source.url.startsWith('http')) results.add(r);
                  }
                }
              }
            } else if (type == 'diag') {
              lastSearchDiag = _clip(
                (event['message'] as String? ?? '').trim(),
              );
            }
          },
          onDone: () {
            if (!stdoutDone.isCompleted) stdoutDone.complete();
          },
          onError: (Object e) {
            if (!stdoutDone.isCompleted) stdoutDone.completeError(e);
          },
        );

    try {
      final code = await proc.exitCode.timeout(const Duration(minutes: 6));
      await stdoutDone.future.timeout(const Duration(seconds: 5));
      final err = stderr.toString().trim();
      if (code != 0) {
        lastSearchDiag = '浏览研究 worker 退出码 $code；stderr: ${_clip(err)}';
        return [];
      }
      if (results.isEmpty) {
        lastSearchDiag = err.isNotEmpty ? _clip(err) : '浏览研究未读到可用网页。';
      }
      return results;
    } on TimeoutException {
      proc.kill();
      _lastDriverError = '浏览研究 worker 超时（>360s）';
      lastSearchDiag = _lastDriverError;
      return [];
    } catch (e) {
      proc.kill();
      _lastDriverError = '浏览研究 worker 失败：$e';
      lastSearchDiag = _lastDriverError;
      return [];
    }
  }

  /// 直接打开一个 URL 阅读。用于 CNKI、ACM、IEEE 等必须进入详情页才能看到摘要的来源。
  Future<BrowserResearchResult?> readPage(
    String url, {
    LoginCredentialProvider? onLoginRequired,
  }) async {
    final items = await _runBrowserWorker([
      'readurl',
      url,
      (await _profileDir()).path,
    ], onLoginRequired: onLoginRequired);
    return items.isEmpty ? null : items.first;
  }

  Future<List<BrowserResearchResult>> _runBrowserWorker(
    List<String> args, {
    LoginCredentialProvider? onLoginRequired,
  }) async {
    lastSearchDiag = '';
    _lastDriverError = '';
    final dir = await _workDir();
    await _writeScript();
    final proc = await Process.start(
      _node,
      ['pw.js', ...args],
      workingDirectory: dir.path,
      runInShell: true,
    );
    final results = <BrowserResearchResult>[];
    final stderr = StringBuffer();
    final stdoutDone = Completer<void>();
    const codec = Utf8Codec(allowMalformed: true);

    proc.stderr.transform(codec.decoder).listen(stderr.write);
    proc.stdout
        .transform(codec.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) async {
            if (line.trim().isEmpty) return;
            Map<String, dynamic> event;
            try {
              event = jsonDecode(line) as Map<String, dynamic>;
            } catch (_) {
              lastSearchDiag = _clip(line);
              return;
            }
            final type = event['event'] as String? ?? '';
            if (type == 'login_required') {
              final request = LoginRequest(
                domain: (event['domain'] as String? ?? '').trim(),
                url: (event['url'] as String? ?? '').trim(),
                title: (event['title'] as String? ?? '').trim(),
                reason: (event['reason'] as String? ?? '页面需要登录后继续阅读').trim(),
              );
              final credential = onLoginRequired == null
                  ? null
                  : await onLoginRequired(request);
              final response = {
                'id': event['id'],
                'skip': credential == null,
                if (credential != null) 'username': credential.username,
                if (credential != null) 'password': credential.password,
              };
              proc.stdin.writeln(jsonEncode(response));
            } else if (type == 'result') {
              final items = event['items'];
              if (items is List) {
                for (final item in items) {
                  if (item is Map<String, dynamic>) {
                    final r = BrowserResearchResult.fromJson(item);
                    if (r.source.url.startsWith('http')) results.add(r);
                  }
                }
              }
            } else if (type == 'diag') {
              lastSearchDiag = _clip(
                (event['message'] as String? ?? '').trim(),
              );
            }
          },
          onDone: () {
            if (!stdoutDone.isCompleted) stdoutDone.complete();
          },
          onError: (Object e) {
            if (!stdoutDone.isCompleted) stdoutDone.completeError(e);
          },
        );

    try {
      final code = await proc.exitCode.timeout(const Duration(minutes: 6));
      await stdoutDone.future.timeout(const Duration(seconds: 5));
      final err = stderr.toString().trim();
      if (code != 0) {
        lastSearchDiag = '浏览研究 worker 退出码 $code；stderr: ${_clip(err)}';
        return [];
      }
      if (results.isEmpty) {
        lastSearchDiag = err.isNotEmpty ? _clip(err) : '浏览研究未读到可用网页。';
      }
      return results;
    } on TimeoutException {
      proc.kill();
      _lastDriverError = '浏览研究 worker 超时（>360s）';
      lastSearchDiag = _lastDriverError;
      return [];
    } catch (e) {
      proc.kill();
      _lastDriverError = '浏览研究 worker 失败：$e';
      lastSearchDiag = _lastDriverError;
      return [];
    }
  }

  static String _clip(String s, [int max = 600]) =>
      clip(s.replaceAll(RegExp(r'\s+'), ' ').trim(), max, suffix: '…');

  /// 把网页渲染后保存为 PDF，成功返回 PDF 字节。
  Future<Uint8List?> pagePdf(String url) async {
    final out =
        '${(await _workDir()).path}\\out_${DateTime.now().microsecondsSinceEpoch}.pdf';
    final r = await _runDriver([
      'pagepdf',
      url,
      out,
    ], timeout: const Duration(seconds: 120));
    return _readAndClean(out, r);
  }

  /// 用浏览器上下文直接下载 PDF（处理跳转/会话），成功返回字节。
  Future<Uint8List?> downloadPdf(String url) async {
    final out =
        '${(await _workDir()).path}\\dl_${DateTime.now().microsecondsSinceEpoch}.pdf';
    final r = await _runDriver([
      'getpdf',
      url,
      out,
    ], timeout: const Duration(seconds: 120));
    return _readAndClean(out, r);
  }

  Uint8List? _readAndClean(String path, ProcessResult? r) {
    final f = File(path);
    try {
      if (r != null && r.exitCode == 0 && f.existsSync()) {
        final bytes = f.readAsBytesSync();
        return bytes.isNotEmpty ? bytes : null;
      }
      return null;
    } finally {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  static const _driverJs = r'''
const { chromium } = require('playwright');
const fs = require('fs');
const readline = require('readline');

(async () => {
  const [, , cmd, ...args] = process.argv;
  const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';
  let browser = null;
  let ctx = null;
  const responses = [];
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', line => {
    try { responses.push(JSON.parse(line)); } catch (e) {}
  });

  const emit = (obj) => process.stdout.write(JSON.stringify(obj) + '\n');
  const clip = (s, max) => {
    s = String(s || '').replace(/\s+/g, ' ').trim();
    return s.length > max ? s.slice(0, max) + '…' : s;
  };
  // Bing 把有机结果链接包成 https://www.bing.com/ck/a?...&u=a1<base64>，需解码出真实地址。
  const decodeBing = (href) => {
    try {
      const m = href.match(/[?&]u=a1([A-Za-z0-9_-]+)/);
      if (!m) return href;
      let b64 = m[1].replace(/-/g, '+').replace(/_/g, '/');
      while (b64.length % 4) b64 += '=';
      const real = Buffer.from(b64, 'base64').toString('utf8');
      return real.startsWith('http') ? real : href;
    } catch (e) { return href; }
  };
  const normalizeHref = (href) => {
    let u = decodeBing(href || '');
    try {
      const parsed = new URL(u, 'https://www.bing.com');
      const duck = parsed.searchParams.get('uddg');
      if (duck && /^https?:/i.test(duck)) u = decodeURIComponent(duck);
      const embedded = parsed.searchParams.get('url') || parsed.searchParams.get('u');
      if (embedded && /^https?:/i.test(embedded)) u = decodeURIComponent(embedded);
    } catch (e) {}
    return u;
  };
  const blocked = (u) => /bing\.com|microsoft\.com|go\.microsoft|msn\.com|duckduckgo\.com|javascript:|mailto:/i.test(u);

  async function extractSearchLinks(page) {
    return await page.evaluate(() => {
      const out = [];
      const push = (a, pdf = false) => {
        const href = a && a.href ? a.href : '';
        const text = ((a && a.textContent) || '').replace(/\s+/g, ' ').trim();
        if (!href || !/^https?:/i.test(href)) return;
        if (!text && !/\.pdf(\?|$)/i.test(href)) return;
        out.push({ title: text || href, url: href, pdf: pdf || /\.pdf(\?|$)/i.test(href) });
      };
      [
        '#b_results li.b_algo h2 a',
        '#b_results h2 a',
        '.b_title a',
        'a.result__a',
        '.result a[href]',
        'article h2 a',
        'article h3 a',
        'main h2 a',
        'main h3 a',
        '.web-result-title a',
        '.result__title a',
        '#content_left .result h3 a',
        '#content_left .c-container h3 a',
        '#content_left .result a[href]',
        '#content_left .c-container a[href]',
        'h2 a[href]',
        'h3 a[href]',
      ].forEach(sel => document.querySelectorAll(sel).forEach(a => push(a)));
      document.querySelectorAll('a[href]').forEach(a => {
        const href = a.href || '';
        const text = (a.textContent || '').replace(/\s+/g, ' ').trim();
        if (/\.pdf(\?|$)/i.test(href)) {
          push(a, true);
        } else if (/^https?:/i.test(href) && text.length >= 6 && text.length <= 180) {
          const nearResult = a.closest('li, article, .result, .b_algo, [data-testid], .web-result');
          const nearBaidu = a.closest('#content_left .result, #content_left .c-container');
          if (nearResult || nearBaidu) push(a);
        }
      });
      return out;
    });
  }

  async function collectSearchResults(page, query, limit) {
    const seen = new Set();
    const final = [];
    const diag = [];
    const entries = [
      {
        name: 'baidu',
        url: (q, p) => 'https://www.baidu.com/s?wd=' + encodeURIComponent(q) + '&pn=' + (p * 10),
      },
      {
        name: 'bing',
        url: (q, p) => 'https://www.bing.com/search?q=' + encodeURIComponent(q) + '&setlang=zh-CN&count=20&first=' + (p * 10 + 1),
      },
      {
        name: 'cn_bing',
        url: (q, p) => 'https://cn.bing.com/search?q=' + encodeURIComponent(q) + '&setlang=zh-CN&count=20&first=' + (p * 10 + 1),
      },
      {
        name: 'duckduckgo',
        url: (q, p) => 'https://duckduckgo.com/html/?q=' + encodeURIComponent(q) + (p > 0 ? '&s=' + (p * 30) : ''),
      },
    ];
    const maxPages = Math.min(6, Math.ceil(limit / 10) + 2);
    for (let engine = 0; engine < entries.length && final.length < limit; engine++) {
      for (let p = 0; p < maxPages && final.length < limit; p++) {
        const entry = entries[engine];
        const url = entry.url(query, p);
        try {
          await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 });
          await page.waitForLoadState('networkidle', { timeout: 12000 }).catch(() => {});
          await page.waitForTimeout(900);
        } catch (e) {
          diag.push(entry.name + ' p' + (p + 1) + ' goto失败:' + (e && e.message ? e.message : e));
          continue;
        }
        const raw = await extractSearchLinks(page);
        const meta = await page.evaluate(() => ({
          title: document.title,
          hasResults: !!document.querySelector('#b_results'),
          algo: document.querySelectorAll('#b_results li.b_algo').length,
          h2a: document.querySelectorAll('#b_results h2 a').length,
          ddg: document.querySelectorAll('a.result__a, .result a[href]').length,
          bodyLen: ((document.body && document.body.innerText) || '').length,
          url: location.href,
        }));
        diag.push(entry.name + ' p' + (p + 1) + ' title="' + meta.title + '" b_results=' + meta.hasResults +
          ' b_algo=' + meta.algo + ' h2a=' + meta.h2a + ' ddg=' + meta.ddg + ' raw=' + raw.length +
          ' bodyLen=' + meta.bodyLen + ' url=' + meta.url);
        let added = 0;
        for (const r of raw) {
          let u = normalizeHref(r.url || '');
          if (!u || !u.startsWith('http')) continue;
          if (blocked(u)) continue;
          if (seen.has(u)) continue;
          seen.add(u);
          const isPdf = r.pdf || /\.pdf(\?|$)/i.test(u);
          final.push({ title: r.title || u, url: u, ext: isPdf ? 'pdf' : 'html' });
          added++;
          if (final.length >= limit) break;
        }
        if (added === 0 && p > 0) break;
      }
    }
    return { final, diag };
  }

  function waitResponse(id, timeoutMs) {
    return new Promise(resolve => {
      const start = Date.now();
      const timer = setInterval(() => {
        const idx = responses.findIndex(x => x && x.id === id);
        if (idx >= 0) {
          const item = responses.splice(idx, 1)[0];
          clearInterval(timer);
          resolve(item);
        } else if (Date.now() - start > timeoutMs) {
          clearInterval(timer);
          resolve({ id, skip: true });
        }
      }, 250);
    });
  }

  async function pageSnapshot(page) {
    return await page.evaluate(() => {
      const text = ((document.body && document.body.innerText) || '').replace(/\s+/g, ' ').trim();
      const links = Array.from(document.querySelectorAll('a[href]')).slice(0, 80).map(a => ({
        text: (a.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 120),
        href: a.href || '',
      }));
      const passwordInputs = document.querySelectorAll('input[type="password"]').length;
      const formCount = document.querySelectorAll('form').length;
      const loginWords = /登录|登陆|账号|用户名|密码|sign in|log in|password|account/i.test(text);
      return {
        title: document.title || '',
        url: location.href,
        text,
        links,
        formCount,
        passwordInputs,
        needsLogin: passwordInputs > 0 || (loginWords && text.length < 2600),
      };
    });
  }

  async function fillLogin(page, credential) {
    if (!credential || credential.skip) return false;
    const userSelectors = [
      'input[type="email"]',
      'input[type="text"]',
      'input[name*="user"]',
      'input[name*="email"]',
      'input[name*="login"]',
      'input[id*="user"]',
      'input[id*="email"]',
      'input[id*="login"]',
    ];
    for (const sel of userSelectors) {
      const loc = page.locator(sel).first();
      if (await loc.count().catch(() => 0)) {
        await loc.fill(String(credential.username || ''), { timeout: 5000 }).catch(() => {});
        break;
      }
    }
    const pwd = page.locator('input[type="password"]').first();
    if (await pwd.count().catch(() => 0)) {
      await pwd.fill(String(credential.password || ''), { timeout: 5000 }).catch(() => {});
    }
    const submit = page.locator('button[type="submit"], input[type="submit"], button:has-text("登录"), button:has-text("登陆"), button:has-text("Sign in"), button:has-text("Log in")').first();
    if (await submit.count().catch(() => 0)) {
      await Promise.all([
        page.waitForLoadState('domcontentloaded', { timeout: 20000 }).catch(() => {}),
        submit.click({ timeout: 8000 }).catch(() => {}),
      ]);
    } else {
      await page.keyboard.press('Enter').catch(() => {});
      await page.waitForLoadState('domcontentloaded', { timeout: 20000 }).catch(() => {});
    }
    await page.waitForTimeout(1200);
    return true;
  }

  async function readResult(ctx, item, index) {
    const page = await ctx.newPage();
    try {
      await page.goto(item.url, { waitUntil: 'domcontentloaded', timeout: 60000 });
      await page.waitForTimeout(1000);
      let snap = await pageSnapshot(page);
      let usedLogin = false;
      if (snap.needsLogin) {
        const reqId = 'login-' + Date.now() + '-' + index;
        let domain = '';
        try { domain = new URL(snap.url).hostname; } catch (e) {}
        emit({
          event: 'login_required',
          id: reqId,
          domain,
          url: snap.url,
          title: snap.title || item.title,
          reason: '页面出现登录表单或账号密码提示，需要登录后继续阅读。',
        });
        const credential = await waitResponse(reqId, 5 * 60 * 1000);
        usedLogin = await fillLogin(page, credential);
        snap = await pageSnapshot(page);
      }
      for (let i = 0; i < 3; i++) {
        await page.mouse.wheel(0, 900).catch(() => {});
        await page.waitForTimeout(450);
      }
      snap = await pageSnapshot(page);
      const screenshotBase64 = await page.screenshot({
        type: 'jpeg',
        quality: 55,
        fullPage: false,
        timeout: 10000,
      }).then(buf => buf.toString('base64')).catch(() => '');
      return {
        title: snap.title || item.title,
        url: snap.url || item.url,
        ext: item.ext || 'html',
        excerpt: clip(snap.text, 3200),
        visibleText: clip(snap.text, 12000),
        readingPath: '搜索结果 → 打开页面' + (usedLogin ? ' → 登录后继续阅读' : '') + ' → 滚动阅读',
        screenshotBase64,
        needsLogin: usedLogin,
      };
    } finally {
      await page.close().catch(() => {});
    }
  }

  try {
    if (cmd === 'research' || cmd === 'readurl') {
      const query = args[0];
      const limit = cmd === 'research' ? parseInt(args[1] || '6', 10) : 1;
      const profileDir = cmd === 'research' ? args[2] : args[1];
      ctx = await chromium.launchPersistentContext(profileDir, {
        headless: true,
        acceptDownloads: true,
        userAgent: UA,
        locale: 'zh-CN',
        viewport: { width: 1365, height: 900 },
      });
      if (cmd === 'readurl') {
        const read = await readResult(ctx, { title: query, url: query, ext: 'html' }, 0);
        emit({ event: 'result', items: [read] });
        return;
      }
      const page = await ctx.newPage();
      const found = await collectSearchResults(page, query, Math.max(limit, 8));
      await page.close().catch(() => {});
      if (found.final.length === 0) emit({ event: 'diag', message: 'DIAG ' + found.diag.join(' || ') });
      const items = [];
      for (let i = 0; i < found.final.length && items.length < limit; i++) {
        const r = found.final[i];
        if (r.ext === 'pdf') {
          items.push({ title: r.title, url: r.url, ext: 'pdf', excerpt: '', visibleText: '', readingPath: '搜索结果 → PDF 链接', screenshotBase64: '', needsLogin: false });
          continue;
        }
        const read = await readResult(ctx, r, i).catch(e => ({
          title: r.title,
          url: r.url,
          ext: r.ext || 'html',
          excerpt: '',
          visibleText: '',
          readingPath: '打开页面失败：' + String(e && e.message ? e.message : e),
          screenshotBase64: '',
          needsLogin: false,
        }));
        if (read.excerpt || read.visibleText || read.ext === 'pdf') items.push(read);
      }
      emit({ event: 'result', items });
    } else {
      browser = await chromium.launch({ headless: true });
      ctx = await browser.newContext({ acceptDownloads: true, userAgent: UA, locale: 'zh-CN' });
      const page = await ctx.newPage();
      if (cmd === 'search') {
        const query = args[0];
        const limit = parseInt(args[1] || '15', 10);
        const found = await collectSearchResults(page, query, limit);
        process.stdout.write(JSON.stringify(found.final));
        if (found.final.length === 0) process.stderr.write('DIAG ' + found.diag.join(' || '));
      } else if (cmd === 'pagepdf') {
        const url = args[0], out = args[1];
        await page.goto(url, { waitUntil: 'networkidle', timeout: 60000 });
        await page.waitForTimeout(800);
        await page.pdf({ path: out, format: 'A4', printBackground: true, margin: { top: '12mm', bottom: '12mm', left: '12mm', right: '12mm' } });
        process.stdout.write('OK');
      } else if (cmd === 'getpdf') {
        const url = args[0], out = args[1];
        const resp = await ctx.request.get(url, { timeout: 60000 });
        const buf = await resp.body();
        fs.writeFileSync(out, buf);
        process.stdout.write('OK');
      } else {
        process.stderr.write('unknown command');
        process.exitCode = 1;
      }
    }
  } catch (e) {
    process.stderr.write(String(e && e.message ? e.message : e));
    process.exitCode = 2;
  } finally {
    rl.close();
    if (ctx) await ctx.close().catch(() => {});
    if (browser) await browser.close().catch(() => {});
  }
})();
''';
}
