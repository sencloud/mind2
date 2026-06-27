import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// 纯文本类文件的应用内预览：
/// - Markdown（.md/.markdown）渲染为富文本
/// - 其他文本（txt/csv/json/xml/代码等）用等宽字体显示
class TextPreview extends StatefulWidget {
  const TextPreview({super.key, required this.path, required this.isMarkdown});

  final String path;
  final bool isMarkdown;

  @override
  State<TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<TextPreview> {
  String? _content;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TextPreview old) {
    super.didUpdateWidget(old);
    // 切换到另一个文件时重新读取内容。
    if (old.path != widget.path) _load();
  }

  Future<void> _load() async {
    setState(() {
      _content = null;
      _error = null;
    });
    try {
      final file = File(widget.path);
      final length = await file.length();
      // 超大文本只读取前 2MB，避免卡顿。
      const limit = 2 * 1024 * 1024;
      String text;
      if (length > limit) {
        final raw = await file.openRead(0, limit).expand((x) => x).toList();
        text = '${String.fromCharCodes(raw)}\n\n…（文件较大，仅预览前 2MB）';
      } else {
        text = await file.readAsString();
      }
      if (mounted) setState(() => _content = text);
    } catch (e) {
      if (mounted) setState(() => _error = '无法读取文本：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(_error!,
            style: const TextStyle(fontSize: 13, color: Color(0xFF9B9B9F))),
      );
    }
    if (_content == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.isMarkdown) {
      return Markdown(
        data: _content!,
        padding: const EdgeInsets.all(24),
        styleSheet: MarkdownStyleSheet(
          p: const TextStyle(fontSize: 14, height: 1.7),
          h2: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: SelectableText(
        _content!,
        style: const TextStyle(
            fontSize: 13, height: 1.6, fontFamily: 'Consolas'),
      ),
    );
  }
}
