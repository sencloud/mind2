import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../code_view.dart';

/// 带「源码引用」的 Markdown 渲染组件：
/// 正文里 [lib/main.dart](ref:lib/main.dart) 形式的链接会被解析为工程内文件，
/// 点击后弹出 `FileContentView` 查看器打开该文件；普通 http(s) 链接走系统浏览器。
class RefMarkdown extends StatelessWidget {
  const RefMarkdown({
    super.key,
    required this.data,
    required this.projectPath,
    this.selectable = true,
  });

  final String data;

  /// 工程根目录（ref: 相对路径的解析基准）。
  final String projectPath;
  final bool selectable;

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      width: 420,
    ));
  }

  /// 解析 ref: 链接目标为工程内绝对路径；容忍 `:行号` 后缀；找不到返回 null。
  static String? resolveRef(String projectPath, String href) {
    var rel = href.startsWith('ref:') ? href.substring(4) : href;
    rel = rel.trim().replaceAll('\\', '/');
    // 去掉可能的 :行号 后缀（如 lib/main.dart:56）。
    final m = RegExp(r'^(.*?):(\d+)$').firstMatch(rel);
    if (m != null) rel = m.group(1)!;
    if (rel.isEmpty) return null;
    final abs = p.normalize(p.join(projectPath, rel.replaceAll('/', p.separator)));
    // 防目录穿越：解析结果必须仍在工程内。
    if (!p.isWithin(projectPath, abs) && !p.equals(projectPath, abs)) {
      return null;
    }
    if (File(abs).existsSync()) return abs;
    return null;
  }

  /// 打开工程内文件查看弹窗。
  static void openFile(BuildContext context, String absPath) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 6, 8),
                child: Row(
                  children: [
                    const Icon(Icons.description_outlined,
                        size: 16, color: Color(0xFF0D9488)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(p.basename(absPath),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w600)),
                    ),
                    Text(absPath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10.5, color: Color(0xFF9B9B9F))),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFFECECEE)),
              Flexible(
                child: FileContentView(
                    key: ValueKey(absPath), absPath: absPath),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onTapLink(BuildContext context, String? href) {
    if (href == null || href.isEmpty) return;
    if (href.startsWith('http://') || href.startsWith('https://')) {
      launchUrl(Uri.parse(href));
      return;
    }
    final abs = resolveRef(projectPath, href);
    if (abs != null) {
      openFile(context, abs);
    } else {
      _toast(context, '未在工程中找到该文件（可能为推断引用）');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: data,
      selectable: selectable,
      onTapLink: (text, href, title) => _onTapLink(context, href),
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(fontSize: 13, height: 1.65),
        listBullet: const TextStyle(fontSize: 13, height: 1.65),
        h1: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        h2: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        h3: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        code: const TextStyle(
            fontSize: 12.5,
            fontFamily: 'Consolas',
            fontFamilyFallback: ['monospace'],
            backgroundColor: Color(0xFFF2F2F4)),
        a: const TextStyle(
            color: Color(0xFF0D9488),
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline),
        blockquoteDecoration: BoxDecoration(
          color: const Color(0xFFF7F7F8),
          borderRadius: BorderRadius.circular(6),
          border: const Border(
              left: BorderSide(color: Color(0xFF0D9488), width: 3)),
        ),
      ),
    );
  }
}
