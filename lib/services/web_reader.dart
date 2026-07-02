import 'dart:convert';

import 'package:http/http.dart' as http;

/// 共享的网页正文读取器。
///
/// 借鉴 Agent-Reach 的做法：把目标 URL 前缀上 https://r.jina.ai/ ，即可用
/// Jina Reader 把任意网页转成「清洗后的 Markdown 正文」——免 API Key、免本地
/// 浏览器，自动去掉导航/广告/脚本。
///
/// 这是一个跨模块共享能力：主题研究、Agent 的 read_url 工具、（未来）聊天等
/// 都复用本类，避免各处各自重复实现网页抓取逻辑。
class WebReader {
  // 统一的 User-Agent，避免被部分站点按爬虫拦截。供直链下载等场景复用。
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';

  /// 读取网页正文，返回清洗后的 Markdown。
  /// 非 200 或正文过短（疑似没抓到内容）时返回 null，由调用方决定后续处理。
  Future<String?> readMarkdown(
    String url, {
    Duration timeout = const Duration(seconds: 40),
  }) async {
    // 容忍用户没写协议头的情况（如 example.com）。
    final target = url.startsWith('http') ? url : 'https://$url';
    try {
      final resp = await http
          .get(
            Uri.parse('https://r.jina.ai/$target'),
            headers: {
              'User-Agent': userAgent,
              'Accept': 'text/plain',
              'X-Return-Format': 'markdown',
            },
          )
          .timeout(timeout);
      if (resp.statusCode != 200) return null;
      final text = utf8.decode(resp.bodyBytes, allowMalformed: true).trim();
      return text.length < 80 ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// 从 Jina/Markdown 文本里取标题：Jina Reader 输出首部通常是 `Title: xxx`，
  /// 普通 Markdown 取第一个一级标题。取不到返回 null。
  String? titleFromMarkdown(String text) {
    for (final line in const LineSplitter().convert(text)) {
      final t = line.trim();
      if (t.startsWith('Title:')) return t.substring(6).trim();
      if (t.startsWith('# ')) return t.substring(2).trim();
    }
    return null;
  }
}
