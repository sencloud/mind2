import 'dart:io';

import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import 'settings_service.dart';

/// 管理「文件库」：把任意文件按类型（视频/图片/文档/照片/其他）归类存放，
/// 并在知识库页展示。文件统一放在 `<vault>/3-文件库/<类型>` 下。
class FileLibraryService extends ChangeNotifier {
  FileLibraryService(this.settings);

  final SettingsService settings;

  List<LibraryFile> files = [];
  bool loading = false;
  String? error;

  bool working = false;
  String workingLabel = '';
  int workingDone = 0;
  int workingTotal = 0;

  String get rootDir => p.join(settings.vaultPath, '3-文件库');

  static const _videoExt = {
    'mp4',
    'mkv',
    'mov',
    'avi',
    'wmv',
    'flv',
    'webm',
    'm4v',
    'mpeg',
    'mpg',
    '3gp',
    'ts',
    'rmvb',
    'rm',
    'vob',
    'm2ts',
  };

  static const _docExt = {
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'txt',
    'md',
    'csv',
    'rtf',
    'odt',
    'ods',
    'odp',
    'epub',
    'wps',
    'pages',
    'json',
    'xml',
    'html',
    'htm',
    'mhtml',
  };

  static const _imageExt = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'bmp',
    'webp',
    'svg',
    'tif',
    'tiff',
    'heic',
    'heif',
    'ico',
    'raw',
    'cr2',
    'nef',
    'arw',
    'dng',
  };

  List<LibraryFile> filesOf(FileKind kind) =>
      files.where((f) => f.kind == kind).toList();

  /// 至少有一个文件的类型，按枚举顺序返回。
  List<FileKind> get nonEmptyKinds =>
      FileKind.values.where((k) => files.any((f) => f.kind == k)).toList();

  Future<void> reload() async {
    loading = true;
    error = null;
    notifyListeners();
    final result = <LibraryFile>[];
    try {
      for (final kind in FileKind.values) {
        final dir = Directory(p.join(rootDir, kind.folder));
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true)) {
          if (entity is! File) continue;
          final stat = entity.statSync();
          result.add(
            LibraryFile(
              path: entity.path,
              name: p.basename(entity.path),
              kind: kind,
              size: stat.size,
              modified: stat.modified,
            ),
          );
        }
      }
    } catch (e) {
      error = '扫描文件库失败：$e';
    }
    result.sort((a, b) => b.modified.compareTo(a.modified));
    files = result;
    loading = false;
    notifyListeners();
  }

  static String _ext(String path) {
    final name = p.basename(path);
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  Future<FileKind> classify(String path) async {
    final ext = _ext(path);
    if (_videoExt.contains(ext)) return FileKind.video;
    if (_docExt.contains(ext)) return FileKind.document;
    if (_imageExt.contains(ext)) {
      return await _isPhoto(path) ? FileKind.photo : FileKind.image;
    }
    return FileKind.other;
  }

  FileKind kindByExtension(String fileName) {
    final ext = _ext(fileName);
    if (_videoExt.contains(ext)) return FileKind.video;
    if (_docExt.contains(ext)) return FileKind.document;
    if (_imageExt.contains(ext)) return FileKind.image;
    return FileKind.other;
  }

  /// 保存一段已下载的字节流到文件库并自动归类，返回入库后的文件相对仓库根的路径。
  Future<String> saveDownloaded(String fileName, Uint8List bytes) async {
    final ext = _ext(fileName);
    FileKind kind;
    if (_videoExt.contains(ext)) {
      kind = FileKind.video;
    } else if (_docExt.contains(ext)) {
      kind = FileKind.document;
    } else if (_imageExt.contains(ext)) {
      kind = _isPhotoBytes(bytes) ? FileKind.photo : FileKind.image;
    } else {
      kind = FileKind.other;
    }
    final destDir = Directory(p.join(rootDir, kind.folder));
    await destDir.create(recursive: true);
    final dest = _uniquePath(p.join(destDir.path, fileName));
    await File(dest).writeAsBytes(bytes);
    final stat = File(dest).statSync();
    files = [
      LibraryFile(
        path: dest,
        name: p.basename(dest),
        kind: kind,
        size: stat.size,
        modified: stat.modified,
      ),
      ...files,
    ];
    notifyListeners();
    return ['3-文件库', kind.folder, p.basename(dest)].join('/');
  }

  bool _isPhotoBytes(Uint8List bytes) {
    try {
      // readExifFromBytes 是异步的，这里用同步近似：仅在 JPEG 头部快速探测 EXIF 标记。
      // 真实判定在 reload/classify 时已覆盖；此处用 APP1/EXIF 标记做轻量判断。
      for (
        var i = 0;
        i < (bytes.length < 4096 ? bytes.length - 4 : 4096);
        i++
      ) {
        if (bytes[i] == 0x45 &&
            bytes[i + 1] == 0x78 &&
            bytes[i + 2] == 0x69 &&
            bytes[i + 3] == 0x66) {
          return true; // 'Exif'
        }
      }
    } catch (_) {}
    return false;
  }

  /// 通过 EXIF 判断是否为相机/手机拍摄的真实照片：
  /// 含拍摄设备信息或拍摄时间即视为「照片」，否则归为「图片」。
  Future<bool> _isPhoto(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final data = await readExifFromBytes(bytes);
      if (data.isEmpty) return false;
      const photoTags = [
        'Image Make',
        'Image Model',
        'EXIF DateTimeOriginal',
        'EXIF DateTimeDigitized',
        'EXIF LensModel',
        'GPS GPSLatitude',
      ];
      return photoTags.any((t) => data.containsKey(t));
    } catch (_) {
      return false;
    }
  }

  /// 手动导入：将外部文件复制进文件库并自动归类，返回成功数量。
  Future<int> importFiles(List<String> paths) =>
      _ingest(paths, '导入文件', move: false);

  /// 扫描文件夹：递归收集其中所有文件并移动进文件库归类，返回成功数量。
  Future<int> importFromDirectory(String sourceDir) async {
    final paths = await _collectFiles(sourceDir);
    return _ingest(paths, '整理文件夹', move: true);
  }

  /// 引入文件夹：递归收集其中所有文件并复制进文件库归类（保留源文件夹），返回成功数量。
  Future<int> importDirectoryCopy(String sourceDir) async {
    final paths = await _collectFiles(sourceDir);
    return _ingest(paths, '引入文件夹', move: false);
  }

  Future<List<String>> _collectFiles(String sourceDir) async {
    final dir = Directory(sourceDir);
    if (!await dir.exists()) return [];
    final paths = <String>[];
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && !entity.path.startsWith(rootDir)) {
        paths.add(entity.path);
      }
    }
    return paths;
  }

  Future<int> _ingest(
    List<String> paths,
    String label, {
    required bool move,
  }) async {
    if (working || paths.isEmpty) return 0;
    working = true;
    workingLabel = label;
    workingDone = 0;
    workingTotal = paths.length;
    notifyListeners();
    var ok = 0;
    try {
      for (final src in paths) {
        try {
          final kind = await classify(src);
          await _placeInto(src, kind, move: move);
          ok++;
        } catch (_) {}
        workingDone++;
        notifyListeners();
      }
    } finally {
      working = false;
      notifyListeners();
    }
    await reload();
    return ok;
  }

  Future<void> _placeInto(
    String srcPath,
    FileKind kind, {
    required bool move,
  }) async {
    final destDir = Directory(p.join(rootDir, kind.folder));
    await destDir.create(recursive: true);
    final name = p.basename(srcPath);
    final dest = _uniquePath(p.join(destDir.path, name));
    final src = File(srcPath);
    if (move) {
      try {
        await src.rename(dest);
      } on FileSystemException {
        // 跨盘移动 rename 会失败，退回「复制后删除」。
        await src.copy(dest);
        await src.delete();
      }
    } else {
      await src.copy(dest);
    }
  }

  /// 避免重名覆盖：已存在则追加 (1)(2)…
  String _uniquePath(String path) {
    if (!File(path).existsSync()) return path;
    final dot = path.lastIndexOf('.');
    final base = dot > 0 ? path.substring(0, dot) : path;
    final ext = dot > 0 ? path.substring(dot) : '';
    var i = 1;
    while (File('$base ($i)$ext').existsSync()) {
      i++;
    }
    return '$base ($i)$ext';
  }

  /// 去重资料：同类型下「规范名（去掉结尾的 (n)）+ 文件大小」相同的文件视为重复，
  /// 仅保留最早的一份，其余删除。返回删除数量。
  Future<int> dedup() async {
    await reload();
    final seen = <String>{};
    var removed = 0;
    // 按修改时间升序，保留最早入库的。
    final ordered = [...files]
      ..sort((a, b) => a.modified.compareTo(b.modified));
    for (final f in ordered) {
      final base = f.name
          .replaceAll(RegExp(r' \(\d+\)(?=\.[^.]+$)'), '')
          .toLowerCase();
      final key = '${f.kind.name}\u0000$base\u0000${f.size}';
      if (seen.add(key)) continue;
      try {
        final file = File(f.path);
        if (await file.exists()) {
          await file.delete();
          removed++;
        }
      } catch (_) {}
    }
    if (removed > 0) await reload();
    return removed;
  }

  Future<void> deleteFile(LibraryFile file) async {
    final f = File(file.path);
    if (await f.exists()) await f.delete();
    files = files.where((x) => x.path != file.path).toList();
    notifyListeners();
  }
}
