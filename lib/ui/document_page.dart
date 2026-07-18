import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../services/document_service.dart';
import '../services/platform_capabilities.dart';
import 'responsive.dart';
import 'sheet_grid.dart';

const _accent = Color(0xFF0D9488);
const _sub = Color(0xFF6B6B70);
const _muted = Color(0xFF9B9B9F);

class DocumentPage extends StatefulWidget {
  const DocumentPage({super.key, required this.document});

  final DocumentService document;

  @override
  State<DocumentPage> createState() => _DocumentPageState();
}

class _DocumentPageState extends State<DocumentPage> {
  final _title = TextEditingController();
  final _topic = TextEditingController();
  final _pages = TextEditingController(text: '3');
  final _content = TextEditingController();

  String _selectedTemplate = DocumentService.templates.first.id;
  String? _boundId;
  bool _editing = false;
  // 窄屏单栏切换：0=配置面板，1=正文。
  int _mobileTab = 0;

  @override
  void dispose() {
    _title.dispose();
    _topic.dispose();
    _pages.dispose();
    _content.dispose();
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

  void _bind(DocumentDraft? draft) {
    if (draft == null || _boundId == draft.id) return;
    _boundId = draft.id;
    _title.text = draft.title;
    _topic.text = draft.topic;
    _pages.text = '${draft.expectedPages}';
    _content.text = draft.content;
    _selectedTemplate = draft.templateId;
    _editing = false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.document,
      builder: (context, _) {
        final svc = widget.document;
        _bind(svc.current);
        return svc.current == null ? _buildShelf(svc) : _buildWorkspace(svc);
      },
    );
  }

