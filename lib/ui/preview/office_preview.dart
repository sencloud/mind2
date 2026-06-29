import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// Office 文档（.xlsx/.docx/.pptx）的应用内预览。
/// 纯 Dart 解析（zip + xml），内容可读，但不保证版式与 MS Office 完全一致。
/// 旧版二进制格式（.doc/.xls/.ppt）无法解析，给出提示。
class OfficePreview extends StatefulWidget {
  const OfficePreview({super.key, required this.absPath});

  final String absPath;

  @override
  State<OfficePreview> createState() => _OfficePreviewState();
}

class _OfficePreviewState extends State<OfficePreview> {
  bool _loading = true;
  String _error = '';
  // xlsx 结果：表名 -> 行（每行是单元格字符串列表）。
  Map<String, List<List<String>>> _sheets = const {};
  String _selectedSheet = '';
  // docx 结果：段落文本。
  String _docText = '';
  // pptx 结果：每页文本。
  List<String> _slides = const [];

  String get _ext => p.extension(widget.absPath).toLowerCase();

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(OfficePreview old) {
    super.didUpdateWidget(old);
    if (old.absPath != widget.absPath) _parse();
  }

  Future<void> _parse() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      switch (_ext) {
        case '.xlsx':
          final sheets = await compute(_parseXlsx, widget.absPath);
          _sheets = sheets;
          _selectedSheet = sheets.keys.isNotEmpty ? sheets.keys.first : '';
          break;
        case '.docx':
          _docText = await compute(_parseDocx, widget.absPath);
          break;
        case '.pptx':
          _slides = await compute(_parsePptx, widget.absPath);
          break;
        default:
          _error = '暂不支持预览旧版 $_ext 文件，请用支持的程序打开。';
      }
    } catch (e) {
      _error = '无法解析此文件：$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF9B9B9F))),
        ),
      );
    }
    return switch (_ext) {
      '.xlsx' => _buildXlsx(),
      '.docx' => _buildDocx(),
      '.pptx' => _buildPptx(),
      _ => const SizedBox(),
    };
  }

  Widget _buildXlsx() {
    final rows = _sheets[_selectedSheet] ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_sheets.length > 1)
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: _sheets.keys.map((name) {
                final sel = name == _selectedSheet;
                return Padding(
                  padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
                  child: ChoiceChip(
                    label: Text(name, style: const TextStyle(fontSize: 12)),
                    selected: sel,
                    onSelected: (_) => setState(() => _selectedSheet = name),
                  ),
                );
              }).toList(),
            ),
          ),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('（空表）'))
              : SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(12),
                    child: _table(rows),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _table(List<List<String>> rows) {
    final cols = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      border: TableBorder.all(color: const Color(0xFFE2E4E8)),
      children: [
        for (var r = 0; r < rows.length; r++)
          TableRow(
            decoration: BoxDecoration(
              color: r == 0 ? const Color(0xFFF3F4F6) : Colors.white,
            ),
            children: [
              for (var c = 0; c < cols; c++)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  child: Text(
                    c < rows[r].length ? rows[r][c] : '',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: r == 0 ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _buildDocx() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: SelectableText(
        _docText.isEmpty ? '（无文本内容）' : _docText,
        style: const TextStyle(fontSize: 14, height: 1.7),
      ),
    );
  }

  Widget _buildPptx() {
    if (_slides.isEmpty) return const Center(child: Text('（无文本内容）'));
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _slides.length,
      itemBuilder: (context, i) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFE2E4E8)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('第 ${i + 1} 页',
                style: const TextStyle(
                    fontSize: 11.5, color: Color(0xFF9B9B9F))),
            const SizedBox(height: 8),
            SelectableText(
              _slides[i].isEmpty ? '（本页无文本）' : _slides[i],
              style: const TextStyle(fontSize: 13.5, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- 后台 isolate 解析（top-level，供 compute 调用）----------

/// 读取 zip 条目文本，去掉可能的 UTF-8 BOM。
String _entryText(Archive archive, String name) {
  for (final f in archive.files) {
    if (f.isFile && f.name == name) {
      var s = utf8.decode(f.content as List<int>, allowMalformed: true);
      if (s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF) s = s.substring(1);
      return s;
    }
  }
  return '';
}

/// 解析 .xlsx：返回 表名 -> 行（每行是单元格字符串）。
Map<String, List<List<String>>> _parseXlsx(String path) {
  final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());

  // 共享字符串表：单元格 t="s" 时引用其下标。
  final shared = <String>[];
  final ssXml = _entryText(archive, 'xl/sharedStrings.xml');
  if (ssXml.isNotEmpty) {
    for (final si in XmlDocument.parse(ssXml).findAllElements('si')) {
      shared.add(si.findAllElements('t', namespace: '*').map((e) => e.innerText).join());
    }
  }

  // 工作表名称（按 workbook.xml 中的出现顺序）。
  final names = <String>[];
  final wbXml = _entryText(archive, 'xl/workbook.xml');
  if (wbXml.isNotEmpty) {
    for (final s in XmlDocument.parse(wbXml).findAllElements('sheet', namespace: '*')) {
      names.add(s.getAttribute('name') ?? 'Sheet${names.length + 1}');
    }
  }

  // 工作表文件按 sheetN.xml 的数字顺序排列，与名称按序配对。
  final sheetFiles = archive.files
      .where((f) => f.isFile &&
          f.name.startsWith('xl/worksheets/sheet') &&
          f.name.endsWith('.xml'))
      .map((f) => f.name)
      .toList()
    ..sort((a, b) => _sheetNum(a).compareTo(_sheetNum(b)));

  final result = <String, List<List<String>>>{};
  for (var i = 0; i < sheetFiles.length; i++) {
    final name = i < names.length ? names[i] : 'Sheet${i + 1}';
    result[name] = _parseSheet(_entryText(archive, sheetFiles[i]), shared);
  }
  return result;
}

int _sheetNum(String name) {
  final m = RegExp(r'sheet(\d+)\.xml').firstMatch(name);
  return m == null ? 0 : int.parse(m.group(1)!);
}

/// 解析单个工作表 xml，按列引用对齐单元格，最多取 1000 行避免卡顿。
List<List<String>> _parseSheet(String xml, List<String> shared) {
  if (xml.isEmpty) return const [];
  final rows = <List<String>>[];
  for (final row in XmlDocument.parse(xml).findAllElements('row', namespace: '*')) {
    final cells = <String>[];
    for (final c in row.findAllElements('c', namespace: '*')) {
      final col = _colIndex(c.getAttribute('r') ?? '');
      // 列上限保护：忽略异常的超宽列，避免超宽行卡顿/占用内存。
      if (col < 0 || col > 255) continue;
      while (cells.length <= col) {
        cells.add('');
      }
      final t = c.getAttribute('t');
      String value;
      if (t == 's') {
        final idx = int.tryParse(c.findAllElements('v', namespace: '*').map((e) => e.innerText).join());
        value = (idx != null && idx >= 0 && idx < shared.length) ? shared[idx] : '';
      } else if (t == 'inlineStr') {
        value = c.findAllElements('t', namespace: '*').map((e) => e.innerText).join();
      } else {
        value = c.findAllElements('v', namespace: '*').map((e) => e.innerText).join();
      }
      if (col >= 0) cells[col] = value;
    }
    rows.add(cells);
    if (rows.length >= 1000) break;
  }
  return rows;
}

/// 列引用（如 "AB12"）转 0 基列下标。
int _colIndex(String ref) {
  var col = 0;
  for (var i = 0; i < ref.length; i++) {
    final ch = ref.codeUnitAt(i);
    if (ch >= 65 && ch <= 90) {
      col = col * 26 + (ch - 64);
    } else if (ch >= 97 && ch <= 122) {
      col = col * 26 + (ch - 96);
    } else {
      break;
    }
  }
  return col - 1;
}

/// 解析 .docx：按段落（w:p）提取文本。
String _parseDocx(String path) {
  final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  final xml = _entryText(archive, 'word/document.xml');
  if (xml.isEmpty) return '';
  final paras = <String>[];
  for (final p in XmlDocument.parse(xml).findAllElements('p', namespace: '*')) {
    final text = p.findAllElements('t', namespace: '*').map((e) => e.innerText).join();
    paras.add(text);
  }
  return paras.join('\n\n').trim();
}

/// 解析 .pptx：每页幻灯片（slideN.xml）提取文本。
List<String> _parsePptx(String path) {
  final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  final slideFiles = archive.files
      .where((f) => f.isFile &&
          f.name.startsWith('ppt/slides/slide') &&
          f.name.endsWith('.xml'))
      .map((f) => f.name)
      .toList()
    ..sort((a, b) => _slideNum(a).compareTo(_slideNum(b)));
  final slides = <String>[];
  for (final name in slideFiles) {
    final xml = _entryText(archive, name);
    if (xml.isEmpty) {
      slides.add('');
      continue;
    }
    final texts = XmlDocument.parse(xml)
        .findAllElements('t', namespace: '*')
        .map((e) => e.innerText)
        .where((t) => t.isNotEmpty);
    slides.add(texts.join('\n'));
  }
  return slides;
}

int _slideNum(String name) {
  final m = RegExp(r'slide(\d+)\.xml').firstMatch(name);
  return m == null ? 0 : int.parse(m.group(1)!);
}
