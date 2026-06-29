import 'package:flutter/material.dart';

import '../services/plan_service.dart';
import 'agent_events_view.dart';

/// 「计划」页面：像普通待办工具一样添加每日待办，
/// 但事项列表上有「AI 分析并执行」能力——可按顺序或并行让第二大脑动手执行。
class PlanPage extends StatefulWidget {
  const PlanPage({super.key, required this.plan});

  final PlanService plan;

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  final _controller = TextEditingController();

  /// 批量执行方式：true=并行，false=按顺序。
  bool _parallel = false;

  /// 当前在右侧详情面板查看执行过程的待办 id。
  String? _selectedId;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _addTodo() {
    widget.plan.add(_controller.text);
    _controller.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.plan,
      builder: (context, _) {
        final plan = widget.plan;
        return Padding(
          padding: const EdgeInsets.all(32),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildMainArea(plan)),
              const SizedBox(width: 20),
              SizedBox(width: 380, child: _buildDetailPanel(plan)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMainArea(PlanService plan) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '计划',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        const Text(
          '添加每日待办，并交给第二大脑以 Agent 模式真正动手执行——可按顺序或并行批量完成。',
          style: TextStyle(fontSize: 13, color: Color(0xFF6B6B70)),
        ),
        const SizedBox(height: 18),
        _buildInputRow(),
        const SizedBox(height: 14),
        _buildToolbar(plan),
        const SizedBox(height: 14),
        Expanded(child: _buildTodoList(plan)),
      ],
    );
  }

  Widget _buildInputRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: '添加一个待办事项，例如：整理本周竞品调研并写成对比表',
              hintStyle: const TextStyle(color: Color(0xFFA8A8AC)),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFD9D9DD)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFD9D9DD)),
              ),
            ),
            onSubmitted: (_) => _addTodo(),
          ),
        ),
        const SizedBox(width: 10),
        FilledButton.icon(
          onPressed: _addTodo,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1A1A1A),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          ),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加'),
        ),
      ],
    );
  }

  Widget _buildToolbar(PlanService plan) {
    final running = plan.anyRunning;
    return Row(
      children: [
        // 执行方式切换：按顺序 / 并行
        _ModeToggle(
          parallel: _parallel,
          onChanged: (v) => setState(() => _parallel = v),
        ),
        const Spacer(),
        if (running)
          TextButton.icon(
            onPressed: plan.cancelAll,
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('全部停止'),
          ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: running
              ? null
              : () => plan.executeAll(parallel: _parallel),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF0D9488),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          icon: running
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.auto_awesome, size: 16),
          label: Text(running ? '执行中…' : 'AI 分析并执行全部'),
        ),
      ],
    );
  }

  Widget _buildTodoList(PlanService plan) {
    if (plan.todos.isEmpty) {
      return const Center(
        child: Text(
          '还没有待办。在上方输入框添加一个吧。',
          style: TextStyle(fontSize: 13, color: Color(0xFF9B9B9F)),
        ),
      );
    }
    return ListView.builder(
      itemCount: plan.todos.length,
      itemBuilder: (context, i) {
        final t = plan.todos[i];
        return _TodoTile(
          todo: t,
          selected: t.id == _selectedId,
          onTap: () => setState(() => _selectedId = t.id),
          onToggleDone: () => plan.toggleDone(t),
          onRun: () {
            setState(() => _selectedId = t.id);
            plan.executeOne(t);
          },
          onCancel: () => plan.cancel(t),
          onDelete: () => plan.remove(t),
        );
      },
    );
  }

  Widget _buildDetailPanel(PlanService plan) {
    PlanTodo? todo;
    for (final t in plan.todos) {
      if (t.id == _selectedId) {
        todo = t;
        break;
      }
    }
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(14),
      ),
      child: todo == null
          ? const Center(
              child: Text(
                '选择一个待办，查看 AI 执行过程',
                style: TextStyle(fontSize: 13, color: Color(0xFFB9B9BD)),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 12, 10),
                  child: Row(
                    children: [
                      const Icon(Icons.auto_awesome,
                          size: 16, color: Color(0xFF0D9488)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          todo.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFE8E8EA)),
                Expanded(
                  child: todo.events.isEmpty
                      ? Center(
                          child: Text(
                            todo.result.isEmpty
                                ? '点击「执行」后，AI 的分析与动手过程会显示在这里'
                                : todo.result,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: Color(0xFF9B9B9F),
                            ),
                          ),
                        )
                      : AgentEventsView(
                          key: ValueKey(todo.id),
                          events: todo.events,
                        ),
                ),
              ],
            ),
    );
  }
}

/// 执行方式切换：按顺序 / 并行。
class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.parallel, required this.onChanged});

  final bool parallel;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 12.5),
      ),
      segments: const [
        ButtonSegment(
          value: false,
          label: Text('按顺序'),
          icon: Icon(Icons.format_list_numbered, size: 15),
        ),
        ButtonSegment(
          value: true,
          label: Text('并行'),
          icon: Icon(Icons.account_tree_outlined, size: 15),
        ),
      ],
      selected: {parallel},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

/// 单个待办的列表项：勾选、标题、状态、执行/停止、删除。
class _TodoTile extends StatelessWidget {
  const _TodoTile({
    required this.todo,
    required this.selected,
    required this.onTap,
    required this.onToggleDone,
    required this.onRun,
    required this.onCancel,
    required this.onDelete,
  });

  final PlanTodo todo;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleDone;
  final VoidCallback onRun;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFFE8F5F3) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
          child: Row(
            children: [
              Checkbox(
                value: todo.done,
                visualDensity: VisualDensity.compact,
                onChanged: (_) => onToggleDone(),
              ),
              Expanded(
                child: Text(
                  todo.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.35,
                    color: todo.done
                        ? const Color(0xFFA8A8AC)
                        : const Color(0xFF2B2B2E),
                    decoration:
                        todo.done ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _statusBadge(todo.status),
              const SizedBox(width: 4),
              if (todo.running)
                IconButton(
                  tooltip: '停止',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  onPressed: onCancel,
                  icon: const Icon(Icons.stop_circle_outlined,
                      color: Color(0xFFDC2626)),
                )
              else
                IconButton(
                  tooltip: 'AI 执行这一项',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  onPressed: onRun,
                  icon: const Icon(Icons.play_circle_outline,
                      color: Color(0xFF0D9488)),
                ),
              IconButton(
                tooltip: '删除',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                onPressed: onDelete,
                icon: const Icon(Icons.close, color: Color(0xFFB9B9BD)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusBadge(PlanStatus s) {
    switch (s) {
      case PlanStatus.running:
        return const SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Color(0xFF0D9488)),
        );
      case PlanStatus.success:
        return const Icon(Icons.check_circle, size: 16, color: Color(0xFF16A34A));
      case PlanStatus.error:
        return const Icon(Icons.error_outline, size: 16, color: Color(0xFFDC2626));
      case PlanStatus.idle:
        return const SizedBox.shrink();
    }
  }
}
