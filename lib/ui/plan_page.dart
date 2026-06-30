import 'package:flutter/material.dart';

import '../services/plan_service.dart';
import 'plan/plan_detail.dart';
import 'plan/plan_editor.dart';
import 'plan/plan_tile.dart';

/// 「计划」页面：功能完整的 AI 任务助手——
/// 快速/详细添加待办（日期、优先级、标签、子任务、备注、关联），
/// 智能分组 + 搜索 + 排序 + 拖拽，单项「先拆解确认再执行」、批量按顺序/并行执行，
/// 右侧查看执行过程 / 历史 / 续做。
class PlanPage extends StatefulWidget {
  const PlanPage({super.key, required this.plan});

  final PlanService plan;

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  final _quickAdd = TextEditingController();
  final _search = TextEditingController();

  bool _parallel = false; // 批量执行：true=并行
  PlanSort _sort = PlanSort.manual;
  String _query = '';
  bool _showArchived = false;
  String? _selectedId;

  @override
  void dispose() {
    _quickAdd.dispose();
    _search.dispose();
    super.dispose();
  }

  void _quickAddTodo() {
    widget.plan.add(_quickAdd.text);
    _quickAdd.clear();
    setState(() {});
  }

  Future<void> _newDetailed() async {
    final result = await showPlanEditor(context);
    if (result is PlanTodo) widget.plan.addTodo(result);
  }