  Widget _buildShelf(DocumentService svc) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '文档写作',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => _newDocument(svc),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1A1A1A),
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新建文档'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '给定主题并选择文档模板，自动生成公文、需求文档、申报书、制度、总结等正式文稿；也可以上传 docx / Excel 模板（Excel 支持多个工作表），按模板结构生成。',
            style: TextStyle(fontSize: 13, color: _sub),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: svc.documents.isEmpty
                ? const Center(
                    child: Text(
                      '还没有文档，点击右上角「新建文档」开始',
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
                    itemCount: svc.documents.length,
                    itemBuilder: (context, i) =>
                        _documentCard(svc, svc.documents[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _documentCard(DocumentService svc, DocumentDraft draft) {
    return Material(
      color: const Color(0xFFF7F7F8),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => svc.open(draft),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.description_outlined,
                    size: 18,
                    color: _accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      draft.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz, size: 18),
                    onSelected: (v) {
                      if (v == 'delete') _confirmDelete(svc, draft);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  draft.topic.isEmpty ? '（暂无主题）' : draft.topic,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: _sub,
                  ),
                ),
              ),
              Row(
                children: [
                  // 模板名可能是很长的文件名，用 Flexible 让它收缩并省略。
                  Flexible(
                    child: _chip(
                      draft.templateName.isEmpty ? '文档' : draft.templateName,
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 8),
                  Text(
                    '${draft.words} 字',
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

  Widget _buildWorkspace(DocumentService svc) {
    final draft = svc.current!;
    final template = svc.templateOf(_selectedTemplate);
    if (context.isCompact) {
      // 窄屏单栏：顶部切换「配置 / 正文」，避免固定 390 侧栏溢出。
      return Column(
        children: [
          _topBar(svc, draft),
          _mobileTabBar(),
          Expanded(
            child: _mobileTab == 0
                ? _leftPanel(svc, draft, template)
                : (_editing ? _editor(draft) : _preview(draft)),
          ),
        ],
      );
    }
    return Column(
      children: [
        _topBar(svc, draft),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 390, child: _leftPanel(svc, draft, template)),
              const VerticalDivider(width: 1),
              Expanded(child: _editing ? _editor(draft) : _preview(draft)),
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
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<int>(
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: 0, label: Text('配置')),
                ButtonSegment(value: 1, label: Text('正文')),
              ],
              selected: {_mobileTab},
              onSelectionChanged: (v) => setState(() => _mobileTab = v.first),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar(DocumentService svc, DocumentDraft draft) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFECECEE))),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回文档列表',
            onPressed: () {
              svc.close();
              _boundId = null;
            },
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              draft.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          if (svc.busy) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(svc.stage, style: const TextStyle(fontSize: 12, color: _sub)),
            const SizedBox(width: 12),
          ],
          OutlinedButton.icon(
            onPressed: svc.busy ? null : () => _pickTemplate(svc),
            icon: const Icon(Icons.upload_file, size: 16),
            label: const Text('上传模板 (docx/xlsx)'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: svc.busy ? null : () => _pickReferences(svc),
            icon: const Icon(Icons.attach_file, size: 16),
            label: const Text('上传参考文档'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: svc.busy ? null : () => _generate(svc),
            style: FilledButton.styleFrom(backgroundColor: _accent),
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('生成文档'),
          ),
          const SizedBox(width: 8),
          // 继续完善：只针对用户指出的地方补充，已有内容原样保留。
          OutlinedButton.icon(
            onPressed: (svc.busy || draft.content.trim().isEmpty)
                ? null
                : () => _refine(svc),
            icon: const Icon(Icons.auto_fix_high_outlined, size: 16),
            label: const Text('继续完善'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: svc.busy ? null : () => _export(svc),
            icon: const Icon(Icons.ios_share, size: 16),
            label: const Text('导出'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => _toggleEdit(svc),
            icon: Icon(
              _editing ? Icons.save_outlined : Icons.edit_outlined,
              size: 16,
            ),
            label: Text(_editing ? '保存' : '编辑'),
          ),
        ],
      ),
    );
  }

  Widget _leftPanel(
    DocumentService svc,
    DocumentDraft draft,
    DocumentTemplate template,
  ) {
    final grouped = <String, List<DocumentTemplate>>{};
    for (final item in DocumentService.templates) {
      grouped.putIfAbsent(item.category, () => []).add(item);
    }
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text('文档信息', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        TextField(
          controller: _title,
          decoration: const InputDecoration(
            labelText: '标题',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) {
            draft.title = v;
            draft.updatedAt = DateTime.now();
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _topic,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: '主题 / 写作要求',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) {
            draft.topic = v;
            draft.updatedAt = DateTime.now();
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pages,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '预计编写页数',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) {
            draft.expectedPages = int.tryParse(v.trim()) ?? draft.expectedPages;
            if (draft.expectedPages < 1) draft.expectedPages = 1;
            draft.updatedAt = DateTime.now();
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _selectedTemplate,
          decoration: const InputDecoration(
            labelText: '内置模板',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final entry in grouped.entries) ...[
              DropdownMenuItem(
                enabled: false,
                value: '__${entry.key}',
                child: Text('— ${entry.key} —'),
              ),
              for (final item in entry.value)
                DropdownMenuItem(value: item.id, child: Text(item.name)),
            ],
          ],
          onChanged: (v) {
            if (v == null || v.startsWith('__')) return;
            setState(() {
              _selectedTemplate = v;
              final next = svc.templateOf(v);
              draft.templateId = next.id;
              draft.templateName = next.name;
              draft.updatedAt = DateTime.now();
            });
          },
        ),
        const SizedBox(height: 12),
        Text(
          template.description,
          style: const TextStyle(fontSize: 12.5, height: 1.5, color: _sub),
        ),
        const SizedBox(height: 8),
        Text(
          template.requirements,
          style: const TextStyle(fontSize: 12, height: 1.55, color: _muted),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            const Text('参考文档', style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _pickReferences(svc),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加'),
            ),
          ],
        ),
        if (draft.references.isEmpty)
          const Text(
            '可上传多个 docx / pdf / xlsx / txt / md 作为参考资料，生成时会自动引入。',
            style: TextStyle(fontSize: 12, color: _muted),
          )
        else
          for (final ref in draft.references)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F7F8),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.description_outlined,
                    size: 16,
                    color: _accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      ref.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: _sub),
                    ),
                  ),
                  IconButton(
                    tooltip: '移除',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => svc.removeReference(ref.path),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 18),
        if (draft.templateText.trim().isNotEmpty) ...[
          Row(
            children: [
              const Icon(Icons.check_circle, size: 16, color: _accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '已导入：${draft.templateName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: _accent),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F7F8),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              draft.templateText,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: _sub, height: 1.45),
            ),
          ),
        ],
      ],
    );
  }

  Widget _preview(DocumentDraft draft) {
    // Excel 模式：按工作表分 sheet 预览（tab 形式）。
    final sheets = draft.spreadsheet
        ? DocumentService.parseSheets(_content.text)
        : const <({String name, List<List<String>> rows})>[];
    return Container(
      color: const Color(0xFFFAFAFB),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFECECEE))),
            ),
            child: const Text(
              '正文预览',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: sheets.isNotEmpty
                ? _sheetTabs(sheets)
                : Markdown(
                    data: _content.text.trim().isEmpty
                        ? '（暂无正文）'
                        : _content.text,
                    padding: const EdgeInsets.all(22),
                    styleSheet: _officialMarkdownStyle(),
                  ),
          ),
        ],
      ),
    );
  }

  /// 多工作表预览：每个工作表一个 tab，内部用表格展示该 sheet 的行/列。
  Widget _sheetTabs(List<({String name, List<List<String>> rows})> sheets) {
    return DefaultTabController(
      length: sheets.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.white,
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: _accent,
              unselectedLabelColor: _sub,
              indicatorColor: _accent,
              labelStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              tabs: [for (final s in sheets) Tab(text: s.name)],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [for (final s in sheets) SheetGrid(rows: s.rows)],
            ),
          ),
        ],
      ),
    );
  }


  MarkdownStyleSheet _officialMarkdownStyle() {
    const body = TextStyle(
      fontFamily: 'FangSong',
      fontSize: 21,
      height: 1.75,
      color: Colors.black,
    );
    return MarkdownStyleSheet(
      p: body,
      pPadding: EdgeInsets.zero,
      h1: const TextStyle(
        fontFamily: 'SimSun',
        fontSize: 29,
        height: 1.45,
        fontWeight: FontWeight.w700,
        color: Colors.black,
      ),
      h1Padding: const EdgeInsets.only(bottom: 22),
      h2: const TextStyle(
        fontFamily: 'SimHei',
        fontSize: 21,
        height: 1.75,
        fontWeight: FontWeight.w400,
        color: Colors.black,
      ),
      h2Padding: EdgeInsets.zero,
      h3: const TextStyle(
        fontFamily: 'KaiTi',
        fontSize: 21,
        height: 1.75,
        fontWeight: FontWeight.w700,
        color: Colors.black,
      ),
      h3Padding: EdgeInsets.zero,
      h4: body.copyWith(fontWeight: FontWeight.w700),
      h5: body.copyWith(fontWeight: FontWeight.w700),
      h6: body.copyWith(fontWeight: FontWeight.w700),
      blockSpacing: 0,
      listIndent: 42,
      listBullet: body,
      tableHead: const TextStyle(
        fontFamily: 'SimHei',
        fontSize: 21,
        height: 1.75,
        color: Colors.black,
      ),
      tableBody: body,
      blockquote: body,
      code: body,
    );
  }

  Widget _editor(DocumentDraft draft) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: TextField(
        controller: _content,
        expands: true,
        maxLines: null,
        minLines: null,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(
          labelText: 'Markdown 编辑',
          alignLabelWithHint: true,
          border: OutlineInputBorder(),
        ),
        style: const TextStyle(fontSize: 14, height: 1.65),
        onChanged: (v) {
          draft.content = v;
          draft.updatedAt = DateTime.now();
        },
      ),
    );
  }

  Future<void> _newDocument(DocumentService svc) async {
    final title = TextEditingController();
    final topic = TextEditingController();
    final pages = TextEditingController(text: '3');
    var templateId = DocumentService.templates.first.id;
    var referencePaths = <String>[];
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('新建文档'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: '标题（可选）'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: topic,
                  minLines: 4,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: '主题 / 写作要求',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: pages,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '预计编写页数'),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await _pickReferencePaths();
                        if (picked.isEmpty) return;
                        setLocal(() {
                          referencePaths = {
                            ...referencePaths,
                            ...picked,
                          }.toList();
                        });
                      },
                      icon: const Icon(Icons.attach_file, size: 16),
                      label: const Text('上传参考文档'),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        referencePaths.isEmpty
                            ? '支持多选 docx / pdf / xlsx / txt / md'
                            : '已选择 ${referencePaths.length} 份参考文档',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: _sub),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: templateId,
                  decoration: const InputDecoration(labelText: '文档模板'),
                  items: [
                    for (final t in DocumentService.templates)
                      DropdownMenuItem(
                        value: t.id,
                        child: Text('${t.category} / ${t.name}'),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setLocal(() => templateId = v);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (created == true) {
      final draft = await svc.create(
        title: title.text,
        topic: topic.text,
        templateId: templateId,
        expectedPages: int.tryParse(pages.text.trim()) ?? 3,
      );
      if (referencePaths.isNotEmpty) {
        await svc.importReferenceDocuments(referencePaths);
      }
      setState(() {
        _boundId = null;
        _bind(draft);
      });
    }
    title.dispose();
    topic.dispose();
    pages.dispose();
  }

  Future<void> _confirmDelete(DocumentService svc, DocumentDraft draft) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文档'),
        content: Text('确定删除《${draft.title}》吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await svc.delete(draft);
  }

  Future<void> _pickTemplate(DocumentService svc) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['docx', 'xlsx'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    try {
      await svc.importTemplate(path);
      _toast('模板已导入');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  Future<void> _pickReferences(DocumentService svc) async {
    final paths = await _pickReferencePaths();
    if (paths.isEmpty) return;
    try {
      await svc.importReferenceDocuments(paths);
      _toast('已导入 ${paths.length} 份参考文档');
    } catch (e) {
      _toast('导入参考文档失败：$e');
    }
  }

  Future<List<String>> _pickReferencePaths() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['docx', 'pdf', 'xlsx', 'txt', 'md', 'markdown'],
    );
    return result?.files.map((f) => f.path).whereType<String>().toList() ??
        const [];
  }

  Future<void> _generate(DocumentService svc) async {
    await _save(svc);
    await svc.generate();
    _boundId = null;
    _bind(svc.current);
    if (svc.stage.startsWith('生成失败')) {
      _toast(svc.stage);
    }
  }

  /// 继续完善：让用户输入要补充/完善的地方，针对性补充，已有内容原样保留。
  Future<void> _refine(DocumentService svc) async {
    final input = TextEditingController();
    final instruction = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('继续完善'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '说明要继续补充/完善的地方（例如「补充 05 关键数据调研工作表的示例数据」）。'
                'AI 只针对你指出的地方补充，其余已有内容会原样保留。',
                style: TextStyle(fontSize: 12.5, color: _sub),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: input,
                autofocus: true,
                maxLines: 5,
                minLines: 3,
                style: const TextStyle(fontSize: 13.5),
                decoration: const InputDecoration(
                  hintText: '要继续完善的内容…',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(12),
                ),
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
            onPressed: () => Navigator.pop(ctx, input.text.trim()),
            child: const Text('开始完善'),
          ),
        ],
      ),
    );
    input.dispose();
    if (instruction == null || instruction.isEmpty) return;
    // 先把编辑框里的最新内容存回，避免完善基于旧内容。
    await _save(svc, showToast: false);
    await svc.refine(instruction);
    _boundId = null;
    _bind(svc.current);
    if (svc.stage.startsWith('完善失败')) _toast(svc.stage);
  }

  Future<void> _export(DocumentService svc) async {
    final draft = svc.current;
    if (draft == null) return;
    // 多工作表 Excel 文档默认只导出 xlsx；普通文稿默认导出 Word + PDF。
    final sheet = draft.spreadsheet;
    // PDF 导出依赖本机 Edge/Chrome 无头打印，移动端不可用。
    final canPdf = PlatformCapabilities.supportsPdfExport;
    var exportWord = !sheet;
    var exportPdf = !sheet && canPdf;
    var exportExcel = sheet;
    var htmlPipeline = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('导出文档'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CheckboxListTile(
                  value: exportExcel,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('导出 Excel'),
                  subtitle: const Text('按「工作表」分节生成多 sheet 的 .xlsx 文件'),
                  onChanged: (v) => setLocal(() => exportExcel = v ?? false),
                ),
                CheckboxListTile(
                  value: exportWord,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('导出 Word'),
                  subtitle: const Text('导出为标准 .docx 文件'),
                  onChanged: (v) => setLocal(() => exportWord = v ?? false),
                ),
                if (canPdf)
                  CheckboxListTile(
                    value: exportPdf,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('导出 PDF'),
                    subtitle: const Text('使用本机 Edge / Chrome 打印为 PDF'),
                    onChanged: (v) => setLocal(() => exportPdf = v ?? false),
                  ),
                if (canPdf) ...[
                  const Divider(height: 24),
                  CheckboxListTile(
                    value: htmlPipeline,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('高级选项：先由 Markdown 生成 HTML 再导出'),
                    subtitle:
                        const Text('默认启用，表格、标题和列表排版更稳定，并保留 HTML 文件'),
                    onChanged: (v) => setLocal(() => htmlPipeline = v ?? true),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: exportWord || exportPdf || exportExcel
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: const Text('导出'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择导出文件夹');
    if (dir == null) return;
    await _save(svc, showToast: false);
    try {
      final exported = await svc.exportCurrent(
        outputDir: dir,
        formats: {
          if (exportWord) DocumentExportFormat.word,
          if (exportPdf) DocumentExportFormat.pdf,
          if (exportExcel) DocumentExportFormat.excel,
        },
        htmlPipeline: htmlPipeline,
      );
      _toast(
        '导出完成：${exported.map((f) => f.path.split(RegExp(r'[\\/]')).last).join('、')}',
      );
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  Future<void> _toggleEdit(DocumentService svc) async {
    if (!_editing) {
      setState(() => _editing = true);
      return;
    }
    await _save(svc);
    setState(() => _editing = false);
  }

  Future<void> _save(DocumentService svc, {bool showToast = true}) async {
    final draft = svc.current;
    if (draft == null) return;
    draft.title = _title.text.trim().isEmpty ? '未命名文档' : _title.text.trim();
    draft.topic = _topic.text.trim();
    draft.expectedPages =
        int.tryParse(_pages.text.trim()) ?? draft.expectedPages;
    if (draft.expectedPages < 1) draft.expectedPages = 1;
    draft.content = _content.text;
    await svc.save();
    if (showToast) _toast('已保存');
  }

  Widget _chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xFFE8F5F3),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 11,
        color: _accent,
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

