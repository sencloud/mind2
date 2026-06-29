import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../services/agent/agent_event.dart';
import '../services/code_index_service.dart';
import '../services/project_service.dart';
import 'agent_events_view.dart';
import 'code_view.dart';

class ProjectPage extends StatefulWidget {
  const ProjectPage({super.key, required this.project, this.onOpenResearch});

  final ProjectService project;

  /// 点击项目头部的研究 tag 时，跳转到对应研究报告。
  final void Function(String researchPath)? onOpenResearch;

  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends State<ProjectPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// 左侧面板标签：0=会话历史，1=文件树。
  int _leftTab = 0;

  /// 主区域已打开的文件（绝对路径，按打开顺序），像 VSCode 的编辑器 tab。
  final List<String> _openDocs = [];

  /// 当前激活的文件 tab；null 表示「对话」tab。
  String? _activeDoc;

  /// 已绑定的工程路径，切换工程时清空已打开的文件 tab。
  String? _boundProject;

  /// 打开一个文件为主区域 tab（已打开则只激活）。
  void _openDoc(String abs) {
    setState(() {
      if (!_openDocs.contains(abs)) _openDocs.add(abs);
      _activeDoc = abs;
    });
  }

  /// 关闭一个文件 tab；若关的是当前 tab，则回退到最后一个或「对话」。
  void _closeDoc(String abs) {
    setState(() {
      final wasActive = _activeDoc == abs;
      _openDocs.remove(abs);
      if (wasActive) {
        _activeDoc = _openDocs.isNotEmpty ? _openDocs.last : null;
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      width: 400,
    ));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _openFolder() async {
    final dir =
        await FilePicker.getDirectoryPath(dialogTitle: '选择要打开的项目文件夹');
    if (dir == null) return;
    widget.project.openProject(dir);
  }

  Future<void> _newProject() async {
    final parent = await FilePicker.getDirectoryPath(
        dialogTitle: '选择新建项目的位置（父目录）');
    if (parent == null || !mounted) return;
    final name = await _promptName();
    if (name == null || name.trim().isEmpty) return;
    final path = await widget.project.createProject(parent, name);
    if (path == null) {
      _toast('项目名无效');
    } else {
      _toast('已创建项目：$path');
    }
  }

  Future<String?> _promptName() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建项目'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: TextField(
            controller: c,
            autofocus: true,
            style: const TextStyle(fontSize: 13.5),
            decoration: const InputDecoration(
              labelText: '项目文件夹名称',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => Navigator.pop(ctx, c.text.trim()),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('创建')),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final proj = widget.project;
    if (text.isEmpty || proj.running || proj.current == null) return;
    _input.clear();
    try {
      await proj.develop(text);
    } catch (e) {
      _toast('开发失败：$e');
    }
  }

  void _openRel(String rel) {
    final root = widget.project.current;
    if (root == null) return;
    _openDoc(p.join(root, rel.replaceAll('/', p.separator)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.project,
      builder: (context, _) {
        final proj = widget.project;
        // 未选项目：完整的引导页（标题 + 说明 + 选择器）。
        if (proj.current == null) {
          return Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('项目开发',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: _newProject,
                      icon: const Icon(Icons.create_new_folder_outlined,
                          size: 16),
                      label: const Text('新建项目'),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: _openFolder,
                      icon: const Icon(Icons.folder_open_outlined, size: 16),
                      label: const Text('打开文件夹'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  '选择一个软件工程目录，第二大脑会像工程师一样：了解工程 → 设计方案 → '
                  '写代码、装依赖、运行调试，直到实现你的开发需求。打开后即可直接开始开发。',
                  style: TextStyle(fontSize: 13, color: Color(0xFF6B6B70)),
                ),
                const SizedBox(height: 18),
                Expanded(child: _buildPicker(proj)),
              ],
            ),
          );
        }
        // 已选项目：紧凑控制台（无大标题、无说明）。
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: _buildConsole(proj),
        );
      },
    );
  }

  Widget _buildPicker(ProjectService proj) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (proj.projects.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.folder_special_outlined,
                      size: 40, color: Color(0xFFC4C4CC)),
                  SizedBox(height: 12),
                  Text('还没有项目',
                      style:
                          TextStyle(fontSize: 14, color: Color(0xFF8B8B93))),
                  SizedBox(height: 4),
                  Text('点击右上角「新建项目」或「打开文件夹」开始',
                      style:
                          TextStyle(fontSize: 12.5, color: Color(0xFFA0A0A5))),
                ],
              ),
            ),
          )
        else ...[
          const Text('最近的项目',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6B6B70))),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.separated(
              itemCount: proj.projects.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final path = proj.projects[i];
                final name = path.split('\\').last;
                return _ProjectTile(
                  name: name,
                  path: path,
                  onOpen: () => proj.openProject(path),
                  onReveal: () => launchUrl(Uri.file(path)),
                  onRemove: () => proj.removeProject(path),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildConsole(ProjectService proj) {
    final path = proj.current!;
    // 切换工程时清空上一个工程打开的文件 tab。
    if (_boundProject != path) {
      _boundProject = path;
      _openDocs.clear();
      _activeDoc = null;
    }
    _scrollToBottom();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(proj, path),
        const SizedBox(height: 10),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 240, child: _buildLeftPanel(proj)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildEditorTabs(proj),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _activeDoc == null
                          ? _buildConvPane(proj)
                          : _buildDocPane(_activeDoc!),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 主区域的编辑器 tab 条：固定的「对话」tab + 每个打开文件一个可关闭 tab。
  Widget _buildEditorTabs(ProjectService proj) {
    return SizedBox(
      height: 34,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _EditorTab(
            icon: Icons.forum_outlined,
            label: '对话',
            active: _activeDoc == null,
            onTap: () => setState(() => _activeDoc = null),
          ),
          if (_openDocs.isNotEmpty) const SizedBox(width: 6),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _openDocs.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final d = _openDocs[i];
                return _EditorTab(
                  icon: Icons.description_outlined,
                  label: p.basename(d),
                  active: _activeDoc == d,
                  onTap: () => setState(() => _activeDoc = d),
                  onClose: () => _closeDoc(d),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 「对话」tab 内容：运行事件区 + 输入框（保持原有体验）。
  Widget _buildConvPane(ProjectService proj) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFFFCFCFD),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFECECEE)),
            ),
            child: proj.events.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        '在下方输入开发需求（如「给用户模块加上邮箱验证码登录」），'
                        '回车发送。Agent 会先用 grep/glob 检索定位相关代码，再动手开发，'
                        '过程会实时显示在这里。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12.5, color: Color(0xFF8B8B93)),
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: AgentEventsView(
                        key: ValueKey(proj.activeConv?.id),
                        events: proj.events,
                        controller: _scroll,
                        onOpenFile: _openRel,
                        onResend:
                            proj.running ? null : (e) => _resend(proj, e)),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        _buildComposer(proj),
      ],
    );
  }

  /// 文件 tab 内容：内嵌文件查看器（md 预览/源码，其他高亮源码）。
  Widget _buildDocPane(String abs) {
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: FileContentView(key: ValueKey(abs), absPath: abs),
    );
  }

  /// 重发某条用户消息：开发会话重跑该指令；研究会话用原始输入重跑研究。
  Future<void> _resend(ProjectService proj, AgentEvent userEvent) async {
    final conv = proj.activeConv;
    if (conv == null) return;
    try {
      if (conv.kind == ConvKind.research) {
        await proj.resendResearch(conv);
      } else {
        await proj.develop(userEvent.text);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// 弹出研究方向对话框，确认后基于当前会话发起一次主题研究。
  Future<void> _startResearch(ProjectService proj) async {
    final idea = await showDialog<String>(
      context: context,
      builder: (_) => _ResearchDialog(proj: proj),
    );
    if (idea == null || idea.trim().isEmpty) return;
    try {
      // startResearch 内部异常已自行记录到会话；此处仅捕获前置守卫错误。
      await proj.startResearch(idea);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Widget _buildHeader(ProjectService proj, String path) {
    final name = path.split('\\').last;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 16, color: Color(0xFF0D9488)),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                Text(path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 10.5, color: Color(0xFF9B9B9F))),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _IndexChip(index: proj.index, onRescan: proj.rescanProject),
          if (proj.linkFor(path) != null) ...[
            const SizedBox(width: 8),
            _ResearchChip(
              title: proj.linkFor(path)!.researchTitle,
              onTap: () =>
                  widget.onOpenResearch?.call(proj.linkFor(path)!.researchPath),
            ),
          ],
          const Spacer(),
          if (proj.running)
            TextButton.icon(
              onPressed: proj.cancel,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: const Color(0xFFD9534F),
              ),
              icon: const Icon(Icons.stop_circle_outlined, size: 15),
              label: const Text('停止', style: TextStyle(fontSize: 12.5)),
            ),
          IconButton(
            tooltip: '基于当前会话开始主题研究',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.science_outlined, size: 16),
            color: const Color(0xFF7C3AED),
            onPressed:
                (proj.running || proj.activeConv == null || !proj.canResearch)
                    ? null
                    : () => _startResearch(proj),
          ),
          IconButton(
            tooltip: '在资源管理器中打开',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.open_in_new, size: 16),
            color: const Color(0xFF6B6B70),
            onPressed: () => launchUrl(Uri.file(path)),
          ),
          IconButton(
            tooltip: '切换 / 关闭项目',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.swap_horiz, size: 18),
            color: const Color(0xFF6B6B70),
            onPressed: proj.running ? null : proj.closeProject,
          ),
        ],
      ),
    );
  }

  Widget _buildLeftPanel(ProjectService proj) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 6, 6),
            child: Row(
              children: [
                _tabButton('会话', 0),
                const SizedBox(width: 4),
                _tabButton('文件', 1),
                const Spacer(),
                if (_leftTab == 0)
                  IconButton(
                    tooltip: '新会话',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.add, size: 18),
                    color: const Color(0xFF0D9488),
                    onPressed: proj.running ? null : proj.newConversation,
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFECECEE)),
          Expanded(
            child: _leftTab == 0
                ? _buildConvBody(proj)
                : _FileTreeView(root: proj.current!, onOpen: _openDoc),
          ),
        ],
      ),
    );
  }

  Widget _tabButton(String label, int tab) {
    final selected = _leftTab == tab;
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: () => setState(() => _leftTab = tab),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFEAF6F4) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? const Color(0xFF0D9488)
                    : const Color(0xFF6B6B70))),
      ),
    );
  }

  Widget _buildConvBody(ProjectService proj) {
    if (proj.conversations.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text('还没有会话\n点击右上角 + 新建',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Color(0xFFB0B0B6))),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      itemCount: proj.conversations.length,
      itemBuilder: (context, i) {
        final c = proj.conversations[i];
        final selected = proj.activeConv == c;
        return _ConvTile(
          title: c.title,
          time: _relTime(c.updatedAt),
          selected: selected,
          isResearch: c.kind == ConvKind.research,
          onTap: () => proj.openConversation(c),
          onDelete: proj.running && selected
              ? null
              : () => proj.deleteConversation(c),
        );
      },
    );
  }

  String _relTime(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    final hm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (diff <= 0) return hm;
    if (diff == 1) return '昨天 $hm';
    if (diff <= 7) return '$diff 天前';
    return '${t.month}-${t.day.toString().padLeft(2, '0')}';
  }

  Widget _buildComposer(ProjectService proj) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD9D9DE)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (event.logicalKey != LogicalKeyboardKey.enter &&
                    event.logicalKey != LogicalKeyboardKey.numpadEnter) {
                  return KeyEventResult.ignored;
                }
                final keys = HardwareKeyboard.instance.logicalKeysPressed;
                final newline = keys.contains(LogicalKeyboardKey.controlLeft) ||
                    keys.contains(LogicalKeyboardKey.controlRight) ||
                    keys.contains(LogicalKeyboardKey.shiftLeft) ||
                    keys.contains(LogicalKeyboardKey.shiftRight);
                if (newline) return KeyEventResult.ignored; // 交给输入框换行
                if (!proj.running) _send();
                return KeyEventResult.handled;
              },
              child: TextField(
                controller: _input,
                enabled: !proj.running,
                minLines: 1,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: proj.running
                      ? '开发进行中…'
                      : '描述要开发的功能或改动；回车发送，Ctrl/Shift+回车换行',
                  hintStyle: const TextStyle(
                      color: Color(0xFFA8A8AC), fontSize: 13.5),
                  isDense: true,
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: proj.running ? null : _send,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1A1A1A),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            child: proj.running
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.arrow_upward, size: 18),
          ),
        ],
      ),
    );
  }
}

