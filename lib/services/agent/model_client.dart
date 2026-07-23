import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../util/text_util.dart';
import '../settings_service.dart';
import 'messages.dart';

/// 与模型对话的客户端：OpenAI/DeepSeek 兼容的 `/chat/completions`，
/// 支持 SSE 流式输出与原生 Function Calling（tools / tool_calls / tool 角色）。
///
/// 两条通道：
/// - 默认（实验/项目主循环）：使用设置里所选的实验模型供应商
///   （`experimentBaseUrl/experimentApiKey/experimentModel`）。
/// - 小模型（`small: true`）：使用通用默认模型（`baseUrl/apiKey/model`，内置 DeepSeek），
///   用于记忆「选择题/抽取」这类廉价任务，对应 Claude Code「用小模型做选择」的设计。
class ModelClient {
  /// [role] 决定走哪条模型通道（见 [ModelRole]）。
  /// 兼容旧调用：不传 role 时，`small: true` → small 通道，否则 → agent 通道，
  /// 与改造前「small=默认DeepSeek / 否则=实验模型」的语义一致。
  ModelClient(this.settings, {this.small = false, ModelRole? role})
      : role = role ?? (small ? ModelRole.small : ModelRole.agent);

  final SettingsService settings;

  /// 是否走小模型通道（记忆选择/抽取等廉价任务）。保留以兼容旧调用。
  final bool small;

  /// 本客户端服务的任务角色，决定模型/供应商。
  final ModelRole role;

  String get _baseUrl => settings.roleBaseUrl(role);
  String get _apiKey => settings.roleApiKey(role);
  String get _model => settings.roleModel(role);

