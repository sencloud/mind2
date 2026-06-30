import 'package:flutter/material.dart';

import '../../services/plan_service.dart';

/// 单个待办的列表项：勾选、优先级、标题、标签、截止时间、子任务进度、
/// 执行状态，以及执行/停止与「更多」菜单（编辑/归档/删除）。
class PlanTile extends StatelessWidget {
  const PlanTile({
    super.key,
    required this.todo,
    required this.selected,
    required this.onTap,
    required this.onToggleDone,
    required this.onRun,
    required this.onCancel,
    required this.onEdit,
    required this.onArchive,
    required this.onDelete,
  });

  final PlanTodo todo;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleDone;
  final VoidCallback onRun;
  final VoidCallback onCancel;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
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
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: todo.done,
                visualDensity: VisualDensity.compact,
                onChanged: (_) => onToggleDone(),
              ),
              _priorityDot(),
              const SizedBox(width: 8),
              Expanded(child: _body(context)),
              const SizedBox(width: 6),
              _statusBadge(todo.status),
              const SizedBox(width: 2),
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
              _moreMenu(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final progress = todo.subtaskProgress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
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
              decoration: todo.done ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
        if (todo.dueAt != null ||
            todo.tags.isNotEmpty ||
            todo.recur != PlanRecur.none ||
            progress != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (todo.dueAt != null) _dueChip(),
                if (todo.recur != PlanRecur.none)
                  _miniChip(Icons.repeat, todo.recur.label),
                if (todo.autoRun) _miniChip(Icons.bolt, '自动'),
                if (progress != null)
                  _miniChip(Icons.checklist,
                      '${progress.done}/${progress.total}'),
                ...todo.tags.map(_tagChip),
              ],
            ),
          ),
      ],
    );
  }

  Widget _priorityDot() {
    final color = switch (todo.priority) {
      PlanPriority.high => const Color(0xFFDC2626),
      PlanPriority.medium => const Color(0xFFF59E0B),
      PlanPriority.low => const Color(0xFF3B82F6),
      PlanPriority.none => Colors.transparent,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }

  Widget _dueChip() {
    final now = DateTime.now();
    final overdue = !todo.done && todo.dueAt!.isBefore(now);
    final color = overdue ? const Color(0xFFDC2626) : const Color(0xFF6B6B70);
    return _chip(
      icon: Icons.schedule,
      text: _fmtDue(todo.dueAt!),
      fg: color,
      bg: overdue ? const Color(0xFFFDECEC) : const Color(0xFFF0F0F2),
    );
  }

  Widget _miniChip(IconData icon, String text) => _chip(
        icon: icon,
        text: text,
        fg: const Color(0xFF6B6B70),
        bg: const Color(0xFFF0F0F2),
      );

  Widget _tagChip(String tag) => _chip(
        text: '#$tag',
        fg: const Color(0xFF0D9488),
        bg: const Color(0xFFE8F5F3),
      );

  Widget _chip({IconData? icon, required String text, required Color fg, required Color bg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: fg),
            const SizedBox(width: 3),
          ],
          Text(text, style: TextStyle(fontSize: 11, color: fg)),
        ],
      ),
    );
  }

  Widget _moreMenu() {
    return PopupMenuButton<String>(
      tooltip: '更多',
      iconSize: 16,
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert, color: Color(0xFFB9B9BD)),
      onSelected: (v) {
        switch (v) {
          case 'edit':
            onEdit();
          case 'archive':
            onArchive();
          case 'delete':
            onDelete();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'edit', child: Text('编辑')),
        PopupMenuItem(
            value: 'archive', child: Text(todo.archived ? '取消归档' : '归档')),
        const PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    );
  }

  Widget _statusBadge(PlanStatus s) {
    if (todo.awaitingApproval) {
      return const Icon(Icons.fact_check_outlined,
          size: 16, color: Color(0xFFF59E0B));
    }
    switch (s) {
      case PlanStatus.running:
        return const SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Color(0xFF0D9488)),
        );
      case PlanStatus.success:
        return const Icon(Icons.check_circle,
            size: 16, color: Color(0xFF16A34A));
      case PlanStatus.error:
        return const Icon(Icons.error_outline,
            size: 16, color: Color(0xFFDC2626));
      case PlanStatus.idle:
        return const SizedBox.shrink();
    }
  }

  /// 截止时间显示：今天只显示时间，其它显示「月-日 时:分」。
  static String _fmtDue(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay = d.year == now.year && d.month == now.month && d.day == now.day;
    if (sameDay) return '今天 ${two(d.hour)}:${two(d.minute)}';
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
