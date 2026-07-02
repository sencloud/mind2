import 'dart:io';

/// 工具执行上下文：贯穿一次 agent 会话，提供工作目录、日志、取消信号等。
class ToolContext {
  ToolContext({
    required this.projectDir,
    required this.log,
    required this.isCancelled,
    this.depth = 0,
  });

  /// 实验工程根目录；所有读写都被限定在此目录内。
  final Directory projectDir;

  /// 向 UI / 日志输出一行。
  final void Function(String line) log;

  /// 是否已请求中止。
  final bool Function() isCancelled;

  /// 当前 agent 的嵌套深度（主 agent=0，子 agent 递增）。
  final int depth;

  /// 工作记事板（由 update_working_checkpoint 工具覆写）：
  /// 长任务的中间结论备忘，上下文压缩后由 Compactor 以 system-reminder 保留。
  String workingCheckpoint = '';

  String get root => projectDir.path;
}

/// 工具执行结果：回灌给模型的文本内容 + 是否为错误。
class ToolResult {
  ToolResult(this.content, {this.isError = false});

  factory ToolResult.error(String message) =>
      ToolResult(message, isError: true);

  final String content;
  final bool isError;
}

/// 单个工具的统一抽象（对应 Claude Code 的 Tool<Input>）。
abstract class AgentTool {
  /// 模型看到的工具名（函数名）。
  String get name;

  /// 模型看到的工具描述（function calling 的 description）。
  String get description;

  /// 入参的 JSON Schema（type:object，含 properties / required）。
  Map<String, dynamic> get parameters;

  /// 只读工具不修改磁盘；用于权限与并发判断。
  bool get isReadOnly => false;

  /// 是否可与相邻的同类工具并发执行（只读工具通常可并发）。
  bool get isConcurrencySafe => isReadOnly;

  /// 结果回灌给模型时的最大字符数，超出将被截断。
  int get maxResultChars => 30000;

  /// 轻量入参校验：返回错误信息字符串，或 null 表示通过。
  String? validate(Map<String, dynamic> input) => null;

  /// 本次调用将访问/修改的工程内相对或绝对路径（供权限模块做目录限定）。
  /// 默认空表示不涉及具体文件路径（如 bash 由命令层面单独校验）。
  List<String> affectedPaths(Map<String, dynamic> input) => const [];

  /// 实际执行。
  Future<ToolResult> call(Map<String, dynamic> input, ToolContext ctx);

  /// 一行式的「正在做什么」描述，用于日志（可被子类覆盖）。
  String describeCall(Map<String, dynamic> input) => name;
}
