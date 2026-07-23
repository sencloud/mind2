import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/media_downloader.dart';
import '../services/self_learning_service.dart';

/// 「知识库自学习」配置与状态页。
///
/// 配置学习主题、轮询间隔、自主扩展、媒体采集与每轮上限；启停后台自学习循环，
/// 并实时展示当前状态与日志。窗口关闭后循环仍在后台运行（最小化到托盘）。
class SelfLearningPage extends StatefulWidget {
  const SelfLearningPage({super.key, required this.service});

  final SelfLearningService service;

  @override
  State<SelfLearningPage> createState() => _SelfLearningPageState();
}

class _SelfLearningPageState extends State<SelfLearningPage> {
  late SelfLearningConfig _cfg;
  late final TextEditingController _topicsCtrl;
  late final TextEditingController _intervalCtrl;
  late final TextEditingController _maxTopicsCtrl;
  late final TextEditingController _maxMediaCtrl;

  static const _accent = Color(0xFF6D28D9);

  @override
  void initState() {
    super.initState();
    _cfg = widget.service.config.copy();
    _topicsCtrl = TextEditingController(text: _cfg.topics.join('\n'));
    _intervalCtrl =
        TextEditingController(text: _cfg.intervalMinutes.toString());
    _maxTopicsCtrl =
        TextEditingController(text: _cfg.maxTopicsPerCycle.toString());
    _maxMediaCtrl =
        TextEditingController(text: _cfg.maxMediaPerTopic.toString());
  }

  @override
  void dispose() {
    _topicsCtrl.dispose();
    _intervalCtrl.dispose();
    _maxTopicsCtrl.dispose();
    _maxMediaCtrl.dispose();
    super.dispose();
  }

  SelfLearningConfig _collect() {
    final topics = _topicsCtrl.text
        .split('\n')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    return SelfLearningConfig(
      enabled: widget.service.config.enabled,
      topics: topics,
      intervalMinutes:
          int.tryParse(_intervalCtrl.text.trim()) ?? _cfg.intervalMinutes,
      autonomousExpand: _cfg.autonomousExpand,
      mediaEnabled: _cfg.mediaEnabled,
      saveMediaFiles: _cfg.saveMediaFiles,
      maxTopicsPerCycle:
          int.tryParse(_maxTopicsCtrl.text.trim()) ?? _cfg.maxTopicsPerCycle,
      maxMediaPerTopic:
          int.tryParse(_maxMediaCtrl.text.trim()) ?? _cfg.maxMediaPerTopic,
    );
  }

