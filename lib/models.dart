class StandardNote {
  StandardNote({
    required this.filePath,
    required this.fileName,
    required this.frontmatterRaw,
    required this.standardNo,
    required this.fullTitle,
    required this.category,
    required this.year,
    required this.status,
    required this.tags,
    required this.body,
    required this.attachmentRelPath,
    required this.modified,
    this.research = '',
  });

  final String filePath;
  final String fileName;
  String frontmatterRaw;
  String standardNo;
  String fullTitle;
  String category;
  String year;
  String status;
  List<String> tags;
  String body;
  String? attachmentRelPath;
  DateTime modified;

  /// 该笔记所属的主题研究（为空表示非研究产物）。
  String research;

  /// 是否为「主题研究」生成的研究报告笔记。
  bool get isResearchReport =>
      frontmatterRaw.contains('来源: 主题研究') || fullTitle.startsWith('【研究】');
}

enum FileKind { video, image, document, photo, other }

extension FileKindInfo on FileKind {
  String get label => switch (this) {
        FileKind.video => '视频',
        FileKind.image => '图片',
        FileKind.document => '文档',
        FileKind.photo => '照片',
        FileKind.other => '其他',
      };

  String get folder => label;
}

class LibraryFile {
  LibraryFile({
    required this.path,
    required this.name,
    required this.kind,
    required this.size,
    required this.modified,
  });

  final String path;
  final String name;
  final FileKind kind;
  final int size;
  final DateTime modified;

  bool get isImage => kind == FileKind.image || kind == FileKind.photo;
}

class ResearchRecord {
  ResearchRecord({
    required this.id,
    required this.topic,
    required this.createdAt,
    required this.logs,
    this.reportPath,
    List<String>? projectPaths,
  }) : projectPaths = projectPaths ?? const [];

  final String id;
  final String topic;
  final DateTime createdAt;
  final List<String> logs;
  String? reportPath;

  /// 本次研究挂接的本地工程绝对路径（用于结合工程代码/文档辅助研究）。
  final List<String> projectPaths;

  Map<String, dynamic> toJson() => {
        'id': id,
        'topic': topic,
        'createdAt': createdAt.toIso8601String(),
        'logs': logs,
        'reportPath': reportPath,
        'projectPaths': projectPaths,
      };

  factory ResearchRecord.fromJson(Map<String, dynamic> json) => ResearchRecord(
        id: json['id'] as String,
        topic: json['topic'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        logs: (json['logs'] as List?)?.map((e) => e.toString()).toList() ?? [],
        reportPath: json['reportPath'] as String?,
        projectPaths:
            (json['projectPaths'] as List?)?.map((e) => e.toString()).toList() ??
                const [],
      );
}

class ChatMessage {
  ChatMessage({required this.role, required this.content});
  final String role;
  String content;

  Map<String, dynamic> toJson() => {'role': role, 'content': content};

  factory ChatMessage.fromJson(Map<String, dynamic> json) =>
      ChatMessage(role: json['role'] as String, content: json['content'] as String);
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.messages,
  });

  final String id;
  String title;
  final DateTime createdAt;
  final List<ChatMessage> messages;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
        id: json['id'] as String,
        title: json['title'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        messages: (json['messages'] as List)
            .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
      );
}
