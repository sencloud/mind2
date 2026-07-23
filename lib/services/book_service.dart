import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../util/text_util.dart';
import 'agent/memory/memory_selector.dart';
import 'agent/memory/memory_store.dart';
import 'agent/memory/memory_types.dart';
import 'agent/model_client.dart';
import 'settings_service.dart';
import 'source_adapters.dart';

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

/// 引导式创作问题：每个问题给出多个可多选项，降低用户输入成本。
class BookDiscussionQuestion {
  BookDiscussionQuestion({required this.prompt, required this.options});

  final String prompt;
  final List<String> options;

  factory BookDiscussionQuestion.fromJson(Map<String, dynamic> j) {
    final options = ((j['options'] as List?) ?? [])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return BookDiscussionQuestion(
      prompt: (j['prompt'] ?? '').toString().trim(),
      options: options,
    );
  }
}

class BookReference {
  BookReference({
    required this.id,
    required this.title,
    this.author = '',
    this.query = '',
    this.note = '',
    this.sourceUrl = '',
    this.sourceLabel = '',
    this.status = '待检索',
    this.excerpt = '',
    this.patternSummary = '',
    this.enabled = true,
  });

  final String id;
  String title;
  String author;
  String query;
  String note;
  String sourceUrl;
  String sourceLabel;
  String status;
  String excerpt;
  String patternSummary;
  bool enabled;