/// 「基于当前会话开始主题研究」对话框：自动用模型给出研究方向建议（可编辑），
/// 确认后返回研究方向文本。
class _ResearchDialog extends StatefulWidget {
  const _ResearchDialog({required this.proj});

  final ProjectService proj;

  @override
  State<_ResearchDialog> createState() => _ResearchDialogState();
}

class _ResearchDialogState extends State<_ResearchDialog> {
  final _ctrl = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSuggestion();
  }

  Future<void> _loadSuggestion() async {
    final s = await widget.proj.suggestResearchTopic();
    if (!mounted) return;
    setState(() {
      if (s.isNotEmpty && _ctrl.text.trim().isEmpty) _ctrl.text = s;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('基于当前会话开始主题研究',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '研究将基于当前会话的需求与代码，围绕你的想法展开（新算法 / 新思路 / 方案）。'
              '研究会话会出现在左侧列表并标记「研究」，报告存入知识库。',
              style: TextStyle(fontSize: 12, color: Color(0xFF6B6B70)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              autofocus: true,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: _loading ? '正在根据会话生成研究方向建议…' : '你想研究的新算法 / 思路 / 方案',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF7C3AED)),
          child: const Text('开始研究'),
        ),
      ],
    );
  }
}

/// 主区域编辑器 tab（像 VSCode 的标签）：可激活、可关闭。
class _EditorTab extends StatelessWidget {
  const _EditorTab({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.onClose,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  /// 为 null 时不显示关闭按钮（如固定的「对话」tab）。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? Colors.white : const Color(0xFFF2F2F4),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.fromLTRB(10, 0, onClose != null ? 4 : 10, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: active
                    ? const Color(0xFFD7DBE0)
                    : const Color(0xFFECECEE)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 14,
                  color: active
                      ? const Color(0xFF0D9488)
                      : const Color(0xFF8A8A92)),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.w500,
                        color: active
                            ? const Color(0xFF2B2B2E)
                            : const Color(0xFF6B6B70))),
              ),
              if (onClose != null) ...[
                const SizedBox(width: 4),
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: onClose,
                  child: const Padding(
                    padding: EdgeInsets.all(3),
                    child:
                        Icon(Icons.close, size: 13, color: Color(0xFF9B9B9F)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 项目头部的「来源研究」标识：标明该项目源自哪份研究报告，点击可跳回查看。
class _ResearchChip extends StatelessWidget {
  const _ResearchChip({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '来源研究：$title（点击查看）',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF0D9488).withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.travel_explore,
                  size: 13, color: Color(0xFF0D9488)),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF0D9488),
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 工程文件小标签：显示扫描状态 / 代码文件数；点击可重新扫描。
class _IndexChip extends StatelessWidget {
  const _IndexChip({required this.index, required this.onRescan});

  final CodeIndexService index;
  final Future<void> Function() onRescan;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: index,
      builder: (context, _) {
        late final IconData icon;
        late final String label;
        late final Color color;
        VoidCallback? onTap = () => onRescan();
        if (index.scanning) {
          icon = Icons.autorenew;
          label = '扫描中…';
          color = const Color(0xFF0D9488);
          onTap = null;
        } else if (index.fileCount > 0) {
          icon = Icons.folder_copy_outlined;
          label = '${index.fileCount} 个文件';
          color = const Color(0xFF0D9488);
        } else {
          icon = Icons.refresh;
          label = '扫描工程';
          color = const Color(0xFF6B6B70);
        }
        return Tooltip(
          message: index.scanning ? '正在扫描工程文件…' : '点击重新扫描工程文件',
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (index.scanning)
                    SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.8, color: color),
                    )
                  else
                    Icon(icon, size: 13, color: color),
                  const SizedBox(width: 5),
                  Text(label,
                      style: TextStyle(
                          fontSize: 11, color: color, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 懒加载文件树：展开目录时才列出其子项，点击文件用查看器打开。
class _FileTreeView extends StatefulWidget {
  const _FileTreeView({required this.root, required this.onOpen});

  final String root;
  final void Function(String absPath) onOpen;

  @override
  State<_FileTreeView> createState() => _FileTreeViewState();
}

class _FileTreeViewState extends State<_FileTreeView> {
  static const _ignore = {
    '.git', '.hg', '.svn', 'node_modules', 'build', 'dist', 'out', 'target',
    '.dart_tool', '.idea', '.vscode', '.gradle', 'bin', 'obj', 'Pods',
    '.next', '.nuxt', 'coverage', 'venv', '.venv', '__pycache__', '.pub-cache',
  };

  final Set<String> _expanded = {};

  List<FileSystemEntity> _children(String dir) {
    try {
      final list = Directory(dir).listSync(followLinks: false);
      list.sort((a, b) {
        final ad = a is Directory ? 0 : 1;
        final bd = b is Directory ? 0 : 1;
        if (ad != bd) return ad - bd;
        return p.basename(a.path).toLowerCase().compareTo(
            p.basename(b.path).toLowerCase());
      });
      return [
        for (final e in list)
          if (!(e is Directory && _ignore.contains(p.basename(e.path))) &&
              !p.basename(e.path).startsWith('.git'))
            e,
      ];
    } catch (_) {
      return const [];
    }
  }

  void _build(List<Widget> out, String dir, int depth) {
    for (final e in _children(dir)) {
      final name = p.basename(e.path);
      final isDir = e is Directory;
      final open = _expanded.contains(e.path);
      out.add(
        InkWell(
          onTap: () {
            if (isDir) {
              setState(() {
                if (open) {
                  _expanded.remove(e.path);
                } else {
                  _expanded.add(e.path);
                }
              });
            } else {
              widget.onOpen(e.path);
            }
          },
          child: Padding(
            padding: EdgeInsets.fromLTRB(8.0 + depth * 12, 4, 8, 4),
            child: Row(
              children: [
                Icon(
                    isDir
                        ? (open
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right)
                        : Icons.insert_drive_file_outlined,
                    size: 15,
                    color: isDir
                        ? const Color(0xFF8A8A92)
                        : const Color(0xFFB0B0B6)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color: const Color(0xFF374151),
                          fontWeight:
                              isDir ? FontWeight.w500 : FontWeight.w400)),
                ),
              ],
            ),
          ),
        ),
      );
      if (isDir && open) _build(out, e.path, depth + 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    _build(rows, widget.root, 0);
    if (rows.isEmpty) {
      return const Center(
        child: Text('（空目录）',
            style: TextStyle(fontSize: 12, color: Color(0xFFB0B0B6))),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: rows,
    );
  }
}

class _ConvTile extends StatelessWidget {
  const _ConvTile({
    required this.title,
    required this.time,
    required this.selected,
    required this.onTap,
    required this.onDelete,
    this.isResearch = false,
  });

  final String title;
  final String time;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  /// 是否为「研究」类型会话（显示研究标签）。
  final bool isResearch;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? const Color(0xFFEAF6F4) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (isResearch) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: const Color(0xFF7C3AED)
                                    .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('研究',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: Color(0xFF7C3AED),
                                      fontWeight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 5),
                          ],
                          Expanded(
                            child: Text(title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: const Color(0xFF2B2B2E))),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(time,
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFFA0A0A5))),
                    ],
                  ),
                ),
                if (onDelete != null)
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: onDelete,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close,
                          size: 14, color: Color(0xFFB0B0B6)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.name,
    required this.path,
    required this.onOpen,
    required this.onReveal,
    required this.onRemove,
  });

  final String name;
  final String path;
  final VoidCallback onOpen;
  final VoidCallback onReveal;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFAFAFB),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFECECEE)),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_outlined,
                  size: 18, color: Color(0xFF6B6B70)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                    Text(path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5, color: Color(0xFF9B9B9F))),
                  ],
                ),
              ),
              IconButton(
                tooltip: '在资源管理器中打开',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.open_in_new,
                    size: 16, color: Color(0xFF9B9B9F)),
                onPressed: onReveal,
              ),
              IconButton(
                tooltip: '从列表移除',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close,
                    size: 16, color: Color(0xFF9B9B9F)),
                onPressed: onRemove,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
