import 'dart:convert';

import '../model_client.dart';

/// 沉淀出的一条候选技能（SOP）。
class CrystallizedSkill {
  CrystallizedSkill({
    required this.name,
    required this.description,
    required this.body,
    this.update,
  });

  final String name;

  /// 一句话适用场景（技能召回时靠它匹配任务）。
  final String description;

  /// SOP 正文：前置条件 / 步骤 / 关键命令 / 易错点。
  final String body;

  /// 若为对已有技能的更新，则为目标文件名；否则 null（新建）。
  final String? update;
}

/// 技能沉淀器（对应 GenericAgent 的"执行路径固化为 Skill"）：
/// 任务成功结束后，用**小模型**审视执行转写，判断其中是否有
/// 「未来同类任务可直接复用的执行路径」，有则提炼成一条 SOP。
/// 纪律与记忆抽取一致：宁缺毋滥，一次性任务不沉淀。
class SkillCrystallizer {
  SkillCrystallizer(this.model);

  /// 必须是小模型通道。
  final ModelClient model;

  static const _system = '''
你是技能沉淀器。一个 AI Agent 刚刚成功完成了一次任务，下面给你任务描述和执行转写。
判断这次执行是否形成了「未来遇到**同类任务**时可以直接照做的可复用执行路径」。
如果是，把它提炼成一条 SOP（标准作业程序）技能。

值得沉淀的例子：
- 摸索出了一套固定步骤（装某依赖→写某配置→跑某命令→验证）；
- 踩过坑并找到了正确做法（错误做法与正确做法都要写进易错点）；
- 一类任务的通用流程（如"给 Flutter 工程加新页面并接线"的固定套路）。

坚决不要沉淀：
- 一次性的、不会再遇到的任务（如修一个特定的拼写错误）；
- 没有可复用步骤、纯问答/纯浏览类的执行；
- 与已有技能重复的内容——若只是补充或修正某条已有技能，用 update 指向其文件名更新它，不要新建近似技能。

SOP 正文（body）结构要求，用 Markdown：
## 适用场景
（什么样的任务应该用这条 SOP）
## 前置条件
（需要什么环境/工具/信息）
## 步骤
（编号列出可直接执行的步骤，含关键命令/代码片段）
## 易错点
（踩过的坑、错误做法与规避方式；没有可省略）

只输出 JSON：
{"skill":{"name":"<=12字短名","description":"一句话适用场景","body":"SOP正文","update":"可选,要更新的已有技能文件名"}}
不值得沉淀就输出 {"skill":null}。不要编造未发生的步骤。''';

  /// 返回 null 表示本次执行不值得沉淀。
  Future<CrystallizedSkill?> crystallize({
    required String task,
    required String transcript,
    required String skillsManifest,
  }) async {
    if (transcript.trim().isEmpty) return null;
    final user = StringBuffer()
      ..writeln('【已有技能清单】')
      ..writeln(skillsManifest.trim().isEmpty ? '(空)' : skillsManifest)
      ..writeln()
      ..writeln('【任务描述】')
      ..writeln(_clip(task, 1500))
      ..writeln()
      ..writeln('【执行转写】')
      ..writeln(_clip(transcript, 12000));

    final turn = await model.stream(
      messages: [
        {'role': 'system', 'content': _system},
        {'role': 'user', 'content': user.toString()},
      ],
      jsonMode: true,
    );
    return _parse(turn.content);
  }

  CrystallizedSkill? _parse(String raw) {
    Map<String, dynamic>? obj;
    try {
      final start = raw.indexOf('{');
      final end = raw.lastIndexOf('}');
      if (start < 0 || end <= start) return null;
      obj = jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final skill = obj['skill'];
    if (skill is! Map) return null;
    final name = (skill['name'] ?? '').toString().trim();
    final description = (skill['description'] ?? '').toString().trim();
    final body = (skill['body'] ?? '').toString().trim();
    if (name.isEmpty || body.isEmpty) return null;
    final update = (skill['update'] ?? '').toString().trim();
    return CrystallizedSkill(
      name: name,
      description: description,
      body: body,
      update: update.isEmpty ? null : update,
    );
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}\n…（已截断）';
}
