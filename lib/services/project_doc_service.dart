import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'agent/agent_loop.dart';
import 'agent/agent_runner.dart';
import 'agent/memory/memory_service.dart';
import 'agent/messages.dart';
import 'agent/model_client.dart';
import 'agent/reporter.dart';
import 'code_index_service.dart';
import 'document_service.dart';
import 'library_service.dart';
import 'project_doc_store.dart';
import 'ripgrep.dart';
import 'settings_service.dart';

/// 一类标准项目文档：定义文档的分类、写作结构要求，以及生成时应重点结合的工程信息。
class ProjectDocCategory {
  const ProjectDocCategory({
    required this.id,
    required this.order,
    required this.name,
    required this.group,
    required this.description,
    required this.structure,
    required this.focus,
  });

  final String id;

  /// 文件序号（用于输出文件名前缀，如 06-数据库设计说明书.docx）。
  final int order;
  final String name;

  /// 分组（计划、需求、设计、测试、交付/运维）。
  final String group;

  /// 一句话说明该文档用途。
  final String description;

  /// 建议的章节结构与写作要求。
  final String structure;

  /// 生成该文档时应重点从工程代码中挖掘/结合的信息。
  final String focus;

  /// 带序号的输出文件基名（不含扩展名）。
  String get fileBase => '${order.toString().padLeft(2, '0')}-$name';
}

/// 已上传的文档模版：某分类对应的模版文件与其解析出的结构文本。
class ProjectDocTemplate {
  ProjectDocTemplate({
    required this.categoryId,
    required this.fileName,
    required this.filePath,
    required this.text,
  });

  final String categoryId;
  final String fileName;
  final String filePath;
  final String text;

  Map<String, dynamic> toJson() => {
        'categoryId': categoryId,
        'fileName': fileName,
        'filePath': filePath,
        'text': text,
      };

  factory ProjectDocTemplate.fromJson(Map<String, dynamic> j) =>
      ProjectDocTemplate(
        categoryId: j['categoryId'] as String? ?? '',
        fileName: j['fileName'] as String? ?? '',
        filePath: j['filePath'] as String? ?? '',
        text: j['text'] as String? ?? '',
      );
}

enum DocGenState { pending, running, done, error }

/// 一份文档在本次生成任务中的进度项。
class DocGenItem {
  DocGenItem({required this.categoryId, required this.name});

  final String categoryId;
  final String name;
  DocGenState state = DocGenState.pending;
  String? outputPath;
  String? error;

  /// 已生成的字数（正文实时字符数），用于进度展示。
  int chars = 0;
}

/// 「按项目写文档」服务：
/// - 维护一套标准项目文档分类（计划/需求/设计/测试/交付等）；
/// - 管理各分类的文档模版（上传 docx/xlsx，解析其结构作为生成参考）；
/// - 对某个工程：先用 Agent 深入阅读代码、理解整体结构（含子工程），
///   再结合模版逐个功能模块输出文档（Markdown → docx），全程实时上报进度。
class ProjectDocService extends ChangeNotifier {
  ProjectDocService(this.settings, this.memory, this.documents, this.library)
      : _model = ModelClient(settings),
        _writer = ModelClient(settings, role: ModelRole.writing) {
    _runner = AgentRunner(model: _model, memory: memory);
  }

  final SettingsService settings;
  final MemoryService memory;
  final DocumentService documents;

  /// 全局知识库服务：生成文档同时写入 vault 笔记（并触发重扫）。
  final LibraryService library;
  final ModelClient _model;
  final ModelClient _writer;
  late final AgentRunner _runner;

  /// 按项目持久化「文档撰写」记录（分析/功能树/文档/节点文档）。
  final ProjectDocStore store = ProjectDocStore();

  /// 标准文档分类（对齐常见软件工程交付文档体系）。
  static const List<ProjectDocCategory> categories = [
    ProjectDocCategory(
      id: 'plan',
      order: 1,
      name: '项目计划书',
      group: '计划',
      description: '明确项目目标、范围、进度、资源与里程碑。',
      structure:
          '项目背景与目标、建设范围、总体方案概述、里程碑与进度计划、组织分工与角色、资源与工具、风险与应对、交付物清单。',
      focus:
          '从工程规模（模块数量、技术栈、子工程划分）与已实现功能，反推项目范围与实施计划；结合实际目录结构说明交付物。',
    ),
    ProjectDocCategory(
      id: 'review',
      order: 2,
      name: '项目评审报告',
      group: '计划',
      description: '记录项目/方案评审的结论与整改意见。',
      structure:
          '评审概述（时间、范围、依据）、评审内容与要点、发现的问题与风险、评审结论、整改建议与跟踪。',
      focus:
          '基于代码质量、架构合理性、模块耦合、测试覆盖等客观现状，形成评审要点与结论。',
    ),
    ProjectDocCategory(
      id: 'requirement',
      order: 3,
      name: '项目需求分析说明书',
      group: '需求',
      description: '描述系统的业务需求、功能需求与非功能需求。',
      structure:
          '引言（背景、目的、范围）、总体业务描述、用户角色与场景、功能需求（逐功能模块：输入/处理/输出/规则）、数据需求、接口需求、非功能需求（性能/安全/可用性）、验收标准。',
      focus:
          '从各功能模块的实现代码逆向梳理业务需求：入口/路由、服务方法、校验规则、数据流；逐个模块给出功能需求条目。',
    ),
    ProjectDocCategory(
      id: 'outline_design',
      order: 4,
      name: '项目概要设计说明书',
      group: '设计',
      description: '描述系统总体架构与模块划分。',
      structure:
          '总体架构（分层/组件/部署）、模块划分与职责、模块间关系与调用、总体数据结构、关键技术选型、接口与集成概述、运行环境。',
      focus:
          '总体理解工程结构（含子工程/服务划分），画出模块清单与依赖关系，说明技术栈与分层架构。',
    ),
    ProjectDocCategory(
      id: 'interface',
      order: 5,
      name: '项目接口规格说明书',
      group: '设计',
      description: '描述系统对内对外的接口规格。',
      structure:
          '接口概述、接口清单、每个接口的：地址/方法、请求参数、响应结构、状态码/错误码、鉴权方式、调用示例。',
      focus:
          '从路由/控制器/API 定义、RPC/服务方法中提取全部接口，逐一给出请求响应结构与参数说明。',
    ),
    ProjectDocCategory(
      id: 'database',
      order: 6,
      name: '数据库设计说明书',
      group: '设计',
      description: '描述数据库的库表结构与设计。',
      structure:
          '数据库概述、E-R 关系、库表清单、每张表的字段（名称/类型/约束/说明）、索引、关键约束与关系、初始化数据说明。',
      focus:
          '从建表脚本(sql/迁移文件)、ORM 实体/模型定义中还原表结构与字段，整理表清单与字段明细表格及表间关系。',
    ),
    ProjectDocCategory(
      id: 'detail_design',
      order: 7,
      name: '详细设计说明书',
      group: '设计',
      description: '描述各模块的详细实现设计。',
      structure:
          '逐功能模块：模块职责、类/函数设计、核心算法与处理流程、时序/状态说明、关键数据结构、异常处理、与其它模块的交互。',
      focus:
          '深入阅读每个功能模块的核心实现代码，逐模块描述类与方法、处理流程与关键逻辑。',
    ),
    ProjectDocCategory(
      id: 'test_plan',
      order: 8,
      name: '项目测试方案及计划',
      group: '测试',
      description: '规划测试范围、策略、环境与进度。',
      structure:
          '测试目标与范围、测试策略（单元/集成/系统/验收）、测试环境、测试进度安排、资源与分工、风险、通过/退出准则。',
      focus:
          '结合功能模块与接口清单确定测试范围；参考现有测试代码/框架说明测试策略与环境。',
    ),
    ProjectDocCategory(
      id: 'test_record',
      order: 9,
      name: '测试记录',
      group: '测试',
      description: '记录测试用例的执行情况。',
      structure:
          '用例清单表格（用例编号、模块、前置条件、步骤、预期结果、实际结果、结论），按功能模块组织。',
      focus:
          '依据各功能模块与接口，逐模块设计典型测试用例，以表格形式列出用例与预期结果。',
    ),
    ProjectDocCategory(
      id: 'test_report',
      order: 10,
      name: '测试报告',
      group: '测试',
      description: '汇总测试结果与质量结论。',
      structure:
          '测试概述、测试范围与用例统计、缺陷统计与分析、覆盖情况、遗留问题、质量评估与结论。',
      focus:
          '基于功能模块与用例情况，形成覆盖统计与质量结论，客观评估系统实现质量。',
    ),
    ProjectDocCategory(
      id: 'train_plan',
      order: 11,
      name: '项目培训方案及计划',
      group: '交付',
      description: '规划面向用户/运维的培训。',
      structure:
          '培训目标、培训对象、培训内容大纲（按角色/模块）、培训方式与课时安排、考核与资料、师资与环境。',
      focus:
          '按系统功能模块与使用角色，制定对应的培训内容大纲与课时安排。',
    ),
    ProjectDocCategory(
      id: 'user_manual',
      order: 12,
      name: '项目用户操作手册',
      group: '交付',
      description: '指导最终用户使用系统。',
      structure:
          '系统概述、运行环境与登录、功能操作说明（逐功能：入口、操作步骤、界面/字段说明、注意事项）、常见问题。',
      focus:
          '从前端页面/交互与后端功能，逐功能给出用户操作步骤与说明。',
    ),
    ProjectDocCategory(
      id: 'deploy',
      order: 13,
      name: '项目系统软件部署说明',
      group: '运维',
      description: '指导系统的安装、配置与部署。',
      structure:
          '部署架构、软硬件与环境要求、依赖与中间件、安装步骤、配置说明（配置项含义）、初始化、启动与验证、升级与回滚。',
      focus:
          '从构建/依赖文件、配置文件、部署脚本(Dockerfile/CI/启动脚本)还原部署与配置步骤。',
    ),
    ProjectDocCategory(
      id: 'inspection',
      order: 14,
      name: '系统巡检手册',
      group: '运维',
      description: '指导系统日常巡检与维护。',
      structure:
          '巡检目标与周期、巡检项清单（服务状态、日志、资源、数据库、备份等）、检查方法与正常判据、异常处理、巡检记录表模板。',
      focus:
          '结合服务组件、数据库、日志与依赖中间件，制定巡检项清单与检查方法。',
    ),
    ProjectDocCategory(
      id: 'release',
      order: 15,
      name: '系统版本发布说明书',
      group: '运维',
      description: '说明版本发布内容与变更。',
      structure:
          '版本信息、发布内容概述、新增/优化/修复清单、兼容性与数据迁移说明、部署/升级步骤、已知问题、回滚方案。',
      focus:
          '结合功能模块与版本管理信息，整理本次发布内容与升级注意事项。',
    ),
  ];

