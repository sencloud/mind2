/// 记忆系统的「类型规范」与提示词段（移植自 Claude Code 的 memdir/memoryTypes.ts，中文化）。
///
/// 设计要点（对照 refs.md）：
/// - 结构化优于自由文本：每条记忆都必须落在四类型之一，并带 frontmatter（name/description/type）。
/// - 索引常驻 + 内容按需：`MEMORY.md` 只存一行一条的索引；正文按需加载。
/// - 廉价模型做选择题：选择器/抽取器用小模型。
/// - 时间感知 + 主动验证：记忆是「某一时刻的快照」，用前先核实。
library;

/// 四种记忆类型。前两类属于「全局库」（跨功能、关于用户本人），
/// 后两类属于「项目库」（关于某个工程/研究）。
enum MemoryType {
  /// 关于用户是谁、长期稳定的画像与偏好（跨功能共享）。
  user,

  /// 用户给出的纠正 / 反馈 / 明确表达过的好恶（跨功能共享）。
  feedback,

  /// 某个工程/研究的事实、结构、约定、决策（项目库）。
  project,

  /// 与某个工程/研究相关的外部参考、资料指针、链接（项目库）。
  reference,
}

extension MemoryTypeX on MemoryType {
  String get id => switch (this) {
        MemoryType.user => 'user',
        MemoryType.feedback => 'feedback',
        MemoryType.project => 'project',
        MemoryType.reference => 'reference',
      };

  String get label => switch (this) {
        MemoryType.user => '用户画像',
        MemoryType.feedback => '反馈纠正',
        MemoryType.project => '项目事实',
        MemoryType.reference => '参考资料',
      };

  /// 是否属于全局库（关于用户本人、跨功能）。否则属于项目库。
  bool get isGlobal =>
      this == MemoryType.user || this == MemoryType.feedback;

  /// 正文是否强制 `**Why:** / **How to apply:**` 结构（反馈/项目类需要）。
  bool get needsWhyHow =>
      this == MemoryType.feedback || this == MemoryType.project;
}

MemoryType? parseMemoryType(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'user':
      return MemoryType.user;
    case 'feedback':
      return MemoryType.feedback;
    case 'project':
      return MemoryType.project;
    case 'reference':
      return MemoryType.reference;
  }
  return null;
}

/// 记忆系统涉及的所有提示词段，集中放置便于复用与维护。
class MemoryPrompts {
  /// 四类型说明 + 何时该记 + 正文结构（供抽取器使用）。
  static const typesGuide = '''
记忆分为四种类型，必须二选一归类：
- user（用户画像）：关于用户本人、长期稳定的事实与偏好（身份、研究方向、习惯用的工具/语言、长期目标）。跨功能共享。
- feedback（反馈纠正）：用户明确给出的纠正、好恶、规则（"以后别这么做""我更喜欢 X"）。跨功能共享。
- project（项目事实）：某个工程/研究内可复用的事实、结构、约定、关键决策与其原因。
- reference（参考资料）：与该工程/研究相关的外部资料、链接、文件指针。

正文结构要求：
- feedback / project 类正文必须包含两段：
  **Why:** 为什么值得记（背景/原因）。
  **How to apply:** 以后在什么情形下、怎样应用这条记忆。
- user / reference 类正文为简洁的事实陈述即可。
''';

  /// 什么坚决不要记（噪音纪律）。
  static const whatNotToSave = '''
坚决不要记录：
- 一次性的、不会复用的临时信息（某次具体报错的堆栈、临时变量值）。
- 能从代码/文件里随时直接读到的内容（用核实代替记忆）。
- 含密钥、令牌、口令等敏感凭据。
- 含糊、无行动指向、记了也用不上的"感想"。
- 与已有记忆重复的内容（应更新已有条目而非新建）。
宁可少记、准记，也不要堆噪音。''';

