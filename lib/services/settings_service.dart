import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'platform_capabilities.dart';

/// 一个可用于「做实验」的大模型供应商预设。
class LlmProviderPreset {
  const LlmProviderPreset({
    required this.key,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.builtin = false,
    this.hint = '',
  });

  /// 唯一标识（持久化用）。
  final String key;

  /// 展示名。
  final String name;

  /// OpenAI 兼容的接口基址（自动拼接 `/chat/completions`）。
  final String baseUrl;

  /// 默认模型名。
  final String model;

  /// 是否为项目默认供应商。
  /// 默认供应商的密钥来自本地环境，不在设置页里保存。
  final bool builtin;

  /// 申请/文档提示。
  final String hint;
}

/// 按「任务角色」区分模型通道。统一 LLM 客户端据此为每类任务挑选合适的模型，
/// 而不再是过去那种「默认 DeepSeek vs 实验模型」的两档粗粒度划分。
/// - chat：日常聊天
/// - writing：写作（小说/论文/正式文档）
/// - research：主题研究的规划与综合
/// - agent：实验/项目/计划等需要工具调用的 Agent 主循环
/// - small：记忆选择/抽取、分类合并等廉价小任务
/// - vision：需要读图（截图）的任务
enum ModelRole { chat, writing, research, agent, small, vision }

class SettingsService extends ChangeNotifier {
  late SharedPreferences _prefs;

  static const _desktopDefaultVault = r'D:\我的大脑';

  // DeepSeek 密钥不应写进源码。
  // 本地 run / build 脚本会读取 .env，并通过 --dart-define 注入这里。
  static const _apiKey = String.fromEnvironment('DEEPSEEK_API_KEY');
  static const _baseUrl = String.fromEnvironment(
    'DEEPSEEK_BASE_URL',
    defaultValue: 'https://api.deepseek.com',
  );
  static const _model = String.fromEnvironment(
    'DEEPSEEK_MODEL',
    defaultValue: 'deepseek-v4-flash',
  );

  /// 「做实验」可选的大模型供应商。默认仍为 DeepSeek，
  /// MiniMax / GLM / Qwen / Kimi 需用户在设置里填入各自的 API Key 后方可选用。
  static const List<LlmProviderPreset> experimentProviders = [
    LlmProviderPreset(
      key: 'deepseek',
      name: 'DeepSeek（本地环境）',
      baseUrl: _baseUrl,
      model: _model,
      builtin: true,
    ),
    LlmProviderPreset(
      key: 'minimax',
      name: 'MiniMax',
      baseUrl: 'https://api.minimaxi.com/v1',
      model: 'MiniMax-Text-01',
      hint: '在 MiniMax 开放平台创建 API Key。',
    ),
    LlmProviderPreset(
      key: 'glm',
      name: '智谱 GLM',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-4-plus',
      hint: '在智谱 AI 开放平台（bigmodel.cn）创建 API Key。',
    ),
    LlmProviderPreset(
      key: 'qwen',
      name: '通义千问 Qwen',
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      model: 'qwen-plus',
      hint: '在阿里云百炼 DashScope 控制台创建 API Key。',
    ),
    LlmProviderPreset(
      key: 'kimi',
      name: 'Kimi（Moonshot）',
      baseUrl: 'https://api.moonshot.cn/v1',
      model: 'moonshot-v1-32k',
      hint: '在 Moonshot 开放平台（platform.moonshot.cn）创建 API Key。',
    ),
  ];

