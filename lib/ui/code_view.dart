import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:highlight/highlight.dart' show highlight;
import 'package:highlight/languages/all.dart' show allLanguages;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'editable_code_view.dart';
import 'preview/media_preview.dart';
import 'preview/office_preview.dart';

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
/// 内容渲染统一交给 [FileContentView]：可编辑文本/代码、md 预览/编辑、图片/PDF/Office 预览。
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

/// 可内嵌的文件内容查看器（不含标题栏 / 关闭按钮，便于放进 tab 或对话框）。
/// 按扩展名分发到不同呈现方式，背景统一为白色：
/// - 图片：缩放预览；PDF：内嵌阅读；音视频：内嵌播放；
/// - Office（.xlsx/.docx/.pptx）：解析后表格 / 文本预览；
/// - Markdown：「预览 / 编辑」可切换；其他文本/代码：高亮可编辑 + 保存。
class FileContentView extends StatelessWidget {
  const FileContentView({super.key, required this.absPath});

  final String absPath;

  static const _imageExt = {
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.ico'
  };
  static const _videoExt = {
    '.mp4', '.mkv', '.mov', '.avi', '.wmv', '.flv', '.webm', '.m4v',
    '.mpeg', '.mpg', '.3gp', '.ts', '.rmvb', '.rm', '.vob', '.m2ts'
  };
  static const _audioExt = {
    '.mp3', '.wav', '.flac', '.aac', '.ogg', '.m4a', '.wma', '.opus', '.aiff'
  };
  static const _officeExt = {
    '.xlsx', '.docx', '.pptx', '.xls', '.doc', '.ppt'
  };
  static const _markdownExt = {'.md', '.markdown'};

  @override
  Widget build(BuildContext context) {
    final ext = p.extension(absPath).toLowerCase();

    if (_imageExt.contains(ext)) {
      return Container(
        color: Colors.white,
        padding: const EdgeInsets.all(24),
        child: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: Image.file(
              File(absPath),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Text('无法预览此图片'),
            ),
          ),
        ),
      );
    }
    if (ext == '.pdf') {
      return PdfViewer.file(
        absPath,
        key: ValueKey('pdf:$absPath'),
        params: PdfViewerParams(
          backgroundColor: const Color(0xFFEDEDF0),
          loadingBannerBuilder: (context, downloaded, total) =>
              const Center(child: CircularProgressIndicator()),
          errorBannerBuilder: (context, error, stack, ref) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('无法预览此 PDF：$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF9B9B9F))),
            ),
          ),
        ),
      );
    }
    if (_videoExt.contains(ext)) {
      return MediaPreview(path: absPath, isVideo: true);
    }
    if (_audioExt.contains(ext)) {
      return MediaPreview(path: absPath, isVideo: false);
    }
    if (_officeExt.contains(ext)) {
      return Container(
        color: Colors.white,
        child: OfficePreview(absPath: absPath),
      );
    }
    // Markdown：预览/编辑；其他文本/代码：高亮可编辑。
    return Container(
      color: Colors.white,
      child: EditableCodeView(
        key: ValueKey('edit:$absPath'),
        absPath: absPath,
        markdownPreview: _markdownExt.contains(ext),
      ),
    );
  }
}
