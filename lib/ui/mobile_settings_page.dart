import 'package:flutter/material.dart';

import '../services/library_service.dart';
import '../services/settings_service.dart';

class MobileSettingsPage extends StatelessWidget {
  const MobileSettingsPage({
    super.key,
    required this.settings,
    required this.library,
  });

  final SettingsService settings;
  final LibraryService library;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '设置',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 18),
          const Text(
            '知识库目录',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          SelectableText(
            settings.vaultPath,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B6B70)),
          ),
          const SizedBox(height: 8),
          const Text(
            'Android 首版使用 App 沙盒本地知识库。资料可在知识库页通过系统文件选择器导入。',
            style: TextStyle(fontSize: 13, color: Color(0xFF6B6B70)),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: () async {
              await library.initialize();
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('知识库目录已初始化')));
              }
            },
            icon: const Icon(Icons.create_new_folder_outlined, size: 16),
            label: const Text('初始化知识库目录'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: library.reload,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重新扫描知识库'),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          const Text(
            '移动端暂不包含项目开发、实验工程、Zotero 本地连接、Playwright 浏览器抓取和工程索引配置。',
            style: TextStyle(fontSize: 12.5, color: Color(0xFF9B9B9F)),
          ),
        ],
      ),
    );
  }
}
