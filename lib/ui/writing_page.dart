import 'package:flutter/material.dart';

import '../services/book_service.dart';
import '../services/document_service.dart';
import '../services/paper_service.dart';
import 'book_page.dart';
import 'document_page.dart';
import 'paper_page.dart';

class WritingPage extends StatefulWidget {
  const WritingPage({
    super.key,
    required this.document,
    required this.book,
    required this.paper,
    this.initialTab = 0,
  });

  final DocumentService document;
  final BookService book;
  final PaperService paper;

  /// 0=文档，1=小说，2=论文。
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
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                    value: 0,
                    icon: Icon(Icons.description_outlined, size: 16),
                    label: Text('文档'),
                  ),
                  ButtonSegment(
                    value: 1,
                    icon: Icon(Icons.auto_stories_outlined, size: 16),
                    label: Text('小说'),
                  ),
                  ButtonSegment(
                    value: 2,
                    icon: Icon(Icons.article_outlined, size: 16),
                    label: Text('论文'),
                  ),
                ],
                selected: {_tab},
                onSelectionChanged: (values) {
                  setState(() => _tab = values.first);
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              DocumentPage(document: widget.document),
              BookPage(book: widget.book),
              PaperPage(paper: widget.paper),
            ],
          ),
        ),
      ],
    );
  }
}
