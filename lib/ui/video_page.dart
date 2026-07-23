import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/video_service.dart';
import 'responsive.dart';

const _accent = Color(0xFF7C3AED);
const _sub = Color(0xFF6B6B70);
const _muted = Color(0xFF9B9B9F);

class VideoPage extends StatefulWidget {
  const VideoPage({super.key, required this.video});

  final VideoService video;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  final _title = TextEditingController();
  final _premise = TextEditingController();
  final _style = TextEditingController();
  final _duration = TextEditingController();

  String? _boundId;
  int _mobileTab = 0; // 0=配置，1=分镜

  @override
  void dispose() {
    _title.dispose();
    _premise.dispose();
    _style.dispose();
    _duration.dispose();
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

  void _bind(VideoProject? proj) {
    if (proj == null || _boundId == proj.id) return;
    _boundId = proj.id;
    _title.text = proj.title;
    _premise.text = proj.premise;
    _style.text = proj.style;
    _duration.text = proj.targetDuration;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.video,
      builder: (context, _) {
        final svc = widget.video;
        _bind(svc.current);
        return svc.current == null ? _buildShelf(svc) : _buildWorkspace(svc);
      },
    );
  }

  // ---------------------------------------------------------------- 货架

  Widget _buildShelf(VideoService svc) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '视频',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => _newVideo(svc),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1A1A1A),
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新建视频'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '给定创意、风格与目标时长，自动生成故事梗概与专业的分镜脚本（逐镜的景别、运镜、'
            '画面、台词、音效等），可编辑并导出。',
            style: TextStyle(fontSize: 13, color: _sub),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: svc.projects.isEmpty
                ? const Center(
                    child: Text(
                      '还没有视频，点击右上角「新建视频」开始',
                      style: TextStyle(fontSize: 13, color: _muted),
                    ),
                  )
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 340,
                          mainAxisExtent: 168,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                    itemCount: svc.projects.length,
                    itemBuilder: (context, i) => _card(svc, svc.projects[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _card(VideoService svc, VideoProject proj) {
    return Material(
      color: const Color(0xFFF7F7F8),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => svc.open(proj),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.movie_creation_outlined,
                      size: 18, color: _accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      proj.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz, size: 18),
                    onSelected: (v) {
                      if (v == 'delete') _confirmDelete(svc, proj);
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
                  proj.logline.isNotEmpty
                      ? proj.logline
                      : (proj.premise.isEmpty ? '（暂无创意）' : proj.premise),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.5, color: _sub),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (proj.style.isNotEmpty) ...[
                    Flexible(child: _chip(proj.style, soft: true)),
                    const SizedBox(width: 6),
                  ],
                  if (proj.targetDuration.isNotEmpty)
                    _chip(proj.targetDuration, soft: true),
                  const Spacer(),
                  Text(
                    proj.shotCount > 0 ? '${proj.shotCount} 镜' : '未生成',
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

  // ------------------------------------------------------------- 工作区

  Widget _buildWorkspace(VideoService svc) {
    final proj = svc.current!;
    if (context.isCompact) {
      return Column(
        children: [
          _topBar(svc, proj),
          _mobileTabBar(),
          Expanded(
            child: _mobileTab == 0
                ? _leftPanel(svc, proj)
                : _rightPanel(svc, proj),
          ),
        ],
      );
    }
    return Column(
      children: [
        _topBar(svc, proj),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 380, child: _leftPanel(svc, proj)),
              const VerticalDivider(width: 1),
              Expanded(child: _rightPanel(svc, proj)),
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
      child: SegmentedButton<int>(
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: 0, label: Text('配置')),
          ButtonSegment(value: 1, label: Text('分镜')),
        ],
        selected: {_mobileTab},
        onSelectionChanged: (v) => setState(() => _mobileTab = v.first),
      ),
    );
  }

  Widget _topBar(VideoService svc, VideoProject proj) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFECECEE))),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回视频列表',
            onPressed: () {
              svc.close();
              _boundId = null;
            },
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              proj.title,
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
            Flexible(
              child: Text(
                svc.stage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: _sub),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => svc.cancel(),
              icon: const Icon(Icons.stop_circle_outlined, size: 16),
              label: const Text('停止'),
            ),
            const SizedBox(width: 8),
          ],
          FilledButton.icon(
            onPressed: svc.busy ? null : () => _generate(svc),
            style: FilledButton.styleFrom(backgroundColor: _accent),
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: Text(proj.shotCount > 0 ? '重新生成分镜' : '生成分镜脚本'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed:
                (svc.busy || proj.shotCount == 0) ? null : () => _export(svc, proj),
            icon: const Icon(Icons.ios_share, size: 16),
            label: const Text('导出脚本'),
          ),
        ],
      ),
    );
  }

  Widget _leftPanel(VideoService svc, VideoProject proj) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text('视频信息', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        TextField(
          controller: _title,
          decoration: const InputDecoration(
            labelText: '标题',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) {
            proj.title = v;
            proj.updatedAt = DateTime.now();
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _premise,
          minLines: 5,
          maxLines: 12,
          decoration: const InputDecoration(
            labelText: '创意 / 主题',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) {
            proj.premise = v;
            proj.updatedAt = DateTime.now();
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _style,
          decoration: const InputDecoration(
            labelText: '风格（如 广告片 / 宣传片 / 微电影，写实 / 动画…）',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) {
            proj.style = v;
            proj.updatedAt = DateTime.now();
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _duration,
          decoration: const InputDecoration(
            labelText: '目标时长（如 60秒）',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) {
            proj.targetDuration = v;
            proj.updatedAt = DateTime.now();
          },
        ),
      ],
    );
  }

  Widget _rightPanel(VideoService svc, VideoProject proj) {
    if (proj.shots.isEmpty && proj.synopsis.isEmpty) {
      return Container(
        color: const Color(0xFFFAFAFB),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.movie_creation_outlined,
                  size: 40, color: _muted),
              const SizedBox(height: 12),
              Text(
                svc.busy ? svc.stage : '填写创意后，点击顶部「生成分镜脚本」',
                style: const TextStyle(fontSize: 13, color: _muted),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      color: const Color(0xFFFAFAFB),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (proj.logline.isNotEmpty || proj.synopsis.isNotEmpty)
            _synopsisCard(proj),
          if (proj.shots.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(bottom: 10, left: 2),
              child: Text(
                '分镜表 · 共 ${proj.shots.length} 个镜头',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600, color: _sub),
              ),
            ),
            for (final shot in proj.shots) _shotCard(shot),
          ],
        ],
      ),
    );
  }

  Widget _synopsisCard(VideoProject proj) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (proj.logline.isNotEmpty) ...[
            Row(
              children: [
                const Icon(Icons.flare_outlined, size: 16, color: _accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    proj.logline,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (proj.synopsis.isNotEmpty) const SizedBox(height: 10),
          ],
          if (proj.synopsis.isNotEmpty)
            Text(
              proj.synopsis,
              style: const TextStyle(fontSize: 13, height: 1.6, color: _sub),
            ),
        ],
      ),
    );
  }

  Widget _shotCard(StoryboardShot shot) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFFF6F3FF),
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _accent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${shot.index}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (shot.scene.isNotEmpty) _badge(shot.scene, strong: true),
                      if (shot.shotSize.isNotEmpty) _badge(shot.shotSize),
                      if (shot.camera.isNotEmpty) _badge(shot.camera),
                      if (shot.duration.isNotEmpty) _badge(shot.duration),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (shot.visual.isNotEmpty) _field('画面', shot.visual),
                if (shot.action.isNotEmpty) _field('动作/演出', shot.action),
                if (shot.dialogue.isNotEmpty) _field('台词/旁白', shot.dialogue),
                if (shot.audio.isNotEmpty) _field('音效/音乐', shot.audio),
                if (shot.notes.isNotEmpty) _field('备注', shot.notes),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontSize: 13, height: 1.55, color: Color(0xFF2B2B2E)),
          children: [
            TextSpan(
              text: '$label：',
              style: const TextStyle(
                  fontWeight: FontWeight.w600, color: _sub),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }

  Widget _badge(String text, {bool strong = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: strong ? _accent.withValues(alpha: 0.14) : const Color(0xFFEFEFF2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            color: strong ? _accent : _sub,
            fontWeight: FontWeight.w500,
          ),
        ),
      );

  // -------------------------------------------------------------- 动作

  Future<void> _newVideo(VideoService svc) async {
    final title = TextEditingController();
    final premise = TextEditingController();
    final style = TextEditingController();
    final duration = TextEditingController();
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建视频'),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: '标题'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: premise,
                  minLines: 4,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    labelText: '创意 / 主题',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: style,
                  decoration: const InputDecoration(
                      labelText: '风格（可选，如 广告片 / 微电影）'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: duration,
                  decoration: const InputDecoration(
                      labelText: '目标时长（可选，如 60秒）'),
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
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (created == true && mounted) {
      final proj = svc.create(
        title: title.text,
        premise: premise.text,
        style: style.text,
        targetDuration: duration.text,
      );
      setState(() {
        _boundId = null;
        _bind(proj);
      });
    }
    title.dispose();
    premise.dispose();
    style.dispose();
    duration.dispose();
  }

  Future<void> _generate(VideoService svc) async {
    final proj = svc.current;
    if (proj == null) return;
    proj.title = _title.text.trim().isEmpty ? '未命名视频' : _title.text.trim();
    proj.premise = _premise.text.trim();
    proj.style = _style.text.trim();
    proj.targetDuration = _duration.text.trim();
    await svc.save();
    await svc.generateStoryboard();
    if (svc.stage.startsWith('生成分镜失败') || svc.stage.startsWith('请先')) {
      _toast(svc.stage);
    }
  }

  Future<void> _export(VideoService svc, VideoProject proj) async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择导出文件夹');
    if (dir == null) return;
    try {
      final safe = proj.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
      final name = '${safe.isEmpty ? '视频' : safe}-分镜脚本.md';
      final out = File('$dir${Platform.pathSeparator}$name');
      await out.writeAsString(svc.exportMarkdown(proj));
      _toast('已导出：$name');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  Future<void> _confirmDelete(VideoService svc, VideoProject proj) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除视频'),
        content: Text('确定删除《${proj.title}》吗？'),
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
    if (ok == true) await svc.delete(proj);
  }

  Widget _chip(String text, {bool soft = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: soft ? const Color(0xFFF1EEF9) : const Color(0xFFEDE7FB),
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
