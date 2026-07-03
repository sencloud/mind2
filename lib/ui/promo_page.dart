import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../services/promo_service.dart';

// 统一配色，与写作其它页保持一致。
const _accent = Color(0xFF0D9488);
const _ink = Color(0xFF2F2F33);
const _sub = Color(0xFF6B6B70);
const _muted = Color(0xFF9B9B9F);
const _panel = Color(0xFFF7F7F8);

/// 「推广」页：为指定应用生成知乎推广推文。
/// 书架（推广稿列表）+ 工作区（左侧填应用信息与参数，右侧生成推文并预览）。
class PromoPage extends StatefulWidget {
  const PromoPage({super.key, required this.service});

  final PromoService service;

  @override
  State<PromoPage> createState() => _PromoPageState();
}

class _PromoPageState extends State<PromoPage> {
  final _appNameCtrl = TextEditingController();
  final _introCtrl = TextEditingController();
  final _sellingCtrl = TextEditingController();
  final _audienceCtrl = TextEditingController();
  String? _boundDraftId;

  /// 右侧正文视图：false=预览，true=编辑 Markdown 源码。
  bool _editing = false;
  final _contentCtrl = TextEditingController();

  /// 走读日志的滚动控制（新日志到达时自动滚到底部）。
  final _logScroll = ScrollController();

  /// 是否在右侧展示走读日志（走读中强制展示；完成后可手动切回推文）。
  bool _showLog = false;

