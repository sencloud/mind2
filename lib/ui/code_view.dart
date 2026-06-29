import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight.dart' show highlight;
import 'package:highlight/languages/all.dart' show allLanguages;
import 'package:path/path.dart' as p;

bool _registered = false;
void _ensureRegistered() {
  if (_registered) return;
  highlight.registerLanguages(allLanguages);
  _registered = true;
}

/// 由文件扩展名推断 highlight 语言名（未知则交给 plaintext 兜底）。
String _languageFor(String path) {
  final ext = p.extension(path).toLowerCase();
  switch (ext) {
    case '.dart':
      return 'dart';
    case '.py':
      return 'python';
    case '.js':
    case '.mjs':
    case '.cjs':
      return 'javascript';
    case '.jsx':
      return 'javascript';
    case '.ts':
      return 'typescript';
    case '.tsx':
      return 'typescript';
    case '.java':
      return 'java';
    case '.kt':
      return 'kotlin';
    case '.go':
      return 'go';
    case '.rs':
      return 'rust';
    case '.c':
    case '.h':
      return 'c';
    case '.cc':
    case '.cpp':
    case '.hpp':
    case '.cxx':
      return 'cpp';
    case '.cs':
      return 'cs';
    case '.rb':
      return 'ruby';
    case '.php':
      return 'php';
    case '.swift':
      return 'swift';
    case '.scala':
      return 'scala';
    case '.sh':
    case '.bash':
      return 'bash';
    case '.ps1':
      return 'powershell';
    case '.sql':
      return 'sql';
    case '.lua':
      return 'lua';
    case '.r':
      return 'r';
    case '.html':
    case '.vue':
    case '.svelte':
      return 'xml';
    case '.xml':
      return 'xml';
    case '.css':
      return 'css';
    case '.scss':
      return 'scss';
    case '.less':
      return 'less';
    case '.json':
      return 'json';
    case '.yaml':
    case '.yml':
      return 'yaml';
    case '.toml':
    case '.ini':
      return 'ini';
    case '.md':
      return 'markdown';
    default:
      return 'plaintext';
  }
}

/// 带语法高亮的代码查看器（只读、可横向/纵向滚动）。
class CodeView extends StatelessWidget {
  const CodeView({super.key, required this.source, required this.filePath});

  final String source;
  final String filePath;

  @override
  Widget build(BuildContext context) {
    _ensureRegistered();
    return Scrollbar(
      child: SingleChildScrollView(
        primary: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: HighlightView(
            source,
            language: _languageFor(filePath),
            theme: githubTheme,
            padding: const EdgeInsets.all(14),
            textStyle: const TextStyle(
                fontFamily: 'Consolas', fontSize: 12.5, height: 1.45),
          ),
        ),
      ),
    );
  }
}

/// 弹出一个对话框展示文件内容（其他模块仍可用；项目页改用内嵌 tab）。
/// 内容渲染统一交给 [FileContentView]：md 走「预览/源码」、其他走高亮源码。
Future<void> showCodeViewer(BuildContext context, String absPath) async {
  final name = p.basename(absPath);
  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.description_outlined,
                      size: 16, color: Color(0xFF0D9488)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(child: FileContentView(absPath: absPath)),
          ],
        ),
      ),
    ),
  );
}

/// 可内嵌的文件内容查看器（不含标题栏 / 关闭按钮，便于放进 tab 或对话框）：
/// - Markdown（.md/.markdown）：「预览」格式化渲染 + 可切换「源码」tab；
/// - 其他文本文件：语法高亮源码。
/// 自行按路径异步读取文件内容，切换路径会自动重载。
class FileContentView extends StatefulWidget {
  const FileContentView({super.key, required this.absPath});

  final String absPath;

  @override
  State<FileContentView> createState() => _FileContentViewState();
}

class _FileContentViewState extends State<FileContentView> {
  String? _content;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FileContentView old) {
    super.didUpdateWidget(old);
    if (old.absPath != widget.absPath) _load();
  }

  Future<void> _load() async {
    setState(() {
      _content = null;
      _error = null;
    });
    try {
      final text = await File(widget.absPath).readAsString();
      if (mounted) setState(() => _content = text);
    } catch (e) {
      if (mounted) setState(() => _error = '无法以文本打开该文件（可能为二进制）：$e');
    }
  }

  bool get _isMarkdown {
    final ext = p.extension(widget.absPath).toLowerCase();
    return ext == '.md' || ext == '.markdown';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              style:
                  const TextStyle(fontSize: 13, color: Color(0xFF9B9B9F))),
        ),
      );
    }
    if (_content == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_isMarkdown) {
      return CodeView(source: _content!, filePath: widget.absPath);
    }
    // Markdown：预览 / 源码 两个 tab。
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: Color(0xFF0D9488),
            unselectedLabelColor: Color(0xFF8A8A92),
            indicatorColor: Color(0xFF0D9488),
            labelStyle: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            tabs: [
              Tab(height: 36, text: '预览'),
              Tab(height: 36, text: '源码'),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              children: [
                Markdown(
                  data: _content!,
                  padding: const EdgeInsets.all(22),
                  styleSheet: MarkdownStyleSheet(
                    p: const TextStyle(fontSize: 14, height: 1.7),
                    h1: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w700, height: 1.6),
                    h2: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700, height: 1.5),
                    h3: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600, height: 1.5),
                    code: const TextStyle(
                        fontSize: 12.5,
                        fontFamily: 'Consolas',
                        backgroundColor: Color(0xFFEFF1F4)),
                    blockquote: const TextStyle(
                        fontSize: 13.5, color: Color(0xFF6B7280)),
                    tableBorder:
                        TableBorder.all(color: const Color(0xFFE0E2E6)),
                    a: const TextStyle(color: Color(0xFF0D9488)),
                  ),
                ),
                CodeView(source: _content!, filePath: widget.absPath),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