  /// 抽取器：把本轮对话抽成结构化记忆的指令（要求只输出 JSON）。
  static String extractionSystem({
    required String globalManifest,
    required String projectManifest,
  }) =>
      '''
你是记忆抽取器。读完本轮对话转写后，判断有没有「值得长期记住、未来能复用」的信息，抽成结构化记忆。

$typesGuide

$whatNotToSave

去重：下面是已存在的记忆清单（含 type 与一句话描述）。若新信息与某条重复或只是补充，请用 update 指向其文件名，不要新建近似条目。
【全局库现有记忆】
${globalManifest.trim().isEmpty ? '(空)' : globalManifest}
【项目库现有记忆】
${projectManifest.trim().isEmpty ? '(空)' : projectManifest}

只输出 JSON，格式：
{"memories":[{"type":"user|feedback|project|reference","name":"<=8字短标题","description":"一句话索引描述","body":"正文(feedback/project 含 Why/How to apply)","update":"可选,要更新的已有文件名"}]}
没有任何值得记的，就返回 {"memories":[]}。不要编造，不要把一次性信息硬记。''';

  /// 选择器：从索引里挑相关记忆的严苛系统提示（移植 findRelevantMemories 的"不确定就别选"）。
  static const selectionSystem = '''
你是记忆选择器。下面给你一份记忆清单（每行：[type] 文件名 (时间): 描述）和当前的用户请求。
只选出**确实与当前请求相关、能帮上忙**的记忆，最多 5 条。

严苛标准：
- 不确定是否相关，就**不要选**。宁缺毋滥。
- 只能从清单里给出的文件名中选，不得编造文件名。
- 与当前请求无关的用户画像/历史项目事实，一律不选。

只输出 JSON：{"files":["a.md","b.md"]}。没有相关的就返回 {"files":[]}。''';

  /// 自进化守则（对应 GenericAgent 的 L0 元规则补充）：
  /// 告诉 Agent 如何使用注入的技能 SOP 与工作记事板。
  static const evolutionGuide = '''
## 自进化守则
- 若会话开头注入了「技能 SOP」（过去成功完成同类任务的标准流程），**优先按 SOP 执行**；
  执行中发现 SOP 与现实不符时，以现实为准并自行探索，不要僵化照搬。
- 长任务（预计超过 5 轮）中，请在关键节点调用 update_working_checkpoint 更新工作记事板：
  写清「目标 / 已完成 / 下一步 / 关键结论」。上下文被压缩后记事板会保留，
  这是你唯一不会丢失的短期备忘。切换阶段、得出重要中间结论时务必更新。''';

  /// 主动验证段（移植 TRUSTING_RECALL_SECTION）：记忆是时间快照，用前先核实。
  static const trustingRecall = '''
## 关于"回忆"的纪律
注入给你的记忆是**过去某一时刻的快照**，当前的代码/文件/环境可能已经变了。
- 在依据某条记忆采取行动前，先用工具核实：grep 搜索相关函数/符号、读对应文件、确认路径仍存在。
- 若记忆带有"过时警告"（system-reminder 标注 N 天前），尤其要先核实再用。
- 记忆与现实冲突时，以**现实为准**，并据此更新你的判断。''';

  /// 组装进 system prompt 的「如何使用记忆 + 索引」说明块。
  /// [globalIndex] / [projectIndex] 为已截断的 MEMORY.md 索引正文，可为空。
  static String systemBlock({
    required String globalIndex,
    String projectIndex = '',
  }) {
    final buf = StringBuffer()
      ..writeln('# 你的记忆')
      ..writeln(
          '下面是长期记忆的**索引**（只是指针，不是全文）。相关记忆的正文会在需要时另行注入。')
      ..writeln('用记忆前请遵守上面的"回忆纪律"：先核实，再行动。')
      ..writeln();
    if (globalIndex.trim().isNotEmpty) {
      buf
        ..writeln('## 全局记忆索引（关于用户本人）')
        ..writeln(globalIndex.trim())
        ..writeln();
    }
    if (projectIndex.trim().isNotEmpty) {
      buf
        ..writeln('## 项目记忆索引（关于当前工程/研究）')
        ..writeln(projectIndex.trim())
        ..writeln();
    }
    if (globalIndex.trim().isEmpty && projectIndex.trim().isEmpty) {
      return '';
    }
    return buf.toString().trimRight();
  }
}