  static LlmProviderPreset presetFor(String key) => experimentProviders
      .firstWhere((p) => p.key == key, orElse: () => experimentProviders.first);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    if (!_prefs.containsKey('vaultPath')) {
      final path = await _initialVaultPath();
      await Directory(path).create(recursive: true);
      await _prefs.setString('vaultPath', path);
    }
  }

  Future<String> _initialVaultPath() async {
    if (PlatformCapabilities.isMobile) {
      final dir = await getApplicationDocumentsDirectory();
      return p.join(dir.path, '我的大脑');
    }
    if (!kIsWeb && Platform.isWindows && await Directory(r'D:\').exists()) {
      return _desktopDefaultVault;
    }
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home != null && home.trim().isNotEmpty) {
      return p.join(home, '我的大脑');
    }
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, '我的大脑');
  }

  String get vaultPath => _prefs.getString('vaultPath') ?? _desktopDefaultVault;

  // 默认（DeepSeek）配置：研究 / 对话 / 知识库等全部沿用，不受实验模型选择影响。
  String get apiKey => _apiKey;
  String get baseUrl => _baseUrl;
  String get model => _model;

  // ---------------------------------------------------------------------------
  // 「做实验」专用的大模型供应商配置
  // ---------------------------------------------------------------------------

  /// 当前用于做实验的供应商 key，默认使用本地环境注入的 DeepSeek。
  String get experimentProvider =>
      _prefs.getString('experimentProvider') ?? 'deepseek';

  String providerApiKey(String key) {
    if (key == 'deepseek') return _apiKey;
    return (_prefs.getString('llm_${key}_apiKey') ?? '').trim();
  }

  String providerBaseUrl(String key) {
    if (key == 'deepseek') return _baseUrl;
    final v = (_prefs.getString('llm_${key}_baseUrl') ?? '').trim();
    return v.isNotEmpty ? v : presetFor(key).baseUrl;
  }

  String providerModel(String key) {
    if (key == 'deepseek') return _model;
    final v = (_prefs.getString('llm_${key}_model') ?? '').trim();
    return v.isNotEmpty ? v : presetFor(key).model;
  }

  /// 某供应商是否已就绪。DeepSeek 需要通过 .env 注入 API Key。
  bool providerReady(String key) => providerApiKey(key).isNotEmpty;

  // 做实验时实际使用的配置（指向所选供应商）。
  String get experimentApiKey => providerApiKey(experimentProvider);
  String get experimentBaseUrl => providerBaseUrl(experimentProvider);
  String get experimentModel => providerModel(experimentProvider);

  Future<void> setExperimentProvider(String key) async {
    await _prefs.setString('experimentProvider', key);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 按任务角色的模型路由（统一 LLM 客户端使用）
  // ---------------------------------------------------------------------------

  /// 角色 → 供应商 key。用户在设置里为某角色单独指定时优先用其选择；
  /// 否则用默认映射：agent 跟随「实验/项目大模型」，其余角色走默认 DeepSeek。
  /// 这样在用户未做任何配置时，行为与改造前完全一致。
  String roleProviderKey(ModelRole role) {
    final saved = (_prefs.getString('role_${role.name}_provider') ?? '').trim();
    if (saved.isNotEmpty) return saved;
    // agent 与 vision（读图/网页截图判断）默认跟随「实验/项目大模型」，
    // 其余角色走默认 DeepSeek。用户可在设置里为任一角色单独覆盖。
    return (role == ModelRole.agent || role == ModelRole.vision)
        ? experimentProvider
        : 'deepseek';
  }

  /// 该角色用户显式指定的供应商 key；为空表示沿用默认映射（供设置页展示）。
  String roleProviderOverride(ModelRole role) =>
      (_prefs.getString('role_${role.name}_provider') ?? '').trim();

  String roleBaseUrl(ModelRole role) => providerBaseUrl(roleProviderKey(role));
  String roleApiKey(ModelRole role) => providerApiKey(roleProviderKey(role));
  String roleModel(ModelRole role) => providerModel(roleProviderKey(role));

  /// 该角色当前是否就绪（对应供应商已填好 Key）。
  bool roleReady(ModelRole role) => providerReady(roleProviderKey(role));

  /// 为某个角色单独指定供应商（传空字符串表示恢复默认映射）。
  Future<void> setRoleProvider(ModelRole role, String key) async {
    if (key.trim().isEmpty) {
      await _prefs.remove('role_${role.name}_provider');
    } else {
      await _prefs.setString('role_${role.name}_provider', key.trim());
    }
    notifyListeners();
  }

  Future<void> setProviderConfig(
    String key, {
    String? apiKey,
    String? baseUrl,
    String? model,
  }) async {
    if (key == 'deepseek') return; // 内置默认不可改。
    if (apiKey != null) {
      await _prefs.setString('llm_${key}_apiKey', apiKey.trim());
    }
    if (baseUrl != null) {
      await _prefs.setString('llm_${key}_baseUrl', baseUrl.trim());
    }
    if (model != null) await _prefs.setString('llm_${key}_model', model.trim());
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 工程语义索引（Embedding）配置——用于「项目开发」的代码检索 (RAG)
  // ---------------------------------------------------------------------------

  static const _embeddingDefaultBaseUrl =
      'https://dashscope.aliyuncs.com/compatible-mode/v1';
  static const _embeddingDefaultModel = 'text-embedding-v3';

  bool get embeddingEnabled => _prefs.getBool('embeddingEnabled') ?? true;

  String get embeddingBaseUrl {
    final v = (_prefs.getString('embeddingBaseUrl') ?? '').trim();
    return v.isNotEmpty ? v : _embeddingDefaultBaseUrl;
  }

  String get embeddingApiKey =>
      (_prefs.getString('embeddingApiKey') ?? '').trim();

  String get embeddingModel {
    final v = (_prefs.getString('embeddingModel') ?? '').trim();
    return v.isNotEmpty ? v : _embeddingDefaultModel;
  }

  /// 是否可用于建索引：已启用且填了 Key。
  bool get embeddingReady => embeddingEnabled && embeddingApiKey.isNotEmpty;

  Future<void> setEmbeddingConfig({
    bool? enabled,
    String? apiKey,
    String? baseUrl,
    String? model,
  }) async {
    if (enabled != null) await _prefs.setBool('embeddingEnabled', enabled);
    if (apiKey != null) {
      await _prefs.setString('embeddingApiKey', apiKey.trim());
    }
    if (baseUrl != null) {
      await _prefs.setString('embeddingBaseUrl', baseUrl.trim());
    }
    if (model != null) await _prefs.setString('embeddingModel', model.trim());
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 图像生成（文生图）配置——用于「专业书籍」补充插图
  // OpenAI 兼容接口：自动拼接 `/images/generations`。未配置时该功能置灰。
  // ---------------------------------------------------------------------------

  String get imageBaseUrl => (_prefs.getString('imageBaseUrl') ?? '').trim();
  String get imageApiKey => (_prefs.getString('imageApiKey') ?? '').trim();
  String get imageModel => (_prefs.getString('imageModel') ?? '').trim();

  /// 三项都填好才算就绪，文生图按钮才可点。
  bool get imageGenReady =>
      imageBaseUrl.isNotEmpty && imageApiKey.isNotEmpty && imageModel.isNotEmpty;

  Future<void> setImageConfig({
    String? apiKey,
    String? baseUrl,
    String? model,
  }) async {
    if (apiKey != null) await _prefs.setString('imageApiKey', apiKey.trim());
    if (baseUrl != null) await _prefs.setString('imageBaseUrl', baseUrl.trim());
    if (model != null) await _prefs.setString('imageModel', model.trim());
    notifyListeners();
  }

  // Zotero 本地集成（连接桌面端，无需 API Key）。
  bool get zoteroEnabled => _prefs.getBool('zoteroEnabled') ?? true;
  int get zoteroPort => _prefs.getInt('zoteroPort') ?? 23119;

  // Playwright 辅助抓取（更可靠地渲染政策/法规/标准页面并下载 PDF）。
  bool get playwrightEnabled => _prefs.getBool('playwrightEnabled') ?? true;

  /// 浏览研究模式会打开持久 Playwright 会话，像用户一样搜索、滚动、阅读网页。
  /// 它依赖设置里的实验/项目大模型做页面理解，默认关闭，避免未配置视觉模型时误用。
  bool get playwrightBrowserResearchEnabled =>
      _prefs.getBool('playwrightBrowserResearchEnabled') ?? false;

  Future<void> update({
    String? vaultPath,
    bool? zoteroEnabled,
    int? zoteroPort,
    bool? playwrightEnabled,
    bool? playwrightBrowserResearchEnabled,
  }) async {
    if (vaultPath != null) await _prefs.setString('vaultPath', vaultPath);
    if (zoteroEnabled != null) {
      await _prefs.setBool('zoteroEnabled', zoteroEnabled);
    }
    if (zoteroPort != null) await _prefs.setInt('zoteroPort', zoteroPort);
    if (playwrightEnabled != null) {
      await _prefs.setBool('playwrightEnabled', playwrightEnabled);
    }
    if (playwrightBrowserResearchEnabled != null) {
      await _prefs.setBool(
        'playwrightBrowserResearchEnabled',
        playwrightBrowserResearchEnabled,
      );
    }
    notifyListeners();
  }
}
