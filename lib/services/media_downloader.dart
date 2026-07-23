import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'system_proxy.dart';

/// 一条媒体检索结果：视频/音频的元信息 + 已抽取的字幕正文。
class MediaHit {
  MediaHit({
    required this.id,
    required this.title,
    required this.url,
    required this.durationSec,
    required this.subtitleText,
  });

  final String id;
  final String title;
  final String url;
  final int durationSec;

  /// 从平台字幕/自动字幕抽取并去时间轴后的纯文本；无字幕时为空串。
  final String subtitleText;

  bool get hasSubtitle => subtitleText.trim().isNotEmpty;
}

/// yt-dlp + ffmpeg 的统一封装（整合 OmniGet / yt-dlp 的核心采集能力）。
///
/// 全工程唯一的媒体采集入口：二进制探测/释放、多站点检索、按 URL 提取（覆盖
/// yt-dlp 支持的 1800+ 站）、字幕抽取转文字、媒体文件下载都收敛到这里。新增
/// 「按主题找视频 / 下载音视频 / 抓字幕」的功能一律复用本类，不要再各处自拼
/// yt-dlp 的 `Process.run` 参数。
///
/// yt-dlp 子进程不会继承 Dart 侧的 [HttpOverrides] 代理，因此这里在 [_prepare]
/// 时探测系统代理，并通过 [_commonArgs] 给每次调用带上 `--proxy`。
///
/// 字幕优先策略：只抓取平台已有的人工/自动字幕并转成文字，不做本地语音转录(STT)。
/// 无字幕的音视频由调用方决定是否仅存文件 + 元数据笔记。
class MediaDownloader {
  MediaDownloader._();
  static final MediaDownloader instance = MediaDownloader._();

  /// 优先抓取的字幕语言（中文各变体优先，其次英文）。
  static const _subLangs = 'zh-Hans,zh-CN,zh,zh-Hant,zh-TW,en,en-US';

  /// 多站点关键词搜索默认引擎前缀：YouTube / Bilibili / SoundCloud。
  static const defaultSearchEngines = ['ytsearch', 'bilisearch', 'scsearch'];

  String? _ytDlp;
  String? _ffmpegDir;
  String? _proxy;
  Future<bool>? _preparing;

  /// 仅 Windows 打包了二进制。
  bool get available => Platform.isWindows;

  /// 探测到的系统代理（形如 `127.0.0.1:7897`），未启用为 null。
  String? get proxy => _proxy;

  /// 释放并校验二进制（幂等）。成功后 [_ytDlp]/[_ffmpegDir] 就绪。
  Future<bool> ready() {
    if (_ytDlp != null && _ffmpegDir != null) return Future.value(true);
    return _preparing ??= _prepare().whenComplete(() => _preparing = null);
  }

  Future<bool> _prepare() async {
    if (!Platform.isWindows) return false;
    Directory support;
    try {
      support = await getApplicationSupportDirectory();
    } catch (_) {
      return false;
    }
    final binDir = Directory(p.join(support.path, 'bin'));
    final yt = await _extract('assets/bin/windows/yt-dlp.exe', binDir, 'yt-dlp.exe');
    final ff = await _extract('assets/bin/windows/ffmpeg.exe', binDir, 'ffmpeg.exe');
    if (yt == null || ff == null) return false;
    _ytDlp = yt;
    _ffmpegDir = p.dirname(ff);
    _proxy = await SystemProxy.detect();
    return true;
  }

  /// 所有 yt-dlp 调用共用的参数：代理（若探测到）+ 静默/容错。
  /// 需要 ffmpeg 的调用（字幕转 srt、合流下载）再各自附加 `--ffmpeg-location`。
  List<String> _commonArgs() => [
        ..._proxyArgs(),
        '--ignore-errors',
        '--no-warnings',
        '--no-progress',
      ];

  /// yt-dlp 的 `--proxy` 参数需带协议前缀；系统代理只给出 `host:port`，这里补齐。
  List<String> _proxyArgs() {
    final proxy = _proxy;
    if (proxy == null || proxy.trim().isEmpty) return const [];
    var url = proxy.trim();
    if (!url.contains('://')) url = 'http://$url';
    return ['--proxy', url];
  }

