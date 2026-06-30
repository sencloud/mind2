import 'package:flutter/material.dart';

import '../../services/plan_service.dart';

/// 新建 / 编辑任务的弹窗：标题、优先级、截止日期、重复、自动执行、标签、备注、关联。
/// 新建时返回新的 [PlanTodo]；编辑时返回 true 表示有改动（调用方据此持久化）。
Future<Object?> showPlanEditor(BuildContext context, {PlanTodo? todo}) {
  return showDialog<Object?>(
    context: context,
    builder: (_) => _PlanEditorDialog(todo: todo),
  );
}

class _PlanEditorDialog extends StatefulWidget {
  const _PlanEditorDialog({this.todo});

  /// 为空表示新建；否则就地编辑该任务。
  final PlanTodo? todo;

  @override
  State<_PlanEditorDialog> createState() => _PlanEditorDialogState();
}

class _PlanEditorDialogState extends State<_PlanEditorDialog> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  late final TextEditingController _tags;

  late PlanPriority _priority;
  late PlanRecur _recur;
  late bool _autoRun;
  DateTime? _due;
  late List<PlanLink> _links;

  bool get _isEdit => widget.todo != null;

  @override
  void initState() {
    super.initState();
    final t = widget.todo;
    _title = TextEditingController(text: t?.title ?? '');
    _notes = TextEditingController(text: t?.notes ?? '');
    _tags = TextEditingController(text: t?.tags.join(', ') ?? '');
    _priority = t?.priority ?? PlanPriority.none;
    _recur = t?.recur ?? PlanRecur.none;
    _autoRun = t?.autoRun ?? false;
    _due = t?.dueAt;
    _links = t == null
        ? []
        : t.links.map((l) => PlanLink(kind: l.kind, label: l.label)).toList();
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _due ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null) return;
    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_due ?? now),
    );
    setState(() {
      _due = DateTime(date.year, date.month, date.day, time?.hour ?? 9,
          time?.minute ?? 0);
    });
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final tags = _tags.text
        .split(RegExp(r'[,，]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final t = widget.todo;
    if (t == null) {
      Navigator.pop(
        context,
        PlanTodo(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          title: title,
          createdAt: DateTime.now(),
          notes: _notes.text.trim(),
          priority: _priority,
          tags: tags,
          dueAt: _due,
          recur: _recur,
          autoRun: _autoRun,
          links: _links,
        ),
      );
    } else {
      t
        ..title = title
        ..notes = _notes.text.trim()
        ..priority = _priority
        ..tags = tags
        ..dueAt = _due
        ..recur = _recur
        ..autoRun = _autoRun
        ..links = _links;
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 8),
              child: Text(
                _isEdit ? '编辑任务' : '新建任务',
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _field('任务', _title, hint: '要做什么？'),
                    const SizedBox(height: 14),
                    _priorityRow(),
                    const SizedBox(height: 14),
                    _dueRow(),
                    const SizedBox(height: 14),
                    _recurRow(),
                    const SizedBox(height: 14),
                    _field('标签', _tags, hint: '用逗号分隔，如：工作, 调研'),
                    const SizedBox(height: 14),
                    _field('备注', _notes, hint: '补充说明（支持 Markdown）', lines: 3),
                    const SizedBox(height: 14),
                    _linksSection(),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0D9488),
                    ),
                    child: Text(_isEdit ? '保存' : '添加'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12.5,
                color: Color(0xFF6B6B70),
                fontWeight: FontWeight.w500)),
      );

  Widget _field(String label, TextEditingController c,
      {String? hint, int lines = 1}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(label),
        TextField(
          controller: c,
          minLines: lines,
          maxLines: lines == 1 ? 1 : lines + 2,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }

  Widget _priorityRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label('优先级'),
        Wrap(
          spacing: 8,
          children: PlanPriority.values.map((p) {
            final sel = _priority == p;
            return ChoiceChip(
              label: Text(p.label),
              selected: sel,
              onSelected: (_) => setState(() => _priority = p),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _dueRow() {
    final txt = _due == null ? '未设置' : _fmt(_due!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label('截止 / 计划时间'),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _pickDue,
              icon: const Icon(Icons.event, size: 16),
              label: Text(txt),
            ),
            if (_due != null)
              IconButton(
                tooltip: '清除',
                onPressed: () => setState(() => _due = null),
                icon: const Icon(Icons.clear, size: 18),
              ),
            const Spacer(),
            // 仅在设置了时间后，自动执行才有意义。
            if (_due != null)
              Row(
                children: [
                  Checkbox(
                    value: _autoRun,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) => setState(() => _autoRun = v ?? false),
                  ),
                  const Text('到点自动执行', style: TextStyle(fontSize: 12.5)),
                ],
              ),
          ],
        ),
      ],
    );
  }

  Widget _recurRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label('重复'),
        Wrap(
          spacing: 8,
          children: PlanRecur.values.map((r) {
            final sel = _recur == r;
            return ChoiceChip(
              label: Text(r.label),
              selected: sel,
              onSelected: (_) => setState(() => _recur = r),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _linksSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _label('关联'),
            const Spacer(),
            TextButton.icon(
              onPressed: _addLink,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加'),
            ),
          ],
        ),
        if (_links.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text('可关联项目 / 研究 / 知识库笔记 / 链接，供 AI 执行时参考',
                style: TextStyle(fontSize: 12, color: Color(0xFFA8A8AC))),
          ),
        ..._links.asMap().entries.map((e) => _linkRow(e.key, e.value)),
      ],
    );
  }

  Widget _linkRow(int i, PlanLink link) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          DropdownButton<PlanLinkKind>(
            value: link.kind,
            underline: const SizedBox.shrink(),
            items: PlanLinkKind.values
                .map((k) => DropdownMenuItem(
                    value: k,
                    child: Text(
                        PlanLink(kind: k, label: '').kindLabel,
                        style: const TextStyle(fontSize: 13))))
                .toList(),
            onChanged: (k) =>
                setState(() => _links[i] = PlanLink(kind: k!, label: link.label)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: TextEditingController(text: link.label)
                ..selection =
                    TextSelection.collapsed(offset: link.label.length),
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '名称 / 主题 / 标题 / 网址',
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => link.label = v,
            ),
          ),
          IconButton(
            tooltip: '移除',
            onPressed: () => setState(() => _links.removeAt(i)),
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }

  void _addLink() {
    setState(() => _links.add(PlanLink(kind: PlanLinkKind.note, label: '')));
  }

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
