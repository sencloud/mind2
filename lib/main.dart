import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:window_manager/window_manager.dart';

import 'services/agent/memory/memory_service.dart';
import 'services/book_service.dart';
import 'services/chat_service.dart';
import 'services/document_service.dart';
import 'services/drawing_service.dart';
import 'services/experiment_service.dart';
import 'services/file_library_service.dart';
import 'services/library_service.dart';
import 'services/mind_map_service.dart';
import 'services/paper_service.dart';
import 'services/plan_service.dart';
import 'services/platform_capabilities.dart';
import 'services/playwright_service.dart';
import 'services/pro_book_service.dart';
import 'services/project_doc_service.dart';
import 'services/project_service.dart';
import 'services/promo_service.dart';
import 'services/settings_service.dart';
import 'services/system_proxy.dart';
import 'services/topic_service.dart';
import 'services/video_service.dart';
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
  final project = ProjectService(settings, memory, research: topic);
  final document = DocumentService(settings);
  final projectDoc = ProjectDocService(settings, memory, document, library);
  final proBook = ProBookService(
    settings,
    library: library,
    fileLibrary: fileLibrary,
  );
  final mindMap = MindMapService(settings);
  final book = BookService(settings);
  final paper = PaperService(settings, project: project, docs: projectDoc);
  final promo = PromoService(settings, project: project, memory: memory);
  // 「画图」：据关联工程生成漂亮完整的架构图（复用文档服务的 Mermaid 渲染）。
  final drawing = DrawingService(settings, project: project, document: document);
  // 「视频」：据创意生成分镜脚本。
  final video = VideoService(settings);
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
  if (PlatformCapabilities.supportsProjectDev) {
    await projectDoc.init();
  }
  await proBook.init();
  await mindMap.init();
  await book.init();
  await paper.init();
  await promo.init();
  await drawing.init();
  await video.init();
  await plan.init();
  unawaited(library.reload());
  unawaited(fileLibrary.reload());
  runApp(
    MindApp(
      settings: settings,
      memory: memory,
      library: library,
      fileLibrary: fileLibrary,
      chat: chat,
      topic: topic,
      zotero: zotero,
      playwright: playwright,
      experiment: experiment,
      project: project,
      projectDoc: projectDoc,
      document: document,
      proBook: proBook,
      mindMap: mindMap,
      book: book,
      paper: paper,
      promo: promo,
      drawing: drawing,
      video: video,
      plan: plan,
    ),
  );
}

void unawaited(Future<void> f) {}

/// 允许触摸、鼠标、触控笔、触控板拖动滚动：安卓触摸滚动更顺，桌面也可鼠标拖拽。
class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
      };
}

class MindApp extends StatelessWidget {
  const MindApp({
    super.key,
    required this.settings,
    required this.memory,
    required this.library,
    required this.fileLibrary,
    required this.chat,
    required this.topic,
    required this.zotero,
    required this.playwright,
    required this.experiment,
    required this.project,
    required this.projectDoc,
    required this.document,
    required this.proBook,
    required this.mindMap,
    required this.book,
    required this.paper,
    required this.promo,
    required this.drawing,
    required this.video,
    required this.plan,
  });

  final SettingsService settings;
  final MemoryService memory;
  final LibraryService library;
  final FileLibraryService fileLibrary;
  final ChatService chat;
  final TopicFetchService topic;
  final ZoteroService zotero;
  final PlaywrightService playwright;
  final ExperimentService experiment;
  final ProjectService project;
  final ProjectDocService projectDoc;
  final DocumentService document;
  final ProBookService proBook;
  final MindMapService mindMap;
  final BookService book;
  final PaperService paper;
  final PromoService promo;
  final DrawingService drawing;
  final VideoService video;
  final PlanService plan;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '第二大脑',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const _AppScrollBehavior(),
      theme: ThemeData(
        useMaterial3: true,
        // 打包字体统一桌面与安卓观感；系统字体作为缺字兜底。
        fontFamily: 'Noto Sans SC',
        fontFamilyFallback: const [
          'Microsoft YaHei UI',
          'PingFang SC',
          'Noto Sans CJK SC',
          'sans-serif',
        ],
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
              memory: memory,
              library: library,
              fileLibrary: fileLibrary,
              chat: chat,
              topicService: topic,
              document: document,
              proBook: proBook,
              mindMap: mindMap,
              book: book,
              paper: paper,
              promo: promo,
            )
          : AppShell(
              settings: settings,
              memory: memory,
              library: library,
              fileLibrary: fileLibrary,
              chat: chat,
              topicService: topic,
              zotero: zotero,
              playwright: playwright,
              experiment: experiment,
              project: project,
              projectDoc: projectDoc,
              document: document,
              proBook: proBook,
              mindMap: mindMap,
              book: book,
              paper: paper,
              promo: promo,
              drawing: drawing,
              video: video,
              plan: plan,
            ),
    );
  }
}
