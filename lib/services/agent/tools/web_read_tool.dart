import '../../web_reader.dart';
import '../tool.dart';

/// 让 Agent 能读取任意网页正文（跨模块共享能力）。
///
/// 复用 [WebReader]（Jina Reader）：项目/实验/计划等 Agent 调用本工具即可
/// 查资料、读文档、读 GitHub 页面，无需各自实现网页抓取。
class WebReadTool extends AgentTool {
  WebReadTool({WebReader? reader}) : _reader = reader ?? WebReader();

  final WebReader _reader;

  @override
  String get name => 'read_url';

  @override
  String get description =>
      '读取一个网页链接的正文，返回清洗后的 Markdown 文本（经 Jina Reader，免浏览器）。'
      '适合查资料、读在线文档、读 GitHub 页面等。';

  @override
  bool get isReadOnly => true;

  @override
  int get maxResultChars => 20000;

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': '要读取的网页地址'},
        },
        'required': ['url'],
      };

  @override
  String describeCall(Map<String, dynamic> input) => '读取网页 ${input['url']}';

  @override
  Future<ToolResult> call(Map<String, dynamic> input, ToolContext ctx) async {
    final url = (input['url'] ?? '').toString().trim();
    if (url.isEmpty) return ToolResult.error('缺少 url 参数');
    final md = await _reader.readMarkdown(url);
    if (md == null) return ToolResult.error('无法读取该网页正文：$url');
    return ToolResult(md);
  }
}
