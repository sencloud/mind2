import '../../topic_service.dart';
import '../tool.dart';

/// 让 Agent 触发一次完整的「主题研究」（跨模块：Agent → 主题研究）。
///
/// 复用 [TopicFetchService] 的研究流程：自动多来源检索、读资料、综合写报告并
/// 存入知识库，最后把报告正文回灌给 Agent。耗时较长，且同一时间只能跑一个。
class DeepResearchTool extends AgentTool {
  DeepResearchTool(this.research);

  final TopicFetchService research;

  @override
  String get name => 'deep_research';

  @override
  String get description =>
      '对某个主题做一次完整的深度研究：自动检索多来源、阅读资料、综合撰写研究报告'
      '并存入知识库，返回报告正文。耗时较长，适合需要系统性调研的任务。';

  // 会写入知识库笔记，且同一时间只允许一个研究在跑。
  @override
  bool get isReadOnly => false;

  @override
  bool get isConcurrencySafe => false;

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'topic': {'type': 'string', 'description': '研究主题'},
          'clarification': {
            'type': 'string',
            'description': '对研究方向/范围的补充说明，可选',
          },
        },
        'required': ['topic'],
      };

  @override
  String describeCall(Map<String, dynamic> input) => '深度研究：${input['topic']}';

  @override
  Future<ToolResult> call(Map<String, dynamic> input, ToolContext ctx) async {
    final topic = (input['topic'] ?? '').toString().trim();
    if (topic.isEmpty) return ToolResult.error('缺少 topic 参数');
    final clarification = (input['clarification'] ?? '').toString().trim();
    try {
      final report = await research.researchForAgent(
        topic,
        clarification: clarification,
        log: ctx.log, // 研究进度实时回传到 Agent 日志/界面。
      );
      return ToolResult(report);
    } catch (e) {
      return ToolResult.error('深度研究失败：$e');
    }
  }
}
