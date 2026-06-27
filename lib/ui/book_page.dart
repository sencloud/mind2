import 'package:flutter/material.dart';

import '../services/book_service.dart';

const _accent = Color(0xFF0D9488);
const _ink = Color(0xFF2B2B2E);
const _sub = Color(0xFF6B6B70);
const _muted = Color(0xFF9B9B9F);
const _inspireGenreOptions = [
  '玄幻',
  '奇幻',
  '科幻',
  '虚拟现实',
  '悬疑',
  '推理',
  '都市',
  '言情',
  '历史',
  '武侠',
  '仙侠',
  '游戏',
  '末世',
  '现实 / 生存',
  '非虚构',
];

class BookPage extends StatefulWidget {
  const BookPage({super.key, required this.book});

  final BookService book;

  @override
  State<BookPage> createState() => _BookPageState();
}

class _BookPageState extends State<BookPage> {
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
      listenable: widget.book,
      builder: (context, _) {
        final svc = widget.book;
        return svc.current == null ? _buildShelf(svc) : _buildWorkspace(svc);
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 书架
  // ---------------------------------------------------------------------------

  Widget _buildShelf(BookService svc) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '写作',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => _newBook(svc),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1A1A1A),
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新建书籍'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '像专业作者一样写长篇：先立项（题材/读者/文风/核心创意），再由 AI 生成故事设定集与章节大纲，'
            '然后逐章成文（自动携带设定与上一章上下文保证连贯），最后润色并导出。',
            style: TextStyle(fontSize: 13, color: _sub),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: svc.books.isEmpty
                ? const Center(
                    child: Text(
                      '还没有书籍，点击右上角「新建书籍」开始创作',
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
                    itemCount: svc.books.length,
                    itemBuilder: (context, i) => _bookCard(svc, svc.books[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _bookCard(BookService svc, Book book) {
    return Material(
      color: const Color(0xFFF7F7F8),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => svc.openBook(book),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.auto_stories_outlined,
                    size: 18,
                    color: _accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _CardMenu(onDelete: () => _confirmDelete(svc, book)),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  book.logline.isNotEmpty
                      ? book.logline
                      : (book.premise.isNotEmpty ? book.premise : '（暂无简介）'),
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
                  if (book.genre.isNotEmpty) _chip(book.genre),
                  const Spacer(),
                  Text(
                    '${book.doneChapters}/${book.chapters.length} 章 · ${book.totalWords} 字',
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

  Future<void> _confirmDelete(BookService svc, Book book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定删除《${book.title}》吗？此操作不可恢复。'),
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
    if (ok == true) await svc.deleteBook(book);
  }

  Future<void> _newBook(BookService svc) async {
    final title = TextEditingController();
    final genre = TextEditingController();
    final audience = TextEditingController();
    final style = TextEditingController();
    final premise = TextEditingController();
    final chapters = TextEditingController(text: '12');
    final words = TextEditingController(text: '2000');

    var inspiring = false;
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> roll() async {
            if (inspiring) return;
            final selectedGenre = await _chooseInspireGenre(genre.text);
            if (selectedGenre == null) return;
            genre.text = selectedGenre;
            setLocal(() => inspiring = true);
            try {
              final m = await svc.inspire(genre: selectedGenre);
              if (m != null) {
                title.text = (m['title'] ?? title.text).toString();
                genre.text = (m['genre'] ?? genre.text).toString();
                audience.text = (m['audience'] ?? audience.text).toString();
                style.text = (m['style'] ?? style.text).toString();
                premise.text = (m['premise'] ?? premise.text).toString();
                final c = (m['targetChapters'] as num?)?.toInt();
                final w = (m['targetWordsPerChapter'] as num?)?.toInt();
                if (c != null && c > 0) chapters.text = '$c';
                if (w != null && w > 0) words.text = '$w';
              } else {
                _toast('灵感生成失败，请重试');
              }
            } catch (e) {
              _toast('灵感生成失败：$e');
            } finally {
              setLocal(() => inspiring = false);
            }
          }

          return AlertDialog(
            title: const Text('新建书籍'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _field(title, '书名 *', '例如：群星彼岸'),
                    _field(genre, '类型 / 题材', '科幻 / 玄幻 / 悬疑 / 言情 / 历史 / 非虚构…'),
                    _field(audience, '目标读者', '例如：喜欢硬核设定的成年读者'),
                    _field(style, '文风 / 基调', '例如：冷峻克制、画面感强'),
                    _field(premise, '核心创意 / 立意', '一句话说清这本书最想讲什么', maxLines: 3),
                    Row(
                      children: [
                        Expanded(
                          child: _field(chapters, '计划章数', '12', number: true),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _field(words, '每章目标字数', '2000', number: true),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              IconButton(
                tooltip: 'AI 帮我设计选题（自动填充）',
                onPressed: inspiring ? null : roll,
                icon: inspiring
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.casino_outlined),
                color: _accent,
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: inspiring
                    ? null
                    : () {
                        if (title.text.trim().isEmpty) return;
                        Navigator.pop(ctx, true);
                      },
                child: const Text('创建'),
              ),
            ],
          );
        },
      ),
    );

    if (created == true) {
      svc.createBook(
        title: title.text,
        genre: genre.text,
        audience: audience.text,
        style: style.text,
        premise: premise.text,
        targetChapters: int.tryParse(chapters.text.trim()) ?? 12,
        targetWordsPerChapter: int.tryParse(words.text.trim()) ?? 2000,
      );
    }
  }

  Future<String?> _chooseInspireGenre(String currentGenre) async {
    final trimmed = currentGenre.trim();
    final custom = TextEditingController(
      text: trimmed.isNotEmpty && !_inspireGenreOptions.contains(trimmed)
          ? trimmed
          : '',
    );
    String? selected = _inspireGenreOptions.contains(trimmed) ? trimmed : null;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('选择随机题材'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'AI 会按你选择的题材随机设计书名、读者、风格和核心创意。',
                  style: TextStyle(fontSize: 12.5, color: _sub),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in _inspireGenreOptions)
                      ChoiceChip(
                        label: Text(option),
                        selected: selected == option && custom.text.isEmpty,
                        onSelected: (_) {
                          custom.clear();
                          setDialogState(() => selected = option);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: custom,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(
                    labelText: '其他题材',
                    hintText: '例如：科幻 / 虚拟现实 / 生存',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _accent),
              onPressed: custom.text.trim().isEmpty && selected == null
                  ? null
                  : () {
                      final customGenre = custom.text.trim();
                      Navigator.pop(
                        ctx,
                        customGenre.isNotEmpty ? customGenre : selected,
                      );
                    },
              child: const Text('开始随机'),
            ),
          ],
        ),
      ),
    );
    custom.dispose();
    return result;
  }

  Widget _field(
    TextEditingController c,
    String label,
    String hint, {
    int maxLines = 1,
    bool number = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: _ink,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: c,
            maxLines: maxLines,
            keyboardType: number ? TextInputType.number : null,
            style: const TextStyle(fontSize: 13.5, height: 1.4),
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 工作区
  // ---------------------------------------------------------------------------

  Widget _buildWorkspace(BookService svc) {
    final book = svc.current!;
    return Column(
      children: [
        _topBar(svc, book),
        if (svc.busy || svc.stage.isNotEmpty) _statusStrip(svc),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _leftPanel(svc, book),
              const VerticalDivider(width: 1),
              Expanded(
                child: svc.activeChapter == null
                    ? _BibleEditor(svc: svc, book: book)
                    : _ChapterEditor(
                        key: ValueKey(svc.activeChapter!.id),
                        svc: svc,
                        chapter: svc.activeChapter!,
                        content: svc.activeChapter!.content,
                        busy: svc.busy,
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _topBar(BookService svc, Book book) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回书架',
            onPressed: svc.busy ? null : svc.closeBook,
            icon: const Icon(Icons.arrow_back, size: 18),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${book.genre.isEmpty ? '未分类' : book.genre} · '
                  '${book.doneChapters}/${book.chapters.length} 章 · 约 ${book.totalWords} 字',
                  style: const TextStyle(fontSize: 11.5, color: _muted),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: svc.busy ? null : () => _writeAll(svc),
            style: FilledButton.styleFrom(backgroundColor: _accent),
            icon: const Icon(Icons.auto_stories, size: 15),
            label: const Text('写完全本'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: svc.busy ? null : () => _export(svc),
            icon: const Icon(Icons.ios_share, size: 15),
            label: const Text('导出'),
          ),
        ],
      ),
    );
  }

  Future<void> _writeAll(BookService svc) async {
    final book = svc.current!;
    final pending = book.chapters.where((c) => !c.hasContent).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('一键写完全本'),
        content: Text(
          book.chapters.isEmpty
              ? '将先生成设定集与章节大纲，再依次写完每一章。整本长篇耗时较长，期间可随时点「停止」，已写内容会自动保存。是否开始？'
              : '将依次为剩余 $pending 个未完成章节生成正文（已写章节自动跳过）。'
                    '整本长篇耗时较长，期间可随时点「停止」，每章写完即自动保存。是否开始？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _accent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始'),
          ),
        ],
      ),
    );
    if (ok == true) await svc.writeWholeBook();
  }

  Widget _statusStrip(BookService svc) {
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

  Widget _leftPanel(BookService svc, Book book) {
    return SizedBox(
      width: 270,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: _navTile(
              icon: Icons.menu_book_outlined,
              label: '故事设定集',
              selected: svc.activeChapter == null,
              onTap: () => svc.openChapter(null),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                const Text(
                  '章节',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _muted,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '生成 / 重排大纲',
                  visualDensity: VisualDensity.compact,
                  onPressed: svc.busy ? null : svc.generateOutline,
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  color: _accent,
                ),
              ],
            ),
          ),
          Expanded(
            child: book.chapters.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Text(
                          '还没有章节大纲',
                          style: TextStyle(fontSize: 12.5, color: _muted),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.tonalIcon(
                          onPressed: svc.busy ? null : svc.generateOutline,
                          icon: const Icon(Icons.auto_awesome, size: 15),
                          label: const Text('生成章节大纲'),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: book.chapters.length,
                    itemBuilder: (context, i) =>
                        _chapterTile(svc, book.chapters[i], i),
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

  Widget _chapterTile(BookService svc, BookChapter ch, int i) {
    final selected = svc.activeChapter == ch;
    return Material(
      color: selected ? const Color(0xFFECECEE) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => svc.openChapter(ch),
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
                  color: ch.hasContent ? _accent : const Color(0xFFD3D3D7),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '第${i + 1}章 ${ch.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: _ink),
                    ),
                    if (ch.summary.isNotEmpty)
                      Text(
                        ch.summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: _muted),
                      ),
                  ],
                ),
              ),
              if (ch.hasContent)
                Text(
                  '${ch.words}',
                  style: const TextStyle(fontSize: 10.5, color: _muted),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _export(BookService svc) async {
    try {
      final path = await svc.export();
      _toast('已导出到：$path');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }
}

class _CardMenu extends StatelessWidget {
  const _CardMenu({required this.onDelete});

  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: const Icon(Icons.more_horiz, size: 18, color: _muted),
      padding: EdgeInsets.zero,
      onSelected: (v) {
        if (v == 'delete') onDelete();
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// 设定集编辑器（焦点感知：用户编辑中不被外部刷新覆盖，AI 生成后自动回填）
// -----------------------------------------------------------------------------

class _BibleEditor extends StatefulWidget {
  const _BibleEditor({required this.svc, required this.book});

  final BookService svc;
  final Book book;

  @override
  State<_BibleEditor> createState() => _BibleEditorState();
}

class _BibleEditorState extends State<_BibleEditor> {
  final _logline = TextEditingController();
  final _synopsis = TextEditingController();
  final _worldview = TextEditingController();
  final _loglineFocus = FocusNode();
  final _synopsisFocus = FocusNode();
  final _worldviewFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _seed();
  }

  void _seed() {
    _logline.text = widget.book.logline;
    _synopsis.text = widget.book.synopsis;
    _worldview.text = widget.book.worldview;
  }

  @override
  void didUpdateWidget(covariant _BibleEditor old) {
    super.didUpdateWidget(old);
    if (old.book.id != widget.book.id) {
      _seed();
      return;
    }
    // 外部（AI 生成）更新且该字段未在编辑时，回填最新内容。
    if (!_loglineFocus.hasFocus && _logline.text != widget.book.logline) {
      _logline.text = widget.book.logline;
    }
    if (!_synopsisFocus.hasFocus && _synopsis.text != widget.book.synopsis) {
      _synopsis.text = widget.book.synopsis;
    }
    if (!_worldviewFocus.hasFocus && _worldview.text != widget.book.worldview) {
      _worldview.text = widget.book.worldview;
    }
  }

  @override
  void dispose() {
    _logline.dispose();
    _synopsis.dispose();
    _worldview.dispose();
    _loglineFocus.dispose();
    _synopsisFocus.dispose();
    _worldviewFocus.dispose();
    super.dispose();
  }

  void _flush() {
    widget.book.logline = _logline.text.trim();
    widget.book.synopsis = _synopsis.text;
    widget.book.worldview = _worldview.text;
    widget.svc.saveBible();
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final busy = widget.svc.busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '故事设定集',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'AI 生成的"故事圣经"——后续每章成文都会自动参考它，保证设定一致。',
                  style: TextStyle(fontSize: 11.5, color: _muted),
                ),
              ),
              FilledButton.icon(
                onPressed: busy ? null : widget.svc.generateBible,
                style: FilledButton.styleFrom(backgroundColor: _accent),
                icon: const Icon(Icons.auto_awesome, size: 15),
                label: Text(book.hasBible ? '重新生成' : '生成设定集'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              children: [
                _label('一句话梗概（Logline）'),
                _box(_logline, _loglineFocus, '一句话讲清核心冲突与卖点', maxLines: 2),
                _label('故事大纲（Synopsis）'),
                _box(_synopsis, _synopsisFocus, '主线、核心冲突、转折与结局走向', maxLines: 8),
                _label('世界观 / 设定'),
                _box(_worldview, _worldviewFocus, '时代背景、规则、关键设定', maxLines: 6),
                const SizedBox(height: 8),
                _label('主要人物'),
                if (book.characters.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '点击「生成设定集」由 AI 设计人物，或先填写梗概再生成。',
                      style: TextStyle(fontSize: 12.5, color: _muted),
                    ),
                  )
                else
                  ...book.characters.map(_characterCard),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: _ink,
      ),
    ),
  );

  Widget _box(
    TextEditingController c,
    FocusNode f,
    String hint, {
    int maxLines = 3,
  }) {
    return TextField(
      controller: c,
      focusNode: f,
      minLines: 1,
      maxLines: maxLines,
      onTapOutside: (_) {
        f.unfocus();
        _flush();
      },
      onEditingComplete: _flush,
      style: const TextStyle(fontSize: 13.5, height: 1.6),
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _characterCard(BookCharacter c) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.person_outline, size: 15, color: _accent),
              const SizedBox(width: 6),
              Text(
                c.name,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (c.role.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  c.role,
                  style: const TextStyle(fontSize: 11.5, color: _accent),
                ),
              ],
            ],
          ),
          if (c.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              c.description,
              style: const TextStyle(fontSize: 12.5, height: 1.5, color: _sub),
            ),
          ],
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 章节编辑器
// -----------------------------------------------------------------------------

class _ChapterEditor extends StatefulWidget {
  const _ChapterEditor({
    super.key,
    required this.svc,
    required this.chapter,
    required this.content,
    required this.busy,
  });

  final BookService svc;
  final BookChapter chapter;

  /// 显式传入正文用于变更检测（流式生成会持续更新它）。
  final String content;
  final bool busy;

  @override
  State<_ChapterEditor> createState() => _ChapterEditorState();
}

class _ChapterEditorState extends State<_ChapterEditor> {
  late final TextEditingController _title = TextEditingController(
    text: widget.chapter.title,
  );
  late final TextEditingController _content = TextEditingController(
    text: widget.chapter.content,
  );
  final _contentFocus = FocusNode();

  @override
  void didUpdateWidget(covariant _ChapterEditor old) {
    super.didUpdateWidget(old);
    // 流式生成中持续把最新正文同步进编辑框，并把光标移到末尾。
    if (widget.content != old.content && _content.text != widget.content) {
      if (widget.busy || !_contentFocus.hasFocus) {
        _content.value = TextEditingValue(
          text: widget.content,
          selection: TextSelection.collapsed(offset: widget.content.length),
        );
      }
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _contentFocus.dispose();
    super.dispose();
  }

  void _save() {
    widget.chapter.title = _title.text.trim().isEmpty
        ? widget.chapter.title
        : _title.text.trim();
    widget.chapter.content = _content.text;
    widget.svc.saveChapter();
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.svc;
    final ch = widget.chapter;
    final busy = widget.busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 18, 28, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _title,
            onTapOutside: (_) => _save(),
            onEditingComplete: _save,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: '章节标题',
            ),
          ),
          if (ch.summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(
                '概要：${ch.summary}',
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: _muted,
                ),
              ),
            ),
          const SizedBox(height: 8),
          _toolbar(svc, ch, busy),
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              controller: _content,
              focusNode: _contentFocus,
              readOnly: busy,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              onTapOutside: (_) => _save(),
              style: const TextStyle(fontSize: 14.5, height: 1.9),
              decoration: const InputDecoration(
                hintText: '本章正文将显示在这里。点击「生成本章」由 AI 起草，或直接手动撰写。',
                border: InputBorder.none,
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${ch.words} 字',
              style: const TextStyle(fontSize: 11.5, color: _muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(BookService svc, BookChapter ch, bool busy) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: busy ? null : () => svc.writeChapter(ch),
          style: FilledButton.styleFrom(backgroundColor: _accent),
          icon: const Icon(Icons.auto_awesome, size: 15),
          label: Text(ch.hasContent ? '重写本章' : '生成本章'),
        ),
        OutlinedButton.icon(
          onPressed: busy || !ch.hasContent
              ? null
              : () => svc.continueChapter(ch),
          icon: const Icon(Icons.subdirectory_arrow_right, size: 15),
          label: const Text('续写'),
        ),
        OutlinedButton.icon(
          onPressed: busy || !ch.hasContent
              ? null
              : () => svc.polishChapter(ch),
          icon: const Icon(Icons.auto_fix_high, size: 15),
          label: const Text('润色'),
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : _save,
          icon: const Icon(Icons.save_outlined, size: 15),
          label: const Text('保存'),
        ),
      ],
    );
  }
}
