import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../services/paper_service.dart';
import '../services/platform_capabilities.dart';
import 'responsive.dart';

const _accent = Color(0xFF0D9488);
const _ink = Color(0xFF2B2B2E);
const _sub = Color(0xFF6B6B70);
const _muted = Color(0xFF9B9B9F);

class PaperPage extends StatefulWidget {
  const PaperPage({super.key, required this.paper});

  final PaperService paper;

  @override
  State<PaperPage> createState() => _PaperPageState();
}

class _PaperPageState extends State<PaperPage> {
  bool _previewEnglish = false;
  // 窄屏单栏切换：0=大纲，1=正文，2=预览。
  int _mobileTab = 0;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        width: 420,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.paper,
      builder: (context, _) {
        final svc = widget.paper;
        return svc.current == null ? _buildShelf(svc) : _buildWorkspace(svc);
      },
    );
  }

  Widget _buildShelf(PaperService svc) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '论文写作',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () => svc.createBlank(format: PaperFormat.latex),
                icon: const Icon(Icons.functions, size: 16),
                label: const Text('新建 LaTeX 论文'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => svc.createBlank(),
                style: FilledButton.styleFrom(backgroundColor: _accent),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新建 Markdown 论文'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '按期刊论文结构组织写作：题目、摘要、引言、相关工作、方法、实验、结果、讨论、结论与参考文献，支持中文稿和英文稿并行编辑。',
            style: TextStyle(fontSize: 13, color: _sub),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: svc.papers.isEmpty
                ? const Center(
                    child: Text(
                      '还没有论文，点击右上角新建，或从研究报告页转换生成',
                      style: TextStyle(fontSize: 13, color: _muted),
                    ),
                  )
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 340,
                          mainAxisExtent: 162,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                    itemCount: svc.papers.length,
                    itemBuilder: (context, i) => _paperCard(svc, svc.papers[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _paperCard(PaperService svc, PaperDraft draft) {
    return Material(
      color: const Color(0xFFF7F7F8),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => svc.openPaper(draft),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.article_outlined, size: 18, color: _accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      draft.titleZh,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    icon: const Icon(Icons.more_horiz, size: 18, color: _muted),
                    onSelected: (value) {
                      if (value == 'delete') _confirmDelete(svc, draft);
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  draft.titleEn.isEmpty ? '（等待生成英文题目）' : draft.titleEn,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: _sub,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _chip(draft.format.label),
                  const Spacer(),
                  Text(
                    '${draft.doneSections}/${draft.sections.length} 节 · ${draft.totalWords} 字词',
                    style: const TextStyle(fontSize: 11.5, color: _muted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(PaperService svc, PaperDraft draft) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除论文'),
        content: Text('确定删除《${draft.titleZh}》吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await svc.deletePaper(draft);
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F5F3),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: _accent,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildWorkspace(PaperService svc) {
    final draft = svc.current!;
    final body = svc.activeSection == null
        ? _overview(svc, draft)
        : _PaperSectionEditor(
            key: ValueKey(svc.activeSection!.id),
            svc: svc,
            section: svc.activeSection!,
            busy: svc.busy,
          );
    if (context.isCompact) {
      // 窄屏单栏：大纲 / 正文 / 预览 顶部切换。
      return Column(
        children: [
          _topBar(svc, draft),
          if (svc.busy || svc.stage.isNotEmpty) _statusStrip(svc),
          _mobileTabBar(),
          Expanded(
            child: switch (_mobileTab) {
              0 => _leftPanel(svc, draft, mobile: true),
              1 => body,
              _ => _previewPanel(svc, draft),
            },
          ),
        ],
      );
    }
    return Column(
      children: [
        _topBar(svc, draft),
        if (svc.busy || svc.stage.isNotEmpty) _statusStrip(svc),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _leftPanel(svc, draft),
              const VerticalDivider(width: 1),
              Expanded(flex: 3, child: body),
              const VerticalDivider(width: 1),
              Expanded(flex: 2, child: _previewPanel(svc, draft)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _mobileTabBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFECECEE))),
      ),
      child: SegmentedButton<int>(
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: 0, label: Text('大纲')),
          ButtonSegment(value: 1, label: Text('正文')),
          ButtonSegment(value: 2, label: Text('预览')),
        ],
        selected: {_mobileTab},
        onSelectionChanged: (v) => setState(() => _mobileTab = v.first),
      ),
    );
  }

  Widget _topBar(PaperService svc, PaperDraft draft) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回论文列表',
            onPressed: svc.busy ? null : svc.closePaper,
            icon: const Icon(Icons.arrow_back, size: 18),
          ),
          Flexible(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  draft.titleZh,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${draft.format.label} · ${draft.doneSections}/${draft.sections.length} 节 · 约 ${draft.totalWords} 字词',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: _muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 按钮较多，用 Wrap 自动换行，保证任何宽度下都完整可见、可点、不溢出。
          Flexible(
            flex: 6,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: _actions(svc, draft),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _actions(PaperService svc, PaperDraft draft) {
    return [
      OutlinedButton.icon(
        onPressed: svc.busy ? null : () => _chooseTopic(svc, draft),
        icon: const Icon(Icons.lightbulb_outline, size: 15),
        label: const Text('选择论文主题'),
      ),
      OutlinedButton.icon(
        onPressed: svc.busy ? null : () => svc.generateTitleAndOutline(draft),
        icon: const Icon(Icons.schema_outlined, size: 15),
        label: const Text('生成结构'),
      ),
      _langMenuButton(
        svc: svc,
        icon: Icons.auto_awesome,
        label: '写稿 ▾',
        filled: true,
        withBoth: true,
        onZh: () => svc.writeDraft(PaperLang.zh, draft),
        onEn: () => svc.writeDraft(PaperLang.en, draft),
        onBoth: () => svc.writeDraft(PaperLang.both, draft),
      ),
      _langMenuButton(
        svc: svc,
        icon: Icons.rate_review_outlined,
        label: '审校 ▾',
        onZh: () => _runReview(svc, draft, PaperLang.zh),
        onEn: () => _runReview(svc, draft, PaperLang.en),
      ),
      _langMenuButton(
        svc: svc,
        icon: Icons.brush_outlined,
        label: '润色 ▾',
        onZh: () => svc.applyPolish(PaperLang.zh, draft),
        onEn: () => svc.applyPolish(PaperLang.en, draft),
      ),
      // 图表依赖 python+matplotlib（桌面外部工具链），移动端隐藏。
      if (PlatformCapabilities.supportsFigures)
        OutlinedButton.icon(
          onPressed: svc.busy ? null : () => _generateFigures(svc, draft),
          icon: const Icon(Icons.insert_chart_outlined, size: 15),
          label: Text(
            draft.figures.isEmpty ? '图表' : '图表(${draft.figures.length})',
          ),
        ),
      // 关联工程解读依赖 ripgrep（桌面捆绑二进制），移动端隐藏。
      if (PlatformCapabilities.supportsCodeSearch) _projectButton(svc, draft),
      PopupMenuButton<String>(
        enabled: !svc.busy,
        tooltip: '导出',
        onSelected: (v) {
          if (v == 'pdf_zh') _export(svc, PaperLang.zh);
          if (v == 'pdf_en') _export(svc, PaperLang.en);
          if (v == 'md') _exportMarkdown(svc);
        },
        itemBuilder: (_) => [
          // PDF 导出依赖 xelatex/pandoc（桌面），移动端仅保留 Markdown。
          if (PlatformCapabilities.supportsPdfExport) ...const [
            PopupMenuItem(value: 'pdf_zh', child: Text('导出中文 PDF')),
            PopupMenuItem(value: 'pdf_en', child: Text('导出英文 PDF')),
          ],
          const PopupMenuItem(value: 'md', child: Text('导出 Markdown')),
        ],
        child: OutlinedButton.icon(
          onPressed: null,
          style: OutlinedButton.styleFrom(
            disabledForegroundColor: svc.busy ? null : _ink,
          ),
          icon: const Icon(Icons.ios_share, size: 15),
          label: Text(PlatformCapabilities.supportsPdfExport ? '导出 ▾' : '导出'),
        ),
      ),
    ];
  }

  /// 带「中文稿 / 英文稿 (/ 双语稿)」下拉的动作按钮。
  Widget _langMenuButton({
    required PaperService svc,
    required IconData icon,
    required String label,
    required VoidCallback onZh,
    required VoidCallback onEn,
    VoidCallback? onBoth,
    bool withBoth = false,
    bool filled = false,
  }) {
    final child = filled
        ? FilledButton.icon(
            onPressed: null,
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              disabledBackgroundColor: svc.busy ? null : _accent,
              disabledForegroundColor: Colors.white,
            ),
            icon: Icon(icon, size: 15),
            label: Text(label),
          )
        : OutlinedButton.icon(
            onPressed: null,
            style: OutlinedButton.styleFrom(
              disabledForegroundColor: svc.busy ? null : _ink,
            ),
            icon: Icon(icon, size: 15),
            label: Text(label),
          );
    return PopupMenuButton<String>(
      enabled: !svc.busy,
      onSelected: (v) {
        if (v == 'zh') onZh();
        if (v == 'en') onEn();
        if (v == 'both') onBoth?.call();
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'zh', child: Text('中文稿')),
        const PopupMenuItem(value: 'en', child: Text('英文稿')),
        if (withBoth) const PopupMenuItem(value: 'both', child: Text('双语稿')),
      ],
      child: child,
    );
  }

  Widget _projectButton(PaperService svc, PaperDraft draft) {
    final count = draft.linkedProjects.length;
    final linked = count > 0;
    return OutlinedButton.icon(
      onPressed: svc.busy ? null : () => _manageProjects(svc, draft),
      style: OutlinedButton.styleFrom(
        foregroundColor: linked ? _accent : _ink,
      ),
      icon: Icon(linked ? Icons.link : Icons.link_outlined, size: 15),
      label: Text(
        linked ? '已关联 $count 个 ▾' : '关联工程 ▾',
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// 关联工程管理弹窗：支持从最近工程或选择文件夹添加多个工程、逐个解读、移除。
  Future<void> _manageProjects(PaperService svc, PaperDraft draft) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
          child: ListenableBuilder(
            listenable: svc,
            builder: (context, _) {
              final linked = draft.linkedProjects;
              final recent = svc.recentProjects
                  .where((path) => !linked.any((e) => e.path == path))
                  .toList();
              return Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.science_outlined,
                            size: 18, color: _accent),
                        const SizedBox(width: 8),
                        const Text(
                          '关联工程',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(ctx).pop(),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                    const Text(
                      '可关联多个工程；第二大脑会读取真实文件解读，用于推荐选题、生成结构与写稿。',
                      style: TextStyle(fontSize: 12.5, height: 1.5, color: _sub),
                    ),
                    if (svc.busy) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              svc.stage,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF0F766E)),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 14),
                    Text(
                      '已关联（${linked.length}）',
                      style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: _muted),
                    ),
                    const SizedBox(height: 6),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (linked.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text('尚未关联工程',
                                    style: TextStyle(
                                        fontSize: 12.5, color: _muted)),
                              ),
                            for (final proj in linked)
                              _linkedProjectRow(svc, proj),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                const Text(
                                  '添加工程',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: _muted),
                                ),
                                const Spacer(),
                                OutlinedButton.icon(
                                  onPressed: svc.busy
                                      ? null
                                      : () => _pickAndAddProject(svc),
                                  icon:
                                      const Icon(Icons.folder_open, size: 15),
                                  label: const Text('选择文件夹…'),
                                ),
                              ],
                            ),
                            if (recent.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              const Text(
                                '最近打开的工程',
                                style:
                                    TextStyle(fontSize: 11.5, color: _muted),
                              ),
                              const SizedBox(height: 4),
                              for (final path in recent)
                                _recentProjectRow(svc, path),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _linkedProjectRow(PaperService svc, LinkedProject proj) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  proj.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                Text(
                  proj.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
                Text(
                  proj.hasDigest ? '已解读' : '未解读（写稿/选题前会自动解读）',
                  style: TextStyle(
                    fontSize: 11,
                    color: proj.hasDigest ? _accent : _muted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: proj.hasDigest ? '重新解读' : '解读工程',
            onPressed: svc.busy
                ? null
                : () => svc.interpretProjects(onlyPath: proj.path),
            icon: const Icon(Icons.auto_stories_outlined, size: 17),
          ),
          IconButton(
            tooltip: '移除',
            onPressed:
                svc.busy ? null : () => svc.removeLinkedProject(proj.path),
            icon: const Icon(Icons.close, size: 17),
          ),
        ],
      ),
    );
  }

  Widget _recentProjectRow(PaperService svc, String path) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 15, color: _muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: _sub),
            ),
          ),
          TextButton(
            onPressed: svc.busy ? null : () => svc.addLinkedProject(path),
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndAddProject(PaperService svc) async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: '选择要关联的工程目录',
    );
    if (dir == null) return;
    await svc.addLinkedProject(dir);
  }

  /// 「选择论文主题」弹窗：与关联工程交互生成候选选题，选定后驱动结构生成与写稿。
  Future<void> _chooseTopic(PaperService svc, PaperDraft draft) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 660),
          child: ListenableBuilder(
            listenable: svc,
            builder: (context, _) {
              final options = draft.topicOptions;
              return Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.lightbulb_outline,
                            size: 18, color: _accent),
                        const SizedBox(width: 8),
                        const Text(
                          '选择论文主题',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(ctx).pop(),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                    const Text(
                      '与关联工程交互（智能体多轮检索代码），生成可投稿的候选选题；选定后即可「生成结构」「写稿」。',
                      style: TextStyle(fontSize: 12.5, height: 1.5, color: _sub),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed:
                              svc.busy ? null : () => svc.recommendTopics(draft),
                          style: FilledButton.styleFrom(
                              backgroundColor: _accent),
                          icon: const Icon(Icons.auto_awesome, size: 15),
                          label: Text(
                              options.isEmpty ? '与工程交互生成推荐' : '重新推荐'),
                        ),
                        const SizedBox(width: 12),
                        if (svc.busy)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        if (svc.busy) const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            svc.busy
                                ? svc.stage
                                : (draft.hasLinkedProject
                                    ? '已关联 ${draft.linkedProjects.length} 个工程'
                                    : '未关联工程，将仅依据来源研究报告'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: _muted),
                          ),
                        ),
                      ],
                    ),
                    if (svc.busy) ...[
                      const SizedBox(height: 10),
                      _ProgressLog(lines: svc.progressLog),
                    ],
                    const SizedBox(height: 12),
                    Flexible(
                      child: options.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 24),
                                child: Text(
                                  svc.busy
                                      ? '智能体正在检索工程代码，深挖研究方向…'
                                      : '点击上方按钮，让第二大脑结合工程生成候选选题',
                                  style: const TextStyle(
                                      fontSize: 12.5, color: _muted),
                                ),
                              ),
                            )
                          : SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (final option in options)
                                    _topicOptionCard(ctx, svc, option),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _topicOptionCard(
    BuildContext ctx,
    PaperService svc,
    PaperTopicOption option,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            option.titleZh,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          if (option.titleEn.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              option.titleEn,
              style: const TextStyle(
                  fontSize: 12, color: _sub, fontStyle: FontStyle.italic),
            ),
          ],
          if (option.summary.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              option.summary,
              style: const TextStyle(fontSize: 12.5, height: 1.55, color: _sub),
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: svc.busy
                  ? null
                  : () async {
                      await svc.selectTopic(option);
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      _toast('已选定主题，可点击「生成结构」或「写稿」');
                    },
              style: FilledButton.styleFrom(backgroundColor: _accent),
              child: const Text('选用此主题'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusStrip(PaperService svc) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFF0FBF9),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (svc.busy)
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (svc.busy) const SizedBox(width: 10),
          Expanded(
            child: Text(
              svc.stage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF0F766E)),
            ),
          ),
          if (svc.busy)
            TextButton(
              onPressed: svc.cancel,
              child: const Text('停止', style: TextStyle(fontSize: 12.5)),
            ),
        ],
      ),
    );
  }

  Widget _leftPanel(PaperService svc, PaperDraft draft, {bool mobile = false}) {
    return SizedBox(
      width: mobile ? double.infinity : 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: _navTile(
              icon: Icons.dashboard_outlined,
              label: '论文概览',
              selected: svc.activeSection == null,
              onTap: () => svc.openSection(null),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: Row(
              children: [
                const Text(
                  '论文结构',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _muted,
                  ),
                ),
                const Spacer(),
                _chip(draft.format.label),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: draft.sections.length,
              itemBuilder: (context, i) => _sectionTile(svc, draft.sections[i]),
            ),
          ),
          if (draft.sourceResearchTitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                '来源研究：${draft.sourceResearchTitle}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: _muted,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _navTile({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? const Color(0xFFE8F5F3) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              Icon(icon, size: 17, color: selected ? _accent : _sub),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? _accent : _ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTile(PaperService svc, PaperSection section) {
    final selected = svc.activeSection == section;
    return Material(
      color: selected ? const Color(0xFFECECEE) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => svc.openSection(section),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 8, top: 2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: section.hasContent ? _accent : const Color(0xFFD3D3D7),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      section.zhTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: _ink),
                    ),
                    Text(
                      section.enTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: _muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _overview(PaperService svc, PaperDraft draft) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            draft.titleZh,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          if (draft.titleEn.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              draft.titleEn,
              style: const TextStyle(fontSize: 15, color: _sub, height: 1.5),
            ),
          ],
          if (PlatformCapabilities.supportsCodeSearch) ...[
            const SizedBox(height: 24),
            _projectCard(svc, draft),
          ],
          const SizedBox(height: 24),
          const Text(
            '论文结构',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          for (final section in draft.sections)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '• ${section.zhTitle} / ${section.enTitle}${section.brief.isEmpty ? '' : '：${section.brief}'}',
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: _sub,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _projectCard(PaperService svc, PaperDraft draft) {
    final linked = draft.linkedProjects;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.science_outlined, size: 17, color: _accent),
              const SizedBox(width: 8),
              Text(
                '关联工程（${linked.length}）',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: svc.busy ? null : () => _manageProjects(svc, draft),
                icon: const Icon(Icons.tune, size: 15),
                label: const Text('管理关联工程'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (linked.isEmpty)
            const Text(
              '关联该论文对应的实验/代码工程（可多选）后，第二大脑会读取工程真实文件，'
              '据此推荐选题、生成结构，并把方法、实验设置、结果等按真实实现落地到论文。',
              style: TextStyle(fontSize: 12.5, height: 1.5, color: _sub),
            )
          else
            for (final proj in linked) _projectDigestBlock(proj),
        ],
      ),
    );
  }

  Widget _projectDigestBlock(LinkedProject proj) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder_outlined, size: 14, color: _accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  proj.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                proj.hasDigest ? '已解读' : '未解读',
                style: TextStyle(
                  fontSize: 11,
                  color: proj.hasDigest ? _accent : _muted,
                ),
              ),
            ],
          ),
          if (proj.hasDigest) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFECECEE)),
              ),
              child: MarkdownBody(
                data: proj.digest,
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(fontSize: 12.5, height: 1.6),
                  h2: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _previewPanel(PaperService svc, PaperDraft draft) {
    final data = svc.renderPreview(draft, english: _previewEnglish);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Row(
            children: [
              const Text(
                '格式化预览',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('中文')),
                  ButtonSegment(value: true, label: Text('英文')),
                ],
                selected: {_previewEnglish},
                onSelectionChanged: (set) {
                  setState(() => _previewEnglish = set.first);
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: draft.format == PaperFormat.markdown
              ? Markdown(
                  data: data,
                  selectable: true,
                  padding: const EdgeInsets.all(20),
                  styleSheet: MarkdownStyleSheet(
                    p: const TextStyle(fontSize: 13.5, height: 1.7),
                    h1: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                    h2: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: SelectableText(
                    data,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.55,
                      fontFamily: 'Consolas',
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _export(PaperService svc, PaperLang lang) async {
    try {
      final paths = await svc.exportPdf(lang);
      _toast('已导出 ${paths.length} 个 PDF，并打开导出目录');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  Future<void> _generateFigures(PaperService svc, PaperDraft draft) async {
    final lang = draft.sections.any((s) => s.zh.trim().isNotEmpty)
        ? PaperLang.zh
        : PaperLang.en;
    await svc.generateFigures(lang, draft);
  }

  /// 审校：跑 5 专家审校，完成后展示意见，并可确认让润色主笔人据此改稿。
  Future<void> _runReview(
    PaperService svc,
    PaperDraft draft,
    PaperLang lang,
  ) async {
    await svc.reviewPaper(lang, draft);
    if (!mounted) return;
    if (draft.reviewReport.trim().isEmpty) {
      _toast(svc.stage);
      return;
    }
    await _showReviewDialog(svc, draft, lang);
  }

  Future<void> _showReviewDialog(
    PaperService svc,
    PaperDraft draft,
    PaperLang lang,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.rate_review_outlined, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      '专家审校意见（${lang == PaperLang.en ? '英文稿' : '中文稿'}）',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Markdown(
                    data: draft.reviewReport,
                    selectable: true,
                    padding: EdgeInsets.zero,
                    styleSheet: MarkdownStyleSheet(
                      p: const TextStyle(fontSize: 13, height: 1.55),
                      h1: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                      ),
                      h2: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                      h3: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                      strong: const TextStyle(fontWeight: FontWeight.w700),
                      listBullet: const TextStyle(fontSize: 13, height: 1.55),
                      horizontalRuleDecoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            width: 1,
                            color: Colors.grey.shade300,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('稍后处理'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: _accent),
                      onPressed: () {
                        Navigator.pop(ctx);
                        svc.applyPolish(lang, draft);
                      },
                      icon: const Icon(Icons.brush_outlined, size: 15),
                      label: const Text('让润色主笔人据此改稿'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _exportMarkdown(PaperService svc) async {
    try {
      final paths = await svc.exportMarkdown();
      _toast('已导出 ${paths.length} 个 Markdown，并打开导出目录');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

}

/// 实时进度日志面板：随新行滚动到底部，让用户看到智能体每一步在做什么。
class _ProgressLog extends StatelessWidget {
  const _ProgressLog({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 128,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: SingleChildScrollView(
        reverse: true,
        child: Text(
          lines.join('\n'),
          style: const TextStyle(
            fontSize: 11.5,
            height: 1.5,
            color: Color(0xFF6B7280),
            fontFamily: 'Consolas',
          ),
        ),
      ),
    );
  }
}

class _PaperSectionEditor extends StatefulWidget {
  const _PaperSectionEditor({
    super.key,
    required this.svc,
    required this.section,
    required this.busy,
  });

  final PaperService svc;
  final PaperSection section;
  final bool busy;

  @override
  State<_PaperSectionEditor> createState() => _PaperSectionEditorState();
}

class _PaperSectionEditorState extends State<_PaperSectionEditor> {
  late final TextEditingController _zhTitle = TextEditingController(
    text: widget.section.zhTitle,
  );
  late final TextEditingController _enTitle = TextEditingController(
    text: widget.section.enTitle,
  );
  late final TextEditingController _zh = TextEditingController(
    text: widget.section.zh,
  );
  late final TextEditingController _en = TextEditingController(
    text: widget.section.en,
  );
  final _zhFocus = FocusNode();
  final _enFocus = FocusNode();
  bool _editingEnglish = false;

  @override
  void didUpdateWidget(covariant _PaperSectionEditor old) {
    super.didUpdateWidget(old);
    if (old.section.id != widget.section.id) {
      _seed();
      return;
    }
    if (!_zhFocus.hasFocus && _zh.text != widget.section.zh) {
      _zh.value = TextEditingValue(
        text: widget.section.zh,
        selection: TextSelection.collapsed(offset: widget.section.zh.length),
      );
    }
    if (!_enFocus.hasFocus && _en.text != widget.section.en) {
      _en.value = TextEditingValue(
        text: widget.section.en,
        selection: TextSelection.collapsed(offset: widget.section.en.length),
      );
    }
  }

  @override
  void dispose() {
    _zhTitle.dispose();
    _enTitle.dispose();
    _zh.dispose();
    _en.dispose();
    _zhFocus.dispose();
    _enFocus.dispose();
    super.dispose();
  }

  void _seed() {
    _zhTitle.text = widget.section.zhTitle;
    _enTitle.text = widget.section.enTitle;
    _zh.text = widget.section.zh;
    _en.text = widget.section.en;
  }

  Future<void> _save() async {
    widget.section.zhTitle = _zhTitle.text.trim().isEmpty
        ? widget.section.zhTitle
        : _zhTitle.text.trim();
    widget.section.enTitle = _enTitle.text.trim().isEmpty
        ? widget.section.enTitle
        : _enTitle.text.trim();
    widget.section.zh = _zh.text;
    widget.section.en = _en.text;
    await widget.svc.saveDraft();
  }

  TextEditingController get _activeTitle =>
      _editingEnglish ? _enTitle : _zhTitle;

  TextEditingController get _activeBody => _editingEnglish ? _en : _zh;

  FocusNode get _activeFocus => _editingEnglish ? _enFocus : _zhFocus;

  String get _activeTitleHint =>
      _editingEnglish ? 'English section title' : '中文小节标题';

  String get _activeDraftLabel => _editingEnglish ? '英文稿' : '中文稿';

  String get _activeBodyHint => _editingEnglish
      ? 'English draft will appear here. You can edit it manually.'
      : '中文稿会显示在这里，也可以手动撰写。';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _activeTitle,
                  onChanged: (value) {
                    if (_editingEnglish) {
                      widget.section.enTitle = value;
                    } else {
                      widget.section.zhTitle = value;
                    }
                  },
                  onTapOutside: (_) => _save(),
                  onEditingComplete: _save,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: _activeTitleHint,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('中文')),
                  ButtonSegment(value: true, label: Text('英文')),
                ],
                selected: {_editingEnglish},
                onSelectionChanged: (set) async {
                  await _save();
                  if (!mounted) return;
                  setState(() => _editingEnglish = set.first);
                },
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: widget.busy ? null : _save,
                icon: const Icon(Icons.save_outlined, size: 15),
                label: const Text('保存'),
              ),
            ],
          ),
          if (widget.section.brief.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '写作要点：${widget.section.brief}',
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: _muted,
                ),
              ),
            ),
          Expanded(
            child: _editorBox(
              title: _activeDraftLabel,
              controller: _activeBody,
              focus: _activeFocus,
              hint: _activeBodyHint,
            ),
          ),
        ],
      ),
    );
  }

  Widget _editorBox({
    required String title,
    required TextEditingController controller,
    required FocusNode focus,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: _sub,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focus,
            readOnly: widget.busy,
            onChanged: (value) {
              if (_editingEnglish) {
                widget.section.en = value;
              } else {
                widget.section.zh = value;
              }
            },
            expands: true,
            maxLines: null,
            textAlignVertical: TextAlignVertical.top,
            onTapOutside: (_) {
              focus.unfocus();
              _save();
            },
            style: const TextStyle(fontSize: 13.5, height: 1.65),
            decoration: InputDecoration(
              hintText: hint,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
        ),
      ],
    );
  }
}
