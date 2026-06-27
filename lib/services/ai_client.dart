import 'dart:convert';

import 'package:http/http.dart' as http;

import 'settings_service.dart';

/// 一次性（非流式）的大模型调用。
class AiClient {
  AiClient(this.settings);

  final SettingsService settings;

  Future<String> complete({
    required String system,
    required String user,
  }) async {
    final response = await http
        .post(
          Uri.parse('${settings.baseUrl}/chat/completions'),
          headers: {
            'Authorization': 'Bearer ${settings.apiKey}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': settings.model,
            'stream': false,
            'messages': [
              {'role': 'system', 'content': system},
              {'role': 'user', 'content': user},
            ],
          }),
        )
        .timeout(const Duration(minutes: 3));
    if (response.statusCode != 200) {
      throw Exception(
          'HTTP ${response.statusCode} ${utf8.decode(response.bodyBytes)}');
    }
    final json =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final content =
        (json['choices']?[0]?['message']?['content'] as String? ?? '').trim();
    if (content.isEmpty) throw Exception('模型未返回内容');
    return content;
  }
}
