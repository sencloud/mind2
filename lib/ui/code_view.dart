import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/github.dart';
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

/// 弹出一个对话框展示文件内容（语法高亮）。
Future<void> showCodeViewer(BuildContext context, String absPath) async {
  final file = File(absPath);
  String content;
  try {
    content = await file.readAsString();
  } catch (e) {
    content = '无法以文本打开该文件（可能为二进制）：$e';
  }
  if (!context.mounted) return;
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
            Flexible(child: CodeView(source: content, filePath: absPath)),
          ],
        ),
      ),
    ),
  );
}
