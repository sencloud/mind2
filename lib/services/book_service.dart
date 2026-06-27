import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'agent/memory/memory_selector.dart';
import 'agent/memory/memory_store.dart';
import 'agent/memory/memory_types.dart';
import 'agent/model_client.dart';
import 'settings_service.dart';

/// 人物卡：构成「故事圣经(story bible)」的一部分，为正文生成提供一致性约束。
class BookCharacter {
  BookCharacter({required this.name, this.role = '', this.description = ''});

  String name;

  /// 角色定位（主角/反派/配角…）。
  String role;

  /// 性格、背景、目标、外貌等设定。
  String description;

  Map<String, dynamic> toJson() => {
    'name': name,
    'role': role,
    'description': description,
  };

  factory BookCharacter.fromJson(Map<String, dynamic> j) => BookCharacter(
    name: j['name'] as String? ?? '',
    role: j['role'] as String? ?? '',
    description: j['description'] as String? ?? '',
  );
}

/// 一章：标题 + 概要(beat) + 正文。概要来自大纲，正文按需生成/编辑。
class BookChapter {
  BookChapter({
    required this.id,
    required this.title,
    this.summary = '',
    this.content = '',
    this.recap = '',
  });

  final String id;
  String title;

  /// 本章关键情节/目标/钩子（来自大纲，用于指导成文）。
  String summary;

  /// 本章正文。
  String content;

  /// 本章「事后纪要」：成文后由模型客观归纳的本章关键事件，
  /// 用于维护故事台账与后续章节的连贯（防止前写后忘）。
  String recap;

  BookChapter._({
    required this.id,
    required this.title,
    required this.summary,
    required this.content,
    required this.recap,
  });

  bool get hasContent => content.trim().isNotEmpty;

  /// 中文场景下用「非空白字符数」近似字数。
  int get words => content.replaceAll(RegExp(r'\s'), '').length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'summary': summary,
    'content': content,
    'recap': recap,
  };

  factory BookChapter.fromJson(Map<String, dynamic> j) => BookChapter._(
    id: j['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
    title: j['title'] as String? ?? '',
    summary: j['summary'] as String? ?? '',
    content: j['content'] as String? ?? '',
    recap: j['recap'] as String? ?? '',
  );
}

/// 一本书：项目元信息 + 故事圣经(设定集) + 章节大纲与正文。
class Book {
  Book({
    required this.id,
    required this.title,
    this.genre = '',
    this.audience = '',
    this.style = '',
    this.premise = '',
    this.targetChapters = 12,
    this.targetWordsPerChapter = 2000,
    this.logline = '',
    this.synopsis = '',
    this.worldview = '',
    this.storyState = '',
    List<BookCharacter>? characters,
    List<BookChapter>? chapters,
    required this.createdAt,
    required this.updatedAt,
  }) : characters = characters ?? [],
       chapters = chapters ?? [];

  final String id;
  String title;

  /// 类型/题材（玄幻/科幻/悬疑/言情/历史/都市/非虚构…）。
  String genre;

  /// 目标读者。
  String audience;

  /// 文风/基调（如：冷峻克制、轻松诙谐、史诗厚重…）。
  String style;

  /// 一句话核心创意/立意（用户输入，作为创作锚点）。
  String premise;

  /// 计划章数与每章目标字数（用于大纲与成文）。
  int targetChapters;
  int targetWordsPerChapter;

  // —— 故事圣经(story bible) ——
  String logline;
  String synopsis;
  String worldview;
  List<BookCharacter> characters;

  /// 「故事进展台账」：随章节推进滚动更新的精炼状态摘要——
  /// 主线进展、人物现状与关系、已揭示设定、未解伏笔、时间线。
  /// 它是支撑长篇连贯（防止前写后忘）的核心「常驻记忆」。
  String storyState;

  // —— 大纲与正文 ——
  List<BookChapter> chapters;

  final DateTime createdAt;
  DateTime updatedAt;

  bool get hasBible =>
      synopsis.trim().isNotEmpty ||
      worldview.trim().isNotEmpty ||
      characters.isNotEmpty;

