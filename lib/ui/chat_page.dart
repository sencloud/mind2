import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models.dart';
import '../services/chat_service.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import 'enter_to_send.dart';

const _attachMarker = '【附件：';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.chat,
    required this.library,
    required this.settings,
  });

  final ChatService chat;
  final LibraryService library;
  final SettingsService settings;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  late final List<({String label, String prompt})> _quickPrompts;
  StandardNote? _attached;

  static const _quickPromptPool = [
    (label: '导入资料', prompt: '我想把本地文件整理进知识库，应该从哪里开始？'),
    (label: '创建笔记', prompt: '帮我新建一份结构化笔记，适合记录标准、政策或研究资料'),
    (label: '主题研究', prompt: '我想围绕一个主题做资料收集、分析和研究报告，应该怎么操作？'),
    (label: '项目助手', prompt: '如果我要管理一个项目，可以怎样用项目功能拆解任务和沉淀资料？'),
    (label: '知识库问答', prompt: '知识库里还没有资料时，我可以先问你哪些问题？'),
    (label: '写作空间', prompt: '介绍一下写作功能，小说和论文分别适合怎么使用？'),
    (label: '论文写作', prompt: '我想把研究资料转成论文，推荐的工作流程是什么？'),
    (label: '文件预览', prompt: '导入 PDF、文档或图片后，可以如何预览和整理？'),
    (label: '学习计划', prompt: '帮我制定一个熟悉这款知识库工具的一周学习计划'),
    (label: '使用建议', prompt: '作为第一次使用的新用户，我应该先完成哪三件事？'),
  ];

  @override
  void initState() {
    super.initState();
    final prompts = List<({String label, String prompt})>.of(_quickPromptPool);
    prompts.shuffle(Random());
    _quickPrompts = prompts.take(4).toList();
  }

  String _systemPrompt() {
    final notes = widget.library.notes;
    final buffer = StringBuffer()
      ..writeln('你是「第二大脑」，用户的本地知识库助手。')
      ..writeln(
        '用户的本地知识库收录了 ${notes.length} 份文件（以中国档案领域标准为主，也可能包含其他领域的政策、报告等），目录（仅标题/编号索引）如下：',
      );
    // 目录只列标题与编号，不带阅读状态。
    // 阅读状态（未读/在读/已读）是用户的学习进度标记，与“能否解读”无关，
    // 之前把它写进目录会误导模型“未读=无内容=不能解读”，这里去掉。
    for (final n in notes) {
      final no = n.standardNo.isEmpty ? '' : '${n.standardNo} ';
      buffer.writeln('- [${n.category}] $no${n.fullTitle}');
    }
    buffer
      ..writeln()
      ..writeln('要求：')
      ..writeln('1. 始终用中文回答，引用标准时给出标准号；')
      ..writeln(
        '2. 上面的目录只是知识库的索引。无论某条目是否已生成本地笔记，你都应基于'
        '你对该标准/文件的专业了解进行解读；当知识库暂无该条目的详细笔记时，'
        '依据通用专业知识作答，并简要说明“以下为基于通用知识的解读，知识库暂未收录其详细笔记”。'
        '绝不要因为条目的阅读状态（未读/在读/已读）而拒绝解读——阅读状态只是用户的学习进度。',
      )
      ..writeln('3. 用户消息中带有【附件：…】的部分是标准笔记原文，请优先基于它回答；')
      ..writeln('4. 回答面向学习和实际工作，结构清晰、重点突出。');
    return buffer.toString();
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _controller.text).trim();
    if (text.isEmpty || widget.chat.streaming) return;
    var content = text;
    final attached = _attached;
    if (attached != null) {
      final body = attached.body.length > 6000
          ? attached.body.substring(0, 6000)
          : attached.body;
      content = '$text\n\n$_attachMarker标准笔记《${attached.fileName}》】\n$body';
    }
    _controller.clear();
    setState(() => _attached = null);
    await widget.chat.send(content, systemPrompt: _systemPrompt());
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _pickAttachment() async {
    final note = await showDialog<StandardNote>(
      context: context,
      builder: (context) => _NotePickerDialog(library: widget.library),
    );
    if (note != null) setState(() => _attached = note);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.chat,
      builder: (context, _) {
        final session = widget.chat.current;
        if (session == null || session.messages.isEmpty) {
          return _buildEmptyState();
        }
        _scrollToBottom();
        return Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(48, 16, 48, 24),
                itemCount: session.messages.length,
                itemBuilder: (context, i) =>
                    _MessageBubble(message: session.messages[i]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 0, 48, 24),
              child: _buildInput(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '我们该做什么？',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 28),
            _buildInput(),
            const SizedBox(height: 20),
            for (final action in _quickPrompts)
              _QuickAction(
                label: action.label,
                prompt: action.prompt,
                onTap: () {
                  _controller.text = action.prompt;
                  setState(() {});
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInput() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE3E3E6)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_attached != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Chip(
                avatar: const Icon(Icons.description_outlined, size: 16),
                label: Text(
                  _attached!.fileName,
                  style: const TextStyle(fontSize: 12),
                ),
                onDeleted: () => setState(() => _attached = null),
                visualDensity: VisualDensity.compact,
              ),
            ),
          EnterToSend(
            onSubmit: _send,
            child: TextField(
              controller: _controller,
              minLines: 1,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: '随心输入，向你的知识库提问…（回车发送，Ctrl/Shift+回车换行）',
                hintStyle: TextStyle(color: Color(0xFFA8A8AC), fontSize: 14),
                border: InputBorder.none,
                isDense: true,
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              IconButton(
                tooltip: '引用一份标准笔记',
                onPressed: _pickAttachment,
                icon: const Icon(Icons.add, size: 20),
                visualDensity: VisualDensity.compact,
              ),
              const Spacer(),
              ListenableBuilder(
                listenable: widget.chat,
                builder: (context, _) => IconButton.filled(
                  onPressed: widget.chat.streaming ? null : () => _send(),
                  icon: widget.chat.streaming
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_upward, size: 18),
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF1A1A1A),
                    foregroundColor: Colors.white,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.label,
    required this.prompt,
    required this.onTap,
  });

  final String label;
  final String prompt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.bolt_outlined, size: 16, color: Color(0xFF9B9B9F)),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(fontSize: 13.5, color: Color(0xFF2B2B2E)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                prompt,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFFA8A8AC),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.role == 'user') {
      var text = message.content;
      String? attachName;
      final idx = text.indexOf(_attachMarker);
      if (idx >= 0) {
        final head = text.substring(idx);
        final close = head.indexOf('】');
        if (close > 0) attachName = head.substring(_attachMarker.length, close);
        text = text.substring(0, idx).trim();
      }
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 16, left: 80),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F1F3),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SelectableText(text, style: const TextStyle(fontSize: 14)),
              if (attachName != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.attach_file,
                        size: 13,
                        color: Color(0xFF9B9B9F),
                      ),
                      Text(
                        attachName,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF9B9B9F),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 24, right: 40),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(7),
            ),
            child: const Icon(
              Icons.psychology_outlined,
              color: Colors.white,
              size: 15,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: message.content.isEmpty
                ? const Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: _TypingDots(),
                    ),
                  )
                : MarkdownBody(
                    data: message.content,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet(
                      p: const TextStyle(fontSize: 14, height: 1.7),
                      code: const TextStyle(
                        fontSize: 13,
                        backgroundColor: Color(0xFFF1F1F3),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 等待回复时的「···」打字动效。
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 5),
              _dot(i),
            ],
          ],
        );
      },
    );
  }

  Widget _dot(int index) {
    // 三个点依次起伏
    final t = (_controller.value - index * 0.18) % 1.0;
    final wave = t < 0.5 ? (1 - (t * 2 - 0.5).abs() * 2) : 0.0;
    return Transform.translate(
      offset: Offset(0, -3.5 * wave),
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Color.lerp(
            const Color(0xFFC9C9CD),
            const Color(0xFF6B6B70),
            wave,
          ),
        ),
      ),
    );
  }
}

class _NotePickerDialog extends StatefulWidget {
  const _NotePickerDialog({required this.library});

  final LibraryService library;

  @override
  State<_NotePickerDialog> createState() => _NotePickerDialogState();
}

class _NotePickerDialogState extends State<_NotePickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final notes = widget.library.notes
        .where(
          (n) =>
              q.isEmpty ||
              n.fileName.toLowerCase().contains(q) ||
              n.standardNo.toLowerCase().contains(q),
        )
        .toList();
    return Dialog(
      child: SizedBox(
        width: 520,
        height: 480,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索标准…',
                  prefixIcon: Icon(Icons.search, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: notes.length,
                itemBuilder: (context, i) {
                  final n = notes[i];
                  return ListTile(
                    dense: true,
                    title: Text(
                      n.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      n.category,
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => Navigator.pop(context, n),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
