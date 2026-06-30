import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../services/pro_book_service.dart';

// 统一配色，和写作其它页保持一致。
const _accent = Color(0xFF0D9488);
const _ink = Color(0xFF2F2F33);
const _sub = Color(0xFF6B6B70);
const _muted = Color(0xFF9B9B9F);
const _panel = Color(0xFFF7F7F8);

/// 「专业书籍」页：书架 + 阶段式编辑器（立项 → 大纲 → 资料 → 成文 → 审校 → 导出）。
class ProBookPage extends StatefulWidget {
  const ProBookPage({super.key, required this.service});

  final ProBookService service;

  @override
  State<ProBookPage> createState() => _ProBookPageState();
}

class _ProBookPageState extends State<ProBookPage> {
  /// 右侧面板视图：0=正文 1=立项 2=资料 3=审校。
  int _view = 0;

  // 正文编辑控制器（按小节切换重新填充）。
  final _contentCtrl = TextEditingController();
  String? _contentSectionId;

  /// 正文区是否处于编辑模式（false=按教材排版预览，true=编辑 Markdown 源码）。
  bool _editing = false;

  // 立项编辑控制器（按书切换重新填充）。
  final _topicCtrl = TextEditingController();
  final _readerCtrl = TextEditingController();
  final _valueCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  String? _kickoffBookId;

  @override
  void dispose() {
    _contentCtrl.dispose();
    _topicCtrl.dispose();
    _readerCtrl.dispose();
    _valueCtrl.dispose();
    _titleCtrl.dispose();
    super.dispose();
  }

