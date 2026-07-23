import '../../../util/text_util.dart';
import '../tool.dart';

/// 工作记事板工具（对应 GenericAgent 的 working checkpoint）：
/// Agent 在长任务中随时**覆写**一块"当前任务记事板"（目标/已完成/下一步/关键结论）。
/// 上下文压缩裁掉早期消息后，最新记事板会以 system-reminder 形式保留，
/// 防止中间结论在长任务中被裁丢。
class CheckpointTool extends AgentTool {
  @override
  String get name => 'update_working_checkpoint';

  @override
  String get description =>
      '覆写你的"当前任务记事板"。长任务中在关键节点调用：写清 目标/已完成/下一步/关键结论。'
      '上下文被压缩后记事板内容仍会保留给你，这是你唯一不会丢失的短期备忘。'
      '每次调用是整体覆盖（不是追加），请写完整。';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'content': {
            'type': 'string',
            'description':
                'Markdown 记事板全文，建议结构：## 目标 / ## 已完成 / ## 下一步 / ## 关键结论',
          },
        },
        'required': ['content'],
      };

  @override
  String? validate(Map<String, dynamic> input) {
    final c = (input['content'] ?? '').toString().trim();
    if (c.isEmpty) return 'content 不能为空。';
    return null;
  }

  @override
  String describeCall(Map<String, dynamic> input) => '更新工作记事板';

  @override
  Future<ToolResult> call(Map<String, dynamic> input, ToolContext ctx) async {
    final content = (input['content'] ?? '').toString().trim();
    // 限制长度：记事板是备忘不是仓库，过长会挤占压缩后的上下文预算。
    const maxLen = 4000;
    ctx.workingCheckpoint = clip(content, maxLen);
    return ToolResult('记事板已更新（${ctx.workingCheckpoint.length} 字）。');
  }
}
