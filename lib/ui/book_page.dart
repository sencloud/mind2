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

class _QuestionDraft {
  _QuestionDraft(this.questions)
    : customInputs = [
        for (var i = 0; i < questions.length; i++) TextEditingController(),
      ];

  final List<BookDiscussionQuestion> questions;
  final List<TextEditingController> customInputs;
  final Map<int, Set<int>> selected = {};

  void dispose() {
    for (final controller in customInputs) {
      controller.dispose();
    }
  }

  bool get hasAnswers {
    for (var i = 0; i < questions.length; i++) {
      if ((selected[i] ?? const <int>{}).isNotEmpty) return true;
      if (customInputs[i].text.trim().isNotEmpty) return true;
    }
    return false;
  }

  String composeAnswer({String prefix = ''}) {
    final buf = StringBuffer();
    if (prefix.trim().isNotEmpty) {
      buf
        ..writeln('补充说明：')
        ..writeln(prefix.trim())
        ..writeln();
    }
    for (var i = 0; i < questions.length; i++) {
      final question = questions[i];
      final choices = <String>[
        for (final optionIndex in (selected[i] ?? const <int>{}))
          if (optionIndex >= 0 && optionIndex < question.options.length)
            question.options[optionIndex],
      ];
      final custom = customInputs[i].text.trim();
      if (choices.isEmpty && custom.isEmpty) continue;
      buf.writeln('${i + 1}. ${question.prompt}');
      for (final choice in choices) {
        buf.writeln('- $choice');
      }
      if (custom.isNotEmpty) buf.writeln('- 其他：$custom');
      buf.writeln();
    }
    return buf.toString().trim();
  }
}