  /// Markdown 图片渲染：支持 file:// 本地图片与 http(s) 网络图片。
  Widget _mdImage(Uri uri, String? title, String? alt) {
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Image.network(uri.toString(), fit: BoxFit.contain),
      );
    }
    final path = uri.scheme == 'file'
        ? uri.toFilePath(windows: Platform.isWindows)
        : uri.toString();
    final file = File(path);
    if (file.existsSync()) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Image.file(file, fit: BoxFit.contain),
      );
    }
    return Text(
      '[图片缺失：${alt ?? ''}]',
      style: const TextStyle(color: _muted, fontSize: 12),
    );
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

  Widget _buildShelf(ProBookService svc) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '专业书籍',
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
            '面向科技、档案行业的专业书写作：先立项（选题/读者/核心价值），再生成结构化大纲，'
            '梳理资料与标准，逐节成文，最后审校术语一致性并导出。',
            style: TextStyle(fontSize: 13, color: _sub),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: svc.books.isEmpty
                ? const Center(
                    child: Text(
                      '还没有专业书籍，点击右上角「新建书籍」开始',
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

  Widget _bookCard(ProBookService svc, ProBook book) {
    return Material(
      color: _panel,
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
                  const Icon(Icons.menu_book_outlined, size: 18, color: _accent),
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
                  IconButton(
                    tooltip: '删除',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    onPressed: () => _confirmDelete(svc, book),
                    icon: const Icon(Icons.close, color: _muted),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  book.valueProposition.isNotEmpty
                      ? book.valueProposition
                      : (book.topic.isNotEmpty ? book.topic : '（暂无简介）'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, height: 1.5, color: _sub),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _chip(book.industry.label),
                  const SizedBox(width: 6),
                  _chip(book.bookType.label),
                  const Spacer(),
                  Text(
                    '${book.doneSections}/${book.totalSections} 节',
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

  Future<void> _confirmDelete(ProBookService svc, ProBook book) async {
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

  Future<void> _newBook(ProBookService svc) async {
    final title = TextEditingController();
    final audience = TextEditingController();
    final topic = TextEditingController();
    var industry = ProIndustry.tech;
    var bookType = ProBookType.textbook;

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('新建专业书籍'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _field(title, '书名 *', '例如：数字档案馆建设实务'),
                  const SizedBox(height: 12),
                  const Text('行业', style: TextStyle(fontSize: 12.5, color: _sub)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final v in ProIndustry.values)
                        ChoiceChip(
                          label: Text(v.label),
                          selected: industry == v,
                          onSelected: (_) => setLocal(() => industry = v),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('书籍类型', style: TextStyle(fontSize: 12.5, color: _sub)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final v in ProBookType.values)
                        ChoiceChip(
                          label: Text(v.label),
                          selected: bookType == v,
                          onSelected: (_) => setLocal(() => bookType = v),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _field(audience, '目标读者', '例如：档案馆一线业务人员'),
                  _field(topic, '选题（可留空）', '一句话说清这本书要解决什么', maxLines: 3),
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
                if (title.text.trim().isEmpty) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );

    if (created == true) {
      svc.createBook(
        title: title.text,
        industry: industry,
        bookType: bookType,
        audience: audience.text,
        topic: topic.text,
      );
      setState(() => _view = 1); // 新书先进入「立项」
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

  Widget _buildWorkspace(ProBookService svc) {
    final book = svc.current!;
    if (_kickoffBookId != book.id) {
      _kickoffBookId = book.id;
      _topicCtrl.text = book.topic;
      _readerCtrl.text = book.readerPositioning;
      _valueCtrl.text = book.valueProposition;
      _titleCtrl.text = book.title;
    }
    return Column(
      children: [
        _topBar(svc, book),
        _workflowBar(svc, book),
        const Divider(height: 1, color: Color(0xFFECECEE)),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 300, child: _outlinePanel(svc, book)),
              const VerticalDivider(width: 1, color: Color(0xFFECECEE)),
              Expanded(child: _rightPanel(svc, book)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _topBar(ProBookService svc, ProBook book) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      color: Colors.white,
      child: Row(
        children: [
          IconButton(
            tooltip: '返回书架',
            onPressed: svc.busy ? null : svc.closeBook,
            icon: const Icon(Icons.arrow_back, size: 18),
          ),
          SizedBox(
            width: 280,
            child: TextField(
              controller: _titleCtrl,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '书名',
              ),
              onChanged: (v) => book.title = v.trim().isEmpty ? '未命名' : v.trim(),
              onEditingComplete: svc.save,
              onTapOutside: (_) => svc.save(),
            ),
          ),
          const SizedBox(width: 8),
          _chip(book.industry.label),
          const SizedBox(width: 6),
          _chip(book.bookType.label),
          const SizedBox(width: 12),
          if (svc.busy)
            Expanded(
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      svc.stage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: _sub),
                    ),
                  ),
                  TextButton(onPressed: svc.cancel, child: const Text('停止')),
                ],
              ),
            )
          else ...[
            Expanded(
              child: Text(
                svc.stage.isEmpty
                    ? '${book.doneSections}/${book.totalSections} 节 · 约 ${book.totalWords} 字'
                    : svc.stage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: _muted),
              ),
            ),
            TextButton.icon(
              onPressed: () => _openReader(book),
              icon: const Icon(Icons.menu_book_outlined, size: 16),
              label: const Text('阅读全书'),
            ),
            TextButton.icon(
              onPressed: () => _openPlaceholderLocator(svc),
              icon: const Icon(Icons.image_outlined, size: 16),
              label: Text('图表待补 (${svc.placeholders().length})'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () => _doExport(svc),
              style: FilledButton.styleFrom(backgroundColor: _accent),
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
              label: const Text('导出 PDF'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _doExport(ProBookService svc) async {
    _toast('正在按出书规范生成 PDF（首次编译可能较慢）…');
    try {
      final path = await svc.export();
      if (mounted) _toast('已导出 PDF：$path');
    } catch (e) {
      if (mounted) _toast('导出失败：$e');
    }
  }

  /// 「阅读全书」：把整本书拼成连续的教材排版页面，供通读。
  void _openReader(ProBook book) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFFECECEE))),
              ),
              child: Row(
                children: [
                  const Icon(Icons.menu_book_outlined, size: 18, color: _accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      book.title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(40, 28, 40, 48),
                    child: MarkdownBody(
                      data: _wholeBookMarkdown(book),
                      styleSheet: _textbookStyle(context),
                      imageBuilder: _mdImage,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _wholeBookMarkdown(ProBook book) {
    final buf = StringBuffer();
    for (final chapter in book.chapters) {
      buf
        ..writeln('# ${chapter.title}')
        ..writeln();
      for (final section in chapter.sections) {
        buf
          ..writeln('## ${section.title}')
          ..writeln();
        final content = _stripDupHeading(section.content, section.title);
        buf
          ..writeln(content.trim().isEmpty ? '（待撰写）' : content.trim())
          ..writeln();
      }
    }
    return buf.toString();
  }

  /// 去掉正文开头与小节标题重复的那行标题（模型常会重复一遍）。
  String _stripDupHeading(String content, String title) {
    final lines = content.replaceAll('\r\n', '\n').split('\n');
    final norm = title.replaceAll(RegExp(r'\s'), '');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().isEmpty) continue;
      final h = RegExp(r'^#{1,6}\s+(.*)').firstMatch(lines[i].trim());
      if (h != null && h.group(1)!.replaceAll(RegExp(r'\s'), '') == norm) {
        lines.removeAt(i);
      }
      break;
    }
    return lines.join('\n');
  }

  /// 「图表待补」：列出全书所有图/表占位符，点击跳转到对应小节。
  void _openPlaceholderLocator(ProBookService svc) {
    final items = svc.placeholders();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('待补充的图 / 表（${items.length}）'),
        content: SizedBox(
          width: 520,
          child: items.isEmpty
              ? const Text(
                  '暂无图表占位符。生成正文时，AI 会在需要图表处自动预留占位符。',
                  style: TextStyle(fontSize: 13, color: _sub),
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final ph = items[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          ph.isFigure
                              ? Icons.image_outlined
                              : Icons.table_chart_outlined,
                          size: 18,
                          color: _accent,
                        ),
                        title: Text(
                          ph.description.isEmpty
                              ? (ph.isFigure ? '（待补充图）' : '（待补充表）')
                              : ph.description,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                        subtitle: Text(
                          '${ph.chapter.title} › ${ph.section.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, color: _muted),
                        ),
                        trailing: TextButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            svc.openSection(ph.section);
                            setState(() => _view = 0);
                            _openFillMenu(svc, ph);
                          },
                          icon: const Icon(Icons.auto_fix_high_outlined, size: 15),
                          label: const Text('补全'),
                        ),
                        onTap: () {
                          svc.openSection(ph.section);
                          setState(() => _view = 0);
                          Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
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

  /// 补全菜单：表只有「AI 生成表格」；图可选「AI 图表代码 / AI 文生图 / 上传图片」。
  void _openFillMenu(ProBookService svc, ProPlaceholder ph) {
    final imgReady = svc.settings.imageGenReady;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ph.isFigure ? '补充图' : '补充表'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              ph.description.isEmpty ? '（无描述）' : ph.description,
              style: const TextStyle(fontSize: 12.5, color: _sub),
            ),
            const SizedBox(height: 16),
            if (!ph.isFigure)
              _fillOption(
                icon: Icons.table_chart_outlined,
                title: 'AI 生成表格',
                desc: '根据本节上下文自动生成 Markdown 表格',
                onTap: () {
                  Navigator.pop(ctx);
                  _runFill(svc, () => svc.fillTable(ph));
                },
              )
            else ...[
              _fillOption(
                icon: Icons.account_tree_outlined,
                title: 'AI 图表代码',
                desc: '生成流程/结构图（Mermaid），在线渲染成图片',
                onTap: () {
                  Navigator.pop(ctx);
                  _runFill(svc, () => svc.fillDiagram(ph));
                },
              ),
              const SizedBox(height: 8),
              _fillOption(
                icon: Icons.auto_awesome_outlined,
                title: 'AI 文生图',
                desc: imgReady ? '用图像模型生成插图' : '需先在「设置 → 图像模型」里配置',
                enabled: imgReady,
                onTap: () {
                  Navigator.pop(ctx);
                  _runFill(svc, () => svc.fillTextToImage(ph));
                },
              ),
              const SizedBox(height: 8),
              _fillOption(
                icon: Icons.upload_file_outlined,
                title: '上传图片',
                desc: '从本地选择一张图片插入',
                onTap: () async {
                  Navigator.pop(ctx);
                  final res = await FilePicker.pickFiles(
                    type: FileType.image,
                  );
                  final path = res?.files.single.path;
                  if (path != null) {
                    await _runFill(svc, () => svc.fillUploadImage(ph, path));
                  }
                },
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _fillOption({
    required IconData icon,
    required String title,
    required String desc,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE6E6E9)),
          color: enabled ? Colors.white : const Color(0xFFF5F5F7),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: enabled ? _accent : _muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: enabled ? _ink : _muted,
                    ),
                  ),
                  Text(
                    desc,
                    style: const TextStyle(fontSize: 11.5, color: _muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 执行一次补全：调用 service 方法，结束后把结果提示给用户。
  Future<void> _runFill(ProBookService svc, Future<void> Function() run) async {
    await run();
    if (mounted) _toast(svc.stage);
  }

  /// 工作流动作条：立项 → 大纲 → 资料 → 成文 → 审校。
  Widget _workflowBar(ProBookService svc, ProBook book) {
    final busy = svc.busy;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          _stageBtn('① 立项分析', Icons.flag_outlined, busy ? null : () {
            setState(() => _view = 1);
            _runKickoff(svc);
          }),
          _stageBtn('② 生成大纲', Icons.account_tree_outlined, busy ? null : () {
            setState(() => _view = 0);
            svc.generateOutline();
          }),
          _stageBtn('③ 资料建议', Icons.library_books_outlined, busy ? null : () {
            setState(() => _view = 2);
            svc.suggestReferences();
          }),
          _stageBtn('④ 一键成文', Icons.edit_note_outlined, busy ? null : () {
            setState(() => _view = 0);
            svc.writeAll();
          }),
          _stageBtn('⑤ 审校', Icons.fact_check_outlined, busy ? null : () {
            setState(() => _view = 3);
            svc.review();
          }),
          _stageBtn('⑥ 修订', Icons.auto_fix_high_outlined, busy ? null : () {
            setState(() => _view = 0); // 修订后回到正文查看效果
            svc.revise();
          }),
        ],
      ),
    );
  }

  Widget _stageBtn(String label, IconData icon, VoidCallback? onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: _ink,
        side: const BorderSide(color: Color(0xFFD9D9DE)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      icon: Icon(icon, size: 15, color: _accent),
      label: Text(label, style: const TextStyle(fontSize: 12.5)),
    );
  }

  // ---------------- 左侧：大纲导航 ----------------

  Widget _outlinePanel(ProBookService svc, ProBook book) {
    return Container(
      color: _panel,
      child: book.chapters.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  '还没有大纲。\n点击上方「生成大纲」。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: _muted),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final chapter in book.chapters) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 12, 4),
                    child: Text(
                      chapter.title,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: _ink,
                      ),
                    ),
                  ),
                  for (final section in chapter.sections)
                    _sectionTile(svc, section),
                ],
              ],
            ),
    );
  }

  Widget _sectionTile(ProBookService svc, ProSection section) {
    final selected = svc.activeSection == section;
    return Material(
      color: selected ? const Color(0xFFE8F5F3) : Colors.transparent,
      child: InkWell(
        onTap: () {
          svc.openSection(section);
          setState(() => _view = 0);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 7, 12, 7),
          child: Row(
            children: [
              Icon(
                section.hasContent
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                size: 13,
                color: section.hasContent ? _accent : const Color(0xFFCDCDD2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  section.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    color: selected ? _accent : _ink,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 右侧：视图选择 + 内容 ----------------

  Widget _rightPanel(ProBookService svc, ProBook book) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SegmentedButton<int>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: 0, label: Text('正文')),
              ButtonSegment(value: 1, label: Text('立项')),
              ButtonSegment(value: 2, label: Text('资料')),
              ButtonSegment(value: 3, label: Text('审校')),
            ],
            selected: {_view},
            onSelectionChanged: (v) => setState(() => _view = v.first),
          ),
        ),
        Expanded(
          child: switch (_view) {
            1 => _kickoffView(svc, book),
            2 => _referencesView(svc, book),
            3 => _reviewView(svc, book),
            _ => _contentView(svc, book),
          },
        ),
      ],
    );
  }

  // 正文：编辑当前小节
  Widget _contentView(ProBookService svc, ProBook book) {
    final section = svc.activeSection;
    if (section == null) {
      return const Center(
        child: Text(
          '在左侧选择一个小节开始写作',
          style: TextStyle(fontSize: 13, color: _muted),
        ),
      );
    }
    // 非生成状态下，按小节切换重新填充编辑框。
    if (!svc.busy && _contentSectionId != section.id) {
      _contentSectionId = section.id;
      _contentCtrl.text = section.content;
    }
    // 生成中强制走预览（实时按教材排版显示），不显示可编辑框。
    final showEditor = _editing && !svc.busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  section.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // 预览（按教材排版）/ 编辑（Markdown 源码）切换。
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
                        // 切到编辑时，把最新正文灌进输入框。
                        if (edit) _contentCtrl.text = section.content;
                        setState(() => _editing = edit);
                      },
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: svc.busy ? null : () => svc.writeSection(section),
                icon: const Icon(Icons.auto_awesome, size: 15),
                label: Text(section.hasContent ? '重写本节' : '写本节'),
              ),
            ],
          ),
          if (section.brief.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '要点：${section.brief}',
                style: const TextStyle(fontSize: 12, color: _sub),
              ),
            ),
          Expanded(
            child: showEditor
                ? TextField(
                    controller: _contentCtrl,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(fontSize: 13.5, height: 1.6),
                    decoration: const InputDecoration(
                      hintText: '本节正文 Markdown 源码…（可手动编辑，或点击「写本节」由 AI 生成）',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(12),
                    ),
                    onChanged: (v) => section.content = v,
                    onTapOutside: (_) => svc.save(),
                  )
                : _textbookPreview(svc, section),
          ),
        ],
      ),
    );
  }

  /// 正文预览：按标准教材排版渲染 Markdown（宋体正文、黑体标题、合适字号行距）。
  Widget _textbookPreview(ProBookService svc, ProSection section) {
    if (section.content.trim().isEmpty) {
      return Center(
        child: Text(
          svc.busy ? '生成中…' : '本节还没有内容，点击右上角「写本节」生成',
          style: const TextStyle(fontSize: 13, color: _muted),
        ),
      );
    }
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
          data: section.content,
          styleSheet: _textbookStyle(context),
          imageBuilder: _mdImage,
        ),
      ),
    );
  }

  /// 教材排版样式：正文用宋体、标题用黑体，字号与行距贴近纸质教材。
  MarkdownStyleSheet _textbookStyle(BuildContext context) {
    const body = Color(0xFF1A1A1A);
    const serif = 'SimSun'; // 宋体：正文
    const hei = 'SimHei'; // 黑体：各级标题
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: const TextStyle(
        fontFamily: serif,
        fontSize: 16,
        height: 1.9,
        color: body,
      ),
      pPadding: const EdgeInsets.only(bottom: 10),
      h1: const TextStyle(
        fontFamily: hei,
        fontSize: 23,
        height: 1.6,
        fontWeight: FontWeight.w700,
        color: body,
      ),
      h1Padding: const EdgeInsets.only(top: 8, bottom: 12),
      h2: const TextStyle(
        fontFamily: hei,
        fontSize: 19,
        height: 1.6,
        fontWeight: FontWeight.w700,
        color: body,
      ),
      h2Padding: const EdgeInsets.only(top: 14, bottom: 8),
      h3: const TextStyle(
        fontFamily: hei,
        fontSize: 16.5,
        height: 1.6,
        fontWeight: FontWeight.w700,
        color: body,
      ),
      h3Padding: const EdgeInsets.only(top: 10, bottom: 6),
      listBullet: const TextStyle(
        fontFamily: serif,
        fontSize: 16,
        height: 1.9,
        color: body,
      ),
      blockquote: const TextStyle(
        fontFamily: serif,
        fontSize: 15,
        height: 1.8,
        color: _sub,
      ),
      blockquoteDecoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        border: const Border(left: BorderSide(color: _accent, width: 3)),
        borderRadius: BorderRadius.circular(4),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      code: const TextStyle(
        fontFamily: 'Consolas',
        fontSize: 14,
        backgroundColor: Color(0xFFF0F0F2),
      ),
      strong: const TextStyle(fontFamily: hei, fontWeight: FontWeight.w700),
    );
  }

  /// 跑「AI 立项分析」，完成后把生成结果回填到输入框。
  /// 注意：立项输入框只在切换书籍时按 book.id 初始化一次，
  /// AI 生成后必须手动回填，否则界面看起来「没生成内容」。
  Future<void> _runKickoff(ProBookService svc) async {
    await svc.generateKickoff();
    if (!mounted) return;
    final book = svc.current;
    if (book == null) return;
    setState(() {
      _topicCtrl.text = book.topic;
      _readerCtrl.text = book.readerPositioning;
      _valueCtrl.text = book.valueProposition;
    });
  }

  /// 立项参考资料上传条：传一份 PDF，AI 会结合书名解读分析。
  Widget _referenceUploadBar(ProBookService svc, ProBook book) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FBF9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFB9E8E0)),
      ),
      child: Row(
        children: [
          const Icon(Icons.picture_as_pdf_outlined, size: 18, color: _accent),
          const SizedBox(width: 8),
          Expanded(
            child: book.hasReference
                ? Text(
                    '参考资料：${book.referenceName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: _ink),
                  )
                : const Text(
                    '可上传一份 PDF（如考试大纲、同类书目录、行业标准），AI 立项分析会结合书名一起解读。',
                    style: TextStyle(fontSize: 12, color: _sub),
                  ),
          ),
          if (book.hasReference)
            TextButton(
              onPressed: svc.busy ? null : svc.clearReference,
              child: const Text('移除'),
            ),
          TextButton.icon(
            onPressed: svc.busy ? null : () => _pickReferencePdf(svc),
            icon: const Icon(Icons.upload_file, size: 15),
            label: Text(book.hasReference ? '更换' : '上传 PDF'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickReferencePdf(ProBookService svc) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    await svc.attachReference(path);
    if (!mounted) return;
    if (svc.stage.contains('失败') || svc.stage.contains('未能')) {
      _toast(svc.stage);
    }
  }

  // 立项视图
  Widget _kickoffView(ProBookService svc, ProBook book) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _referenceUploadBar(svc, book),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: svc.busy ? null : () => _runKickoff(svc),
              icon: const Icon(Icons.auto_awesome, size: 15),
              label: const Text('AI 立项分析'),
            ),
          ),
          _bigField('选题', _topicCtrl, '这本书要解决什么问题', (v) => book.topic = v, svc),
          _bigField('读者定位', _readerCtrl, '是谁、什么水平、读它解决什么',
              (v) => book.readerPositioning = v, svc),
          _bigField('核心价值主张', _valueCtrl, '读者读完能获得什么、与同类书的差异',
              (v) => book.valueProposition = v, svc),
        ],
      ),
    );
  }

  Widget _bigField(
    String label,
    TextEditingController c,
    String hint,
    void Function(String) onChanged,
    ProBookService svc,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: c,
            minLines: 2,
            maxLines: 6,
            style: const TextStyle(fontSize: 13, height: 1.5),
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: onChanged,
            onTapOutside: (_) => svc.save(),
          ),
        ],
      ),
    );
  }

  // 资料视图
  Widget _referencesView(ProBookService svc, ProBook book) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              const Text(
                '参考资料 / 标准',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: svc.busy ? null : () => svc.addReference(),
                icon: const Icon(Icons.add, size: 15),
                label: const Text('手动添加'),
              ),
              TextButton.icon(
                onPressed: svc.busy ? null : svc.suggestReferences,
                icon: const Icon(Icons.auto_awesome, size: 15),
                label: const Text('AI 建议'),
              ),
            ],
          ),
        ),
        Expanded(
          child: book.references.isEmpty
              ? const Center(
                  child: Text(
                    '暂无资料。点击「AI 建议」或「手动添加」。',
                    style: TextStyle(fontSize: 12.5, color: _muted),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: book.references.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) =>
                      _referenceRow(svc, book.references[i]),
                ),
        ),
      ],
    );
  }

  Widget _referenceRow(ProBookService svc, ProReference ref) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _chip(ref.source),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ref.title.isEmpty ? '(未命名资料)' : ref.title,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (ref.note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      ref.note,
                      style: const TextStyle(fontSize: 11.5, color: _sub),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: '编辑',
            visualDensity: VisualDensity.compact,
            iconSize: 15,
            onPressed: () => _editReference(svc, ref),
            icon: const Icon(Icons.edit_outlined, color: _muted),
          ),
          IconButton(
            tooltip: '删除',
            visualDensity: VisualDensity.compact,
            iconSize: 15,
            onPressed: () => svc.removeReference(ref),
            icon: const Icon(Icons.close, color: _muted),
          ),
        ],
      ),
    );
  }

  Future<void> _editReference(ProBookService svc, ProReference ref) async {
    final title = TextEditingController(text: ref.title);
    final note = TextEditingController(text: ref.note);
    final url = TextEditingController(text: ref.url);
    var source = ref.source;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('编辑资料'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _field(title, '资料名称', '标准 / 著作 / 文档名称'),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Text('来源：', style: TextStyle(fontSize: 12.5)),
                    const SizedBox(width: 8),
                    for (final s in const ['知识库', '网页', '手动'])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(s),
                          selected: source == s,
                          onSelected: (_) => setLocal(() => source = s),
                        ),
                      ),
                  ],
                ),
                _field(note, '用途说明', '支撑哪部分内容', maxLines: 2),
                _field(url, '链接（可选）', 'https://…'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _accent),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      ref.title = title.text.trim();
      ref.note = note.text.trim();
      ref.url = url.text.trim();
      ref.source = source;
      await svc.save();
    }
  }

  // 审校视图
  Widget _reviewView(ProBookService svc, ProBook book) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: svc.busy ? null : svc.review,
                icon: const Icon(Icons.fact_check_outlined, size: 15),
                label: const Text('AI 审校'),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                // 审校之后才能按意见修订。
                onPressed: (svc.busy || book.reviewNotes.trim().isEmpty)
                    ? null
                    : () {
                        setState(() => _view = 0);
                        svc.revise();
                      },
                icon: const Icon(Icons.auto_fix_high_outlined, size: 15),
                label: const Text('按审校意见修订'),
              ),
            ],
          ),
          if (book.glossary.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text(
              '术语表',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            for (final t in book.glossary)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• ${t.term}：${t.definition}',
                  style: const TextStyle(fontSize: 12.5, height: 1.4),
                ),
              ),
            const SizedBox(height: 14),
          ],
          const Text(
            '审校意见',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          book.reviewNotes.isEmpty
              ? const Text(
                  '点击「AI 审校」检查术语一致性与内容准确性。',
                  style: TextStyle(fontSize: 12.5, color: _muted),
                )
              : MarkdownBody(data: book.reviewNotes),
        ],
      ),
    );
  }
}
