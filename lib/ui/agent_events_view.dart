import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../services/agent/agent_event.dart';

/// 复用「做实验 / 项目开发」Agent 运行过程的结构化展示：
/// 状态行、助手文本（含 `<think>` 折叠）、工具调用卡片（可展开输出）。
class AgentEventsView extends StatefulWidget {
  const AgentEventsView({
    super.key,
    required this.events,
    this.controller,
    this.padding = const EdgeInsets.fromLTRB(20, 0, 20, 20),
    this.onOpenFile,
    this.onResend,
  });

  final List<AgentEvent> events;
  final ScrollController? controller;
  final EdgeInsets padding;

  /// 点击「改动文件」时回调（传入相对工程根的路径）。
  final void Function(String relPath)? onOpenFile;

  /// 点击用户消息上的「重发」时回调（传入该用户消息事件）。
  /// 为 null 时不显示重发按钮（例如运行中或不支持重发的场景）。
  final void Function(AgentEvent userEvent)? onResend;

  @override
  State<AgentEventsView> createState() => _AgentEventsViewState();
}

class _AgentEventsViewState extends State<AgentEventsView> {
  final Set<int> _expandedSteps = {};
  final Map<String, bool> _expandedThinks = {};
  final Map<int, bool> _expandedGroups = {};

