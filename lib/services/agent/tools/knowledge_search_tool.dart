import 'dart:io';

import '../tool.dart';

/// 让 Agent 检索用户「知识库」(vault) 里的 Markdown 笔记（跨模块共享能力）。
///
/// 项目/实验/计划等 Agent 借此复用用户已有的研究/标准/资料积累，
/// 真正做到各模块相互用好彼此的产出。只读，安全可并发。
class KnowledgeSearchTool extends AgentTool {
  KnowledgeSearchTool(this.vaultPath);

  /// 知识库根目录（来自 settings.vaultPath）。
  final String vaultPath;

  // 为避免在超大知识库里全量读盘卡死，限定单次最多扫描的文件数。
  static const _maxScan = 2000;

  @override
  String get name => 'search_knowledge';

  @override
  String get description =>
      '在用户的本地知识库（Markdown 笔记库）里按关键词检索相关笔记，'
      '返回标题、路径与命中片段。用于查阅用户已有的研究报告、标准、资料积累。';

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': '检索关键词'},
          'limit': {'type': 'integer', 'description': '最多返回条数，默认 5'},
        },
        'required': ['query'],
      };

  @override
  String describeCall(Map<String, dynamic> input) => '检索知识库：${input['query']}';

  @override
  Future<ToolResult> call(Map<String, dynamic> input, ToolContext ctx) async {
    final query = (input['query'] ?? '').toString().trim();
    if (query.isEmpty) return ToolResult.error('缺少 query 参数');
    if (vaultPath.isEmpty) return ToolResult.error('未配置知识库路径');
    final dir = Directory(vaultPath);
    if (!await dir.exists()) return ToolResult.error('知识库目录不存在：$vaultPath');

    final limit = (input['limit'] as num?)?.toInt() ?? 5;
    final q = query.toLowerCase();
    final hits = <String>[];
    var scanned = 0;

    await for (final ent in dir.list(recursive: true, followLinks: false)) {
      if (hits.length >= limit || scanned >= _maxScan) break;
      if (ent is! File || !ent.path.toLowerCase().endsWith('.md')) continue;
      scanned++;
      String text;
      try {
        text = await ent.readAsString();
      } catch (_) {
        continue;
      }
      final name = ent.uri.pathSegments.last;
      final idx = text.toLowerCase().indexOf(q);
      // 文件名或正文命中任一即算相关。
      if (!name.toLowerCase().contains(q) && idx < 0) continue;
      // 取命中位置附近一小段作为预览。
      final start = idx < 0 ? 0 : (idx - 60).clamp(0, text.length);
      final end = (start + 240).clamp(0, text.length);
      final snippet = text.substring(start, end).replaceAll('\n', ' ').trim();
      hits.add('### $name\n路径：${ent.path}\n片段：…$snippet…');
    }

    if (hits.isEmpty) {
      return ToolResult('知识库中未找到与「$query」相关的笔记。');
    }
    return ToolResult(hits.join('\n\n'));
  }
}
