import '../../../util/text_util.dart';
import '../model_client.dart';
import 'memory_types.dart';

/// 抽取出的一条候选记忆。
class ExtractedMemory {
  ExtractedMemory({
    required this.type,
    required this.name,
    required this.description,
    required this.body,
    this.update,
  });

  final MemoryType type;
  final String name;
  final String description;
  final String body;

  /// 若为对已有记忆的更新，则为目标文件名；否则 null（新建）。
  final String? update;
}

/// 记忆抽取器：会话结束后用**小模型**对本轮转写做一次抽取，
/// 按四类型决定该不该记、去重，产出结构化候选记忆（由 MemoryStore 落盘）。
/// 对应 Claude Code 的 extractMemories——「结构化优于自由文本」。
class MemoryExtractor {
  MemoryExtractor(this.model);

  /// 必须是小模型通道。
  final ModelClient model;

  Future<List<ExtractedMemory>> extract({
    required String transcript,
    required String globalManifest,
    required String projectManifest,
  }) async {
    if (transcript.trim().isEmpty) return [];
    final turn = await model.stream(
      messages: [
        {
          'role': 'system',
          'content': MemoryPrompts.extractionSystem(
            globalManifest: globalManifest,
            projectManifest: projectManifest,
          ),
        },
        {
          'role': 'user',
          'content': '本轮对话转写：\n${_clip(transcript, 12000)}',
        },
      ],
      jsonMode: true,
    );
    return _parse(turn.content);
  }

  List<ExtractedMemory> _parse(String raw) {
    final out = <ExtractedMemory>[];
    Map<String, dynamic> obj;
    try {
      obj = ModelClient.parseJsonObject(raw);
    } catch (_) {
      return out;
    }
    final list = obj['memories'];
    if (list is! List) return out;
    for (final item in list) {
      if (item is! Map) continue;
      final type = parseMemoryType(item['type']?.toString());
      if (type == null) continue;
      final name = (item['name'] ?? '').toString().trim();
      final description = (item['description'] ?? '').toString().trim();
      final body = (item['body'] ?? '').toString().trim();
      if (name.isEmpty || body.isEmpty) continue;
      final update = (item['update'] ?? '').toString().trim();
      out.add(ExtractedMemory(
        type: type,
        name: name,
        description: description,
        body: body,
        update: update.isEmpty ? null : update,
      ));
    }
    return out;
  }

  static String _clip(String s, int max) =>
      clip(s, max, suffix: '\n…（已截断 ${s.length - max} 字）');
}
