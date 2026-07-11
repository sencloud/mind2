import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/mind_map_service.dart';

const _accent = Color(0xFF0D9488);
const _sub = Color(0xFF6B6B70);
const _muted = Color(0xFF9B9B9F);

/// 思维导图页：历史列表 + 工作区（左侧输入/上传，右侧预览并下载）。
class MindMapPage extends StatefulWidget {
  const MindMapPage({super.key, required this.service});

  final MindMapService service;

  @override
  State<MindMapPage> createState() => _MindMapPageState();
}

class _MindMapPageState extends State<MindMapPage> {
  final _ctrl = TextEditingController();
  String? _boundId; // 已绑定到输入框的记录 id，避免重复覆盖用户输入

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 打开新记录时把它的原文回填到输入框（同一条记录只绑定一次）。
  void _bind(MindMapRecord rec) {
    if (_boundId == rec.id) return;
    _boundId = rec.id;
    _ctrl.text = rec.sourceText;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final svc = widget.service;
        if (svc.current == null) return _buildShelf(svc);
        _bind(svc.current!);
        return _buildWorkspace(svc);
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 历史列表
  // ---------------------------------------------------------------------------

  Widget _buildShelf(MindMapService svc) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '思维导图',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => svc.create(),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1A1A1A),
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新建思维导图'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '粘贴文字或上传 PDF / Word 文档，一键生成思维导图，可切换发散/层级样式并下载 PNG / JPG。',
            style: TextStyle(fontSize: 13, color: _sub),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: svc.records.isEmpty
                ? const Center(
                    child: Text(
                      '还没有思维导图，点击右上角「新建思维导图」开始',
                      style: TextStyle(fontSize: 13, color: _muted),
                    ),
                  )
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 320,
                          mainAxisExtent: 132,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                    itemCount: svc.records.length,
                    itemBuilder: (context, i) => _recordCard(svc, svc.records[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _recordCard(MindMapService svc, MindMapRecord rec) {
    return Material(
      color: const Color(0xFFF7F7F8),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => svc.open(rec),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.account_tree_outlined, size: 18,
                      color: _accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      rec.title,
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
                      if (v == 'delete') svc.delete(rec);
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
                  rec.sourceText.isEmpty ? '（尚未生成）' : rec.sourceText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: _sub,
                  ),
                ),
              ),
              Text(
                _fmtTime(rec.updatedAt),
                style: const TextStyle(fontSize: 11.5, color: _muted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 工作区
  // ---------------------------------------------------------------------------

  Widget _buildWorkspace(MindMapService svc) {
    final rec = svc.current!;
    return Column(
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              IconButton(
                onPressed: svc.busy ? null : svc.close,
                icon: const Icon(Icons.arrow_back, size: 20),
                tooltip: '返回列表',
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  rec.title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFECECEE)),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 380, child: _inputPanel()),
              const VerticalDivider(width: 1, color: Color(0xFFECECEE)),
              Expanded(child: _previewPanel()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _inputPanel() {
    final svc = widget.service;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '粘贴文字，或上传 PDF / Word 文档，一键生成思维导图。',
            style: TextStyle(fontSize: 12.5, color: _sub, height: 1.5),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: svc.busy ? null : _upload,
                icon: const Icon(Icons.upload_file_outlined, size: 16),
                label: const Text('上传文档 (pdf/word)'),
              ),
              if (svc.sourceName != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    svc.sourceName!,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: _muted),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              controller: _ctrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontSize: 13, height: 1.6),
              decoration: const InputDecoration(
                hintText: '在此粘贴或输入需要梳理的内容…',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.all(12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _accent),
              onPressed: svc.busy ? null : () => svc.generate(_ctrl.text),
              icon: svc.busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.account_tree_outlined, size: 16),
              label: Text(svc.busy ? '生成中…' : '生成思维导图'),
            ),
          ),
          if (svc.stage.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              svc.stage,
              style: const TextStyle(fontSize: 12, color: _muted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _previewPanel() {
    final svc = widget.service;
    if (svc.image == null) {
      return const Center(
        child: Text(
          '生成后在此预览思维导图',
          style: TextStyle(fontSize: 13, color: _muted),
        ),
      );
    }
    return Column(
      children: [
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _layoutSelector(svc),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: svc.busy ? null : () => _download(jpg: false),
                icon: const Icon(Icons.image_outlined, size: 16),
                label: const Text('下载 PNG'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: svc.busy ? null : () => _download(jpg: true),
                icon: const Icon(Icons.image_outlined, size: 16),
                label: const Text('下载 JPG'),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFECECEE)),
        Expanded(
          child: Container(
            color: const Color(0xFFFAFAFA),
            padding: const EdgeInsets.all(16),
            child: InteractiveViewer(
              minScale: 0.2,
              maxScale: 5,
              child: Center(
                  child: Image.memory(svc.image!,
                      filterQuality: FilterQuality.high)),
            ),
          ),
        ),
      ],
    );
  }

  /// 展现形式选择器：发散气泡 / 横向层级 / 纵向层级。
  Widget _layoutSelector(MindMapService svc) {
    return Row(
      children: [
        const Text('样式', style: TextStyle(fontSize: 12.5, color: _sub)),
        const SizedBox(width: 8),
        SegmentedButton<MindMapLayout>(
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
          ),
          segments: const [
            ButtonSegment(
              value: MindMapLayout.bubble,
              icon: Icon(Icons.bubble_chart_outlined, size: 15),
              label: Text('发散'),
            ),
            ButtonSegment(
              value: MindMapLayout.treeRight,
              icon: Icon(Icons.account_tree_outlined, size: 15),
              label: Text('横向层级'),
            ),
            ButtonSegment(
              value: MindMapLayout.treeDown,
              icon: Icon(Icons.schema_outlined, size: 15),
              label: Text('纵向层级'),
            ),
          ],
          selected: {svc.layout},
          onSelectionChanged: svc.busy
              ? null
              : (values) => svc.setLayout(values.first),
        ),
      ],
    );
  }

  Future<void> _upload() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'docx', 'txt', 'md', 'markdown'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    await widget.service.importFile(path);
    // 把抽取到的文字回填到输入框，方便查看和微调。
    final rec = widget.service.current;
    if (rec != null && rec.sourceText.isNotEmpty) {
      _ctrl.text = rec.sourceText;
    }
  }

  Future<void> _download({required bool jpg}) async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择保存文件夹');
    if (dir == null) return;
    try {
      final path = await widget.service.exportImage(dir, jpg: jpg);
      _toast('已保存：$path');
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
