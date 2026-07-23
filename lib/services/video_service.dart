import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'agent/model_client.dart';
import 'settings_service.dart';

/// 一个分镜（一个镜头）。
class StoryboardShot {
  StoryboardShot({
    required this.index,
    this.scene = '',
    this.shotSize = '',
    this.camera = '',
    this.duration = '',
    this.visual = '',
    this.action = '',
    this.dialogue = '',
    this.audio = '',
    this.notes = '',
  });

  /// 镜号（从 1 开始）。
  int index;

  /// 场景 / 地点。
  String scene;

  /// 景别（远景/全景/中景/近景/特写等）。
  String shotSize;

  /// 运镜 / 机位（推拉摇移、固定、跟拍等）。
  String camera;

  /// 时长（如 "3s"）。
  String duration;

  /// 画面描述（镜头里看到什么）。
  String visual;

  /// 动作 / 演出（人物动作、调度、演出重点）。
  String action;

  /// 台词 / 旁白 / 字幕。
  String dialogue;

  /// 音效 / 音乐 / 音频提示。
  String audio;

  /// 备注（转场、特效、注意事项）。
  String notes;

  Map<String, dynamic> toJson() => {
    'index': index,
    'scene': scene,
    'shotSize': shotSize,
    'camera': camera,
    'duration': duration,
    'visual': visual,
    'action': action,
    'dialogue': dialogue,
    'audio': audio,
    'notes': notes,
  };

  factory StoryboardShot.fromJson(Map<String, dynamic> j) => StoryboardShot(
    index: (j['index'] as num?)?.toInt() ?? 0,
    scene: j['scene'] as String? ?? '',
    shotSize: j['shotSize'] as String? ?? '',
    camera: j['camera'] as String? ?? '',
    duration: j['duration'] as String? ?? '',
    visual: j['visual'] as String? ?? '',
    action: j['action'] as String? ?? '',
    dialogue: j['dialogue'] as String? ?? '',
    audio: j['audio'] as String? ?? '',
    notes: j['notes'] as String? ?? '',
  );
}

/// 一个视频项目：创意/主题 + 风格 + 目标时长 + 梗概 + 分镜脚本。
class VideoProject {
  VideoProject({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.premise = '',
    this.style = '',
    this.targetDuration = '',
    this.logline = '',
    this.synopsis = '',
    List<StoryboardShot>? shots,
  }) : shots = shots ?? [];

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;

  /// 创意 / 主题 / 简介（用户输入的核心想法或脚本梗概）。
  String premise;

  /// 风格（如「短视频/广告片/宣传片/微电影」「写实/动画/赛博朋克」等）。
  String style;

  /// 目标时长（如 "60秒"）。
  String targetDuration;

  /// 一句话概括（logline）。
  String logline;

  /// 故事梗概（模型生成，供分镜前对齐叙事）。
  String synopsis;

  /// 分镜脚本。
  List<StoryboardShot> shots;