  Future<void> _save() async {
    final next = _collect();
    await widget.service.saveConfig(next);
    if (mounted) {
      _cfg = next.copy();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存配置')),
      );
    }
  }

  Future<void> _toggle() async {
    final svc = widget.service;
    if (svc.config.enabled) {
      await svc.stop();
    } else {
      // 启动前先保存最新配置。
      await svc.saveConfig(_collect());
      if (_collect().topics.isEmpty && !_cfg.autonomousExpand) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请先配置至少一个学习主题，或开启自主扩展')),
          );
        }
        return;
      }
      await svc.start();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('知识库自学习'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0.5,
      ),
      body: AnimatedBuilder(
        animation: widget.service,
        builder: (context, _) {
          return LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= 900;
              final config = _buildConfig(context);
              final status = _buildStatus(context);
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 5, child: config),
                    const VerticalDivider(width: 1),
                    Expanded(flex: 4, child: status),
                  ],
                );
              }
              return ListView(
                children: [config, const Divider(height: 1), status],
              );
            },
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 配置区
  // ---------------------------------------------------------------------------

  Widget _buildConfig(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('学习主题'),
          const SizedBox(height: 6),
          const Text(
            '每行一个主题。自学习会按主题定时研究、采集并整理进知识库。',
            style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _topicsCtrl,
            maxLines: 6,
            minLines: 4,
            decoration: const InputDecoration(
              hintText: '例如：\n大语言模型的记忆机制\n分布式系统一致性算法\n宋代美学',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle('学习节奏'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _numField(
                  label: '轮询间隔（分钟）',
                  controller: _intervalCtrl,
                  hint: '默认 120',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _numField(
                  label: '每轮主题数',
                  controller: _maxTopicsCtrl,
                  hint: '默认 2',
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _sectionTitle('学习方式'),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: _accent,
            value: _cfg.autonomousExpand,
            onChanged: (v) => setState(() => _cfg.autonomousExpand = v),
            title: const Text('AI 自主扩展子主题'),
            subtitle: const Text(
              '结合知识体系短板，自动发现并深入新的子主题（更耗算力）',
              style: TextStyle(fontSize: 12),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: _accent,
            value: _cfg.mediaEnabled,
            onChanged: (v) => setState(() => _cfg.mediaEnabled = v),
            title: const Text('采集视频字幕'),
            subtitle: const Text(
              '用 yt-dlp 检索相关视频，抓取平台字幕转成文字入库（字幕优先，不做语音转录）',
              style: TextStyle(fontSize: 12),
            ),
          ),
          if (_cfg.mediaEnabled) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Row(
                children: [
                  Expanded(
                    child: _numField(
                      label: '每主题采集条数',
                      controller: _maxMediaCtrl,
                      hint: '默认 3',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      activeThumbColor: _accent,
                      value: _cfg.saveMediaFiles,
                      onChanged: (v) => setState(() => _cfg.saveMediaFiles = v),
                      title: const Text('保存媒体文件', style: TextStyle(fontSize: 13)),
                      subtitle: const Text('额外下载视频本体到文件库（占空间）',
                          style: TextStyle(fontSize: 11)),
                    ),
                  ),
                ],
              ),
            ),
            if (!MediaDownloader.instance.available)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '当前平台未内置 yt-dlp，媒体采集将被跳过。',
                  style: TextStyle(fontSize: 12, color: Color(0xFFB45309)),
                ),
              ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _toggle,
                style: FilledButton.styleFrom(
                  backgroundColor: widget.service.config.enabled
                      ? const Color(0xFFDC2626)
                      : _accent,
                ),
                icon: Icon(
                  widget.service.config.enabled
                      ? Icons.stop
                      : Icons.play_arrow,
                ),
                label: Text(widget.service.config.enabled ? '停止自学习' : '开启自学习'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存配置'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: widget.service.running
                    ? null
                    : () => widget.service.runNow(),
                icon: const Icon(Icons.bolt_outlined, size: 18),
                label: const Text('立即学习一轮'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '提示：关闭窗口后应用会最小化到系统托盘，自学习在后台持续运行；'
            '在托盘图标右键可切换「开机自启动」，实现始终在线学习。',
            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 状态区
  // ---------------------------------------------------------------------------

  Widget _buildStatus(BuildContext context) {
    final svc = widget.service;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              _statusChip(svc),
              const Spacer(),
              TextButton.icon(
                onPressed: svc.logs.isEmpty ? null : svc.clearLogs,
                icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                label: const Text('清空日志'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _stat('已完成轮次', '${svc.cyclesCompleted}'),
              if (svc.currentTopic.isNotEmpty)
                _stat('当前主题', svc.currentTopic),
              if (svc.lastRunAt != null)
                _stat('上次运行', _fmt(svc.lastRunAt!)),
              if (svc.config.enabled && svc.nextRunAt != null)
                _stat('下次运行', _fmt(svc.nextRunAt!)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1),
        Expanded(
          child: svc.logs.isEmpty
              ? const Center(
                  child: Text('暂无日志',
                      style: TextStyle(color: Color(0xFF9CA3AF))),
                )
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(16),
                  itemCount: svc.logs.length,
                  itemBuilder: (context, i) {
                    final line = svc.logs[svc.logs.length - 1 - i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: SelectableText(
                        line,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          fontFamily: 'monospace',
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _statusChip(SelfLearningService svc) {
    final Color color;
    final String text;
    if (svc.running) {
      color = _accent;
      text = '学习中';
    } else if (svc.config.enabled) {
      color = const Color(0xFF16A34A);
      text = '已开启 · 待命';
    } else {
      color = const Color(0xFF9CA3AF);
      text = '已停止';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (svc.running)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
            )
          else
            Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
          Text(text,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
        Text(value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _sectionTitle(String t) => Text(
        t,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      );

  Widget _numField({
    required String label,
    required TextEditingController controller,
    String? hint,
  }) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  static String _fmt(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
