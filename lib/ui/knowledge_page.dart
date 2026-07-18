import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models.dart';
import '../services/agent/memory/memory_service.dart';
import '../services/ai_client.dart';
import '../services/knowledge_service.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/topic_service.dart';
import 'graph_page.dart';
import 'responsive.dart';
import 'skill_library_view.dart';

class KnowledgePage extends StatefulWidget {
  const KnowledgePage({
    super.key,
    required this.library,
    required this.settings,
    required this.topicService,
    required this.memory,
    required this.onOpenNote,
    required this.onOpenTopic,
  });

  final LibraryService library;
  final SettingsService settings;
  final TopicFetchService topicService;
  final MemoryService memory;
  final void Function(StandardNote) onOpenNote;
  final VoidCallback onOpenTopic;

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);
  late final AiClient _ai = AiClient(widget.settings);

  bool _aiLoading = false;
  String? _aiText;
  List<String> _explore = [];
  bool _graphOpened = false;

  @override
  void initState() {
    super.initState();
    _tab.addListener(_handleTabChanged);
  }

  @override
  void dispose() {
    _tab.removeListener(_handleTabChanged);
    _tab.dispose();
    super.dispose();
  }

  void _handleTabChanged() {
    if (_tab.index == 1 && !_graphOpened) {
      setState(() => _graphOpened = true);
    }
  }

  Future<void> _diagnose(KnowledgeOverview o) async {
    if (_aiLoading) return;
    setState(() {
      _aiLoading = true;
      _aiText = null;
      _explore = [];
    });
    try {
      final prompt =
          '''
以下是「我的第二大脑」知识库的体系统计：
${KnowledgeAnalyzer.summaryForAi(o)}

请把它当作一个人的知识体系来诊断，输出 Markdown（不超过 600 字）：

## 知识画像
（这个人的知识由哪些方向构成、整体偏向什么领域、处于什么阶段）

## 长处
（覆盖扎实、掌握较好的方向，并说明依据）

## 短板与盲区
（薄弱、零散、缺失或几乎全未读的方向；逻辑上应该补充但尚未涉及的基础或前沿方向）

## 深入学习建议
（3-5 条具体、可执行的下一步：该读哪些已有笔记、该研究哪些新主题）

最后追加一个代码块，列出 3-6 个最值得「主题研究」的探索方向（简短中文短语）：
```explore
["方向1","方向2"]
```
''';
      var text = await _ai.complete(
        system: '你是一名学习教练与知识体系架构师，善于评估一个人的知识结构、发现盲区并给出可执行的学习路径。回答精炼、有洞察，用中文。',
        user: prompt,
      );
      final explore = _parseExplore(text);
      text = text.replaceAll(RegExp(r'```explore[\s\S]*?```'), '').trim();
      if (mounted) {
        setState(() {
          _aiText = text;
          _explore = explore;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _aiText = '诊断失败：$e');
    } finally {
      if (mounted) setState(() => _aiLoading = false);
    }
  }

  List<String> _parseExplore(String text) {
    final m = RegExp(r'```explore\s*([\s\S]*?)```').firstMatch(text);
    if (m == null) return [];
    try {
      final list = jsonDecode(m.group(1)!.trim());
      if (list is! List) return [];
      return [
        for (final x in list)
          if (x is String && x.trim().isNotEmpty) x.trim(),
      ];
    } catch (_) {
      return [];
    }
  }

  void _research(String topic) {
    widget.topicService.run(topic);
    widget.onOpenTopic();
  }

  @override
  Widget build(BuildContext context) {
    final hPad = context.isCompact ? 16.0 : 40.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(hPad, 24, hPad, 0),
          child: Row(
            children: [
              const Text(
                '知识体系',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: TabBar(
                  controller: _tab,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelColor: const Color(0xFF0D9488),
                  unselectedLabelColor: const Color(0xFF6B6B70),
                  indicatorColor: const Color(0xFF0D9488),
                  labelStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  tabs: const [
                    Tab(text: '体系概览'),
                    Tab(text: '关联网络'),
                    Tab(text: '技能库'),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              _buildOverview(),
              _graphOpened
                  ? GraphPage(
                      library: widget.library,
                      settings: widget.settings,
                      topicService: widget.topicService,
                      onOpenNote: widget.onOpenNote,
                      onOpenTopic: widget.onOpenTopic,
                    )
                  : const Center(
                      child: Text(
                        '切换到关联网络后加载知识图谱',
                        style: TextStyle(color: Color(0xFF9B9B9F)),
                      ),
                    ),
              // 技能库：Agent 自动沉淀的可复用执行路径（L3 记忆）。
              SkillLibraryView(memory: widget.memory),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOverview() {
    return ListenableBuilder(
      listenable: widget.library,
      builder: (context, _) {
        if (widget.library.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        final o = KnowledgeAnalyzer.analyze(widget.library.notes);
        if (o.isEmpty) {
          return const Center(
            child: Text(
              '知识库为空，先去「知识库」扫描或「主题研究」补充内容',
              style: TextStyle(color: Color(0xFF9B9B9F)),
            ),
          );
        }
        final compact = context.isCompact;
        return ListView(
          padding: EdgeInsets.fromLTRB(compact ? 16 : 40, 20, compact ? 16 : 40, 40),
          children: [
            _buildMetrics(o, compact),
            const SizedBox(height: 24),
            _sectionTitle('知识构成'),
            const SizedBox(height: 10),
            ...o.domains.map(_buildDomainRow),
            const SizedBox(height: 24),
            // 窄屏纵向堆叠长处/短板，宽屏并排。
            if (compact) ...[
              _buildStrengths(o),
              const SizedBox(height: 14),
              _buildWeaknesses(o),
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildStrengths(o)),
                  const SizedBox(width: 20),
                  Expanded(child: _buildWeaknesses(o)),
                ],
              ),
            const SizedBox(height: 24),
            _buildDiagnosis(o),
          ],
        );
      },
    );
  }

  Widget _sectionTitle(String t) => Text(
    t,
    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
  );

  Widget _buildMetrics(KnowledgeOverview o, [bool compact = false]) {
    Widget card(String label, String value, Color color, {String? sub}) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F7F8),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF6B6B70),
                ),
              ),
              if (sub != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    sub,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9B9B9F),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final c1 = card(
      '知识领域',
      '${o.domains.length}',
      const Color(0xFF1A1A1A),
      sub: '${o.totalNotes} 篇笔记',
    );
    final c2 = card(
      '整体掌握度',
      '${(o.masteryRatio * 100).round()}%',
      const Color(0xFF0D9488),
      sub: '已读 ${o.read} · 在读 ${o.reading} · 未读 ${o.unread}',
    );
    final c3 = card(
      '有原文',
      '${o.withOriginal}',
      const Color(0xFF14B8A6),
      sub: '${o.totalNotes - o.withOriginal} 篇无原文',
    );
    final c4 = card(
      '孤立笔记',
      '${o.isolated}',
      const Color(0xFFF59E0B),
      sub: '尚未与其他笔记关联',
    );
    if (compact) {
      // 窄屏 2×2 排布，避免四张卡横向挤压。
      return Column(
        children: [
          Row(children: [c1, const SizedBox(width: 14), c2]),
          const SizedBox(height: 14),
          Row(children: [c3, const SizedBox(width: 14), c4]),
        ],
      );
    }
    return Row(
      children: [
        c1,
        const SizedBox(width: 14),
        c2,
        const SizedBox(width: 14),
        c3,
        const SizedBox(width: 14),
        c4,
      ],
    );
  }

  Widget _buildDomainRow(DomainStat d) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  d.name,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                '${d.total} 篇 · 掌握 ${(d.mastery * 100).round()}%',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9B9B9F)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              children: [
                Container(height: 8, color: const Color(0xFFEDEDEF)),
                FractionallySizedBox(
                  widthFactor: d.mastery.clamp(0.02, 1.0),
                  child: Container(
                    height: 8,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF14B8A6), Color(0xFF0D9488)],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStrengths(KnowledgeOverview o) {
    return _panel(
      icon: Icons.trending_up,
      iconColor: const Color(0xFF16A34A),
      title: '长处',
      bg: const Color(0xFFF0FDF4),
      border: const Color(0xFFBBF7D0),
      child: o.strengths.isEmpty
          ? const Text(
              '暂无明显长处，继续积累与精读吧。',
              style: TextStyle(fontSize: 12.5, color: Color(0xFF6B6B70)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final d in o.strengths)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '· ${d.name}：${d.total} 篇，掌握度 ${(d.mastery * 100).round()}%',
                      style: const TextStyle(fontSize: 12.5, height: 1.5),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildWeaknesses(KnowledgeOverview o) {
    return _panel(
      icon: Icons.trending_down,
      iconColor: const Color(0xFFD97706),
      title: '短板',
      bg: const Color(0xFFFFFBEB),
      border: const Color(0xFFFDE68A),
      child: o.weaknesses.isEmpty && o.unread == 0
          ? const Text(
              '知识结构较均衡。',
              style: TextStyle(fontSize: 12.5, color: Color(0xFF6B6B70)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final d in o.weaknesses)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            '· ${d.name}：${d.total} 篇，掌握度 ${(d.mastery * 100).round()}%'
                            '${d.unread > 0 ? '，${d.unread} 篇未读' : ''}',
                            style: const TextStyle(fontSize: 12.5, height: 1.5),
                          ),
                        ),
                        const SizedBox(width: 6),
                        _miniBtn('深入研究', () => _research(d.name)),
                      ],
                    ),
                  ),
                if (o.unread > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '共 ${o.unread} 篇未读、${o.isolated} 篇孤立，建议优先消化。',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF9B9B9F),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _miniBtn(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFE3E3E6)),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 11, color: Color(0xFF0D9488)),
        ),
      ),
    );
  }

  Widget _panel({
    required IconData icon,
    required Color iconColor,
    required String title,
    required Color bg,
    required Color border,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: iconColor),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _buildDiagnosis(KnowledgeOverview o) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.psychology_outlined,
                size: 18,
                color: Color(0xFF1A1A1A),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'AI 体系诊断与探索建议',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              FilledButton.icon(
                onPressed: _aiLoading ? null : () => _diagnose(o),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1A1A1A),
                ),
                icon: _aiLoading
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.auto_awesome, size: 15),
                label: Text(
                  _aiLoading ? '诊断中…' : (_aiText == null ? '开始诊断' : '重新诊断'),
                ),
              ),
            ],
          ),
          if (_aiText == null && !_aiLoading)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                '让 AI 把你的知识库当作一个人的知识体系来诊断，给出画像、长处、盲区和下一步学习路径。',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF6B6B70)),
              ),
            ),
          if (_aiText != null) ...[
            const SizedBox(height: 14),
            MarkdownBody(
              data: _aiText!,
              styleSheet: MarkdownStyleSheet(
                p: const TextStyle(fontSize: 13, height: 1.7),
                h2: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
                listBullet: const TextStyle(fontSize: 13, height: 1.7),
              ),
            ),
            if (_explore.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text(
                '一键深入研究：',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6B6B70),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in _explore)
                    ActionChip(
                      avatar: const Icon(
                        Icons.travel_explore,
                        size: 15,
                        color: Color(0xFF0D9488),
                      ),
                      label: Text(t, style: const TextStyle(fontSize: 12.5)),
                      onPressed: widget.topicService.running
                          ? null
                          : () => _research(t),
                    ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}