  Future<void> _edit(PlanTodo t) async {
    final changed = await showPlanEditor(context, todo: t);
    if (changed == true) widget.plan.update(t);
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
              Expanded(child: _main(plan)),
              const SizedBox(width: 20),
              SizedBox(width: 420, child: _detail(plan)),
            ],
          ),
        );
      },
    );
  }

  // -------------------- 左侧主区 --------------------
  Widget _main(PlanService plan) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('计划',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _newDetailed,
              icon: const Icon(Icons.tune, size: 16),
              label: const Text('详细新建'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text('添加每日待办，并交给第二大脑以 Agent 模式真正动手执行——可先拆解确认，再按顺序或并行批量完成。',
            style: TextStyle(fontSize: 13, color: Color(0xFF6B6B70))),
        const SizedBox(height: 16),
        _quickAddRow(),
        const SizedBox(height: 12),
        if (plan.dueReminders.isNotEmpty) _reminderBanner(plan),
        _toolbar(plan),
        const SizedBox(height: 10),
        Expanded(child: _list(plan)),
      ],
    );
  }

  Widget _quickAddRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _quickAdd,
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
            ),
            onSubmitted: (_) => _quickAddTodo(),
          ),
        ),
        const SizedBox(width: 10),
        FilledButton.icon(
          onPressed: _quickAddTodo,
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

  Widget _reminderBanner(PlanService plan) {
    final titles =
        plan.dueReminders.map((t) => t.title).take(3).join('、');
    final more = plan.dueReminders.length > 3
        ? ' 等 ${plan.dueReminders.length} 项'
        : '';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF6E7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFF5D58A)),
      ),
      child: Row(
        children: [
          const Icon(Icons.notifications_active,
              size: 16, color: Color(0xFFB7791F)),
          const SizedBox(width: 8),
          Expanded(
            child: Text('到期提醒：$titles$more',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF8A6D1B))),
          ),
          TextButton(
            onPressed: plan.clearReminders,
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(PlanService plan) {
    final running = plan.anyRunning;
    return Column(
      children: [
        Row(
          children: [
            SizedBox(
              width: 200,
              child: TextField(
                controller: _search,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: '搜索任务 / 标签',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 4),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
            const SizedBox(width: 10),
            _sortDropdown(),
            const Spacer(),
            IconButton(
              tooltip: _showArchived ? '隐藏已归档' : '显示已归档',
              onPressed: () => setState(() => _showArchived = !_showArchived),
              icon: Icon(
                  _showArchived ? Icons.inventory_2 : Icons.inventory_2_outlined,
                  size: 18),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
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
              onPressed:
                  running ? null : () => plan.executeAll(parallel: _parallel),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF0D9488),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              icon: running
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.auto_awesome, size: 16),
              label: Text(running ? '执行中…' : 'AI 分析并执行全部'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _sortDropdown() {
    return DropdownButton<PlanSort>(
      value: _sort,
      underline: const SizedBox.shrink(),
      style: const TextStyle(fontSize: 13, color: Color(0xFF2B2B2E)),
      items: const [
        DropdownMenuItem(value: PlanSort.manual, child: Text('手动排序')),
        DropdownMenuItem(value: PlanSort.due, child: Text('按截止日期')),
        DropdownMenuItem(value: PlanSort.priority, child: Text('按优先级')),
        DropdownMenuItem(value: PlanSort.status, child: Text('按状态')),
      ],
      onChanged: (v) => setState(() => _sort = v ?? PlanSort.manual),
    );
  }

  // -------------------- 列表（分组 / 排序 / 拖拽） --------------------
  Widget _list(PlanService plan) {
    final all = plan.todos.where(_matches).toList();
    final active = all.where((t) => !t.archived).toList();
    final archived = all.where((t) => t.archived).toList();

    if (all.isEmpty) {
      return Center(
        child: Text(
          _query.isEmpty ? '还没有待办。在上方添加一个吧。' : '没有匹配「$_query」的任务',
          style: const TextStyle(fontSize: 13, color: Color(0xFF9B9B9F)),
        ),
      );
    }

    // 手动排序且未搜索：整段可拖拽。
    final reorderable = _sort == PlanSort.manual && _query.isEmpty;
    if (reorderable) {
      return ListView(
        children: [
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: true,
            itemCount: active.length,
            onReorder: (o, n) => plan.reorderActive(active, o, n),
            itemBuilder: (_, i) =>
                _tile(plan, active[i], key: ValueKey(active[i].id)),
          ),
          if (_showArchived && archived.isNotEmpty)
            _archivedSection(plan, archived),
        ],
      );
    }

    // 其它排序：分组展示，不可拖拽。
    final sorted = _sorted(active);
    return ListView(
      children: [
        if (_sort == PlanSort.due)
          ..._dueGroups(plan, sorted)
        else
          ...sorted.map((t) => _tile(plan, t)),
        if (_showArchived && archived.isNotEmpty)
          _archivedSection(plan, archived),
      ],
    );
  }

  /// 按截止日期分组：逾期/今天、未来 7 天、以后、无期限。
  List<Widget> _dueGroups(PlanService plan, List<PlanTodo> list) {
    final now = DateTime.now();
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final weekEnd = todayEnd.add(const Duration(days: 7));
    final overdueToday = <PlanTodo>[];
    final soon = <PlanTodo>[];
    final later = <PlanTodo>[];
    final noDate = <PlanTodo>[];
    for (final t in list) {
      if (t.dueAt == null) {
        noDate.add(t);
      } else if (!t.dueAt!.isAfter(todayEnd)) {
        overdueToday.add(t);
      } else if (!t.dueAt!.isAfter(weekEnd)) {
        soon.add(t);
      } else {
        later.add(t);
      }
    }
    return [
      ..._group(plan, '今天 / 逾期', overdueToday),
      ..._group(plan, '即将（7 天内）', soon),
      ..._group(plan, '以后', later),
      ..._group(plan, '无期限', noDate),
    ];
  }

  List<Widget> _group(PlanService plan, String title, List<PlanTodo> items) {
    if (items.isEmpty) return [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 12, 6, 4),
        child: Text(title,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF9B9B9F))),
      ),
      ...items.map((t) => _tile(plan, t)),
    ];
  }

  Widget _archivedSection(PlanService plan, List<PlanTodo> archived) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 6),
        title: Text('已归档 (${archived.length})',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF9B9B9F))),
        children: archived.map((t) => _tile(plan, t)).toList(),
      ),
    );
  }

  Widget _tile(PlanService plan, PlanTodo t, {Key? key}) {
    return PlanTile(
      key: key,
      todo: t,
      selected: t.id == _selectedId,
      onTap: () => setState(() => _selectedId = t.id),
      onToggleDone: () => plan.toggleDone(t),
      onRun: () {
        setState(() => _selectedId = t.id);
        plan.executeOne(t);
      },
      onCancel: () => plan.cancel(t),
      onEdit: () => _edit(t),
      onArchive: () => plan.toggleArchived(t),
      onDelete: () => plan.remove(t),
    );
  }

  // -------------------- 过滤 / 排序工具 --------------------
  bool _matches(PlanTodo t) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return t.title.toLowerCase().contains(q) ||
        t.notes.toLowerCase().contains(q) ||
        t.tags.any((tag) => tag.toLowerCase().contains(q));
  }

  List<PlanTodo> _sorted(List<PlanTodo> list) {
    final out = List.of(list);
    switch (_sort) {
      case PlanSort.priority:
        out.sort((a, b) => a.priority.rank.compareTo(b.priority.rank));
      case PlanSort.status:
        out.sort((a, b) => _statusRank(a).compareTo(_statusRank(b)));
      case PlanSort.due:
        out.sort((a, b) {
          if (a.dueAt == null && b.dueAt == null) return 0;
          if (a.dueAt == null) return 1;
          if (b.dueAt == null) return -1;
          return a.dueAt!.compareTo(b.dueAt!);
        });
      case PlanSort.manual:
        break;
    }
    return out;
  }

  int _statusRank(PlanTodo t) {
    if (t.done) return 4;
    return switch (t.status) {
      PlanStatus.running => 0,
      PlanStatus.error => 1,
      PlanStatus.idle => 2,
      PlanStatus.success => 3,
    };
  }

  // -------------------- 右侧详情 --------------------
  Widget _detail(PlanService plan) {
    PlanTodo? todo;
    for (final t in plan.todos) {
      if (t.id == _selectedId) {
        todo = t;
        break;
      }
    }
    if (todo == null) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF7F7F8),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Center(
          child: Text('选择一个待办，查看 AI 执行过程与历史',
              style: TextStyle(fontSize: 13, color: Color(0xFFB9B9BD))),
        ),
      );
    }
    return PlanDetail(key: ValueKey(todo.id), plan: plan, todo: todo);
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
