import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/library_service.dart';
import '../services/playwright_service.dart';
import '../services/settings_service.dart';
import '../services/zotero_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.library,
    required this.zotero,
    required this.playwright,
  });

  final SettingsService settings;
  final LibraryService library;
  final ZoteroService zotero;
  final PlaywrightService playwright;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _vaultController = TextEditingController(
    text: widget.settings.vaultPath,
  );
  late final _portController = TextEditingController(
    text: widget.settings.zoteroPort.toString(),
  );
  late bool _zoteroEnabled = widget.settings.zoteroEnabled;
  late bool _pwEnabled = widget.settings.playwrightEnabled;
  late bool _pwBrowserResearchEnabled =
      widget.settings.playwrightBrowserResearchEnabled;

  // 「做实验」所用的大模型供应商及各自的 API 接入配置。
  late String _expProvider = widget.settings.experimentProvider;
  late final Map<String, _ProviderControllers> _providerCtrls = {
    for (final p in SettingsService.experimentProviders)
      if (!p.builtin)
        p.key: _ProviderControllers(
          apiKey: TextEditingController(
            text: widget.settings.providerApiKey(p.key),
          ),
          baseUrl: TextEditingController(
            text: widget.settings.providerBaseUrl(p.key),
          ),
          model: TextEditingController(
            text: widget.settings.providerModel(p.key),
          ),
        ),
  };

  // 「图像模型（文生图）」配置——用于专业书籍补充插图。
  late final _imgKeyCtrl = TextEditingController(
    text: widget.settings.imageApiKey,
  );
  late final _imgBaseCtrl = TextEditingController(
    text: widget.settings.imageBaseUrl,
  );
  late final _imgModelCtrl = TextEditingController(
    text: widget.settings.imageModel,
  );

  bool _testing = false;
  bool? _testOk;

  bool _pwChecking = false;
  bool? _pwReady;
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  @override
  void dispose() {
    _vaultController.dispose();
    _portController.dispose();
    _imgKeyCtrl.dispose();
    _imgBaseCtrl.dispose();
    _imgModelCtrl.dispose();
    for (final c in _providerCtrls.values) {
      c.apiKey.dispose();
      c.baseUrl.dispose();
      c.model.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final port = int.tryParse(_portController.text.trim()) ?? 23119;
    await widget.settings.update(
      vaultPath: _vaultController.text.trim(),
      zoteroEnabled: _zoteroEnabled,
      zoteroPort: port,
      playwrightEnabled: _pwEnabled,
      playwrightBrowserResearchEnabled: _pwBrowserResearchEnabled,
    );
    for (final entry in _providerCtrls.entries) {
      await widget.settings.setProviderConfig(
        entry.key,
        apiKey: entry.value.apiKey.text,
        baseUrl: entry.value.baseUrl.text,
        model: entry.value.model.text,
      );
    }
    await widget.settings.setExperimentProvider(_expProvider);
    await widget.settings.setImageConfig(
      apiKey: _imgKeyCtrl.text,
      baseUrl: _imgBaseCtrl.text,
      model: _imgModelCtrl.text,
    );
    await widget.library.reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('设置已保存，知识库已重新扫描'),
          behavior: SnackBarBehavior.floating,
          width: 400,
        ),
      );
    }
  }

  Future<void> _testZotero() async {
    final port = int.tryParse(_portController.text.trim()) ?? 23119;
    await widget.settings.update(zoteroPort: port);
    setState(() {
      _testing = true;
      _testOk = null;
    });
    final ok = await widget.zotero.ping();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = ok;
    });
  }

  Future<void> _checkPlaywright() async {
    setState(() {
      _pwChecking = true;
      _pwReady = null;
    });
    final ok = await widget.playwright.ready();
    if (!mounted) return;
    setState(() {
      _pwChecking = false;
      _pwReady = ok;
    });
  }

  Future<void> _installPlaywright() async {
    // 先确保开关已保存，否则 ready() 始终为 false。
    await widget.settings.update(playwrightEnabled: true);
    if (!mounted) return;
    setState(() => _pwEnabled = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AnimatedBuilder(
        animation: widget.playwright,
        builder: (_, child) {
          final logs = widget.playwright.logs;
          final done = !widget.playwright.installing;
          return AlertDialog(
            title: const Text('安装 Playwright'),
            content: SizedBox(
              width: 520,
              height: 320,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!done)
                    const Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 10),
                        Text('正在安装，请耐心等待（首次需下载 Chromium）…'),
                      ],
                    ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F7),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SingleChildScrollView(
                        reverse: true,
                        child: Text(
                          logs.isEmpty ? '准备中…' : logs.join('\n'),
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontFamily: 'Consolas',
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: done ? () => Navigator.of(dialogCtx).pop() : null,
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
    await widget.playwright.install();
    await _checkPlaywright();
  }

  Future<void> _clearPlaywrightState() async {
    await widget.playwright.clearBrowserState();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已清除 Playwright 浏览研究的网页登录态'),
        behavior: SnackBarBehavior.floating,
        width: 400,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(40),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '设置',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
              ),
              FilledButton.icon(
                onPressed: _save,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1A1A1A),
                ),
                icon: const Icon(Icons.save_outlined, size: 16),
                label: const Text('保存'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field('知识库路径（本地文件夹）', _vaultController),
              const SizedBox(height: 8),
              _buildExperimentModelCard(),
              const SizedBox(height: 8),
              _buildRoleModelCard(),
              const SizedBox(height: 8),
              _buildImageModelCard(),
              const SizedBox(height: 8),
              _buildZoteroCard(),
              const SizedBox(height: 8),
              _buildPlaywrightCard(),
              const SizedBox(height: 8),
              _buildAboutCard(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildExperimentModelCard() {
    final providers = SettingsService.experimentProviders;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '做实验/项目开发使用的大模型',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            '「做实验/项目开发」时由该模型驱动 Agent 写代码、跑程序、修报错。'
            'DeepSeek 从本地 .env 注入，MiniMax / GLM / Qwen / Kimi 可在这里填写 API Key 后切换选用。'
            '开启 Playwright 浏览研究后，网页阅读和整理也会使用这里选择的大模型。',
            style: TextStyle(fontSize: 12, color: Color(0xFF8B8B90)),
          ),
          const SizedBox(height: 12),
          RadioGroup<String>(
            groupValue: _expProvider,
            onChanged: (v) => setState(() => _expProvider = v!),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final p in providers) _buildProviderTile(p)],
            ),
          ),
        ],
      ),
    );
  }

  /// 「各功能使用的模型」：为每类任务单独挑选供应商。
  /// 选「默认」即沿用推荐映射（Agent 跟随上面的实验大模型，其余走 DeepSeek），
  /// 不配置时行为与以前完全一致。改动即时保存。
  Widget _buildRoleModelCard() {
    const roles = <(ModelRole, String, String)>[
      (ModelRole.chat, '聊天', '日常对话回复'),
      (ModelRole.writing, '写作', '小说 / 论文 / 正式文档生成'),
      (ModelRole.research, '主题研究', '研究规划与报告综合'),
      (ModelRole.agent, '实验 / 项目 / 计划', '需要工具调用的 Agent 主循环'),
      (ModelRole.small, '轻量任务', '记忆抽取、分类合并等廉价调用'),
      (ModelRole.vision, '读图分析', '网页截图等需要视觉的判断'),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '各功能使用的模型',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            '可为不同任务分别指定模型，例如写作用更强的模型、轻量任务用便宜模型。'
            '选「默认」即沿用推荐：实验/项目/计划跟随上面的大模型，其余走 DeepSeek。',
            style: TextStyle(fontSize: 12, color: Color(0xFF8B8B90)),
          ),
          const SizedBox(height: 8),
          for (final r in roles) _buildRoleRow(r.$1, r.$2, r.$3),
        ],
      ),
    );
  }

  Widget _buildRoleRow(ModelRole role, String label, String hint) {
    final current = widget.settings.roleProviderOverride(role);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  hint,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9B9B9F),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: current,
            underline: const SizedBox.shrink(),
            style: const TextStyle(fontSize: 13, color: Color(0xFF2B2B2E)),
            items: [
              const DropdownMenuItem(value: '', child: Text('默认（推荐）')),
              for (final p in SettingsService.experimentProviders)
                DropdownMenuItem(value: p.key, child: Text(p.name)),
            ],
            onChanged: (v) async {
              await widget.settings.setRoleProvider(role, v ?? '');
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }

  /// 「图像模型（文生图）」：用于专业书籍里 AI 生成插图。
  /// 走 OpenAI 兼容的 /images/generations 接口，需填基址、Key、模型名。
  /// 三项填全后「专业书籍 → 补充图表 → AI 文生图」才可用，否则置灰。
  Widget _buildImageModelCard() {
    final ready = widget.settings.imageGenReady;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '图像模型（文生图）',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              if (ready)
                _tag('已配置', const Color(0xFF0D9488))
              else
                _tag('未配置', const Color(0xFFB08400)),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '用于「专业书籍 → 补充图表 → AI 文生图」。填写 OpenAI 兼容的图像生成接口'
            '（如智谱 CogView、通义万相等），自动拼接 /images/generations。未配置时该选项不可用。',
            style: TextStyle(fontSize: 12, color: Color(0xFF8B8B90)),
          ),
          const SizedBox(height: 12),
          _miniField('API Key', _imgKeyCtrl, obscure: true),
          const SizedBox(height: 8),
          _miniField('接口基址 Base URL', _imgBaseCtrl),
          const SizedBox(height: 8),
          _miniField('模型名 Model', _imgModelCtrl),
        ],
      ),
    );
  }

  Widget _buildProviderTile(LlmProviderPreset p) {
    final selected = _expProvider == p.key;
    final ctrls = _providerCtrls[p.key];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.fromLTRB(12, 4, 12, selected ? 14 : 4),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFF0FBF9) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? const Color(0xFF7FD3C7) : const Color(0xFFE6E6E9),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RadioListTile<String>(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: p.key,
            activeColor: const Color(0xFF0D9488),
            title: Row(
              children: [
                Text(
                  p.name,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                if (widget.settings.providerReady(p.key) ||
                    (ctrls?.apiKey.text.trim().isNotEmpty ?? false))
                  _tag('已配置', const Color(0xFF0D9488))
                else if (p.builtin)
                  _tag('需 .env', const Color(0xFFB08400))
                else
                  _tag('未配置', const Color(0xFFB08400)),
              ],
            ),
            subtitle: p.hint.isEmpty
                ? null
                : Text(
                    p.hint,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF9B9B9F),
                    ),
                  ),
          ),
          if (selected && !p.builtin && ctrls != null) ...[
            const SizedBox(height: 4),
            _miniField('API Key', ctrls.apiKey, obscure: true),
            const SizedBox(height: 8),
            _miniField('接口基址 Base URL', ctrls.baseUrl),
            const SizedBox(height: 8),
            _miniField('模型名 Model', ctrls.model),
          ],
        ],
      ),
    );
  }

  Widget _tag(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
    ),
  );

  Widget _miniField(
    String label,
    TextEditingController controller, {
    bool obscure = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Widget _buildZoteroCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _zoteroEnabled,
            onChanged: (v) => setState(() => _zoteroEnabled = v),
            title: const Text(
              '接入 Zotero 文献库',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              '主题研究时优先检索你已有的文献，并把新下载的论文自动登记入 Zotero（含 PDF 附件）。'
              '需在 Zotero「设置 → 高级」勾选「允许其他应用与本机 Zotero 通信」并保持 Zotero 运行。',
              style: TextStyle(fontSize: 12, color: Color(0xFF8B8B90)),
            ),
          ),
          if (_zoteroEnabled) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 13.5),
                    decoration: InputDecoration(
                      labelText: '本地端口',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _testing ? null : _testZotero,
                  icon: _testing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering, size: 16),
                  label: const Text('测试连接'),
                ),
                const SizedBox(width: 12),
                if (_testOk == true)
                  const Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        color: Color(0xFF0D9488),
                        size: 18,
                      ),
                      SizedBox(width: 4),
                      Text(
                        '已连接',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF0D9488),
                        ),
                      ),
                    ],
                  ),
                if (_testOk == false)
                  const Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: Color(0xFFD9534F),
                        size: 18,
                      ),
                      SizedBox(width: 4),
                      Text(
                        '未连接（请确认 Zotero 已运行）',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFFD9534F),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPlaywrightCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _pwEnabled,
            onChanged: (v) => setState(() => _pwEnabled = v),
            title: const Text(
              '启用 Playwright 辅助抓取',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              '主题研究时用 Playwright 渲染政策/法规/标准等网页，抓取真实链接、'
              '把网页保存为 PDF 或直接下载 PDF，比系统自带浏览器更可靠。'
              '需已安装 Node.js，首次使用请点下方「安装 Playwright」。',
              style: TextStyle(fontSize: 12, color: Color(0xFF8B8B90)),
            ),
          ),
          if (_pwEnabled) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _pwBrowserResearchEnabled,
              onChanged: (v) => setState(() => _pwBrowserResearchEnabled = v),
              title: const Text(
                '启用 Playwright 浏览研究模式',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '主题研究的网页来源会像用户一样搜索、打开、滚动阅读。'
                '页面理解使用上方“做实验/项目开发使用的大模型”：${widget.settings.experimentModel}。'
                '登录凭据只临时用于当前会话，不保存账号密码。',
                style: const TextStyle(fontSize: 12, color: Color(0xFF8B8B90)),
              ),
            ),
            if (_pwBrowserResearchEnabled &&
                widget.settings.experimentProvider == 'deepseek') ...[
              const SizedBox(height: 4),
              const Text(
                '当前仍是 DeepSeek。浏览研究需要先在上方切换并配置支持视觉的大模型。',
                style: TextStyle(fontSize: 12, color: Color(0xFFD97706)),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: widget.playwright.installing
                      ? null
                      : _installPlaywright,
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('安装 Playwright'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _pwChecking ? null : _checkPlaywright,
                  icon: _pwChecking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.verified_outlined, size: 16),
                  label: const Text('检测状态'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _clearPlaywrightState,
                  icon: const Icon(Icons.logout, size: 16),
                  label: const Text('清除网页登录态'),
                ),
                const SizedBox(width: 12),
                if (_pwReady == true)
                  const Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        color: Color(0xFF0D9488),
                        size: 18,
                      ),
                      SizedBox(width: 4),
                      Text(
                        '已就绪',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF0D9488),
                        ),
                      ),
                    ],
                  ),
                if (_pwReady == false)
                  const Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: Color(0xFFD9534F),
                        size: 18,
                      ),
                      SizedBox(width: 4),
                      Text(
                        '未就绪',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFFD9534F),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAboutCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFECECEE)),
      ),
      child: FutureBuilder<PackageInfo>(
        future: _packageInfo,
        builder: (context, snapshot) {
          final version = snapshot.data?.version ?? '读取中';
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '关于',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              const Text(
                '第二大脑是一款面向本地知识库、主题研究、写作和项目开发的一体化智能工作台。',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF6B6B70)),
              ),
              const SizedBox(height: 8),
              Text(
                '版本号：$version',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9B9B9F)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _field(String label, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: Color(0xFF6B6B70)),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个实验模型供应商的输入控制器集合。
class _ProviderControllers {
  _ProviderControllers({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  });

  final TextEditingController apiKey;
  final TextEditingController baseUrl;
  final TextEditingController model;
}
