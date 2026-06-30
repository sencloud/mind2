import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../services/plan_service.dart';
import '../agent_events_view.dart';

/// 右侧详情面板：概览（步骤确认 / 子任务 / 备注 / 关联 / 结果）、
/// 执行过程（实时事件）、历史（每次运行可回看），底部可「打开目录」与「追加指令继续」。
class PlanDetail extends StatefulWidget {
  const PlanDetail({super.key, required this.plan, required this.todo});

  final PlanService plan;
  final PlanTodo todo;

  @override
  State<PlanDetail> createState() => _PlanDetailState();
}

class _PlanDetailState extends State<PlanDetail> with TickerProviderStateMixin {
  late TabController _tab;
  final _followUp = TextEditingController();
  PlanRun? _openRun; // 历史中展开查看的某次运行

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
  }

  @override
  void didUpdateWidget(PlanDetail old) {
    super.didUpdateWidget(old);
    // 切换到另一个任务时，重置历史展开项。
    if (old.todo.id != widget.todo.id) _openRun = null;
  }

  @override
  void dispose() {
    _tab.dispose();
    _followUp.dispose();
    super.dispose();
  }

  PlanTodo get t => widget.todo;
  PlanService get plan => widget.plan;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          const Divider(height: 1, color: Color(0xFFE8E8EA)),
          TabBar(
            controller: _tab,
            labelStyle:
                const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            labelColor: const Color(0xFF0D9488),
            indicatorColor: const Color(0xFF0D9488),
            tabs: [
              const Tab(height: 38, text: '概览'),
              const Tab(height: 38, text: '执行过程'),
              Tab(height: 38, text: '历史 (${t.runs.length})'),
            ],
          ),
          const Divider(height: 1, color: Color(0xFFE8E8EA)),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [_overview(), _process(), _history()],
            ),
          ),
          _footer(),
        ],
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, size: 16, color: Color(0xFF0D9488)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------- 概览 --------------------
  Widget _overview() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (t.awaitingApproval) _approvalBanner(),
        if (t.subtasks.isNotEmpty) ...[
          _sectionTitle(t.awaitingApproval ? '建议步骤（可勾选/确认）' : '子任务'),
          ...t.subtasks.map(_subtaskRow),
          const SizedBox(height: 12),
        ],
        if (t.notes.trim().isNotEmpty) ...[
          _sectionTitle('备注'),
          _md(t.notes),
          const SizedBox(height: 12),
        ],
        if (t.links.isNotEmpty) ...[
          _sectionTitle('关联'),
          ...t.links.map((l) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('· [${l.kindLabel}] ${l.label}',
                    style: const TextStyle(fontSize: 12.5)),
              )),
          const SizedBox(height: 12),
        ],
        if (t.result.trim().isNotEmpty) ...[
          _sectionTitle('最近结果'),
          _md(t.result),
        ] else if (!t.awaitingApproval)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Text('点击「执行」后，AI 的分析与产出会显示在这里',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: Color(0xFF9B9B9F))),
          ),
      ],
    );
  }

  Widget _approvalBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF6E7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFF5D58A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('AI 已拆解出执行步骤，确认后开始动手（可先勾掉不需要的步骤）。',
              style: TextStyle(fontSize: 12.5, color: Color(0xFF8A6D1B))),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => plan.rejectPlan(t),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => plan.approveAndRun(t),
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0D9488)),
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('确认并执行'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _subtaskRow(PlanSubtask s) {
    return InkWell(
      onTap: () => plan.toggleSubtask(t, s),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              s.done ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18,
              color: s.done ? const Color(0xFF0D9488) : const Color(0xFFB9B9BD),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  s.title,
                  style: TextStyle(
                    fontSize: 12.8,
                    height: 1.35,
                    color: s.done
                        ? const Color(0xFFA8A8AC)
                        : const Color(0xFF2B2B2E),
                    decoration: s.done ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------- 执行过程 --------------------
  Widget _process() {
    if (t.events.isEmpty) {
      return const Center(
        child: Text('暂无运行中过程。点击「执行」开始。',
            style: TextStyle(fontSize: 12.5, color: Color(0xFF9B9B9F))),
      );
    }
    return AgentEventsView(key: ValueKey('live-${t.id}'), events: t.events);
  }

  // -------------------- 历史 --------------------
  Widget _history() {
    if (t.runs.isEmpty) {
      return const Center(
        child: Text('还没有执行历史',
            style: TextStyle(fontSize: 12.5, color: Color(0xFF9B9B9F))),
      );
    }
    if (_openRun != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _openRun = null),
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('返回历史列表'),
            ),
          ),
          Expanded(
            child: _openRun!.events.isNotEmpty
                ? AgentEventsView(
                    key: ValueKey('run-${_openRun!.id}'),
                    events: _openRun!.events)
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [_md(_openRun!.result)]),
          ),
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: t.runs.length,
      separatorBuilder: (_, i) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final r = t.runs[i];
        return ListTile(
          dense: true,
          leading: _runStatusIcon(r.status),
          title: Text('第 ${t.runs.length - i} 次 · ${_fmt(r.startedAt)}',
              style: const TextStyle(fontSize: 12.5)),
          subtitle: Text(
            r.result.trim().isEmpty ? '(无总结)' : r.result.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5),
          ),
          onTap: () => setState(() => _openRun = r),
        );
      },
    );
  }

  Widget _runStatusIcon(PlanStatus s) => switch (s) {
        PlanStatus.success =>
          const Icon(Icons.check_circle, size: 16, color: Color(0xFF16A34A)),
        PlanStatus.error =>
          const Icon(Icons.error_outline, size: 16, color: Color(0xFFDC2626)),
        _ => const Icon(Icons.circle_outlined,
            size: 16, color: Color(0xFFB9B9BD)),
      };

  // -------------------- 底部操作 --------------------
  Widget _footer() {
    final canRun = !t.running && !t.awaitingApproval;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFE8E8EA))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (t.workdir != null)
                TextButton.icon(
                  onPressed: _openWorkdir,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('打开目录', style: TextStyle(fontSize: 12.5)),
                ),
              const Spacer(),
              if (t.runs.isNotEmpty && canRun)
                TextButton.icon(
                  onPressed: () => plan.executeOne(t, withApproval: false),
                  icon: const Icon(Icons.replay, size: 16),
                  label: const Text('重跑', style: TextStyle(fontSize: 12.5)),
                ),
            ],
          ),
          // 追加指令：在上次产物基础上继续完善。
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _followUp,
                  enabled: canRun,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: t.runs.isEmpty ? '先执行一次后可追加指令' : '追加指令，让 AI 接着上次继续…',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onSubmitted: (_) => _sendFollowUp(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: canRun && t.runs.isNotEmpty ? _sendFollowUp : null,
                icon: const Icon(Icons.send, size: 18, color: Color(0xFF0D9488)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _sendFollowUp() {
    final text = _followUp.text.trim();
    if (text.isEmpty) return;
    plan.continueWith(t, text);
    _followUp.clear();
    _tab.animateTo(1); // 跳到「执行过程」看实时
  }

  Future<void> _openWorkdir() async {
    final dir = t.workdir;
    if (dir == null) return;
    if (await Directory(dir).exists()) {
      await Process.start('explorer.exe', [dir]);
    }
  }

  // -------------------- 小工具 --------------------
  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6B6B70))),
      );

  Widget _md(String data) => MarkdownBody(
        data: data,
        styleSheet: MarkdownStyleSheet(
          p: const TextStyle(fontSize: 12.8, height: 1.5),
          code: const TextStyle(fontSize: 12, backgroundColor: Color(0xFFEFEFF1)),
        ),
      );

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
