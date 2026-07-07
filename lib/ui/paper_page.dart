import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../services/paper_service.dart';

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
              Expanded(
                flex: 3,
                child: svc.activeSection == null
                    ? _overview(svc, draft)
                    : _PaperSectionEditor(
                        key: ValueKey(svc.activeSection!.id),
                        svc: svc,
                        section: svc.activeSection!,
                        busy: svc.busy,
                      ),
              ),
              const VerticalDivider(width: 1),
              Expanded(flex: 2, child: _previewPanel(svc, draft)),
            ],
          ),
        ),
      ],
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
          Expanded(
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
                  style: const TextStyle(fontSize: 11.5, color: _muted),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: svc.busy
                ? null
                : () => svc.generateTitleAndOutline(draft),
            icon: const Icon(Icons.schema_outlined, size: 15),
            label: const Text('生成结构'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: svc.busy ? null : () => svc.writeBilingualDraft(draft),
            style: FilledButton.styleFrom(backgroundColor: _accent),
            icon: const Icon(Icons.auto_awesome, size: 15),
            label: const Text('写双语稿'),
          ),
          const SizedBox(width: 8),
          _projectMenu(svc, draft),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            enabled: !svc.busy,
            tooltip: '导出',
            onSelected: (v) {
              if (v == 'pdf') _export(svc);
              if (v == 'md') _exportMarkdown(svc);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pdf', child: Text('导出 PDF')),
              PopupMenuItem(value: 'md', child: Text('导出 Markdown')),
            ],
            child: OutlinedButton.icon(
              onPressed: null,
              style: OutlinedButton.styleFrom(
                disabledForegroundColor: svc.busy ? null : _ink,
              ),
              icon: const Icon(Icons.ios_share, size: 15),
              label: const Text('导出 ▾'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _projectMenu(PaperService svc, PaperDraft draft) {
    final linked = draft.hasLinkedProject;
    return PopupMenuButton<String>(
      enabled: !svc.busy,
      tooltip: linked ? '实验工程：${draft.linkedProjectName}' : '关联实验工程',
      onSelected: (v) async {
        switch (v) {
          case 'link':
            await _linkProject(svc);
          case 'interpret':
            await svc.interpretProject(draft);
          case 'unlink':
            await svc.setLinkedProject(null);
            _toast('已取消关联实验工程');
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'link',
          child: Text(linked ? '重新选择实验工程' : '关联实验工程目录'),
        ),
        if (linked)
          PopupMenuItem(
            value: 'interpret',
            child: Text(draft.projectDigest.isEmpty ? '解读工程' : '重新解读工程'),
          ),
        if (linked)
          const PopupMenuItem(value: 'unlink', child: Text('取消关联')),
      ],
      child: OutlinedButton.icon(
        onPressed: null,
        style: OutlinedButton.styleFrom(
          disabledForegroundColor: svc.busy ? null : (linked ? _accent : _ink),
        ),
        icon: Icon(
          linked ? Icons.link : Icons.link_outlined,
          size: 15,
        ),
        label: Text(
          linked ? '实验工程 ▾' : '关联工程 ▾',
          overflow: TextOverflow.ellipsis,
        ),
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

  Widget _leftPanel(PaperService svc, PaperDraft draft) {
    return SizedBox(
      width: 260,
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
          const SizedBox(height: 24),
          _projectCard(svc, draft),
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
    final linked = draft.hasLinkedProject;
    final hasDigest = draft.projectDigest.trim().isNotEmpty;
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
              const Text(
                '关联实验工程',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (!linked)
                OutlinedButton.icon(
                  onPressed: svc.busy ? null : () => _linkProject(svc),
                  icon: const Icon(Icons.link, size: 15),
                  label: const Text('关联工程目录'),
                )
              else
                OutlinedButton.icon(
                  onPressed: svc.busy ? null : () => svc.interpretProject(draft),
                  icon: const Icon(Icons.auto_stories_outlined, size: 15),
                  label: Text(hasDigest ? '重新解读' : '解读工程'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            linked
                ? '工程目录：${draft.linkedProjectPath}'
                : '关联该论文对应的实验工程目录后，第二大脑会读取工程真实文件，把方法、'
                      '实验设置、结果等按真实实现落地到论文，而非泛泛而谈。',
            style: const TextStyle(fontSize: 12.5, height: 1.5, color: _sub),
          ),
          if (linked) ...[
            const SizedBox(height: 12),
            Text(
              hasDigest ? '工程解读' : '尚未解读（写双语稿时会自动解读一次）',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _muted,
              ),
            ),
            if (hasDigest) ...[
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
                  data: draft.projectDigest,
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

  Future<void> _export(PaperService svc) async {
    try {
      final paths = await svc.export();
      _toast('已导出 ${paths.length} 个 PDF，并打开导出目录');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  Future<void> _exportMarkdown(PaperService svc) async {
    try {
      final paths = await svc.exportMarkdown();
      _toast('已导出 ${paths.length} 个 Markdown，并打开导出目录');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  Future<void> _linkProject(PaperService svc) async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: '选择该论文对应的实验工程目录',
    );
    if (dir == null) return;
    await svc.setLinkedProject(dir);
    _toast('已关联实验工程，可在「实验工程」菜单中点“解读工程”');
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