  @override
  Widget build(BuildContext context) {
    final items = _groupItems();
    return ListView.builder(
      controller: widget.controller,
      padding: widget.padding,
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        if (item.indices.length == 1) {
          final idx = item.indices.first;
          return _buildEventItem(widget.events[idx], idx);
        }
        return _buildToolGroup(item.indices, isLast: i == items.length - 1);
      },
    );
  }

  /// 把连续的工具事件合并为一个分组（其余事件各自独立），便于折叠、更紧凑。
  List<_RenderItem> _groupItems() {
    final items = <_RenderItem>[];
    var i = 0;
    while (i < widget.events.length) {
      if (widget.events[i].kind == AgentEventKind.tool) {
        final group = <int>[];
        while (i < widget.events.length &&
            widget.events[i].kind == AgentEventKind.tool) {
          group.add(i);
          i++;
        }
        items.add(_RenderItem(group));
      } else {
        items.add(_RenderItem([i]));
        i++;
      }
    }
    return items;
  }

  Widget _buildToolGroup(List<int> indices, {required bool isLast}) {
    final start = indices.first;
    final expanded = _expandedGroups[start] ?? isLast;
    final running = indices.any(
        (i) => widget.events[i].status == StepStatus.running);
    final hasError =
        indices.any((i) => widget.events[i].status == StepStatus.error);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () =>
                setState(() => _expandedGroups[start] = !expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
              child: Row(
                children: [
                  Icon(
                      running
                          ? Icons.autorenew
                          : (hasError
                              ? Icons.error_outline
                              : Icons.done_all),
                      size: 13,
                      color: running
                          ? const Color(0xFF0D9488)
                          : (hasError
                              ? const Color(0xFFDC2626)
                              : const Color(0xFFA0A0A8))),
                  const SizedBox(width: 6),
                  Text('${indices.length} 个操作步骤',
                      style: const TextStyle(
                          fontSize: 11.5, color: Color(0xFF8A8A92))),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      size: 15, color: const Color(0xFFA0A0A8)),
                ],
              ),
            ),
          ),
          if (expanded)
            for (final idx in indices) _buildToolCard(widget.events[idx], idx),
        ],
      ),
    );
  }

  Widget _buildEventItem(AgentEvent e, int index) {
    switch (e.kind) {
      case AgentEventKind.status:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.circle, size: 5, color: Color(0xFFC4C4CC)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(e.text,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF8A8A92))),
              ),
            ],
          ),
        );
      case AgentEventKind.assistant:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2, right: 8),
                child: Icon(Icons.auto_awesome,
                    size: 14, color: Color(0xFF0D9488)),
              ),
              Expanded(child: _buildAssistantContent(e.text, index)),
            ],
          ),
        );
      case AgentEventKind.tool:
        return _buildToolCard(e, index);
      case AgentEventKind.changes:
        return _buildChangesCard(e);
      case AgentEventKind.user:
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1, right: 8),
                child: Icon(Icons.person_outline,
                    size: 15, color: Color(0xFF6B6B70)),
              ),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F3F8),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE2E7EF)),
                  ),
                  child: SelectableText(
                    e.text,
                    style: const TextStyle(
                        fontSize: 13, height: 1.5, color: Color(0xFF1F2937)),
                  ),
                ),
              ),
              // 重发按钮：失败或想重试时，按相同消息再跑一次。
              if (widget.onResend != null)
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: IconButton(
                    tooltip: '重发',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh,
                        size: 15, color: Color(0xFF6B6B70)),
                    onPressed: () => widget.onResend!(e),
                  ),
                ),
            ],
          ),
        );
    }
  }

  Widget _buildChangesCard(AgentEvent e) {
    final files = e.detail
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF1FAF8),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFCDEAE4)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.edit_note,
                    size: 16, color: Color(0xFF0D9488)),
                const SizedBox(width: 6),
                Text(e.text,
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF0F766E))),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final f in files)
                  Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: widget.onOpenFile == null
                          ? null
                          : () => widget.onOpenFile!(f),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFD5E9E5)),
                        ),
                        child: Text(f,
                            style: const TextStyle(
                                fontSize: 11.5,
                                fontFamily: 'Consolas',
                                color: Color(0xFF0F766E))),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAssistantContent(String text, int index) {
    final segs = _splitThink(text);
    if (segs.length == 1 && !segs.first.isThink) {
      return _md(segs.first.text);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < segs.length; i++)
          if (segs[i].isThink)
            _buildThinkBlock(segs[i].text, '$index-$i', segs[i].closed)
          else if (segs[i].text.trim().isNotEmpty)
            _md(segs[i].text),
      ],
    );
  }

  Widget _buildThinkBlock(String text, String key, bool closed) {
    final expanded = _expandedThinks[key] ?? !closed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expandedThinks[key] = !expanded),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.psychology_outlined,
                      size: 13, color: Color(0xFFA0A0A8)),
                  const SizedBox(width: 5),
                  Text(closed ? '思考过程' : '思考中…',
                      style: const TextStyle(
                          fontSize: 11.5, color: Color(0xFFA0A0A8))),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      size: 15, color: const Color(0xFFA0A0A8)),
                ],
              ),
            ),
          ),
          if (expanded)
            Container(
              margin: const EdgeInsets.only(top: 2, bottom: 2, left: 2),
              padding: const EdgeInsets.only(left: 8),
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: Color(0xFFE2E2E8), width: 2),
                ),
              ),
              child: MarkdownBody(
                data: text.trim(),
                selectable: true,
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(
                      fontSize: 11.5, height: 1.55, color: Color(0xFF9A9AA2)),
                  listBullet: const TextStyle(
                      fontSize: 11.5, color: Color(0xFF9A9AA2)),
                  code: const TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'Consolas',
                      color: Color(0xFF8A8A92),
                      backgroundColor: Color(0xFFF1F1F4)),
                  strong: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF85858E)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _md(String data) => MarkdownBody(
        data: data,
        selectable: true,
        styleSheet: MarkdownStyleSheet(
          p: const TextStyle(
              fontSize: 13, height: 1.6, color: Color(0xFF374151)),
          h1: const TextStyle(
              fontSize: 16,
              height: 1.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1F2937)),
          h2: const TextStyle(
              fontSize: 15,
              height: 1.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1F2937)),
          h3: const TextStyle(
              fontSize: 13.5,
              height: 1.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1F2937)),
          code: const TextStyle(
              fontSize: 12,
              fontFamily: 'Consolas',
              backgroundColor: Color(0xFFEFF1F4)),
          tableHead:
              const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          tableBody: const TextStyle(fontSize: 12, height: 1.4),
          tableBorder:
              TableBorder.all(color: const Color(0xFFE0E2E6), width: 1),
          a: const TextStyle(color: Color(0xFF0D9488)),
          blockquote:
              const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
        ),
      );

  List<_TextSeg> _splitThink(String input) {
    final segs = <_TextSeg>[];
    var i = 0;
    while (i < input.length) {
      final open = input.indexOf('<think>', i);
      if (open < 0) {
        segs.add(_TextSeg(input.substring(i), false, true));
        break;
      }
      if (open > i) segs.add(_TextSeg(input.substring(i, open), false, true));
      final close = input.indexOf('</think>', open + 7);
      if (close < 0) {
        segs.add(_TextSeg(input.substring(open + 7), true, false));
        break;
      }
      segs.add(_TextSeg(input.substring(open + 7, close), true, true));
      i = close + 8;
    }
    return segs.isEmpty ? [_TextSeg('', false, true)] : segs;
  }

  Widget _buildToolCard(AgentEvent e, int index) {
    final expanded = _expandedSteps.contains(index);
    final hasDetail = e.detail.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE6E8EC)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: hasDetail
                  ? () => setState(() => expanded
                      ? _expandedSteps.remove(index)
                      : _expandedSteps.add(index))
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                child: Row(
                  children: [
                    Icon(_toolIcon(e.tool),
                        size: 15, color: const Color(0xFF0D9488)),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        e.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF374151),
                            fontFamily: 'Consolas'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _stepStatusIcon(e.status),
                    if (hasDetail)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(
                            expanded ? Icons.expand_less : Icons.expand_more,
                            size: 16,
                            color: const Color(0xFFAEAEB6)),
                      ),
                  ],
                ),
              ),
            ),
            if (expanded && hasDetail)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F2F5),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFE6E8EC)),
                ),
                child: SelectableText(
                  e.detail.length > 6000
                      ? '${e.detail.substring(0, 6000)}\n…（输出过长已截断）'
                      : e.detail,
                  style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.5,
                      fontFamily: 'Consolas',
                      color: Color(0xFF4B5563)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _stepStatusIcon(StepStatus s) {
    switch (s) {
      case StepStatus.running:
        return const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
                strokeWidth: 1.8, color: Color(0xFF0D9488)));
      case StepStatus.done:
        return const Icon(Icons.check_circle,
            size: 14, color: Color(0xFF16A34A));
      case StepStatus.error:
        return const Icon(Icons.error_outline,
            size: 14, color: Color(0xFFDC2626));
    }
  }

  IconData _toolIcon(String tool) => switch (tool) {
        'read_file' => Icons.description_outlined,
        'write_file' => Icons.note_add_outlined,
        'edit_file' => Icons.edit_outlined,
        'bash' => Icons.terminal,
        'glob' => Icons.folder_open_outlined,
        'grep' => Icons.search,
        'codebase_search' => Icons.manage_search,
        'tool_search' => Icons.travel_explore,
        'task' => Icons.account_tree_outlined,
        'skill' => Icons.auto_awesome,
        'update_working_checkpoint' => Icons.push_pin_outlined,
        _ => Icons.build_outlined,
      };
}

/// 渲染项：要么是单个事件，要么是连续工具步骤的分组。
class _RenderItem {
  _RenderItem(this.indices);
  final List<int> indices;
}

class _TextSeg {
  _TextSeg(this.text, this.isThink, this.closed);

  final String text;
  final bool isThink;
  final bool closed;
}
