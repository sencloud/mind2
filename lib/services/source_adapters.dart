import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'headless_browser.dart';

/// 固定可靠源站标识。
enum SourceId {
  zotero,
  arxiv,
  openalex,
  europepmc,
  cnki,
  github,
  gutenberg,
  commons,
  web,
}

class ResearchSourceProfile {
  const ResearchSourceProfile({
    required this.id,
    required this.label,
    required this.description,
    required this.preferredSources,
    this.siteQueries = const [],
    this.requiresBrowserSites = const [],
  });

  final String id;
  final String label;
  final String description;
  final List<SourceId> preferredSources;

  /// Web 查询模板。`{query}` 会被替换为主题或缺口查询。
  final List<String> siteQueries;

  /// 这些站点通常需要点击进入、执行 JS 或登录后才能读到有效内容。
  final List<String> requiresBrowserSites;
}

const researchSourceProfiles = [
  ResearchSourceProfile(
    id: 'ai_cs_engineering',
    label: 'AI/CS/工程实现',
    description: '论文、开源实现、benchmark、工程方案和 Papers with Code。',
    preferredSources: [SourceId.arxiv, SourceId.openalex, SourceId.github],
    siteQueries: [],
    requiresBrowserSites: [
      'dl.acm.org',
      'ieeexplore.ieee.org',
      'scholar.google.com',
    ],
  ),
  ResearchSourceProfile(
    id: 'biomedicine',
    label: '医学/生命科学',
    description: 'PubMed、Europe PMC、临床试验、WHO/FDA 等证据来源。',
    preferredSources: [SourceId.europepmc, SourceId.openalex, SourceId.web],
    siteQueries: [
      '{query} site:pubmed.ncbi.nlm.nih.gov',
      '{query} site:clinicaltrials.gov',
      '{query} site:who.int',
      '{query} site:fda.gov',
    ],
  ),
  ResearchSourceProfile(
    id: 'chinese_academic',
    label: '中文学术',
    description: '中文期刊、硕博论文、会议论文和国内研究现状。',
    preferredSources: [SourceId.cnki, SourceId.web, SourceId.openalex],
    siteQueries: [
      '{query} site:kns.cnki.net',
      '{query} site:wanfangdata.com.cn',
      '{query} site:cqvip.com',
      '{query} site:nssd.cn',
    ],
    requiresBrowserSites: ['kns.cnki.net', 'wanfangdata.com.cn', 'cqvip.com'],
  ),
  ResearchSourceProfile(
    id: 'policy_standards',
    label: '政策/标准/行业报告',
    description: '政府、标准机构、监管部门和行业协会发布的规范与报告。',
    preferredSources: [SourceId.web, SourceId.cnki, SourceId.openalex],
    siteQueries: [
      '{query} site:gov.cn',
      '{query} site:miit.gov.cn',
      '{query} site:samr.gov.cn',
      '{query} site:std.samr.gov.cn',
      '{query} site:iso.org',
      '{query} site:iec.ch',
      '{query} site:ieee.org',
    ],
    requiresBrowserSites: ['std.samr.gov.cn', 'iso.org', 'iec.ch'],
  ),
  ResearchSourceProfile(
    id: 'finance_economy',
    label: '金融/经济/公司',
    description: '宏观经济、金融市场、公司披露和国际组织数据。',
    preferredSources: [SourceId.web, SourceId.openalex],
    siteQueries: [
      '{query} site:sec.gov',
      '{query} site:fred.stlouisfed.org',
      '{query} site:worldbank.org',
      '{query} site:imf.org',
      '{query} site:oecd.org',
      '{query} site:stats.gov.cn',
    ],
  ),
  ResearchSourceProfile(
    id: 'law_regulation',
    label: '法律/法规',
    description: '法律法规、司法解释、法院公开资料和裁判文书。',
    preferredSources: [SourceId.web, SourceId.cnki],
    siteQueries: [
      '{query} site:npc.gov.cn',
      '{query} site:moj.gov.cn',
      '{query} site:court.gov.cn',
      '{query} site:wenshu.court.gov.cn',
      '{query} site:pkulaw.com',
    ],
    requiresBrowserSites: ['wenshu.court.gov.cn', 'pkulaw.com'],
  ),
  ResearchSourceProfile(
    id: 'code_security',
    label: '代码/安全',
    description: '代码实现、安全漏洞、攻防资料和官方安全公告。',
    preferredSources: [SourceId.github, SourceId.web],
    siteQueries: [
      '{query} site:gitlab.com',
      '{query} site:grep.app',
      '{query} site:nvd.nist.gov',
      '{query} site:cve.org',
      '{query} site:owasp.org',
      '{query} site:cisa.gov',
    ],
  ),
  ResearchSourceProfile(
    id: 'books_humanities',
    label: '书籍/人文',
    description: '书籍、档案、公共图书馆和人文资料。',
    preferredSources: [SourceId.gutenberg, SourceId.web, SourceId.openalex],
    siteQueries: [
      '{query} site:archive.org',
      '{query} site:worldcat.org',
      '{query} site:douban.com',
      '{query} site:ucdrs.superlib.net',
    ],
    requiresBrowserSites: ['douban.com', 'ucdrs.superlib.net'],
  ),
];

