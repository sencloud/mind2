/// 面向 UI 的 agent 运行事件，用于像 Cursor 那样以结构化卡片展示过程，
/// 而不是一串纯文本日志。
enum AgentEventKind { status, assistant, tool, user, changes }

enum StepStatus { running, done, error }

class AgentEvent {
  AgentEvent({
    required this.kind,
    this.text = '',
    this.tool = '',
    this.title = '',
    this.detail = '',
    this.status = StepStatus.running,
  });

  /// 流程状态行（轻量、灰色）。
  factory AgentEvent.status(String text) =>
      AgentEvent(kind: AgentEventKind.status, text: text, status: StepStatus.done);

  /// 助手文本（思考/说明）。
  factory AgentEvent.assistant(String text) =>
      AgentEvent(kind: AgentEventKind.assistant, text: text);

  /// 工具调用卡片。
  factory AgentEvent.tool({required String tool, required String title}) =>
      AgentEvent(kind: AgentEventKind.tool, tool: tool, title: title);

  /// 用户发出的指令/需求（像聊天里的用户气泡）。
  factory AgentEvent.user(String text) =>
      AgentEvent(kind: AgentEventKind.user, text: text, status: StepStatus.done);

  /// 本轮改动文件摘要：[text] 为概述，[detail] 为以换行分隔的文件相对路径列表。
  factory AgentEvent.changes(String text, List<String> files) => AgentEvent(
        kind: AgentEventKind.changes,
        text: text,
        detail: files.join('\n'),
        status: StepStatus.done,
      );

  final AgentEventKind kind;

  /// status / assistant / user 的文本内容。
  String text;

  /// 工具名（用于选图标）。
  String tool;

  /// 工具标题（可读，如「执行：python x.py」）。
  String title;

  /// 工具输出/结果（可展开查看）。
  String detail;

  StepStatus status;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'text': text,
        'tool': tool,
        'title': title,
        'detail': detail,
        'status': status.name,
      };

  factory AgentEvent.fromJson(Map<String, dynamic> j) => AgentEvent(
        kind: AgentEventKind.values.firstWhere(
            (k) => k.name == j['kind'],
            orElse: () => AgentEventKind.status),
        text: j['text'] as String? ?? '',
        tool: j['tool'] as String? ?? '',
        title: j['title'] as String? ?? '',
        detail: j['detail'] as String? ?? '',
        status: StepStatus.values.firstWhere(
            (s) => s.name == j['status'],
            orElse: () => StepStatus.done),
      );
}