  bool get hasPattern => patternSummary.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'query': query,
    'note': note,
    'sourceUrl': sourceUrl,
    'sourceLabel': sourceLabel,
    'status': status,
    'excerpt': excerpt,
    'patternSummary': patternSummary,
    'enabled': enabled,
  };

  factory BookReference.fromJson(Map<String, dynamic> j) => BookReference(
    id: j['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
    title: j['title'] as String? ?? '',
    author: j['author'] as String? ?? '',
    query: j['query'] as String? ?? '',
    note: j['note'] as String? ?? '',
    sourceUrl: j['sourceUrl'] as String? ?? '',
    sourceLabel: j['sourceLabel'] as String? ?? '',
    status: j['status'] as String? ?? '待检索',
    excerpt: j['excerpt'] as String? ?? '',
    patternSummary: j['patternSummary'] as String? ?? '',
    enabled: j['enabled'] as bool? ?? true,
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

/// 一篇：长篇小说的阶段性单元。
///
/// 一般一本书会拆成多篇，每篇默认准备 50 章。篇级设定用于承接全书主线，
/// 同时约束本篇主题、方向、核心冲突、重要配角和伏笔回收。
class BookVolume {
  BookVolume({
    required this.id,
    required this.title,
    this.theme = '',
    this.direction = '',
    this.summary = '',
    this.chapterCount = 50,
    List<BookCharacter>? characters,
    List<BookChapter>? chapters,
  }) : characters = characters ?? [],
       chapters = chapters ?? [];

  final String id;
  String title;

  /// 本篇主题，例如“成长代价”“信任崩塌”“第一次反攻”。
  String theme;

  /// 本篇创作方向：开局状态、阶段目标、核心冲突和结尾状态。
  String direction;

  /// 本篇梗概。生成章节大纲和正文时会作为篇级常驻上下文。
  String summary;

  /// 本篇计划章数。默认 50 章，但用户可以在 UI 中修改。
  int chapterCount;

  /// 本篇重点人物。这里不只放主角，也放反派、盟友、工具人、阶段性配角。
  List<BookCharacter> characters;

  /// 本篇章节。
  List<BookChapter> chapters;

  int get totalWords => chapters.fold(0, (s, c) => s + c.words);
  int get doneChapters => chapters.where((c) => c.hasContent).length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'theme': theme,
    'direction': direction,
    'summary': summary,
    'chapterCount': chapterCount,
    'characters': characters.map((c) => c.toJson()).toList(),
    'chapters': chapters.map((c) => c.toJson()).toList(),
  };

  factory BookVolume.fromJson(Map<String, dynamic> j) => BookVolume(
    id: j['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
    title: j['title'] as String? ?? '未命名篇',
    theme: j['theme'] as String? ?? '',
    direction: j['direction'] as String? ?? '',
    summary: j['summary'] as String? ?? '',
    chapterCount: (j['chapterCount'] as num?)?.toInt() ?? 50,
    characters: ((j['characters'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => BookCharacter.fromJson(e.cast<String, dynamic>()))
        .toList(),
    chapters: ((j['chapters'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => BookChapter.fromJson(e.cast<String, dynamic>()))
        .toList(),
  );
}

/// 一本书：项目元信息 + 故事圣经(设定集) + 篇/章大纲与正文。
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
    List<BookReference>? references,
    List<BookVolume>? volumes,
    List<BookChapter>? legacyChapters,
    required this.createdAt,
    required this.updatedAt,
  }) : characters = characters ?? [],
       references = references ?? [],
       volumes = (volumes != null && volumes.isNotEmpty)
           ? volumes
           : legacyChapters == null || legacyChapters.isEmpty
           ? <BookVolume>[]
           : [
               BookVolume(
                 id: 'legacy_${DateTime.now().microsecondsSinceEpoch}',
                 title: '第一篇',
                 theme: '旧版章节迁移',
                 direction: '由旧版扁平章节自动迁移，建议进入本篇后重新讨论主题和方向。',
                 summary: '旧版书稿没有篇级规划，这里临时承载原有章节。',
                 chapterCount: legacyChapters.length,
                 chapters: legacyChapters,
               ),
             ];

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
  List<BookReference> references;

  // —— 篇 / 章大纲与正文 ——
  List<BookVolume> volumes;

  final DateTime createdAt;
  DateTime updatedAt;

  bool get hasBible =>
      synopsis.trim().isNotEmpty ||
      worldview.trim().isNotEmpty ||
      characters.isNotEmpty;

  List<BookChapter> get chapters =>
      volumes.expand((volume) => volume.chapters).toList();
  int get totalChapters => volumes.fold(0, (s, v) => s + v.chapters.length);
  int get plannedChapters => volumes.fold(0, (s, v) => s + v.chapterCount);
  int get totalWords => volumes.fold(0, (s, v) => s + v.totalWords);
  int get doneChapters => volumes.fold(0, (s, v) => s + v.doneChapters);

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
    'references': references.map((r) => r.toJson()).toList(),
    'volumes': volumes.map((v) => v.toJson()).toList(),
    // 保留扁平 chapters 方便旧版本读取。新版本以 volumes 为准。
    'chapters': chapters.map((c) => c.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Book.fromJson(Map<String, dynamic> j) {
    final volumes = ((j['volumes'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => BookVolume.fromJson(e.cast<String, dynamic>()))
        .toList();
    final legacyChapters = ((j['chapters'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => BookChapter.fromJson(e.cast<String, dynamic>()))
        .toList();
    return Book(
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
      references: ((j['references'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => BookReference.fromJson(e.cast<String, dynamic>()))
          .where((r) => r.title.trim().isNotEmpty)
          .toList(),
      volumes: volumes,
      legacyChapters: legacyChapters,
      createdAt:
          DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt:
          DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }
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
  BookVolume? activeVolume;
  BookChapter? activeChapter;

  /// 正在生成（生成期间禁用相关操作）。
  bool busy = false;

  /// 当前进度提示。
  String stage = '';

  bool _cancel = false;
  File? _store;
  String _baseDir = '';

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
    activeVolume = null;
    activeChapter = null;
    notifyListeners();
    _persist();
    return book;
  }

  void openBook(Book book) {
    current = book;
    activeVolume = null;
    activeChapter = null;
    notifyListeners();
  }

  void closeBook() {
    current = null;
    activeVolume = null;
    activeChapter = null;
    notifyListeners();
  }

  void openVolume(BookVolume? volume) {
    activeVolume = volume;
    activeChapter = null;
    notifyListeners();
  }

  void openChapter(BookChapter? chapter) {
    if (chapter != null) {
      activeVolume = volumeOf(chapter);
    }
    activeChapter = chapter;
    notifyListeners();
  }

  BookVolume? volumeOf(BookChapter chapter) {
    final book = current;
    if (book == null) return null;
    for (final volume in book.volumes) {
      if (volume.chapters.contains(chapter)) return volume;
    }
    return null;
  }

  Future<void> deleteBook(Book book) async {
    books.remove(book);
    if (current == book) {
      current = null;
      activeVolume = null;
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

  BookReference addReference({
    required String title,
    String author = '',
    String note = '',
  }) {
    final book = current;
    if (book == null) throw StateError('未打开书籍');
    final ref = BookReference(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title.trim(),
      author: author.trim(),
      note: note.trim(),
      query: [title.trim(), author.trim()].where((e) => e.isNotEmpty).join(' '),
    );
    if (ref.title.isEmpty) throw ArgumentError('参考书名不能为空');
    book.references.add(ref);
    _touch();
    unawaited(_persist());
    return ref;
  }

  Future<void> removeReference(BookReference ref) async {
    final book = current;
    if (book == null) return;
    book.references.remove(ref);
    _touch();
    await _persist();
  }

  Future<void> toggleReference(BookReference ref, bool enabled) async {
    ref.enabled = enabled;
    _touch();
    await _persist();
  }

  Future<void> analyzeReference(BookReference ref) async {
    final book = current;
    if (book == null || busy) return;
    _begin('正在查找参考书《${ref.title}》…');
    try {
      ref.status = '检索中';
      notifyListeners();
      final collected = await _collectReferenceText(ref);
      if (collected == null || collected.$2.trim().isEmpty) {
        ref.status = '失败：未找到可读公开文本';
        _touch();
        await _persist();
        return;
      }
      ref.sourceUrl = collected.$1.url;
      ref.sourceLabel = collected.$1.source.label;
      ref.excerpt = _clipText(
        collected.$2.replaceAll(RegExp(r'\s+'), ' '),
        8000,
      );
      ref.status = collected.$3;
      stage = '正在总结《${ref.title}》的叙事套路…';
      notifyListeners();
      ref.patternSummary = await _summarizeReferencePattern(book, ref);
      if (ref.patternSummary.trim().isEmpty) {
        ref.status = '失败：未能总结套路';
      }
      _touch();
      await _persist();
      stage = '参考书套路已更新';
    } catch (e) {
      ref.status = _cancel ? '已停止' : '失败：$e';
      _touch();
      await _persist();
    } finally {
      _end();
    }
  }

  Future<(SourceResult, String, String)?> _collectReferenceText(
    BookReference ref,
  ) async {
    final query = ref.query.trim().isNotEmpty
        ? ref.query.trim()
        : [ref.title, ref.author].where((e) => e.trim().isNotEmpty).join(' ');
    final gutenberg = GutenbergAdapter();
    final gutenbergResults = await gutenberg.search(query, limit: 5);
    for (final result in gutenbergResults) {
      final text = await _readSourceText(result);
      if (text.trim().length >= 400) {
        return (result, text, '已找到公开全文');
      }
    }

    final webQueries = [
      '$query archive.org',
      '$query full text',
      '$query summary',
      '$query plot summary',
      '$query review',
    ];
    final web = HeadlessWebAdapter();
    for (final q in webQueries) {
      final results = await web.search(q, limit: 4);
      for (final result in results) {
        if (!_looksLikeAllowedReferencePage(result.url)) continue;
        final text = await _readSourceText(result);
        if (text.trim().length >= 300) {
          final fullText = result.ext == 'pdf' || result.ext == 'txt';
          return (result, text, fullText ? '已找到公开全文' : '只有摘要线索');
        }
      }
    }
    return null;
  }

  bool _looksLikeAllowedReferencePage(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('z-library') ||
        lower.contains('zlibrary') ||
        lower.contains('annas-archive') ||
        lower.contains('libgen') ||
        lower.contains('download-ebook')) {
      return false;
    }
    return true;
  }

  Future<String> _readSourceText(SourceResult result) async {
    if (result.ext == 'html') {
      final rendered = await HeadlessWebAdapter.renderDom(result.url);
      if (rendered != null && rendered.trim().isNotEmpty) {
        return _htmlToText(rendered);
      }
      final resp = await http
          .get(
            Uri.parse(result.url),
            headers: {'User-Agent': SourceAdapter.userAgent},
          )
          .timeout(const Duration(seconds: 25));
      if (resp.statusCode != 200) return '';
      return _htmlToText(utf8.decode(resp.bodyBytes, allowMalformed: true));
    }

    final bytes = await _downloadBytes(result.url);
    if (bytes == null) return '';
    if (result.ext == 'pdf') return _pdfText(bytes);
    if (result.ext == 'txt') {
      return utf8.decode(bytes, allowMalformed: true);
    }
    // EPUB 先登记线索，不做全文解析，避免误判压缩包内部版权/格式。
    return '';
  }

  Future<Uint8List?> _downloadBytes(String url) async {
    try {
      final resp = await http
          .get(Uri.parse(url), headers: {'User-Agent': SourceAdapter.userAgent})
          .timeout(const Duration(seconds: 35));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return null;
      return Uint8List.fromList(resp.bodyBytes);
    } catch (_) {
      return null;
    }
  }

  Future<String> _pdfText(
    Uint8List bytes, {
    int maxChars = 12000,
    int maxPages = 20,
  }) async {
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openData(
        bytes,
      ).timeout(const Duration(seconds: 20));
      final sb = StringBuffer();
      final count = doc.pages.length < maxPages ? doc.pages.length : maxPages;
      for (var i = 0; i < count; i++) {
        final text = await doc.pages[i].loadText();
        final fullText = text?.fullText.trim();
        if (fullText != null && fullText.isNotEmpty) {
          sb
            ..writeln('--- PDF 第 ${i + 1} 页 ---')
            ..writeln(fullText)
            ..writeln();
        }
        if (sb.length >= maxChars) break;
      }
      return _clipText(sb.toString().trim(), maxChars);
    } catch (_) {
      return '';
    } finally {
      await doc?.dispose();
    }
  }

  String _htmlToText(String html) {
    var text = html
        .replaceAll(
          RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'<[^>]+>'), ' ');
    text = SourceAdapter.unescapeXml(
      text,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    return _clipText(text, 12000);
  }

  Future<String> _summarizeReferencePattern(
    Book book,
    BookReference ref,
  ) async {
    final reply = await _chat([
      {
        'role': 'system',
        'content':
            '你是小说编辑和类型文学研究员。请只总结参考书的叙事技法，不复刻具体剧情、人名、设定或表达。输出中文 Markdown。',
      },
      {'role': 'user', 'content': _referencePatternPrompt(book, ref)},
    ]);
    return reply.trim();
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

  /// 手动保存篇设定。
  Future<void> saveVolume() async {
    _touch();
    await _persist();
  }

  List<BookCharacter> _charactersFromList(List<dynamic> list) => list
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
      if (chars.isNotEmpty) book.characters = _charactersFromList(chars);
    }
    _touch();
    await _persist();
  }

  Future<List<BookDiscussionQuestion>> discussBible(String userAnswer) async {
    final book = current;
    if (book == null || busy) return [];
    _begin('正在梳理需要确认的总体方向…');
    try {
      final reply = await _chat([
        {
          'role': 'system',
          'content':
              '你是长篇小说总策划。你要根据当前设定和用户补充，提出下一轮必须确认的问题。'
              '问题要具体，围绕总体方向、主线、人物群像、反派、配角池、篇章规模和长期伏笔。'
              '只输出 JSON，不要解释。',
        },
        {'role': 'user', 'content': _bibleDiscussionPrompt(book, userAnswer)},
      ], jsonMode: true);
      stage = '已生成待确认问题';
      return _discussionQuestionsFromReply(reply);
    } catch (e) {
      stage = _cancel ? '已停止' : '总体设定讨论失败：$e';
      return [];
    } finally {
      _end();
    }
  }

  Future<void> applyBibleDiscussion(String userAnswer) async {
    final book = current;
    if (book == null || busy) return;
    _begin('正在把讨论结果更新到故事设定集…');
    try {
      final reply = await _chat([
        {
          'role': 'system',
          'content':
              '你是资深小说编辑。请把用户对总体方向的回答合并进故事圣经。'
              '必须保留有用旧设定，并补强人物群像、反派、重要配角、阵营关系和长期成长线。只输出 JSON。',
        },
        {
          'role': 'user',
          'content': _applyBibleDiscussionPrompt(book, userAnswer),
        },
      ], jsonMode: true);
      final m = _parseJson(reply);
      if (m != null) {
        book.logline = (m['logline'] as String? ?? book.logline).trim();
        book.synopsis = (m['synopsis'] as String? ?? book.synopsis).trim();
        book.worldview = (m['worldview'] as String? ?? book.worldview).trim();
        final chars = (m['characters'] as List?) ?? [];
        if (chars.isNotEmpty) book.characters = _charactersFromList(chars);
      }
      _touch();
      await _persist();
      stage = '故事设定集已更新';
    } catch (e) {
      stage = _cancel ? '已停止' : '更新设定集失败：$e';
    } finally {
      _end();
    }
  }

  // ---------------------------------------------------------------------------
  // ③ 规划篇 / 生成篇内章节大纲
  // ---------------------------------------------------------------------------

  Future<void> generateVolumePlan() async {
    final book = current;
    if (book == null || busy) return;
    _begin('正在规划全书篇结构…');
    try {
      await _doVolumePlan(book);
    } catch (e) {
      stage = _cancel ? '已停止' : '生成篇规划失败：$e';
    } finally {
      _end();
    }
  }

  Future<void> _doVolumePlan(Book book) async {
    final reply = await _chat([
      {
        'role': 'system',
        'content':
            '你是资深长篇小说结构师。请把一本长篇拆成多篇，每篇有独立主题、阶段目标、核心冲突、配角配置和伏笔承接。只输出 JSON。',
      },
      {'role': 'user', 'content': _volumePlanPrompt(book)},
    ], jsonMode: true);
    final m = _parseJson(reply);
    final list = (m?['volumes'] as List?) ?? [];
    if (list.isEmpty) return;

    final existing = {for (final v in book.volumes) v.title: v};
    final next = <BookVolume>[];
    var i = 0;
    for (final item in list.whereType<Map>()) {
      i++;
      final title = (item['title'] ?? '第$i篇').toString().trim();
      final prev = existing[title];
      final chapterCount = (item['chapterCount'] as num?)?.toInt() ?? 50;
      final rawCharacters = item['characters'] as List?;
      next.add(
        BookVolume(
          id: prev?.id ?? '${DateTime.now().microsecondsSinceEpoch}_v$i',
          title: title.isEmpty ? '第$i篇' : title,
          theme: (item['theme'] ?? prev?.theme ?? '').toString().trim(),
          direction: (item['direction'] ?? prev?.direction ?? '')
              .toString()
              .trim(),
          summary: (item['summary'] ?? prev?.summary ?? '').toString().trim(),
          chapterCount: chapterCount <= 0 ? 50 : chapterCount,
          characters: rawCharacters == null
              ? (prev?.characters ?? [])
              : _charactersFromList(rawCharacters),
          chapters: prev?.chapters ?? [],
        ),
      );
    }
    book.volumes = next;
    activeVolume = book.volumes.isNotEmpty ? book.volumes.first : null;
    activeChapter = null;
    _touch();
    await _persist();
  }

  Future<void> generateOutline() async {
    final book = current;
    if (book == null || busy) return;
    _begin('正在规划当前篇章节大纲…');
    try {
      if (book.volumes.isEmpty) await _doVolumePlan(book);
      final volume =
          activeVolume ?? (book.volumes.isNotEmpty ? book.volumes.first : null);
      if (volume == null) {
        stage = '请先生成篇规划';
        return;
      }
      await _doVolumeOutline(book, volume);
    } catch (e) {
      stage = _cancel ? '已停止' : '生成大纲失败：$e';
    } finally {
      _end();
    }
  }

  Future<void> _doOutline(Book book) async {
    if (book.volumes.isEmpty) await _doVolumePlan(book);
    for (final volume in book.volumes) {
      if (_cancel) break;
      if (volume.chapters.isEmpty) await _doVolumeOutline(book, volume);
    }
  }

  Future<void> _doVolumeOutline(Book book, BookVolume volume) async {
    final reply = await _chat([
      {
        'role': 'system',
        'content':
            '你是资深小说结构师，擅长为长篇小说的单篇设计 50 章左右的大纲。'
            '每章必须服务本篇主题、人物变化和结尾钩子。只输出 JSON。',
      },
      {'role': 'user', 'content': _volumeOutlinePrompt(book, volume)},
    ], jsonMode: true);
    final m = _parseJson(reply);
    final list = (m?['chapters'] as List?) ?? [];
    if (list.isNotEmpty) {
      final existing = {for (final c in volume.chapters) c.title: c};
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
      volume.chapters = next;
    }
    activeVolume = volume;
    _touch();
    await _persist();
  }

  Future<List<BookDiscussionQuestion>> discussVolume(
    BookVolume volume,
    String userAnswer,
  ) async {
    final book = current;
    if (book == null || busy) return [];
    _begin('正在梳理本篇需要确认的问题…');
    try {
      final reply = await _chat([
        {
          'role': 'system',
          'content':
              '你是长篇小说分篇策划。请围绕当前篇，提出需要用户确认的问题。'
              '重点确认本篇主题、阶段目标、核心冲突、篇尾状态、主要配角和临时反派。'
              '只输出 JSON，不要解释。',
        },
        {
          'role': 'user',
          'content': _volumeDiscussionPrompt(book, volume, userAnswer),
        },
      ], jsonMode: true);
      stage = '已生成本篇待确认问题';
      return _discussionQuestionsFromReply(reply);
    } catch (e) {
      stage = _cancel ? '已停止' : '篇规划讨论失败：$e';
      return [];
    } finally {
      _end();
    }
  }

  Future<void> applyVolumeDiscussion(
    BookVolume volume,
    String userAnswer,
  ) async {
    final book = current;
    if (book == null || busy) return;
    _begin('正在把讨论结果更新到本篇规划…');
    try {
      final reply = await _chat([
        {
          'role': 'system',
          'content':
              '你是长篇小说分篇编辑。请把用户回答合并进当前篇规划，补强配角、反派、盟友、路人功能角色和人物关系。只输出 JSON。',
        },
        {
          'role': 'user',
          'content': _applyVolumeDiscussionPrompt(book, volume, userAnswer),
        },
      ], jsonMode: true);
      final m = _parseJson(reply);
      if (m != null) {
        volume.title = (m['title'] as String? ?? volume.title).trim();
        volume.theme = (m['theme'] as String? ?? volume.theme).trim();
        volume.direction = (m['direction'] as String? ?? volume.direction)
            .trim();
        volume.summary = (m['summary'] as String? ?? volume.summary).trim();
        final count = (m['chapterCount'] as num?)?.toInt();
        if (count != null && count > 0) volume.chapterCount = count;
        final chars = (m['characters'] as List?) ?? [];
        if (chars.isNotEmpty) volume.characters = _charactersFromList(chars);
      }
      _touch();
      await _persist();
      stage = '本篇规划已更新';
    } catch (e) {
      stage = _cancel ? '已停止' : '更新篇规划失败：$e';
    } finally {
      _end();
    }
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
    BookVolume? volume,
    String? progress,
  }) async {
    final chapterVolume = volume ?? volumeOf(chapter) ?? activeVolume;
    stage = '回忆相关设定与前情…';
    notifyListeners();
    final canon = await _recallCanon(book, chapter);
    final tag = progress == null ? '' : '（$progress）';
    stage = '正在创作《${chapter.title}》$tag…';
    notifyListeners();
    final acc = await _streamChapter(
      chapter,
      system: _novelistSystem,
      user: _chapterPrompt(book, chapter, canon, chapterVolume),
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
      if (book.volumes.isEmpty) {
        stage = '规划全书篇结构…';
        notifyListeners();
        await _doVolumePlan(book);
      }
      if (_cancel) return;
      if (book.volumes.any((volume) => volume.chapters.isEmpty)) {
        stage = '按篇规划章节大纲…';
        notifyListeners();
        await _doOutline(book);
      }
      final total = book.totalChapters;
      if (total == 0) {
        stage = '未能生成章节大纲，请先生成篇规划和篇内大纲';
        return;
      }
      var doneIndex = 0;
      for (final volume in book.volumes) {
        if (_cancel) break;
        activeVolume = volume;
        for (final ch in volume.chapters) {
          doneIndex++;
          if (_cancel) break;
          if (ch.hasContent) continue; // 断点续写：跳过已完成章节
          activeChapter = ch; // 让编辑器跟随当前正在写的章节
          notifyListeners();
          await _composeChapter(
            book,
            ch,
            volume: volume,
            progress: '$doneIndex/$total · ${volume.title}',
          );
        }
      }
      stage = _cancel
          ? '已停止（已完成 ${book.doneChapters}/$total 章）'
          : '🎉 全本完成：${book.doneChapters}/$total 章，约 ${book.totalWords} 字';
    } catch (e) {
      stage = _cancel
          ? '已停止（已完成 ${book.doneChapters}/${book.totalChapters} 章）'
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
      final volume = volumeOf(chapter) ?? activeVolume;
      stage = '正在续写《${chapter.title}》…';
      notifyListeners();
      final acc = await _streamChapter(
        chapter,
        system:
            '你是一位优秀的小说家。请紧接给定的"已有正文"自然地继续往下写，'
            '保持人物口吻、文风与时态一致。只输出新增的后续正文，不要重复已有内容、不要解释。',
        user: _continuePrompt(book, chapter, canon, volume),
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
    await ModelClient(settings, role: ModelRole.writing).streamWithRetry(
      messages: [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      onTextDelta: (delta) {
        acc += delta;
        chapter.content = replace ? acc : '$base\n\n$acc';
        notifyListeners();
      },
      isCancelled: () => _cancel,
      idleTimeout: const Duration(seconds: 90),
      onAttempt: (attempt) {
        acc = '';
        chapter.content = replace ? '' : base;
        stage = '网络中断，正在重试（${attempt - 1}/3）…';
        notifyListeners();
      },
    );
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
        '- 字数：约 ${book.totalWords} 字 · ${book.doneChapters}/${book.totalChapters} 章 · ${book.volumes.length} 篇',
      )
      ..writeln();
    for (final volume in book.volumes) {
      final written = volume.chapters.where((c) => c.hasContent).toList();
      if (written.isEmpty) continue;
      buf
        ..writeln('## ${volume.title}')
        ..writeln();
      if (volume.theme.isNotEmpty) buf.writeln('> 主题：${volume.theme}\n');
      for (final c in written) {
        buf
          ..writeln('### ${c.title}')
          ..writeln()
          ..writeln(c.content.trim())
          ..writeln();
      }
    }
    final dir = Directory(p.join(settings.vaultPath, '4-书稿'));
    await dir.create(recursive: true);
    final file = File(
      p.join(dir.path, '${sanitizeFileName(book.title, fallback: '未命名书稿')}.md'),
    );
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

  String _referencePatternPrompt(Book book, BookReference ref) =>
      '''
请阅读下面的参考资料摘录，提炼可借鉴的叙事套路。

用户自己的作品：
${_meta(book)}

参考书：
- 书名：${ref.title}
- 作者：${ref.author.isEmpty ? '未知' : ref.author}
- 用户备注：${ref.note.isEmpty ? '无' : ref.note}
- 资料来源：${ref.sourceLabel.isEmpty ? '公开网页或公版资源' : ref.sourceLabel}

资料摘录：
${ref.excerpt}

请输出 Markdown，包含这些小节：
1. 情节结构
2. 人物原型与关系
3. 冲突升级方式
4. 章节/篇章钩子
5. 节奏与爽点
6. 可迁移到《${book.title}》的写作策略

硬性限制：
- 只总结技法、结构、节奏和人物功能。
- 不复制原书具体剧情、设定、人名、专有名词和表达。
- 如果资料只是摘要或线索，请明确说明结论可信度较低。''';

  String _referenceBrief(Book b, {bool compact = false}) {
    final refs = b.references.where((r) => r.enabled && r.hasPattern).toList();
    if (refs.isEmpty) return '';
    final sb = StringBuffer()..writeln('参考书套路（只借鉴技法，不复制剧情、设定、人名或具体表达）：');
    for (final ref in refs) {
      sb
        ..writeln()
        ..writeln(
          '### ${ref.title}${ref.author.isEmpty ? '' : ' / ${ref.author}'}',
        )
        ..writeln('状态：${ref.status}');
      if (compact) {
        sb.writeln(_clipText(ref.patternSummary, 700));
      } else {
        sb.writeln(ref.patternSummary);
      }
    }
    return sb.toString().trim();
  }

  String _biblePrompt(Book b) =>
      '''
请基于下面的作品立项信息，搭建一套自洽、有张力的"故事圣经"。

${_meta(b)}

${_referenceBrief(b)}

要求：
- logline：一句话概括全书核心冲突与卖点（不超过60字）。
- synopsis：500~900字的故事大纲，交代主线、核心冲突、阶段转折与结局走向。
- worldview：世界观/背景设定（时代、规则、关键设定），300~600字。
- characters：12~20个人物，不只写主人物；必须包含主角团、反派、导师/盟友、竞争者、功能性配角、阶段性配角。
- 每个人物说明其目标、欲望、弱点、与主线关系、与其他角色的冲突或情感连接。

严格输出 JSON：
{"logline":"...","synopsis":"...","worldview":"...","characters":[{"name":"...","role":"...","description":"..."}]}''';

  String _bibleDiscussionPrompt(Book b, String userAnswer) =>
      '''
请基于当前作品设定和用户补充，提出下一轮最需要确认的问题。

${_meta(b)}

当前故事圣经：
${_bibleBrief(b).trim().isEmpty ? '(空)' : _bibleBrief(b)}

${_referenceBrief(b, compact: true)}

用户刚补充：
${userAnswer.trim().isEmpty ? '(用户还未补充，请先主动提出关键问题)' : userAnswer.trim()}

请输出 5~8 个选择题，覆盖：
- 总体方向与核心爽点/情绪价值。
- 主线目标与终局形态。
- 主角团、反派、重要配角的数量和关系。
- 每篇大约 50 章时，前几篇应该承担什么阶段任务。
- 哪些设定必须避免，哪些桥段必须强化。

严格输出 JSON：
{"questions":[{"prompt":"问题","options":["选项A","选项B","选项C","选项D"]}]}

要求：
- 每题给 4~6 个具体选项，用户可以多选。
- 不要把“其他/自己输入”写进 options，界面会自动提供最后的自定义输入选项。
- 选项必须具体、有取舍价值，不能写成“都可以”。''';

  String _applyBibleDiscussionPrompt(Book b, String userAnswer) =>
      '''
请把用户回答合并到故事圣经中，保留旧设定中有价值的部分，删除互相矛盾的部分。

${_meta(b)}

旧故事圣经：
${_bibleBrief(b).trim().isEmpty ? '(空)' : _bibleBrief(b)}

${_referenceBrief(b)}

用户回答：
${userAnswer.trim()}

严格输出 JSON：
{"logline":"...","synopsis":"...","worldview":"...","characters":[{"name":"...","role":"...","description":"..."}]}

要求：
- characters 至少 12 个，不能只有主人公。
- 必须有主角团、反派、盟友、竞争者、阶段性配角、功能性配角。
- description 写清目标、性格、秘密、关系、成长/退场方向。''';

  String _volumePlanPrompt(Book b) {
    final target = b.targetChapters <= 0 ? 200 : b.targetChapters;
    final volumeCount = (target / 50).ceil().clamp(1, 20);
    return '''
请把这本长篇拆成 $volumeCount 篇。每篇默认 50 章左右。

${_meta(b)}

故事圣经：
${_bibleBrief(b)}

${_referenceBrief(b)}

要求：
- 每篇都要有 title、theme、direction、summary、chapterCount、characters。
- chapterCount 默认 50；如果为了结构需要，可在 40~60 间调整。
- direction 写清本篇开局状态、阶段目标、核心冲突、篇尾状态。
- characters 不只写主角，必须准备本篇会大量使用的配角、反派、盟友、竞争者、工具人、路人功能角色。
- 各篇之间要承接伏笔，不能每篇像独立短篇。

严格输出 JSON：
{"volumes":[{"title":"...","theme":"...","direction":"...","summary":"...","chapterCount":50,"characters":[{"name":"...","role":"...","description":"..."}]}]}''';
  }

  String _volumeBrief(BookVolume? volume) {
    if (volume == null) return '';
    final sb = StringBuffer()
      ..writeln('当前篇：${volume.title}')
      ..writeln('篇主题：${volume.theme.isEmpty ? '（待定）' : volume.theme}')
      ..writeln('篇方向：${volume.direction.isEmpty ? '（待定）' : volume.direction}')
      ..writeln('篇梗概：${volume.summary.isEmpty ? '（待定）' : volume.summary}')
      ..writeln('计划章数：${volume.chapterCount}');
    if (volume.characters.isNotEmpty) {
      sb.writeln('篇人物与配角：');
      for (final c in volume.characters) {
        sb.writeln('- ${c.name}（${c.role}）：${c.description}');
      }
    }
    return sb.toString();
  }

  String _volumeDiscussionPrompt(
    Book b,
    BookVolume volume,
    String userAnswer,
  ) =>
      '''
请基于全书设定、当前篇规划和用户补充，提出本篇继续完善的问题。

全书设定：
${_bibleBrief(b)}

${_referenceBrief(b, compact: true)}

当前篇规划：
${_volumeBrief(volume)}

用户刚补充：
${userAnswer.trim().isEmpty ? '(用户还未补充，请先主动提出关键问题)' : userAnswer.trim()}

请输出 5~8 个选择题，覆盖：
- 本篇主题和情绪曲线。
- 本篇 50 章左右的阶段目标和篇尾状态。
- 本篇需要哪些配角、反派、盟友、竞争者、路人功能角色。
- 哪些人物要登场、退场、反转或关系变化。
- 本篇要埋下/回收哪些伏笔。

严格输出 JSON：
{"questions":[{"prompt":"问题","options":["选项A","选项B","选项C","选项D"]}]}

要求：
- 每题给 4~6 个具体选项，用户可以多选。
- 不要把“其他/自己输入”写进 options，界面会自动提供最后的自定义输入选项。
- 选项必须能直接帮助确定本篇主题、配角、冲突、伏笔或篇尾状态。''';

  String _applyVolumeDiscussionPrompt(
    Book b,
    BookVolume volume,
    String userAnswer,
  ) =>
      '''
请把用户回答合并进当前篇规划。

全书设定：
${_bibleBrief(b)}

${_referenceBrief(b)}

旧篇规划：
${_volumeBrief(volume)}

用户回答：
${userAnswer.trim()}

严格输出 JSON：
{"title":"...","theme":"...","direction":"...","summary":"...","chapterCount":50,"characters":[{"name":"...","role":"...","description":"..."}]}

要求：
- chapterCount 默认 50，可按需要保持旧值。
- characters 至少 10 个，必须有多个配角，不得只列主人公。
- description 写清这个角色在本篇承担的戏剧功能、与主线关系、与其他角色的冲突或合作。''';

  String _volumeOutlinePrompt(Book b, BookVolume volume) =>
      '''
请为《${b.title}》的「${volume.title}」设计 ${volume.chapterCount} 章章节大纲。

全书设定：
${_meta(b)}
${_bibleBrief(b)}

${_referenceBrief(b)}

当前篇设定：
${_volumeBrief(volume)}

要求：
- 只规划当前篇，不要把后续篇的高潮提前写完。
- 每章包含 title 与 summary。
- summary 写清本章目标、冲突、主要出场人物、结尾钩子，60~140字。
- 章节之间要有推进链条：信息、关系、行动和代价逐步升级。
- 充分使用本篇配角，让配角承担推动、误导、阻碍、牺牲、反转等功能。

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

  String _chapterPrompt(
    Book b,
    BookChapter ch,
    String canon,
    BookVolume? volume,
  ) {
    final idx = b.chapters.indexOf(ch);
    final volumeChapters = volume?.chapters ?? b.chapters;
    final volumeIdx = volumeChapters.indexOf(ch);
    final outline = StringBuffer();
    for (var i = 0; i < volumeChapters.length; i++) {
      final c = volumeChapters[i];
      final mark = identical(c, ch) ? '▶ ' : '  ';
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
你正在创作《${b.title}》${volume == null ? '' : '「${volume.title}」'}的第 ${idx + 1} 章：${ch.title}。

== 作品设定 ==
${_meta(b)}
${_bibleBrief(b)}
${_referenceBrief(b, compact: true)}
${volume == null ? '' : '''

== 当前篇设定（本章必须服务本篇主题和方向）==
${_volumeBrief(volume)}'''}
${b.storyState.trim().isEmpty ? '' : '''

== 前情提要与当前状态（务必延续，不要遗忘或矛盾）==
${b.storyState.trim()}'''}
${canon.trim().isEmpty ? '' : '''

== 与本章相关的已确立设定（务必保持一致）==
${canon.trim()}'''}
${recent.isEmpty ? '' : '''

== 最近几章已写情节（避免重复其场景、桥段与描写）==
$recent'''}

== 当前篇大纲（▶ 为当前章）==
${outline.toString().trim()}
${prevTail.isEmpty ? '' : '\n== 上一章结尾（衔接用，勿重复）==\n$prevTail\n'}
== 本章要写的内容 ==
${ch.summary.isEmpty ? '（按大纲推进本章情节）' : ch.summary}

要求：
- 目标篇幅约 ${b.targetWordsPerChapter} 字，紧扣本章 beat，并与上一章自然衔接。
- 本章是当前篇第 ${volumeIdx < 0 ? '?' : volumeIdx + 1} 章，必须推动当前篇主题、阶段目标和人物关系变化。
- 严格延续「前情提要」与「已确立设定」，不得与之矛盾，不得遗忘已发生的事。
- 不要重复前文已写过的场景、桥段与描写；推动情节向前发展。
- 用具体场景、动作与对白推进，避免空洞概述。
- 直接输出本章正文（Markdown 段落），不要写章节标题、不要任何解释。''';
  }

  String _continuePrompt(
    Book b,
    BookChapter ch,
    String canon,
    BookVolume? volume,
  ) {
    final idx = b.chapters.indexOf(ch);
    final t = ch.content.trim();
    final tail = t.length > 1500 ? t.substring(t.length - 1500) : t;
    return '''
你正在续写《${b.title}》第 ${idx + 1} 章：${ch.title}。

== 作品设定 ==
${_bibleBrief(b)}
${_referenceBrief(b, compact: true)}
${volume == null ? '' : '''

== 当前篇设定 ==
${_volumeBrief(volume)}'''}
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
    notifyListeners();
  }

  /// 容错版 JSON 提取：复用 [ModelClient.parseJsonObject]，解析失败返回 null。
  Map<String, dynamic>? _parseJson(String reply) {
    try {
      return ModelClient.parseJsonObject(reply);
    } catch (_) {
      return null;
    }
  }

  List<BookDiscussionQuestion> _discussionQuestionsFromReply(String reply) {
    final m = _parseJson(reply);
    final list = (m?['questions'] as List?) ?? [];
    return list
        .whereType<Map>()
        .map((e) => BookDiscussionQuestion.fromJson(e.cast<String, dynamic>()))
        .where((q) => q.prompt.isNotEmpty && q.options.isNotEmpty)
        .toList();
  }

  /// 写作类一次性调用：统一走 [ModelClient] 的 writing 角色通道。
  Future<String> _chat(
    List<Map<String, String>> messages, {
    bool jsonMode = false,
  }) {
    return ModelClient(settings, role: ModelRole.writing).complete(
      messages: messages,
      jsonMode: jsonMode,
      isCancelled: () => _cancel,
    );
  }

  static String _clipText(String text, int maxChars) => clip(
        text.trim(),
        maxChars,
        suffix: '\n\n（已截断，仅保留前 $maxChars 字用于分析。）',
      );
}