  /// 多站点关键词并行搜索，返回命中的网页 URL 列表（已按引擎聚合，未去重）。
  ///
  /// 对每个引擎前缀跑一次 `PREFIXn:query` 的扁平检索，只打印落地 URL，
  /// 不下载、不抓元数据，尽量快地拿到一批候选交给后续按 URL 提取。
  Future<List<String>> searchUrls(
    String query, {
    List<String> engines = defaultSearchEngines,
    int perEngineLimit = 3,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    if (!await ready()) return const [];
    final lists = await Future.wait(
      engines.map((e) => _searchOne(e, query, perEngineLimit, timeout)),
    );
    return [for (final l in lists) ...l];
  }

  Future<List<String>> _searchOne(
    String engine,
    String query,
    int limit,
    Duration timeout,
  ) async {
    try {
      final r = await Process.run(
        _ytDlp!,
        [
          '$engine$limit:$query',
          '--flat-playlist',
          '--skip-download',
          '--print', '%(url)s',
          ..._commonArgs(),
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
      final urls = <String>[];
      for (final line in const LineSplitter().convert(r.stdout as String)) {
        final t = line.trim();
        if (t.startsWith('http')) urls.add(t);
      }
      return urls;
    } catch (_) {
      return const [];
    }
  }

  /// 探测任意 URL 是否可被 yt-dlp 提取（真正吃到 1800+ 站的关键）。
  /// 用 `--simulate` 只取首个条目的 id，exit 0 且拿到 id 即认为可提取。
  Future<bool> probeExtractable(
    String url, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (!await ready()) return false;
    try {
      final r = await Process.run(
        _ytDlp!,
        [
          url,
          '--simulate',
          '--no-playlist',
          '--playlist-items', '1',
          '--print', '%(id)s',
          ..._commonArgs(),
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
      return r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 常见媒体站主机白名单（命中即认为大概率可交给 yt-dlp 提取）。
  static const _mediaHosts = [
    'youtube.com', 'youtu.be', 'bilibili.com', 'b23.tv', 'vimeo.com',
    'dailymotion.com', 'tiktok.com', 'douyin.com', 'xiaohongshu.com',
    'xhslink.com', 'youku.com', 'iqiyi.com', 'v.qq.com', 'ted.com',
    'coursera.org', 'udemy.com', 'ximalaya.com', 'soundcloud.com',
    'twitter.com', 'x.com', 'twitch.tv', 'nicovideo.jp', 'facebook.com',
    'fb.watch', 'instagram.com', 'ixigua.com', 'music.163.com',
    'open.spotify.com',
  ];

  /// 明确不是媒体（学术库/代码库/百科/文档站）的主机，直接排除避免无谓探测。
  static const _nonMediaHosts = [
    'arxiv.org', 'openalex.org', 'europepmc.org', 'ncbi.nlm.nih.gov',
    'doi.org', 'github.com', 'gutenberg.org', 'wikipedia.org',
    'wikimedia.org', 'cnki.net', 'semanticscholar.org', 'researchgate.net',
  ];

  static const _docExts = [
    '.pdf', '.doc', '.docx', '.ppt', '.pptx', '.xls', '.xlsx',
    '.zip', '.rar', '.epub',
  ];

  /// 大概率是媒体页（主机命中媒体白名单）。
  static bool isLikelyMedia(String url) {
    final u = url.toLowerCase();
    return _mediaHosts.any((h) => u.contains(h));
  }

  /// 明确不是媒体（学术/代码/百科主机，或指向文档/压缩包）。
  static bool isNonMedia(String url) {
    final u = url.toLowerCase();
    if (_nonMediaHosts.any((h) => u.contains(h))) return true;
    final path = Uri.tryParse(u)?.path ?? u;
    return _docExts.any(path.endsWith);
  }

  /// 从一段文本（Markdown 正文/研究笔记）里抽取媒体链接（去重后返回）。
  static List<String> extractMediaUrls(String text) {
    final re = RegExp(r'''https?://[^\s\)\]"'<>，,）】]+''');
    final out = <String>{};
    for (final m in re.allMatches(text)) {
      final u = m.group(0)!;
      if (isLikelyMedia(u) && !isNonMedia(u)) out.add(u);
    }
    return out.toList();
  }

  /// 从 assets 释放单个二进制到 [binDir]（缺失或大小不一致才重写），返回落盘路径。
  Future<String?> _extract(String asset, Directory binDir, String exeName) async {
    try {
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await binDir.create(recursive: true);
      final out = File(p.join(binDir.path, exeName));
      if (!await out.exists() || (await out.length()) != bytes.length) {
        await out.writeAsBytes(bytes, flush: true);
      }
      return out.path;
    } catch (_) {
      return null;
    }
  }

  /// 抓取单个视频链接的字幕并转成文字（无字幕返回空串）。
  Future<MediaHit?> fetchSubtitleText(
    String url, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (!await ready()) return null;
    final tmp = await Directory.systemTemp.createTemp('mind_media_sub1_');
    try {
      final metaFile = File(p.join(tmp.path, '_index.tsv'));
      await Process.run(
        _ytDlp!,
        [
          url,
          '--no-playlist',
          '--skip-download',
          '--write-subs',
          '--write-auto-subs',
          '--sub-langs', _subLangs,
          '--convert-subs', 'srt',
          '--ffmpeg-location', _ffmpegDir!,
          ..._commonArgs(),
          '-o', p.join(tmp.path, '%(id)s.%(ext)s'),
          '--print-to-file',
          '%(id)s\t%(title)s\t%(webpage_url)s\t%(duration)s',
          metaFile.path,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
      if (!await metaFile.exists()) return null;
      final hits = _collectHits(tmp, await metaFile.readAsString());
      return hits.isEmpty ? null : hits.first;
    } on TimeoutException {
      return null;
    } finally {
      _cleanup(tmp);
    }
  }

  /// 下载单个链接的媒体文件到 [destDir]，返回落盘文件路径（失败返回 null）。
  ///
  /// [audioOnly] 为 true 时抽取音频为 m4a，否则下载最佳画质并合流为 mp4。
  Future<String?> download(
    String url,
    Directory destDir, {
    bool audioOnly = false,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    if (!await ready()) return null;
    await destDir.create(recursive: true);
    final before = await _listFiles(destDir);
    try {
      final result = await Process.run(
        _ytDlp!,
        [
          url,
          '--no-playlist',
          '--ffmpeg-location', _ffmpegDir!,
          ..._commonArgs(),
          '--restrict-filenames',
          if (audioOnly) ...[
            '-x',
            '--audio-format', 'm4a',
          ] else ...[
            '-f', 'bv*+ba/b',
            '--merge-output-format', 'mp4',
          ],
          '-o', p.join(destDir.path, '%(title).80B.%(ext)s'),
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
      if (result.exitCode != 0) return null;
      final after = await _listFiles(destDir);
      final added = after.where((f) => !before.contains(f)).toList()
        ..sort((a, b) => File(b).lengthSync().compareTo(File(a).lengthSync()));
      return added.isEmpty ? null : added.first;
    } on TimeoutException {
      return null;
    }
  }

  Future<Set<String>> _listFiles(Directory dir) async {
    if (!await dir.exists()) return {};
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .toSet();
  }

  /// 解析元数据 TSV，并为每条匹配本地字幕文件、转成纯文本。
  List<MediaHit> _collectHits(Directory dir, String tsv) {
    final srtByPrefix = <String, List<File>>{};
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path).toLowerCase();
      if (!name.endsWith('.srt') && !name.endsWith('.vtt')) continue;
      final id = name.split('.').first;
      srtByPrefix.putIfAbsent(id, () => []).add(entity);
    }
    final hits = <MediaHit>[];
    for (final line in const LineSplitter().convert(tsv)) {
      final cols = line.split('\t');
      if (cols.length < 3) continue;
      final id = cols[0].trim();
      final title = cols[1].trim();
      final url = cols[2].trim();
      final duration = cols.length > 3 ? int.tryParse(cols[3].trim()) ?? 0 : 0;
      final sub = _bestSubtitle(srtByPrefix[id.toLowerCase()] ?? const []);
      hits.add(MediaHit(
        id: id,
        title: title,
        url: url,
        durationSec: duration,
        subtitleText: sub,
      ));
    }
    return hits;
  }

  /// 从同一视频的多个字幕文件里挑最优语言并转文字。
  String _bestSubtitle(List<File> files) {
    if (files.isEmpty) return '';
    int rank(String path) {
      final n = p.basename(path).toLowerCase();
      if (n.contains('.zh-hans') || n.contains('.zh-cn') || n.contains('.zh.')) {
        return 0;
      }
      if (n.contains('.zh')) return 1;
      if (n.contains('.en')) return 2;
      return 3;
    }

    final sorted = [...files]..sort((a, b) => rank(a.path).compareTo(rank(b.path)));
    for (final f in sorted) {
      try {
        final text = _subtitleToText(f.readAsStringSync());
        if (text.trim().isNotEmpty) return text;
      } catch (_) {}
    }
    return '';
  }

  /// 把 SRT / VTT 字幕转成连续纯文本：去序号、去时间轴、去标签、合并连续重复行。
  static String _subtitleToText(String raw) {
    final tsRe = RegExp(r'-->');
    final indexRe = RegExp(r'^\d+$');
    final tagRe = RegExp(r'<[^>]*>');
    final out = <String>[];
    String? last;
    for (var line in const LineSplitter().convert(raw)) {
      line = line.trim();
      if (line.isEmpty) continue;
      if (line == 'WEBVTT' || line.startsWith('WEBVTT')) continue;
      if (line.startsWith('Kind:') || line.startsWith('Language:')) continue;
      if (tsRe.hasMatch(line)) continue;
      if (indexRe.hasMatch(line)) continue;
      var text = line.replaceAll(tagRe, '').trim();
      // 去掉 VTT 内联的对齐/位置注记残留。
      text = text.replaceAll(RegExp(r'align:\S+|position:\S+'), '').trim();
      if (text.isEmpty) continue;
      // 自动字幕常有整行滚动重复，合并连续相同行。
      if (text == last) continue;
      out.add(text);
      last = text;
    }
    return out.join(' ');
  }

  void _cleanup(Directory dir) {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
