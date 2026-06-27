import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../settings_service.dart';
import 'messages.dart';

/// 与模型对话的客户端：OpenAI/DeepSeek 兼容的 `/chat/completions`，
/// 支持 SSE 流式输出与原生 Function Calling（tools / tool_calls / tool 角色）。
///
/// 两条通道：
/// - 默认（实验/项目主循环）：使用设置里所选的实验模型供应商
///   （`experimentBaseUrl/experimentApiKey/experimentModel`）。
/// - 小模型（`small: true`）：使用通用默认模型（`baseUrl/apiKey/model`，内置 DeepSeek），
///   用于记忆「选择题/抽取」这类廉价任务，对应 Claude Code「用小模型做选择」的设计。
class ModelClient {
  ModelClient(this.settings, {this.small = false});

  final SettingsService settings;

  /// 是否走小模型通道（记忆选择/抽取等廉价任务）。
  final bool small;

  String get _baseUrl => small ? settings.baseUrl : settings.experimentBaseUrl;
  String get _apiKey => small ? settings.apiKey : settings.experimentApiKey;
  String get _model => small ? settings.model : settings.experimentModel;

  /// 流式发起一轮对话。
  /// - [messages]：完整消息数组（API 形态）。
  /// - [tools]：工具的 JSON Schema 列表（为空则不带 tools）。
  /// - [onTextDelta]：文本增量回调（用于逐字实时显示）。
  /// - [onReasoningDelta]：推理过程增量（DeepSeek reasoning_content，可选）。
  /// - [onToolCallStart]：当某个工具调用的名字确定时回调一次。
  /// - [isCancelled]：返回 true 时尽快中止。
  Future<AssistantTurn> stream({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onTextDelta,
    void Function(String delta)? onReasoningDelta,
    void Function(String toolName)? onToolCallStart,
    bool Function()? isCancelled,
    bool jsonMode = false,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final uri = Uri.parse('$_baseUrl/chat/completions');
    final body = <String, dynamic>{
      'model': _model,
      'stream': true,
      'messages': messages,
      if (jsonMode) 'response_format': {'type': 'json_object'},
      if (tools != null && tools.isNotEmpty) ...{
        'tools': tools,
        'tool_choice': 'auto',
      },
    };

    final client = http.Client();
    try {
      final req = http.Request('POST', uri)
        ..headers['Authorization'] = 'Bearer $_apiKey'
        ..headers['Content-Type'] = 'application/json'
        ..headers['Accept'] = 'text/event-stream'
        ..body = jsonEncode(body);

      final resp = await client.send(req).timeout(timeout);
      if (resp.statusCode != 200) {
        final text = await resp.stream.bytesToString();
        throw Exception('HTTP ${resp.statusCode}: ${_clip(text, 400)}');
      }

      final buf = _ToolCallAccumulator(onToolCallStart);
      final content = StringBuffer();
      final reasoning = StringBuffer();
      String? finishReason;

      final lines = resp.stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());

      await for (final line in lines) {
        if (isCancelled?.call() ?? false) break;
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;
        Map<String, dynamic> json;
        try {
          json = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final choices = json['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final choice = choices.first as Map<String, dynamic>;
        final delta = choice['delta'];
        if (delta is Map<String, dynamic>) {
          final c = delta['content'];
          if (c is String && c.isNotEmpty) {
            content.write(c);
            onTextDelta?.call(c);
          }
          final r = delta['reasoning_content'];
          if (r is String && r.isNotEmpty) {
            reasoning.write(r);
            onReasoningDelta?.call(r);
          }
          final tc = delta['tool_calls'];
          if (tc is List) buf.add(tc);
        }
        final fr = choice['finish_reason'];
        if (fr is String && fr.isNotEmpty) finishReason = fr;
      }

      return AssistantTurn(
        content: content.toString(),
        reasoning: reasoning.toString(),
        toolCalls: buf.build(),
        finishReason: finishReason,
      );
    } finally {
      client.close();
    }
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}

/// 累积流式 tool_calls 分片（按 index 聚合 id/name/arguments）。
class _ToolCallAccumulator {
  _ToolCallAccumulator(this.onToolCallStart);

  final void Function(String toolName)? onToolCallStart;
  final Map<int, _PartialCall> _calls = {};

  void add(List<dynamic> deltas) {
    for (final d in deltas) {
      if (d is! Map) continue;
      final index = (d['index'] as int?) ?? 0;
      final call = _calls.putIfAbsent(index, () => _PartialCall());
      final id = d['id'];
      if (id is String && id.isNotEmpty) call.id = id;
      final fn = d['function'];
      if (fn is Map) {
        final name = fn['name'];
        if (name is String && name.isNotEmpty) {
          final wasEmpty = call.name.isEmpty;
          call.name = name;
          if (wasEmpty) onToolCallStart?.call(name);
        }
        final args = fn['arguments'];
        if (args is String) call.args.write(args);
      }
    }
  }

  List<ToolCall> build() {
    final keys = _calls.keys.toList()..sort();
    return [
      for (final k in keys)
        ToolCall(
          id: _calls[k]!.id.isEmpty ? 'call_$k' : _calls[k]!.id,
          name: _calls[k]!.name,
          arguments: _calls[k]!.args.toString(),
        ),
    ];
  }
}

class _PartialCall {
  String id = '';
  String name = '';
  final StringBuffer args = StringBuffer();
}
