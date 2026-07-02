import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../services/agent/memory/memory_service.dart';
import '../services/agent/memory/skill_store.dart';

/// 技能库视图（知识体系页的"技能库"tab）：
/// 展示 Agent 自动沉淀的技能 SOP（L3 记忆），支持查看、编辑、删除。
/// 技能由任务成功后自动沉淀，这里是人工管理入口。
class SkillLibraryView extends StatefulWidget {
  const SkillLibraryView({super.key, required this.memory});

  final MemoryService memory;

  @override
  State<SkillLibraryView> createState() => _SkillLibraryViewState();
}

class _SkillLibraryViewState extends State<SkillLibraryView> {
  List<SkillHeader> _headers = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final headers = await widget.memory.skills.scanHeaders();
    if (!mounted) return;
    setState(() {
      _headers = headers;
      _loading = false;
    });
  }

  Future<void> _delete(SkillHeader h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除技能'),
        content: Text('确定删除技能「${h.name}」？删除后同类任务将无法召回这条 SOP。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.memory.skills.delete(h.filename);
    await _reload();
  }

  Future<void> _view(SkillHeader h) async {
    final body = await widget.memory.skills.readBody(h.filename) ?? '';
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    const Icon(Icons.auto_awesome,
                        size: 18, color: Color(0xFF0D9488)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        h.name,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: '编辑',
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _edit(h, body);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Markdown(
                  data: body.isEmpty ? '（正文为空）' : body,
                  padding: const EdgeInsets.all(20),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _edit(SkillHeader h, String body) async {
    final nameCtrl = TextEditingController(text: h.name);
    final descCtrl = TextEditingController(text: h.description);
    final bodyCtrl = TextEditingController(text: body);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 680),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('编辑技能',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 14),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '技能名',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: descCtrl,
                  decoration: const InputDecoration(
                    labelText: '适用场景（召回时靠它匹配任务）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: TextField(
                    controller: bodyCtrl,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                    decoration: const InputDecoration(
                      labelText: 'SOP 正文（Markdown）',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved == true) {
      final name = nameCtrl.text.trim();
      final bodyText = bodyCtrl.text.trim();
      if (name.isNotEmpty && bodyText.isNotEmpty) {
        await widget.memory.skills.save(
          name: name,
          description: descCtrl.text.trim(),
          body: bodyText,
          filename: h.filename,
        );
        await _reload();
      }
    }
    nameCtrl.dispose();
    descCtrl.dispose();
    bodyCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_headers.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 40, color: Color(0xFFD1D1D6)),
            SizedBox(height: 12),
            Text(
              '暂无沉淀的技能\n当「计划 / 项目 / 实验」的任务成功完成后，\nAgent 会自动把可复用的执行路径固化为技能 SOP',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF9B9B9F), height: 1.6),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(40, 20, 40, 40),
        itemCount: _headers.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          if (i == 0) return _hint();
          final h = _headers[i - 1];
          return _skillCard(h);
        },
      ),
    );
  }

  Widget _hint() {
    return Row(
      children: [
        Expanded(
          child: Text(
            '共 ${_headers.length} 条技能 · 任务成功后自动沉淀，同类任务自动召回',
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF9B9B9F)),
          ),
        ),
        IconButton(
          tooltip: '刷新',
          icon: const Icon(Icons.refresh, size: 18),
          onPressed: _reload,
        ),
      ],
    );
  }

  Widget _skillCard(SkillHeader h) {
    final days = ((DateTime.now().millisecondsSinceEpoch - h.mtimeMs) /
            86400000)
        .floor();
    final age = days <= 0 ? '今天更新' : '$days 天前更新';
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _view(h),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE8E8EC)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome,
                  size: 20, color: Color(0xFF0D9488)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      h.name,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      h.description.isEmpty ? '（无适用场景描述）' : h.description,
                      style: const TextStyle(
                          fontSize: 12.5, color: Color(0xFF6B6B70)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6F7F4),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '命中 ${h.hits} 次',
                      style: const TextStyle(
                          fontSize: 11.5, color: Color(0xFF0D9488)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    age,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF9B9B9F)),
                  ),
                ],
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert,
                    size: 18, color: Color(0xFF9B9B9F)),
                onSelected: (v) async {
                  if (v == 'view') {
                    await _view(h);
                  } else if (v == 'edit') {
                    final body =
                        await widget.memory.skills.readBody(h.filename) ?? '';
                    if (mounted) await _edit(h, body);
                  } else if (v == 'delete') {
                    await _delete(h);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'view', child: Text('查看 SOP')),
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
