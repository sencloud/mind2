import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../models.dart';
import '../services/agent/memory/memory_service.dart';
import '../services/book_service.dart';
import '../services/chat_service.dart';
import '../services/document_service.dart';
import '../services/experiment_service.dart';
import '../services/file_library_service.dart';
import '../services/library_service.dart';
import '../services/mind_map_service.dart';
import '../services/paper_service.dart';
import '../services/plan_service.dart';
import '../services/playwright_service.dart';
import '../services/pro_book_service.dart';
import '../services/project_doc_service.dart';
import '../services/project_service.dart';
import '../services/promo_service.dart';
import '../services/settings_service.dart';
import '../services/topic_service.dart';
import '../services/zotero_service.dart';
import 'chat_page.dart';
import 'knowledge_page.dart';
import 'library_page.dart';
import 'plan_page.dart';
import 'project_page.dart';
import 'settings_page.dart';
import 'topic_page.dart';
import 'writing_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.settings,
    required this.memory,
    required this.library,
    required this.fileLibrary,
    required this.chat,
    required this.topicService,
    required this.zotero,
    required this.playwright,
    required this.experiment,
    required this.project,
    required this.projectDoc,
    required this.document,
    required this.proBook,
    required this.mindMap,
    required this.book,
    required this.paper,
    required this.promo,
    required this.plan,
  });

  final SettingsService settings;
  final MemoryService memory;
  final LibraryService library;
  final FileLibraryService fileLibrary;
  final ChatService chat;
  final TopicFetchService topicService;
  final ZoteroService zotero;
  final PlaywrightService playwright;
  final ExperimentService experiment;
  final ProjectService project;
  final ProjectDocService projectDoc;
  final DocumentService document;
  final ProBookService proBook;
  final MindMapService mindMap;
  final BookService book;
  final PaperService paper;
  final PromoService promo;
  final PlanService plan;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  StandardNote? _noteToOpen;
  int _libToken = 0;
  int _writingTab = 0; // 0=文档 1=专业书籍 2=小说 3=论文
  int _writingToken = 0;
  bool _sidebarCollapsed = false;

  @override
  void initState() {
    super.initState();
    // 研究完成后自动跳转到知识库查看报告。
    widget.topicService.onResearchComplete = (path) {
      if (!mounted) return;
      final matches = widget.library.notes.where((n) => n.filePath == path);
      if (matches.isNotEmpty) _openNote(matches.first);
    };
  }

  void _openNote(StandardNote note) {
    setState(() {
      _index = 2;
      _noteToOpen = note;
      _libToken++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      ChatPage(
        chat: widget.chat,
        library: widget.library,
        settings: widget.settings,
      ),
      KnowledgePage(
        library: widget.library,
        settings: widget.settings,
        topicService: widget.topicService,
        memory: widget.memory,
        onOpenNote: _openNote,
        onOpenTopic: () => setState(() => _index = 3),
      ),
      LibraryPage(
        key: ValueKey('lib$_libToken'),
        library: widget.library,
        fileLibrary: widget.fileLibrary,
        experiment: widget.experiment,
        initialNote: _noteToOpen,
        onContinueResearch: (topic, clarification) {
          setState(() => _index = 3);
          widget.topicService.run(topic, clarification: clarification);
        },
        onConvertResearchToPaper: (note, format) {
          final draft = widget.paper.createFromResearch(note, format);
          setState(() {
            _index = 6;
            _writingTab = 3; // 论文 tab（文档/专业书籍/小说/论文）
            _writingToken++;
          });
          Future.microtask(() => widget.paper.writeDraft(PaperLang.both, draft));
        },
        onOpenAsProject: (projectPath, researchPath, researchTitle) {
          widget.project.openFromExperiment(
            projectPath: projectPath,
            researchPath: researchPath,
            researchTitle: researchTitle,
          );
          setState(() => _index = 5);
        },
      ),
      TopicPage(
        topicService: widget.topicService,
        library: widget.library,
        project: widget.project,
        onOpenReport: (path) {
          final matches = widget.library.notes.where((n) => n.filePath == path);
          if (matches.isNotEmpty) _openNote(matches.first);
        },
        onOpenNote: _openNote,
      ),
      SettingsPage(
        settings: widget.settings,
        library: widget.library,
        zotero: widget.zotero,
        playwright: widget.playwright,
      ),
      ProjectPage(
        project: widget.project,
        projectDoc: widget.projectDoc,
        onOpenResearch: (notePath) {
          final matches = widget.library.notes.where(
            (n) => n.filePath == notePath,
          );
          if (matches.isNotEmpty) _openNote(matches.first);
        },
      ),
      WritingPage(
        key: ValueKey('writing$_writingToken'),
        document: widget.document,
        proBook: widget.proBook,
        mindMap: widget.mindMap,
        book: widget.book,
        paper: widget.paper,
        promo: widget.promo,
        initialTab: _writingTab,
      ),
      PlanPage(plan: widget.plan),
    ];

    return Scaffold(
      body: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSidebar(),
              // 顶部留出窗口拖动区的高度，避免内容顶到边
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 32),
                  child: pages[_index],
                ),
              ),
            ],
          ),
          // 顶部可拖动区域（右侧留出窗口按钮的位置）
          const Positioned(
            left: 0,
            top: 0,
            right: 138,
            height: 26,
            child: _DragArea(),
          ),
          const Positioned(right: 0, top: 0, child: _WindowButtons()),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    final collapsed = _sidebarCollapsed;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: collapsed ? 72 : 240,
      color: const Color(0xFFF7F7F8),
      // 按动画中的实际宽度决定是否显示文字，避免目标状态已切换、宽度尚未到位时 Row 溢出。
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 160;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DragArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 22 : 20,
                    20,
                    compact ? 22 : 20,
                    12,
                  ),
                  child: Row(
                    mainAxisAlignment: compact
                        ? MainAxisAlignment.center
                        : MainAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.asset(
                          'assets/icon/app_icon.png',
                          width: 28,
                          height: 28,
                          fit: BoxFit.cover,
                        ),
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 10),
                        const Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '第二大脑',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(height: 1),
                              Text(
                                '自进化智能体',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: Color(0xFF9B9B9F),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              _NavItem(
                icon: Icons.edit_square,
                label: '新对话',
                selected: _index == 0 && widget.chat.current == null,
                collapsed: compact,
                onTap: () {
                  widget.chat.newSession();
                  setState(() => _index = 0);
                },
              ),
              _NavItem(
                icon: Icons.travel_explore_outlined,
                label: '主题研究',
                selected: _index == 3,
                collapsed: compact,
                onTap: () => setState(() => _index = 3),
              ),
              _NavItem(
                icon: Icons.checklist_rtl,
                label: '计划',
                selected: _index == 7,
                collapsed: compact,
                onTap: () => setState(() => _index = 7),
              ),
              _NavItem(
                icon: Icons.auto_stories_outlined,
                label: '写作',
                selected: _index == 6,
                collapsed: compact,
                onTap: () => setState(() => _index = 6),
              ),
              _NavItem(
                icon: Icons.code,
                label: '项目',
                selected: _index == 5,
                collapsed: compact,
                onTap: () => setState(() => _index = 5),
              ),
              _NavItem(
                icon: Icons.menu_book_outlined,
                label: '知识库',
                selected: _index == 2,
                collapsed: compact,
                onTap: () => setState(() => _index = 2),
              ),
              _NavItem(
                icon: Icons.hub_outlined,
                label: '知识体系',
                selected: _index == 1,
                collapsed: compact,
                onTap: () => setState(() => _index = 1),
              ),
              if (!compact) ...[
                const SizedBox(height: 18),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
                  child: Text(
                    '对话',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF6B6B70),
                    ),
                  ),
                ),
                Expanded(child: _buildChatList()),
              ] else
                const Spacer(),
              _buildSettingsRow(collapsed, compact: compact),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSettingsRow(bool collapsed, {required bool compact}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Row(
        children: [
          Expanded(
            child: _NavItem(
              icon: Icons.settings_outlined,
              label: '设置',
              selected: _index == 4,
              collapsed: compact,
              outerPadding: EdgeInsets.zero,
              onTap: () => setState(() => _index = 4),
            ),
          ),
          if (!compact) const SizedBox(width: 4),
          Tooltip(
            message: collapsed ? '展开侧边栏' : '收起侧边栏',
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _sidebarCollapsed = !collapsed),
                child: SizedBox(
                  width: compact ? 34 : 32,
                  height: 34,
                  child: Icon(
                    collapsed ? Icons.chevron_right : Icons.chevron_left,
                    size: 20,
                    color: const Color(0xFF6B6B70),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatList() {
    return ListenableBuilder(
      listenable: widget.chat,
      builder: (context, _) {
        final sessions = [...widget.chat.sessions]
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        if (sessions.isEmpty) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              '暂无聊天',
              style: TextStyle(fontSize: 13, color: Color(0xFFB9B9BD)),
            ),
          );
        }
        return _buildGroupedList(
          items: sessions,
          dateOf: (s) => s.createdAt,
          itemBuilder: (s) => _SessionItem(
            title: s.title.isEmpty ? '(空对话)' : s.title,
            selected: _index == 0 && widget.chat.current == s,
            onTap: () {
              widget.chat.openSession(s);
              setState(() => _index = 0);
            },
            onDelete: () => widget.chat.deleteSession(s),
          ),
        );
      },
    );
  }

  /// 按时间分组（今天 / 昨天 / 7 天内 / 30 天内 / 更早）渲染历史列表。
  /// [items] 需已按时间倒序排列。
  Widget _buildGroupedList<T>({
    required List<T> items,
    required DateTime Function(T) dateOf,
    required Widget Function(T) itemBuilder,
  }) {
    final rows = <Widget>[];
    String? lastLabel;
    for (final it in items) {
      final label = _timeGroupLabel(dateOf(it));
      if (label != lastLabel) {
        rows.add(_GroupHeader(label));
        lastLabel = label;
      }
      rows.add(itemBuilder(it));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      children: rows,
    );
  }

  /// 根据创建时间返回所属的时间分组标签。
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
}

/// 历史列表里的时间分组小标题。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Color(0xFFA0A0A5),
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// 可拖动窗口的区域，双击切换最大化。
class _DragArea extends StatelessWidget {
  const _DragArea({this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: () async {
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      },
      child: child ?? const SizedBox.expand(),
    );
  }
}

class _WindowButtons extends StatefulWidget {
  const _WindowButtons();

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButton(
          icon: Icons.horizontal_rule,
          onTap: () => windowManager.minimize(),
        ),
        _CaptionButton(
          icon: _maximized ? Icons.filter_none : Icons.crop_square,
          iconSize: _maximized ? 12 : 14,
          onTap: () async {
            _maximized
                ? await windowManager.unmaximize()
                : await windowManager.maximize();
          },
        ),
        _CaptionButton(
          icon: Icons.close,
          isClose: true,
          onTap: () => windowManager.close(),
        ),
      ],
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.onTap,
    this.iconSize = 15,
    this.isClose = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double iconSize;
  final bool isClose;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: 44,
          height: 30,
          color: _hover
              ? (widget.isClose
                    ? const Color(0xFFE81123)
                    : const Color(0xFFE9E9EB))
              : Colors.transparent,
          child: Icon(
            widget.icon,
            size: widget.iconSize,
            color: _hover && widget.isClose
                ? Colors.white
                : const Color(0xFF49494D),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.collapsed = false,
    this.outerPadding = const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool collapsed;
  final EdgeInsetsGeometry outerPadding;

  @override
  Widget build(BuildContext context) {
    final content = Material(
      color: selected ? const Color(0xFFECECEE) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: collapsed ? 0 : 12,
            vertical: 8,
          ),
          child: Row(
            mainAxisAlignment: collapsed
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: const Color(0xFF49494D)),
              if (!collapsed) ...[
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: Color(0xFF2B2B2E),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: outerPadding,
      child: Material(
        color: Colors.transparent,
        child: collapsed ? Tooltip(message: label, child: content) : content,
      ),
    );
  }
}

class _SessionItem extends StatefulWidget {
  const _SessionItem({
    required this.title,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  State<_SessionItem> createState() => _SessionItemState();
}

class _SessionItemState extends State<_SessionItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: widget.selected ? const Color(0xFFECECEE) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF49494D),
                    ),
                  ),
                ),
                if (_hover)
                  GestureDetector(
                    onTap: widget.onDelete,
                    child: const Icon(
                      Icons.close,
                      size: 14,
                      color: Color(0xFF9B9B9F),
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
