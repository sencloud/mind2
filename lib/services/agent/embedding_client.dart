import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../util/text_util.dart';
import '../settings_service.dart';

/// 文本向量化客户端：调用 OpenAI 兼容的 `/embeddings` 接口
/// （默认通义千问 Qwen / DashScope 的 text-embedding-v3），用于工程代码的语义索引。
///
/// 返回的向量统一做 L2 归一化，检索时直接用点积即等价于余弦相似度。
class EmbeddingClient {
  EmbeddingClient(this.settings);

  final SettingsService settings;

  /// DashScope text-embedding-v3 单次最多 10 条输入；保守取 10。
  static const _batchSize = 10;

  bool get ready => settings.embeddingReady;

  /// 当前模型名（落盘到索引 manifest，用于判断索引是否需重建）。
  String get model => settings.embeddingModel;

  /// 批量向量化：按批请求接口，结果顺序与输入一致；每个向量已 L2 归一化。
  /// [onProgress] 回报已完成的条数 / 总数。
  Future<List<List<double>>> embed(
    List<String> inputs, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (inputs.isEmpty) return const [];
    if (!ready) {
      throw StateError('未配置 Embedding API Key，无法建立工程索引。');
    }
    final out = <List<double>>[];
    final client = http.Client();
    try {
      for (var i = 0; i < inputs.length; i += _batchSize) {
        if (isCancelled?.call() ?? false) break;
        final batch = inputs.sublist(
            i, math.min(i + _batchSize, inputs.length));
        final vectors = await _embedBatch(client, batch, timeout);
        out.addAll(vectors);
        onProgress?.call(out.length, inputs.length);
      }
    } finally {
      client.close();
    }
    return out;
  }

  /// 单条文本向量化（用于检索 query）。
  Future<List<double>> embedOne(String input,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final r = await embed([input], timeout: timeout);
    if (r.isEmpty) throw StateError('向量化失败：无返回。');
    return r.first;
  }

  Future<List<List<double>>> _embedBatch(
      http.Client client, List<String> batch, Duration timeout) async {
    final uri = Uri.parse('${settings.embeddingBaseUrl}/embeddings');
    final resp = await client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer ${settings.embeddingApiKey}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': settings.embeddingModel,
            'input': batch,
            'encoding_format': 'float',
          }),
        )
        .timeout(timeout);
    if (resp.statusCode != 200) {
      throw Exception('Embedding HTTP ${resp.statusCode}: '
          '${_clip(utf8.decode(resp.bodyBytes), 400)}');
    }
    final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final data = json['data'];
    if (data is! List) throw Exception('Embedding 返回格式异常。');
    // 按 index 排序，保证与输入顺序一致。
    final items = data.whereType<Map>().toList()
      ..sort((a, b) =>
          ((a['index'] as num?) ?? 0).compareTo((b['index'] as num?) ?? 0));
    return [
      for (final item in items)
        _normalize([
          for (final v in (item['embedding'] as List? ?? const []))
            (v as num).toDouble(),
        ]),
    ];
  }

  static List<double> _normalize(List<double> v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    final norm = math.sqrt(sum);
    if (norm == 0) return v;
    return [for (final x in v) x / norm];
  }

  static String _clip(String s, int max) => clip(s, max, suffix: '…');
}