Widget _questionChoiceList(_QuestionDraft draft, VoidCallback onChanged) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < draft.questions.length; i++)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFECECEE)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${i + 1}. ${draft.questions[i].prompt}',
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: _ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              for (var j = 0; j < draft.questions[i].options.length; j++)
                CheckboxListTile(
                  value: draft.selected[i]?.contains(j) ?? false,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    draft.questions[i].options[j],
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.35,
                      color: _ink,
                    ),
                  ),
                  onChanged: (checked) {
                    final set = draft.selected.putIfAbsent(i, () => <int>{});
                    if (checked == true) {
                      set.add(j);
                    } else {
                      set.remove(j);
                    }
                    onChanged();
                  },
                ),
              const SizedBox(height: 6),
              TextField(
                controller: draft.customInputs[i],
                minLines: 1,
                maxLines: 3,
                onChanged: (_) => onChanged(),
                style: const TextStyle(fontSize: 12.5, height: 1.4),
                decoration: const InputDecoration(
                  labelText: '其他 / 自己输入',
                  hintText: '没有合适选项时，在这里补充你的想法',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

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
            '再按篇讨论主题、配角和阶段方向，最后按篇逐章成文并导出。',
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
                    '${book.volumes.length} 篇 · ${book.doneChapters}/${book.totalChapters} 章 · ${book.totalWords} 字',
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
    final chapters = TextEditingController(text: '200');
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
                          child: _field(chapters, '计划总章数', '200', number: true),
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
              Expanded(child: _rightEditor(svc, book)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _rightEditor(BookService svc, Book book) {
    if (svc.activeChapter != null) {
      return _ChapterEditor(
        key: ValueKey(svc.activeChapter!.id),
        svc: svc,
        chapter: svc.activeChapter!,
        content: svc.activeChapter!.content,
        busy: svc.busy,
      );
    }
    if (svc.activeVolume != null) {
      return _VolumeEditor(
        key: ValueKey(svc.activeVolume!.id),
        svc: svc,
        book: book,
        volume: svc.activeVolume!,
      );
    }
    return _BibleEditor(svc: svc, book: book);
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
                  '${book.volumes.length} 篇 · ${book.doneChapters}/${book.totalChapters} 章 · 约 ${book.totalWords} 字',
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
              ? '将先生成设定集、篇规划与篇内章节大纲，再按篇依次写完每一章。整本长篇耗时较长，期间可随时点「停止」，已写内容会自动保存。是否开始？'
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
              selected: svc.activeChapter == null && svc.activeVolume == null,
              onTap: () {
                svc.openVolume(null);
                svc.openChapter(null);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                const Text(
                  '篇 / 章节',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _muted,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '生成 / 重排篇规划',
                  visualDensity: VisualDensity.compact,
                  onPressed: svc.busy ? null : svc.generateVolumePlan,
                  icon: const Icon(Icons.account_tree_outlined, size: 16),
                  color: _accent,
                ),
              ],
            ),
          ),
          Expanded(
            child: book.volumes.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Text(
                          '还没有篇规划',
                          style: TextStyle(fontSize: 12.5, color: _muted),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.tonalIcon(
                          onPressed: svc.busy ? null : svc.generateVolumePlan,
                          icon: const Icon(
                            Icons.account_tree_outlined,
                            size: 15,
                          ),
                          label: const Text('生成篇规划'),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: book.volumes.length,
                    itemBuilder: (context, i) =>
                        _volumeTile(svc, book.volumes[i], i),
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

  Widget _volumeTile(BookService svc, BookVolume volume, int i) {
    final selected = svc.activeVolume == volume && svc.activeChapter == null;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFE8F5F3) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ExpansionTile(
        key: PageStorageKey(volume.id),
        initiallyExpanded:
            selected || volume.chapters.contains(svc.activeChapter),
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        childrenPadding: const EdgeInsets.only(left: 8, bottom: 6),
        leading: Icon(
          Icons.segment_outlined,
          size: 17,
          color: selected ? _accent : _sub,
        ),
        title: Text(
          '${i + 1}. ${volume.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? _accent : _ink,
          ),
        ),
        subtitle: Text(
          '${volume.doneChapters}/${volume.chapters.length} 章 · 计划 ${volume.chapterCount} 章',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: _muted),
        ),
        onExpansionChanged: (_) => svc.openVolume(volume),
        children: [
          if (volume.chapters.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 8, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: svc.busy ? null : svc.generateOutline,
                  icon: const Icon(Icons.auto_awesome, size: 14),
                  label: const Text('生成本篇章节大纲'),
                ),
              ),
            )
          else
            for (var j = 0; j < volume.chapters.length; j++)
              _chapterTile(svc, volume.chapters[j], j),
        ],
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
  final _discussion = TextEditingController();
  final _refTitle = TextEditingController();
  final _refAuthor = TextEditingController();
  final _refNote = TextEditingController();
  final _loglineFocus = FocusNode();
  final _synopsisFocus = FocusNode();
  final _worldviewFocus = FocusNode();
  _QuestionDraft? _draft;

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
    _discussion.dispose();
    _refTitle.dispose();
    _refAuthor.dispose();
    _refNote.dispose();
    _draft?.dispose();
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

  Future<void> _askQuestions() async {
    final questions = await widget.svc.discussBible(_discussion.text);
    if (!mounted) return;
    setState(() {
      _draft?.dispose();
      _draft = _QuestionDraft(questions);
    });
  }

  Future<void> _applyDiscussion() async {
    final answer =
        _draft?.composeAnswer(prefix: _discussion.text) ??
        _discussion.text.trim();
    await widget.svc.applyBibleDiscussion(answer);
    if (!mounted) return;
    _seed();
    setState(() {
      _draft?.dispose();
      _draft = null;
      _discussion.clear();
    });
  }

  Future<void> _addReference() async {
    final title = _refTitle.text.trim();
    if (title.isEmpty) return;
    try {
      widget.svc.addReference(
        title: title,
        author: _refAuthor.text.trim(),
        note: _refNote.text.trim(),
      );
      _refTitle.clear();
      _refAuthor.clear();
      _refNote.clear();
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('添加参考书失败：$e')));
    }
  }

  Future<void> _analyzeReference(BookReference ref) async {
    await widget.svc.analyzeReference(ref);
    if (mounted) setState(() {});
  }

  Future<void> _removeReference(BookReference ref) async {
    await widget.svc.removeReference(ref);
    if (mounted) setState(() {});
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
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: busy ? null : _askQuestions,
                icon: const Icon(Icons.forum_outlined, size: 15),
                label: const Text('对话完善'),
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
                _referencePanel(busy),
                _discussionPanel(busy),
                const SizedBox(height: 8),
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

  Widget _discussionPanel(bool busy) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '总体方向对话',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            '先让 AI 提出需要确认的问题，再把你的回答应用到故事设定集。适合补强主线、人物群像、反派和长期配角池。',
            style: TextStyle(fontSize: 12, color: _muted, height: 1.5),
          ),
          if (_draft != null) ...[
            const SizedBox(height: 10),
            _questionChoiceList(_draft!, () => setState(() {})),
          ],
          const SizedBox(height: 10),
          TextField(
            controller: _discussion,
            minLines: 3,
            maxLines: 6,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 13.5, height: 1.5),
            decoration: const InputDecoration(
              hintText: '可选：写下整体补充、禁忌、想强化的人物或总体方向…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : _askQuestions,
                icon: const Icon(Icons.help_outline, size: 15),
                label: const Text('让 AI 追问'),
              ),
              FilledButton.icon(
                onPressed:
                    busy ||
                        (_discussion.text.trim().isEmpty &&
                            !(_draft?.hasAnswers ?? false))
                    ? null
                    : _applyDiscussion,
                style: FilledButton.styleFrom(backgroundColor: _accent),
                icon: const Icon(Icons.check, size: 15),
                label: const Text('应用到设定集'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _referencePanel(bool busy) {
    final refs = widget.book.references;
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.menu_book_outlined, size: 16, color: _accent),
              const SizedBox(width: 6),
              const Text(
                '参考书目',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Text(
                '${refs.where((r) => r.enabled).length}/${refs.length} 本参与规划',
                style: const TextStyle(fontSize: 11.5, color: _muted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '填写想借鉴的书。系统优先找公版全文；如果只找到网页摘要或书评，只提炼可见线索，不绕过付费、登录或版权限制。',
            style: TextStyle(fontSize: 12, color: _muted, height: 1.5),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _smallInput(_refTitle, '书名', '例如：Pride and Prejudice'),
              ),
              const SizedBox(width: 8),
              Expanded(child: _smallInput(_refAuthor, '作者', '可选')),
            ],
          ),
          const SizedBox(height: 8),
          _smallInput(_refNote, '备注', '想借鉴什么：节奏、人物关系、冲突升级…', maxLines: 2),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: busy || _refTitle.text.trim().isEmpty
                  ? null
                  : _addReference,
              style: FilledButton.styleFrom(backgroundColor: _accent),
              icon: const Icon(Icons.add, size: 15),
              label: const Text('添加参考书'),
            ),
          ),
          if (refs.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...refs.map((ref) => _referenceCard(ref, busy)),
          ],
        ],
      ),
    );
  }

  Widget _smallInput(
    TextEditingController c,
    String label,
    String hint, {
    int maxLines = 1,
  }) {
    return TextField(
      controller: c,
      maxLines: maxLines,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(fontSize: 12.5, height: 1.45),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _referenceCard(BookReference ref, bool busy) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  ref.author.isEmpty
                      ? ref.title
                      : '${ref.title} / ${ref.author}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _ink,
                  ),
                ),
              ),
              Switch(
                value: ref.enabled,
                activeThumbColor: _accent,
                onChanged: busy
                    ? null
                    : (v) async {
                        await widget.svc.toggleReference(ref, v);
                        if (mounted) setState(() {});
                      },
              ),
              IconButton(
                tooltip: '删除参考书',
                onPressed: busy ? null : () => _removeReference(ref),
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
            ],
          ),
          Text(
            ref.status,
            style: TextStyle(
              fontSize: 11.5,
              color: ref.status.startsWith('失败') ? Colors.redAccent : _muted,
            ),
          ),
          if (ref.sourceUrl.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '来源：${ref.sourceLabel.isEmpty ? ref.sourceUrl : ref.sourceLabel} · ${ref.sourceUrl}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: _muted),
            ),
          ],
          if (ref.note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '备注：${ref.note}',
              style: const TextStyle(fontSize: 12, color: _sub, height: 1.45),
            ),
          ],
          if (ref.excerpt.isNotEmpty) ...[
            const SizedBox(height: 8),
            _summaryBlock('可见资料摘录', ref.excerpt, maxLines: 4),
          ],
          if (ref.patternSummary.isNotEmpty) ...[
            const SizedBox(height: 8),
            _summaryBlock('套路总结', ref.patternSummary, maxLines: 8),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: busy ? null : () => _analyzeReference(ref),
              icon: const Icon(Icons.travel_explore, size: 15),
              label: Text(ref.patternSummary.isEmpty ? '联网查找并总结' : '重新查找并总结'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryBlock(String title, String text, {int maxLines = 5}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 11.5,
              color: _accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            text,
            maxLines: maxLines,
            style: const TextStyle(fontSize: 12, color: _sub, height: 1.45),
          ),
        ],
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
// 篇详情编辑器
// -----------------------------------------------------------------------------

class _VolumeEditor extends StatefulWidget {
  const _VolumeEditor({
    super.key,
    required this.svc,
    required this.book,
    required this.volume,
  });

  final BookService svc;
  final Book book;
  final BookVolume volume;

  @override
  State<_VolumeEditor> createState() => _VolumeEditorState();
}

class _VolumeEditorState extends State<_VolumeEditor> {
  late final _title = TextEditingController(text: widget.volume.title);
  late final _theme = TextEditingController(text: widget.volume.theme);
  late final _direction = TextEditingController(text: widget.volume.direction);
  late final _summary = TextEditingController(text: widget.volume.summary);
  late final _chapterCount = TextEditingController(
    text: widget.volume.chapterCount.toString(),
  );
  final _discussion = TextEditingController();
  _QuestionDraft? _draft;

  @override
  void dispose() {
    _title.dispose();
    _theme.dispose();
    _direction.dispose();
    _summary.dispose();
    _chapterCount.dispose();
    _discussion.dispose();
    _draft?.dispose();
    super.dispose();
  }

  void _seed() {
    _title.text = widget.volume.title;
    _theme.text = widget.volume.theme;
    _direction.text = widget.volume.direction;
    _summary.text = widget.volume.summary;
    _chapterCount.text = widget.volume.chapterCount.toString();
  }

  void _save() {
    widget.volume.title = _title.text.trim().isEmpty
        ? widget.volume.title
        : _title.text.trim();
    widget.volume.theme = _theme.text.trim();
    widget.volume.direction = _direction.text.trim();
    widget.volume.summary = _summary.text.trim();
    final count = int.tryParse(_chapterCount.text.trim());
    if (count != null && count > 0) widget.volume.chapterCount = count;
    widget.svc.saveVolume();
  }

  Future<void> _askQuestions() async {
    _save();
    final questions = await widget.svc.discussVolume(
      widget.volume,
      _discussion.text,
    );
    if (!mounted) return;
    setState(() {
      _draft?.dispose();
      _draft = _QuestionDraft(questions);
    });
  }

  Future<void> _applyDiscussion() async {
    _save();
    final answer =
        _draft?.composeAnswer(prefix: _discussion.text) ??
        _discussion.text.trim();
    await widget.svc.applyVolumeDiscussion(widget.volume, answer);
    if (!mounted) return;
    _seed();
    setState(() {
      _draft?.dispose();
      _draft = null;
      _discussion.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.svc.busy;
    final volume = widget.volume;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  volume.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : _askQuestions,
                icon: const Icon(Icons.forum_outlined, size: 15),
                label: const Text('对话完善本篇'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: busy ? null : widget.svc.generateOutline,
                style: FilledButton.styleFrom(backgroundColor: _accent),
                icon: const Icon(Icons.auto_awesome, size: 15),
                label: Text(volume.chapters.isEmpty ? '生成本篇大纲' : '重排本篇大纲'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(
              children: [
                Row(
                  children: [
                    Expanded(child: _field(_title, '篇名', '第一篇')),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 140,
                      child: _field(_chapterCount, '计划章数', '50', number: true),
                    ),
                  ],
                ),
                _field(_theme, '本篇主题', '例如：信任崩塌、第一次反攻、离开故乡'),
                _field(_direction, '本篇方向', '开局状态、阶段目标、核心冲突、篇尾状态', maxLines: 4),
                _field(_summary, '本篇梗概', '本篇主要事件与人物变化', maxLines: 6),
                _discussionPanel(busy),
                const SizedBox(height: 14),
                const Text(
                  '本篇人物与配角',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                if (volume.characters.isEmpty)
                  const Text(
                    '还没有篇人物。先通过「对话完善本篇」补充配角、反派、盟友和功能性人物。',
                    style: TextStyle(fontSize: 12.5, color: _muted),
                  )
                else
                  ...volume.characters.map(_characterCard),
              ],
            ),
          ),
        ],
      ),
    );
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
            onTapOutside: (_) => _save(),
            onEditingComplete: _save,
            style: const TextStyle(fontSize: 13.5, height: 1.45),
            decoration: InputDecoration(
              hintText: hint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _discussionPanel(bool busy) {
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '本篇方向对话',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          const Text(
            '每篇通常约 50 章。先讨论本篇主题、阶段目标、配角配置和篇尾状态，再生成章节大纲。',
            style: TextStyle(fontSize: 12, color: _muted, height: 1.5),
          ),
          if (_draft != null) ...[
            const SizedBox(height: 10),
            _questionChoiceList(_draft!, () => setState(() {})),
          ],
          const SizedBox(height: 10),
          TextField(
            controller: _discussion,
            minLines: 3,
            maxLines: 6,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 13.5, height: 1.5),
            decoration: const InputDecoration(
              hintText: '可选：写下你对本篇主题、配角、冲突、伏笔和结尾状态的补充…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : _askQuestions,
                icon: const Icon(Icons.help_outline, size: 15),
                label: const Text('让 AI 追问'),
              ),
              FilledButton.icon(
                onPressed:
                    busy ||
                        (_discussion.text.trim().isEmpty &&
                            !(_draft?.hasAnswers ?? false))
                    ? null
                    : _applyDiscussion,
                style: FilledButton.styleFrom(backgroundColor: _accent),
                icon: const Icon(Icons.check, size: 15),
                label: const Text('应用到本篇'),
              ),
            ],
          ),
        ],
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
              const Icon(Icons.group_outlined, size: 15, color: _accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  c.name,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (c.role.isNotEmpty)
                Text(
                  c.role,
                  style: const TextStyle(fontSize: 11.5, color: _accent),
                ),
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