  int get shotCount => shots.length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'premise': premise,
    'style': style,
    'targetDuration': targetDuration,
    'logline': logline,
    'synopsis': synopsis,
    'shots': shots.map((e) => e.toJson()).toList(),
  };

  factory VideoProject.fromJson(Map<String, dynamic> j) => VideoProject(
    id: j['id'] as String,
    title: j['title'] as String? ?? '未命名视频',
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
    premise: j['premise'] as String? ?? '',
    style: j['style'] as String? ?? '',
    targetDuration: j['targetDuration'] as String? ?? '',
    logline: j['logline'] as String? ?? '',
    synopsis: j['synopsis'] as String? ?? '',
    shots: ((j['shots'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => StoryboardShot.fromJson(e.cast<String, dynamic>()))
        .toList(),
  );
}

/// 「视频」业务：目前实现「生成分镜脚本」——据创意/主题/风格/时长，
/// 用大模型产出故事梗概与逐镜分镜表。
class VideoService extends ChangeNotifier {
  VideoService(this.settings);

  final SettingsService settings;

  final List<VideoProject> projects = [];
  VideoProject? current;
  bool busy = false;
  String stage = '';

  bool _cancel = false;
  File? _store;

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _store = File(p.join(dir.path, 'videos.json'));
    if (await _store!.exists()) {
      try {
        final data = jsonDecode(await _store!.readAsString());
        if (data is List) {
          projects
            ..clear()
            ..addAll(
              data.whereType<Map>().map(
                (e) => VideoProject.fromJson(e.cast<String, dynamic>()),
              ),
            );
          projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        }
      } catch (_) {}
    }
  }

  VideoProject create({
    String title = '',
    String premise = '',
    String style = '',
    String targetDuration = '',
  }) {
    final now = DateTime.now();
    final proj = VideoProject(
      id: now.microsecondsSinceEpoch.toString(),
      title: title.trim().isEmpty ? '未命名视频' : title.trim(),
      createdAt: now,
      updatedAt: now,
      premise: premise.trim(),
      style: style.trim(),
      targetDuration: targetDuration.trim(),
    );
    projects.insert(0, proj);
    current = proj;
    notifyListeners();
    _persist();
    return proj;
  }

  void open(VideoProject proj) {
    current = proj;
    notifyListeners();
  }

  void close() {
    current = null;
    notifyListeners();
  }

  Future<void> delete(VideoProject proj) async {
    projects.remove(proj);
    if (current == proj) current = null;
    notifyListeners();
    await _persist();
  }

  Future<void> save() async {
    final proj = current;
    if (proj == null) return;
    proj.updatedAt = DateTime.now();
    projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    notifyListeners();
    await _persist();
  }

  /// 生成分镜脚本：先产出/更新一句话概括与故事梗概，再产出逐镜分镜表。
  Future<void> generateStoryboard([VideoProject? target]) async {
    final proj = target ?? current;
    if (proj == null || busy) return;
    if (proj.premise.trim().isEmpty) {
      stage = '请先填写「创意 / 主题」再生成分镜';
      notifyListeners();
      return;
    }
    _begin('正在构思分镜脚本…');
    try {
      final reply = await ModelClient(settings, role: ModelRole.writing)
          .complete(
            system:
                '你是资深短视频/影视导演与分镜师。你依据创意、风格与目标时长，产出专业、可拍摄、'
                '镜头语言明确的分镜脚本。分镜要覆盖完整叙事（开场→发展→高潮→收尾），镜头之间有节奏与逻辑。'
                '只输出一个 JSON 对象，不要解释、不要代码围栏。',
            user: _prompt(proj),
            jsonMode: true,
            isCancelled: () => _cancel,
          );
      if (_cancel) return;
      final obj = ModelClient.parseJsonObject(reply);
      proj.logline = (obj['logline'] ?? proj.logline).toString().trim();
      proj.synopsis = (obj['synopsis'] ?? proj.synopsis).toString().trim();
      final rawShots = (obj['shots'] as List?) ?? const [];
      final shots = <StoryboardShot>[];
      var i = 0;
      for (final raw in rawShots.whereType<Map>()) {
        i++;
        final m = raw.cast<String, dynamic>();
        shots.add(
          StoryboardShot(
            index: (m['index'] as num?)?.toInt() ?? i,
            scene: (m['scene'] ?? '').toString().trim(),
            shotSize: (m['shotSize'] ?? '').toString().trim(),
            camera: (m['camera'] ?? '').toString().trim(),
            duration: (m['duration'] ?? '').toString().trim(),
            visual: (m['visual'] ?? '').toString().trim(),
            action: (m['action'] ?? '').toString().trim(),
            dialogue: (m['dialogue'] ?? '').toString().trim(),
            audio: (m['audio'] ?? '').toString().trim(),
            notes: (m['notes'] ?? '').toString().trim(),
          ),
        );
      }
      if (shots.isEmpty) throw Exception('模型未返回分镜');
      // 规范镜号连续。
      for (var k = 0; k < shots.length; k++) {
        shots[k].index = k + 1;
      }
      proj.shots = shots;
      proj.updatedAt = DateTime.now();
      stage = '已生成 ${shots.length} 个分镜';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '生成分镜失败：$e';
    } finally {
      if (_cancel) stage = '已停止';
      _end();
    }
  }

  /// 停止正在进行的分镜生成。
  void cancel() {
    if (!busy) return;
    _cancel = true;
    stage = '正在停止…';
    notifyListeners();
  }

  /// 导出分镜脚本为 Markdown（返回文本），供页面写文件。
  String exportMarkdown(VideoProject proj) {
    final buf = StringBuffer()
      ..writeln('# ${proj.title} · 分镜脚本')
      ..writeln();
    if (proj.style.trim().isNotEmpty) buf.writeln('- 风格：${proj.style.trim()}');
    if (proj.targetDuration.trim().isNotEmpty) {
      buf.writeln('- 目标时长：${proj.targetDuration.trim()}');
    }
    if (proj.logline.trim().isNotEmpty) {
      buf.writeln('- 一句话概括：${proj.logline.trim()}');
    }
    buf.writeln();
    if (proj.synopsis.trim().isNotEmpty) {
      buf
        ..writeln('## 故事梗概')
        ..writeln()
        ..writeln(proj.synopsis.trim())
        ..writeln();
    }
    buf
      ..writeln('## 分镜表')
      ..writeln()
      ..writeln('| 镜号 | 场景 | 景别 | 运镜 | 时长 | 画面 | 动作/演出 | 台词/旁白 | 音效/音乐 | 备注 |')
      ..writeln('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |');
    for (final s in proj.shots) {
      String c(String v) => v.replaceAll('|', '/').replaceAll('\n', ' ').trim();
      buf.writeln(
        '| ${s.index} | ${c(s.scene)} | ${c(s.shotSize)} | ${c(s.camera)} | '
        '${c(s.duration)} | ${c(s.visual)} | ${c(s.action)} | ${c(s.dialogue)} | '
        '${c(s.audio)} | ${c(s.notes)} |',
      );
    }
    return buf.toString();
  }

  String _prompt(VideoProject proj) {
    return '''
请为下面的视频创意设计一份专业的**分镜脚本**。

视频标题：${proj.title}
创意 / 主题：
${proj.premise.trim()}
风格：${proj.style.trim().isEmpty ? '（未指定，请你依据主题给出合适风格）' : proj.style.trim()}
目标时长：${proj.targetDuration.trim().isEmpty ? '（未指定，请你给出合适时长并据此安排镜头数量与节奏）' : proj.targetDuration.trim()}

要求：
- 先给出一句话概括（logline）与一段故事梗概（synopsis），确保叙事完整、有吸引力。
- 再给出逐镜分镜：镜头数量与总时长匹配目标时长（如无指定则自定），一般 8~24 个镜头，节奏张弛有度。
- 每个镜头字段：index（镜号，从1递增）、scene（场景/地点）、shotSize（景别：远景/全景/中景/近景/特写等）、
  camera（运镜/机位：固定、推、拉、摇、移、跟、升降等）、duration（时长，如 "3s"）、visual（画面描述，看到什么）、
  action（动作/演出/调度）、dialogue（台词/旁白/字幕，无则留空）、audio（音效/音乐/氛围声）、notes（转场/特效/备注）。
- 镜头语言专业、可执行；画面描述具体、有画面感；音画配合、转场自然。

严格只输出 JSON：
{"logline":"...","synopsis":"...","shots":[{"index":1,"scene":"...","shotSize":"...","camera":"...","duration":"3s","visual":"...","action":"...","dialogue":"...","audio":"...","notes":"..."}]}
''';
  }

  void _begin(String message) {
    busy = true;
    _cancel = false;
    stage = message;
    notifyListeners();
  }

  void _end() {
    busy = false;
    notifyListeners();
  }

  Future<void> _persist() async {
    if (_store == null) return;
    try {
      await _store!.writeAsString(
        jsonEncode(projects.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }
}