  @override
  void dispose() {
    _appNameCtrl.dispose();
    _introCtrl.dispose();
    _sellingCtrl.dispose();
    _audienceCtrl.dispose();
    _contentCtrl.dispose();
    _logScroll.dispose();
    super.dispose();
  }

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
      listenable: widget.service,
      builder: (context, _) {
        final svc = widget.service;
        return svc.current == null ? _buildShelf(svc) : _buildWorkspace(svc);
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 书架
  // ---------------------------------------------------------------------------

  Widget _buildShelf(PromoService svc) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '推广',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => _newDraft(svc),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1A1A1A),
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新建推广'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '为指定应用撰写知乎推广推文：填写应用信息与切入角度，AI 生成贴合知乎调性的'
            '标题与正文（真实体验切入、干货植入、自然引导）。',
            style: TextStyle(fontSize: 13, color: _sub),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: svc.drafts.isEmpty
                ? const Center(
                    child: Text(
                      '还没有推广稿，点击右上角「新建推广」开始',
                      style: TextStyle(fontSize: 13, color: _muted),
                    ),
                  )
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 320,
                          mainAxisExtent: 150,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                    itemCount: svc.drafts.length,
                    itemBuilder: (context, i) => _draftCard(svc, svc.drafts[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _draftCard(PromoService svc, PromoDraft draft) {
    return Material(
      color: _panel,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => svc.openDraft(draft),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.campaign_outlined, size: 18, color: _accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      draft.appName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '删除',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    onPressed: () => _confirmDelete(svc, draft),
                    icon: const Icon(Icons.close, color: _muted),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  draft.title.isNotEmpty
                      ? draft.title
                      : (draft.appIntro.isNotEmpty ? draft.appIntro : '（暂无内容）'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, height: 1.5, color: _sub),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _chip('知乎'),
                  const SizedBox(width: 6),
                  if (draft.angle.isNotEmpty) _chip(draft.angle),
                  const Spacer(),
                  Text(
                    draft.hasContent ? '${draft.words} 字' : '未生成',
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

  Widget _chip(String text) => Container(
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

  Future<void> _confirmDelete(PromoService svc, PromoDraft draft) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除推广稿'),
        content: Text('确定删除《${draft.appName}》的推广稿吗？此操作不可恢复。'),
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
    if (ok == true) await svc.deleteDraft(draft);
  }

  Future<void> _newDraft(PromoService svc) async {
    final appName = TextEditingController();
    final intro = TextEditingController();
    final audience = TextEditingController();
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建知乎推广'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _field(appName, '应用名称 *', '例如：第二大脑'),
                _field(intro, '应用简介 / 核心功能', '一句话说清它是什么、能帮用户做什么', maxLines: 3),
                _field(audience, '目标读者（可选）', '例如：需要整理资料的知识工作者'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _accent),
            onPressed: () {
              if (appName.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (created == true) {
      svc.createDraft(
        appName: appName.text,
        appIntro: intro.text,
        audience: audience.text,
      );
    }
  }

  Widget _field(
    TextEditingController c,
    String label,
    String hint, {
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        style: const TextStyle(fontSize: 13.5),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 工作区
  // ---------------------------------------------------------------------------

  Widget _buildWorkspace(PromoService svc) {
    final draft = svc.current!;
    if (_boundDraftId != draft.id) {
      _boundDraftId = draft.id;
      _appNameCtrl.text = draft.appName;
      _introCtrl.text = draft.appIntro;
      _sellingCtrl.text = draft.sellingPoints;
      _audienceCtrl.text = draft.audience;
      _contentCtrl.text = draft.content;
      _editing = false;
      _showLog = false;
    }
    return Column(
      children: [
        _topBar(svc, draft),
        const Divider(height: 1, color: Color(0xFFECECEE)),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 340, child: _settingsPanel(svc, draft)),
              const VerticalDivider(width: 1, color: Color(0xFFECECEE)),
              Expanded(
                child: svc.walking || _showLog
                    ? _walkLogView(svc)
                    : _postPanel(svc, draft),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _topBar(PromoService svc, PromoDraft draft) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      color: Colors.white,
      child: Row(
        children: [
          IconButton(
            tooltip: '返回列表',
            onPressed: svc.busy ? null : svc.closeDraft,
            icon: const Icon(Icons.arrow_back, size: 18),
          ),
          const Icon(Icons.campaign_outlined, size: 18, color: _accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              draft.appName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          _chip('知乎'),
          const SizedBox(width: 12),
          if (svc.busy)
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    svc.stage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: _sub),
                  ),
                ),
                TextButton(onPressed: svc.cancel, child: const Text('停止')),
              ],
            )
          else ...[
            if (svc.stage.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(
                  svc.stage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: _muted),
                ),
              ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: draft.hasContent ? () => _copy(draft) : null,
              icon: const Icon(Icons.copy_all_outlined, size: 16),
              label: const Text('复制推文'),
            ),
            FilledButton.icon(
              onPressed: draft.hasContent ? () => _doExport(svc) : null,
              style: FilledButton.styleFrom(backgroundColor: _accent),
              icon: const Icon(Icons.download_outlined, size: 16),
              label: const Text('导出 MD'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _copy(PromoDraft draft) async {
    final text = draft.title.isEmpty
        ? draft.content
        : '${draft.title}\n\n${draft.content}';
    await Clipboard.setData(ClipboardData(text: text));
    _toast('已复制推文到剪贴板');
  }

  Future<void> _doExport(PromoService svc) async {
    try {
      final path = await svc.export();
      if (mounted) _toast('已导出：$path');
    } catch (e) {
      if (mounted) _toast('导出失败：$e');
    }
  }

  // ---------------- 左侧：应用信息与参数 ----------------

  Widget _settingsPanel(PromoService svc, PromoDraft draft) {
    return Container(
      color: _panel,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _panelField('应用名称', _appNameCtrl, '产品/应用名', svc,
                (v) => draft.appName = v.trim().isEmpty ? '未命名应用' : v.trim()),
            _panelField('应用简介 / 核心功能', _introCtrl, '它是什么、能帮用户解决什么', svc,
                (v) => draft.appIntro = v, maxLines: 4),
            _panelField('卖点 / 亮点（可选）', _sellingCtrl, '最想突出的差异化优势', svc,
                (v) => draft.sellingPoints = v, maxLines: 3),
            _panelField('目标读者（可选）', _audienceCtrl, '这篇推文想打动谁', svc,
                (v) => draft.audience = v),
            const SizedBox(height: 18),
            _projectSection(svc, draft),
            const SizedBox(height: 16),
            const Text('切入角度',
                style: TextStyle(fontSize: 12.5, color: _sub)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final a in PromoService.angles)
                  ChoiceChip(
                    label: Text(a, style: const TextStyle(fontSize: 12)),
                    selected: draft.angle == a,
                    onSelected: svc.busy
                        ? null
                        : (_) {
                            draft.angle = draft.angle == a ? '' : a;
                            svc.save();
                          },
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const Text('语气风格',
                style: TextStyle(fontSize: 12.5, color: _sub)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in PromoService.tones)
                  ChoiceChip(
                    label: Text(t, style: const TextStyle(fontSize: 12)),
                    selected: draft.tone == t,
                    onSelected: svc.busy
                        ? null
                        : (_) {
                            draft.tone = t;
                            svc.save();
                          },
                  ),
              ],
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: svc.busy ? null : svc.generateTitles,
              style: OutlinedButton.styleFrom(
                foregroundColor: _ink,
                side: const BorderSide(color: Color(0xFFD9D9DE)),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              icon: const Icon(Icons.title_outlined, size: 16, color: _accent),
              label: const Text('① 生成标题建议'),
            ),
            if (draft.titleOptions.isNotEmpty) ...[
              const SizedBox(height: 10),
              _titleOptions(svc, draft),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: svc.busy ? null : svc.generatePost,
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.auto_awesome, size: 16),
              label: Text(draft.hasContent ? '② 重新生成推文' : '② 生成知乎推文'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panelField(
    String label,
    TextEditingController c,
    String hint,
    PromoService svc,
    void Function(String) onChanged, {
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(
            controller: c,
            maxLines: maxLines,
            style: const TextStyle(fontSize: 13, height: 1.5),
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              border: const OutlineInputBorder(),
            ),
            onChanged: onChanged,
            onTapOutside: (_) => svc.save(),
          ),
        ],
      ),
    );
  }

  String _projName(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? path : parts.last;
  }

  Widget _projectSection(PromoService svc, PromoDraft draft) {
    final projects = svc.projects;
    final hasSelection =
        draft.projectPath.isNotEmpty && projects.contains(draft.projectPath);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE6E6E9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.code, size: 15, color: _accent),
              const SizedBox(width: 6),
              const Text('关联工程（可选）',
                  style:
                      TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 4),
          const Text('先走读源码提炼真实特点，写出的推文更接地气、准确。',
              style: TextStyle(fontSize: 11.5, color: _muted, height: 1.4)),
          const SizedBox(height: 8),
          if (projects.isEmpty)
            const Text('暂无可关联工程，请先在「项目」里打开一个工程。',
                style: TextStyle(fontSize: 12, color: _sub))
          else
            DropdownButtonFormField<String>(
              initialValue: hasSelection ? draft.projectPath : null,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                hintText: '选择要走读的工程',
              ),
              style: const TextStyle(fontSize: 12.5, color: _ink),
              items: [
                const DropdownMenuItem(value: '', child: Text('不关联工程')),
                for (final path in projects)
                  DropdownMenuItem(
                    value: path,
                    child: Text(
                      _projName(path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: svc.busy
                  ? null
                  : (v) => svc.selectProject(v == null || v.isEmpty ? null : v),
            ),
          if (hasSelection) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: svc.busy
                    ? null
                    : () {
                        setState(() => _showLog = true);
                        svc.analyzeProject();
                      },
                style: OutlinedButton.styleFrom(
                  foregroundColor: _accent,
                  side: const BorderSide(color: _accent),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                ),
                icon: const Icon(Icons.travel_explore_outlined, size: 16),
                label: Text(draft.hasProjectBrief ? '重新走读源码' : '走读源码·提炼特点'),
              ),
            ),
            if (draft.hasProjectBrief) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.check_circle,
                      size: 14, color: _accent),
                  const SizedBox(width: 5),
                  const Expanded(
                    child: Text('已提炼工程特点，将用于生成',
                        style: TextStyle(fontSize: 11.5, color: _accent)),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 28),
                    ),
                    onPressed: () => _showBrief(draft),
                    child: const Text('查看', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  void _showBrief(PromoDraft draft) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('工程源码走读要点'),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: MarkdownBody(data: draft.projectBrief),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _titleOptions(PromoService svc, PromoDraft draft) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('候选标题（点击选用）',
            style: TextStyle(fontSize: 12, color: _sub)),
        const SizedBox(height: 6),
        for (final t in draft.titleOptions)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: InkWell(
              onTap: svc.busy ? null : () => svc.selectTitle(t),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: draft.title == t
                      ? const Color(0xFFE8F5F3)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: draft.title == t ? _accent : const Color(0xFFE6E6E9),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      draft.title == t
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 15,
                      color: draft.title == t ? _accent : _muted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t,
                        style: const TextStyle(fontSize: 12.5, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ---------------- 右侧：走读源码进度日志 ----------------

  Widget _walkLogView(PromoService svc) {
    // 新日志到达后自动滚动到底部。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (svc.walking)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.travel_explore_outlined,
                    size: 16, color: _accent),
              const SizedBox(width: 8),
              const Text('走读源码进度',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (!svc.walking)
                TextButton.icon(
                  onPressed: () => setState(() => _showLog = false),
                  icon: const Icon(Icons.arrow_forward, size: 15),
                  label: const Text('查看推文'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFBFBFC),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFECECEE)),
              ),
              child: svc.walkLog.isEmpty
                  ? const Center(
                      child: Text('正在启动走读…',
                          style: TextStyle(fontSize: 13, color: _muted)),
                    )
                  : ListView.builder(
                      controller: _logScroll,
                      itemCount: svc.walkLog.length,
                      itemBuilder: (context, i) => _logRow(svc.walkLog[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _logRow(PromoLogEntry e) {
    late final IconData icon;
    late final Color color;
    switch (e.kind) {
      case 'tool':
        icon = Icons.terminal;
        color = _accent;
      case 'result':
        icon = Icons.subdirectory_arrow_right;
        color = _muted;
      case 'thought':
        icon = Icons.psychology_outlined;
        color = const Color(0xFF7A6FF0);
      default:
        icon = Icons.info_outline;
        color = _sub;
    }
    final indent = e.kind == 'result';
    return Padding(
      padding: EdgeInsets.only(bottom: 6, left: indent ? 20 : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1.5),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              e.text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: e.kind == 'result' ? _muted : _ink,
                fontWeight:
                    e.kind == 'tool' ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 右侧：推文正文 ----------------

  Widget _postPanel(PromoService svc, PromoDraft draft) {
    if (!svc.busy && _contentCtrl.text != draft.content && !_editing) {
      _contentCtrl.text = draft.content;
    }
    final showEditor = _editing && !svc.busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  draft.title.isEmpty ? '知乎推文' : draft.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SegmentedButton<bool>(
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: false, label: Text('预览')),
                  ButtonSegment(value: true, label: Text('编辑')),
                ],
                selected: {_editing},
                onSelectionChanged: svc.busy
                    ? null
                    : (v) {
                        final edit = v.first;
                        if (edit) _contentCtrl.text = draft.content;
                        setState(() => _editing = edit);
                      },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: draft.content.trim().isEmpty && !svc.busy
                ? const Center(
                    child: Text(
                      '在左侧填写应用信息后，点击「生成知乎推文」。',
                      style: TextStyle(fontSize: 13, color: _muted),
                    ),
                  )
                : showEditor
                    ? TextField(
                        controller: _contentCtrl,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(fontSize: 13.5, height: 1.7),
                        decoration: const InputDecoration(
                          hintText: '推文 Markdown 源码…',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.all(12),
                        ),
                        onChanged: (v) => draft.content = v,
                        onTapOutside: (_) => svc.save(),
                      )
                    : _preview(draft),
          ),
        ],
      ),
    );
  }

  Widget _preview(PromoDraft draft) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: SingleChildScrollView(
        child: MarkdownBody(
          data: draft.content.trim().isEmpty ? '生成中…' : draft.content,
          styleSheet: _postStyle(context),
        ),
      ),
    );
  }

  MarkdownStyleSheet _postStyle(BuildContext context) {
    const body = Color(0xFF1A1A1A);
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: const TextStyle(fontSize: 15, height: 1.85, color: body),
      pPadding: const EdgeInsets.only(bottom: 10),
      h1: const TextStyle(fontSize: 21, height: 1.5, fontWeight: FontWeight.w700, color: body),
      h1Padding: const EdgeInsets.only(top: 6, bottom: 12),
      h2: const TextStyle(fontSize: 18, height: 1.5, fontWeight: FontWeight.w700, color: body),
      h2Padding: const EdgeInsets.only(top: 14, bottom: 8),
      h3: const TextStyle(fontSize: 16, height: 1.5, fontWeight: FontWeight.w700, color: body),
      h3Padding: const EdgeInsets.only(top: 10, bottom: 6),
      listBullet: const TextStyle(fontSize: 15, height: 1.85, color: body),
      blockquote: const TextStyle(fontSize: 14.5, height: 1.7, color: _sub),
      blockquoteDecoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        border: const Border(left: BorderSide(color: _accent, width: 3)),
        borderRadius: BorderRadius.circular(4),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      strong: const TextStyle(fontWeight: FontWeight.w700, color: body),
    );
  }
}
