import '../models.dart';
import 'graph_service.dart';

/// 单个领域（分类）的知识统计。
class DomainStat {
  DomainStat(this.name);

  final String name;
  int total = 0;
  int read = 0; // 已读
  int reading = 0; // 在读
  int unread = 0; // 未读
  int withOriginal = 0; // 有原文
  int connections = 0; // 该领域笔记参与的引用连接数
  final List<StandardNote> notes = [];

  /// 掌握度：已读记 1 分、在读记 0.5 分。
  double get mastery => total == 0 ? 0 : (read + reading * 0.5) / total;

  /// 连接密度：平均每篇笔记的引用连接数。
  double get density => total == 0 ? 0 : connections / total;
}

/// 整个知识库的体系画像。
class KnowledgeOverview {
  KnowledgeOverview({
    required this.totalNotes,
    required this.read,
    required this.reading,
    required this.unread,
    required this.withOriginal,
    required this.isolated,
    required this.domains,
    required this.bySource,
    required this.strengths,
    required this.weaknesses,
    required this.isolatedNotes,
    required this.unreadNotes,
  });

  final int totalNotes;
  final int read;
  final int reading;
  final int unread;
  final int withOriginal;
  final int isolated; // 无任何引用连接的笔记数
  final List<DomainStat> domains; // 按数量降序
  final Map<String, int> bySource; // 来源分布
  final List<DomainStat> strengths;
  final List<DomainStat> weaknesses;
  final List<StandardNote> isolatedNotes;
  final List<StandardNote> unreadNotes;

  double get masteryRatio =>
      totalNotes == 0 ? 0 : (read + reading * 0.5) / totalNotes;

  bool get isEmpty => totalNotes == 0;
}

class KnowledgeAnalyzer {
  /// 基于笔记与图谱连接，计算知识体系画像。
  static KnowledgeOverview analyze(
    List<StandardNote> notes, {
    Map<String, int>? refDegreeByPath,
  }) {
    if (notes.isEmpty) {
      return KnowledgeOverview(
        totalNotes: 0,
        read: 0,
        reading: 0,
        unread: 0,
        withOriginal: 0,
        isolated: 0,
        domains: const [],
        bySource: const {},
        strengths: const [],
        weaknesses: const [],
        isolatedNotes: const [],
        unreadNotes: const [],
      );
    }

    // 引用连接度优先复用已构建的图谱；若图谱页尚未打开，则只计算轻量引用度，
    // 避免概览页预先创建完整节点/边/布局数据。
    final refDegree =
        refDegreeByPath ??
        GraphBuilder.cachedResult(notes)?.refDegreeByPath ??
        GraphBuilder.referenceDegreeByPath(notes);

    final domainMap = <String, DomainStat>{};
    final bySource = <String, int>{};
    var read = 0, reading = 0, unread = 0, withOriginal = 0, isolated = 0;
    final isolatedNotes = <StandardNote>[];
    final unreadNotes = <StandardNote>[];

    for (final n in notes) {
      final stat = domainMap.putIfAbsent(
        n.category,
        () => DomainStat(n.category),
      );
      stat.total++;
      stat.notes.add(n);
      stat.connections += refDegree[n.filePath] ?? 0;
      switch (n.status) {
        case '已读':
          read++;
          stat.read++;
          break;
        case '在读':
          reading++;
          stat.reading++;
          break;
        default:
          unread++;
          stat.unread++;
          unreadNotes.add(n);
      }
      if (n.attachmentRelPath != null) {
        withOriginal++;
        stat.withOriginal++;
      }
      final source = _sourceOf(n);
      bySource[source] = (bySource[source] ?? 0) + 1;
      if ((refDegree[n.filePath] ?? 0) == 0) {
        isolated++;
        isolatedNotes.add(n);
      }
    }

    final domains = domainMap.values.toList()
      ..sort((a, b) => b.total.compareTo(a.total));

    // 长处：覆盖较多且掌握度高、连接较密的领域。
    final strengths =
        domains.where((d) => d.total >= 2 && d.mastery >= 0.5).toList()..sort(
          (a, b) => (b.mastery * b.total).compareTo(a.mastery * a.total),
        );

    // 短板：掌握度低、或几乎全未读、或孤立连接少的领域。
    final weaknesses =
        domains.where((d) => d.mastery < 0.34 || d.density < 0.4).toList()
          ..sort((a, b) => a.mastery.compareTo(b.mastery));

    return KnowledgeOverview(
      totalNotes: notes.length,
      read: read,
      reading: reading,
      unread: unread,
      withOriginal: withOriginal,
      isolated: isolated,
      domains: domains,
      bySource: bySource,
      strengths: strengths.take(6).toList(),
      weaknesses: weaknesses.take(6).toList(),
      isolatedNotes: isolatedNotes,
      unreadNotes: unreadNotes,
    );
  }

  static String _sourceOf(StandardNote note) {
    final m = RegExp(
      r'^来源:\s*(.+)$',
      multiLine: true,
    ).firstMatch(note.frontmatterRaw);
    if (m != null) return m.group(1)!.trim();
    return '本地';
  }

  /// 生成给 AI 的体系摘要文本（控制长度）。
  static String summaryForAi(KnowledgeOverview o) {
    final buf = StringBuffer()
      ..writeln(
        '总笔记 ${o.totalNotes} 篇；已读 ${o.read}、在读 ${o.reading}、未读 ${o.unread}；'
        '整体掌握度 ${(o.masteryRatio * 100).round()}%；孤立笔记 ${o.isolated} 篇。',
      )
      ..writeln('各领域构成（领域 | 篇数 | 掌握度 | 平均连接）：');
    for (final d in o.domains) {
      buf.writeln(
        '- ${d.name} | ${d.total} | ${(d.mastery * 100).round()}% | '
        '${d.density.toStringAsFixed(1)}',
      );
    }
    if (o.bySource.isNotEmpty) {
      buf.writeln(
        '来源分布：${o.bySource.entries.map((e) => '${e.key}×${e.value}').join('，')}',
      );
    }
    return buf.toString();
  }
}
