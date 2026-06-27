/// Agent 对话的消息与内容模型（OpenAI / DeepSeek 兼容的 chat 协议）。
///
/// 角色：system / user / assistant / tool。assistant 可携带 tool_calls；
/// tool 消息通过 tool_call_id 回应对应的工具调用。
library;

/// 模型发起的一次工具调用。
class ToolCall {
  ToolCall({required this.id, required this.name, required this.arguments});

  final String id;
  final String name;

  /// 原始 JSON 字符串形式的参数（流式拼接得到，可能为空字符串）。
  final String arguments;

  Map<String, dynamic> toApi() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      };
}

/// 模型一轮回复：可能含文本、推理过程与若干工具调用。
class AssistantTurn {
  AssistantTurn({
    this.content = '',
    this.reasoning = '',
    List<ToolCall>? toolCalls,
    this.finishReason,
  }) : toolCalls = toolCalls ?? [];

  final String content;
  final String reasoning;
  final List<ToolCall> toolCalls;
  final String? finishReason;

  bool get hasToolCalls => toolCalls.isNotEmpty;

  /// 转为发回 API 的 assistant 消息。
  Map<String, dynamic> toApi() => {
        'role': 'assistant',
        if (content.isNotEmpty) 'content': content else 'content': null,
        if (toolCalls.isNotEmpty)
          'tool_calls': toolCalls.map((c) => c.toApi()).toList(),
      };
}

/// 构造各类消息的工具方法。
class Msg {
  static Map<String, dynamic> system(String content) =>
      {'role': 'system', 'content': content};

  static Map<String, dynamic> user(String content) =>
      {'role': 'user', 'content': content};

  static Map<String, dynamic> assistant(AssistantTurn turn) => turn.toApi();

  /// 工具执行结果，回应某个 tool_call。
  static Map<String, dynamic> tool({
    required String toolCallId,
    required String content,
  }) =>
      {
        'role': 'tool',
        'tool_call_id': toolCallId,
        'content': content,
      };
}
