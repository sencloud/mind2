import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:window_manager/window_manager.dart';

import 'services/agent/memory/memory_service.dart';
import 'services/book_service.dart';
import 'services/chat_service.dart';
import 'services/document_service.dart';
import 'services/experiment_service.dart';
import 'services/file_library_service.dart';
import 'services/library_service.dart';
import 'services/paper_service.dart';
import 'services/plan_service.dart';
import 'services/platform_capabilities.dart';
import 'services/playwright_service.dart';
import 'services/project_service.dart';
import 'services/settings_service.dart';
import 'services/system_proxy.dart';
import 'services/topic_service.dart';
import 'services/zotero_service.dart';
import 'ui/app_shell.dart';
import 'ui/mobile_app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 遵循系统代理（如 Clash）：否则 Dart 默认直连，境外站点（arXiv/OpenAlex/GitHub 等）
  // 可能因网络干扰导致 TLS 握手失败（CERTIFICATE_VERIFY_FAILED）。
  final sysProxy = await SystemProxy.detect();
  if (sysProxy != null && sysProxy.isNotEmpty) {
    HttpOverrides.global = SystemProxyHttpOverrides(sysProxy);
  }
  // 初始化媒体内核（视频/音频应用内播放）和 PDF 渲染引擎。
  MediaKit.ensureInitialized();
  await pdfrxFlutterInitialize();
  if (PlatformCapabilities.supportsDesktopWindow) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1280, 720),
      minimumSize: Size(960, 600),
      center: true,
      title: '第二大脑',
      titleBarStyle: TitleBarStyle.hidden,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  final settings = SettingsService();
  await settings.init();
  final memory = MemoryService(settings);
  await memory.init();
  final library = LibraryService(settings);
  final fileLibrary = FileLibraryService(settings);
  final chat = ChatService(settings, memory);
  final zotero = ZoteroService(settings);
  final playwright = PlaywrightService(settings);
  final topic = TopicFetchService(
    settings,
    library,
    fileLibrary,
    zotero,
    playwright,
    memory,
  );
  final experiment = ExperimentService(settings, memory);
  final project = ProjectService(settings, memory);
  final document = DocumentService(settings);
  final book = BookService(settings);
  final paper = PaperService(settings);
  // 「计划」：每日待办 + AI 分析并执行（复用统一 Agent 内核）。
  final plan = PlanService(settings, memory, research: topic);
  await chat.init();
  await topic.init();
  if (PlatformCapabilities.supportsExperiment) {
    await experiment.init();
  }
  if (PlatformCapabilities.supportsProjectDev) {
    await project.init();
  }
  await document.init();
  await book.init();
  await paper.init();
  await plan.init();
  unawaited(library.reload());
  unawaited(fileLibrary.reload());
  runApp(
    MindApp(
      settings: settings,
      library: library,
      fileLibrary: fileLibrary,
      chat: chat,
      topic: topic,
      zotero: zotero,
      playwright: playwright,
      experiment: experiment,
      project: project,
      document: document,
      book: book,
      paper: paper,
      plan: plan,
    ),
  );
}

void unawaited(Future<void> f) {}

class MindApp extends StatelessWidget {
  const MindApp({
    super.key,
    required this.settings,
    required this.library,
    required this.fileLibrary,
    required this.chat,
    required this.topic,
    required this.zotero,
    required this.playwright,
    required this.experiment,
    required this.project,
    required this.document,
    required this.book,
    required this.paper,
    required this.plan,
  });

  final SettingsService settings;
  final LibraryService library;
  final FileLibraryService fileLibrary;
  final ChatService chat;
  final TopicFetchService topic;
  final ZoteroService zotero;
  final PlaywrightService playwright;
  final ExperimentService experiment;
  final ProjectService project;
  final DocumentService document;
  final BookService book;
  final PaperService paper;
  final PlanService plan;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '第二大脑',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Microsoft YaHei UI',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A1A1A),
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: Colors.white,
        dividerColor: const Color(0xFFECECEE),
      ),
      home: PlatformCapabilities.isMobile
          ? MobileAppShell(
              settings: settings,
              library: library,
              fileLibrary: fileLibrary,
              chat: chat,
              topicService: topic,
              document: document,
              book: book,
              paper: paper,
            )
          : AppShell(
              settings: settings,
              library: library,
              fileLibrary: fileLibrary,
              chat: chat,
              topicService: topic,
              zotero: zotero,
              playwright: playwright,
              experiment: experiment,
              project: project,
              document: document,
              book: book,
              paper: paper,
              plan: plan,
            ),
    );
  }
}