  static ProjectDocCategory categoryOf(String id) =>
      categories.firstWhere((c) => c.id == id, orElse: () => categories.first);

  // ---------------------------------------------------------------------------
  // 模版管理（全局，作为标准模版，跨项目复用）
  // ---------------------------------------------------------------------------

  final Map<String, ProjectDocTemplate> _templates = {};
  File? _tplStore;

  ProjectDocTemplate? templateFor(String categoryId) => _templates[categoryId];

  int get templateCount => _templates.length;

  Future<void> init() async {
    await store.init();
    try {
      final base = await getApplicationSupportDirectory();
      _tplStore = File('${base.path}\\project_doc_templates.json');
      if (await _tplStore!.exists()) {
        final data = jsonDecode(await _tplStore!.readAsString());
        if (data is Map) {
          data.forEach((k, v) {
            if (v is Map) {
              _templates[k.toString()] =
                  ProjectDocTemplate.fromJson(v.cast<String, dynamic>());
            }
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _persistTemplates() async {
    try {
      await _tplStore?.writeAsString(
          jsonEncode(_templates.map((k, v) => MapEntry(k, v.toJson()))));
    } catch (_) {}
  }

  /// 上传（或替换）某分类的模版文件，解析其结构文本后持久化。
  Future<void> importTemplate(String categoryId, String path) async {
    final text = await documents.extractTemplateText(path);
    if (text.trim().isEmpty) throw Exception('未从模版中解析到内容');
    _templates[categoryId] = ProjectDocTemplate(
      categoryId: categoryId,
      fileName: p.basename(path),
      filePath: path,
      text: text,
    );
    notifyListeners();
    await _persistTemplates();
  }

  Future<void> removeTemplate(String categoryId) async {
    _templates.remove(categoryId);
    notifyListeners();
    await _persistTemplates();
  }

  // ---------------------------------------------------------------------------
  // 文档生成（深读代码 → 分档输出，实时进度）
  // ---------------------------------------------------------------------------

  bool generating = false;
  bool _cancel = false;

  /// 当前生成任务针对的工程路径。
  String? currentProjectPath;

  /// 高层阶段文案（如“正在深入分析工程结构…”）。
  String phase = '';

  /// 实时日志行（Agent 检索/读取/生成过程），最新在后。
  final List<String> logLines = [];

  /// 本次要生成的各文档进度项。
  List<DocGenItem> items = [];

  /// 输出目录（生成完成后可一键打开）。
  String? outputDir;

  /// 已完成的文档数。
  int get doneCount => items.where((e) => e.state == DocGenState.done).length;

  void _log(String line) {
    if (line.trim().isEmpty) return;
    logLines.add(line.trim());
    // 只保留最近若干行，避免无限增长。
    if (logLines.length > 400) logLines.removeRange(0, logLines.length - 400);
    notifyListeners();
  }

  void cancel() {
    if (generating) {
      _cancel = true;
      _log('⏹ 收到停止请求，将在当前步骤后结束…');
    }
  }

  /// 为某工程生成所选分类的文档。
  Future<void> generate({
    required String projectPath,
    required List<String> categoryIds,
    String? outputDirectory,
  }) async {
    if (generating) throw StateError('已有文档生成任务在进行中');
    final dir = Directory(projectPath);
    if (!await dir.exists()) throw StateError('项目目录不存在：$projectPath');
    final selected = categoryIds
        .map(categoryOf)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    if (selected.isEmpty) throw StateError('请至少选择一个文档');

    generating = true;
    _cancel = false;
    currentProjectPath = projectPath;
    phase = '准备中…';
    logLines.clear();
    items = [
      for (final c in selected) DocGenItem(categoryId: c.id, name: c.name),
    ];
    outputDir = outputDirectory ?? p.join(projectPath, '项目文档');
    notifyListeners();

    final projectName = p.basename(projectPath);
    final rec = await store.load(projectPath);
    rec.projectName = projectName;
    var wroteVault = false;

    try {
      await Directory(outputDir!).create(recursive: true);

      // ① 深入阅读代码、理解整体工程结构（含子工程）。
      phase = '正在深入分析工程结构与代码…';
      notifyListeners();
      final analysis = await _analyzeProject(dir);
      if (_cancel) {
        _log('已中止，未生成文档。');
        return;
      }
      _log('✅ 工程结构分析完成，开始逐个生成文档。');
      rec.analysis = analysis;

      // ①b 采集真实代码语料（一次），供每份文档按聚焦点检索、落地到真实代码。
      phase = '正在采集工程真实代码…';
      notifyListeners();
      final rg = await Ripgrep.instance.exePath();
      final corpus = await compute(_collectCodeCorpus, (dir.path, rg));
      if (corpus.isEmpty) {
        _log('⚠ 未采集到可引用的源码文件，文档将主要依据工程分析生成。');
      } else {
        _log('📚 已采集 ${corpus.length} 个源码/配置文件用于据实撰写。');
      }

      // ② 逐个文档：结合模版 + 工程分析 + 相关真实代码生成正文并导出 docx。
      for (var i = 0; i < items.length; i++) {
        if (_cancel) break;
        final item = items[i];
        final cat = categoryOf(item.categoryId);
        item.state = DocGenState.running;
        phase = '正在生成（${i + 1}/${items.length}）：${cat.name}';
        _log('📝 开始生成：${cat.name}');
        notifyListeners();
        try {
          final markdown =
              await _generateDocMarkdown(cat, analysis, item, dir, corpus);
          if (_cancel && markdown.trim().isEmpty) {
            item.state = DocGenState.error;
            item.error = '已中止';
            break;
          }
          final title = markdown.trim().isEmpty
              ? cat.name
              : '$projectName ${cat.name}';
          final out = File(p.join(outputDir!, '${cat.fileBase}.docx'));
          await documents.writeMarkdownToDocx(
            title: title,
            markdown: markdown,
            out: out,
          );
          item.outputPath = out.path;
          item.state = DocGenState.done;
          _log('✅ 已完成：${cat.name} → ${p.basename(out.path)}');
          // 记录到项目文档库，并写入全局知识库 vault。
          _upsertDoc(rec, cat, markdown, out.path);
          if (await _writeVaultNote(projectName, cat.name, markdown)) {
            wroteVault = true;
          }
        } catch (e) {
          item.state = DocGenState.error;
          item.error = '$e';
          _log('✖ 生成失败：${cat.name}：$e');
        }
        notifyListeners();
      }

      // ③ 提炼「系统功能分类 → 子分类」树并持久化（供项目概览使用）。
      if (!_cancel) {
        phase = '正在提炼系统功能分类…';
        notifyListeners();
        try {
          final tree = await _buildFunctionTree(analysis, projectName);
          if (tree.isNotEmpty) {
            _mergeFunctionTree(rec, tree);
            _log('🌳 已生成系统功能树（${tree.length} 个一级模块）。');
          }
        } catch (e) {
          _log('功能树提炼失败（不影响文档）：$e');
        }
      }

      rec.generatedAt = DateTime.now();
      await store.save(rec);
      if (wroteVault) {
        try {
          await library.reload();
        } catch (_) {}
      }

      phase = _cancel
          ? '已停止（完成 $doneCount/${items.length}）'
          : '全部完成（$doneCount/${items.length}）';
      _log(phase);
    } catch (e) {
      phase = '生成失败：$e';
      _log(phase);
      // 即便中途失败，也保存已产出的部分，避免丢失。
      rec.generatedAt = DateTime.now();
      await store.save(rec);
    } finally {
      generating = false;
      _cancel = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // 项目文档库：持久化、功能树、节点详细设计文档、单文档生成/修订、vault 笔记
  // ---------------------------------------------------------------------------

  /// 详细设计/单文档生成/修订的运行态（供项目概览 UI 展示进度）。
  bool detailBusy = false;
  String detailPhase = '';

  /// 当前正在处理的目标 id（节点 id 或文档分类 id），供 UI 高亮。
  String? detailTargetId;
  int detailChars = 0;

  /// 读取某工程已持久化的文档撰写记录（分析/功能树/文档/节点文档）。
  Future<ProjectDocRecord> loadRecord(String projectPath) =>
      store.load(projectPath);

  bool hasRecord(String projectPath) => store.has(projectPath);

  /// 为功能树某节点生成/重写「详细设计文档」，落盘 docx、存库并写入 vault。
  Future<ProjectDocRecord> generateNodeDoc({
    required String projectPath,
    required String nodeId,
    String instruction = '',
  }) async {
    if (generating || detailBusy) throw StateError('已有生成任务在进行中，请稍候');
    final rec = await store.load(projectPath);
    final node = rec.findNode(nodeId);
    if (node == null) throw StateError('未找到该功能节点');
    if (rec.analysis.trim().isEmpty) {
      throw StateError('尚无工程分析，请先在项目列表用“根据工程生成项目文档”完整生成一次');
    }
    final projectName =
        rec.projectName.isEmpty ? p.basename(projectPath) : rec.projectName;
    detailBusy = true;
    detailTargetId = nodeId;
    detailChars = 0;
    detailPhase = '正在采集相关代码…';
    notifyListeners();
    try {
      final rg = await Ripgrep.instance.exePath();
      final corpus = await compute(_collectCodeCorpus, (projectPath, rg));
      final code = _selectCode(corpus, _keywordsForText('${node.title} ${node.desc}'));
      detailPhase = '正在撰写《${node.title}》详细设计…';
      notifyListeners();
      final messages = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content': '你是资深软件详细设计专家，依据真实工程代码为单个功能模块撰写《详细设计说明》。'
              '只输出 Markdown 正文，不要多余说明。',
        },
        {
          'role': 'user',
          'content': _nodeDocPrompt(node, rec.analysis, code, projectName, instruction),
        },
      ];
      final text = await _streamDoc(messages);
      if (text.isEmpty) throw Exception('模型未返回内容');
      final outDir = Directory(p.join(projectPath, '项目文档', '详细设计'));
      await outDir.create(recursive: true);
      final safe = node.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
      final out = File(p.join(outDir.path, '$safe.docx'));
      await documents.writeMarkdownToDocx(
        title: '$projectName $safe 详细设计',
        markdown: text,
        out: out,
      );
      node.detailMarkdown = text;
      node.detailDocxPath = out.path;
      node.detailUpdatedAt = DateTime.now();
      await store.save(rec);
      if (await _writeVaultNote(projectName, '$safe 详细设计', text)) {
        try {
          await library.reload();
        } catch (_) {}
      }
      return rec;
    } finally {
      detailBusy = false;
      detailTargetId = null;
      detailPhase = '';
      notifyListeners();
    }
  }

  /// 生成或修订单份标准文档（复用已存工程分析，不再重跑深度分析）。
  /// - instruction 为空：全新生成该分类（用于「继续新写」未写的文档）。
  /// - instruction 非空且已存在：按要求修订，未提及处保留。
  Future<ProjectDocRecord> writeCategoryDoc({
    required String projectPath,
    required String categoryId,
    String instruction = '',
  }) async {
    if (generating || detailBusy) throw StateError('已有生成任务在进行中，请稍候');
    final rec = await store.load(projectPath);
    if (rec.analysis.trim().isEmpty) {
      throw StateError('尚无工程分析，请先在项目列表用“根据工程生成项目文档”完整生成一次');
    }
    final cat = categoryOf(categoryId);
    final projectName =
        rec.projectName.isEmpty ? p.basename(projectPath) : rec.projectName;
    final existing = rec.docFor(categoryId);
    final revising = existing != null && instruction.trim().isNotEmpty;
    detailBusy = true;
    detailTargetId = categoryId;
    detailChars = 0;
    detailPhase = '正在采集相关代码…';
    notifyListeners();
    try {
      final rg = await Ripgrep.instance.exePath();
      final corpus = await compute(_collectCodeCorpus, (projectPath, rg));
      final code = _selectCode(corpus, _catKeywords[cat.id] ?? _fallbackKeywords);
      detailPhase = revising ? '正在修订《${cat.name}》…' : '正在生成《${cat.name}》…';
      notifyListeners();
      final List<Map<String, dynamic>> messages;
      if (revising) {
        messages = [
          {
            'role': 'system',
            'content': '你是资深软件工程文档专家。按修订要求更新文档，未提及处逐字保留。'
                '只输出更新后的完整 Markdown 正文。',
          },
          {
            'role': 'user',
            'content':
                _reviseDocPrompt(cat, existing.markdown, rec.analysis, code, instruction),
          },
        ];
      } else {
        messages = [
          {
            'role': 'system',
            'content': '你是资深软件工程文档专家，依据真实工程代码撰写规范、详实的项目交付文档。'
                '只输出 Markdown 正文，不要多余说明。',
          },
          {
            'role': 'user',
            'content':
                _docPrompt(cat, rec.analysis, _templates[cat.id], projectName, code),
          },
        ];
      }
      final text = await _streamDoc(messages);
      if (text.isEmpty) throw Exception('模型未返回内容');
      final out = File(
        existing != null && existing.docxPath.isNotEmpty
            ? existing.docxPath
            : p.join(projectPath, '项目文档', '${cat.fileBase}.docx'),
      );
      await out.parent.create(recursive: true);
      await documents.writeMarkdownToDocx(
        title: '$projectName ${cat.name}',
        markdown: text,
        out: out,
      );
      _upsertDoc(rec, cat, text, out.path);
      await store.save(rec);
      if (await _writeVaultNote(projectName, cat.name, text)) {
        try {
          await library.reload();
        } catch (_) {}
      }
      return rec;
    } finally {
      detailBusy = false;
      detailTargetId = null;
      detailPhase = '';
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // 项目概览工作台：结构化概览、交互架构图、与项目对话
  // ---------------------------------------------------------------------------

  /// 「与项目对话」运行态。
  bool qaBusy = false;

  /// 深度分级对应的提示词描述与预算。
  static const Map<String, String> depthLabels = {
    'quick': '快速',
    'standard': '标准',
    'deep': '深入',
    'audit': '审计',
  };

  /// 生成结构化项目概览（13 段结构 + 证据标签 + ref: 引用），存库返回。
  Future<ProjectDocRecord> buildOverview({
    required String projectPath,
    String depth = 'standard',
  }) async {
    if (generating || detailBusy) throw StateError('已有生成任务在进行中，请稍候');
    final rec = await store.load(projectPath);
    if (rec.analysis.trim().isEmpty) {
      throw StateError('尚无工程分析，请先在项目列表用“根据工程生成项目文档”完整生成一次');
    }
    final projectName =
        rec.projectName.isEmpty ? p.basename(projectPath) : rec.projectName;
    detailBusy = true;
    detailTargetId = 'overview';
    detailChars = 0;
    detailPhase = '正在生成结构化概览（${depthLabels[depth] ?? depth}）…';
    notifyListeners();
    try {
      final rg = await Ripgrep.instance.exePath();
      final inventory = await compute(_collectPathInventory, (projectPath, rg));
      final messages = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content': '你是资深软件架构分析师，产出证据优先的项目概览。只输出 Markdown 正文。',
        },
        {
          'role': 'user',
          'content': _overviewPrompt(rec.analysis, projectName, inventory, depth),
        },
      ];
      final text = await _streamDoc(messages);
      if (text.isEmpty) throw Exception('模型未返回内容');
      rec.overviewMarkdown = text;
      rec.depth = depth;
      await store.save(rec);
      return rec;
    } finally {
      detailBusy = false;
      detailTargetId = null;
      detailPhase = '';
      notifyListeners();
    }
  }

  String _overviewPrompt(
    String analysis,
    String projectName,
    List<String> inventory,
    String depth,
  ) {
    final depthRule = switch (depth) {
      'quick' => '快速模式：每节 2-4 句，聚焦最重要结论，总长控制在 1500 字内。',
      'deep' => '深入模式：核心模块与主流程要展开到关键类/函数级，风险按影响×概率排序。',
      'audit' => '审计模式：以风险为先导组织内容，每个风险给出证据与整改建议。',
      _ => '标准模式：各节均衡覆盖，重点节（架构/主流程/核心模块）展开。',
    };
    return '''
请基于《工程分析》与《真实文件清单》，为工程「$projectName」生成一份**结构化项目概览**。

严格按以下 13 节组织（用 ## 二级标题，节名保持一致）：
1. 项目简介；2. 技术栈；3. 目录与关键文件；4. 启动与运行路径；5. 系统架构；
6. 主数据/控制流；7. 核心模块；8. 状态与数据契约；9. 外部依赖；10. 测试与验证；
11. 风险与开放问题；12. 建议下一步；13. 新人阅读路径。

证据纪律（非常重要）：
- 每个重要结论标注证据级别：【Observed】（源自工程分析/真实文件）、【Inferred】（结构推断）、【Open】（待确认）。
- 提到具体文件时，使用 markdown 链接格式 [路径](ref:路径)，路径必须来自《真实文件清单》或工程分析中出现过的真实路径（相对工程根目录，用 / 分隔）。不得编造路径。
- 「风险与开放问题」每条注明级别与依据。

$depthRule

【真实文件清单（相对路径，供引用与核对）】
${inventory.take(400).join('\n')}

【工程分析】
${_clip(analysis, depth == 'quick' ? 8000 : 20000)}

输出要求：中文 Markdown；不要开场白/结语；不要手写目录。
''';
  }

  /// 生成/重建一张架构图（kind: system/directory/flow）：模型产出 Mermaid 与
  /// 节点→路径映射，渲染 PNG 存盘，持久化后返回记录。
  ///
  /// [scopeLabel]/[scopePath] 非空时按该节点**下钻**：只画该模块/目录内部的
  /// 架构、结构或流程，支持从根层逐层深入。
  Future<ProjectDocRecord> buildArchitecture({
    required String projectPath,
    required String kind,
    String scopeLabel = '',
    String scopePath = '',
  }) async {
    if (generating || detailBusy) throw StateError('已有生成任务在进行中，请稍候');
    final rec = await store.load(projectPath);
    if (rec.analysis.trim().isEmpty) {
      throw StateError('尚无工程分析，请先在项目列表用“根据工程生成项目文档”完整生成一次');
    }
    final projectName =
        rec.projectName.isEmpty ? p.basename(projectPath) : rec.projectName;
    final scopeKey = scopePath.isNotEmpty ? scopePath : scopeLabel;
    detailBusy = true;
    detailTargetId = 'arch:$kind:$scopeKey';
    detailChars = 0;
    detailPhase = scopeKey.isEmpty
        ? '正在生成${_archKindName(kind)}…'
        : '正在深入「${scopeLabel.isEmpty ? scopePath : scopeLabel}」生成${_archKindName(kind)}…';
    notifyListeners();
    try {
      final rg = await Ripgrep.instance.exePath();
      var inventory = await compute(_collectPathInventory, (projectPath, rg));
      // 下钻到某目录时，清单聚焦到该子树（更精准、更省 token）。
      if (scopePath.isNotEmpty) {
        final scoped = inventory
            .where((f) => f == scopePath || f.startsWith('$scopePath/'))
            .toList();
        if (scoped.isNotEmpty) inventory = scoped;
      }
      final messages = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content': '你是资深软件架构师。只输出 JSON 对象，不要解释、不要代码围栏。',
        },
        {
          'role': 'user',
          'content': _archPrompt(
              rec.analysis, projectName, inventory, kind, scopeLabel, scopePath),
        },
      ];
      final text = await _streamDoc(messages);
      final parsed = _parseArchJson(text);
      final mermaid = (parsed?['mermaid'] as String? ?? '').trim();
      if (mermaid.isEmpty) throw Exception('模型未返回有效的图定义');
      final nodes = <ArchNode>[];
      final rawNodes = parsed?['nodes'];
      if (rawNodes is List) {
        final invSet = inventory.toSet();
        for (final n in rawNodes) {
          if (n is! Map) continue;
          final label = (n['label'] ?? '').toString().trim();
          var path = (n['path'] ?? '').toString().trim().replaceAll('\\', '/');
          if (label.isEmpty) continue;
          // 只保留真实存在的路径（文件在清单内，或目录是清单某路径的前缀）。
          final isReal = invSet.contains(path) ||
              inventory.any((f) => f.startsWith('$path/'));
          if (!isReal) path = '';
          nodes.add(ArchNode(label: label, path: path));
        }
      }
      detailPhase = '正在渲染图…';
      notifyListeners();
      String imagePath = '';
      final png = await documents.renderMermaidPng(mermaid);
      if (png != null) {
        final scopeTag = scopeKey.isEmpty
            ? ''
            : '_${scopeKey.hashCode.toUnsigned(32).toRadixString(16)}';
        final out = store.assetPath(projectPath, 'arch_$kind$scopeTag.png');
        if (out != null) {
          await File(out).writeAsBytes(png);
          imagePath = out;
        }
      }
      final diagram = ArchDiagram(
        kind: kind,
        scopeLabel: scopeLabel,
        scopePath: scopePath,
        mermaid: mermaid,
        imagePath: imagePath,
        nodes: nodes,
        updatedAt: DateTime.now(),
      );
      rec.diagrams
          .removeWhere((d) => d.kind == kind && d.scopeKey == scopeKey);
      rec.diagrams.add(diagram);
      await store.save(rec);
      return rec;
    } finally {
      detailBusy = false;
      detailTargetId = null;
      detailPhase = '';
      notifyListeners();
    }
  }

  static String _archKindName(String kind) => switch (kind) {
        'directory' => '目录结构图',
        'flow' => '主流程图',
        _ => '系统架构图',
      };

  String _archPrompt(
    String analysis,
    String projectName,
    List<String> inventory,
    String kind,
    String scopeLabel,
    String scopePath,
  ) {
    final goal = switch (kind) {
      'directory' => '目录结构图：以顶层目录/子工程为节点（graph TB），体现包含关系与职责，'
          '节点 path 填对应目录（如 lib/services）。',
      'flow' => '主流程图：选择系统最核心的 1 条业务/数据主流程（flowchart LR），'
          '从输入→分发→核心逻辑→外部依赖→状态/输出，节点 path 填承载该步骤的文件。',
      _ => '系统架构图：按分层/子系统组织（flowchart TB + subgraph），体现模块与依赖方向，'
          '节点 path 填模块对应的目录或核心文件。',
    };
    final scopeName = scopeLabel.isNotEmpty ? scopeLabel : scopePath;
    final scopeBlock = scopeName.isEmpty
        ? ''
        : '''

【下钻聚焦（非常重要）】
本图**只画「$scopeName」${scopePath.isEmpty ? '' : '（对应路径 $scopePath）'}这个模块内部**：
- 拆解它的内部子模块/子目录/子步骤及相互关系，不要重复画整个系统。
- 节点应尽量比上一层更细一级（如类/文件/子目录/子流程），便于继续逐层下钻。
- 与外部模块的交互最多画 1-2 个边界节点即可。
''';
    return '''
请基于《工程分析》与《真实文件清单》，为工程「$projectName」生成一张 **${_archKindName(kind)}**。

$goal
$scopeBlock

Mermaid 语法纪律：
- 节点 id 用英文/数字（无空格），显示文字放中括号标签内；标签含括号/冒号等特殊字符时用双引号包裹。
- 不要 click 语句、不要样式/classDef、不要 HTML。
- 节点数控制在 8~24 个，保证可读。

只输出一个 JSON 对象（无围栏、无多余文字）：
{"mermaid":"<mermaid 源码>","nodes":[{"label":"<图中节点显示文字>","path":"<相对路径，找不到就填空串>"}]}

nodes 覆盖图中所有节点；path 必须取自《真实文件清单》（或其目录前缀），不得编造。

【真实文件清单】
${inventory.take(400).join('\n')}

【工程分析】
${_clip(analysis, 14000)}
''';
  }

  Map<String, dynamic>? _parseArchJson(String content) {
    try {
      var s = content.trim();
      if (s.startsWith('```')) {
        s = s.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '');
        if (s.endsWith('```')) s = s.substring(0, s.length - 3);
      }
      final start = s.indexOf('{');
      final end = s.lastIndexOf('}');
      if (start < 0 || end <= start) return null;
      final data = jsonDecode(s.substring(start, end + 1));
      return data is Map ? data.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// 最近一次问答所属的会话 id（供 UI 定位新建的会话）。
  String? lastQaSessionId;

  /// 「与项目对话」：Agent 在工程目录内 grep/glob/read 取证后作答，
  /// 引用以 [路径](ref:路径) 链接给出；追加到指定会话（[sessionId] 为空或不存在
  /// 时新建一个会话），问答历史持久化。
  Future<ProjectDocRecord> askProject({
    required String projectPath,
    required String question,
    String? sessionId,
  }) async {
    if (qaBusy) throw StateError('上一个问题还在回答中，请稍候');
    final rec = await store.load(projectPath);
    final projectName =
        rec.projectName.isEmpty ? p.basename(projectPath) : rec.projectName;
    qaBusy = true;
    detailChars = 0;
    notifyListeners();
    try {
      final dir = Directory(projectPath);
      if (!await dir.exists()) throw StateError('项目目录不存在：$projectPath');
      final buf = StringBuffer();
      final reporter = AgentReporter(
        onStatus: (_) {},
        onAssistantText: (full) {
          if (full.trim().isNotEmpty) buf.write(full);
        },
      );
      final result = await _runner.run(
        dir: dir,
        systemPrompt: _qaSystem(projectName, rec.analysis),
        initialMessages: [Msg.user(question)],
        recallQuery: question,
        reporter: reporter,
        isCancelled: () => false,
        enableMemory: false,
        extractMemory: false,
        maxTurns: 0,
        maxDepth: 1,
      );
      var answer = buf.toString().trim();
      if (answer.isEmpty) answer = _lastAssistantText(result.messages).trim();
      if (answer.isEmpty) {
        answer = result.reason == AgentStopReason.error
            ? '（模型调用失败，请稍后重试）'
            : '（未获得回答）';
      }
      final now = DateTime.now();
      var session = sessionId == null ? null : rec.sessionFor(sessionId);
      if (session == null) {
        session = QaSession(
          id: 'qa_${now.microsecondsSinceEpoch}',
          title: _sessionTitle(question),
          createdAt: now,
        );
        rec.qaSessions.insert(0, session);
      }
      session.items.add(QaItem(question: question, answer: answer, at: now));
      session.updatedAt = now;
      if (session.items.length == 1) session.title = _sessionTitle(question);
      lastQaSessionId = session.id;
      await store.save(rec);
      return rec;
    } finally {
      qaBusy = false;
      notifyListeners();
    }
  }

  /// 供论文选题：让 Agent 在工程内多轮 grep/glob/read 深挖，围绕“这个工程能支撑
  /// 哪些研究方向、可拟哪些论文题目”产出分方向、成体系的富文本分析（不落库）。
  /// 与「项目对话」共用同一套 AgentRunner，因此深度/广度与项目概览对话一致。
  Future<String> exploreForTopics(
    String projectPath, {
    String extraBrief = '',
    void Function(String line)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(projectPath);
    if (!await dir.exists()) throw StateError('项目目录不存在：$projectPath');
    final rec = await store.load(projectPath);
    final projectName =
        rec.projectName.isEmpty ? p.basename(projectPath) : rec.projectName;
    final buf = StringBuffer();
    final reporter = AgentReporter(
      onStatus: (m) => onProgress?.call(m),
      onToolStart: (_, _, title) => onProgress?.call('🔎 $title'),
      onToolEnd: (_, isError, _) {
        if (isError) onProgress?.call('⚠ 工具执行出错');
      },
      onAssistantText: (full) {
        if (full.trim().isNotEmpty) buf.write(full);
        final snippet = full
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .firstWhere((l) => l.isNotEmpty, orElse: () => '');
        if (snippet.isNotEmpty) {
          onProgress?.call(
            '💭 ${snippet.length > 64 ? '${snippet.substring(0, 64)}…' : snippet}',
          );
        }
      },
    );
    final result = await _runner.run(
      dir: dir,
      systemPrompt: _topicSystem(projectName, rec.analysis),
      initialMessages: [Msg.user(_topicQuestion(extraBrief))],
      recallQuery: 'paper research directions and candidate topics',
      reporter: reporter,
      isCancelled: isCancelled ?? () => false,
      enableMemory: false,
      extractMemory: false,
      maxTurns: 0,
      maxDepth: 1,
    );
    var out = buf.toString().trim();
    if (out.isEmpty) out = _lastAssistantText(result.messages).trim();
    return out;
  }

  String _topicSystem(String projectName, String analysis) => '''
你是资深科研选题顾问，正在研究工程「$projectName」，目标是判断它能支撑哪些**有深度、有广度、可投稿**的学术论文方向与题目。

可用工具（路径相对工程根目录，只读）：read_file / grep / glob。

工作方式：
1. 先用 grep/glob 摸清工程的核心能力、关键模块与技术特色，read_file 精读关键实现后再判断，不要凭空猜。
2. 从工程真实能力出发，**发散出多个不同研究方向**（问题视角 / 方法层面 / 应用层面等），每个方向再给若干候选论文题目。
3. 论文要**高于并抽象于具体工程**：题目与研究焦点用通用学术语言；可在心里以代码为据，但**产出中不要出现文件名/函数名/类名/库版本等实现痕迹**。
4. 用中文 Markdown 输出，按「研究方向 → 该方向下的候选题目（中文题目 + 一句话研究问题/创新点）」组织，尽量覆盖多个方向。
5. 充分检索后再作答，追求深度与广度。

以下是此前生成的《工程分析》摘要，可作背景（仍以实际检索为准）：
${_clip(analysis, 6000)}
''';

  String _topicQuestion(String extraBrief) => '''
请深入检索这个工程的代码与能力，判断它能支撑哪些方向的学术论文，并为每个方向拟出候选论文题目（分方向、成体系、有深度有广度）。
${extraBrief.trim().isEmpty ? '' : '\n补充背景 / 研究倾向：\n$extraBrief\n'}
要求：多给几个不同方向；每个方向 2-3 个候选题目；题目抽象、学术、可投稿，不要出现具体文件名/函数名。
''';

  /// 删除一段对话会话。
  Future<ProjectDocRecord> deleteQaSession({
    required String projectPath,
    required String sessionId,
  }) async {
    final rec = await store.load(projectPath);
    rec.qaSessions.removeWhere((s) => s.id == sessionId);
    await store.save(rec);
    notifyListeners();
    return rec;
  }

  static String _sessionTitle(String question) {
    final t = question.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) return '新对话';
    return t.length <= 20 ? t : '${t.substring(0, 20)}…';
  }

  String _qaSystem(String projectName, String analysis) => '''
你是工程「$projectName」的代码问答助手。用户会就这个工程提问，你需要**基于真实代码**作答。

可用工具（路径相对工程根目录，只读）：read_file / grep / glob。

纪律：
1. 先用 grep/glob 定位相关代码，read_file 精读后再回答；不确定的先检索，不要凭空猜。
2. 回答里引用文件时，使用 markdown 链接 [路径](ref:路径)（相对路径、/ 分隔），可加 :行号，如 [lib/main.dart:56](ref:lib/main.dart)。引用必须是检索确认存在的真实文件。
3. 在代码里找不到答案时，如实说明「未在代码中找到」，不得编造。
4. 回答用中文 Markdown，简洁直接，先给结论再给依据。

以下是此前生成的《工程分析》摘要，可作背景（仍以实际检索为准）：
${_clip(analysis, 6000)}
''';

  /// 轻量收集工程内文件相对路径清单（不读内容），isolate 中执行。
  /// [msg] 为 (工程根路径, rg 可执行文件路径)。
  static List<String> _collectPathInventory((String, String) msg) {
    final rootPath = msg.$1;
    final rgExe = msg.$2;
    final out = <String>[];
    for (final rel in Ripgrep.listFilesSync(rgExe, rootPath)) {
      if ('/'.allMatches(rel).length > 6) continue;
      out.add(rel);
      if (out.length >= 800) break;
    }
    out.sort();
    return out;
  }

  Future<String> _streamDoc(List<Map<String, dynamic>> messages) async {
    final buf = StringBuffer();
    var last = 0;
    final turn = await _writer.stream(
      messages: messages,
      isCancelled: () => false,
      timeout: const Duration(minutes: 6),
      onTextDelta: (d) {
        buf.write(d);
        detailChars = buf.length;
        if (buf.length - last >= 80) {
          last = buf.length;
          notifyListeners();
        }
      },
    );
    var text = buf.toString().trim();
    if (text.isEmpty) text = turn.content.trim();
    return text;
  }

  void _upsertDoc(
    ProjectDocRecord rec,
    ProjectDocCategory cat,
    String markdown,
    String docxPath,
  ) {
    final existing = rec.docFor(cat.id);
    if (existing != null) {
      existing.name = cat.name;
      existing.markdown = markdown;
      existing.docxPath = docxPath;
      existing.updatedAt = DateTime.now();
    } else {
      rec.docs.add(GeneratedDoc(
        categoryId: cat.id,
        name: cat.name,
        markdown: markdown,
        docxPath: docxPath,
        updatedAt: DateTime.now(),
      ));
    }
  }

  /// 把一份项目文档写入全局知识库 vault（类别「项目文档」）。返回是否写入成功。
  Future<bool> _writeVaultNote(
    String projectName,
    String docName,
    String markdown,
  ) async {
    try {
      const cat = '项目文档';
      final title = '$projectName $docName'
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
          .trim();
      final dir = Directory(p.join(library.notesDir, cat));
      await dir.create(recursive: true);
      final fm = '---\n'
          '题名: "${title.replaceAll('"', '')}"\n'
          '类别: $cat\n'
          '来源: 项目文档\n'
          '项目: "${projectName.replaceAll('"', '')}"\n'
          '状态: 未读\n'
          'tags:\n'
          '  - 项目文档\n'
          '  - ${projectName.replaceAll('\n', ' ')}\n'
          '---\n\n';
      await File(p.join(dir.path, '$title.md')).writeAsString(fm + markdown);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 从工程分析提炼「系统功能分类 → 子分类」树（JSON）。
  Future<List<FuncNode>> _buildFunctionTree(
    String analysis,
    String projectName,
  ) async {
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': '你是资深软件架构师。只输出 JSON，不要输出任何解释或代码围栏。',
      },
      {'role': 'user', 'content': _functionTreePrompt(analysis, projectName)},
    ];
    final text = await _streamDoc(messages);
    return _parseFunctionTree(text);
  }

  String _functionTreePrompt(String analysis, String projectName) => '''
请基于下面这份《工程分析》，为工程「$projectName」梳理"系统功能分类 → 子分类"结构树。
要求：
- 一级为系统的主要功能模块/子系统；二级为其下的具体功能点。
- 严格基于工程分析中的真实模块与功能，不要编造。
- 每个节点给出简短 desc（一句话职责）。
- 最多 10 个一级模块，每个模块最多 8 个子功能。

只输出 JSON 数组（不要 markdown 围栏、不要多余文字），格式：
[{"title":"模块名","desc":"职责","children":[{"title":"功能点","desc":"说明"}]}]

【工程分析】
${_clip(analysis, 16000)}
''';

  List<FuncNode> _parseFunctionTree(String content) {
    try {
      var s = content.trim();
      if (s.startsWith('```')) {
        s = s.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '');
        if (s.endsWith('```')) s = s.substring(0, s.length - 3);
      }
      final start = s.indexOf('[');
      final end = s.lastIndexOf(']');
      if (start < 0 || end <= start) return [];
      final data = jsonDecode(s.substring(start, end + 1));
      if (data is! List) return [];
      var seq = 0;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      FuncNode toNode(Map m) {
        final children = <FuncNode>[];
        final ch = m['children'];
        if (ch is List) {
          for (final c in ch) {
            if (c is Map) children.add(toNode(c));
          }
        }
        return FuncNode(
          id: 'n${seq++}_$stamp',
          title: (m['title'] ?? '').toString().trim(),
          desc: (m['desc'] ?? '').toString().trim(),
          children: children,
        );
      }

      return [
        for (final e in data)
          if (e is Map && (e['title'] ?? '').toString().trim().isNotEmpty)
            toNode(e),
      ];
    } catch (_) {
      return [];
    }
  }

  /// 合并新旧功能树：按标题保留旧节点已生成的详细设计文档。
  void _mergeFunctionTree(ProjectDocRecord rec, List<FuncNode> fresh) {
    if (rec.functionTree.isEmpty) {
      rec.functionTree = fresh;
      return;
    }
    List<FuncNode> merge(List<FuncNode> oldNodes, List<FuncNode> newNodes) {
      for (final n in newNodes) {
        final match = oldNodes.firstWhere(
          (o) => o.title == n.title,
          orElse: () => FuncNode(id: '', title: ''),
        );
        if (match.id.isNotEmpty) {
          n.detailMarkdown = match.detailMarkdown;
          n.detailDocxPath = match.detailDocxPath;
          n.detailUpdatedAt = match.detailUpdatedAt;
          n.children = merge(match.children, n.children);
        }
      }
      return newNodes;
    }

    rec.functionTree = merge(rec.functionTree, fresh);
  }

  String _nodeDocPrompt(
    FuncNode node,
    String analysis,
    String codeBlock,
    String projectName,
    String instruction,
  ) =>
      '''
请为工程「$projectName」的功能模块「${node.title}」撰写一份**详细设计说明书**（只针对该模块，不要泛泛描述整个系统）。
${node.desc.trim().isEmpty ? '' : '模块职责：${node.desc}\n'}${node.children.isEmpty ? '' : '包含子功能：${node.children.map((c) => c.title).join('、')}\n'}${instruction.trim().isEmpty ? '' : '额外要求：$instruction\n'}
建议章节：模块概述与职责、功能点清单、处理流程与核心算法、关键类/函数设计、数据结构与存储、对内/对外接口、异常与边界处理、与其它模块的交互、相关配置项。

${codeBlock.trim().isEmpty ? '' : '【相关真实代码片段（务必据此提取真实类名/函数名/字段/接口/参数，勿臆造）】\n$codeBlock\n'}
【工程分析（总体背景）】
${_clip(analysis, 8000)}

输出要求：
- 使用中文 Markdown，聚焦「${node.title}」，详尽、专业、可交付。
- 接口/库表/字段/参数必须取自真实代码片段；代码没有的用【待补充：...】标注。
- 图示（流程/时序/类图）用 ```mermaid 代码块，不要用 ASCII 手画；不要手写「目录」。
- 直接输出正文，不要「以下是」之类前后缀。
''';

  String _reviseDocPrompt(
    ProjectDocCategory cat,
    String currentMarkdown,
    String analysis,
    String codeBlock,
    String instruction,
  ) =>
      '''
下面是工程「${cat.name}」文档的现有正文。请只针对我指出的修订要求进行补充/修改，其它已有内容原样保留，不要删改或重排。

修订要求：
$instruction

${codeBlock.trim().isEmpty ? '' : '【相关真实代码片段（涉及接口/表/字段/参数请据此，勿臆造）】\n$codeBlock\n'}
【工程分析】
${_clip(analysis, 8000)}

现有正文：
${_clip(currentMarkdown, 16000)}

输出要求：
- 输出完整的更新后正文（含未改动部分），使用 Markdown。
- 只在我指出处修改；接口/表/字段/参数必须与真实代码一致。
- 图示用 ```mermaid 代码块，不要 ASCII 手画；不要手写「目录」。
''';

  /// 由一段中英文文本提取检索关键词（英文词 + 中文短词 + 通用兜底）。
  static List<String> _keywordsForText(String text) {
    final lower = text.toLowerCase();
    final en = RegExp(r'[a-zA-Z]{3,}')
        .allMatches(lower)
        .map((m) => m.group(0)!)
        .toSet()
        .toList();
    final zh = text
        .split(RegExp(r'[\s，,。、/（）()【】\[\]:：+\-]+'))
        .where((s) => s.trim().length >= 2)
        .toList();
    return [...en, ...zh, ..._fallbackKeywords];
  }

  /// 用通用 Agent 内核深入阅读工程：先总体理解结构（含子工程），
  /// 再梳理技术栈、模块划分与职责、数据库结构、接口、关键流程，产出结构化分析文本。
  Future<String> _analyzeProject(Directory dir) async {
    final index = CodeIndexService();
    try {
      await index.bind(dir);
    } catch (_) {}
    final overview = index.overview();

    final buf = StringBuffer();
    final reporter = AgentReporter(
      onStatus: _log,
      onToolStart: (id, tool, title) => _log('· $title'),
      onAssistantText: (full) {
        if (full.trim().isNotEmpty) buf.write(full);
      },
    );

    try {
      final result = await _runner.run(
        dir: dir,
        systemPrompt: _analysisSystem(),
        initialMessages: [Msg.user(_analysisTask(overview))],
        recallQuery: '深入分析工程结构与实现，为编写项目文档做准备',
        reporter: reporter,
        isCancelled: () => _cancel,
        enableMemory: false,
        extractMemory: false,
        maxTurns: 0,
        maxDepth: 2,
        log: _log,
      );
      // 优先用循环里累计的助手总结；为空则从消息里兜取最后一段助手文本。
      var analysis = buf.toString().trim();
      if (analysis.isEmpty) analysis = _lastAssistantText(result.messages).trim();

      // 校验：分析过程若因模型报错（如限流/额度上限）中断，直接失败，
      // 绝不带着空/残缺的分析继续生成脱离工程的空壳文档。
      if (result.reason == AgentStopReason.error) {
        throw Exception(
          '工程分析中断：模型调用失败（常见于接口限流或额度上限）。'
          '当前仅获取到约 ${analysis.length} 字的分析，已停止生成，请稍后重试或更换可用模型。',
        );
      }
      if (!_cancel && analysis.length < 300) {
        throw Exception(
          '工程分析结果过短（仅 ${analysis.length} 字），可能未成功读取工程或被中途打断。'
          '为避免生成脱离真实代码的文档，已停止。请检查模型配置后重试。',
        );
      }
      return analysis;
    } finally {
      index.unbind();
    }
  }

  String _analysisSystem() {
    final os = Platform.isWindows
        ? 'Windows（bash 工具经 cmd /c 执行命令）'
        : 'Unix（bash 工具经 bash -lc 执行命令）';
    return '''
你是一位**资深软件架构分析师** Agent，运行环境为 $os，工作目录为用户的一个软件工程。
你的任务：**深入、详细地阅读工程代码，彻底弄清系统的整体结构与实现**，为随后编写全套项目文档
（需求、概要/详细设计、接口、数据库、测试、部署等）打好基础。

可用工具（路径相对工程根目录，只读为主）：
- read_file / grep / glob / task（explore 子 agent 可并行探索）

== 分析纪律 ==
1. **先总体、后局部**：工程可能包含多个子工程/服务。先用 glob/grep 摸清顶层结构、
   构建与依赖文件（package.json/pom.xml/pubspec.yaml/go.mod/requirements.txt/Dockerfile 等），
   判断技术栈、子工程划分与它们之间的关系。
2. **按需检索、精读关键处**：用 grep 按符号/关键词定位路由/控制器/服务/模型/建表脚本，
   命中后 read_file 精读，不要逐个文件整读。
3. **重点弄清**：技术栈与架构分层；模块/功能划分与各自职责；对内对外接口（地址、参数、响应）；
   数据库/数据模型（表、字段、关系，来自 sql/迁移/ORM 实体）；关键业务流程与核心算法；
   配置与部署方式。

== 结束 ==
完成检索后，**停止调用任何工具**，用一段结构化 **Markdown** 输出详尽的《工程分析》，至少覆盖：
1. 系统总体架构与技术栈；2. 子工程/模块清单与职责（逐个）；3. 模块间关系与依赖；
4. 数据库/数据模型（表与字段概要）；5. 对内/对外接口清单；6. 关键业务流程与核心实现；
7. 配置与部署要点。内容要具体、引用真实的文件/类/表名，避免空泛。这段分析将作为后续所有文档的事实依据。
''';
  }

  String _analysisTask(String overview) {
    final ov = overview.trim();
    return '''
现在开始深入分析这个工程，为编写全套项目文档做准备。
${ov.isEmpty ? '' : '以下是工程顶层概览（仅用于快速建立认知，定位代码请用 grep/glob 检索）：\n$ov\n'}
请先总体理解工程结构（注意是否包含子工程/多服务），再逐个模块深入阅读实现，最后输出详尽的《工程分析》。
''';
  }

  /// 生成单个文档的 Markdown 正文：结合工程分析 + 按聚焦点检索到的真实代码
  /// 片段 + 该分类的写作要求与上传模版结构。
  Future<String> _generateDocMarkdown(
    ProjectDocCategory cat,
    String analysis,
    DocGenItem item,
    Directory dir,
    List<Map<String, String>> corpus,
  ) async {
    final tpl = _templates[cat.id];
    final projectName = p.basename(dir.path);
    final codeBlock = _selectRelevantCode(corpus, cat);
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content':
            '你是资深软件工程文档专家，擅长依据真实工程代码撰写规范、详实的项目交付文档。'
                '只输出文档正文（Markdown），不要输出任何多余说明。',
      },
      {
        'role': 'user',
        'content': _docPrompt(cat, analysis, tpl, projectName, codeBlock),
      },
    ];

    final buf = StringBuffer();
    var lastNotify = 0;
    final turn = await _writer.stream(
      messages: messages,
      isCancelled: () => _cancel,
      timeout: const Duration(minutes: 6),
      onTextDelta: (d) {
        buf.write(d);
        item.chars = buf.length;
        // 节流通知：每累计约 80 字刷新一次进度。
        if (buf.length - lastNotify >= 80) {
          lastNotify = buf.length;
          notifyListeners();
        }
      },
    );
    var text = buf.toString().trim();
    if (text.isEmpty) text = turn.content.trim();
    item.chars = text.length;
    return text;
  }

  String _docPrompt(
    ProjectDocCategory cat,
    String analysis,
    ProjectDocTemplate? tpl,
    String projectName,
    String codeBlock,
  ) {
    return '''
请基于下面这份《工程分析》与《相关真实代码片段》，为工程「$projectName」撰写一份完整、详实的《${cat.name}》。

文档用途：${cat.description}
建议章节结构：${cat.structure}
本文档应重点结合的工程信息：${cat.focus}

${tpl == null ? '' : '用户上传的《${cat.name}》标准模版结构如下，请严格参照其章节层级与栏目组织内容：\n${_clip(tpl.text, 8000)}\n'}
【工程分析（总体事实依据，务必据此撰写，不要脱离实际代码臆造）】
${_clip(analysis, 14000)}

${codeBlock.trim().isEmpty ? '' : '【相关真实代码片段（与本文档最相关的源码/配置，请据此提取真实的接口/表结构/字段/参数/流程/配置等细节，凡文中出现的具体名称必须来自代码）】\n$codeBlock\n'}
输出要求：
- 使用中文，使用 Markdown 表达标题层级、条款、表格与列表。
- 严格围绕上面的工程分析与真实代码片段撰写；逐个功能模块展开，力求详尽、专业、可交付。
- 涉及接口/库表/字段/参数/配置项时，必须取自上面的真实代码片段（真实的路径、类名、函数名、字段名、参数名），用表格清晰呈现，不得编造。
- 代码中确实没有的信息用【待补充：...】标注，不要臆造。
- 不要手写「目录/目次」章节（导出时会自动生成 Word 目录）。
- 需要架构图、流程图、时序图、类图、E-R 图等图示时，一律用 Mermaid 代码块输出（```mermaid 开头），
  使用合法的 mermaid 语法（flowchart/graph、sequenceDiagram、classDiagram、erDiagram、stateDiagram 等），
  节点文字用中文；不要用 ASCII 字符（|、+、─、方框等）手画示意图。
- 确实无法从代码得知、需人工补充处用【待补充：...】标注，不要编造具体单位、人名、真实文号等敏感信息。
- 直接输出文档正文，不要输出「以下是」之类的前后缀说明。
''';
  }

  static String _lastAssistantText(List<Map<String, dynamic>> messages) {
    for (final m in messages.reversed) {
      if (m['role'] == 'assistant') {
        final c = (m['content'] ?? '').toString().trim();
        if (c.isNotEmpty) return c;
      }
    }
    return '';
  }

  // ---------------------------------------------------------------------------
  // 真实代码语料采集与按文档聚焦点检索（grounding）
  // ---------------------------------------------------------------------------

  /// 各文档分类的检索关键词（用于从真实代码中挑选与之最相关的文件）。
  static const Map<String, List<String>> _catKeywords = {
    'requirement': [
      'route', 'controller', 'service', 'handler', 'view', 'form', 'validate',
      'permission', 'auth', 'api', 'main', 'app', 'usecase',
    ],
    'outline_design': [
      'module', 'service', 'component', 'config', 'main', 'app', 'client',
      'server', 'factory', 'provider', 'registry', 'core',
    ],
    'interface': [
      'route', 'router', 'controller', 'api', 'endpoint', 'http', 'request',
      'response', 'get', 'post', 'put', 'delete', 'rest', 'grpc', 'proto',
      'fastapi', 'flask', 'express', 'mapping', 'handler', 'urlpattern',
    ],
    'database': [
      'sql', 'create table', 'migration', 'schema', 'model', 'entity', 'table',
      'column', 'orm', 'sqlalchemy', 'prisma', 'gorm', 'sequelize',
      'repository', 'dao', 'foreignkey', 'primary key',
    ],
    'detail_design': [
      'class', 'def ', 'function', 'algorithm', 'process', 'service', 'core',
      'util', 'handler', 'manager', 'engine', 'pipeline',
    ],
    'test_plan': ['test', 'spec', 'assert', 'mock', 'pytest', 'junit', 'jest'],
    'test_record': ['test', 'spec', 'assert', 'case'],
    'test_report': ['test', 'coverage', 'assert'],
    'deploy': [
      'dockerfile', 'docker', 'compose', 'deploy', 'ci', 'workflow', 'install',
      'env', 'config', 'port', 'nginx', 'systemd', '.sh', 'start', 'build',
    ],
    'inspection': ['log', 'health', 'monitor', 'metric', 'service', 'backup'],
    'release': ['version', 'changelog', 'release', 'tag', 'migrate'],
    'plan': ['readme', 'package', 'pubspec', 'requirements', 'config'],
    'review': ['test', 'config', 'service', 'module'],
    'train_plan': ['readme', 'ui', 'page', 'view', 'service', 'api'],
    'user_manual': ['ui', 'page', 'view', 'component', 'route', 'form',
      'button', 'login', 'menu'],
  };

  static const List<String> _fallbackKeywords = [
    'service', 'config', 'main', 'app', 'module', 'api', 'model',
  ];

  /// 从语料中挑出与该分类最相关的若干文件，拼成带路径的代码片段块。
  String _selectRelevantCode(
    List<Map<String, String>> corpus,
    ProjectDocCategory cat,
  ) =>
      _selectCode(corpus, _catKeywords[cat.id] ?? _fallbackKeywords);

  /// 按关键词从语料中挑出最相关的若干文件，拼成带路径的代码片段块。
  String _selectCode(List<Map<String, String>> corpus, List<String> kws) {
    if (corpus.isEmpty) return '';
    final scored = <({int score, Map<String, String> file})>[];
    for (final f in corpus) {
      final path = (f['path'] ?? '').toLowerCase();
      final lc = (f['content'] ?? '').toLowerCase();
      final base = p.basename(path);
      var score = 0;
      // 背景基础分：README/清单/配置/建表脚本总是值得带上一点，保证有总体上下文。
      if (base.startsWith('readme') ||
          base == 'package.json' ||
          base == 'pubspec.yaml' ||
          base == 'requirements.txt' ||
          base == 'dockerfile' ||
          base.endsWith('.sql')) {
        score += 2;
      }
      for (final k in kws) {
        if (path.contains(k)) score += 3;
        var idx = lc.indexOf(k);
        var hits = 0;
        while (idx >= 0 && hits < 6) {
          hits++;
          idx = lc.indexOf(k, idx + k.length);
        }
        score += hits;
      }
      if (score > 0) scored.add((score: score, file: f));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    final buf = StringBuffer();
    var budget = 16000;
    var count = 0;
    for (final s in scored) {
      if (budget <= 0 || count >= 8) break;
      var content = s.file['content'] ?? '';
      if (content.length > 4000) {
        content = '${content.substring(0, 4000)}\n…（内容截断）';
      }
      buf
        ..writeln('### 文件：${s.file['path']}')
        ..writeln('```')
        ..writeln(content)
        ..writeln('```')
        ..writeln();
      budget -= content.length;
      count++;
    }
    return buf.toString();
  }

  /// 在后台 isolate 遍历工程，采集用于据实撰写的真实文件内容（含路径）。
  /// 文档/依赖清单/配置/建表脚本优先，其余源码按浅层优先收集，控制总预算。
  static List<Map<String, String>> _collectCodeCorpus((String, String) msg) {
    final rootPath = msg.$1;
    final rgExe = msg.$2;
    const exts = {
      '.dart', '.py', '.js', '.jsx', '.ts', '.tsx', '.java', '.kt', '.go',
      '.rs', '.c', '.h', '.cc', '.cpp', '.hpp', '.cxx', '.cs', '.rb', '.php',
      '.swift', '.m', '.scala', '.lua', '.vue', '.svelte', '.sql', '.proto',
      '.graphql', '.yaml', '.yml', '.toml', '.ini', '.cfg', '.json', '.xml',
      '.gradle', '.md', '.txt', '.sh',
    };
    const manifestNames = {'dockerfile', 'makefile'};
    const maxTotal = 240000;
    const maxFiles = 140;
    const perFileCap = 6000;

    final collected = <({int depth, File file})>[];
    for (final rel in Ripgrep.listFilesSync(rgExe, rootPath)) {
      if (collected.length >= maxFiles * 4) break;
      final depth = '/'.allMatches(rel).length;
      if (depth > 6) continue;
      final lower = p.basename(rel).toLowerCase();
      final ext = p.extension(lower);
      if (!exts.contains(ext) && !manifestNames.contains(lower)) continue;
      collected.add((depth: depth, file: File(p.join(rootPath, rel))));
    }

    int priority(String lower, String ext) {
      if (lower.startsWith('readme')) return 0;
      if (const {
        'requirements.txt', 'pyproject.toml', 'setup.py', 'package.json',
        'pubspec.yaml', 'cargo.toml', 'go.mod', 'pom.xml', 'build.gradle',
        'dockerfile', 'makefile',
      }.contains(lower)) {
        return 1;
      }
      if (ext == '.sql') return 2;
      if (const ['.yaml', '.yml', '.toml', '.ini', '.cfg', '.json', '.xml']
          .contains(ext)) {
        return 3;
      }
      return 4;
    }

    collected.sort((a, b) {
      final la = p.basename(a.file.path).toLowerCase();
      final lb = p.basename(b.file.path).toLowerCase();
      final pa = priority(la, p.extension(la));
      final pb = priority(lb, p.extension(lb));
      if (pa != pb) return pa - pb;
      return a.depth.compareTo(b.depth);
    });

    final out = <Map<String, String>>[];
    var total = 0;
    for (final c in collected) {
      if (out.length >= maxFiles || total >= maxTotal) break;
      String content;
      try {
        content = c.file.readAsStringSync();
      } catch (_) {
        continue;
      }
      if (content.trim().isEmpty) continue;
      if (content.length > perFileCap) {
        content = '${content.substring(0, perFileCap)}\n…（内容截断）';
      }
      final rel =
          p.relative(c.file.path, from: rootPath).replaceAll('\\', '/');
      out.add({'path': rel, 'content': content});
      total += content.length;
    }
    return out;
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}\n…（已截断）';
}
