import 'package:flutter/material.dart';

import '../services/book_service.dart';
import '../services/document_service.dart';
import '../services/mind_map_service.dart';
import '../services/paper_service.dart';
import '../services/pro_book_service.dart';
import '../services/promo_service.dart';
import 'book_page.dart';
import 'document_page.dart';
import 'mind_map_page.dart';
import 'paper_page.dart';
import 'pro_book_page.dart';
import 'promo_page.dart';
import 'responsive.dart';

/// 写作分区元信息：值 + 图标 + 名称（供段控与下拉共用）。
const List<({int value, IconData icon, String label})> _writingTabs = [
  (value: 0, icon: Icons.description_outlined, label: '文档'),
  (value: 4, icon: Icons.account_tree_outlined, label: '思维导图'),
  (value: 1, icon: Icons.menu_book_outlined, label: '专业书籍'),
  (value: 2, icon: Icons.auto_stories_outlined, label: '小说'),
  (value: 3, icon: Icons.article_outlined, label: '论文'),
  (value: 5, icon: Icons.campaign_outlined, label: '推广'),
];

class WritingPage extends StatefulWidget {
  const WritingPage({
    super.key,
    required this.document,
    required this.proBook,
    required this.mindMap,
    required this.book,
    required this.paper,
    required this.promo,
    this.initialTab = 0,
  });

  final DocumentService document;
  final ProBookService proBook;
  final MindMapService mindMap;
  final BookService book;
  final PaperService paper;
  final PromoService promo;

  /// 0=文档，1=专业书籍，2=小说，3=论文，4=思维导图，5=推广。
  final int initialTab;

  @override
  State<WritingPage> createState() => _WritingPageState();
}

class _WritingPageState extends State<WritingPage> {
  late int _tab = widget.initialTab;

  @override
  void didUpdateWidget(covariant WritingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _tab = widget.initialTab;
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompact;
    return Column(
      children: [
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(color: Color(0xFFECECEE), width: 1),
            ),
          ),
          child: Row(
            children: [
              const Text(
                '写作',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 18),
              // 窄屏用下拉切换分区，避免 6 段控溢出；宽屏保持段控。
              if (compact)
                Expanded(child: _buildTabDropdown())
              else
                _buildSegmented(),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              DocumentPage(document: widget.document),
              ProBookPage(service: widget.proBook),
              BookPage(book: widget.book),
              PaperPage(paper: widget.paper),
              MindMapPage(service: widget.mindMap),
              PromoPage(service: widget.promo),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSegmented() {
    return SegmentedButton<int>(
      segments: [
        for (final t in _writingTabs)
          ButtonSegment(
            value: t.value,
            icon: Icon(t.icon, size: 16),
            label: Text(t.label),
          ),
      ],
      selected: {_tab},
      onSelectionChanged: (values) => setState(() => _tab = values.first),
    );
  }

  Widget _buildTabDropdown() {
    return DropdownButtonHideUnderline(
      child: DropdownButton<int>(
        value: _tab,
        isExpanded: true,
        isDense: true,
        borderRadius: BorderRadius.circular(10),
        items: [
          for (final t in _writingTabs)
            DropdownMenuItem(
              value: t.value,
              child: Row(
                children: [
                  Icon(t.icon, size: 16, color: const Color(0xFF6B6B70)),
                  const SizedBox(width: 8),
                  Text(t.label, style: const TextStyle(fontSize: 14)),
                ],
              ),
            ),
        ],
        onChanged: (v) {
          if (v != null) setState(() => _tab = v);
        },
      ),
    );
  }
}
