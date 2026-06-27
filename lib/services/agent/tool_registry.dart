import 'tool.dart';

/// 工具注册表：持有可用工具，按名查找，并生成发给模型的 tools JSON Schema。
///
/// 支持「延迟加载」（deferred）：被标记为 deferred 的工具默认不暴露给模型，
/// 需经 tool_search 按关键词搜索并 activate 后才出现在 schema 中
/// （对应 Claude Code 的 ToolSearch / defer_loading 机制）。
class ToolRegistry {
  ToolRegistry(List<AgentTool> tools, {Set<String> deferred = const {}})
      : _byName = {for (final t in tools) t.name: t},
        _tools = List.unmodifiable(tools),
        _deferred = {...deferred},
        _activated = {};

  final Map<String, AgentTool> _byName;
  final List<AgentTool> _tools;
  final Set<String> _deferred;
  final Set<String> _activated;

  List<AgentTool> get tools => _tools;

  AgentTool? find(String name) => _byName[name];

  bool _visible(AgentTool t) =>
      !_deferred.contains(t.name) || _activated.contains(t.name);

  /// 当前对模型可见的工具（含已激活的延迟工具）。
  List<AgentTool> get visibleTools => [
        for (final t in _tools)
          if (_visible(t)) t,
      ];

  /// 启用若干延迟工具。
  void activate(Iterable<String> names) {
    for (final n in names) {
      if (_byName.containsKey(n)) _activated.add(n);
    }
  }

  /// 在「尚未激活的延迟工具」中按关键词搜索。
  List<AgentTool> searchDeferred(String query) {
    final terms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList();
    return [
      for (final t in _tools)
        if (_deferred.contains(t.name) && !_activated.contains(t.name))
          if (terms.isEmpty ||
              terms.any((term) =>
                  t.name.toLowerCase().contains(term) ||
                  t.description.toLowerCase().contains(term)))
            t,
    ];
  }

  /// 转为 OpenAI/DeepSeek function calling 的 tools 数组（仅含可见工具）。
  List<Map<String, dynamic>> toApiSchema() => [
        for (final t in visibleTools)
          {
            'type': 'function',
            'function': {
              'name': t.name,
              'description': t.description,
              'parameters': t.parameters,
            },
          },
      ];
}