ResearchSourceProfile? researchProfileFromString(String id) {
  final key = id.trim().toLowerCase();
  for (final p in researchSourceProfiles) {
    if (p.id == key) return p;
  }
  return null;
}

extension SourceIdInfo on SourceId {
  String get id => name;

  String get label => switch (this) {
    SourceId.zotero => '我的 Zotero 文库',
    SourceId.arxiv => 'arXiv 论文',
    SourceId.openalex => 'OpenAlex 论文',
    SourceId.europepmc => 'Europe PMC 论文',
    SourceId.cnki => '知网 CNKI（引用/手动下载）',
    SourceId.github => 'GitHub 开源项目',
    SourceId.gutenberg => 'Project Gutenberg 电子书',
    SourceId.commons => 'Wikimedia 图片/媒体',
    SourceId.web => '通用网页(浏览器搜索)',
  };

  /// 给 AI 看的能力说明。
  String get desc => switch (this) {
    SourceId.zotero => '用户本地 Zotero 已收藏文献（优先复用，无需重复下载）。',
    SourceId.arxiv => '英文学术论文（人工智能、计算机、物理、统计、数学等），返回 PDF 与论文摘要。检索词用英文关键词。',
    SourceId.openalex => '跨学科学术论文，覆盖最广，返回开放获取 PDF。检索词用英文关键词。',
    SourceId.europepmc => '生物医学与生命科学开放获取论文，返回 PDF。检索词用英文关键词。',
    SourceId.cnki =>
      '中文学术论文、期刊、硕博论文、会议论文等知网线索。检索词用中文；详情页需用 Playwright 点击进入读取可见摘要，全文仍按机构权限手动下载。',
    SourceId.github =>
      '开源代码项目与工程实现，返回仓库简介、Star 数、主语言、链接。研究“如何实现/工程方案”类问题必选。检索词用英文。',
    SourceId.gutenberg => '公版经典书籍（多为英文），返回 PDF/EPUB/TXT。',
    SourceId.commons => '维基共享资源的图片、示意图、照片、媒体素材。',
    SourceId.web =>
      '通用网页（用浏览器驱动 Bing 搜索并翻页抓取真实结果链接与可下载文件），用于中文标准、政策、行业报告等其他来源。检索词用中文。',
  };
}

SourceId? sourceFromString(String s) {
  for (final v in SourceId.values) {
    if (v.name == s.trim().toLowerCase()) return v;
  }
  return null;
}

/// 一条检索结果。`ext` 为空表示这是引用（如 GitHub 项目），不下载文件。
class SourceResult {
  SourceResult({
    required this.title,
    required this.url,
    required this.source,
    this.year = '',
    this.authors = '',
    this.ext = 'pdf',
    this.summary = '',
    this.landingUrl,
  });

  final String title;
  final String url;
  final SourceId source;
  final String year;
  final String authors;
  final String ext;
  final String summary;
  final String? landingUrl;

  bool get downloadable => ext.isNotEmpty;
}

abstract class SourceAdapter {
  SourceId get sourceId;
  Future<List<SourceResult>> search(String query, {int limit = 5});

  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';

