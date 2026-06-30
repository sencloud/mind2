import 'agent/agent_event.dart';

/// 单个待办事项的 AI 执行状态。
enum PlanStatus { idle, running, success, error }

/// 任务优先级（用于排序与配色）。none 表示未设置。
enum PlanPriority { high, medium, low, none }

/// 重复规则：到期或完成后自动生成下一次。
enum PlanRecur { none, daily, weekdays, weekly, monthly }

/// 关联引用的类型。
enum PlanLinkKind { project, research, note, url }

extension PlanPriorityX on PlanPriority {
  /// 排序权重：高优先级排前面。
  int get rank => switch (this) {
        PlanPriority.high => 0,
        PlanPriority.medium => 1,
        PlanPriority.low => 2,
        PlanPriority.none => 3,
      };

  String get label => switch (this) {
        PlanPriority.high => '高',
        PlanPriority.medium => '中',
        PlanPriority.low => '低',
        PlanPriority.none => '无',
      };
}

extension PlanRecurX on PlanRecur {
  String get label => switch (this) {
        PlanRecur.none => '不重复',
        PlanRecur.daily => '每天',
        PlanRecur.weekdays => '工作日',
        PlanRecur.weekly => '每周',
        PlanRecur.monthly => '每月',
      };

  /// 在 [from] 基础上推进到下一个发生日期；none 返回 null。
  DateTime? next(DateTime from) {
    switch (this) {
      case PlanRecur.none:
        return null;
      case PlanRecur.daily:
        return from.add(const Duration(days: 1));
      case PlanRecur.weekly:
        return from.add(const Duration(days: 7));
      case PlanRecur.monthly:
        // 简单地按月推进（跨月天数差异由 DateTime 归一化处理）。
        return DateTime(from.year, from.month + 1, from.day,
            from.hour, from.minute);
      case PlanRecur.weekdays:
        // 跳到下一个周一~周五。
        var d = from.add(const Duration(days: 1));
        while (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
          d = d.add(const Duration(days: 1));
        }
        return d;
    }
  }
}

/// 子任务 / AI 拆解出的执行步骤（可勾选）。
class PlanSubtask {
  PlanSubtask({required this.id, required this.title, this.done = false});

  final String id;
  String title;
  bool done;

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'done': done};

  factory PlanSubtask.fromJson(Map<String, dynamic> j) => PlanSubtask(
        id: j['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        title: j['title'] as String? ?? '',
        done: j['done'] as bool? ?? false,
      );
}

/// 一条关联引用：让 AI 执行时知道"相关的项目/研究/笔记/链接"。
class PlanLink {
  PlanLink({required this.kind, required this.label});

  final PlanLinkKind kind;
  String label; // 项目名 / 研究主题 / 笔记标题 / URL

  String get kindLabel => switch (kind) {
        PlanLinkKind.project => '项目',
        PlanLinkKind.research => '研究',
        PlanLinkKind.note => '笔记',
        PlanLinkKind.url => '链接',
      };

  Map<String, dynamic> toJson() => {'kind': kind.name, 'label': label};

  factory PlanLink.fromJson(Map<String, dynamic> j) => PlanLink(
        kind: PlanLinkKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => PlanLinkKind.note,
        ),
        label: j['label'] as String? ?? '',
      );
}

/// 一次 AI 执行的历史记录（可回看/对比）。
class PlanRun {
  PlanRun({
    required this.id,
    required this.startedAt,
    this.finishedAt,
    this.status = PlanStatus.idle,
    this.result = '',
    this.workdir,
    List<AgentEvent>? events,
  }) : events = events ?? [];

  final String id;
  final DateTime startedAt;
  DateTime? finishedAt;
  PlanStatus status;
  String result; // 最终总结（Markdown）
  String? workdir;

  /// 该次执行的结构化过程事件（持久化，便于回看）。
  final List<AgentEvent> events;

  Map<String, dynamic> toJson() => {
        'id': id,
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
        'status': status.name,
        'result': result,
        'workdir': workdir,
        'events': events.map((e) => e.toJson()).toList(),
      };

