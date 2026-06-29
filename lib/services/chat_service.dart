import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'agent/memory/memory_service.dart';
import 'settings_service.dart';
import 'web_reader.dart';

class ChatService extends ChangeNotifier {
  ChatService(this.settings, this.memory);

  final SettingsService settings;

  /// 全局用户记忆（第二大脑级）：发送前注入相关记忆，回复后抽取新记忆。
  final MemoryService memory;

  List<ChatSession> sessions = [];
  ChatSession? current;
  bool streaming = false;

  File? _storeFile;

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _storeFile = File('${dir.path}\\sessions.json');
    if (await _storeFile!.exists()) {
      try {
        final list = jsonDecode(await _storeFile!.readAsString()) as List;
        sessions = list
            .map((e) => ChatSession.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        sessions = [];
      }
    }
  }

  Future<void> _persist() async {
    if (_storeFile == null) return;
    await _storeFile!
        .writeAsString(jsonEncode(sessions.map((s) => s.toJson()).toList()));
  }

  void newSession() {
    current = null;
    notifyListeners();
  }

  void openSession(ChatSession session) {
    current = session;
    notifyListeners();
  }

  Future<void> deleteSession(ChatSession session) async {
    sessions.remove(session);
    if (current == session) current = null;
    notifyListeners();
    await _persist();
  }

  Future<void> send(String userText, {required String systemPrompt}) async {
    if (streaming) return;
    if (current == null) {
      final title = userText.replaceAll('\n', ' ');
      current = ChatSession(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: title.length > 24 ? title.substring(0, 24) : title,
        createdAt: DateTime.now(),
        messages: [],
      );
      sessions.insert(0, current!);
    }
    final session = current!;
    session.messages.add(ChatMessage(role: 'user', content: userText));
    final assistant = ChatMessage(role: 'assistant', content: '');
    session.messages.add(assistant);
    streaming = true;
    notifyListeners();

    try {
      // 发送前注入全局用户记忆：索引常驻 system，相关正文作为 system-reminder 注入。
      var systemContent = systemPrompt;
      String injection = '';
      try {
        final instr = await memory.instructions();
        if (instr.isNotEmpty) systemContent = '$systemContent\n\n$instr';
        final recall = await memory.recall(query: userText);
        if (!recall.isEmpty) injection = recall.injection;
      } catch (_) {
        // 记忆失败不影响正常聊天（不静默兜底业务结果，仅跳过记忆增强）。
      }

      // 若用户消息里贴了网址，直接读取其正文作为上下文（复用共享 WebReader，
      // 与主题研究 / Agent 的 read_url 工具同源）。这样聊天里贴个链接就能"读"。
      final webContext = await _readUrlsIn(userText);

      final payload = <Map<String, String>>[
        {'role': 'system', 'content': systemContent},
        if (injection.isNotEmpty) {'role': 'system', 'content': injection},
        if (webContext.isNotEmpty) {'role': 'system', 'content': webContext},
        for (final m in session.messages.where((m) => m.content.isNotEmpty))
          {'role': m.role, 'content': m.content},
      ];
      await for (final delta in _stream(payload)) {
        assistant.content += delta;
        notifyListeners();
      }
      if (assistant.content.isEmpty) {
        assistant.content = '（模型未返回内容）';
      }
    } catch (e) {
      assistant.content += '\n\n> 请求失败：$e';
    }
    streaming = false;
    notifyListeners();
    await _persist();

    // 回复结束后后台抽取全局用户记忆（user/feedback）。
    if (assistant.content.isNotEmpty &&
        !assistant.content.startsWith('（模型未返回')) {
      unawaited(_extractMemory(userText, assistant.content));
    }
  }

  // 共享网页读取器：把聊天里出现的链接读成正文，注入上下文。
  final WebReader _webReader = WebReader();

  /// 提取消息中的网址（最多 2 个）并并行读取正文，拼成一段上下文文本。
  /// 读不到的链接直接跳过；没有链接时返回空串。
  Future<String> _readUrlsIn(String text) async {
    final urls = RegExp(r'https?://[^\s，,）)】\]"]+')
        .allMatches(text)
        .map((m) => m.group(0)!)
        .toSet()
        .take(2)
        .toList();
    if (urls.isEmpty) return '';
    final pages = await Future.wait(
      urls.map((u) =>
          _webReader.readMarkdown(u, timeout: const Duration(seconds: 25))),
    );
    final buf = StringBuffer('以下是用户消息中链接的网页正文，供你参考作答：\n');
    var any = false;
    for (var i = 0; i < urls.length; i++) {
      final md = pages[i];
      if (md == null) continue;
      any = true;
      // 单页正文裁剪到 6000 字，避免上下文过长。
      final clip = md.length > 6000 ? '${md.substring(0, 6000)}…（已截断）' : md;
      buf.writeln('\n【${urls[i]}】\n$clip\n');
    }
    return any ? buf.toString() : '';
  }

  Future<void> _extractMemory(String userText, String reply) async {
    try {
      await memory.extract(transcript: '[用户] $userText\n[助手] $reply');
    } catch (_) {
      // 抽取失败不影响聊天。
    }
  }

  Stream<String> _stream(List<Map<String, String>> messages) async* {
    // 聊天走 chat 角色通道（默认仍是 DeepSeek，可在设置里改用其它模型）。
    const role = ModelRole.chat;
    final request = http.Request('POST',
        Uri.parse('${settings.roleBaseUrl(role)}/chat/completions'));
    request.headers['Authorization'] = 'Bearer ${settings.roleApiKey(role)}';
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode({
      'model': settings.roleModel(role),
      'messages': messages,
      'stream': true,
    });

    final response = await http.Client().send(request);
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw Exception('HTTP ${response.statusCode} $body');
    }

    var buffer = '';
    await for (final chunk in response.stream.transform(utf8.decoder)) {
      buffer += chunk;
      while (true) {
        final newline = buffer.indexOf('\n');
        if (newline < 0) break;
        final line = buffer.substring(0, newline).trim();
        buffer = buffer.substring(newline + 1);
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') return;
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final content =
              json['choices']?[0]?['delta']?['content'] as String?;
          if (content != null && content.isNotEmpty) yield content;
        } catch (_) {
          // 忽略无法解析的片段
        }
      }
    }
  }
}
