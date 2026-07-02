import 'package:flutter/material.dart';

import '../models.dart';
import '../services/agent/memory/memory_service.dart';
import '../services/book_service.dart';
import '../services/chat_service.dart';
import '../services/document_service.dart';
import '../services/file_library_service.dart';
import '../services/library_service.dart';
import '../services/mind_map_service.dart';
import '../services/paper_service.dart';
import '../services/pro_book_service.dart';
import '../services/settings_service.dart';
import '../services/topic_service.dart';
import 'chat_page.dart';
import 'knowledge_page.dart';
import 'mobile_library_page.dart';
import 'mobile_settings_page.dart';
import 'topic_page.dart';
import 'writing_page.dart';

class MobileAppShell extends StatefulWidget {
  const MobileAppShell({
    super.key,
    required this.settings,
    required this.memory,
    required this.library,
    required this.fileLibrary,
    required this.chat,
    required this.topicService,
    required this.document,
    required this.proBook,
    required this.mindMap,
    required this.book,
    required this.paper,
  });

  final SettingsService settings;
  final MemoryService memory;
  final LibraryService library;
  final FileLibraryService fileLibrary;
  final ChatService chat;
  final TopicFetchService topicService;
  final DocumentService document;
  final ProBookService proBook;
  final MindMapService mindMap;
  final BookService book;
  final PaperService paper;

  @override
  State<MobileAppShell> createState() => _MobileAppShellState();
}

class _MobileAppShellState extends State<MobileAppShell> {
  int _index = 0;
  StandardNote? _noteToOpen;
  int _libraryToken = 0;

  @override
  void initState() {
    super.initState();
    widget.topicService.onResearchComplete = (path) {
      if (!mounted) return;
      final matches = widget.library.notes.where((n) => n.filePath == path);
      if (matches.isNotEmpty) _openNote(matches.first);
    };
  }

  void _openNote(StandardNote note) {
    setState(() {
      _index = 1;
      _noteToOpen = note;
      _libraryToken++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      ChatPage(
        chat: widget.chat,
        library: widget.library,
        settings: widget.settings,
      ),
      MobileLibraryPage(
        key: ValueKey('mobile-lib-$_libraryToken'),
        library: widget.library,
        fileLibrary: widget.fileLibrary,
        initialNote: _noteToOpen,
        onContinueResearch: (topic, clarification) {
          setState(() => _index = 2);
          widget.topicService.run(topic, clarification: clarification);
        },
      ),
      TopicPage(
        topicService: widget.topicService,
        library: widget.library,
        onOpenReport: (path) {
          final matches = widget.library.notes.where((n) => n.filePath == path);
          if (matches.isNotEmpty) _openNote(matches.first);
        },
        onOpenNote: _openNote,
      ),
      KnowledgePage(
        library: widget.library,
        settings: widget.settings,
        topicService: widget.topicService,
        memory: widget.memory,
        onOpenNote: _openNote,
        onOpenTopic: () => setState(() => _index = 2),
      ),
      WritingPage(
        document: widget.document,
        proBook: widget.proBook,
        mindMap: widget.mindMap,
        book: widget.book,
        paper: widget.paper,
      ),
      MobileSettingsPage(settings: widget.settings, library: widget.library),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('第二大脑', style: TextStyle(fontSize: 18)),
            Text(
              '自进化智能体',
              style: TextStyle(fontSize: 10.5, color: Color(0xFF9B9B9F)),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: () => setState(() => _index = 5),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index > 4 ? 0 : _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '对话',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: '知识库',
          ),
          NavigationDestination(
            icon: Icon(Icons.travel_explore_outlined),
            selectedIcon: Icon(Icons.travel_explore),
            label: '研究',
          ),
          NavigationDestination(
            icon: Icon(Icons.hub_outlined),
            selectedIcon: Icon(Icons.hub),
            label: '体系',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_stories_outlined),
            selectedIcon: Icon(Icons.auto_stories),
            label: '写作',
          ),
        ],
      ),
    );
  }
}