  factory PlanRun.fromJson(Map<String, dynamic> j) => PlanRun(
        id: j['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        startedAt:
            DateTime.tryParse(j['startedAt'] as String? ?? '') ?? DateTime.now(),
        finishedAt: DateTime.tryParse(j['finishedAt'] as String? ?? ''),
        // 历史记录里不会有 running（进程已结束），异常状态归位。
        status: PlanStatus.values.firstWhere(
          (s) => s.name == j['status'] && s != PlanStatus.running,
          orElse: () => PlanStatus.idle,
        ),
        result: j['result'] as String? ?? '',
        workdir: j['workdir'] as String?,
        events: (j['events'] as List?)
                ?.map((e) => AgentEvent.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

/// 一个「计划」待办事项：既是功能完整的 todo（日期/优先级/标签/子任务/备注/关联），
/// 又可交给第二大脑以 Agent 模式真正动手执行（先拆解确认→执行→沉淀历史）。
class PlanTodo {
  PlanTodo({
    required this.id,
    required this.title,
    required this.createdAt,
    this.done = false,
    this.notes = '',
    this.priority = PlanPriority.none,
    List<String>? tags,
    this.dueAt,
    this.recur = PlanRecur.none,
    this.autoRun = false,
    this.archived = false,
    List<PlanSubtask>? subtasks,
    List<PlanLink>? links,
    this.status = PlanStatus.idle,
    this.result = '',
    this.workdir,
    List<PlanRun>? runs,
    this.order = 0,
  })  : tags = tags ?? [],
        subtasks = subtasks ?? [],
        links = links ?? [],
        runs = runs ?? [];

  final String id;
  String title; // 待办内容 / 要执行的任务
  final DateTime createdAt;
  bool done; // 手动完成勾选

  String notes; // 备注 / 描述（Markdown）
  PlanPriority priority;
  List<String> tags;
  DateTime? dueAt; // 截止 / 计划时间
  PlanRecur recur; // 重复规则
  bool autoRun; // 到点是否自动执行
  bool archived; // 是否归档（从主列表折叠隐藏）

  List<PlanSubtask> subtasks; // 子任务 / AI 拆解的步骤
  List<PlanLink> links; // 关联引用

  PlanStatus status; // 最近一次 AI 执行状态
  String result; // 最近一次执行的最终总结（Markdown）
  String? workdir; // 最近一次执行所用的工作目录
  List<PlanRun> runs; // 执行历史

  int order; // 手动拖拽排序用的序号（同组内）

  /// 运行期：当前正在执行的过程事件（实时展示，结束后落到对应 PlanRun）。
  final List<AgentEvent> events = [];

  /// 运行期：AI 已拆解出步骤、等待用户确认后才真正执行。
  bool awaitingApproval = false;

  bool get running => status == PlanStatus.running;

  /// 子任务完成进度（已完成 / 总数）；无子任务返回 null。
  ({int done, int total})? get subtaskProgress {
    if (subtasks.isEmpty) return null;
    return (done: subtasks.where((s) => s.done).length, total: subtasks.length);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'done': done,
        'notes': notes,
        'priority': priority.name,
        'tags': tags,
        'dueAt': dueAt?.toIso8601String(),
        'recur': recur.name,
        'autoRun': autoRun,
        'archived': archived,
        'subtasks': subtasks.map((s) => s.toJson()).toList(),
        'links': links.map((l) => l.toJson()).toList(),
        'status': status.name,
        'result': result,
        'workdir': workdir,
        'runs': runs.map((r) => r.toJson()).toList(),
        'order': order,
      };

  factory PlanTodo.fromJson(Map<String, dynamic> j) => PlanTodo(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        createdAt:
            DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
        done: j['done'] as bool? ?? false,
        notes: j['notes'] as String? ?? '',
        priority: PlanPriority.values.firstWhere(
          (p) => p.name == j['priority'],
          orElse: () => PlanPriority.none,
        ),
        tags: (j['tags'] as List?)?.map((e) => e.toString()).toList() ?? [],
        dueAt: DateTime.tryParse(j['dueAt'] as String? ?? ''),
        recur: PlanRecur.values.firstWhere(
          (r) => r.name == j['recur'],
          orElse: () => PlanRecur.none,
        ),
        autoRun: j['autoRun'] as bool? ?? false,
        archived: j['archived'] as bool? ?? false,
        subtasks: (j['subtasks'] as List?)
                ?.map((e) => PlanSubtask.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        links: (j['links'] as List?)
                ?.map((e) => PlanLink.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        // 上次未跑完的 running 状态不恢复（进程已结束），统一归位 idle。
        status: PlanStatus.values.firstWhere(
          (s) => s.name == j['status'] && s != PlanStatus.running,
          orElse: () => PlanStatus.idle,
        ),
        result: j['result'] as String? ?? '',
        workdir: j['workdir'] as String?,
        runs: (j['runs'] as List?)
                ?.map((e) => PlanRun.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        order: j['order'] as int? ?? 0,
      );
}
