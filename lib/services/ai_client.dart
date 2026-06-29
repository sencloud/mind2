import 'agent/model_client.dart';
import 'settings_service.dart';

/// 一次性（非流式）的大模型调用。
/// 已统一到 [ModelClient]：本类仅作为面向 UI（图谱/知识诊断）的薄封装，
/// 走 [ModelRole.chat] 通道，不再各自维护一份 `/chat/completions` 接入逻辑。
class AiClient {
  AiClient(this.settings);

  final SettingsService settings;

  Future<String> complete({
    required String system,
    required String user,
  }) async {
    final content = await ModelClient(
      settings,
      role: ModelRole.chat,
    ).complete(system: system, user: user);
    if (content.isEmpty) throw Exception('模型未返回内容');
    return content;
  }
}