  static String unescapeXml(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

class ArxivAdapter extends SourceAdapter {
  @override
  SourceId get sourceId => SourceId.arxiv;

  @override
  Future<List<SourceResult>> search(String query, {int limit = 5}) async {
    final uri = Uri.parse(
      'https://export.arxiv.org/api/query?search_query=all:${Uri.encodeQueryComponent(query)}&start=0&max_results=$limit',
    );
    final resp = await http
        .get(uri, headers: {'User-Agent': SourceAdapter.userAgent})
        .timeout(const Duration(seconds: 25));
    if (resp.statusCode != 200) return [];
    final xml = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final out = <SourceResult>[];
    for (final m in RegExp(r'<entry>([\s\S]*?)</entry>').allMatches(xml)) {
      final e = m.group(1)!;
      final title = SourceAdapter.unescapeXml(
        RegExp(r'<title>([\s\S]*?)</title>').firstMatch(e)?.group(1) ?? '',
      );
      final id =
          RegExp(r'<id>([\s\S]*?)</id>').firstMatch(e)?.group(1)?.trim() ?? '';
      if (title.isEmpty || !id.contains('/abs/')) continue;
      final absId = id.split('/abs/').last;
      final year = RegExp(r'<published>(\d{4})').firstMatch(e)?.group(1) ?? '';
      final authors = RegExp(
        r'<name>([\s\S]*?)</name>',
      ).allMatches(e).map((a) => a.group(1)!.trim()).take(3).join(', ');
      final summary = SourceAdapter.unescapeXml(
        RegExp(r'<summary>([\s\S]*?)</summary>').firstMatch(e)?.group(1) ?? '',
      );
      out.add(
        SourceResult(
          title: title,
          url: 'https://arxiv.org/pdf/$absId.pdf',
          source: SourceId.arxiv,
          year: year,
          authors: authors,
          ext: 'pdf',
          summary: summary.length > 400 ? summary.substring(0, 400) : summary,
          landingUrl: 'https://arxiv.org/abs/$absId',
        ),
      );
    }
    return out;
  }
}

class OpenAlexAdapter extends SourceAdapter {
  @override
  SourceId get sourceId => SourceId.openalex;

  @override
  Future<List<SourceResult>> search(String query, {int limit = 5}) async {
    final uri = Uri.parse(
      'https://api.openalex.org/works?search=${Uri.encodeQueryComponent(query)}'
      '&filter=open_access.is_oa:true&per_page=$limit&mailto=secondbrain@example.com',
    );
    final resp = await http
        .get(uri, headers: {'User-Agent': SourceAdapter.userAgent})
        .timeout(const Duration(seconds: 25));
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map;
    final results = data['results'];
    if (results is! List) return [];
    final out = <SourceResult>[];
    for (final r in results) {
      if (r is! Map) continue;
      final pdf = (r['best_oa_location'] as Map?)?['pdf_url'] as String?;
      if (pdf == null || pdf.isEmpty) continue;
      final title = (r['display_name'] as String? ?? '').trim();
      if (title.isEmpty) continue;
      final authors = ((r['authorships'] as List?) ?? [])
          .take(3)
          .map((a) => ((a as Map)['author'] as Map?)?['display_name'])
          .whereType<String>()
          .join(', ');
      out.add(
        SourceResult(
          title: title,
          url: pdf,
          source: SourceId.openalex,
          year: '${r['publication_year'] ?? ''}',
          authors: authors,
          ext: 'pdf',
          landingUrl: r['doi'] as String?,
        ),
      );
    }
    return out;
  }
}

class EuropePmcAdapter extends SourceAdapter {
  @override
  SourceId get sourceId => SourceId.europepmc;

  @override
  Future<List<SourceResult>> search(String query, {int limit = 5}) async {
    final uri = Uri.parse(
      'https://www.ebi.ac.uk/europepmc/webservices/rest/search'
      '?query=${Uri.encodeQueryComponent('$query AND OPEN_ACCESS:Y AND HAS_PDF:Y')}'
      '&format=json&resultType=core&pageSize=$limit',
    );
    final resp = await http
        .get(uri, headers: {'User-Agent': SourceAdapter.userAgent})
        .timeout(const Duration(seconds: 25));
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map;
    final results = (data['resultList'] as Map?)?['result'];
    if (results is! List) return [];
    final out = <SourceResult>[];
    for (final r in results) {
      if (r is! Map) continue;
      final title = (r['title'] as String? ?? '').trim();
      final pmcid = r['pmcid'] as String?;
      String? pdf;
      final urls = (r['fullTextUrlList'] as Map?)?['fullTextUrl'];
      if (urls is List) {
        for (final u in urls) {
          if (u is Map &&
              (u['documentStyle'] as String?)?.toLowerCase() == 'pdf') {
            pdf = u['url'] as String?;
            break;
          }
        }
      }
      pdf ??= pmcid != null
          ? 'https://europepmc.org/articles/$pmcid?pdf=render'
          : null;
      if (title.isEmpty || pdf == null) continue;
      out.add(
        SourceResult(
          title: title,
          url: pdf,
          source: SourceId.europepmc,
          year: '${r['pubYear'] ?? ''}',
          authors: (r['authorString'] as String? ?? '').trim(),
          ext: 'pdf',
          landingUrl: pmcid != null
              ? 'https://europepmc.org/article/PMC/$pmcid'
              : null,
        ),
      );
    }
    return out;
  }
}

class CnkiAdapter extends SourceAdapter {
  @override
  SourceId get sourceId => SourceId.cnki;

  @override
  Future<List<SourceResult>> search(String query, {int limit = 5}) async {
    if (!_looksChinese(query) ||
        !_hasMeaningfulChineseQuery(query) ||
        _looksLikeBadCnkiQuery(query)) {
      return [];
    }
    final out = <SourceResult>[];
    final seen = <String>{};
    final cnkiSearch =
        'https://kns.cnki.net/kns8s/defaultresult/index?kw=${Uri.encodeQueryComponent(query)}';
    try {
      final uri = Uri.parse(
        'https://www.bing.com/search?q=${Uri.encodeQueryComponent('site:kns.cnki.net/kcms/detail $query')}&setlang=zh-CN&count=20',
      );
      final resp = await http
          .get(uri, headers: {'User-Agent': SourceAdapter.userAgent})
          .timeout(const Duration(seconds: 25));
      if (resp.statusCode == 200) {
        final html = utf8.decode(resp.bodyBytes, allowMalformed: true);
        for (final m in RegExp(
          r'<h2[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*>([\s\S]*?)</a>',
          caseSensitive: false,
        ).allMatches(html)) {
          final url = HeadlessWebAdapter.decodeBingRedirect(
            SourceAdapter.unescapeXml(m.group(1)!),
          );
          final title = SourceAdapter.unescapeXml(
            m.group(2)!.replaceAll(RegExp(r'<[^>]+>'), ''),
          );
          if (title.isEmpty ||
              !url.startsWith('http') ||
              !url.contains('cnki.net') ||
              !seen.add(url)) {
            continue;
          }
          out.add(
            SourceResult(
              title: title,
              url: url,
              source: SourceId.cnki,
              ext: '',
              summary: '知网检索线索：需打开链接后按机构权限手动下载全文。',
              landingUrl: url,
            ),
          );
          if (out.length >= limit) return out;
        }
      }
    } catch (_) {}

    // 搜索引擎未给出可解析条目时，至少登记知网检索入口，便于手动打开继续下载。
    out.add(
      SourceResult(
        title: '知网检索：$query',
        url: cnkiSearch,
        source: SourceId.cnki,
        ext: '',
        summary: '打开知网检索页后，可按机构权限筛选、引用并手动下载全文。',
        landingUrl: cnkiSearch,
      ),
    );
    return out.take(limit).toList();
  }

  static bool _looksChinese(String value) =>
      RegExp(r'[\u4e00-\u9fa5]').hasMatch(value);

  static bool _hasMeaningfulChineseQuery(String query) {
    final chinese = RegExp(
      r'[\u4e00-\u9fa5]+',
    ).allMatches(query).map((m) => m.group(0)!).join();
    final meaningful = chinese.replaceAll(
      RegExp(r'(知网检索|综述|研究|引用|手动|下载|打开|链接|机构|权限|中文|学术|线索|方案|标准)'),
      '',
    );
    return meaningful.length >= 2;
  }

  static bool _looksLikeBadCnkiQuery(String query) {
    final normalized = query
        .replaceAll(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9]+'), '')
        .toLowerCase();
    const bad = {'知网检索', '综述研究', '引用手动下载', '手动下载', '打开链接', '机构权限', '中文学术线索'};
    return normalized.isEmpty || bad.contains(normalized);
  }
}

class GitHubAdapter extends SourceAdapter {
  @override
  SourceId get sourceId => SourceId.github;

  @override
  Future<List<SourceResult>> search(String query, {int limit = 5}) async {
    final uri = Uri.parse(
      'https://api.github.com/search/repositories?q=${Uri.encodeQueryComponent(query)}'
      '&sort=stars&order=desc&per_page=$limit',
    );
    final resp = await http
        .get(
          uri,
          headers: {
            'User-Agent': SourceAdapter.userAgent,
            'Accept': 'application/vnd.github+json',
          },
        )
        .timeout(const Duration(seconds: 25));
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map;
    final items = data['items'];
    if (items is! List) return [];
    final out = <SourceResult>[];
    for (final r in items.take(limit)) {
      if (r is! Map) continue;
      final name = (r['full_name'] as String? ?? '').trim();
      final htmlUrl = r['html_url'] as String?;
      if (name.isEmpty || htmlUrl == null) continue;
      final stars = r['stargazers_count'] ?? 0;
      final lang = r['language'] as String? ?? '';
      final desc = (r['description'] as String? ?? '').trim();
      out.add(
        SourceResult(
          title: name,
          url: htmlUrl,
          source: SourceId.github,
          ext: '', // 引用，不下载
          summary:
              '★$stars${lang.isEmpty ? '' : ' · $lang'}${desc.isEmpty ? '' : ' · $desc'}',
          landingUrl: htmlUrl,
        ),
      );
    }
    return out;
  }
}

class GutenbergAdapter extends SourceAdapter {
  @override
  SourceId get sourceId => SourceId.gutenberg;

  @override
  Future<List<SourceResult>> search(String query, {int limit = 5}) async {
    final uri = Uri.parse(
      'https://gutendex.com/books?search=${Uri.encodeQueryComponent(query)}',
    );
    final resp = await http
        .get(uri, headers: {'User-Agent': SourceAdapter.userAgent})
        .timeout(const Duration(seconds: 25));
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map;
    final results = data['results'];
    if (results is! List) return [];
    final out = <SourceResult>[];
    for (final r in results.take(limit)) {
      if (r is! Map) continue;
      final title = (r['title'] as String? ?? '').trim();
      final formats = r['formats'] as Map?;
      if (title.isEmpty || formats == null) continue;
      String? url;
      String ext = 'txt';
      for (final entry in {
        'application/pdf': 'pdf',
        'application/epub+zip': 'epub',
        'text/plain; charset=utf-8': 'txt',
        'text/plain': 'txt',
      }.entries) {
        final u = formats[entry.key] as String?;
        if (u != null && !u.endsWith('.zip')) {
          url = u;
          ext = entry.value;
          break;
        }
      }
      if (url == null) continue;
      final authors = ((r['authors'] as List?) ?? [])
          .map((a) => (a as Map)['name'])
          .whereType<String>()
          .take(2)
          .join(', ');
      out.add(
        SourceResult(
          title: title,
          url: url,
          source: SourceId.gutenberg,
          authors: authors,
          ext: ext,
        ),
      );
    }
    return out;
  }
}

class CommonsAdapter extends SourceAdapter {
  @override
  SourceId get sourceId => SourceId.commons;

  static const _extByMime = {
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/gif': 'gif',
    'image/svg+xml': 'svg',
    'image/webp': 'webp',
    'image/tiff': 'tif',
    'video/webm': 'webm',
    'video/mp4': 'mp4',
    'application/pdf': 'pdf',
  };

  @override
  Future<List<SourceResult>> search(String query, {int limit = 5}) async {
    final uri = Uri.parse(
      'https://commons.wikimedia.org/w/api.php?action=query&generator=search'
      '&gsrsearch=${Uri.encodeQueryComponent(query)}&gsrnamespace=6&gsrlimit=$limit'
      '&prop=imageinfo&iiprop=url|mime|size&format=json',
    );
    final resp = await http
        .get(uri, headers: {'User-Agent': SourceAdapter.userAgent})
        .timeout(const Duration(seconds: 25));
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map;
    final pages = (data['query'] as Map?)?['pages'];
    if (pages is! Map) return [];
    final out = <SourceResult>[];
    for (final p in pages.values) {
      if (p is! Map) continue;
      final info = (p['imageinfo'] as List?)?.firstOrNull;
      if (info is! Map) continue;
      final url = info['url'] as String?;
      final mime = info['mime'] as String? ?? '';
      if (url == null) continue;
      final ext =
          _extByMime[mime] ??
          (url.contains('.') ? url.split('.').last.toLowerCase() : 'jpg');
      var title = (p['title'] as String? ?? '').replaceFirst('File:', '');
      out.add(
        SourceResult(
          title: title.isEmpty ? url.split('/').last : title,
          url: url,
          source: SourceId.commons,
          ext: ext.length > 5 ? 'jpg' : ext,
        ),
      );
    }
    return out;
  }
}

/// 通过系统无头浏览器渲染 JS 页面，抓取真实可下载的文件直链（PDF 等）。
class HeadlessWebAdapter extends SourceAdapter {
  @override
  SourceId get sourceId => SourceId.web;

  static bool get available => HeadlessBrowser.available;

  /// 用无头浏览器渲染页面并返回 DOM HTML。
  static Future<String?> renderDom(String url) => HeadlessBrowser.renderDom(url);

  static String decodeBingRedirect(String href) {
    final m = RegExp(r'[?&]u=a1([A-Za-z0-9_-]+)').firstMatch(href);
    if (m == null) return href;
    try {
      var b64 = m.group(1)!.replaceAll('-', '+').replaceAll('_', '/');
      while (b64.length % 4 != 0) {
        b64 += '=';
      }
      final real = utf8.decode(base64.decode(b64), allowMalformed: true);
      return real.startsWith('http') ? real : href;
    } catch (_) {
      return href;
    }
  }

  @override
  Future<List<SourceResult>> search(String query, {int limit = 5}) async {
    if (!available) return [];
    final dom = await renderDom(
      'https://www.bing.com/search?q=${Uri.encodeQueryComponent(query)}&setlang=zh-CN&count=20',
    );
    if (dom == null) return [];
    final out = <SourceResult>[];
    final seen = <String>{};

    // 1) 网页搜索结果（标题 + 链接），保存为 HTML。
    for (final m in RegExp(
      r'<h2[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*>([\s\S]*?)</a>',
      caseSensitive: false,
    ).allMatches(dom)) {
      var url = decodeBingRedirect(SourceAdapter.unescapeXml(m.group(1)!));
      final title = SourceAdapter.unescapeXml(
        m.group(2)!.replaceAll(RegExp(r'<[^>]+>'), ''),
      );
      if (!url.startsWith('http') ||
          url.contains('bing.com') ||
          url.contains('microsoft.com') ||
          title.isEmpty) {
        continue;
      }
      if (!seen.add(url)) continue;
      final isPdf = url.toLowerCase().contains('.pdf');
      out.add(
        SourceResult(
          title: title,
          url: url,
          source: SourceId.web,
          ext: isPdf ? 'pdf' : 'html',
          landingUrl: url,
        ),
      );
      if (out.length >= limit) break;
    }

    // 2) 页面里直接出现的 PDF 直链作为补充。
    for (final m in RegExp(
      r'https?://[^"<>\s\\)）]+?\.pdf',
      caseSensitive: false,
    ).allMatches(dom)) {
      if (out.length >= limit) break;
      final u = SourceAdapter.unescapeXml(m.group(0)!);
      if (u.contains('bing.com') || u.contains('microsoft.com')) continue;
      if (!seen.add(u)) continue;
      out.add(
        SourceResult(
          title: Uri.decodeComponent(
            u
                .split('/')
                .last
                .replaceAll(RegExp(r'\.pdf$', caseSensitive: false), ''),
          ),
          url: u,
          source: SourceId.web,
          ext: 'pdf',
          landingUrl: u,
        ),
      );
    }
    return out;
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
