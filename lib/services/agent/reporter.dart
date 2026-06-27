/// Agent 运行过程的结构化上报通道：把「状态 / 助手文本 / 工具调用」事件
/// 解耦地交给上层（UI）渲染，而不是拼成一串纯文本日志。
class AgentReporter {
  AgentReporter({
    this.onStatus,
    this.onAssistantDelta,
    this.onAssistantText,
    this.onToolStart,
    this.onToolEnd,
  });

  /// 静默上报（用于子 agent，不向主时间线输出噪音）。
  factory AgentReporter.silent() => AgentReporter();

  /// 流程状态（如"进入执行循环""达最大轮数"）。
  final void Function(String text)? onStatus;

  /// 助手文本流式增量。
  final void Function(String delta)? onAssistantDelta;

  /// 助手一段完整文本（本轮 thinking/说明）。
  final void Function(String text)? onAssistantText;

  /// 工具调用开始：callId 唯一标识，tool 为工具名，title 为可读标题。
  final void Function(String callId, String tool, String title)? onToolStart;

  /// 工具调用结束：isError 表示失败，result 为返回内容。
  final void Function(String callId, bool isError, String result)? onToolEnd;
}
