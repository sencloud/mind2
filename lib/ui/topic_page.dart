import 'package:flutter/material.dart';

import '../models.dart';
import '../services/library_service.dart';
import '../services/playwright_service.dart';
import '../services/topic_service.dart';
import 'enter_to_send.dart';

class TopicPage extends StatefulWidget {
  const TopicPage({
    super.key,
    required this.topicService,
    required this.library,
    this.onOpenReport,
    this.onOpenNote,
  });

  final TopicFetchService topicService;
  final LibraryService library;
  final void Function(String reportPath)? onOpenReport;
  final void Function(StandardNote note)? onOpenNote;

  @override
  State<TopicPage> createState() => _TopicPageState();
}

class _TopicPageState extends State<TopicPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  /// 正在审题/澄清（run 之前的准备阶段）。
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    widget.topicService.onLoginRequired = _askLoginCredential;
  }

  @override
  void dispose() {
    widget.topicService.onLoginRequired = null;
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        width: 400,
      ),
    );
  }

  Future<void> _start([String? preset]) async {
    final topic = (preset ?? _controller.text).trim();
    if (topic.isEmpty || widget.topicService.running || _preparing) return;
    if (preset != null) _controller.text = preset;

    // 开始检索前先与用户澄清研究意图（消除歧义、明确对比维度与深度）。
    String clarification = '';
    setState(() => _preparing = true);
    try {
      final c = await widget.topicService.clarify(topic);
      if (!mounted) return;
      if (c.needsInput) {
        final answers = await _askClarifications(c);
        if (answers == null) {
          setState(() => _preparing = false);
          return; // 用户取消
        }
        clarification = answers;
      }
    } catch (e) {
      _toast('审题失败，请稍后重试：$e');
      if (mounted) setState(() => _preparing = false);
      return;
    }
    if (mounted) setState(() => _preparing = false);
    await widget.topicService.run(topic, clarification: clarification);
  }

  /// 弹出澄清问题对话框，收集用户答复并返回 Q/A 文本；用户取消返回 null。
  /// 每个问题以「多选选项 + 末尾自定义输入框」的形式呈现，降低输入成本，
  /// 只有最后一个「其他/自己输入」框需要用户自行填写。
  Future<String?> _askClarifications(TopicClarification c) async {
    // 每题选中的选项下标集合。
    final selected = <int, Set<int>>{};
    // 每题末尾的「其他/自己输入」文本框。
    final customInputs = [
      for (var i = 0; i < c.questions.length; i++) TextEditingController(),
    ];
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: const Text('开始研究前，请先确认一下'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (c.understanding.isNotEmpty) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0FBF9),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFB9E8E0)),
                        ),
                        child: Text(
                          '我的理解：${c.understanding}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.5,
                            color: Color(0xFF0F766E),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    const Text(
                      '为了研究得更准确、更深入，请勾选下面的选项（可多选、可留空）：',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Color(0xFF6B6B70),
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (var i = 0; i < c.questions.length; i++) ...[
                      Text(
                        '${i + 1}. ${c.questions[i].prompt}',
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // 模型给出的备选项：用复选框让用户勾选，无需手动输入。
                      for (var j = 0; j < c.questions[i].options.length; j++)
                        CheckboxListTile(
                          value: selected[i]?.contains(j) ?? false,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            c.questions[i].options[j],
                            style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.35,
                            ),
                          ),
                          onChanged: (checked) {
                            final set = selected.putIfAbsent(i, () => <int>{});
                            if (checked == true) {
                              set.add(j);
                            } else {
                              set.remove(j);
                            }
                            setLocal(() {});
                          },
                        ),
                      const SizedBox(height: 6),
                      // 最后一项：没有合适选项时，用户在这里自行补充。
                      TextField(
                        controller: customInputs[i],
                        minLines: 1,
                        maxLines: 3,
                        style: const TextStyle(fontSize: 12.5, height: 1.4),
                        decoration: const InputDecoration(
                          labelText: '其他 / 自己输入',
                          hintText: '没有合适选项时，在这里补充你的想法',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final buf = StringBuffer();
                  for (var i = 0; i < c.questions.length; i++) {
                    final q = c.questions[i];
                    // 收集勾选的选项 + 末尾自定义输入，拼成一行答复。
                    final parts = <String>[
                      for (final idx in (selected[i] ?? const <int>{}))
                        if (idx >= 0 && idx < q.options.length) q.options[idx],
                    ];
                    final custom = customInputs[i].text.trim();
                    if (custom.isNotEmpty) parts.add('其他：$custom');
                    buf
                      ..writeln('问：${q.prompt}')
                      ..writeln(
                        '答：${parts.isEmpty ? '（用户未填写）' : parts.join('、')}',
                      )
                      ..writeln();
                  }
                  Navigator.pop(ctx, buf.toString());
                },
                child: const Text('确认并开始研究'),
              ),
            ],
          ),
        ),
      );
    } finally {
      for (final ctrl in customInputs) {
        ctrl.dispose();
      }
    }
  }

  Future<LoginCredential?> _askLoginCredential(LoginRequest request) async {
    if (!mounted) return null;
    final userController = TextEditingController();
    final passController = TextEditingController();
    try {
      return await showDialog<LoginCredential>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('网站需要登录'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.domain.isEmpty ? request.url : request.domain,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (request.title.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    request.title,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF6B6B70),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  request.reason,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF8B8B90),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: userController,
                  decoration: const InputDecoration(
                    labelText: '用户名 / 邮箱 / 账号',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '凭据只会传给当前浏览器会话用于本次登录，不会写入日志、笔记或设置。',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF9B9B9F)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('跳过这个网站'),
            ),
            FilledButton(
              onPressed: () {
                final username = userController.text.trim();
                final password = passController.text;
                if (username.isEmpty || password.isEmpty) {
                  _toast('请填写用户名和密码，或选择跳过这个网站。');
                  return;
                }
                Navigator.pop(
                  ctx,
                  LoginCredential(username: username, password: password),
                );
              },
              child: const Text('提交并继续'),
            ),
          ],
        ),
      );
    } finally {
      userController.dispose();
      passController.dispose();
    }
  }

  Widget _buildRecordDetail(ResearchRecord record) {
    final c = record.createdAt;
    final stamp =
        '${c.year}-${c.month.toString().padLeft(2, '0')}-${c.day.toString().padLeft(2, '0')} '
        '${c.hour.toString().padLeft(2, '0')}:${c.minute.toString().padLeft(2, '0')}';
    final related =
        widget.library.notes
            .where((n) => n.research.trim() == record.topic.trim())
            .toList()
          ..sort((a, b) {
            if (a.isResearchReport != b.isResearchReport) {
              return a.isResearchReport ? -1 : 1;
            }
            return a.fullTitle.compareTo(b.fullTitle);
          });
    final refs = related.where((n) => !n.isResearchReport).toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FBF9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFB9E8E0)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.history, size: 16, color: Color(0xFF0D9488)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '历史研究：${record.topic}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      stamp,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF9B9B9F),
                      ),
                    ),
                  ],
                ),
              ),
              if (record.reportPath != null)
                FilledButton.tonalIcon(
                  onPressed: () =>
                      widget.onOpenReport?.call(record.reportPath!),
                  icon: const Icon(Icons.description_outlined, size: 15),
                  label: const Text('打开报告', style: TextStyle(fontSize: 12.5)),
                ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => widget.topicService.startNew(),
                child: const Text('新研究', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
          if (related.isNotEmpty) ...[
            const SizedBox(height: 10),
            Divider(
              height: 1,
              color: const Color(0xFFB9E8E0).withValues(alpha: 0.7),
            ),
            const SizedBox(height: 10),
            Text(
              '关联文件 · ${refs.length} 份参考资料',
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B6B70)),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 92),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final n in related)
                      ActionChip(
                        avatar: Icon(
                          n.isResearchReport
                              ? Icons.article_outlined
                              : Icons.insert_drive_file_outlined,
                          size: 15,
                          color: const Color(0xFF0D9488),
                        ),
                        label: Text(
                          n.isResearchReport ? '报告' : n.fullTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => widget.onOpenNote?.call(n),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Widget _buildMainArea(
    TopicFetchService svc,
    ResearchRecord? viewing,
    List<String> displayLogs,
  ) {
    final showRecord = !svc.running && viewing != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '主题研究',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 6),
                  Text(
                    '输入一个研究问题，第二大脑会像研究员一样：多轮发散检索、下载关键资料、记录过程笔记，并综合成研究报告。',
                    style: TextStyle(fontSize: 13, color: Color(0xFF6B6B70)),
                  ),
                ],
              ),
            ),
            if (showRecord)
              TextButton.icon(
                onPressed: () => widget.topicService.startNew(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新研究'),
              ),
          ],
        ),
        const SizedBox(height: 18),
        _buildInputRow(svc),
        const SizedBox(height: 16),
        if (showRecord) ...[
          _buildRecordDetail(viewing),
          const SizedBox(height: 14),
        ],
        Expanded(
          child: _buildLogPanel(
            title: svc.running
                ? '研究进行中'
                : showRecord
                ? '历史研究日志'
                : '研究进度',
            logs: displayLogs,
            emptyText: showRecord ? '这条历史研究暂无日志' : '输入主题并点击「开始研究」后，研究进度会显示在这里',
          ),
        ),
      ],
    );
  }

  Widget _buildInputRow(TopicFetchService svc) {
    final busy = svc.running || _preparing;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _controller.text.trim().isEmpty
              ? const Color(0xFFD9D9DD)
              : const Color(0xFF0D9488),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        children: [
          EnterToSend(
            // 忙碌时不响应回车发送。
            enabled: !busy,
            onSubmit: _start,
            child: TextField(
              controller: _controller,
              enabled: !busy,
              minLines: 3,
              maxLines: 8,
              textInputAction: TextInputAction.newline,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontSize: 14, height: 1.55),
              decoration: const InputDecoration(
                hintText:
                    '例如：\n我想研究高校档案智能体的安全与长期工程，重点关注准确性、知识库增强、skills 方式和可落地方案。\n（回车发送，Ctrl/Shift+回车换行）',
                hintStyle: TextStyle(color: Color(0xFFA8A8AC)),
                border: InputBorder.none,
                contentPadding: EdgeInsets.fromLTRB(16, 14, 150, 54),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: FilledButton.icon(
              onPressed: busy ? null : _start,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1A1A1A),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
              icon: busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.travel_explore, size: 16),
              label: Text(
                _preparing ? '审题中…' : (svc.running ? '研究中…' : '开始研究'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogPanel({
    required String title,
    required List<String> logs,
    required String emptyText,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal, size: 16, color: Color(0xFF6B6B70)),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (logs.isNotEmpty)
                Text(
                  '${logs.length} 条',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF9B9B9F),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: logs.isEmpty
                ? Center(
                    child: Text(
                      emptyText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF9B9B9F),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: logs.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        logs[i],
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          fontFamily: 'Consolas',
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryPanel(TopicFetchService svc) {
    return Container(
      width: 312,
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListenableBuilder(
        listenable: svc,
        builder: (context, _) {
          final history = [...svc.history]
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '研究历史',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: svc.running ? null : svc.startNew,
                      child: const Text('新研究', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFFE8E8EA)),
              Expanded(
                child: history.isEmpty
                    ? const Center(
                        child: Text(
                          '暂无研究历史',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFFB9B9BD),
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
                        children: _buildHistoryRows(history, svc),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildHistoryRows(
    List<ResearchRecord> history,
    TopicFetchService svc,
  ) {
    final rows = <Widget>[];
    String? lastGroup;
    for (final record in history) {
      final group = _timeGroupLabel(record.createdAt);
      if (group != lastGroup) {
        rows.add(_HistoryGroupHeader(group));
        lastGroup = group;
      }
      rows.add(
        _ResearchHistoryTile(
          record: record,
          selected: svc.viewing == record,
          onOpen: () => svc.openRecord(record),
          onOpenReport: record.reportPath == null
              ? null
              : () => widget.onOpenReport?.call(record.reportPath!),
          onDelete: () => svc.deleteRecord(record),
        ),
      );
    }
    return rows;
  }

  String _timeGroupLabel(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff <= 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff <= 7) return '7 天内';
    if (diff <= 30) return '30 天内';
    return '更早';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.topicService,
      builder: (context, _) {
        final svc = widget.topicService;
        final viewing = svc.viewing;
        final showRecord = !svc.running && viewing != null;
        final displayLogs = showRecord ? viewing.logs : svc.logs;
        _scrollToBottom();
        return Padding(
          padding: const EdgeInsets.all(32),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildMainArea(svc, viewing, displayLogs)),
              const SizedBox(width: 20),
              _buildHistoryPanel(svc),
            ],
          ),
        );
      },
    );
  }
}

class _HistoryGroupHeader extends StatelessWidget {
  const _HistoryGroupHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11.5, color: Color(0xFF9B9B9F)),
      ),
    );
  }
}

class _ResearchHistoryTile extends StatelessWidget {
  const _ResearchHistoryTile({
    required this.record,
    required this.selected,
    required this.onOpen,
    required this.onDelete,
    this.onOpenReport,
  });

  final ResearchRecord record;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final VoidCallback? onOpenReport;

  String get _stamp {
    final c = record.createdAt;
    return '${c.month.toString().padLeft(2, '0')}-${c.day.toString().padLeft(2, '0')} '
        '${c.hour.toString().padLeft(2, '0')}:${c.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFFE8F5F3) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 9, 4, 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Icon(
                  record.reportPath == null
                      ? Icons.travel_explore_outlined
                      : Icons.article_outlined,
                  size: 16,
                  color: selected
                      ? const Color(0xFF0D9488)
                      : const Color(0xFF8B8B90),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.topic.isEmpty ? '(空研究)' : record.topic,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: const Color(0xFF2F2F33),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _stamp,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF9B9B9F),
                            ),
                          ),
                        ),
                        if (onOpenReport != null)
                          InkWell(
                            borderRadius: BorderRadius.circular(5),
                            onTap: onOpenReport,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              child: Text(
                                '报告',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF0D9488),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '删除研究记录',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                onPressed: onDelete,
                icon: const Icon(Icons.close, color: Color(0xFFB9B9BD)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
