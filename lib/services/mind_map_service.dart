import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:xml/xml.dart';

import 'settings_service.dart';

/// 思维导图的展现形式。
/// - bubble：Mermaid mindmap，发散/气泡状（默认）。
/// - treeRight：层级图·横向（graph LR，从左到右的树）。
/// - treeDown：层级图·纵向（graph TB，从上到下的树）。
enum MindMapLayout { bubble, treeRight, treeDown }

/// 一条思维导图生成历史记录。持久化到本地，和文档模块一样可回看/继续操作。
class MindMapRecord {
  MindMapRecord({
    required this.id,
    this.title = '未命名导图',
    this.sourceText = '',
    this.mermaid = '',
    this.layout = MindMapLayout.bubble,
    this.imagePath = '',
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  String title;
  String sourceText; // 生成用的原文
  String mermaid; // 模型生成的原始 mindmap 代码（层级结构来源）
  MindMapLayout layout; // 当前展现形式
  String imagePath; // 已保存的预览 PNG 路径（对应当前布局）
  final DateTime createdAt;
  DateTime updatedAt;

  bool get hasResult => mermaid.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'sourceText': sourceText,
    'mermaid': mermaid,
    'layout': layout.index,
    'imagePath': imagePath,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory MindMapRecord.fromJson(Map<String, dynamic> json) {
    final idx = (json['layout'] as num?)?.toInt() ?? 0;
    return MindMapRecord(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      title: json['title'] as String? ?? '未命名导图',
      sourceText: json['sourceText'] as String? ?? '',
      mermaid: json['mermaid'] as String? ?? '',
      layout: MindMapLayout
          .values[idx.clamp(0, MindMapLayout.values.length - 1)],
      imagePath: json['imagePath'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// 思维导图服务：把文档（pdf/word）或文字交给模型，生成 Mermaid mindmap 代码，
/// 再用 mermaid.ink 渲染成图片，支持导出 png / jpg。
/// 生成后可在多种「展现形式」间切换：切换布局只在本地把已生成的层级结构
/// 转成不同的 Mermaid 语法重新渲染，不再重复调用大模型。
/// 每次生成都会写入历史记录（records），和文档模块一致，可回看。
class MindMapService extends ChangeNotifier {
  MindMapService(this.settings);

  final SettingsService settings;

  final List<MindMapRecord> records = []; // 历史记录（最新在前）
  MindMapRecord? current; // 当前打开的记录；为 null 时显示历史列表
  bool busy = false;
  String stage = '';
  String? sourceName; // 本次导入的文件名（临时提示用）
  Uint8List? image; // 当前记录的预览 PNG 字节

  File? _store; // 历史记录 JSON 文件
  Directory? _imgDir; // 预览图存放目录
  http.Client? _client;

  // 便捷读取当前记录的字段，方便 UI 使用。
  String get mermaid => current?.mermaid ?? '';
  MindMapLayout get layout => current?.layout ?? MindMapLayout.bubble;

  /// 启动时载入历史记录，并准备预览图目录。
  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _store = File(p.join(dir.path, 'mindmaps.json'));
    _imgDir = Directory(p.join(dir.path, 'mindmaps'));
    await _imgDir!.create(recursive: true);
    if (await _store!.exists()) {
      try {
        final data = jsonDecode(await _store!.readAsString());
        if (data is List) {
          records
            ..clear()
            ..addAll(
              data.whereType<Map>().map(
                (e) => MindMapRecord.fromJson(e.cast<String, dynamic>()),
              ),
            );
        }
      } catch (_) {
        records.clear();
      }
    }
  }

  /// 新建一条空记录并打开（进入工作区）。
  MindMapRecord create() {
    final now = DateTime.now();
    final rec = MindMapRecord(
      id: now.microsecondsSinceEpoch.toString(),
      createdAt: now,
      updatedAt: now,
    );
    records.insert(0, rec);
    current = rec;
    image = null;
    sourceName = null;
    stage = '';
    notifyListeners();
    _persist();
    return rec;
  }

  /// 打开一条历史记录，并载入已保存的预览图（不联网）。
  Future<void> open(MindMapRecord rec) async {
    current = rec;
    sourceName = null;
    stage = '';
    image = null;
    notifyListeners();
    if (rec.imagePath.isNotEmpty) {
      final f = File(rec.imagePath);
      if (await f.exists()) {
        image = await f.readAsBytes();
        notifyListeners();
      }
    }
  }

  /// 返回历史列表。
  void close() {
    current = null;
    image = null;
    stage = '';
    notifyListeners();
  }

  /// 删除一条记录（连同其预览图文件）。
  Future<void> delete(MindMapRecord rec) async {
    records.removeWhere((r) => r.id == rec.id);
    if (current?.id == rec.id) {
      current = null;
      image = null;
    }
    if (rec.imagePath.isNotEmpty) {
      try {
        final f = File(rec.imagePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    notifyListeners();
    await _persist();
  }

  /// 导入文件并抽取纯文本（pdf / docx / txt / md），写入当前记录。
  Future<void> importFile(String path) async {
    final rec = current;
    if (rec == null) return;
    busy = true;
    stage = '正在解析文件…';
    notifyListeners();
    try {
      final text = await _extractText(File(path));
      if (text.trim().isEmpty) {
        throw Exception('未能从文件中提取到文字（可能是扫描件或空文档）');
      }
      rec.sourceText = text;
      sourceName = p.basename(path);
      stage = '已导入：$sourceName（约 ${text.length} 字）';
    } catch (e) {
      stage = '解析失败：$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 根据文字生成思维导图：模型产出 mindmap 代码 → mermaid.ink 渲染 PNG，写入当前记录。
  Future<void> generate(String text) async {
    final rec = current;
    if (rec == null) return;
    final src = text.trim();
    if (src.isEmpty) {
      stage = '请先输入文字或导入文件';
      notifyListeners();
      return;
    }
    busy = true;
    stage = '正在生成思维导图…';
    image = null;
    notifyListeners();
    try {
      final reply = await _chat(_messages(src));
      final code = _extractMermaid(reply);
      if (code.isEmpty) throw Exception('模型未返回有效的思维导图结构');
      rec.sourceText = src;
      rec.mermaid = code;
      rec.title = _titleFrom(code, src);
      stage = '正在渲染…';
      notifyListeners();
      final png = await _render(_codeFor(rec.layout), 'png');
      image = png;
      rec.imagePath = await _saveImage(rec.id, png);
      rec.updatedAt = DateTime.now();
      stage = '生成完成';
      await _persist();
    } catch (e) {
      stage = '生成失败：$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 切换展现形式并重新渲染（不重新调用大模型）。
  Future<void> setLayout(MindMapLayout next) async {
    final rec = current;
    if (rec == null || next == rec.layout) return;
    rec.layout = next;
    if (rec.mermaid.isEmpty) {
      notifyListeners();
      return;
    }
    busy = true;
    stage = '正在切换展现形式…';
    notifyListeners();
    try {
      final png = await _render(_codeFor(rec.layout), 'png');
      image = png;
      rec.imagePath = await _saveImage(rec.id, png);
      rec.updatedAt = DateTime.now();
      stage = '已切换';
      await _persist();
    } catch (e) {
      stage = '渲染失败：$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 导出图片到目录。jpg 为 true 用 jpeg 格式，否则 png。返回文件路径。
  /// 全程不依赖联网：直接复用预览时已渲染好的 PNG 内存字节；
  /// 需要 JPG 时用 image 包在本地把 PNG 转码成 JPG。
  Future<String> exportImage(String dir, {required bool jpg}) async {
    if (mermaid.isEmpty) throw Exception('请先生成思维导图');
    // 没有内存字节（理论上不会）时再联网补渲染一次 PNG。
    final png = image ?? await _render(_codeFor(layout), 'png');
    final Uint8List bytes;
    if (jpg) {
      final decoded = img.decodeImage(png);
      if (decoded == null) throw Exception('图片解码失败，无法转 JPG');
      bytes = img.encodeJpg(decoded, quality: 92);
    } else {
      bytes = png;
    }
    final name =
        'mindmap_${DateTime.now().millisecondsSinceEpoch}.${jpg ? 'jpg' : 'png'}';
    final file = File(p.join(dir, name));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// 按当前布局返回对应的 Mermaid 代码。
  /// 气泡布局直接用模型输出的 mindmap 代码；层级布局把 mindmap 的缩进
  /// 结构解析成树，再转成 flowchart（graph LR / graph TB）。
  String _codeFor(MindMapLayout l) {
    if (l == MindMapLayout.bubble) return mermaid;
    final root = _parseTree(mermaid);
    if (root == null) return mermaid; // 解析失败则退回原图
    final dir = l == MindMapLayout.treeRight ? 'LR' : 'TB';
    return _emitFlowchart(root, dir);
  }

  /// 把 mindmap 代码（靠缩进表示层级）解析成一棵树。
  _MindNode? _parseTree(String code) {
    final lines = code.split('\n');
    final roots = <_MindNode>[];
    final stack = <_MindNode>[]; // 按层级维护的祖先栈
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      if (line.trim() == 'mindmap') continue;
      final indent = line.length - line.trimLeft().length;
      final node = _MindNode(_nodeLabel(line.trim()), indent);
      // 弹出所有缩进不小于当前的祖先，找到真正的父节点。
      while (stack.isNotEmpty && stack.last.indent >= indent) {
        stack.removeLast();
      }
      if (stack.isEmpty) {
        roots.add(node);
      } else {
        stack.last.children.add(node);
      }
      stack.add(node);
    }
    if (roots.isEmpty) return null;
    if (roots.length == 1) return roots.first;
    // 多个顶层节点时，套一个统一根节点。
    final synthetic = _MindNode('思维导图', -1)..children.addAll(roots);
    return synthetic;
  }

  /// 去掉 mindmap 节点的形状包裹，取出纯文本标签。
  /// 例如 `root((主题))` → `主题`，`A[文本]` → `文本`。
  static String _nodeLabel(String s) {
    final round2 = RegExp(r'^\w*\(\((.*)\)\)$').firstMatch(s);
    if (round2 != null) return round2.group(1)!.trim();
    final wrapped = RegExp(r'^\w*[\[\(\{](.*)[\]\)\}]$').firstMatch(s);
    if (wrapped != null) return wrapped.group(1)!.trim();
    return s;
  }

  /// 把树转成 flowchart 代码。dir 为 LR（横向）或 TB（纵向）。
  String _emitFlowchart(_MindNode root, String dir) {
    final buf = StringBuffer('graph $dir\n');
    var counter = 0;
    void walk(_MindNode node, String? parentId) {
      final id = 'n${counter++}';
      // 方括号会破坏 flowchart 节点语法，做安全替换。
      final label = node.label
          .replaceAll('"', "'")
          .replaceAll('[', '【')
          .replaceAll(']', '】');
      if (parentId == null) {
        buf.writeln('  $id["$label"]');
      } else {
        buf.writeln('  $parentId --> $id["$label"]');
      }
      for (final child in node.children) {
        walk(child, id);
      }
    }

    walk(root, null);
    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // 文本抽取
  // ---------------------------------------------------------------------------

  Future<String> _extractText(File file) async {
    final ext = p.extension(file.path).toLowerCase();
    if (ext == '.pdf') return _pdfText(file);
    if (ext == '.docx') return _docxText(file);
    if (ext == '.txt' || ext == '.md' || ext == '.markdown') {
      return _clip(await file.readAsString(), 16000);
    }
    throw Exception('暂不支持的格式：$ext（支持 pdf / docx / txt / md）');
  }

  Future<String> _pdfText(File file) async {
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openData(
        await file.readAsBytes(),
      ).timeout(const Duration(seconds: 25));
      final sb = StringBuffer();
      final count = doc.pages.length < 40 ? doc.pages.length : 40;
      for (var i = 0; i < count; i++) {
        final text = await doc.pages[i].loadText();
        final full = text?.fullText.trim();
        if (full != null && full.isNotEmpty) sb.writeln(full);
        if (sb.length >= 16000) break;
      }
      return _clip(sb.toString().trim(), 16000);
    } finally {
      await doc?.dispose();
    }
  }

  Future<String> _docxText(File file) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    final document = archive.findFile('word/document.xml');
    if (document == null) throw Exception('不是有效的 docx 文件');
    final xml = XmlDocument.parse(utf8.decode(document.content));
    final paragraphs = <String>[];
    for (final pNode in xml.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'p',
    )) {
      final text = pNode.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 't')
          .map((e) => e.innerText)
          .join()
          .trim();
      if (text.isNotEmpty) paragraphs.add(text);
    }
    return _clip(paragraphs.join('\n'), 16000);
  }

  // ---------------------------------------------------------------------------
  // 模型与渲染
  // ---------------------------------------------------------------------------

  List<Map<String, String>> _messages(String source) {
    return [
      {
        'role': 'system',
        'content':
            '你是资料结构化专家，擅长把内容提炼成层次清晰的思维导图。'
            '只输出 Mermaid 的 mindmap 代码，用 ```mermaid 代码块包裹，不要任何解释。',
      },
      {
        'role': 'user',
        'content':
            '''根据下面的内容生成一张思维导图（Mermaid mindmap）。要求：
- 第一行是 `mindmap`；
- 根节点用 `root((中心主题))` 表示，中心主题为内容的总标题；
- 用缩进（每级 2 个空格）表示层级，一般 3~4 层，覆盖主要分支与关键要点；
- 节点文字简短（不超过 15 字），不要出现英文括号 ()、方括号 []、花括号 {} 等特殊符号，需要时用中文顿号/冒号；
- 只输出 ```mermaid 代码块，不要输出其它文字。

内容如下：
$source''',
      },
    ];
  }

  /// 从模型回复中提取 mermaid 代码块；没有代码块则回退到含 mindmap 的正文。
  String _extractMermaid(String reply) {
    final fence = RegExp(
      r'```(?:mermaid)?\s*([\s\S]*?)```',
      caseSensitive: false,
    );
    final m = fence.firstMatch(reply);
    final raw = (m != null ? m.group(1) : reply)?.trim() ?? '';
    if (raw.isEmpty) return '';
    // 保证以 mindmap 开头。
    if (raw.startsWith('mindmap')) return raw;
    final idx = raw.indexOf('mindmap');
    return idx >= 0 ? raw.substring(idx).trim() : '';
  }

  /// 用 mermaid.ink 渲染 Mermaid 代码，type 支持 png / jpeg。
  Future<Uint8List> _render(String code, String type) async {
    final b64 = base64Url.encode(utf8.encode(code)).replaceAll('=', '');
    final url = 'https://mermaid.ink/img/$b64?type=$type&bgColor=white';
    final client = _client = http.Client();
    try {
      final resp = await client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 40));
      if (resp.statusCode != 200) {
        throw Exception('mermaid.ink 渲染失败 HTTP ${resp.statusCode}');
      }
      return resp.bodyBytes;
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  Future<String> _chat(List<Map<String, String>> messages) async {
    const role = ModelRole.writing;
    final client = _client = http.Client();
    try {
      final resp = await client.post(
        Uri.parse('${settings.roleBaseUrl(role)}/chat/completions'),
        headers: {
          'Authorization': 'Bearer ${settings.roleApiKey(role)}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': settings.roleModel(role),
          'stream': false,
          'messages': messages,
        }),
      );
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode} ${utf8.decode(resp.bodyBytes)}');
      }
      final json = jsonDecode(utf8.decode(resp.bodyBytes));
      return (json['choices']?[0]?['message']?['content'] as String?) ?? '';
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  /// 把预览 PNG 存到本地目录，文件名用记录 id（覆盖旧图）。返回路径。
  Future<String> _saveImage(String id, Uint8List bytes) async {
    final dir = _imgDir ?? Directory.systemTemp;
    final file = File(p.join(dir.path, '$id.png'));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// 由 mindmap 根节点或原文首行推导记录标题。
  String _titleFrom(String code, String src) {
    final root = _parseTree(code);
    final t = root?.label.trim() ?? '';
    if (t.isNotEmpty && t != '思维导图') return _clip(t, 30);
    final firstLine = src.trim().split('\n').first.trim();
    return firstLine.isEmpty ? '未命名导图' : _clip(firstLine, 30);
  }

  Future<void> _persist() async {
    if (_store == null) return;
    await _store!.writeAsString(
      jsonEncode(records.map((r) => r.toJson()).toList()),
    );
  }

  static String _clip(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);
}

/// 解析 mindmap 缩进结构时用到的临时树节点。
class _MindNode {
  _MindNode(this.label, this.indent);

  final String label;
  final int indent; // 该节点在原文里的缩进空格数
  final List<_MindNode> children = [];
}
