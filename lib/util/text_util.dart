/// 跨模块复用的纯文本工具：字符串裁剪与文件名清洗。
///
/// 统一取代过去散落在各 service / UI 里自写的 `_clip` / `_clipText` /
/// `_clipForPrompt` / `_sanitize` 等重复实现。新增功能一律复用这里，
/// 不要再在各文件里重造轮子。
library;

/// 把字符串裁剪到至多 [max] 个字符。超长时截断并可追加 [suffix]（如 '…'
/// 或「（已截断）」提示）。不超长则原样返回。
String clip(String s, int max, {String suffix = ''}) {
  if (s.length <= max) return s;
  return '${s.substring(0, max)}$suffix';
}

/// 把任意文本清洗成安全的文件名：去掉非法字符、限制长度，空则回退到 [fallback]。
String sanitizeFileName(
  String s, {
  int maxLen = 80,
  String fallback = '未命名',
}) {
  var out = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
  if (out.length > maxLen) out = out.substring(0, maxLen).trim();
  return out.isEmpty ? fallback : out;
}
