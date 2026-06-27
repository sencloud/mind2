import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../models.dart';
import 'media_preview.dart';
import 'text_preview.dart';

/// 应用内文件预览的统一入口。
/// 根据文件扩展名分发到不同的预览方式：
/// PDF、纯文本/Markdown/代码、图片、视频、音频。
/// 无法在应用内渲染的格式（如 Office 文档）回退到 [placeholder]，
/// 由调用方提供「用系统默认程序打开」的提示。
class FilePreview extends StatelessWidget {
  const FilePreview({super.key, required this.file, required this.placeholder});

  final LibraryFile file;
  final Widget placeholder;

  // 各类可应用内预览的扩展名集合。
  static const _textExt = {
    'txt', 'log', 'csv', 'json', 'xml', 'yaml', 'yml', 'ini', 'conf', 'toml',
    'html', 'htm', 'dart', 'py', 'js', 'ts', 'java', 'c', 'cpp', 'cc', 'h',
    'hpp', 'cs', 'go', 'rs', 'rb', 'php', 'sh', 'bat', 'ps1', 'sql', 'kt',
    'swift', 'gradle', 'properties'
  };
  static const _markdownExt = {'md', 'markdown'};
  // Image.file 能解码的常见栅格格式（svg/heic/tiff 等交给 placeholder）。
  static const _imageExt = {'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'ico'};
  static const _videoExt = {
    'mp4', 'mkv', 'mov', 'avi', 'wmv', 'flv', 'webm', 'm4v', 'mpeg', 'mpg',
    '3gp', 'ts', 'rmvb', 'rm', 'vob', 'm2ts'
  };
  static const _audioExt = {
    'mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'wma', 'opus', 'aiff'
  };

  static String _ext(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final ext = _ext(file.name);

    if (ext == 'pdf') {
      // 用 ValueKey 绑定路径，切换文件时强制重建并重新加载；
      // 提供加载/错误横幅，避免加载失败时只剩一片空白。
      return PdfViewer.file(
        file.path,
        key: ValueKey('pdf:${file.path}'),
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
    if (_markdownExt.contains(ext)) {
      return TextPreview(path: file.path, isMarkdown: true);
    }
    if (_textExt.contains(ext)) {
      return TextPreview(path: file.path, isMarkdown: false);
    }
    if (_videoExt.contains(ext)) {
      return MediaPreview(path: file.path, isVideo: true);
    }
    if (_audioExt.contains(ext)) {
      return MediaPreview(path: file.path, isVideo: false);
    }
    // 图片：优先看扩展名，其次看归类（兼容无扩展名但归为图片/照片的情况）。
    if (_imageExt.contains(ext) || file.isImage) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: Image.file(
              File(file.path),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => placeholder,
            ),
          ),
        ),
      );
    }
    return placeholder;
  }
}