  /// 一次性（非工具）补全：内部复用 [stream]，统一了过去散落在各 service 里
  /// 重复的 `/chat/completions` 接入逻辑（超时、错误处理、SSE 解析）。
  /// 传 [system]/[user] 或直接传完整 [messages] 二选一。
  Future<String> complete({
    String? system,
    String? user,
    List<Map<String, dynamic>>? messages,
    bool jsonMode = false,
    bool Function()? isCancelled,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final msgs =
        messages ??
        <Map<String, dynamic>>[
          if (system != null) {'role': 'system', 'content': system},
          if (user != null) {'role': 'user', 'content': user},
        ];
    final turn = await stream(
      messages: msgs,
      jsonMode: jsonMode,
      isCancelled: isCancelled,
      timeout: timeout,
    );
    return turn.content.trim();
  }

  /// 一次性补全并解析为 JSON 对象：内部走 `complete(jsonMode: true)` 后调
  /// [parseJsonObject]，统一了各 service 里「补全 + 提取 JSON」的重复逻辑。
  Future<Map<String, dynamic>> completeJson({
    String? system,
    String? user,
    List<Map<String, dynamic>>? messages,
    bool Function()? isCancelled,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final reply = await complete(
      system: system,
      user: user,
      messages: messages,
      jsonMode: true,
      isCancelled: isCancelled,
      timeout: timeout,
    );
    return parseJsonObject(reply);
  }

  /// 流式发起一轮对话。
  /// - [messages]：完整消息数组（API 形态）。
  /// - [tools]：工具的 JSON Schema 列表（为空则不带 tools）。
  /// - [onTextDelta]：文本增量回调（用于逐字实时显示）。
  /// - [onReasoningDelta]：推理过程增量（DeepSeek reasoning_content，可选）。
  /// - [onToolCallStart]：当某个工具调用的名字确定时回调一次。
  /// - [isCancelled]：返回 true 时尽快中止。
  Future<AssistantTurn> stream({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onTextDelta,
    void Function(String delta)? onReasoningDelta,
    void Function(String toolName)? onToolCallStart,
    bool Function()? isCancelled,
    bool jsonMode = false,
    Duration timeout = const Duration(minutes: 5),
    Duration? idleTimeout,
  }) async {
    final uri = Uri.parse('$_baseUrl/chat/completions');
    final body = <String, dynamic>{
      'model': _model,
      'stream': true,
      'messages': messages,
      if (jsonMode) 'response_format': {'type': 'json_object'},
      if (tools != null && tools.isNotEmpty) ...{
        'tools': tools,
        'tool_choice': 'auto',
      },
    };

    final client = http.Client();
    try {
      final req = http.Request('POST', uri)
        ..headers['Authorization'] = 'Bearer $_apiKey'
        ..headers['Content-Type'] = 'application/json'
        ..headers['Accept'] = 'text/event-stream'
        ..body = jsonEncode(body);

      final resp = await client.send(req).timeout(timeout);
      if (resp.statusCode != 200) {
        final text = await resp.stream.bytesToString();
        throw Exception('HTTP ${resp.statusCode}: ${clip(text, 400, suffix: '…')}');
      }

      final buf = _ToolCallAccumulator(onToolCallStart);
      final content = StringBuffer();
      final reasoning = StringBuffer();
      String? finishReason;

      var lines = resp.stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());
      // 空闲超时：若长时间没有新分片流入，判定连接假死并抛出，交由上层重试。
      if (idleTimeout != null) lines = lines.timeout(idleTimeout);

      await for (final line in lines) {
        if (isCancelled?.call() ?? false) break;
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;
        Map<String, dynamic> json;
        try {
          json = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final choices = json['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final choice = choices.first as Map<String, dynamic>;
        final delta = choice['delta'];
        if (delta is Map<String, dynamic>) {
          final c = delta['content'];
          if (c is String && c.isNotEmpty) {
            content.write(c);
            onTextDelta?.call(c);
          }
          final r = delta['reasoning_content'];
          if (r is String && r.isNotEmpty) {
            reasoning.write(r);
            onReasoningDelta?.call(r);
          }
          final tc = delta['tool_calls'];
          if (tc is List) buf.add(tc);
        }
        final fr = choice['finish_reason'];
        if (fr is String && fr.isNotEmpty) finishReason = fr;
      }

      return AssistantTurn(
        content: content.toString(),
        reasoning: reasoning.toString(),
        toolCalls: buf.build(),
        finishReason: finishReason,
      );
    } finally {
      client.close();
    }
  }

  /// 带「瞬时网络断线重试」的流式补全：长流式响应常被服务端/中间代理中途断开，
  /// 这里对可重试的网络错误做有限次数重试（用户主动取消或非网络类错误不重试）。
  /// 每次重试前回调 [onAttempt]，让调用方清空上一轮已累计的文本再重写。
  Future<AssistantTurn> streamWithRetry({
    required List<Map<String, dynamic>> messages,
    void Function(String delta)? onTextDelta,
    bool Function()? isCancelled,
    int maxAttempts = 3,
    Duration? idleTimeout,
    Duration timeout = const Duration(minutes: 5),
    void Function(int attempt)? onAttempt,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (isCancelled?.call() ?? false) break;
      if (attempt > 1) onAttempt?.call(attempt);
      try {
        return await stream(
          messages: messages,
          onTextDelta: onTextDelta,
          isCancelled: isCancelled,
          idleTimeout: idleTimeout,
          timeout: timeout,
        );
      } catch (e) {
        lastError = e;
        if ((isCancelled?.call() ?? false) || !isTransientNetworkError(e)) {
          rethrow;
        }
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
    if (isCancelled?.call() ?? false) {
      return AssistantTurn(finishReason: 'cancelled');
    }
    throw Exception('连续 $maxAttempts 次因网络中断失败：$lastError');
  }

  /// 从模型回复里稳健地提取一个 JSON 对象：先剥 ```json 围栏，再取首个 `{`
  /// 到最后一个 `}` 之间的片段解析。统一取代各 service 里自写的 `_parseJson`。
  static Map<String, dynamic> parseJsonObject(String reply) {
    var t = reply.trim();
    if (t.startsWith('```')) {
      t = t.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '');
      final fence = t.lastIndexOf('```');
      if (fence >= 0) t = t.substring(0, fence);
      t = t.trim();
    }
    final start = t.indexOf('{');
    final end = t.lastIndexOf('}');
    if (start < 0 || end <= start) throw Exception('模型未返回 JSON');
    final body = t.substring(start, end + 1);
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } on FormatException {
      // 仅当严格解析失败时，才容忍「对象/数组结尾多余逗号」这类常见非法 JSON：
      // 去掉尾随逗号后重试，避免误伤字符串值里合法出现的 `, }` / `, ]`。
      // 注意 replaceAll 不解释 $1 反向引用，必须用 replaceAllMapped。
      final relaxed = body.replaceAllMapped(
        RegExp(r',(\s*[}\]])'),
        (m) => m.group(1)!,
      );
      return jsonDecode(relaxed) as Map<String, dynamic>;
    }
  }

  /// 判断是否为可重试的瞬时网络错误（连接被断开 / 超时等），而非模型/参数错误。
  static bool isTransientNetworkError(Object e) {
    if (e is SocketException || e is TimeoutException) return true;
    if (e is http.ClientException) return true;
    final s = e.toString().toLowerCase();
    return s.contains('connection closed') ||
        s.contains('connection reset') ||
        s.contains('connection terminated') ||
        s.contains('connection refused') ||
        s.contains('broken pipe') ||
        s.contains('timed out') ||
        s.contains('timeout') ||
        s.contains('httpexception') ||
        s.contains('clientexception');
  }
}

/// 累积流式 tool_calls 分片（按 index 聚合 id/name/arguments）。
class _ToolCallAccumulator {
  _ToolCallAccumulator(this.onToolCallStart);

  final void Function(String toolName)? onToolCallStart;
  final Map<int, _PartialCall> _calls = {};

  void add(List<dynamic> deltas) {
    for (final d in deltas) {
      if (d is! Map) continue;
      final index = (d['index'] as int?) ?? 0;
      final call = _calls.putIfAbsent(index, () => _PartialCall());
      final id = d['id'];
      if (id is String && id.isNotEmpty) call.id = id;
      final fn = d['function'];
      if (fn is Map) {
        final name = fn['name'];
        if (name is String && name.isNotEmpty) {
          final wasEmpty = call.name.isEmpty;
          call.name = name;
          if (wasEmpty) onToolCallStart?.call(name);
        }
        final args = fn['arguments'];
        if (args is String) call.args.write(args);
      }
    }
  }

  List<ToolCall> build() {
    final keys = _calls.keys.toList()..sort();
    return [
      for (final k in keys)
        ToolCall(
          id: _calls[k]!.id.isEmpty ? 'call_$k' : _calls[k]!.id,
          name: _calls[k]!.name,
          arguments: _calls[k]!.args.toString(),
        ),
    ];
  }
}

class _PartialCall {
  String id = '';
  String name = '';
  final StringBuffer args = StringBuffer();
}