  int get totalWords => chapters.fold(0, (s, c) => s + c.words);
  int get doneChapters => chapters.where((c) => c.hasContent).length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'genre': genre,
    'audience': audience,
    'style': style,
    'premise': premise,
    'targetChapters': targetChapters,
    'targetWordsPerChapter': targetWordsPerChapter,
    'logline': logline,
    'synopsis': synopsis,
    'worldview': worldview,
    'storyState': storyState,
    'characters': characters.map((c) => c.toJson()).toList(),
    'chapters': chapters.map((c) => c.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Book.fromJson(Map<String, dynamic> j) => Book(
    id: j['id'] as String,
    title: j['title'] as String? ?? '未命名',
    genre: j['genre'] as String? ?? '',
    audience: j['audience'] as String? ?? '',
    style: j['style'] as String? ?? '',
    premise: j['premise'] as String? ?? '',
    targetChapters: (j['targetChapters'] as num?)?.toInt() ?? 12,
    targetWordsPerChapter:
        (j['targetWordsPerChapter'] as num?)?.toInt() ?? 2000,
    logline: j['logline'] as String? ?? '',
    synopsis: j['synopsis'] as String? ?? '',
    worldview: j['worldview'] as String? ?? '',
    storyState: j['storyState'] as String? ?? '',
    characters: ((j['characters'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => BookCharacter.fromJson(e.cast<String, dynamic>()))
        .toList(),
    chapters: ((j['chapters'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => BookChapter.fromJson(e.cast<String, dynamic>()))
        .toList(),
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
  );
}

/// 「写作」：参照主流 AI 写作软件（Sudowrite / Novelcrafter 等）的实践，
/// 把长文创作拆成可控的流水线——
/// ① 立项(书名/题材/读者/文风/核心创意) →
/// ② 故事圣经(一句话梗概/故事大纲/世界观/人物卡，保证设定一致) →
/// ③ 章节大纲(逐章 beat) →
/// ④ 逐章成文(携带圣经+相邻章节摘要+上一章结尾做滚动上下文，保证连贯) →
/// ⑤ 章节级续写/润色 → ⑥ 合并导出。
class BookService extends ChangeNotifier {
  BookService(this.settings);

  final SettingsService settings;

  final List<Book> books = [];
  Book? current;
  BookChapter? activeChapter;

  /// 正在生成（生成期间禁用相关操作）。
  bool busy = false;

  /// 当前进度提示。
  String stage = '';

  bool _cancel = false;
  File? _store;
  String _baseDir = '';

  /// 当前在途的 HTTP client：取消时直接关闭以中断请求（含非流式的长调用）。
  http.Client? _client;

  /// 小模型通道（用通用默认模型）：供「按需回忆」相关设定的廉价选择题使用，
  /// 复用项目重构后的记忆基建（MemoryStore 结构化文件 + MemorySelector 小模型选择）。
  late final ModelClient _small = ModelClient(settings, small: true);
  late final MemorySelector _selector = MemorySelector(_small);

  /// 每本书一个「设定记忆库」（结构化 .md + MEMORY.md 索引），
  /// 落在应用数据目录，不污染知识库。
  MemoryStore _canon(Book book) =>
      MemoryStore('$_baseDir\\book_data\\${book.id}\\memory');

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _baseDir = dir.path;
    _store = File('${dir.path}\\books.json');
    if (await _store!.exists()) {
      try {
        final data = jsonDecode(await _store!.readAsString());
        if (data is List) {
          books
            ..clear()
            ..addAll(
              data.whereType<Map>().map(
                (e) => Book.fromJson(e.cast<String, dynamic>()),
              ),
            );
          books.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        }
      } catch (_) {
        // 解析失败保持空列表，不静默写坏数据。
      }
    }
  }

  Future<void> _persist() async {
    if (_store == null) return;
    try {
      await _store!.writeAsString(
        jsonEncode(books.map((b) => b.toJson()).toList()),
      );
    } catch (_) {}
  }

  void _touch() {
    current?.updatedAt = DateTime.now();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 书架管理
  // ---------------------------------------------------------------------------

  Book createBook({
    required String title,
    String genre = '',
    String audience = '',
    String style = '',
    String premise = '',
    int targetChapters = 12,
    int targetWordsPerChapter = 2000,
  }) {
    final book = Book(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title.trim().isEmpty ? '未命名' : title.trim(),
      genre: genre.trim(),
      audience: audience.trim(),
      style: style.trim(),
      premise: premise.trim(),
      targetChapters: targetChapters,
      targetWordsPerChapter: targetWordsPerChapter,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    books.insert(0, book);
    current = book;
    activeChapter = null;
    notifyListeners();
    _persist();
    return book;
  }

  void openBook(Book book) {
    current = book;
    activeChapter = null;
    notifyListeners();
  }

  void closeBook() {
    current = null;
    activeChapter = null;
    notifyListeners();
  }

  void openChapter(BookChapter? chapter) {
    activeChapter = chapter;
    notifyListeners();
  }

  Future<void> deleteBook(Book book) async {
    books.remove(book);
    if (current == book) {
      current = null;
      activeChapter = null;
    }
    notifyListeners();
    await _persist();
    // 一并清理该书的设定记忆库目录。
    try {
      final dir = Directory('$_baseDir\\book_data\\${book.id}');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 「灵感骰子」：让 AI 随机设计一个适合写成百万字长篇的选题，
  /// 返回可填充新建表单的字段。失败返回 null（由 UI 提示）。
  Future<Map<String, dynamic>?> inspire({required String genre}) async {
    final selectedGenre = genre.trim();
    final reply = await _chat([
      {
        'role': 'system',
        'content': '你是富有创意的小说选题策划，擅长构思新颖、有市场吸引力、可支撑百万字体量的长篇设定。只输出 JSON。',
      },
      {
        'role': 'user',
        'content':
            '''
随机构思一个**适合写成 100 万字以上长篇**的小说选题，要新颖、有钩子、避免老套。
题材必须围绕：$selectedGenre。可以细化子题材，但不要偏离这个方向。
严格输出 JSON：
{"title":"书名","genre":"类型/题材","audience":"目标读者","style":"文风/基调","premise":"一句话核心创意/立意","targetChapters":整数(建议 200~400),"targetWordsPerChapter":整数(建议 2500~4000)}''',
      },
    ], jsonMode: true);
    return _parseJson(reply);
  }

  void cancel() {
    if (busy) {
      _cancel = true;
      stage = '正在停止…';
      // 关闭在途请求，立即中断「规划大纲 / 生成设定集 / 成文」等长调用。
      try {
        _client?.close();
      } catch (_) {}
      notifyListeners();
    }
  }

  /// 手动保存章节正文/标题/概要（编辑器失焦或点保存时调用）。
  Future<void> saveChapter() async {
    _touch();
    await _persist();
  }

  /// 手动保存设定集编辑。
  Future<void> saveBible() async {
    _touch();
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // ② 生成故事圣经（设定集）
  // ---------------------------------------------------------------------------

  Future<void> generateBible() async {
    final book = current;
    if (book == null || busy) return;
    _begin('正在生成故事设定集（梗概 / 世界观 / 人物）…');
    try {
      await _doBible(book);
    } catch (e) {
      stage = _cancel ? '已停止' : '生成设定集失败：$e';
    } finally {
      _end();
    }
  }

  Future<void> _doBible(Book book) async {
    final reply = await _chat([
      {
        'role': 'system',
        'content': '你是资深小说编辑与故事策划，擅长为作品搭建"故事圣经(story bible)"。只输出 JSON，不要多余解释。',
      },
      {'role': 'user', 'content': _biblePrompt(book)},
    ], jsonMode: true);
    final m = _parseJson(reply);
    if (m != null) {
      book.logline = (m['logline'] as String? ?? book.logline).trim();
      book.synopsis = (m['synopsis'] as String? ?? book.synopsis).trim();
      book.worldview = (m['worldview'] as String? ?? book.worldview).trim();
      final chars = (m['characters'] as List?) ?? [];
      if (chars.isNotEmpty) {
        book.characters = chars
            .whereType<Map>()
            .map(
              (e) => BookCharacter(
                name: (e['name'] ?? '').toString().trim(),
                role: (e['role'] ?? '').toString().trim(),
                description: (e['description'] ?? '').toString().trim(),
              ),
            )
            .where((c) => c.name.isNotEmpty)
            .toList();
      }
    }
    _touch();
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // ③ 生成章节大纲
  // ---------------------------------------------------------------------------

  Future<void> generateOutline() async {
    final book = current;
    if (book == null || busy) return;
    _begin('正在规划章节大纲…');
    try {
      await _doOutline(book);
    } catch (e) {
      stage = _cancel ? '已停止' : '生成大纲失败：$e';
    } finally {
      _end();
    }
  }

  Future<void> _doOutline(Book book) async {
    final reply = await _chat([
      {
        'role': 'system',
        'content': '你是资深小说结构师，擅长用"起承转合/三幕式"设计章节大纲，每章有明确目标、冲突与钩子。只输出 JSON。',
      },
      {'role': 'user', 'content': _outlinePrompt(book)},
    ], jsonMode: true);
    final m = _parseJson(reply);
    final list = (m?['chapters'] as List?) ?? [];
    if (list.isNotEmpty) {
      final existing = {for (final c in book.chapters) c.title: c};
      final next = <BookChapter>[];
      var i = 0;
      for (final item in list.whereType<Map>()) {
        i++;
        final title = (item['title'] ?? '第$i章').toString().trim();
        final summary = (item['summary'] ?? '').toString().trim();
        // 保留已写正文：同标题章节沿用其内容。
        final prev = existing[title];
        next.add(
          BookChapter(
            id: prev?.id ?? '${DateTime.now().microsecondsSinceEpoch}_$i',
            title: title.isEmpty ? '第$i章' : title,
            summary: summary,
            content: prev?.content ?? '',
            recap: prev?.recap ?? '',
          ),
        );
      }
      book.chapters = next;
    }
    _touch();
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // ④/⑤ 章节成文 / 续写 / 润色（流式）
  // ---------------------------------------------------------------------------

  static const _novelistSystem =
      '你是一位优秀的小说家，文笔细腻、节奏鲜明，擅长"展示而非告知"，对白自然、画面感强。'
      '直接输出本章正文（Markdown 段落），不要输出标题、解释或任何元信息。';

  /// 生成（覆盖）本章正文。
  Future<void> writeChapter(BookChapter chapter) async {
    final book = current;
    if (book == null || busy) return;
    _begin('回忆相关设定与前情…');
    try {
      await _composeChapter(book, chapter);
    } catch (e) {
      stage = _cancel ? '已停止' : '生成失败：$e';
    } finally {
      _end();
    }
  }

  /// 写一章的核心：回忆相关设定 → 流式成文 → 连贯性归档。
  /// 不管理 busy（由调用方负责），以便被「一键写完全本」复用。
  Future<void> _composeChapter(
    Book book,
    BookChapter chapter, {
    String? progress,
  }) async {
    stage = '回忆相关设定与前情…';
    notifyListeners();
    final canon = await _recallCanon(book, chapter);
    final tag = progress == null ? '' : '（$progress）';
    stage = '正在创作《${chapter.title}》$tag…';
    notifyListeners();
    final acc = await _streamChapter(
      chapter,
      system: _novelistSystem,
      user: _chapterPrompt(book, chapter, canon),
      replace: true,
    );
    if (acc.trim().isNotEmpty && !_cancel) await _consolidate(book, chapter);
  }

  /// 「一键写完全本」：必要时先补设定集/大纲，再依次为所有空章节生成正文。
  /// 已写章节自动跳过（可断点续写），期间可随时停止。
  Future<void> writeWholeBook() async {
    final book = current;
    if (book == null || busy) return;
    _begin('准备一键写作…');
    try {
      if (!book.hasBible) {
        stage = '生成故事设定集…';
        notifyListeners();
        await _doBible(book);
      }
      if (_cancel) return;
      if (book.chapters.isEmpty) {
        stage = '规划章节大纲…';
        notifyListeners();
        await _doOutline(book);
      }
      final total = book.chapters.length;
      if (total == 0) {
        stage = '未能生成章节大纲，请先手动生成大纲';
        return;
      }
      for (var i = 0; i < book.chapters.length; i++) {
        if (_cancel) break;
        final ch = book.chapters[i];
        if (ch.hasContent) continue; // 断点续写：跳过已完成章节
        activeChapter = ch; // 让编辑器跟随当前正在写的章节
        notifyListeners();
        await _composeChapter(book, ch, progress: '${i + 1}/$total');
      }
      stage = _cancel
          ? '已停止（已完成 ${book.doneChapters}/$total 章）'
          : '🎉 全本完成：${book.doneChapters}/$total 章，约 ${book.totalWords} 字';
    } catch (e) {
      stage = _cancel
          ? '已停止（已完成 ${book.doneChapters}/${book.chapters.length} 章）'
          : '写作中断：$e';
    } finally {
      _end();
    }
  }

  /// 接着本章已有正文继续写。
  Future<void> continueChapter(BookChapter chapter) async {
    if (!chapter.hasContent) return writeChapter(chapter);
    final book = current;
    if (book == null || busy) return;
    _begin('回忆相关设定与前情…');
    try {
      final canon = await _recallCanon(book, chapter);
      stage = '正在续写《${chapter.title}》…';
      notifyListeners();
      final acc = await _streamChapter(
        chapter,
        system:
            '你是一位优秀的小说家。请紧接给定的"已有正文"自然地继续往下写，'
            '保持人物口吻、文风与时态一致。只输出新增的后续正文，不要重复已有内容、不要解释。',
        user: _continuePrompt(book, chapter, canon),
        replace: false,
      );
      if (acc.trim().isNotEmpty && !_cancel) await _consolidate(book, chapter);
    } catch (e) {
      stage = _cancel ? '已停止' : '生成失败：$e';
    } finally {
      _end();
    }
  }

  /// 润色本章正文（整体重写为更精炼流畅的版本）。
  Future<void> polishChapter(BookChapter chapter) async {
    if (!chapter.hasContent || busy) return;
    _begin('正在润色《${chapter.title}》…');
    try {
      final reply = await _chat([
        {
          'role': 'system',
          'content':
              '你是资深文学编辑，擅长在不改变情节与设定的前提下润色文字：'
              '让语言更精炼传神、节奏更顺、对白更自然、删除冗余。只输出润色后的完整正文，不要解释。',
        },
        {
          'role': 'user',
          'content': '请润色以下章节正文（保持原意与篇幅相当）：\n\n${chapter.content}',
        },
      ]);
      if (reply.trim().isNotEmpty && !_cancel) {
        chapter.content = reply.trim();
      }
      _touch();
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '润色失败：$e';
    } finally {
      _end();
    }
  }

  /// 流式生成正文写入章节，返回累计文本。由调用方管理 busy 与异常。
  Future<String> _streamChapter(
    BookChapter chapter, {
    required String system,
    required String user,
    required bool replace,
  }) async {
    final base = replace ? '' : chapter.content;
    if (replace) chapter.content = '';
    var acc = '';
    await for (final delta in _streamChat([
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': user},
    ])) {
      if (_cancel) break;
      acc += delta;
      chapter.content = replace ? acc : '$base\n\n$acc';
      notifyListeners();
    }
    if (acc.trim().isEmpty && replace) stage = '模型未返回内容';
    _touch();
    await _persist();
    return acc;
  }

  // ---------------------------------------------------------------------------
  // 长篇连贯记忆（参照项目记忆系统：常驻台账 + 结构化设定库 + 小模型按需回忆）
  // ---------------------------------------------------------------------------

  /// 写当前章前，用小模型从「设定记忆库」里挑出与本章相关的已确立设定，
  /// 注入正文生成上下文，避免与前文矛盾或遗忘关键信息。
  Future<String> _recallCanon(Book book, BookChapter ch) async {
    try {
      final store = _canon(book);
      final headers = await store.scanHeaders();
      if (headers.isEmpty) return '';
      final query = '${ch.title}。${ch.summary}';
      final selected = await _selector.select(
        query: query,
        headers: headers,
        manifest: store.formatManifest(headers),
        maxResults: 8,
      );
      if (selected.isEmpty) return '';
      final buf = StringBuffer();
      for (final h in selected) {
        final body = await store.readBody(h.filename);
        if (body == null || body.trim().isEmpty) continue;
        buf.writeln('- ${h.name}：${body.trim()}');
      }
      return buf.toString().trim();
    } catch (_) {
      // 回忆失败不阻断写作。
      return '';
    }
  }

  /// 写完一章后：归纳本章纪要 → 更新故事台账 → 抽取设定/伏笔入记忆库。
  Future<void> _consolidate(Book book, BookChapter ch) async {
    try {
      stage = '归纳本章纪要…';
      notifyListeners();
      final recap = await _chat([
        {'role': 'system', 'content': '你负责为长篇小说做连贯性归档。只输出简洁中文，不要解释。'},
        {
          'role': 'user',
          'content':
              '用150字以内客观概述本章的关键事件（情节推进、人物状态/关系变化、'
              '新揭示的信息或埋下的伏笔），供后续章节保持连贯。只输出概述：\n\n${ch.content}',
        },
      ]);
      if (recap.trim().isNotEmpty) ch.recap = recap.trim();

      stage = '更新故事进展台账…';
      notifyListeners();
      final state = await _chat([
        {
          'role': 'system',
          'content': '你在维护一部长篇小说的"故事进展台账"，用于保证后续章节连贯、不遗忘、不自相矛盾。',
        },
        {'role': 'user', 'content': _stateUpdatePrompt(book, ch)},
      ]);
      if (state.trim().isNotEmpty) book.storyState = state.trim();

      stage = '沉淀设定与伏笔到记忆库…';
      notifyListeners();
      await _extractCanon(book, ch);

      _touch();
      await _persist();
    } catch (e) {
      // 连贯性归档失败不影响已写正文。
      stage = '连贯性归档失败（不影响正文）：$e';
      notifyListeners();
    }
  }

  /// 从本章抽取「需长期保持一致」的设定事实/伏笔，去重后写入记忆库。
  Future<void> _extractCanon(Book book, BookChapter ch) async {
    final store = _canon(book);
    final headers = await store.scanHeaders();
    final manifest = store.formatManifest(headers);
    final reply = await _chat([
      {
        'role': 'system',
        'content': '你负责从小说正文里抽取需长期保持一致的"设定事实"，建立设定圣经。只输出 JSON。',
      },
      {
        'role': 'user',
        'content':
            '''
从本章正文中抽取「未来章节需保持一致」的设定（人物的新设定或状态/关系变化、新登场的地点与设定、重要物品、被揭示的真相、埋下的伏笔/悬念）。

去重：下面是已有设定清单，若只是重复或补充已有项，请用 update 指向其文件名，不要新建近似项：
${manifest.isEmpty ? '(空)' : manifest}

严格输出 JSON：
{"facts":[{"type":"project|reference","name":"<=10字短标题","description":"一句话索引","body":"具体设定内容","update":"可选,要更新的文件名"}]}
（type：project=设定/事实，reference=伏笔/线索；没有可记的就 {"facts":[]}）

本章正文：
${ch.content}''',
      },
    ], jsonMode: true);
    final m = _parseJson(reply);
    final facts = (m?['facts'] as List?) ?? [];
    for (final f in facts.whereType<Map>()) {
      final name = (f['name'] ?? '').toString().trim();
      final body = (f['body'] ?? '').toString().trim();
      if (name.isEmpty || body.isEmpty) continue;
      final type = parseMemoryType(f['type']?.toString()) ?? MemoryType.project;
      final update = (f['update'] ?? '').toString().trim();
      await store.save(
        name: name,
        description: (f['description'] ?? '').toString().trim(),
        type: type,
        body: body,
        filename: update.isEmpty ? null : update,
      );
    }
  }

  String _stateUpdatePrompt(Book book, BookChapter ch) {
    final idx = book.chapters.indexOf(ch);
    return '''
已有故事台账（截至上一章）：
${book.storyState.trim().isEmpty ? '(空，本章是开篇附近)' : book.storyState.trim()}

刚完成的第 ${idx + 1} 章《${ch.title}》纪要：
${ch.recap.isEmpty ? ch.summary : ch.recap}

请输出更新后的故事台账（合并新信息、删除冗余，控制在约 1800 字内），用以下结构：
## 主线进展
## 人物现状与关系（位置 / 状态 / 掌握的信息 / 重要变化）
## 已揭示的关键设定
## 未解伏笔与悬念
## 时间线
只输出台账正文，不要解释。''';
  }

  // ---------------------------------------------------------------------------
  // ⑥ 导出为 Markdown（写入知识库根下的「4-书稿」目录）
  // ---------------------------------------------------------------------------

  /// 返回导出文件路径。
  Future<String> export() async {
    final book = current;
    if (book == null) throw StateError('未打开书籍');
    final buf = StringBuffer()
      ..writeln('# ${book.title}')
      ..writeln();
    if (book.logline.isNotEmpty) buf.writeln('> ${book.logline}\n');
    if (book.genre.isNotEmpty) buf.writeln('- 类型：${book.genre}');
    if (book.audience.isNotEmpty) buf.writeln('- 目标读者：${book.audience}');
    if (book.style.isNotEmpty) buf.writeln('- 文风：${book.style}');
    buf
      ..writeln(
        '- 字数：约 ${book.totalWords} 字 · ${book.doneChapters}/${book.chapters.length} 章',
      )
      ..writeln();
    for (final c in book.chapters) {
      if (!c.hasContent) continue;
      buf
        ..writeln('## ${c.title}')
        ..writeln()
        ..writeln(c.content.trim())
        ..writeln();
    }
    final dir = Directory(p.join(settings.vaultPath, '4-书稿'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, '${_sanitize(book.title)}.md'));
    await file.writeAsString(buf.toString());
    return file.path;
  }

  // ---------------------------------------------------------------------------
  // 提示词
  // ---------------------------------------------------------------------------

  String _meta(Book b) {
    final sb = StringBuffer()..writeln('书名：${b.title}');
    if (b.genre.isNotEmpty) sb.writeln('类型：${b.genre}');
    if (b.audience.isNotEmpty) sb.writeln('目标读者：${b.audience}');
    if (b.style.isNotEmpty) sb.writeln('文风/基调：${b.style}');
    if (b.premise.isNotEmpty) sb.writeln('核心创意/立意：${b.premise}');
    return sb.toString();
  }

  String _bibleBrief(Book b) {
    final sb = StringBuffer();
    if (b.logline.isNotEmpty) sb.writeln('一句话梗概：${b.logline}');
    if (b.synopsis.isNotEmpty) sb.writeln('故事大纲：${b.synopsis}');
    if (b.worldview.isNotEmpty) sb.writeln('世界观/设定：${b.worldview}');
    if (b.characters.isNotEmpty) {
      sb.writeln('主要人物：');
      for (final c in b.characters) {
        sb.writeln('- ${c.name}（${c.role}）：${c.description}');
      }
    }
    return sb.toString();
  }

  String _biblePrompt(Book b) =>
      '''
请基于下面的作品立项信息，搭建一套自洽、有张力的"故事圣经"。

${_meta(b)}

要求：
- logline：一句话概括全书核心冲突与卖点（不超过60字）。
- synopsis：300~500字的故事大纲，交代主线、核心冲突、转折与结局走向。
- worldview：世界观/背景设定（时代、规则、关键设定），200~400字。
- characters：4~8个主要人物，每个含 name(姓名)、role(定位)、description(性格/背景/目标/与主线的关系)。

严格输出 JSON：
{"logline":"...","synopsis":"...","worldview":"...","characters":[{"name":"...","role":"...","description":"..."}]}''';

  String _outlinePrompt(Book b) =>
      '''
请为这本书设计 ${b.targetChapters} 章的章节大纲。

${_meta(b)}

${_bibleBrief(b)}

要求：
- 共约 ${b.targetChapters} 章，整体遵循起承转合/三幕式，节奏有起伏。
- 每章包含 title(简洁有吸引力的章节标题) 与 summary(本章关键情节、人物目标、冲突与结尾钩子，60~120字)。
- 前后衔接连贯，逐步推进主线并埋设/回收伏笔。

严格输出 JSON：{"chapters":[{"title":"...","summary":"..."}]}''';

  /// 取最近 [n] 个有正文的前序章节纪要，用于「避免重复已写情节/描写」。
  String _recentRecaps(Book b, int idx, {int n = 3}) {
    final buf = StringBuffer();
    var taken = 0;
    for (var i = idx - 1; i >= 0 && taken < n; i--) {
      final c = b.chapters[i];
      final r = c.recap.trim().isNotEmpty ? c.recap.trim() : c.summary.trim();
      if (r.isEmpty) continue;
      buf.writeln('- 第${i + 1}章《${c.title}》：$r');
      taken++;
    }
    return buf.toString().trim();
  }

  String _chapterPrompt(Book b, BookChapter ch, String canon) {
    final idx = b.chapters.indexOf(ch);
    final outline = StringBuffer();
    for (var i = 0; i < b.chapters.length; i++) {
      final c = b.chapters[i];
      final mark = i == idx ? '▶ ' : '  ';
      outline.writeln('$mark第${i + 1}章 ${c.title}：${c.summary}');
    }
    var prevTail = '';
    if (idx > 0) {
      final prev = b.chapters[idx - 1];
      if (prev.hasContent) {
        final t = prev.content.trim();
        prevTail = t.length > 800 ? t.substring(t.length - 800) : t;
      }
    }
    final recent = _recentRecaps(b, idx);
    return '''
你正在创作《${b.title}》的第 ${idx + 1} 章：${ch.title}。

== 作品设定 ==
${_meta(b)}
${_bibleBrief(b)}
${b.storyState.trim().isEmpty ? '' : '''

== 前情提要与当前状态（务必延续，不要遗忘或矛盾）==
${b.storyState.trim()}'''}
${canon.trim().isEmpty ? '' : '''

== 与本章相关的已确立设定（务必保持一致）==
${canon.trim()}'''}
${recent.isEmpty ? '' : '''

== 最近几章已写情节（避免重复其场景、桥段与描写）==
$recent'''}

== 全书大纲（▶ 为当前章）==
${outline.toString().trim()}
${prevTail.isEmpty ? '' : '\n== 上一章结尾（衔接用，勿重复）==\n$prevTail\n'}
== 本章要写的内容 ==
${ch.summary.isEmpty ? '（按大纲推进本章情节）' : ch.summary}

要求：
- 目标篇幅约 ${b.targetWordsPerChapter} 字，紧扣本章 beat，并与上一章自然衔接。
- 严格延续「前情提要」与「已确立设定」，不得与之矛盾，不得遗忘已发生的事。
- 不要重复前文已写过的场景、桥段与描写；推动情节向前发展。
- 用具体场景、动作与对白推进，避免空洞概述。
- 直接输出本章正文（Markdown 段落），不要写章节标题、不要任何解释。''';
  }

  String _continuePrompt(Book b, BookChapter ch, String canon) {
    final idx = b.chapters.indexOf(ch);
    final t = ch.content.trim();
    final tail = t.length > 1500 ? t.substring(t.length - 1500) : t;
    return '''
你正在续写《${b.title}》第 ${idx + 1} 章：${ch.title}。

== 作品设定 ==
${_bibleBrief(b)}
${b.storyState.trim().isEmpty ? '' : '''

== 前情提要与当前状态（务必延续）==
${b.storyState.trim()}'''}
${canon.trim().isEmpty ? '' : '''

== 与本章相关的已确立设定（务必保持一致）==
${canon.trim()}'''}

== 本章目标 ==
${ch.summary}

== 已有正文（请紧接其后继续）==
$tail

要求：自然承接，保持文风与人物口吻一致，推进本章情节；不与前情/设定矛盾，不重复已写内容。只输出新增的后续正文，不要解释。''';
  }

  // ---------------------------------------------------------------------------
  // 模型调用
  // ---------------------------------------------------------------------------

  void _begin(String s) {
    busy = true;
    _cancel = false;
    stage = s;
    notifyListeners();
  }

  void _end() {
    busy = false;
    _cancel = false;
    _client = null;
    notifyListeners();
  }

  Map<String, dynamic>? _parseJson(String reply) {
    final start = reply.indexOf('{');
    final end = reply.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      return jsonDecode(reply.substring(start, end + 1))
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<String> _chat(
    List<Map<String, String>> messages, {
    bool jsonMode = false,
  }) async {
    final client = _client = http.Client();
    try {
      final resp = await client.post(
        Uri.parse('${settings.baseUrl}/chat/completions'),
        headers: {
          'Authorization': 'Bearer ${settings.apiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': settings.model,
          'stream': false,
          if (jsonMode) 'response_format': {'type': 'json_object'},
          'messages': messages,
        }),
      );
      if (resp.statusCode != 200) {
        throw Exception(
          'HTTP ${resp.statusCode} ${utf8.decode(resp.bodyBytes)}',
        );
      }
      final j = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      return (j['choices']?[0]?['message']?['content'] as String?)?.trim() ??
          '';
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  Stream<String> _streamChat(List<Map<String, String>> messages) async* {
    final request = http.Request(
      'POST',
      Uri.parse('${settings.baseUrl}/chat/completions'),
    );
    request.headers['Authorization'] = 'Bearer ${settings.apiKey}';
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode({
      'model': settings.model,
      'messages': messages,
      'stream': true,
    });

    final client = _client = http.Client();
    try {
      final response = await client.send(request);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw Exception('HTTP ${response.statusCode} $body');
      }

      var buffer = '';
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        if (_cancel) return;
        buffer += chunk;
        while (true) {
          final newline = buffer.indexOf('\n');
          if (newline < 0) break;
          final line = buffer.substring(0, newline).trim();
          buffer = buffer.substring(newline + 1);
          if (!line.startsWith('data:')) continue;
          final data = line.substring(5).trim();
          if (data == '[DONE]') return;
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            final content =
                json['choices']?[0]?['delta']?['content'] as String?;
            if (content != null && content.isNotEmpty) yield content;
          } catch (_) {
            // 忽略无法解析的片段
          }
        }
      }
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  static String _sanitize(String s) {
    var out = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    if (out.length > 80) out = out.substring(0, 80).trim();
    return out.isEmpty ? '未命名书稿' : out;
  }
}
